# <img src="checkvist%20focus/Assets.xcassets/AppIcon.appiconset/ios-1024.png" alt="Checkvist Focus logo" width="28" /> Checkvist Focus

A keyboard-first macOS menu bar app for working your Checkvist lists quickly, with due/tag/priority views, timers, and Obsidian export.

## Highlights

- Menu bar title shows the current task (and timer summary when enabled).
- Root views: **All / Due / Tags / Priority**.
- Due view buckets: **Overdue, ASAP, Today, Tomorrow, Next 7 days, Future**.
- Priority ranking with automatic shifting (`1-9`, `=`, `-`).
- Obsidian integration with note export, folder linking, and offline fallback.
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
| `dd` | Open due command |
| `gg` | Open first URL in task |
| `gt` / `gu` | Open tag / untag command |
| `sc` | Toggle breadcrumb context on rows |

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
- `due <value>`, `clear due`
- `tag <name>`, `untag <name>`
- `list <name>`
- `priority <1-9>`, `priority back`, `clear priority`
- `sync obsidian`
- `open obsidian new window`
- `link obsidian folder`
- `clear obsidian folder`

## Obsidian integration

- Fetches Checkvist tasks with notes (`with_notes=true`).
- Exports markdown to your configured Obsidian inbox folder.
- Supports per-task folder linking: link a parent task to a vault folder and subtree exports follow that folder.
- Uses security-scoped bookmarks for persistent folder access.
- Offline-safe flow:
  - uses cached task/note payload when network refresh fails,
  - tracks pending sync queue and retries when connectivity returns.

## Preferences

Open **Preferences** from the menu bar context menu or `Cmd+,`.

Configure:

1. Checkvist username
2. Checkvist remote API key
3. Checklist selection / list ID
4. Obsidian inbox folder
5. Global hotkey and app preferences

## Installation

Because this app is open-source and unsigned, Gatekeeper may block first launch.

1. Download the latest `.dmg` from [Releases](https://github.com/MaybeItsAdam/Checkvist-focus/releases).
2. Drag `Checkvist Focus.app` to `Applications`.
3. Right-click the app and choose **Open** once.

Or:

```bash
xattr -cr /Applications/"Checkvist Focus.app"
```

## Build

```bash
xcodebuild -project 'checkvist focus.xcodeproj' -scheme 'checkvist focus' -configuration Debug -destination 'platform=macOS' build
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
