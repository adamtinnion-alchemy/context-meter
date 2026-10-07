import Cocoa

// ContextMeter
// Menu bar meter for how big each live Claude Code window has grown.
//
// Reads the local session logs in ~/.claude/projects/*/*.jsonl, so it works
// whichever Claude account is signed in. Every step in a window re-reads the
// whole context, so the bigger a window gets, the more each step costs.
//
// The menu bar shows the window you touched most recently. The dropdown lists
// every window active in the last 36 hours (adjustable), newest first, in a
// box that scrolls, topped up to ten with older ones when there are fewer.
// Pinned windows stay at the top however old they get.

// MARK: - Settings

let fm = FileManager.default
let fmHome = fm.homeDirectoryForCurrentUser

let amberAt = 150_000
let redAt = 250_000
/// The bar goes idle when nothing has been touched for this long.
let liveWindowHours = 3.0
/// The list never shows fewer than this, if that many windows exist at all.
let minListed = 10
/// How many older logs the top-up may open looking for them.
let topUpLimit = 60
let listHourChoices: [(hours: Double, title: String)] = [
    (12, "12 hours"), (24, "24 hours"), (36, "36 hours"), (72, "3 days"), (168, "7 days"),
]
var listHours: Double {
    get { let h = UserDefaults.standard.double(forKey: "listHours"); return h > 0 ? h : 36 }
    set { UserDefaults.standard.set(newValue, forKey: "listHours") }
}
let pollSeconds = 5.0

// MARK: - Plan usage settings
//
// THREE SOURCES. With a claude.ai session key (menu: Add Claude key…) the bar
// shows claude.ai's own figures. Without one, or when the key expires, it asks
// the account's own `claude` program (`claude -p /usage`), which is just as
// exact. Only if both fail does it fall back to an estimate from the local
// Claude Code logs, so it never goes blank, and marks that with a trailing `~`.
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
/// When an account's weekly window resets. Learned from claude.ai the first
/// time its key works and remembered, so the estimate lines up with the real
/// week even after the key expires. Before that, weeks are counted from a
/// fixed epoch.
func weekAnchor(_ account: String) -> Date {
    let t = UserDefaults.standard.double(forKey: anchorKey(account))
    return t > 0 ? Date(timeIntervalSince1970: t) : Date(timeIntervalSince1970: 0)
}
func anchorKey(_ account: String) -> String { account == Account.main ? "weekAnchor" : "weekAnchor.\(account)" }

let usageCache = fmHome.appendingPathComponent(".claude/context-meter-usage.json")
let usageConfig = fmHome.appendingPathComponent(".claude/context-meter-config.json")
/// The bar's latest claude.ai figures, percentages only, never a key. Other
/// tools (`--json`, Switchboard) read this instead of the Keychain, so only
/// the menu bar app ever asks the Keychain for anything.
let liveCache = fmHome.appendingPathComponent(".claude/context-meter-live.json")

// MARK: - Accounts
//
// TWO CLAUDE ACCOUNTS ON ONE MAC. Claude Code keeps one login per config
// folder: `~/.claude` by default, and any other folder you point
// CLAUDE_CONFIG_DIR at (for example `~/.claude-work`). Every `~/.claude-*`
// folder holding a `.claude.json` is treated as a second account.
//
// The folders may share one `projects` folder through a symlink, so a log's
// location cannot say whose it is. Each folder's `session-env` holds a
// directory per session it ran, and that is what assigns a log to an account.

struct Account {
    /// The Keychain account name, and the key for everything stored per account.
    /// `default` for `~/.claude`, which is what a single-account install always used.
    static let main = "default"
    let id: String
    let dir: URL
    var isMain: Bool { id == Account.main }

    var name: String {
        get {
            let names = UserDefaults.standard.dictionary(forKey: "accountNames") as? [String: String] ?? [:]
            if let n = names[id], !n.isEmpty { return n }
            if isMain { return "Main" }
            let suffix = dir.lastPathComponent.replacingOccurrences(of: ".claude-", with: "")
            return suffix.prefix(1).uppercased() + suffix.dropFirst()
        }
        nonmutating set {
            var names = UserDefaults.standard.dictionary(forKey: "accountNames") as? [String: String] ?? [:]
            names[id] = newValue
            UserDefaults.standard.set(names, forKey: "accountNames")
        }
    }

    /// Set on a terminal command so a resumed window stays on its own account.
    var envPrefix: String {
        isMain ? "" : "CLAUDE_CONFIG_DIR='" + dir.path.replacingOccurrences(of: "'", with: "'\\''") + "' "
    }

    static func discover() -> [Account] {
        var found = [Account(id: main, dir: fmHome.appendingPathComponent(".claude"))]
        let home = (try? fm.contentsOfDirectory(at: fmHome, includingPropertiesForKeys: nil, options: [])) ?? []
        for dir in home.sorted(by: { $0.path < $1.path }) where dir.lastPathComponent.hasPrefix(".claude-") {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue,
                  fm.fileExists(atPath: dir.appendingPathComponent(".claude.json").path) else { continue }
            found.append(Account(id: dir.lastPathComponent, dir: dir))
        }
        return found
    }

    /// Every log folder, each real folder once however many accounts link to it.
    static func projectDirs(_ accounts: [Account]) -> [URL] {
        var seen = Set<String>(), out: [URL] = []
        for a in accounts {
            let p = a.dir.appendingPathComponent("projects")
            let real = p.resolvingSymlinksInPath().path
            if fm.fileExists(atPath: real), seen.insert(real).inserted { out.append(p) }
        }
        return out
    }

    /// Session id to account id, for every session a second account ran.
    /// Anything not listed belongs to the main account.
    static func owners(_ accounts: [Account]) -> [String: String] {
        var map: [String: String] = [:]
        for a in accounts where !a.isMain {
            for s in (try? fm.contentsOfDirectory(atPath: a.dir.appendingPathComponent("session-env").path)) ?? [] {
                map[s] = a.id
            }
            // A log kept in the account's own, unshared projects folder is its own too.
            let own = a.dir.appendingPathComponent("projects")
            if (try? own.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true {
                for d in (try? fm.contentsOfDirectory(at: own, includingPropertiesForKeys: nil)) ?? [] {
                    for f in (try? fm.contentsOfDirectory(atPath: d.path)) ?? [] where f.hasSuffix(".jsonl") {
                        map[String(f.dropLast(6))] = a.id
                    }
                }
            }
        }
        return map
    }
}

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
        if !lastPrompt.isEmpty { return String(lastPrompt.prefix(80)) }
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

// MARK: - Which windows are listed

/// A window as the menu shows it: a value copied off the scan queue, so the
/// main thread never reads a Session mid-parse.
struct Window {
    let id: String
    let name: String
    let project: String
    let cwd: String
    let context: Int
    let steps: Int
    let reread: Int
    let modified: Date
    var pinned: Bool
    /// Which account ran it.
    let account: String
}

enum Pins {
    static var all: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "pinned") ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: "pinned") }
    }
    static func toggle(_ id: String) {
        var p = all
        if p.remove(id) == nil { p.insert(id) }
        all = p
    }
}

/// Pinned first, then newest first.
func listOrder(_ a: Window, _ b: Window) -> Bool {
    if a.pinned != b.pinned { return a.pinned }
    return a.modified > b.modified
}

/// Reads the logs on its own queue. A day and a half of windows is tens of
/// megabytes on first launch, which would freeze the bar if parsed on the
/// main thread. After that each pass only reads what was appended.
final class Scanner {
    private let queue = DispatchQueue(label: "contextmeter.windows", qos: .utility)
    private var sessions: [String: Session] = [:]
    private var busy = false

    func refresh(_ accounts: [Account], done: @escaping ([Window]) -> Void) {
        guard !busy else { return }
        busy = true
        queue.async {
            let found = self.scan(accounts)
            DispatchQueue.main.async { self.busy = false; done(found) }
        }
    }

    func scan(_ accounts: [Account]) -> [Window] {
        let cutoff = Date().addingTimeInterval(-listHours * 3600)
        let pins = Pins.all
        let owners = accounts.count > 1 ? Account.owners(accounts) : [:]
        var files: [(url: URL, mod: Date)] = []
        for dir in Account.projectDirs(accounts).flatMap({ (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }) {
            let inside = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in inside where file.pathExtension == "jsonl" {
                let mod = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                files.append((file, mod))
            }
        }
        files.sort { $0.mod > $1.mod }
        var kept: [String: Session] = [:]
        var found: [Window] = []
        var listed = 0, olderOpened = 0
        for f in files {
            let id = f.url.deletingPathExtension().lastPathComponent
            let pinned = pins.contains(id)
            // Past the cutoff a window is only there to top the list up to ten.
            if !pinned && f.mod <= cutoff {
                if listed >= minListed || olderOpened >= topUpLimit { continue }
                olderOpened += 1
            }
            let s = sessions[f.url.path] ?? Session(url: f.url)
            kept[f.url.path] = s
            s.update()
            guard s.steps > 0 else { continue }
            if !pinned { listed += 1 }
            found.append(Window(id: id, name: s.name, project: s.project, cwd: s.cwd, context: s.context,
                                steps: s.steps, reread: s.reread, modified: s.modified, pinned: pinned,
                                account: owners[id] ?? Account.main))
        }
        // Forget windows that have dropped off so memory stays flat.
        sessions = kept
        return found.sorted(by: listOrder)
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
    /// Whose key: the Keychain account name, one per Claude account.
    let account: String
    /// The account's Claude Code config folder, nil for `~/.claude`.
    let configDir: URL?
    init(account: String = Account.main, configDir: URL? = nil) { self.account = account; self.configDir = configDir }
    private(set) var live: LiveUsage?
    private(set) var lastError: String?
    /// Every window claude.ai returned, by its own key, for rows beyond the two.
    private(set) var windows: [String: (pct: Int, resets: Date?)] = [:]
    private(set) var rawBody: [String: Any] = [:]
    private var org: String?

    /// Remembered from the last refresh, never read on the main thread: after
    /// an update the Keychain stops to ask about the new signature, and a menu
    /// that waits on that question cannot open.
    private(set) var hasKey = false
    /// Read from the Keychain once per launch, not once a minute: each read
    /// is a chance for macOS to ask for the password again.
    private var cachedKey: String?
    private var lastCLI: Date?
    /// Whether the figures on show came from the `claude` program rather than claude.ai.
    private(set) var fromCLI = false

    // MARK: Keychain

    static func readKey(_ account: String = Account.main) -> String? {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
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
    static func writeKey(_ key: String, account: String = Account.main) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
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
    func keyChanged() { org = nil; live = nil; lastError = nil; hasKey = true; cachedKey = nil }

    /// claude.ai first, where a key is stored and still works. Otherwise the
    /// account's own `claude` program, which needs no key and cannot go stale.
    func refresh() {
        let before = live?.fetched
        // `--cli` leaves claude.ai and the Keychain alone (for testing a fresh build).
        if !CommandLine.arguments.contains("--cli") { refreshFromKey() }
        if live?.fetched == before { refreshFromCLI() }
        // A figure nobody has confirmed for ten minutes is not shown as current.
        if let l = live, Date().timeIntervalSince(l.fetched) > 600 { live = nil }
    }

    private static let cliPath: String? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", home + "/.claude/local/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// `claude -p /usage` answers from the account's own login without a model
    /// call, so it costs nothing. Run with no settings and no saved session, so
    /// no hooks fire and no window appears in the list.
    private func refreshFromCLI() {
        if let at = lastCLI, Date().timeIntervalSince(at) < 170 { return }
        guard let bin = Self.cliPath else { return }
        lastCLI = Date()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["-p", "/usage", "--output-format", "json", "--no-session-persistence",
                       "--strict-mcp-config", "--setting-sources", ""]
        var env = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "USER": NSUserName(),
                   "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"]
        if let configDir { env["CLAUDE_CONFIG_DIR"] = configDir.path }
        p.environment = env
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 40) { if p.isRunning { p.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = j["result"] as? String, let usage = Self.parseUsage(text) else { return }
        if let wk = usage.weeklyResets {
            UserDefaults.standard.set(wk.addingTimeInterval(-7 * 24 * 3600).timeIntervalSince1970, forKey: anchorKey(account))
        }
        live = usage
        fromCLI = true
        lastError = nil
    }

    /// Lines such as `Current week (all models): 35% used · resets Oct 10 at 6pm (Europe/London)`.
    static func parseUsage(_ text: String, now: Date = Date()) -> LiveUsage? {
        let line = try! NSRegularExpression(pattern: #"^Current (session|week)(?: \(([^)]+)\))?: (\d+)% used(?: · resets (.+?)(?: \(([^)]+)\))?)?\s*$"#, options: [.anchorsMatchLines])
        var session: (Int, Date?)?
        var week: (Int, Date?)?
        var scoped: [(name: String, pct: Int, resets: Date?)] = []
        let ns = text as NSString
        for m in line.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            func g(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
            guard let kind = g(1), let pct = g(3).flatMap({ Int($0) }) else { continue }
            let resets = g(4).flatMap { resetDate($0, zone: g(5), now: now) }
            if kind == "session" { session = (pct, resets) }
            else if let scope = g(2), scope != "all models" { scoped.append((scope, pct, resets)) }
            else { week = (pct, resets) }
        }
        guard let session, let week else { return nil }
        return LiveUsage(scoped: scoped, sessionPct: session.0, sessionResets: session.1,
                         weeklyPct: week.0, weeklyResets: week.1, fetched: now)
    }

    /// `Oct 10 at 6pm`, `Oct 7 at 1:30pm`, or a bare `6pm` for later today.
    static func resetDate(_ s: String, zone: String?, now: Date) -> Date? {
        let tz = zone.flatMap { TimeZone(identifier: $0) } ?? .current
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy MMM d"
        let today = f.string(from: now)
        let year = String(today.prefix(4))
        let clean = s.replacingOccurrences(of: "am", with: "AM").replacingOccurrences(of: "pm", with: "PM")
        for (prefix, format, dated) in [(year + " ", "MMM d 'at' h:mma", true), (year + " ", "MMM d 'at' ha", true),
                                        (today + " ", "h:mma", false), (today + " ", "ha", false)] {
            f.dateFormat = "yyyy " + (dated ? "" : "MMM d ") + format
            guard var d = f.date(from: prefix + clean) else { continue }
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = tz
            if dated, d < now.addingTimeInterval(-86400) { d = cal.date(byAdding: .year, value: 1, to: d) ?? d }
            if !dated, d < now { d = cal.date(byAdding: .day, value: 1, to: d) ?? d }
            return d
        }
        return nil
    }

    private func refreshFromKey() {
        guard let key = cachedKey ?? Self.readKey(account) else { hasKey = false; lastError = nil; return }
        cachedKey = key
        hasKey = true
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
            UserDefaults.standard.set(wk.addingTimeInterval(-7 * 24 * 3600).timeIntervalSince1970, forKey: anchorKey(account))
        }
        live = LiveUsage(scoped: scoped, sessionPct: session.0, sessionResets: session.1,
                         weeklyPct: weekly.0, weeklyResets: weekly.1, fetched: Date())
        fromCLI = false
    }
}

// MARK: - Plan usage, from the same local logs

/// One request's weighted spend, at the moment it happened, and on whose
/// account. `a` is nil for the main account, which is all a cache written
/// before accounts existed holds.
struct Spend: Codable { let at: Double; let cost: Double; var a: String? = nil }

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

    /// Ceilings learned from your own history, never published figures. Shared
    /// by every account: a new account has no completed weeks of its own yet,
    /// and the same person's worst week is the fairest reference it can have.
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
    func refresh(_ accounts: [Account], done: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.scan(accounts)
            DispatchQueue.main.async(execute: done)
        }
    }

    private func scan(_ accounts: [Account]) {
        let horizon = Date().addingTimeInterval(-15 * 24 * 3600)
        let owners = accounts.count > 1 ? Account.owners(accounts) : [:]
        for root in Account.projectDirs(accounts) {
            for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                for file in files where file.pathExtension == "jsonl" {
                    let mod = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    guard mod > horizon else { continue }
                    let owner = owners[file.deletingPathExtension().lastPathComponent]
                    read(file, owner: owner == Account.main ? nil : owner)
                }
            }
        }
        // A fortnight is plenty: the longest question asked of it is one week.
        let cutoff = horizon.timeIntervalSince1970
        spend.removeAll { $0.at < cutoff }
        if seen.count > 400_000 { seen.removeAll() }   // offsets still guard against double counting
        learnCeilings(accounts)
        save()
    }

    private func read(_ url: URL, owner: String?) {
        // Keyed by the real path, so a log reached through two linked
        // folders is still only counted once.
        let key = url.resolvingSymlinksInPath().path
        let start = offsets[key] ?? offsets[url.path] ?? 0
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return }
        if size < start { offsets[key] = 0; return }
        guard size > start, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), let lastNewline = data.lastIndex(of: 0x0A) else { return }
        let complete = data[data.startIndex...lastNewline]
        offsets[key] = start + UInt64(complete.count)
        for line in complete.split(separator: 0x0A) { parse(Data(line), owner: owner) }
    }

    private func parse(_ line: Data, owner: String?) {
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
        spend.append(Spend(at: at.timeIntervalSince1970, cost: cost, a: owner))
    }

    // MARK: Answering

    private func mine(_ account: String) -> [Spend] {
        spend.filter { ($0.a ?? Account.main) == account }
    }

    private func total(_ account: String, from: Date, to: Date = Date()) -> Double {
        let a = from.timeIntervalSince1970, b = to.timeIntervalSince1970
        return mine(account).reduce(0) { $0 + (($1.at >= a && $1.at < b) ? $1.cost : 0) }
    }

    /// The current 5-hour block starts at the first activity after the last
    /// gap of five hours or more, floored to the hour, which is how the window
    /// behaves in practice: it opens when you start, not on a wall clock.
    func blockStart(_ account: String) -> Date? {
        let sorted = mine(account).map(\.at).sorted()
        guard var cursor = sorted.last else { return nil }
        for t in sorted.reversed() {
            if cursor - t >= blockHours * 3600 { break }
            cursor = t
        }
        let floored = (cursor / 3600).rounded(.down) * 3600
        let start = Date(timeIntervalSince1970: floored)
        return Date().timeIntervalSince(start) < blockHours * 3600 ? start : nil
    }

    func blockSpend(_ account: String) -> Double { blockStart(account).map { total(account, from: $0) } ?? 0 }
    func blockEnds(_ account: String) -> Date? { blockStart(account).map { $0.addingTimeInterval(blockHours * 3600) } }

    /// The week runs seven days from the account's anchor, rolled forward to today.
    func weekStart(_ account: String) -> Date {
        var start = weekAnchor(account)
        let week = 7.0 * 24 * 3600
        if start > Date() { return start.addingTimeInterval(-week) }
        while start.addingTimeInterval(week) <= Date() { start = start.addingTimeInterval(week) }
        return start
    }
    func weekSpend(_ account: String) -> Double { total(account, from: weekStart(account)) }
    func weekEnds(_ account: String) -> Date { weekStart(account).addingTimeInterval(7 * 24 * 3600) }

    /// Every COMPLETED block and week in the fortnight, so the reference is
    /// your own worst case rather than a number somebody invented. A partial
    /// window in progress is never allowed to set the ceiling.
    private func learnCeilings(_ accounts: [Account]) {
        let week = 7.0 * 24 * 3600, block = blockHours * 3600
        var wk = 0.0, bl = 0.0
        for acct in accounts {
            var weeks: [Double: Double] = [:], blocks: [Double: Double] = [:]
            let anchor = weekAnchor(acct.id).timeIntervalSince1970
            for s in mine(acct.id) {
                weeks[((s.at - anchor) / week).rounded(.down), default: 0] += s.cost
                blocks[(s.at / block).rounded(.down), default: 0] += s.cost
            }
            let liveWeek = ((Date().timeIntervalSince1970 - anchor) / week).rounded(.down)
            let liveBlock = (Date().timeIntervalSince1970 / block).rounded(.down)
            wk = max(wk, weeks.filter { $0.key != liveWeek }.values.max() ?? 0)
            bl = max(bl, blocks.filter { $0.key != liveBlock }.values.max() ?? 0)
        }
        weekCeiling = wk
        blockCeiling = bl
    }

    func blockPct(_ account: String) -> Int? { blockCeiling > 0 ? Int((blockSpend(account) / blockCeiling * 100).rounded()) : nil }
    func weekPct(_ account: String) -> Int? { weekCeiling > 0 ? Int((weekSpend(account) / weekCeiling * 100).rounded()) : nil }
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

    static func open(_ s: Window, account: Account?) {
        let id = s.id
        guard uuid.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil else { return }
        var target = OpenIn.current
        if !target.installed { target = .auto }
        let local = desktopId(for: id)
        // The Claude app only knows its own login, so another account's window
        // always resumes in a terminal, on that account.
        let elsewhere = account.map { !$0.isMain } ?? false
        if target == .auto || (target == .claude && elsewhere) {
            target = (local != nil && !elsewhere && OpenIn.claude.installed) ? .claude : .terminal
        }
        switch target {
        case .claude:
            // A Code-tab session opens as itself; a terminal session is imported.
            let link = local.map { "claude://code/continue?session=\($0)" } ?? "claude://resume?session=\(id)"
            if let url = URL(string: link) { NSWorkspace.shared.open(url) }
        case .terminal, .iterm:
            let dir = s.cwd.isEmpty ? NSHomeDirectory() : s.cwd
            let quoted = "'" + dir.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let cmd = "cd \(quoted) && \(account?.envPrefix ?? "")claude --resume \(id)"
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
    if mins < 48 * 60 { return "\(mins / 60)h ago" }
    return "\(mins / 1440)d ago"
}

// MARK: - The window list
//
// A plain NSMenu cannot scroll a section of itself, so the windows live in one
// custom view: a scroll view of rows that highlight, open and pin themselves.

final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class WindowRow: NSView {
    static let height: CGFloat = 40
    /// Clicks this close to the right edge are the pin, not the row.
    static let pinZone: CGFloat = 44
    private(set) var entry: Window
    var onOpen: ((Window) -> Void)?
    var onPin: ((Window) -> Void)?
    var hovered = false { didSet { if hovered != oldValue { restyle() } } }
    private let highlight = NSVisualEffectView()
    private let dot = NSTextField(labelWithString: "●")
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let pin = NSImageView()
    /// The account's name, shown first in the detail line for a second account's window.
    private let accountTag: String?

    init(_ w: Window, width: CGFloat, tag: String?) {
        entry = w
        self.accountTag = tag
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: WindowRow.height))
        autoresizingMask = [.width]
        highlight.material = .selection
        highlight.state = .active
        highlight.isEmphasized = true
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 5
        dot.font = NSFont.menuFont(ofSize: 0)
        title.font = NSFont.menuFont(ofSize: 0)
        detail.font = NSFont.menuFont(ofSize: 11)
        for t in [title, detail] { t.lineBreakMode = .byTruncatingTail; t.maximumNumberOfLines = 1 }
        for v in [highlight, dot, title, detail, pin] as [NSView] { addSubview(v) }
        show(w)
        arrange()
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ w: Window) {
        entry = w
        dot.textColor = colour(for: w.context)
        title.stringValue = "\(short(w.context))   \(w.name)"
        detail.stringValue = (accountTag.map { "\($0) · " } ?? "") + "\(w.project) · \(w.steps) steps · \(short(w.reread)) re-read · \(ago(w.modified))"
        pin.image = NSImage(systemSymbolName: w.pinned ? "pin.fill" : "pin", accessibilityDescription: w.pinned ? "Unpin" : "Pin")
        toolTip = w.name
        restyle()
    }

    private func restyle() {
        highlight.isHidden = !hovered
        title.textColor = hovered ? .selectedMenuItemTextColor : .labelColor
        detail.textColor = hovered ? NSColor.selectedMenuItemTextColor.withAlphaComponent(0.8) : .secondaryLabelColor
        pin.isHidden = !(hovered || entry.pinned)
        pin.contentTintColor = hovered ? .selectedMenuItemTextColor : .secondaryLabelColor
    }

    private func arrange() {
        let w = bounds.width
        highlight.frame = NSRect(x: 5, y: 0, width: w - 10, height: WindowRow.height)
        dot.frame = NSRect(x: 14, y: 19, width: 16, height: 17)
        title.frame = NSRect(x: 31, y: 19, width: w - 31 - WindowRow.pinZone, height: 17)
        detail.frame = NSRect(x: 31, y: 4, width: w - 31 - WindowRow.pinZone, height: 14)
        pin.frame = NSRect(x: w - 32, y: 12, width: 16, height: 16)
    }

    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); arrange() }
    /// The labels would otherwise swallow the click.
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p) else { return }
        if p.x >= bounds.width - WindowRow.pinZone { onPin?(entry) } else { onOpen?(entry) }
    }
}

final class WindowList: NSView {
    static let width: CGFloat = 420
    var onOpen: ((Window) -> Void)?
    var onPin: ((Window) -> Void)?
    /// The account name for a row, or nil for the main account's.
    var accountTag: (Window) -> String? = { _ in nil }
    private let scroll = NSScrollView()
    private let doc = FlippedView()
    private var rows: [WindowRow] = []

    init(_ windows: [Window], visibleRows: Int, tag: @escaping (Window) -> String?) {
        self.accountTag = tag
        let h = CGFloat(min(windows.count, visibleRows)) * WindowRow.height
        super.init(frame: NSRect(x: 0, y: 0, width: WindowList.width, height: h))
        autoresizingMask = [.width]
        scroll.frame = bounds
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .none
        doc.autoresizingMask = [.width]
        scroll.documentView = doc
        addSubview(scroll)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        show(windows)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Same rows, new contents: the box must not change height while the menu is open.
    func show(_ windows: [Window]) {
        rows.forEach { $0.removeFromSuperview() }
        doc.frame = NSRect(x: 0, y: 0, width: bounds.width, height: CGFloat(windows.count) * WindowRow.height)
        rows = windows.enumerated().map { i, w in
            let r = WindowRow(w, width: bounds.width, tag: accountTag(w))
            r.frame.origin.y = CGFloat(i) * WindowRow.height
            r.onOpen = { [weak self] in self?.onOpen?($0) }
            r.onPin = { [weak self] in self?.onPin?($0) }
            doc.addSubview(r)
            return r
        }
        hover(window?.mouseLocationOutsideOfEventStream)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { scroll.flashScrollers() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hover(event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { hover(event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { hover(nil) }
    @objc private func scrolled() { hover(window?.mouseLocationOutsideOfEventStream) }

    /// One row is lit at a time, worked out here rather than per row so it
    /// stays right when the list scrolls under a still pointer.
    private func hover(_ inWindow: NSPoint?) {
        var p: NSPoint?
        if let q = inWindow, bounds.contains(convert(q, from: nil)) { p = doc.convert(q, from: nil) }
        for r in rows { r.hovered = p.map { r.frame.contains($0) } ?? false }
    }
}

// MARK: - App

/// One account's plan figures, from claude.ai when its key works and from the
/// local estimate otherwise.
struct Plan {
    let live: Bool
    let sessionPct: Int?
    let weeklyPct: Int?
    let sessionResets: Date?
    let weeklyResets: Date?
    let scoped: [(name: String, pct: Int, resets: Date?)]
    let error: String?
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    lazy var item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let scanner = Scanner()
    var windows: [Window] = []
    let usage = Usage()
    var accounts: [Account] = Account.discover()
    private var apis: [String: ClaudeAPI] = [:]
    var multi: Bool { accounts.count > 1 }

    override init() {
        super.init()
        syncAPIs()
    }

    func api(_ a: Account) -> ClaudeAPI { apis[a.id] ?? ClaudeAPI(account: a.id, configDir: a.isMain ? nil : a.dir) }

    /// A config folder made while the meter runs shows up within the minute.
    private func syncAPIs() {
        for a in accounts where apis[a.id] == nil { apis[a.id] = ClaudeAPI(account: a.id, configDir: a.isMain ? nil : a.dir) }
    }

    func plan(_ a: Account) -> Plan {
        let api = api(a)
        if let live = api.live {
            return Plan(live: true, sessionPct: live.sessionPct, weeklyPct: live.weeklyPct,
                        sessionResets: live.sessionResets, weeklyResets: live.weeklyResets,
                        scoped: live.scoped, error: nil)
        }
        return Plan(live: false, sessionPct: usage.blockPct(a.id), weeklyPct: usage.weekPct(a.id),
                    sessionResets: usage.blockEnds(a.id), weeklyResets: usage.weekEnds(a.id),
                    scoped: [], error: api.lastError)
    }

    var hasPlan: Bool { usage.hasHistory || accounts.contains { api($0).live != nil } }

    /// The letter each account goes by in the bar. Whole names if two letters clash.
    func barLabels() -> [String: String] {
        let initials = accounts.map { String($0.name.prefix(1)).uppercased() }
        let clash = Set(initials).count < initials.count
        return Dictionary(uniqueKeysWithValues: zip(accounts.map(\.id), clash ? accounts.map(\.name) : initials))
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refresh()
        rescan()
        Timer.scheduledTimer(withTimeInterval: pollSeconds, repeats: true) { [weak self] _ in self?.rescan() }
        // The plan figures move far more slowly than a window does, and the
        // first scan reads a fortnight of logs, so they get their own slower
        // timer on a background queue rather than riding the 5-second one.
        usage.refresh(accounts) { [weak self] in self?.refresh() }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.usage.refresh(self.accounts) { self.refresh() }
        }
        // The live figures come off the network, so they get their own timer
        // and their own queue. A minute is plenty: these move in percent, not
        // in tokens, and claude.ai does not need pestering.
        pollLive()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.pollLive() }
        // `ContextMeter --local --open` drops the menu by itself (for testing).
        if CommandLine.arguments.contains("--open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let menu = self?.item.menu, let screen = NSScreen.main?.visibleFrame else { return }
                NSApp.activate(ignoringOtherApps: true)
                menu.popUp(positioning: nil, at: NSPoint(x: screen.maxX - 520, y: screen.maxY - 10), in: nil)
            }
        }
    }

    func rescan() {
        scanner.refresh(accounts) { [weak self] found in
            self?.windows = found
            self?.refresh()
        }
    }

    /// The window the bar reports: the one touched most recently, if that was
    /// recent enough to still be work in progress.
    var current: Window? {
        guard let w = windows.max(by: { $0.modified < $1.modified }),
              w.modified > Date().addingTimeInterval(-liveWindowHours * 3600) else { return nil }
        return w
    }

    /// THE BAR. Context size first, because that is the thing you can act on
    /// this minute, then the
    /// two plan windows. Each carries its own colour, so the bar answers
    /// "am I about to run out" without opening anything.
    func refresh() {
        guard let button = item.button else { return }
        let title = NSMutableAttributedString()
        if let current {
            title.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: colour(for: current.context)]))
            title.append(NSAttributedString(string: short(current.context)))
        } else {
            title.append(NSAttributedString(string: "○ idle", attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
        }
        // COMPACT FOR THE NOTCH: on a notched MacBook, menu bar items that do not
        // fit are hidden. Dots in the bar, gauges only on click.
        func window(_ label: String, _ pct: Int?, labelColour: NSColor = .labelColor, lead: String = "  |  ") {
            title.append(NSAttributedString(string: lead, attributes: [.foregroundColor: NSColor.tertiaryLabelColor]))
            title.append(NSAttributedString(string: "\(label) ", attributes: [.foregroundColor: labelColour]))
            title.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: usageDot(pct)]))
            title.append(NSAttributedString(string: pct.map { "\($0)%" } ?? "–", attributes: [.foregroundColor: NSColor.labelColor]))
        }
        func estimated() {
            title.append(NSAttributedString(string: "~", attributes: [.foregroundColor: NSColor.tertiaryLabelColor]))
        }
        if hasPlan, multi {
            // TWO ACCOUNTS: only each one's 5-hour figure fits beside the notch.
            // The week is not dropped, it moves into the letter: the account's
            // letter turns orange at 70% of its week and red at 85%, so a week
            // running out still shows without opening anything.
            let labels = barLabels()
            for (i, a) in accounts.enumerated() {
                let p = plan(a)
                window(labels[a.id] ?? a.name, p.sessionPct, labelColour: weekLetter(p.weeklyPct), lead: i == 0 ? "  |  " : "   ")
                if !p.live { estimated() }
            }
        } else if hasPlan, let a = accounts.first {
            let p = plan(a)
            window("5h", p.sessionPct)
            window("wk", p.weeklyPct)
            if !p.live { title.append(NSAttributedString(string: " ")); estimated() }
        }
        button.attributedTitle = title
    }

    func pollLive() {
        if CommandLine.arguments.contains("--local") { return }
        accounts = Account.discover()
        syncAPIs()
        let all = accounts.map { api($0) }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            all.forEach { $0.refresh() }
            DispatchQueue.main.async { self?.writeLiveCache(); self?.refresh() }
        }
    }

    func writeLiveCache() {
        func stamp(_ d: Date?) -> Any { d.map { $0.timeIntervalSince1970 } ?? NSNull() }
        var out: [String: Any] = [:]
        for a in accounts {
            guard let l = api(a).live else { continue }
            out[a.id] = ["fiveHourPct": l.sessionPct, "fiveHourResets": stamp(l.sessionResets),
                         "weekPct": l.weeklyPct, "weekResets": stamp(l.weeklyResets),
                         "scoped": l.scoped.map { ["name": $0.name, "pct": $0.pct, "resets": stamp($0.resets)] },
                         "fetched": l.fetched.timeIntervalSince1970]
        }
        if let data = try? JSONSerialization.data(withJSONObject: out) { try? data.write(to: liveCache, options: .atomic) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // THE TWO PLAN WINDOWS, with what you actually want to know beside
        // each: how much is gone and when it lifts. One block per account.
        if hasPlan {
            for a in accounts {
                let p = plan(a)
                let planHeader = NSMenuItem(title: multi ? a.name : "Plan usage", action: nil, keyEquivalent: "")
                planHeader.isEnabled = false
                menu.addItem(planHeader)
                addWindowRow(menu, "5-hour session", p.sessionPct, until(p.sessionResets))
                addWindowRow(menu, "7 days, all models", p.weeklyPct, until(p.weeklyResets))
                for m in p.scoped {
                    addWindowRow(menu, "7 days, \(m.name)", m.pct, until(m.resets))
                }
                addFootnote(menu, p.error)
                menu.addItem(.separator())
            }
        }

        let header = NSMenuItem(title: windows.isEmpty ? "No windows yet" : "Windows", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if !windows.isEmpty {
            let names = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.name) })
            // Only the second account's windows are named: most rows are the
            // main account, and a name on every one of them is noise.
            let list = WindowList(windows, visibleRows: visibleRows()) { $0.account == Account.main ? nil : names[$0.account] }
            list.onOpen = { [weak self] w in
                menu.cancelTracking()
                let account = self?.accounts.first { $0.id == w.account }
                DispatchQueue.main.async { Opener.open(w, account: account) }
            }
            list.onPin = { [weak self, weak list] w in
                guard let self else { return }
                Pins.toggle(w.id)
                let pins = Pins.all
                self.windows = self.windows.map { var x = $0; x.pinned = pins.contains(x.id); return x }.sorted(by: listOrder)
                list?.show(self.windows)
            }
            let holder = NSMenuItem()
            holder.view = list
            menu.addItem(holder)
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
        let span = NSMenuItem(title: "Show windows from the last", action: nil, keyEquivalent: "")
        let spanMenu = NSMenu()
        for choice in listHourChoices {
            let c = NSMenuItem(title: choice.title, action: #selector(pickListHours(_:)), keyEquivalent: "")
            c.target = self
            c.representedObject = choice.hours
            c.state = listHours == choice.hours ? .on : .off
            spanMenu.addItem(c)
        }
        span.submenu = spanMenu
        menu.addItem(span)
        for a in accounts {
            let which = multi ? a.name : "Claude"
            let keyItem = NSMenuItem(title: api(a).hasKey ? "Update \(which) key…" : "Add \(which) key…", action: #selector(askForKey(_:)), keyEquivalent: "")
            keyItem.target = self
            keyItem.representedObject = a.id
            menu.addItem(keyItem)
        }
        menu.addItem(NSMenuItem(title: "Quit ContextMeter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// Says, in the place you are already looking, which of the two answers you
    /// is reading and what to do if it is the weaker one. ClaudeMeter's whole
    /// failure was a screen that looked fine while being wrong.
    /// Only speaks when something is wrong: colour explains the rest. A dead key is the one thing colour cannot say.
    private func addFootnote(_ menu: NSMenu, _ error: String?) {
        guard let err = error else { return }
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
    /// page the key comes from. With two accounts the same dialog also names
    /// the account, since the name is what the bar and the menu go by.
    @objc func askForKey(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let account = accounts.first(where: { $0.id == id }) else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = multi ? "\(account.name) key" : "Claude key"
        alert.informativeText = "claude.ai › Developer tools › Application › Cookies › sessionKey"
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-ant-sid…"
        let nameField = NSTextField(frame: NSRect(x: 0, y: 32, width: 320, height: 24))
        nameField.stringValue = account.name
        nameField.placeholderString = "Name"
        if multi {
            let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 56))
            box.addSubview(nameField)
            box.addSubview(field)
            alert.accessoryView = box
        } else {
            alert.accessoryView = field
        }
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open claude.ai")
        alert.window.initialFirstResponder = field
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if multi, !name.isEmpty, name != account.name { account.name = name; refresh() }
            let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            ClaudeAPI.writeKey(key, account: account.id)
            api(account).keyChanged()
            pollLive()
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(URL(string: "https://claude.ai")!)
        default:
            break
        }
    }

    /// Ten rows, fewer on a screen too short to hold them with the rest of the
    /// menu, which grows by a block for each extra account.
    private func visibleRows() -> Int {
        let screen = NSScreen.main?.visibleFrame.height ?? 900
        let plans = CGFloat(accounts.count - 1) * 160
        return max(4, min(minListed, Int((screen - 380 - plans) / WindowRow.height)))
    }

    @objc func pickListHours(_ sender: NSMenuItem) {
        if let h = sender.representedObject as? Double { listHours = h; rescan() }
    }

    @objc func pickOpenIn(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let c = OpenIn(rawValue: raw) { OpenIn.current = c }
    }

    @objc func noop() {}
}

/// An account's letter in the bar carries its week: plain until 70%, then
/// orange, then red at 85%, the same steps as the dots.
func weekLetter(_ pct: Int?) -> NSColor {
    guard let pct else { return .labelColor }
    if pct >= 85 { return .systemRed }
    if pct >= 70 { return .systemOrange }
    return .labelColor
}

/// The account a command line names: by its name, or by its folder
/// (`work` finds `~/.claude-work`). No name means the main account.
func pickAccount(after flag: String) -> Account? {
    let accounts = Account.discover()
    guard let i = CommandLine.arguments.firstIndex(of: flag), i + 1 < CommandLine.arguments.count,
          !CommandLine.arguments[i + 1].hasPrefix("--") else { return accounts.first }
    let want = CommandLine.arguments[i + 1].lowercased()
    return accounts.first {
        $0.name.lowercased() == want || $0.id.lowercased() == want
            || $0.dir.lastPathComponent.lowercased() == ".claude-\(want)"
            || ($0.isMain && ["main", "default", ".claude"].contains(want))
    }
}

// `ContextMeter --resolve <session-id>` says where a click would open it (for testing).
if let i = CommandLine.arguments.firstIndex(of: "--resolve"), i + 1 < CommandLine.arguments.count {
    let id = CommandLine.arguments[i + 1]
    let local = Opener.desktopId(for: id)
    let accounts = Account.discover()
    let owner = Account.owners(accounts)[id].flatMap { o in accounts.first { $0.id == o } }
    print("preference: \(OpenIn.current.title)")
    if let owner, !owner.isMain {
        print("account: \(owner.name) -> Terminal: \(owner.envPrefix)claude --resume \(id)")
        exit(0)
    }
    print(local.map { "Claude app record: \($0) -> claude://code/continue?session=\($0)" } ?? "no Claude app record -> Terminal: claude --resume \(id)")
    exit(0)
}

// `ContextMeter --windows [account]` lists every usage window claude.ai reports, by key.
if CommandLine.arguments.contains("--windows") {
    guard let account = pickAccount(after: "--windows") else { print("No such account."); exit(1) }
    let api = ClaudeAPI(account: account.id); api.refresh()
    if let e = api.lastError { print(e) }
    if CommandLine.arguments.contains("--raw"),
       let d = try? JSONSerialization.data(withJSONObject: api.rawBody, options: [.prettyPrinted, .sortedKeys]),
       let t = String(data: d, encoding: .utf8) { print(t); exit(0) }
    for (k, v) in api.windows.sorted(by: { $0.key < $1.key }) {
        print("\(k)\t\(v.pct)%\tresets \(v.resets.map { "\($0)" } ?? "–")")
    }
    exit(0)
}

// `ContextMeter --setkey [account]` stores a claude.ai session key in the Keychain.
//
// A PROMPT, NOT AN ARGUMENT. Passing a credential on the command line writes it
// into the shell history and into every process listing on the machine; typing
// it at a prompt does neither. The value is pasted by you,
// it goes straight to the Keychain, and nothing echoes it back.
if CommandLine.arguments.contains("--setkey") {
    guard let account = pickAccount(after: "--setkey") else {
        print("No such account. Accounts: " + Account.discover().map(\.name).joined(separator: ", "))
        exit(1)
    }
    print("Paste the claude.ai session key (sessionKey cookie) for \(account.name), or blank to remove it.")
    print("Safari or Chrome: claude.ai, Developer tools, Application, Cookies, sessionKey.")
    print("key: ", terminator: "")
    let entered = (readLine() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if entered.isEmpty {
        ClaudeAPI.writeKey("", account: account.id)
        print("Removed. ContextMeter falls back to the local estimate.")
        exit(0)
    }
    guard ClaudeAPI.writeKey(entered, account: account.id) else { print("Could not write to the Keychain."); exit(1) }
    let api = ClaudeAPI(account: account.id)
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
// `--json` is one JSON object for other local tools (Switchboard) to read:
// accounts with their plan figures (claude.ai's own, from the running bar's
// cache), then windows. `--json --local` keeps to the local estimate.
if CommandLine.arguments.contains("--json") {
    let app = AppDelegate()
    let waiter = DispatchSemaphore(value: 0)
    app.usage.refresh(app.accounts) { waiter.signal() }
    while waiter.wait(timeout: .now() + 0.05) == .timedOut {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    // The real figures, as the running menu bar app last fetched them from
    // claude.ai. Read from its cache file, never the Keychain, so this never
    // prompts. Older than ten minutes (bar not running) means the estimate.
    var cached: [String: [String: Any]] = [:]
    if !CommandLine.arguments.contains("--local"), let d = try? Data(contentsOf: liveCache),
       let j = try? JSONSerialization.jsonObject(with: d) as? [String: [String: Any]] {
        cached = j.filter { (($0.value["fetched"] as? Double) ?? 0) > Date().timeIntervalSince1970 - 600 }
    }
    func stamp(_ d: Date?) -> Any { d.map { $0.timeIntervalSince1970 } ?? NSNull() }
    let accounts: [[String: Any]] = app.accounts.map { a in
        if let c = cached[a.id] {
            return ["id": a.id, "name": a.name, "dir": a.dir.path, "main": a.isMain, "live": true,
                    "fiveHourPct": c["fiveHourPct"] ?? NSNull(), "fiveHourResets": c["fiveHourResets"] ?? NSNull(),
                    "weekPct": c["weekPct"] ?? NSNull(), "weekResets": c["weekResets"] ?? NSNull(),
                    "scoped": c["scoped"] ?? [], "error": NSNull()]
        }
        let p = app.plan(a)
        return ["id": a.id, "name": a.name, "dir": a.dir.path, "main": a.isMain, "live": p.live,
                "fiveHourPct": p.sessionPct.map { $0 as Any } ?? NSNull(), "fiveHourResets": stamp(p.sessionResets),
                "weekPct": p.weeklyPct.map { $0 as Any } ?? NSNull(), "weekResets": stamp(p.weeklyResets),
                "scoped": p.scoped.map { ["name": $0.name, "pct": $0.pct, "resets": stamp($0.resets)] },
                "error": p.error.map { $0 as Any } ?? NSNull()]
    }
    let windows: [[String: Any]] = app.scanner.scan(app.accounts).map { s in
        ["id": s.id, "name": s.name, "project": s.project, "cwd": s.cwd, "context": s.context,
         "steps": s.steps, "reread": s.reread, "modified": s.modified.timeIntervalSince1970,
         "pinned": s.pinned, "account": s.account]
    }
    let data = try! JSONSerialization.data(withJSONObject: ["accounts": accounts, "windows": windows])
    FileHandle.standardOutput.write(data)
    exit(0)
}

if CommandLine.arguments.contains("--print") {
    let app = AppDelegate()
    let waiter = DispatchSemaphore(value: 0)
    app.usage.refresh(app.accounts) { waiter.signal() }
    // The scan runs on its own queue and calls back on the main one, which is
    // not running yet in this mode, so pump it until the callback lands.
    while waiter.wait(timeout: .now() + 0.05) == .timedOut {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    // `--print --local` leaves claude.ai and the Keychain alone: a fresh build
    // has a new signature, and the Keychain stops to ask about it.
    if !CommandLine.arguments.contains("--local") { app.accounts.forEach { app.api($0).refresh() } }
    let u = app.usage
    for a in app.accounts {
        let p = app.plan(a)
        if app.multi { print("== \(a.name)  (\(a.dir.path))") }
        print(p.live
              ? "source: \(app.api(a).fromCLI ? "claude program" : "claude.ai") (accurate)"
              : "source: local estimate\(p.error.map { " (" + $0 + ")" } ?? "") · add a key with --setkey\(a.isMain ? "" : " " + a.name.lowercased())")
        func line(_ label: String, _ pct: Int?, _ spent: Double, _ ceiling: Double, _ ends: Date?) {
            let pc = pct.map { "\($0)%" } ?? "no reference yet"
            let ref = p.live ? "" : "\t\(short(Int(spent))) of about \(short(Int(ceiling)))"
            print("\(label)\t\(pc)\(ref)\tresets in \(until(ends))")
        }
        line("5-hour", p.sessionPct, u.blockSpend(a.id), u.blockCeiling, p.sessionResets)
        line("7 days", p.weeklyPct, u.weekSpend(a.id), u.weekCeiling, p.weeklyResets)
        for m in p.scoped { print("7d \(m.name)\t\(m.pct)%\tresets in \(until(m.resets))") }
        print("")
    }
    let names = Dictionary(uniqueKeysWithValues: app.accounts.map { ($0.id, $0.name) })
    for s in app.scanner.scan(app.accounts) {
        let who = app.multi ? "\(names[s.account] ?? s.account)\t" : ""
        print("\(s.pinned ? "pin" : "")\t\(who)\(short(s.context))\t\(s.steps) steps\t\(short(s.reread)) re-read\t\(ago(s.modified))\t\(s.project)\t\(s.name)")
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
