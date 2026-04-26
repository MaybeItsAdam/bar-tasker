# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Bar Tasker is a keyboard-first macOS menu bar app (macOS 15.6+, Xcode 17+) for working Checkvist lists. It is an Xcode app with a Swift Package layered on top — `Package.swift` exposes `BarTaskerCore` (pure logic) and `BarTaskerPlugins` (integration plugins) as SPM library targets that share source with the Xcode project.

## Build, Run, Test

```bash
# Full app build (the canonical "does it compile" check)
xcodebuild -project 'Bar Tasker.xcodeproj' -scheme 'Bar Tasker' -configuration Debug -destination 'platform=macOS' build

# Run all SPM unit tests (BarTaskerCoreTests + BarTaskerPluginTests)
swift test

# Run a single test by filter (XCTest style)
swift test --filter BarTaskerCoreTests.CommandEngineCommandParsingTests/testParseSimpleKeywordCommands

# Build + launch the Debug app (kills any running instance first)
./scripts/run.sh

# Produce a release DMG
./scripts/build_dmg.sh <version>
```

`README.md` is authoritative for keybindings and command palette syntax — consult it when editing `KeyboardShortcutRouter.swift` or `CommandEngine.swift` so behaviour stays in sync.

## Architectural Layout (Two Build Systems, One Source Tree)

The same files are compiled by two different systems, which is the most important thing to know before editing:

1. **Xcode project** (`Bar Tasker.xcodeproj`) — builds the actual macOS app from everything under `Bar Tasker/`.
2. **Swift Package** (`Package.swift`) — builds two libraries from a curated subset:
   - `BarTaskerCore` — sources rooted at `Bar Tasker/CoreLogic/`. Pure, headless logic only (command parser, recurrence, timer policies, feedback service protocol). This is what `corelogic-tests/` exercises.
   - `BarTaskerPlugins` — explicit `sources:` list of plugin files plus `plugin-tests-support/PluginModelStubs.swift` (which provides minimal stub models so plugin code compiles without the app shell). Tested by `plugin-tests/`.

Consequences when editing:

- `Package.swift` has a large `pluginTargetExcludes` list and an explicit `sources:` list. Adding a new plugin file or moving a file into/out of `CoreLogic/` requires updating `Package.swift`, or `swift test` will start failing even though Xcode still builds.
- `BarTaskerCore` must stay free of AppKit/SwiftUI/UI dependencies — anything in `Bar Tasker/CoreLogic/` is consumed by the test target without the app.
- `BarTaskerPlugins` deliberately excludes each plugin's `+Settings.swift` extension and any service that pulls in app types (e.g. `CheckvistAPIClient.swift`, `ObsidianSyncService.swift`). Keep cross-plugin / app-only types out of the curated `sources:` list.

## App Composition

- `MainApp.swift` is a near-empty `@main` that installs `AppDelegate` via `NSApplicationDelegateAdaptor`. The app uses `.accessory` activation policy (menu bar only).
- `AppDelegate` is the composition root: it owns the singleton `AppCoordinator` (constructed with `PluginRegistry.nativeFirst()`), the `MenuBarController` (status item + popover), and the `GlobalShortcutManager` (Carbon hotkeys for toggle-popover and quick-add).
- **MCP launch mode**: when launched with `--mcp-server`, `AppDelegate.applicationDidFinishLaunching` short-circuits into `launchMCPServerMode()` (stdio MCP server) before any UI is set up. Same binary, two modes — preserve this branch when refactoring startup. See `docs/mcp-server.md`.
- `AppCoordinator` is a known "god object" — it forwards many properties to `TaskRepository`, `NavigationState`, and `TaskListViewModel`, and its responsibilities are split across `AppCoordinator+*.swift` extensions (Navigation, QuickAdd, ReorderingAndTiming, StateAndLifecycle, TaskMutations, TaskScoping, TaskSync, Undo). `ARCHITECTURE_IMPROVEMENT_PLAN.md` describes the intended decomposition; align new work with it rather than entrenching the forwarding pattern.
- `TaskRepository` is the source of truth for tasks/auth/lists. Cache invalidation is currently manual via `onCacheRelevantChange` callbacks and `didSet` observers on `AppCoordinator` — be aware that mutations need the right invalidation hook to avoid stale UI.

## Plugin Architecture

All external integrations (Checkvist sync, Obsidian, Google Calendar, MCP) are plugins behind protocols in `Bar Tasker/Plugins/Protocols/PluginProtocols.swift`. Native implementations live one folder per plugin under `Bar Tasker/Plugins/Native/<Name>/`, registered through `PluginRegistry` (`PluginRegistry.nativeFirst()` is the production factory).

Conventions enforced by `docs/plugins.md`:

- One folder per plugin; do **not** put plugin-specific services or models at the app root.
- Plugin settings UI lives in a plugin-local `<PluginName>+Settings.swift` extension that conforms to `PluginSettingsPageProviding`. `SettingsView` enumerates active plugins generically — never add `switch`/`if`-by-plugin logic there.
- New plugin files that the SPM `BarTaskerPlugins` target needs must be added to the explicit `sources:` list in `Package.swift`; UI/`+Settings.swift` files stay app-only and should be left out (or excluded).

`OfflineTaskSyncPlugin` provides offline storage; `AppCoordinator.taskAction()` currently branches on `isUsingOfflineStore` — a known leaky abstraction flagged in the improvement plan.

## Conventions and Tooling

- SwiftLint config (`.swiftlint.yml`) is intentionally permissive: many style-only rules disabled, `file_length` warning at 800 / error at 1500, `function_body_length` warning at 150, `cyclomatic_complexity` warning at 25. Don't gratuitously split files just to satisfy stricter defaults.
- `check_braces.py` and `check_indent.py` are throwaway diagnostic scripts hard-coded to `Bar Tasker/KanbanBoardView.swift`. Not part of CI; ignore unless debugging that file.
- `FocusCore/` is a separate Swift package (sibling, not consumed by the main package) — leave it alone unless explicitly asked.
- Logging uses `os.Logger` with subsystem `uk.co.maybeitsadam.bar-tasker`; reuse this subsystem with a category that matches the type.

## Verifying Changes

After any plugin or core-logic change, run both:

```bash
xcodebuild -project 'Bar Tasker.xcodeproj' -scheme 'Bar Tasker' -configuration Debug -destination 'platform=macOS' build
swift test
```

Xcode catches app-only breakage; `swift test` catches breakage in `BarTaskerCore`/`BarTaskerPlugins` (including `Package.swift` source-list drift).
