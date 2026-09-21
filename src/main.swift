import Cocoa

// ContextMeter
// Menu bar meter for how big each live Claude Code window has grown.
//
// Reads the local session logs in ~/.claude/projects/*/*.jsonl, so it works
// whichever Claude account is signed in. Every step in a window re-reads the
// whole context, so the bigger a window gets, the more each step costs.
//
// The menu bar shows the window you touched most recently. The dropdown lists
// only windows active in the last few hours, newest first, so old chats never
// pile up.

// MARK: - Settings

let fm = FileManager.default
let fmHome = fm.homeDirectoryForCurrentUser
let projectsDir = fmHome.appendingPathComponent(".claude/projects")

let amberAt = 150_000
let redAt = 250_000
let liveWindowHours = 3.0
let maxListed = 6
let pollSeconds = 5.0

// MARK: - Plan usage settings
//
// TWO SOURCES. With a claude.ai session key (menu: Add Claude key…) the bar
// shows claude.ai's own figures. Without one, or when the key expires, it
// falls back to an estimate from the local Claude Code logs, so it never goes
// blank, and marks that with a trailing `~`.
//
// The estimate cannot know the real ceiling, which Anthropic does not publish,
// so its percentages are against a ceiling learned from your own history:
// every completed 5-hour block and week is recorded and the highest of each
// becomes the reference.

/// Spend weights, relative to one input token. These are the published price
/// ratios, which is the closest honest proxy for what a request costs against
/// a plan limit: a cache read is a tenth of fresh input, and output is dear.
let wInput = 1.0, wCacheWrite = 1.25, wCacheRead = 0.1, wOutput = 5.0

/// A session block is five hours from first use.
let blockHours = 5.0
/// When the weekly window resets. Learned from claude.ai the first time a key
/// works and remembered, so the estimate lines up with the real week even
/// after the key expires. Before that, weeks are counted from a fixed epoch.
var weekAnchor: Date {
    let t = UserDefaults.standard.double(forKey: "weekAnchor")
    return t > 0 ? Date(timeIntervalSince1970: t) : Date(timeIntervalSince1970: 0)
}

let usageCache = fmHome.appendingPathComponent(".claude/context-meter-usage.json")
let usageConfig = fmHome.appendingPathComponent(".claude/context-meter-config.json")

// MARK: - Per-window state, parsed incrementally

final class Session {
    let url: URL
    var offset: UInt64 = 0
    var size: UInt64 = 0
    var modified = Date.distantPast
    var seen = Set<String>()
    var context = 0
    var steps = 0
    var reread = 0
    var title = ""
    var lastPrompt = ""
    var project = ""
    var cwd = ""
    /// The Claude Code session id: the log file's name.
    var id: String { url.deletingPathExtension().lastPathComponent }

    init(url: URL) { self.url = url }

    var name: String {
        if !title.isEmpty { return title }
        if !lastPrompt.isEmpty { return String(lastPrompt.prefix(40)) }
        return "Untitled"
    }

    func update() {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let newSize = (attrs[.size] as? NSNumber)?.uint64Value else { return }
        modified = (attrs[.modificationDate] as? Date) ?? modified
        if newSize < offset { reset() }
        guard newSize > offset, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), let lastNewline = data.lastIndex(of: 0x0A) else { return }
        let complete = data[data.startIndex...lastNewline]
        offset += UInt64(complete.count)
        size = newSize
        for line in complete.split(separator: 0x0A) { parse(Data(line)) }
    }

    private func reset() {
        offset = 0; seen.removeAll(); context = 0; steps = 0; reread = 0
    }

    private func parse(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "custom-title":
            if let t = obj["customTitle"] as? String { title = t }
        case "last-prompt":
            if let p = obj["lastPrompt"] as? String { lastPrompt = p }
        case "assistant":
            if obj["isSidechain"] as? Bool == true { return }
            if let c = obj["cwd"] as? String { cwd = c; project = (c as NSString).lastPathComponent }
            guard let msg = obj["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any] else { return }
            let key = (msg["id"] as? String ?? "") + "|" + (obj["requestId"] as? String ?? "")
            if seen.contains(key) { return }
            seen.insert(key)
            func n(_ k: String) -> Int { (usage[k] as? NSNumber)?.intValue ?? 0 }
            let read = n("cache_read_input_tokens")
            let total = n("input_tokens") + n("cache_creation_input_tokens") + read
            if total == 0 { return }
            context = total
            reread += read
            steps += 1
        default:
            break
        }
    }
}

// MARK: - The real numbers, when a session key is present

/// Claude.ai's own answer: the same `session_usage` / `weekly_usage` pair
/// ClaudeMeter reads, which is the accurate 5-hour and 7-day all-model
/// picture rather than an estimate.
struct LiveUsage {
    /// Weekly windows scoped to one model, e.g. Fable, in the order claude.ai lists them.
    var scoped: [(name: String, pct: Int, resets: Date?)] = []
    var sessionPct: Int
    var sessionResets: Date?
    var weeklyPct: Int
    var weeklyResets: Date?
    var fetched: Date
}

/// Talks to claude.ai with a session key the USER pastes in. Claude never
/// reads it out of a browser: harvesting a session cookie is not its job, and
/// that is also how ClaudeMeter's key went two months stale without anyone
/// noticing. The key lives in the Keychain, never in a plist or a dotfile.
///
/// THE FAILURE MODE IS THE POINT. A usage meter whose key goes stale usually
/// just goes blank and says nothing. This one keeps the local estimate running underneath and SAYS
/// which of the two you are looking at, so a dead key is visible in the bar
/// the same day it dies.
final class ClaudeAPI {
    static let keychainService = "com.contextmeter.sessionkey"
    private(set) var live: LiveUsage?
    private(set) var lastError: String?
    /// Every window claude.ai returned, by its own key, for rows beyond the two.
    private(set) var windows: [String: (pct: Int, resets: Date?)] = [:]
    private(set) var rawBody: [String: Any] = [:]
    private var org: String?

    var hasKey: Bool { Self.readKey() != nil }

    // MARK: Keychain

    static func readKey() -> String? {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "default",
            kSecReturnData as String: true,
        ]
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8),
              !s.isEmpty else { return nil }
        return s
    }

    @discardableResult
    static func writeKey(_ key: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "default",
        ]
        SecItemDelete(base as CFDictionary)
        if key.isEmpty { return true }
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    // MARK: Fetching

    private func get(_ path: String, key: String) -> Any? {
        guard let url = URL(string: "https://claude.ai/api" + path) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        // An anonymous standard browser user agent, never a name or a product
        // string: the same rule every scraper in this workspace follows.
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        req.setValue("sessionKey=" + key, forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        var result: Any?
        var status = 0
        let wait = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let data, status == 200 { result = try? JSONSerialization.jsonObject(with: data) }
            wait.signal()
        }.resume()
        _ = wait.wait(timeout: .now() + 25)
        if status == 401 || status == 403 { lastError = "Claude key expired" }
        else if status != 200 && status != 0 { lastError = "claude.ai returned \(status)." }
        return result
    }

    /// The organisation is resolved fresh every time the key changes, never
    /// cached across accounts: caching it is precisely what left ClaudeMeter
    /// pointing at an organisation the new account could not see.
    private func organisation(key: String) -> String? {
        if let org { return org }
        guard let list = get("/organizations", key: key) as? [[String: Any]] else { return nil }
        org = list.compactMap { $0["uuid"] as? String }.first
        if org == nil { lastError = "No organisations for this account." }
        return org
    }

    /// A new key may be a different account, so the organisation is found again.
    func keyChanged() { org = nil; live = nil; lastError = nil }

    func refresh() {
        guard let key = Self.readKey() else { live = nil; lastError = nil; return }
        lastError = nil
        guard let org = organisation(key: key) else { return }
        guard let body = get("/organizations/\(org)/usage", key: key) as? [String: Any] else {
            if lastError == nil { lastError = "Could not read usage." }
            self.org = nil     // force a re-resolve next time, in case the account moved
            return
        }
        let iso = ISO8601DateFormatter()
        func window(_ k: String) -> (Int, Date?)? {
            guard let w = body[k] as? [String: Any],
                  let u = (w["utilization"] as? NSNumber)?.intValue else { return nil }
            let stamp = (w["reset_at"] ?? w["resets_at"]) as? String
            // claude.ai sends some stamps with fractional seconds and some
            // without, and one ISO formatter only reads one of the two.
            let frac = ISO8601DateFormatter()
            frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return (u, stamp.flatMap { iso.date(from: $0) ?? frac.date(from: $0) })
        }
        // `five_hour` / `seven_day` is the newer shape, `session_usage` /
        // `weekly_usage` the one this account's cache was last written with.
        rawBody = body
        var all: [String: (pct: Int, resets: Date?)] = [:]
        for k in body.keys { if let w = window(k) { all[k] = (w.0, w.1) } }
        windows = all
        guard let session = window("five_hour") ?? window("session_usage"),
              let weekly = window("seven_day") ?? window("weekly_usage") else {
            lastError = "Unfamiliar usage shape from claude.ai."
            return
        }
        // FABLE, AND ANY OTHER MODEL WITH ITS OWN WEEKLY CAP. claude.ai lists them under `limits` as `weekly_scoped`, each
        // naming its model, so a new capped model appears here by itself.
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var scoped: [(name: String, pct: Int, resets: Date?)] = []
        for l in (body["limits"] as? [[String: Any]]) ?? [] where l["kind"] as? String == "weekly_scoped" {
            let scope = l["scope"] as? [String: Any]
            let model = scope?["model"] as? [String: Any]
            guard let name = model?["display_name"] as? String,
                  let pct = (l["percent"] as? NSNumber)?.intValue else { continue }
            let stamp = l["resets_at"] as? String
            scoped.append((name, pct, stamp.flatMap { iso.date(from: $0) ?? frac.date(from: $0) }))
        }
        // Remember when the real week turns over, so the local estimate keeps
        // the same week boundaries if this key later expires.
        if let wk = weekly.1 {
            UserDefaults.standard.set(wk.addingTimeInterval(-7 * 24 * 3600).timeIntervalSince1970, forKey: "weekAnchor")
        }
        live = LiveUsage(scoped: scoped, sessionPct: session.0, sessionResets: session.1,
                         weeklyPct: weekly.0, weeklyResets: weekly.1, fetched: Date())
    }
}

// MARK: - Plan usage, from the same local logs

/// One request's weighted spend, at the moment it happened.
struct Spend: Codable { let at: Double; let cost: Double }

/// Walks every session log, not just the live ones, and keeps a rolling
/// fortnight of weighted spend so the 5-hour block and the week can be
/// answered without asking anyone's server.
///
/// Incremental by file offset, exactly like `Session`, and the result is
/// cached to disk so a relaunch does not re-read 900MB of logs. Everything
/// happens off the main thread; the menu bar never waits for it.
final class Usage {
    private var offsets: [String: UInt64] = [:]
    private var seen = Set<String>()
    private var spend: [Spend] = []
    private let queue = DispatchQueue(label: "contextmeter.usage")
    private let iso = ISO8601DateFormatter()

    /// Ceilings learned from your own history, never published figures.
    private(set) var blockCeiling = 0.0
    private(set) var weekCeiling = 0.0

    init() {
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        load()
    }

    // MARK: Reading

    private func load() {
        guard let data = try? Data(contentsOf: usageCache),
              let obj = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        offsets = obj.offsets; spend = obj.spend; seen = Set(obj.seen)
    }

    private struct Cache: Codable {
        var offsets: [String: UInt64]; var spend: [Spend]; var seen: [String]
    }

    private func save() {
        let obj = Cache(offsets: offsets, spend: spend, seen: Array(seen))
        if let data = try? JSONEncoder().encode(obj) { try? data.write(to: usageCache) }
    }

    /// Rescan on a background queue. `done` fires on the main queue.
    func refresh(done: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.scan()
            DispatchQueue.main.async(execute: done)
        }
    }

    private func scan() {
        let horizon = Date().addingTimeInterval(-15 * 24 * 3600)
        let dirs = (try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                let mod = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                guard mod > horizon else { continue }
                read(file)
            }
        }
        // A fortnight is plenty: the longest question asked of it is one week.
        let cutoff = horizon.timeIntervalSince1970
        spend.removeAll { $0.at < cutoff }
        if seen.count > 400_000 { seen.removeAll() }   // offsets still guard against double counting
        learnCeilings()
        save()
    }

    private func read(_ url: URL) {
        let key = url.path
        let start = offsets[key] ?? 0
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return }
        if size < start { offsets[key] = 0; return }
        guard size > start, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), let lastNewline = data.lastIndex(of: 0x0A) else { return }
        let complete = data[data.startIndex...lastNewline]
        offsets[key] = start + UInt64(complete.count)
        for line in complete.split(separator: 0x0A) { parse(Data(line)) }
    }

    private func parse(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "assistant",
              obj["isSidechain"] as? Bool != true,
              let msg = obj["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any],
              let stamp = obj["timestamp"] as? String,
              let at = iso.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp)
        else { return }
        let id = (msg["id"] as? String ?? "") + "|" + (obj["requestId"] as? String ?? "")
        if id == "|" || seen.contains(id) { return }
        seen.insert(id)
        func n(_ k: String) -> Double { ((usage[k] as? NSNumber)?.doubleValue) ?? 0 }
        let cost = n("input_tokens") * wInput
            + n("cache_creation_input_tokens") * wCacheWrite
            + n("cache_read_input_tokens") * wCacheRead
            + n("output_tokens") * wOutput
        guard cost > 0 else { return }
        spend.append(Spend(at: at.timeIntervalSince1970, cost: cost))
    }

    // MARK: Answering

    private func total(from: Date, to: Date = Date()) -> Double {
        let a = from.timeIntervalSince1970, b = to.timeIntervalSince1970
        return spend.reduce(0) { $0 + (($1.at >= a && $1.at < b) ? $1.cost : 0) }
    }

    /// The current 5-hour block starts at the first activity after the last
    /// gap of five hours or more, floored to the hour, which is how the window
    /// behaves in practice: it opens when you start, not on a wall clock.
    var blockStart: Date? {
        let sorted = spend.map(\.at).sorted()
        guard var cursor = sorted.last else { return nil }
        for t in sorted.reversed() {
            if cursor - t >= blockHours * 3600 { break }
            cursor = t
        }
        let floored = (cursor / 3600).rounded(.down) * 3600
        let start = Date(timeIntervalSince1970: floored)
        return Date().timeIntervalSince(start) < blockHours * 3600 ? start : nil
    }

    var blockSpend: Double { blockStart.map { total(from: $0) } ?? 0 }
    var blockEnds: Date? { blockStart.map { $0.addingTimeInterval(blockHours * 3600) } }

    /// The week runs seven days from the anchor, rolled forward to today.
    var weekStart: Date {
        var start = weekAnchor
        let week = 7.0 * 24 * 3600
        if start > Date() { return start.addingTimeInterval(-week) }
        while start.addingTimeInterval(week) <= Date() { start = start.addingTimeInterval(week) }
        return start
    }
    var weekSpend: Double { total(from: weekStart) }
    var weekEnds: Date { weekStart.addingTimeInterval(7 * 24 * 3600) }

    /// Every COMPLETED block and week in the fortnight, so the reference is
    /// your own worst case rather than a number somebody invented. A partial
    /// window in progress is never allowed to set the ceiling.
    private func learnCeilings() {
        let week = 7.0 * 24 * 3600, block = blockHours * 3600
        var weeks: [Double: Double] = [:], blocks: [Double: Double] = [:]
        let anchor = weekAnchor.timeIntervalSince1970
        for s in spend {
            weeks[((s.at - anchor) / week).rounded(.down), default: 0] += s.cost
            blocks[(s.at / block).rounded(.down), default: 0] += s.cost
        }
        let liveWeek = ((Date().timeIntervalSince1970 - anchor) / week).rounded(.down)
        let liveBlock = (Date().timeIntervalSince1970 / block).rounded(.down)
        weekCeiling = weeks.filter { $0.key != liveWeek }.values.max() ?? 0
        blockCeiling = blocks.filter { $0.key != liveBlock }.values.max() ?? 0
    }

    var blockPct: Int? { blockCeiling > 0 ? Int((blockSpend / blockCeiling * 100).rounded()) : nil }
    var weekPct: Int? { weekCeiling > 0 ? Int((weekSpend / weekCeiling * 100).rounded()) : nil }
    var hasHistory: Bool { !spend.isEmpty }
}

// MARK: - Opening a window

/// Where a click on a live window takes you. `auto` opens it in the Claude app
/// when the app knows the session, otherwise resumes it in Terminal.
enum OpenIn: String, CaseIterable {
    case auto, claude, terminal, iterm
    var title: String {
        switch self {
        case .auto: return "Automatic"
        case .claude: return "Claude app"
        case .terminal: return "Terminal"
        case .iterm: return "iTerm"
        }
    }
    var installed: Bool {
        switch self {
        case .auto, .terminal: return true
        case .claude: return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") != nil
        case .iterm: return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil
        }
    }
    static var current: OpenIn {
        get { OpenIn(rawValue: UserDefaults.standard.string(forKey: "openIn") ?? "") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "openIn") }
    }
}

enum Opener {
    static let uuid = try! NSRegularExpression(pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
    static let desktopStore = fmHome.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")

    /// The Claude app keeps one record per Code-tab session, naming the log it
    /// writes. Read fresh on each click: it is a few hundred small files.
    static func desktopId(for cliId: String) -> String? {
        guard let accounts = try? fm.contentsOfDirectory(at: desktopStore, includingPropertiesForKeys: nil) else { return nil }
        for a in accounts {
            for org in (try? fm.contentsOfDirectory(at: a, includingPropertiesForKeys: nil)) ?? [] {
                for f in (try? fm.contentsOfDirectory(at: org, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "json" {
                    guard let data = try? Data(contentsOf: f),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          obj["cliSessionId"] as? String == cliId,
                          let local = obj["sessionId"] as? String else { continue }
                    return local
                }
            }
        }
        return nil
    }

    static func open(_ s: Session) {
        let id = s.id
        guard uuid.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil else { return }
        var target = OpenIn.current
        if !target.installed { target = .auto }
        let local = desktopId(for: id)
        if target == .auto { target = (local != nil && OpenIn.claude.installed) ? .claude : .terminal }
        switch target {
        case .claude:
            // A Code-tab session opens as itself; a terminal session is imported.
            let link = local.map { "claude://code/continue?session=\($0)" } ?? "claude://resume?session=\(id)"
            if let url = URL(string: link) { NSWorkspace.shared.open(url) }
        case .terminal, .iterm:
            let dir = s.cwd.isEmpty ? NSHomeDirectory() : s.cwd
            let quoted = "'" + dir.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let cmd = "cd \(quoted) && claude --resume \(id)"
            let esc = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let script = target == .iterm
                ? "tell application \"iTerm\"\nactivate\nset w to (create window with default profile)\ntell current session of w to write text \"\(esc)\"\nend tell"
                : "tell application \"Terminal\"\nactivate\ndo script \"\(esc)\"\nend tell"
            var err: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&err)
        case .auto:
            break
        }
    }
}

// MARK: - Formatting

func short(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    return "\(Int((Double(n) / 1000).rounded()))k"
}

func colour(for context: Int) -> NSColor {
    if context >= redAt { return .systemRed }
    if context >= amberAt { return .systemOrange }
    return .systemGreen
}

/// COLOUR IS SIGNAL, NOT DECORATION. Coloured text is hard to read on some
/// wallpapers, and a different hue would not fix it. A menu bar sits on
/// whatever wallpaper is behind it and switches between a light and a dark
/// appearance, so ANY fixed hue is a gamble on thin text. `labelColor` is the
/// one colour macOS guarantees against that, because the system flips it with
/// the bar.
///
/// So the healthy state now carries no tint at all: it is ordinary, legible
/// label text. Colour appears only when something is actually wrong, which
/// makes it mean something when it does. Amber and red are far heavier than
/// green and stay readable in both appearances.
func usageColour(_ pct: Int?) -> NSColor {
    // Text always stays in the system label colour: the dot carries the state.
    return pct == nil ? .secondaryLabelColor : .labelColor
}

/// A MINI GAUGE, drawn rather than typed, for the dropdown. A dot said which state a
/// window was in; a gauge also says how far through it you are, which is the
/// thing you actually glance up for. The track follows the menu bar's own
/// appearance, the fill is a solid state colour, so it reads on any wallpaper.
func gauge(_ pct: Int?, width w: CGFloat = 36) -> NSAttributedString {
    let h: CGFloat = 8
    let fill = CGFloat(min(100, max(0, pct ?? 0))) / 100
    let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
        let track = NSBezierPath(roundedRect: rect, xRadius: h / 2, yRadius: h / 2)
        NSColor.labelColor.withAlphaComponent(0.3).setFill()
        track.fill()
        if fill > 0 {
            // Never thinner than a dot, so 1% still shows that something is there.
            let fw = max(h, rect.width * fill)
            let bar = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: fw, height: h), xRadius: h / 2, yRadius: h / 2)
            usageDot(pct).setFill()
            bar.fill()
        }
        return true
    }
    let att = NSTextAttachment()
    att.image = img
    att.bounds = NSRect(x: 0, y: 0.5, width: w, height: h)
    return NSAttributedString(attachment: att)
}

/// The dot beside a figure. A solid disc survives any background that thin
/// glyphs do not, so the state still reads at a glance while the text stays
/// in the system's own colour.
func usageDot(_ pct: Int?) -> NSColor {
    // Yellow at 50%, orange at 70%, red at 85%.
    guard let pct else { return .tertiaryLabelColor }
    if pct >= 85 { return .systemRed }
    if pct >= 70 { return .systemOrange }
    if pct >= 50 { return .systemYellow }
    return .systemGreen
}

/// "1h 40m", "18m": how long until it lifts.
func until(_ date: Date?) -> String {
    guard let date else { return "–" }
    let secs = Int(date.timeIntervalSinceNow)
    if secs <= 0 { return "now" }
    let h = secs / 3600, m = (secs % 3600) / 60
    if h >= 24 { return "\(h / 24)d \(h % 24)h" }
    return h > 0 ? "\(h)h \(m)m" : "\(m)m"
}

func ago(_ date: Date) -> String {
    let mins = Int(Date().timeIntervalSince(date) / 60)
    if mins < 1 { return "now" }
    if mins < 60 { return "\(mins)m ago" }
    return "\(mins / 60)h ago"
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    lazy var item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var sessions: [String: Session] = [:]
    let usage = Usage()
    let api = ClaudeAPI()

    /// What the two percentages in the bar are actually measured against.
    enum Source { case live, estimate }
    var source: Source { api.live != nil ? .live : .estimate }
    var sessionPct: Int? { api.live.map(\.sessionPct) ?? usage.blockPct }
    var weeklyPct: Int? { api.live.map(\.weeklyPct) ?? usage.weekPct }
    var sessionResets: Date? { api.live?.sessionResets ?? usage.blockEnds }
    var weeklyResets: Date? { api.live?.weeklyResets ?? usage.weekEnds }

    func applicationDidFinishLaunching(_ note: Notification) {
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refresh()
        Timer.scheduledTimer(withTimeInterval: pollSeconds, repeats: true) { [weak self] _ in self?.refresh() }
        // The plan figures move far more slowly than a window does, and the
        // first scan reads a fortnight of logs, so they get their own slower
        // timer on a background queue rather than riding the 5-second one.
        usage.refresh { [weak self] in self?.refresh() }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.usage.refresh { self?.refresh() }
        }
        // The live figures come off the network, so they get their own timer
        // and their own queue. A minute is plenty: these move in percent, not
        // in tokens, and claude.ai does not need pestering.
        pollLive()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.pollLive() }
    }

    func liveSessions() -> [Session] {
        let cutoff = Date().addingTimeInterval(-liveWindowHours * 3600)
        let dirs = (try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil)) ?? []
        var live: [Session] = []
        for dir in dirs {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                let mod = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                guard mod > cutoff else { continue }
                let s = sessions[file.path] ?? Session(url: file)
                sessions[file.path] = s
                s.update()
                if s.steps > 0 { live.append(s) }
            }
        }
        // Forget windows that have gone quiet so memory stays flat.
        sessions = sessions.filter { $0.value.modified > cutoff }
        return live.sorted { $0.modified > $1.modified }
    }

    /// THE BAR. Context size first, because that is the thing you can act on
    /// this minute, then the
    /// two plan windows. Each carries its own colour, so the bar answers
    /// "am I about to run out" without opening anything.
    func refresh() {
        guard let button = item.button else { return }
        let live = liveSessions()
        let title = NSMutableAttributedString()
        if let current = live.first {
            title.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: colour(for: current.context)]))
            title.append(NSAttributedString(string: short(current.context)))
        } else {
            title.append(NSAttributedString(string: "○ idle", attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
        }
        // COMPACT FOR THE NOTCH: on a notched MacBook, menu bar items that do not
        // fit are hidden. Dots in the bar, gauges only on click.
        func window(_ label: String, _ pct: Int?) {
            title.append(NSAttributedString(string: "  |  ", attributes: [.foregroundColor: NSColor.tertiaryLabelColor]))
            title.append(NSAttributedString(string: "\(label) ", attributes: [.foregroundColor: NSColor.labelColor]))
            title.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: usageDot(pct)]))
            title.append(NSAttributedString(string: pct.map { "\($0)%" } ?? "–", attributes: [.foregroundColor: NSColor.labelColor]))
        }
        if usage.hasHistory || api.live != nil {
            window("5h", sessionPct)
            window("wk", weeklyPct)
            if source == .estimate {
                title.append(NSAttributedString(string: " ~", attributes: [.foregroundColor: NSColor.tertiaryLabelColor]))
            }
        }
        button.attributedTitle = title
    }

    func pollLive() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.api.refresh()
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // THE TWO PLAN WINDOWS, with what you actually want to know beside
        // each: how much is gone and when it lifts.
        if usage.hasHistory || api.live != nil {
            let planHeader = NSMenuItem(title: "Plan usage", action: nil, keyEquivalent: "")
            planHeader.isEnabled = false
            menu.addItem(planHeader)
            addWindowRow(menu, "5-hour session", sessionPct, until(sessionResets))
            addWindowRow(menu, "7 days, all models", weeklyPct, until(weeklyResets))
            for m in api.live?.scoped ?? [] {
                addWindowRow(menu, "7 days, \(m.name)", m.pct, until(m.resets))
            }
            addFootnote(menu)
            menu.addItem(.separator())
        }

        let live = Array(liveSessions().prefix(maxListed))
        let header = NSMenuItem(title: live.isEmpty ? "No windows active in the last \(Int(liveWindowHours)) hours" : "Live windows", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for s in live {
            let row = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: colour(for: s.context)])
            row.append(NSAttributedString(string: "\(short(s.context))   \(s.name)\n", attributes: [.font: NSFont.menuFont(ofSize: 0)]))
            row.append(NSAttributedString(
                string: "     \(s.project) · \(s.steps) steps · \(short(s.reread)) re-read · \(ago(s.modified))",
                attributes: [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
            let mi = NSMenuItem(title: s.name, action: #selector(openSession(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = s
            mi.attributedTitle = row
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let openIn = NSMenuItem(title: "Open windows in", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for choice in OpenIn.allCases where choice.installed {
            let c = NSMenuItem(title: choice.title, action: #selector(pickOpenIn(_:)), keyEquivalent: "")
            c.target = self
            c.representedObject = choice.rawValue
            c.state = OpenIn.current == choice ? .on : .off
            sub.addItem(c)
        }
        openIn.submenu = sub
        menu.addItem(openIn)
        let keyItem = NSMenuItem(title: api.hasKey ? "Update Claude key…" : "Add Claude key…", action: #selector(askForKey), keyEquivalent: "")
        keyItem.target = self
        menu.addItem(keyItem)
        menu.addItem(NSMenuItem(title: "Quit ContextMeter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// Says, in the place you are already looking, which of the two answers you
    /// is reading and what to do if it is the weaker one. ClaudeMeter's whole
    /// failure was a screen that looked fine while being wrong.
    /// Only speaks when something is wrong: colour explains the rest. A dead key is the one thing colour cannot say.
    private func addFootnote(_ menu: NSMenu) {
        guard let err = api.lastError else { return }
        let note = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        note.isEnabled = false
        note.attributedTitle = NSAttributedString(
            string: "  \(err)",
            attributes: [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.systemOrange])
        menu.addItem(note)
    }

    private func addWindowRow(_ menu: NSMenu, _ label: String, _ pct: Int?, _ left: String) {
        let row = NSMutableAttributedString(string: "\(label)\n", attributes: [.font: NSFont.menuFont(ofSize: 0)])
        row.append(gauge(pct, width: 150))
        row.append(NSAttributedString(
            string: "  \(pct.map { "\($0)%" } ?? "–")   resets in \(left)",
            attributes: [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        let mi = NSMenuItem(title: label, action: #selector(noop), keyEquivalent: "")
        mi.target = self
        mi.attributedTitle = row
        menu.addItem(mi)
    }

    /// ADD THE KEY WITHOUT A TERMINAL. A secure field, so the key never shows
    /// on screen, straight into the Keychain. "Open claude.ai" takes you to the
    /// page the key comes from.
    @objc func askForKey() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Claude key"
        alert.informativeText = "claude.ai › Developer tools › Application › Cookies › sessionKey"
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-ant-sid…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open claude.ai")
        alert.window.initialFirstResponder = field
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            ClaudeAPI.writeKey(key)
            api.keyChanged()
            pollLive()
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(URL(string: "https://claude.ai")!)
        default:
            break
        }
    }

    @objc func openSession(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? Session { Opener.open(s) }
    }

    @objc func pickOpenIn(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let c = OpenIn(rawValue: raw) { OpenIn.current = c }
    }

    @objc func noop() {}
}

// `ContextMeter --resolve <session-id>` says where a click would open it (for testing).
if let i = CommandLine.arguments.firstIndex(of: "--resolve"), i + 1 < CommandLine.arguments.count {
    let id = CommandLine.arguments[i + 1]
    let local = Opener.desktopId(for: id)
    print("preference: \(OpenIn.current.title)")
    print(local.map { "Claude app record: \($0) -> claude://code/continue?session=\($0)" } ?? "no Claude app record -> Terminal: claude --resume \(id)")
    exit(0)
}

// `ContextMeter --windows` lists every usage window claude.ai reports, by key.
if CommandLine.arguments.contains("--windows") {
    let api = ClaudeAPI(); api.refresh()
    if let e = api.lastError { print(e) }
    if CommandLine.arguments.contains("--raw"),
       let d = try? JSONSerialization.data(withJSONObject: api.rawBody, options: [.prettyPrinted, .sortedKeys]),
       let t = String(data: d, encoding: .utf8) { print(t); exit(0) }
    for (k, v) in api.windows.sorted(by: { $0.key < $1.key }) {
        print("\(k)\t\(v.pct)%\tresets \(v.resets.map { "\($0)" } ?? "–")")
    }
    exit(0)
}

// `ContextMeter --setkey` stores a claude.ai session key in the Keychain.
//
// A PROMPT, NOT AN ARGUMENT. Passing a credential on the command line writes it
// into the shell history and into every process listing on the machine; typing
// it at a prompt does neither. The value is pasted by you,
// it goes straight to the Keychain, and nothing echoes it back.
if CommandLine.arguments.contains("--setkey") {
    print("Paste your claude.ai session key (sessionKey cookie), or blank to remove it.")
    print("Safari or Chrome: claude.ai, Developer tools, Application, Cookies, sessionKey.")
    print("key: ", terminator: "")
    let entered = (readLine() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if entered.isEmpty {
        ClaudeAPI.writeKey("")
        print("Removed. ContextMeter falls back to the local estimate.")
        exit(0)
    }
    guard ClaudeAPI.writeKey(entered) else { print("Could not write to the Keychain."); exit(1) }
    let api = ClaudeAPI()
    api.refresh()
    if let live = api.live {
        print("Stored and working: 5-hour \(live.sessionPct)%, 7 days \(live.weeklyPct)%.")
        print("Restart ContextMeter, or wait a minute for it to pick it up.")
    } else {
        print("Stored, but claude.ai did not answer: \(api.lastError ?? "no reason given")")
        print("The bar keeps showing the local estimate until the key works.")
    }
    exit(0)
}

// `ContextMeter --print` lists live windows as text and exits (for testing).
if CommandLine.arguments.contains("--print") {
    let app = AppDelegate()
    let waiter = DispatchSemaphore(value: 0)
    app.usage.refresh { waiter.signal() }
    // The scan runs on its own queue and calls back on the main one, which is
    // not running yet in this mode, so pump it until the callback lands.
    while waiter.wait(timeout: .now() + 0.05) == .timedOut {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    app.api.refresh()
    let u = app.usage
    print(app.source == .live
          ? "source: claude.ai (accurate)"
          : "source: local estimate\(app.api.lastError.map { " (" + $0 + ")" } ?? "") · add a key with --setkey")
    func line(_ label: String, _ pct: Int?, _ spent: Double, _ ceiling: Double, _ ends: Date?) {
        let p = pct.map { "\($0)%" } ?? "no reference yet"
        let ref = app.source == .live ? "" : "\t\(short(Int(spent))) of about \(short(Int(ceiling)))"
        print("\(label)\t\(p)\(ref)\tresets in \(until(ends))")
    }
    line("5-hour", app.sessionPct, u.blockSpend, u.blockCeiling, app.sessionResets)
    line("7 days", app.weeklyPct, u.weekSpend, u.weekCeiling, app.weeklyResets)
    for m in app.api.live?.scoped ?? [] { print("7d \(m.name)\t\(m.pct)%\tresets in \(until(m.resets))") }
    print("")
    for s in app.liveSessions().prefix(maxListed) {
        print("\(short(s.context))\t\(s.steps) steps\t\(short(s.reread)) re-read\t\(s.project)\t\(s.name)")
    }
    exit(0)
}

let app = NSApplication.shared
// AN EDIT MENU, SO CMD+V WORKS IN THE KEY DIALOG. A menu bar app has no menu bar of
// its own, and on macOS the paste shortcut only reaches a text field through
// an Edit menu's Paste item. It is never shown; it only carries the shortcuts.
let mainMenu = NSMenu()
let editHolder = NSMenuItem()
let edit = NSMenu(title: "Edit")
edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editHolder.submenu = edit
mainMenu.addItem(editHolder)
app.mainMenu = mainMenu
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
