# <img src="Bar%20Tasker/Assets.xcassets/AppIcon.appiconset/ios-1024.png" alt="Bar Tasker logo" width="28" /> Bar Tasker

A keyboard-first macOS menu bar app for working your Checkvist lists quickly, with due/tag/priority views, timers, Obsidian export, and Google Calendar handoff.

## Highlights

- Menu bar title shows the current task (and timer summary when enabled).
- Root views: **All / Due / Tags / Priority**.
- Due view buckets: **Overdue, ASAP, Today, Tomorrow, Next 7 days, Future**.
- Priority ranking with automatic shifting (`1-9`, `=`, `-`).
- Obsidian integration with note export, folder linking, and offline fallback.
- Google Calendar integration to create prefilled events from tasks.
- Native-first plugin architecture with built-in Checkvist sync, Obsidian, and Google Calendar plugins.
- Native MCP integration plugin with an embedded MCP stdio server for AI assistants.
- Global hotkey support for quick popover open/close.

## Keyboard

### Navigation

| Key | Action |
|-----|--------|
| `j` / `↓` | Next task |
| `k` / `↑` | Previous task |
| `l` / `→` | Enter subtasks |
| `h` / `←` | Exit to parent |
| `Esc` | Cancel input or close popover |

### Task actions

| Key | Action |
|-----|--------|
| `Space` | Mark done |
| `Shift+Space` | Invalidate task |
| `u` | Undo last action |
| `i` | Edit at start |
| `a` / `F2` | Edit at end |
| `Enter` | Add sibling |
| `Shift+Enter` | Add child |
| `Tab` | Add child |
| `Shift+Tab` | Unindent |
| `Cmd+↑` / `Cmd+↓` | Move task up/down |
| `Fn+Delete` | Delete task |

### Focus and filters

| Key | Action |
|-----|--------|
| `/` | Focus search |
| `H` | Toggle hide-future |
| `Shift+A` | Quick add using configured quick-add location |
| `dd` | Open due command |
| `dt` | Open due command prefilled with `today` |
| `gc` | Add selected task to Google Calendar |
| `gg` | Open first URL in task |
| `gt` / `gu` | Open tag / untag command |
| `sc` | Toggle breadcrumb context on rows (if enabled in Preferences) |

### Root scope (top bars)

| Key | Action |
|-----|--------|
| `q` / `w` / `e` / `r` | Switch root view: All / Due / Tags / Priority |
| `Ctrl+←` / `Ctrl+→` | Previous/next root view |
| `Ctrl+↑` / `Ctrl+↓` | Cycle active lower filter row |
| `z x c v b n m` | Jump to lower filter chips (Due/Tags row) |
| `↑` or `k` from first row | Focus root scope |
| `h` / `l` while root focused | Cycle scope tabs or chips |

### Priority

| Key | Action |
|-----|--------|
| `1..9` | Set priority rank |
| `=` | Send selected task to back of priority list |
| `-` | Clear priority |

### Obsidian

| Key | Action |
|-----|--------|
| `o` | Open selected task in Obsidian |
| `O` | Open selected task in a new Obsidian window |

## Commands (`:` or `;`, or `Cmd+K`)

Command mode supports:

- `done`, `undone`, `invalidate`
- `due <value>`, `clear due` (`due today 14:30`, `due tomorrow 9am`, `due 2026-04-01 17:00`)
- `tag <name>`, `untag <name>`
- `list <name>`
- `priority <1-9>`, `priority back`, `clear priority`
- `sync obsidian`
- `open obsidian new window`
- `link obsidian folder`
- `create obsidian folder`
- `clear obsidian folder`
- `sync google calendar`

## Google Calendar integration

- Opens Google Calendar in your browser with a prefilled event template.
- Uses due date/time for event timing when present; otherwise uses a short default event.
- Can be triggered from command mode (`sync google calendar`) or `gc`.

## Obsidian integration

- Fetches Checkvist tasks with notes (`with_notes=true`).
- Exports markdown to your configured Obsidian inbox folder.
- Supports per-task folder linking: link a parent task to a vault folder and subtree exports follow that folder.
- Uses security-scoped bookmarks for persistent folder access.
- Offline-safe flow:
  - uses cached task/note payload when network refresh fails,
  - tracks pending sync queue and retries when connectivity returns.

## Plugin system

- Integrations are now routed through plugin protocols.
- Built-in defaults are `NativeCheckvistSyncPlugin`, `NativeObsidianIntegrationPlugin`, `NativeGoogleCalendarIntegrationPlugin`, and `NativeMCPIntegrationPlugin`.
- Plugin contracts and wiring live under `Bar Tasker/Plugins/`.
- See [Plugin Development Guide](docs/plugins.md) to create and register custom plugins.

## MCP server

- Bar Tasker itself can run as an MCP server via `--mcp-server`.
- MCP plugin command resolution is app-first, with optional script fallback for local debug/dev flows.
- Preferences includes MCP plugin controls to refresh app command path, copy client config, and open the guide.
- See [MCP Server Guide](docs/mcp-server.md) for setup, env vars, and client config.

## Preferences

Open **Preferences** from the menu bar context menu or `Cmd+,`.

Configure:

1. Checkvist username
2. Checkvist remote API key
3. Checklist selection / list ID
4. Obsidian inbox folder
5. Global hotkey and quick-add hotkey
6. Quick-add target location (list root or specific parent task ID)
7. MCP plugin controls (app command detection, client config copy, guide link)
8. Other app preferences

## Installation

Because this app is open-source and unsigned, Gatekeeper may block first launch.

1. Download the latest `.dmg` from [Releases](https://github.com/MaybeItsAdam/bar-tasker/releases).
2. Drag `Bar Tasker.app` to `Applications`.
3. Right-click the app and choose **Open** once.

Or:

```bash
xattr -cr /Applications/"Bar Tasker.app"
```

## Build

```bash
xcodebuild -project 'Bar Tasker.xcodeproj' -scheme 'Bar Tasker' -configuration Debug -destination 'platform=macOS' build
swift test
```

Build DMG:

```bash
./scripts/build_dmg.sh 1.2.0
```

## Requirements

- macOS 15.6+
- Xcode 17+

## License

MIT License
