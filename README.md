# <img src="Bar%20Tasker/Assets.xcassets/AppIcon.appiconset/ios-1024.png" alt="Bar Tasker logo" width="28" /> Bar Tasker

Bar Tasker is a keyboard-first macOS menu bar app for working Checkvist lists fast, with quick navigation, due/priority workflows, timers, kanban board, and plugin-based integrations.

## What You Get

- Fast menu bar workflow with minimal mouse usage.
- Root views for `All`, `Due`, `Tags`, `Priority`, and `Kanban`.
- Customisable kanban board with drag-to-reorder columns and tag/due-date conditions.
- Priority badges and due-date awareness surfaced directly on kanban cards.
- Task start dates with natural language parsing.
- Named time preferences for reusable time expressions.
- Recurring task rules.
- Due-time aware commands (for example `due today 14:30`, `due tomorrow 9am`).
- Quick-add from keybind to either:
  - list root, or
  - a specific parent task ID.
- Obsidian export/open with folder linking and offline sync queue fallback.
- Google Calendar event handoff from task metadata.
- Embedded MCP server for AI assistants.
- Native-first plugin architecture for all integrations.
- Dismissable onboarding boxes for Checkvist, Obsidian, and Google Calendar.

## Install

1. Download the latest `.dmg` from [Releases](https://github.com/MaybeItsAdam/bar-tasker/releases).
2. Move `Bar Tasker.app` into `Applications`.
3. Right-click once and choose **Open** (unsigned app).

If Gatekeeper blocks launch:

```bash
xattr -cr /Applications/"Bar Tasker.app"
```

## First Run Setup

Open Preferences (`Cmd+,`) and configure:

1. Checkvist username
2. Checkvist remote API key
3. Checklist/list ID
4. Global hotkey
5. Quick-add hotkey and target location
6. Obsidian inbox folder (optional)
7. MCP integration controls (optional)

On first use, optional onboarding boxes can guide setup for Checkvist, Obsidian, and Google Calendar.  
Each box is dismissable so the app remains usable in offline-first mode.

## Core Keyboard Flow

### Navigation

| Key | Action |
| --- | --- |
| `j` / `↓` | Next task |
| `k` / `↑` | Previous task |
| `l` / `→` | Enter subtasks |
| `h` / `←` | Exit to parent |
| `Ctrl+←` / `Ctrl+→` | Cycle root view |
| `q` | Jump to All view |
| `w` | Jump to Due view |
| `e` | Jump to Tags view |
| `r` | Jump to Priority view |
| `t` | Jump to Kanban view |
| `Esc` | Cancel input / close popover |

### Task actions

| Key | Action |
| --- | --- |
| `Space` | Complete task |
| `Shift+Space` | Invalidate task |
| `Enter` | Add sibling |
| `Shift+Enter` / `Tab` | Add child |
| `Shift+Tab` | Unindent |
| `Shift+A` | Quick-add (configured location) |
| `Cmd+↑` / `Cmd+↓` | Move task |
| `1`–`9` | Set scoped priority rank (within parent) |
| `Hyper+1`–`Hyper+9` | Set absolute priority rank (`Ctrl+Cmd+Option+Shift`) |
| `=` | Send to priority back |
| `-` | Clear scoped priority |
| `Hyper+-` | Clear absolute priority |
| `'` | Start a focus session on the selected task (any view) |

### Kanban

| Key | Action |
| --- | --- |
| `h` / `←` | Focus previous column |
| `l` / `→` | Focus next column |
| `Cmd+←` | Move task to previous column |
| `Cmd+→` | Move task to next column |
| `f` | Show selected task in All view (enters subtasks if present) |

### Integrations

| Key | Action |
| --- | --- |
| `o` | Open selected task in Obsidian |
| `O` | Open in new Obsidian window |
| `gc` | Add selected task to Google Calendar |

## Command Palette

Open with `:` / `;` / `Cmd+K`.

Supported command families:

- Status: `done`, `undone`, `invalidate`
- Due: `due <value>`, `clear due`
- Start date: `start <value>`
- Repeat: `repeat <rule>`
- Tags: `tag <name>`, `untag <name>`
- Priority: `priority <1-9>`, `priority back`, `clear priority`
- Obsidian: `sync obsidian`, `open obsidian new window`, `link/create/clear obsidian folder`
- Calendar: `sync google calendar`

## Kanban Board

The kanban view is accessible via the `Kanban` root tab. Columns are configurable in Preferences and can be filtered by tag or scoped to subtasks of the current task.

Cards show:
- Task text (tags stripped from display)
- Priority badge (`P1`–`P9`) when prioritised
- Due date with overdue/today highlighting
- Inline tags
- Subtask count

Press `f` on any selected card to jump to it in the All view, with the cursor positioned inside its subtasks if it has any.

## Plugin System

All external integrations are plugins.

- Built-ins:
  - `NativeCheckvistSyncPlugin`
  - `NativeObsidianIntegrationPlugin`
  - `NativeGoogleCalendarIntegrationPlugin`
  - `NativeMCPIntegrationPlugin`
- Contracts and registry live under `Bar Tasker/Plugins/`.
- Plugin authoring guide: [docs/plugins.md](docs/plugins.md)

End-user plugin install flow:

- Open `Preferences -> Plugins`
- Click `Install Plugin` (supports folder, `.zip`, `.bartasker-plugin`)
- Or drop a plugin folder into:
  - `~/Library/Application Support/Bar Tasker/Plugins`
- Use `Open Plugins Folder` and `Reload` in the same Plugins pane

Current scope: built-in plugins are fully functional; user-installed plugins are manifest-driven (settings, metadata, lifecycle) and prepared for runtime capability wiring.

## MCP Server

Bar Tasker includes an MCP stdio server and can run with `--mcp-server`.

- Configure MCP from Preferences (refresh command path, copy client JSON, open guide).
- Command resolution is app-first with optional script fallback for local dev/debug.
- Full setup and client examples: [docs/mcp-server.md](docs/mcp-server.md)

## Build From Source

Requirements:

- macOS 15.6+
- Xcode 17+

Build app and run tests:

```bash
xcodebuild -project 'Bar Tasker.xcodeproj' -scheme 'Bar Tasker' -configuration Debug -destination 'platform=macOS' build
swift test
```

Build DMG:

```bash
./scripts/build_dmg.sh <version>
```

Swift Package name: `bar-tasker-core`  
Core module name: `BarTaskerCore`

## License

MIT
