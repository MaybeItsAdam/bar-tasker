# Plugin Development Guide

Priority ships with native plugins only. Plugins are self-contained and live under:

- `Priority/Plugins/Native/Checkvist/`
- `Priority/Plugins/Native/Obsidian/`
- `Priority/Plugins/Native/GoogleCalendar/`
- `Priority/Plugins/Native/MCP/`
- `Priority/Plugins/Native/DailyLog/`

`SettingsView` renders plugin settings from active native plugins through shared protocols.

## Core Interfaces

Plugin contracts are defined under `Priority/Plugins/Protocols/`:

- `PriorityPlugin`
- `CheckvistSyncPlugin`
- `ObsidianIntegrationPlugin`
- `GoogleCalendarIntegrationPlugin`
- `MCPIntegrationPlugin`
- `DailyLogPlugin` (in its own file, `Protocols/DailyLogPluginProtocol.swift` — see below)
- `PluginSettingsPageProviding`

Plugin registration lives in `Priority/Plugins/Registry/PriorityPluginRegistry.swift`.

## Native Plugin Rules

- Keep each plugin self-contained in its own folder (logic + settings UI extension).
- Do not place plugin-specific services/models in app root.
- If a plugin has settings, define them in a plugin-local `+Settings.swift` file.
- `SettingsView` should stay generic and never add plugin-specific switch/case logic.

## Responsibilities By Capability

### Checkvist (`CheckvistSyncPlugin`)

- Authentication/token lifecycle (`login`, `clearAuthentication`).
- Task/list fetch and task mutation operations.
- Cache persistence and stale-cache checks.

### Obsidian (`ObsidianIntegrationPlugin`)

- Inbox/linked-folder selection and clearing.
- Markdown export/open behavior via `syncTask(...)`.

### Google Calendar (`GoogleCalendarIntegrationPlugin`)

- Event URL composition for selected tasks.
- Due-date mapping decisions for event timing.

### MCP (`MCPIntegrationPlugin`)

- Resolve server command and optional guide path.
- Generate MCP client configuration JSON.

### Daily Log (`DailyLogPlugin`)

- Append-only event log (completions, reopens, invalidations, finished focus
  sessions, the day's plan snapshot) under
  `~/Library/Application Support/Priority/daylog.jsonl`.
- Logical-day keying against a configurable rollover hour.
- Projections for the Daily view and the note writer, so both render a day the
  same way.
- Managed-block writes into an Obsidian daily note.
- The set of **dailies** (recurring intentions) in `dailies.json` alongside the
  log.

The two files have deliberately different shapes. `daylog.jsonl` is history:
append-only, never rewritten, tolerant of a torn tail. `dailies.json` is
configuration: small, whole-file, atomically replaced. Renaming a daily should
change its name, not append a rename event that every reader has to replay.

Whether a daily is *done* is never stored on the daily — it is a question about
a specific day, answered from the log by
`DayLogAggregator.completedDailyIds`. Anything that would need clearing at
rollover eventually doesn't get cleared.

Daily ticks net **within a logical day only**, unlike task completions, which
net across the whole log. That is the entire behavioural difference between a
habit and a task: reopening a task reaches back to whichever day completed it,
whereas un-ticking a daily today must not blank yesterday's square.

This plugin breaks two conventions on purpose, both for the same reason:

- Its contract lives in `Protocols/DailyLogPluginProtocol.swift` rather than in
  `PluginProtocols.swift`, and
- the whole `Native/DailyLog/` folder is excluded from the `PriorityPlugins`
  SPM target.

Both follow from the module boundary: the plugin traffics in `PriorityCore`
types (`DayLogEvent`, `DayBoundary`, `DayLogAggregator`), a file can only belong
to one SPM target, and the Xcode app compiles everything as one module where
`import PriorityCore` isn't available. `MCPClientInstaller.swift` is app-only
for exactly the same reason. No coverage is lost — the logic worth testing lives
in `Priority/CoreLogic/` and is exercised by `corelogic-tests`.

Recording reaches the plugin through `TaskMutationHost.recordDayLogTaskAction`
(primitives only, since `PriorityAppLogic` can't see the event type either) and
through `FocusSessionManager.onFocusSessionCompleted`.

## Verification

After plugin changes, run:

```bash
xcodebuild -project 'Priority.xcodeproj' -scheme 'Priority' -configuration Debug -destination 'platform=macOS' build
swift test
```
