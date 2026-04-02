# Plugin Development Guide

Bar Tasker ships with native plugins only. Plugins are self-contained and live under:

- `Bar Tasker/Plugins/Native/Checkvist/`
- `Bar Tasker/Plugins/Native/Obsidian/`
- `Bar Tasker/Plugins/Native/GoogleCalendar/`
- `Bar Tasker/Plugins/Native/MCP/`

`SettingsView` renders plugin settings from active native plugins through shared protocols.

## Core Interfaces

Plugin contracts are defined under `Bar Tasker/Plugins/Protocols/`:

- `BarTaskerPlugin`
- `CheckvistSyncPlugin`
- `ObsidianIntegrationPlugin`
- `GoogleCalendarIntegrationPlugin`
- `MCPIntegrationPlugin`
- `PluginSettingsPageProviding`

Plugin registration lives in `Bar Tasker/Plugins/Registry/BarTaskerPluginRegistry.swift`.

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

## Verification

After plugin changes, run:

```bash
xcodebuild -project 'Bar Tasker.xcodeproj' -scheme 'Bar Tasker' -configuration Debug -destination 'platform=macOS' build
swift test
```
