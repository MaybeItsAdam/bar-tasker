# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Priority is a keyboard-first macOS menu bar app (macOS 15.6+, Xcode 17+) for working Checkvist lists. It is an Xcode app with a Swift Package layered on top — `Package.swift` exposes `PriorityCore` (pure logic), `PriorityPlugins` (integration plugins), and `PriorityAppLogic` (the headless-but-app-bound state machines) as SPM library targets that share source with the Xcode project.

`cli/` is a separate Rust crate producing `priority`, a command-line peer of the app that talks to the Checkvist API directly and reads the same local files. It shares no source with the Swift side and nothing in `Priority/` may reference it. Its credentials are deliberately its own (`~/.config/priority/config.json`, see `cli/src/config.rs`) rather than the app's keychain item, which is reachable only by something carrying the app's code signature. See `docs/cli.md`.

## Build, Run, Test

```bash
# Full app build (the canonical "does it compile" check)
xcodebuild -project 'Priority.xcodeproj' -scheme 'Priority' -configuration Debug -destination 'platform=macOS' build

# Run all SPM unit tests (PriorityCoreTests + PriorityPluginTests + PriorityAppLogicTests)
swift test

# Run a single test by filter (XCTest style)
swift test --filter PriorityCoreTests.CommandEngineCommandParsingTests/testParseSimpleKeywordCommands

# Build + launch the Debug app (kills any running instance first)
./scripts/run.sh

# Produce a release DMG
./scripts/build_dmg.sh <version>

# The Rust CLI
cargo test --manifest-path cli/Cargo.toml
cargo clippy --manifest-path cli/Cargo.toml --all-targets -- -D warnings
cargo fmt --manifest-path cli/Cargo.toml --check
./scripts/install_cli.sh            # release build + a symlink onto PATH
```

`README.md` is authoritative for keybindings and command palette syntax — consult it when editing `KeyboardShortcutRouter.swift` or `CommandEngine.swift` so behaviour stays in sync.

## Architectural Layout (Two Build Systems, One Source Tree)

The same files are compiled by two different systems, which is the most important thing to know before editing:

1. **Xcode project** (`Priority.xcodeproj`) — builds the actual macOS app from everything under `Priority/`.
2. **Swift Package** (`Package.swift`) — builds three libraries from curated subsets:
   - `PriorityCore` — sources rooted at `Priority/CoreLogic/`. Pure, headless logic only (command parser, recurrence, timer policies, feedback service protocol). This is what `corelogic-tests/` exercises.
   - `PriorityPlugins` — explicit `sources:` list of plugin files plus `plugin-tests-support/PluginModelStubs.swift` (which provides minimal stub models so plugin code compiles without the app shell). Tested by `plugin-tests/`.
   - `PriorityAppLogic` — explicit `sources:` list of the app-bound state machines (`TaskRepository`, `TaskMutationService`, `SyncService`, `UndoService`, the offline/priority stores) plus `applogic-support/AppLogicSharedTypes.swift`, which re-declares the Checkvist models rather than making `PriorityPlugins` publish them. Tested by `applogic-tests/`.

Consequences when editing:

- `Package.swift` has a large `pluginTargetExcludes` list and an explicit `sources:` list. Adding a new plugin file or moving a file into/out of `CoreLogic/` requires updating `Package.swift`, or `swift test` will start failing even though Xcode still builds.
- `PriorityCore` must stay free of AppKit/SwiftUI/UI dependencies — anything in `Priority/CoreLogic/` is consumed by the test target without the app.
- `PriorityPlugins` deliberately excludes each plugin's `+Settings.swift` extension and any service that pulls in app types (e.g. `CheckvistAPIClient.swift`, `ObsidianSyncService.swift`). Keep cross-plugin / app-only types out of the curated `sources:` list.
- `PriorityAppLogic` sources must not import AppKit or SwiftUI either. `TaskMutationService` and `SyncService` reach the UI layer through the `TaskMutationHost` / `SyncHost` protocols in `Priority/TaskServiceHosts.swift`; `AppCoordinator` provides the production conformance in `AppCoordinator+ServiceHosts.swift`, which is the app-only side and stays out of the package. Adding a coordinator dependency to either service means adding a host member, not a `weak var coordinator`.
- **A file can only belong to one SPM target.** `PriorityAppLogic` therefore cannot `import PriorityCore` and reuse its policies — the same sources are compiled straight into the Xcode app, where `PriorityCore` isn't a module. That's why `OfflineReplayPolicy.swift` sits at the app root rather than in `CoreLogic/` despite being pure logic.

## App Composition

- `MainApp.swift` is a near-empty `@main` that installs `AppDelegate` via `NSApplicationDelegateAdaptor`. The app uses `.accessory` activation policy (menu bar only).
- `AppDelegate` is the composition root: it owns the singleton `AppCoordinator` (constructed with `PluginRegistry.nativeFirst()`), the `MenuBarController` (status item + popover), and the `GlobalShortcutManager` (Carbon hotkeys for toggle-popover and quick-add).
- **MCP launch mode**: when launched with `--mcp-server`, `AppDelegate.applicationDidFinishLaunching` short-circuits into `launchMCPServerMode()` (stdio MCP server) before any UI is set up. Same binary, two modes — preserve this branch when refactoring startup. See `docs/mcp-server.md`.
- `AppCoordinator` is a known "god object" — it forwards many properties to `TaskRepository`, `NavigationState`, and `TaskListViewModel`, and its responsibilities are split across `AppCoordinator+*.swift` extensions (Navigation, QuickAdd, ReorderingAndTiming, StateAndLifecycle, TaskMutations, TaskScoping, TaskSync, Undo). `ARCHITECTURE_IMPROVEMENT_PLAN.md` describes the intended decomposition; align new work with it rather than entrenching the forwarding pattern.
- `TaskRepository` is the source of truth for tasks/auth/lists. Cache invalidation fans out through `CacheInvalidationBus`: a cache-relevant `var`'s `didSet` calls `bus.invalidate()`, and the single subscriber marks `TaskListViewModel`'s cache dirty. The rebuild is lazy — it happens on the next read of `TaskListViewModel.cache`. Adding cache-relevant state means adding a `bus.invalidate()` to its `didSet`, or the UI goes stale. See `docs/state-ownership.md`.

## Plugin Architecture

All external integrations (Checkvist sync, Obsidian, Google Calendar, MCP) are plugins behind protocols in `Priority/Plugins/Protocols/PluginProtocols.swift`. Native implementations live one folder per plugin under `Priority/Plugins/Native/<Name>/`, registered through `PluginRegistry` (`PluginRegistry.nativeFirst()` is the production factory).

Conventions enforced by `docs/plugins.md`:

- One folder per plugin; do **not** put plugin-specific services or models at the app root.
- Plugin settings UI lives in a plugin-local `<PluginName>+Settings.swift` extension that conforms to `PluginSettingsPageProviding`. `SettingsView` enumerates active plugins generically — never add `switch`/`if`-by-plugin logic there.
- New plugin files that the SPM `PriorityPlugins` target needs must be added to the explicit `sources:` list in `Package.swift`; UI/`+Settings.swift` files stay app-only and should be left out (or excluded).

`NativeDailyLogPlugin` is the one deliberate exception to "contracts live in `Protocols/PluginProtocols.swift`, implementations compile into `PriorityPlugins`". Its contract sits in its own file (`Protocols/DailyLogPluginProtocol.swift`) and the whole `Native/DailyLog/` folder is excluded from the `PriorityPlugins` target, because it depends on `PriorityCore` types (`DayLogEvent`, `DayBoundary`, `DayLogAggregator`) — the same one-file-one-target constraint that keeps `MCPClientInstaller.swift` app-only. Its testable logic lives in `CoreLogic/` instead. Recording reaches it through `TaskMutationHost.recordDayLogTaskAction` (primitives only, since `PriorityAppLogic` can't see the event type either) and `FocusSessionManager.onFocusSessionCompleted`. See `docs/plugins.md`.

`OfflineTaskSyncPlugin` provides offline storage. `TaskRepository.activeSyncPlugin` resolves to either it or the Checkvist sync plugin based on `repository.canSyncRemotely`, so callers should always go through `repository.activeSyncPlugin` rather than naming the offline plugin directly.

## Conventions and Tooling

- SwiftLint config (`.swiftlint.yml`) is intentionally permissive: many style-only rules disabled, `file_length` warning at 800 / error at 1500, `function_body_length` warning at 150, `cyclomatic_complexity` warning at 25. Don't gratuitously split files just to satisfy stricter defaults.
- `check_braces.py` and `check_indent.py` are throwaway diagnostic scripts hard-coded to `Priority/KanbanBoardView.swift`. Not part of CI; ignore unless debugging that file.
- `FocusCore/` is a separate Swift package (sibling, not consumed by the main package) — leave it alone unless explicitly asked.
- Logging uses `os.Logger` with subsystem `uk.co.maybeitsadam.priority`; reuse this subsystem with a category that matches the type.

## Verifying Changes

After any plugin or core-logic change, run both:

```bash
xcodebuild -project 'Priority.xcodeproj' -scheme 'Priority' -configuration Debug -destination 'platform=macOS' build
swift test
```

Xcode catches app-only breakage; `swift test` catches breakage in `PriorityCore`/`PriorityPlugins`/`PriorityAppLogic` (including `Package.swift` source-list drift).

After changing anything under `cli/`, also run:

```bash
cargo test --manifest-path cli/Cargo.toml
cargo clippy --manifest-path cli/Cargo.toml --all-targets -- -D warnings
cargo fmt --manifest-path cli/Cargo.toml --check
```

After changing **any** of the three MCP servers (`Priority/Plugins/MCP/MCPServer.swift`, `scripts/priority_mcp_server.py`, or `cli/src/`), also run:

```bash
cargo build --release --manifest-path cli/Cargo.toml   # so the Rust one is included
python3 scripts/mcp_parity_check.py
```

All three are reachable by the same clients and must expose the same tools with the same answers, but none can import the others, so parity is asserted from the outside: drive all three over stdio and diff their tool lists, their answers, the files they leave on disk, and — against a stub Checkvist — the HTTP requests they make. Swift is the reference, since its logic is what `corelogic-tests/` covers directly. Needs a Debug app build; reads no real data and needs no credentials. A missing Rust build is reported and skipped rather than failing, so **check the output says three implementations, not two.**
