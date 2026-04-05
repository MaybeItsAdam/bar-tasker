# Codebase Improvement TODO

Findings from a full audit of the Bar Tasker codebase (2026-04-02). Items marked **done** were addressed in the same session.

---

## Security

- [x] **Validate URL schemes before opening** — `BarTaskerManager+Integrations.swift` now filters to `http`/`https` only.
- [x] **Audit all `NSWorkspace.shared.open()` call sites** — All call sites reviewed. Obsidian (`obsidian://`), MCP guide (`file://`), plugins folder (`file://`), and Google OAuth (`https://accounts.google.com` by construction) are safe. Added `https` scheme guard to the two Google Calendar event URL opens (`outcome.urlToOpen` and `openSavedGoogleCalendarEventLink`) which read from API responses / UserDefaults.
- [x] **Centralise API base URLs** — Created `CheckvistEndpoints.swift` with a single `baseURL` constant and typed endpoint helpers. Updated `CheckvistSession`, `NativeCheckvistSyncPlugin`, `CheckvistTaskRepository`, `BarTaskerMCPServer`, and `ObsidianSyncService` to use it. Google Calendar endpoints were already static constants in the plugin.

## Error Handling

- [x] **Add `os_log` where `try?` silently swallows errors** — `CheckvistSession` and `LocalTaskStore` now log failures.
- [x] **Replace remaining `try?` with logged `do/catch`** — No remaining `try?` in app source code.
- [x] **Replace `preconditionFailure` in static regex properties** — `AppDelegate.swift:350`, `BarTaskerManager+TaskScoping.swift:219`, `BarTaskerCommandEngine.swift:376` all crash on invalid regex. These are compile-time-constant patterns so the risk is low, but a `fatalError` with a descriptive message or a computed `NSRegularExpression?` with a fallback would be safer during refactoring.
- [x] **Preserve error context in `fetchTopTask` catch** — `BarTaskerManager+TaskOperations.swift:281` catches all errors with a generic `localizedDescription` string. Preserve the typed error for programmatic handling upstream.

## Test Coverage

- [x] **Expand `BarTaskerCommandEngine.parse()` tests** — Now 28 tests covering all command paths, aliases, priority edge cases, and due date resolution.
- [x] **Add `BarTaskerTimerStore` tests** — `formatted()`, `childCountByTaskId()`, and `rolledUpElapsedByTaskId()` are completely untested. Contains recursive logic that should have regression coverage.
- [ ] **Add `BarTaskerPluginRegistry` tests** — Registration, active plugin resolution, and `nativeFirst()` factory are untested.
- [ ] **Add `CheckvistAPIClient` tests** — Network layer has zero test coverage. Add tests with a mock `URLSession` / `URLProtocol`.
- [ ] **Add `BarTaskerMCPServer` tests** — MCP command dispatch and configuration generation are untested.
- [ ] **Add `BarTaskerTaskVisibilityEngine` tests** — The visibility engine is a pure function (`computeVisibleTasks(in:)`) that takes a `Context` struct, making it straightforward to test in isolation. Cover root scope filtering, search, due bucket sorting, tag filtering, and priority ordering.
- [ ] **Add `BarTaskerReorderQueue` tests** — The new extracted type is simple enough to unit test: enqueue, dequeue, coalescing by task ID.
- [ ] **Test `+Settings.swift` views** — All 5 plugin settings view files are untested. At minimum, snapshot or view-body tests to catch regressions.

## CI / Build

- [x] **Fix CI pipeline** — Added `swift build` step, removed `|| true`, added timeout, added warnings for missing coverage data.
- [ ] **Upload coverage to a reporting service** — Coverage is printed but not tracked over time. Add a codecov or similar upload step.
- [ ] **Add Xcode project build to CI** — The `macos-build` job exists but only builds the `.xcodeproj`. Consider running Xcode tests as well, or at least verifying the app target links cleanly.
- [ ] **Pin Xcode version** — CI uses `latest-stable` which can break unexpectedly. Pin to a specific version and bump deliberately.

## Concurrency

- [x] **Make `NetworkReachabilityMonitor` Sendable** — Marked `@unchecked Sendable` with `@Sendable` callback.
- [x] **Audit `DispatchQueue.main.async` in SwiftUI views** — All four `DispatchQueue.main.async` / `asyncAfter` calls in `PopoverView.swift` converted to `Task { @MainActor in }`. The 0.1s `asyncAfter` (scroll-to-composer) converted to `Task.sleep(for: .milliseconds(100))`.
- [ ] **Verify timer cancellation safety** — `BarTaskerManager+ReorderingAndTiming.swift:177-184`: the timer loop checks `Task.isCancelled` then sleeps then mutates. If the task is cancelled during the sleep, the mutation is skipped (correct), but consider whether the 1-second granularity causes UI jank on rapid task switches.

## Architecture

- [x] **Extract `BarTaskerCacheState`** — Cache dictionaries are now grouped in a value type.
- [x] **Extract `BarTaskerReorderQueue`** — Reorder batching is now a dedicated `@MainActor` class.
- [ ] **Break up `PopoverView.swift` (53KB)** — This is the largest file. Extract subviews: task row, breadcrumb bar, search/command input, onboarding boxes, delete confirmation, timer display. Each can be its own `View` struct.
- [ ] **Break up `BarTaskerManager+TaskOperations.swift`** — At ~1000 lines, this extension mixes CRUD, offline store, undo, and haptic feedback. Consider splitting into `+RemoteTaskOperations` and `+OfflineTaskOperations`.
- [ ] **Decouple `AppDelegate` from `BarTaskerManager`** — `AppDelegate.shared` is referenced from `BarTaskerManager` callbacks, creating a circular dependency. Introduce a delegate protocol or use Combine to decouple.
- [ ] **Extract preferences binding boilerplate** — `setupBindings()` in `BarTaskerManager+StateAndLifecycle.swift` is ~220 lines of mechanical `$property.sink { self?.preferencesStore.set(...) }`. Consider a macro, property wrapper, or table-driven approach to reduce this.
- [ ] **Move `RootDueBucket`, `RootTaskView`, etc. out of `BarTaskerManager`** — These nested types are referenced by `BarTaskerTaskVisibilityEngine` via `BarTaskerManager.RootTaskView`, coupling the engine to the manager. Move them to top-level types.

## Code Quality

- [x] **Name magic numbers** — `0x0800` (option key modifier), `49` (Space key code), `0x0A00` (shift+option), `11` (B key code) in `BarTaskerManager.swift:268-272` and `AppDelegate.swift`. Define as named constants.
- [ ] **Remove unused state** — Verify `lastUndo`, `commandSuggestionIndex`, and `editCursorAtEnd` are actively used; remove if dead.
- [ ] **Consistent error message strategy** — Error strings are scattered as inline literals. Consider an `AppError` enum with `LocalizedError` conformance for user-facing messages.
