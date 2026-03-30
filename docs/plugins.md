# Plugin Development Guide

This app now uses a native-first plugin model:

- `NativeCheckvistSyncPlugin` handles Checkvist auth, sync, CRUD, and task cache.
- `NativeObsidianIntegrationPlugin` handles Obsidian folder linking and markdown export/open.
- `NativeGoogleCalendarIntegrationPlugin` handles Google Calendar event URL generation.
- `NativeMCPIntegrationPlugin` handles MCP app-command/guide discovery and client-config JSON generation.

These are registered through `FocusPluginRegistry`, then injected into `CheckvistManager`.

## Core Interfaces

Plugin contracts are defined under `Bar Tasker/Plugins/`:

- `FocusPlugin`
- `CheckvistSyncPlugin`
- `ObsidianIntegrationPlugin`
- `GoogleCalendarIntegrationPlugin`
- `MCPIntegrationPlugin`
- `FocusPluginRegistry`

## How To Create A Plugin

1. Add a new Swift file in `Bar Tasker/`.
2. Implement one of these protocols:
   - `CheckvistSyncPlugin` for task backend sync.
   - `ObsidianIntegrationPlugin` for vault export/open behavior.
   - `GoogleCalendarIntegrationPlugin` for calendar event handoff behavior.
   - `MCPIntegrationPlugin` for MCP command discovery and config generation behavior.
3. Give your plugin a unique `pluginIdentifier`.
4. Register and activate it in `AppDelegate` before `CheckvistManager` is created.

Example wiring:

```swift
private let pluginRegistry: FocusPluginRegistry = {
  let registry = FocusPluginRegistry.nativeFirst()
  registry.register(MyCustomCheckvistPlugin(), activate: true)
  registry.register(MyCustomObsidianPlugin(), activate: true)
  registry.register(MyCustomGoogleCalendarPlugin(), activate: true)
  registry.register(MyCustomMCPPlugin(), activate: true)
  return registry
}()

lazy var checkvistManager: CheckvistManager = CheckvistManager(pluginRegistry: pluginRegistry)
```

## Checkvist Plugin Responsibilities

A `CheckvistSyncPlugin` is responsible for:

- Login and token lifecycle (`login`, `clearAuthentication`)
- Task fetch/list fetch
- Task mutations (close/reopen/invalidate/update/create/delete/move/reparent)
- Cache persistence and stale-cache checks used for offline Obsidian sync fallback

If your plugin does not support a capability, return `false` for the operation or throw a typed error.

## Obsidian Plugin Responsibilities

An `ObsidianIntegrationPlugin` is responsible for:

- Inbox selection and clearing
- Per-task linked folders
- Exporting and opening markdown via `syncTask(...)`

The manager handles queueing/retry logic and when to invoke sync; the plugin handles file/vault behavior.

## Google Calendar Plugin Responsibilities

A `GoogleCalendarIntegrationPlugin` is responsible for:

- Building a Google Calendar create-event URL from the selected task
- Deciding how due date/time maps to event timing

The manager handles when the action is triggered; the plugin handles URL composition.

## MCP Plugin Responsibilities

A `MCPIntegrationPlugin` is responsible for:

- Resolving the Bar Tasker executable command path and optional guide file path.
- Generating a valid MCP client config JSON payload for copy/paste into MCP clients.
- Handling placeholder behavior when credentials or command path are unavailable.

The manager handles settings UX (toggle, copy-to-clipboard, open guide); the plugin handles path/config behavior.

## Native-First Rule

Keep core app behavior available with built-in plugins. Add custom plugins by overriding the active plugin in the registry rather than editing view code.

## Verification

After plugin changes, run:

```bash
xcodebuild -project 'Bar Tasker.xcodeproj' -scheme 'Bar Tasker' -configuration Debug -destination 'platform=macOS' build
swift test
```
