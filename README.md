<img src="Priority/Assets.xcassets/AppIcon.appiconset/ios-1024.png" alt="" width="72" align="left" />

# Priority

**A keyboard-first macOS menu bar app for working Checkvist lists fast.**
Quick navigation, priority and due workflows, focus timers, a kanban board, an honest daily log, and a command line that reaches the same data.

<br clear="left" />

---

Priority lives in the menu bar and is built to be driven without the mouse. Checkvist owns your tasks; Priority adds the things Checkvist has no representation for — priority ranking, start dates, recurrence, focus sessions, daily habits, and a record of what actually happened each day.

It works offline. It works from the terminal. And it exposes the whole surface to an AI assistant over MCP.

- **macOS 15.6+**
- Repository: [MaybeItsSoftware/priority](https://github.com/MaybeItsSoftware/priority)

## Contents

- [Install](#install) · [First run](#first-run)
- [Keyboard flow](#keyboard-flow) · [Command palette](#command-palette)
- [Views](#views) · [The dock row](#the-dock-row)
- [Daily log](#daily-log) · [Obsidian daily notes](#obsidian-daily-notes)
- [Command line](#command-line) · [MCP server](#mcp-server) · [Plugins](#plugins)
- [Build from source](#build-from-source) · [Where your data lives](#where-your-data-lives)

## Install

1. Download the latest `.dmg` from [Releases](https://github.com/MaybeItsSoftware/priority/releases).
2. Drag `Priority.app` into `Applications`.
3. Right-click it once and choose **Open**.

The build is signed with a development certificate rather than a Developer ID, so Gatekeeper will ask the first time. If it refuses outright:

```bash
xattr -cr /Applications/Priority.app
```

Or build it yourself — see [Build from source](#build-from-source).

## First run

Open Preferences with `Cmd+,`:

| Step | What |
| --- | --- |
| 1 | Checkvist username and remote API key (from [checkvist.com/auth/profile](https://checkvist.com/auth/profile)) |
| 2 | The checklist/list ID to work in |
| 3 | Global hotkey to toggle the popover |
| 4 | Quick-add hotkey, and whether it targets the list root or a specific parent |
| 5 | Day rollover hour — when your day starts, default 04:00 |
| 6 | Obsidian inbox folder *(optional)* |
| 7 | MCP integration *(optional)* |
| 8 | Launch at login |

Onboarding boxes guide the Checkvist, Obsidian and Google Calendar setup. Each one is dismissable, and the app stays usable offline-first without any of them.

## Keyboard flow

### Navigation

| Key | Action |
| --- | --- |
| `j` / `↓` | Next task |
| `k` / `↑` | Previous task |
| `l` / `→` | Expand the task — subtasks appear indented underneath — then step into them |
| `h` / `←` | Collapse, step back out to the parent row, or leave the scope |
| `Shift+→` / `Shift+←` | Zoom in: the list becomes that task's subtree, and back out. Also `]` / `[` |
| `Ctrl+←` / `Ctrl+→` | Cycle root view |
| `q` | All view |
| `w` | Due view |
| `e` | Tags view |
| `r` | Priority view |
| `t` | Kanban view |
| `y` | Matrix view |
| `u` | Daily view |
| `?` | Every shortcut, on your own bindings — the reference sheet |
| `Esc` | Cancel input / close popover |

### Task actions

| Key | Action |
| --- | --- |
| `Space` | Complete |
| `Shift+Space` | Invalidate ("won't do") |
| `Enter` | Add sibling below |
| `Alt+Enter` | Add sibling **above** |
| `Shift+Enter` | Add child |
| `Tab` / `Shift+Tab` | Indent / unindent |
| `Cmd+D` | Duplicate — content only, no due date, tags or subtasks |
| `Shift+A` | Quick-add at the configured location |
| `Cmd+↑` / `Cmd+↓` | Move task |
| `1`–`9` | Scoped priority rank, within the parent |
| `Hyper+1`–`Hyper+9` | Absolute priority rank (`Ctrl+Cmd+Option+Shift`) |
| `=` | Send to priority back |
| `-` / `0` | Clear scoped priority |
| `Hyper+-` | Clear absolute priority |
| `'` | Start a focus session on the selected task, from any view |
| `Cmd+Z` | Undo the last change |

### Kanban

| Key | Action |
| --- | --- |
| `h` / `←` | Previous column |
| `l` / `→` | Next column |
| `Cmd+←` / `Cmd+→` | Move task between columns |
| `f` | Show this task in the All view, entering its subtasks if it has any |

### Dailies

| Key | Action |
| --- | --- |
| `j` / `k` | Move through the checklist |
| `Space` | Tick / un-tick |
| `Return` | Add a daily — stays open, so a whole routine can be typed in one go |
| `a` / `i` | Rename the selected daily in place |
| `Delete` | Delete it. Past days keep their record, and it can be restored in Preferences |
| `Cmd+↑` / `Cmd+↓` | Reorder |
| `Esc` | Cancel adding or renaming, discarding what's been typed |

### Coming from Checkvist

Priority is a Checkvist client, so the gestures worth keeping are Checkvist's.
`j` `k` and the arrows, `Space` and `Shift+Space`, `Enter` and `Shift+Enter`,
`Tab` and `Shift+Tab`, `Shift+←` / `Shift+→` for hoisting, `⌘↑` / `⌘↓` to move,
`Del`, `F2`, `1`–`9` and `0`, `/`, and the `dd` `dr` `gg` `sc` sequences all mean
what they mean there. So does `?`.

Where it can't match, it's for one reason: Checkvist spells most of its actions
as two-letter sequences (`td`, `tt`, `ct`, `hf`, `ll`, `ee`, `nn`, `uu`), and
Priority spends those same starter letters on single-key root tabs
(`q w e r t y u`) and filter slots (`z x c v b n ,`). A letter can be a sequence
starter or a shortcut, not both — pressing it has to either act or wait for a
second key. The tabs won, because switching view is the thing you do most.

The nearest equivalents:

| Checkvist | Here | |
| --- | --- | --- |
| `td` schedule for today | `dt` | `t` is the Kanban tab |
| `tt` tags | `gt` | `t` is the Kanban tab |
| `ct` clear tags | `gu` | `c` is a filter slot |
| `hf` hide future | `Shift+H` | `h` collapses |
| `ll` go to a list | `Shift+L` | `l` expands |
| `ee` / `ea` / `ei` edit | `F2` / `a` / `i` | `e` is the Tags tab |
| `uu` undo | `Cmd+Z` | `u` is the Daily tab |
| `om` distraction-free | `'` | focus session |

All of them are rebindable in `Preferences → Keybindings` if you'd rather have
the Checkvist spelling than the tab.

### Integrations

| Key | Action |
| --- | --- |
| `o` | Open the selected task in Obsidian |
| `O` | Open in a new Obsidian window |
| `gc` | Add to Google Calendar |

## Command palette

Open with `:`, `;` or `Cmd+K`. Most commands accept several spellings — `unrepeat`, `no repeat`, `remove repeat` and `clear repeat` all do the same thing.

| Family | Commands |
| --- | --- |
| **Status** | `done`, `undone`, `invalidate`, `delete`, `undo` |
| **Due** | `due <value>`, `clear due` |
| **Start date** | `start <value>`, `edit start`, `clear start` |
| **Repeat** | `repeat <rule>`, `repeat daily`, `repeat every <n> <unit>`, `clear repeat` |
| **Tags** | `tag <name>`, `untag <name>` |
| **Priority** | `priority <1-9>`, `priority back`, `clear priority` |
| **Matrix** | `matrix <quadrant>`, `importance <value>`, `urgency <value>` |
| **Kanban** | `kanban left` / `right`, `kanban move left` / `right`, `kanban enter`, `kanban exit`, `kanban show in all`, `kanban focus mode` |
| **Outline** | `expand`, `collapse`, `expand all`, `collapse all`, `enter children`, `exit parent` |
| **View** | `list <name>`, `tab <name>`, `cycle tab next` / `prev`, `cycle filter next` / `prev`, `toggle children`, `toggle subtree`, `toggle context`, `toggle hide future` |
| **Timer** | `focus mode`, `toggle timer`, `pause timer` |
| **Obsidian** | `sync obsidian`, `open obsidian new window`, `link` / `create` / `clear obsidian folder`, `choose obsidian inbox` |
| **Calendar** | `sync google calendar`, `open google calendar` |
| **MCP** | `mcp guide`, `mcp config`, `copy mcp config`, `refresh mcp path` |
| **App** | `preferences`, `search`, `quick add`, `refresh lists`, `upload offline tasks` |

Due values understand natural language and times: `due today 14:30`, `due tomorrow 9am`, `due next week`, `due 4pm fri`, `due next monday morning`. The time words `morning`, `noon`, `afternoon`, `evening`, `midnight`, `eod` and `cob` all resolve to configurable named times.

## Views

| View | Key | What it shows |
| --- | --- | --- |
| **All** | `q` | The full tree |
| **Due** | `w` | Due and overdue, soonest first |
| **Tags** | `e` | Grouped by tag |
| **Priority** | `r` | Your ranked queue |
| **Kanban** | `t` | Configurable columns, filtered by tag or scoped to subtasks |
| **Matrix** | `y` | Eisenhower quadrants by importance and urgency |
| **Daily** | `u` | Dailies, the chart, and what you finished |

Kanban cards show the task text with tags stripped, a `P1`–`P9` priority badge, the due date with overdue/today highlighting, inline tags, and a subtask count. Columns are configured in Preferences and reorder by drag.

## The dock row

A narrow strip along the bottom of the popover, in every view. Right to left:

| Button | Does |
| --- | --- |
| ⚙︎ Gear | Preferences |
| ↻ Refresh | Re-fetch from Checkvist, with a spinner while it runs |
| ↕ Resize | Reveal the drag strip |
| ▁▃▅ Graph | Show/hide the Daily chart — **Daily view only** |

**Each root view remembers its own height.** The Daily view stacks a checklist, a chart and a completions list where the All view is a single list, so one shared height would be wrong for one of them at all times. Drag the strip to set a height; double-click it to go back to sizing from the content.

Heights are clamped to 240–900pt on write *and* on read at launch, so a stored value can never put the strip out of reach. If one somehow does:

```bash
defaults delete uk.co.maybeitsadam.priority panelHeightOverridesByRootView
```

Hiding the graph shortens the panel by exactly the chart's height, which turns the Daily view into a compact checklist on days you're only ticking things off.

## Daily log

The Daily view (`u`) answers "what did I get done, and how does today compare?"

### Dailies

Recurring things you intend to do — habits, not tasks — sitting at the top of the view as a checklist.

- **They reset at every rollover and never go overdue.** Miss one and it's a gap in the history: nothing to clear, nothing to reschedule. That's the whole reason they aren't Checkvist tasks with a `repeat daily` rule — a recurring *task* goes overdue and starts competing with real deadlines.
- **They're local.** Stored in `~/Library/Application Support/Priority/dailies.json`, so "brush teeth" never clutters your project lists or syncs to other Checkvist clients. Ticking one is instant and works offline.
- **Ticks land in the same log as task completions**, so they count towards the chart and appear in the Obsidian note.
- **Two kinds of schedule.** Fixed weekdays (`Mon Wed Fri`, weekdays, weekends, every day) or a rotating cycle — every other day, every three days — counted from the day you set it. A cycle walks through the week, so it's the one for "water the plants", not "standup".
- **Set the schedule as you type** from the menu in the add field, or edit any daily in full — day-by-day toggles, cycle length — in `Preferences → Plugins → Daily Log`.
- **Rename in place with `a`, delete with `Delete`**, without leaving the checklist. Deleting *archives*: the row goes from today's list and from the editor, but every past day that ticked it still renders with its title rather than a raw id, and it can be restored from the Deleted list in `Preferences → Plugins → Daily Log`. That is why deleting needs no confirmation — nothing has been lost.

### What the day records

- **Recording is always on and always local.** Completions, reopens, invalidations, finished focus sessions and the day's plan are appended to `~/Library/Application Support/Priority/daylog.jsonl` — one JSON object per line, so it stays readable with `tail`, and a torn write costs one event rather than the file.
- **Checkvist owns current state, the log owns history, Obsidian owns the archive.** Nothing syncs backwards, so there is no conflict resolution anywhere in this.
- **The day's plan is derived, not authored.** At the first popover open after your rollover hour, whatever is due, overdue or starting that day is snapshotted. That's what "N left" measures against — you never plan a day by hand.
- **Deferring is not slipping.** Pushing a due date forward is recorded distinctly from letting a task rot, so the view doesn't nag about a decision you made deliberately.
- **The day starts at your rollover hour, not midnight** (default 04:00), so a session finishing at 01:30 counts towards the day it belonged to.
- **No backfill.** History starts the day you first run this build. The chart is drawn from day one regardless — a flat run of days is a true statement about a history that has just started — with a "collecting since" line underneath until the window fills.

## Obsidian daily notes

In `Preferences → Plugins → Daily Log`, point Priority at your dailies folder and set the note naming to match your vault (`yyyy-MM-dd` by default; a subfolder pattern like `yyyy/MM` nests them). The preview line shows exactly which note today's block would land in. Then switch on "Write days into Obsidian daily notes", which stays disabled until a folder is chosen.

Once a day closes, its block is spliced into that day's note:

```markdown
<!-- priority:begin -->
## Log

**5 done** · **2/3 dailies** · **1h 40m focused** · 2 of 7 planned left

_Dailies:_
- [x] Read
- [x] Walk
- [ ] Stretch

- [x] Ship the DMG
- [x] Review the sync PR

_Unfinished:_
- [ ] Write release notes
<!-- priority:end -->
```

Only the text between the markers is ever touched, and rewriting a day replaces its own block rather than stacking a second one. **Creating missing notes is off by default**, so the plugin can't beat a Templater or Daily Notes template to the file — turn it on only if nothing else builds your dailies.

## Command line

`priority` is a Rust CLI covering the same ground: your lists, your dailies, your day log. It talks to the Checkvist API directly and reads Priority's local files off disk, so it works whether or not the app is running — and its writes take the same `flock(2)` the app does, so both can be open at once.

Run it with no arguments and it opens a **terminal UI with the same tabs as the app**, and the same keys to reach them:

```
 All q │ Due w │ Tags e │ Priority r │ Kanban t │ Matrix y │ Daily d
┌ All ───────────────────────────────────────────────────────────────┐
│▎[ ] Ship v0.4                                                      │
│   [ ] Draft the release notes  #work                               │
│   [x] Tag the commit                                               │
│ [ ] Buy milk  #home                                                │
└────────────────────────────────────────────────────────────────────┘
 j/k move · l/h in-out · space done · a add · ? help · esc quit
```

Or drive it by subcommand:

```bash
./scripts/install_cli.sh     # release build + a symlink onto your PATH
priority auth login

priority                     # the terminal UI
priority tasks
priority add Draft the release notes --due friday
priority search -q report --due-before 2026-09-01
priority daily add Read for twenty minutes --weekdays mon,wed,fri
priority daily add Water the plants --every-days 3
priority log --days 7
priority --json dailies | jq '.dailies[] | select(.done | not)'
```

Its credentials are its own, in `~/.config/priority/config.json` at mode 0600 — separate from the app's login-keychain item, so neither depends on how the other was built or signed. The dailies, log and metadata commands need no credentials at all.

Every command is one of the MCP tools under a friendlier name, and the same binary serves them over MCP with `priority mcp`. It is also the app's MCP server: Priority.app ships this binary at `Contents/Helpers/priority`.

**Full guide: [docs/cli.md](docs/cli.md)**

## MCP server

Priority exposes **19 MCP tools** so an AI assistant can work with your lists directly — thirteen that reach the Checkvist API, and six for the local state Checkvist has no representation for (day log, dailies, priority ranks and recurrence).

Set it up from `Preferences → Plugins → Native MCP Integration`. It detects Claude Code, Claude Desktop, Cursor, Windsurf, VS Code and Zed, and adds Priority to the one you pick in a single click, preserving any servers already in that client's config.

There is one implementation — the Rust CLI — and the app ships it at `Contents/Helpers/priority`, so it works whether or not you installed the CLI separately. `Priority --mcp-server` hands the process over to it, which keeps configurations written for older versions working unchanged. There were three implementations once; `scripts/mcp_smoke_check.py` is what remains of holding them together, and it now only checks that handover.

**Full guide: [docs/mcp-server.md](docs/mcp-server.md)**

## Plugins

Every external integration is a plugin behind a protocol.

Built in: `NativeCheckvistSyncPlugin`, `NativeObsidianIntegrationPlugin`, `NativeGoogleCalendarIntegrationPlugin`, `NativeMCPIntegrationPlugin`, `NativeDailyLogPlugin`, `OfflineTaskSyncPlugin`.

To install your own, open `Preferences → Plugins` and click **Install Plugin** (folder, `.zip`, or `.priority-plugin`), or drop a plugin folder into `~/Library/Application Support/Priority/Plugins` and hit **Reload**.

Built-in plugins are fully functional; user-installed plugins are manifest-driven (settings, metadata, lifecycle) and prepared for runtime capability wiring.

**Authoring guide: [docs/plugins.md](docs/plugins.md)**

## Build from source

Requirements: macOS 15.6+, Xcode 17+, and [Rust](https://rustup.rs) for the CLI.

```bash
git clone https://github.com/MaybeItsSoftware/priority.git
cd priority

# The app
xcodebuild -project 'Priority.xcodeproj' -scheme 'Priority' -configuration Debug -destination 'platform=macOS' build

# Headless logic (598 tests)
swift test

# The CLI (92 tests) — also the app's MCP server, bundled during the app build
cargo test --manifest-path cli/Cargo.toml

# `Priority --mcp-server` still reaches it
python3 scripts/mcp_smoke_check.py

# Build + launch Debug, or produce a release DMG
./scripts/run.sh
./scripts/build_dmg.sh <version>
```

### Layout

| Path | What |
| --- | --- |
| `Priority/` | The macOS app. |
| `Sources/PriorityCore/` | Pure, headless, UI-free logic. The app links it as a package product. |
| `Priority/Plugins/` | Integration plugins, one folder each, behind protocols |
| `cli/` | The Rust CLI crate — shares no source with the Swift side |
| `scripts/` | Build, install, the Python MCP fallback, and the parity check |
| `docs/` | [CLI](docs/cli.md) · [MCP](docs/mcp-server.md) · [plugins](docs/plugins.md) · [state ownership](docs/state-ownership.md) |

The same source tree is compiled by two build systems: the Xcode project builds the app, and `Package.swift` exposes `PriorityCore`, `PriorityPlugins` and `PriorityAppLogic` as SPM libraries so the headless logic can be tested without the app shell. Adding or moving a file often means updating `Package.swift` too — see [CLAUDE.md](CLAUDE.md).

## Where your data lives

| Path | What |
| --- | --- |
| `~/Library/Application Support/Priority/` | Dailies, day log, task cache, installed plugins |
| `~/Library/Preferences/uk.co.maybeitsadam.priority.plist` | Settings, priority ranks, recurrence rules, start dates |
| Login keychain, service `uk.co.maybeitsadam.priority` | The app's Checkvist remote key |
| `~/.config/priority/config.json` | The CLI's own credentials, mode 0600 |

Nothing is sent anywhere except Checkvist, and Google Calendar or Obsidian if you enable them.

> Upgrading from **Bar Tasker**? Everything is carried across automatically on first launch — preferences, dailies, the day log and your keychain item. The old locations are copied rather than moved, so they stay on disk until you delete them.

## License

MIT
