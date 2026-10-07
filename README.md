# ContextMeter

A macOS menu bar meter for Claude Code.

```
● 73k  |  5h ● 10%  |  wk ● 12%
```

- **73k** is the size of the Claude Code window you used most recently. Every
  step in a window re-reads the whole context, so a big window burns your plan
  faster. Green is fine, amber (150k) means finish the task, red (250k) means
  start a new window.
- **5h** and **wk** are your 5-hour session and 7-day plan usage. The dot turns
  yellow at 50%, orange at 70% and red at 85%.

Click it for progress bars, reset times, any model with its own weekly cap
(for example Fable), and your Claude Code windows. The list holds every window
used in the last 36 hours, ten rows tall, and scrolls for the rest. With fewer
than ten in that time it is topped up with older ones. **Show windows from the
last** changes the 36 hours (12 hours to 7 days). Hover a row and click the pin
to keep that window at the top for good; click it again to let it go.

Click a window to open
it: in the Claude app if it is a Claude app session, otherwise resumed in
Terminal with `claude --resume`. **Open windows in** sets a fixed choice:
Claude app, Terminal or iTerm (only the ones you have installed are listed).

## Two accounts

Claude Code keeps one login per config folder: `~/.claude`, plus any folder you
point `CLAUDE_CONFIG_DIR` at. ContextMeter picks up every `~/.claude-*` folder
with a `.claude.json` in it (for example `~/.claude-work`) as a second account.

```
● 146k  |  P ● 16%   W ● 0%
```

With two accounts the bar shows each account's 5-hour figure behind its
initial. An initial turns orange when that account has used 70% of its week
and red at 85%. Click for each account's full figures. Windows from the second
account are named in the list, and clicking one resumes it on that account.

Each account takes its own key: **Add Work key…** and so on. The same dialog
renames the account. From Terminal, `--setkey work` names the account by its
name or folder.

The folders may share one `projects` folder through a symlink. A window is
assigned to an account by the folder whose `session-env` holds its session.

## Install

Needs macOS 12 or later and the Xcode Command Line Tools
(`xcode-select --install` if `swiftc` is missing). No Xcode, no App Store.

```bash
git clone https://github.com/adamtinnion-alchemy/context-meter.git
cd context-meter
./install.sh
```

This builds the app, puts it in `~/Applications`, and starts it at login.

## Exact plan figures

The plan figures are exact with no setup: the meter asks each account's own
`claude` program (`claude -p /usage`, no model call, so it costs nothing) every
few minutes. Only if that fails does it show an estimate from your local logs,
marked with a trailing `~`.

A claude.ai key is optional and refreshes every minute instead:

1. In Chrome, open claude.ai signed in to the account you want to track.
2. Cmd+Option+I, then **Application**, **Cookies**, **https://claude.ai**.
3. Filter for `sessionKey` and copy its value (starts `sk-ant-sid`).
4. Click the meter, **Add Claude key…**, paste, **Save**.

The key is stored in your macOS Keychain and never written to a file. If it
expires (for example you log out of claude.ai), the meter falls back to the
`claude` program's figures. Use **Update Claude key…**.

## Privacy

- Reads `~/.claude/projects/*/*.jsonl` (and any second account's) locally. Nothing from your logs leaves
  the machine.
- The only network calls are claude.ai's own usage endpoint, when you have
  added a key, and the `claude` program's own usage check.
- Cache: `~/.claude/context-meter-usage.json`.

## Commands

```bash
~/Applications/ContextMeter.app/Contents/MacOS/ContextMeter --print     # figures as text
~/Applications/ContextMeter.app/Contents/MacOS/ContextMeter --setkey    # add a key from Terminal (--setkey work for a second account)
./ContextMeter.app/Contents/MacOS/ContextMeter --print --local           # same, without claude.ai or the Keychain
./ContextMeter.app/Contents/MacOS/ContextMeter --local --open            # drops the menu by itself, for a screenshot
./uninstall.sh                                                           # remove everything, including the key
```

## Updating

```bash
git pull && ./install.sh
```

Each build has a new signature, so after an update macOS asks once for your
login password before the meter may read its key again. Choose **Always Allow**.

## Licence

MIT. Not affiliated with Anthropic. The claude.ai usage endpoint is undocumented and may change.
