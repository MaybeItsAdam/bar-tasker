# Architecture Improvement Plan

This document captures the structural problems in Bar Tasker as it stands today and the staged work needed to resolve them. It is referenced from `CLAUDE.md` and should be kept current — when a phase lands, mark it done; when scope changes, edit here rather than scattering decisions across PRs.

## Guiding Principles

- **Decompose along responsibilities, not file size.** Splitting one 800-LOC file into four 200-LOC files that all import each other is not progress.
- **Push state down, not coordination up.** `AppCoordinator` should orchestrate, not own; managers should own their state and expose intent-level APIs.
- **Plugin identity must not leak.** No `isUsingOfflineStore`-style booleans outside `Plugins/`. Switching is a plugin-layer concern.
- **One source of truth per fact.** No duplicated computed properties across `AppCoordinator` and `TaskRepository`.
- **Tests are part of the contract.** New seams introduced by this plan ship with tests; existing untested code is not refactored without a test first.

## Current Findings

### 1. AppCoordinator god object — 2,205 LOC across 9 files

- Base `AppCoordinator.swift:1` (453 LOC) holds 14 direct properties, ~25 forwarded properties, and 10+ child managers (`repository`, `navigationState`, `taskListViewModel`, `timer`, `quickEntry`, `kanban`, `focusSessionManager`, `startDates`, `recurrence`, `preferences`, `integrations`, `userPluginManager`).
- Largest extensions: `+TaskMutations.swift` (549 LOC), `+TaskScoping.swift` (543 LOC), `+ReorderingAndTiming.swift` (366 LOC), `+StateAndLifecycle.swift` (328 LOC).
- Forwarding pattern hides ownership: e.g. `currentParentId`, `hideFuture`, `tasks`, `username`, `remoteKey` all read through `AppCoordinator` even though their state lives in three different managers.

### 2. UI files past SwiftLint limits

- `PopoverView.swift` — 2,068 LOC (config error threshold is 1,500). Bundles list rendering, command palette, kanban embed, and modal overlays in one file.
- `SettingsView.swift` — 1,473 LOC. Approaches the same limit because plugin settings pages are stitched in here rather than rendered generically.

### 3. Cache invalidation is dual-mechanism and incomplete

Two parallel systems coexist:

- **Callback hooks** — `TaskRepository.onCacheRelevantChange` wired in `AppCoordinator+StateAndLifecycle.swift:26`; same hook on `KanbanManager`, `QuickEntryManager`, `TimerManager`, `FocusSessionManager`, `StartDateManager` (lines 51–66).
- **`didSet` observers** — `AppCoordinator.currentParentId` calls `invalidateCaches()` directly (line 26); `TaskRepository.tasks/priorityTaskIdsByParentId/absolutePriorityTaskIds/taskEisenhowerLevels` fire the hook from `didSet`.

Gaps:

- `TaskRepository.availableLists` has **no** `didSet` — UI consumes it (SettingsView, connection state) but stale state isn't invalidated.
- `TaskRepository.isNetworkReachable` has no hook — offline→online transitions rely on explicit polling/sync calls.
- ~~`isUsingOfflineStore` is computed identically in `AppCoordinator+TaskScoping.swift:25` *and* `TaskRepository.swift:127`. `activeCredentials` similarly duplicated.~~ (Phase 1: renamed to `canSyncRemotely`, owned by `TaskRepository`; AppCoordinator forwards.)

### 4. Plugin abstraction leaks

- ~~`isUsingOfflineStore` referenced in non-plugin code at: `AppCoordinator+TaskScoping.swift:25`, `AppCoordinator+TaskSync.swift:12`, `TaskRepository.swift:127,133`, `SettingsView.swift:633,644`.~~ (Phase 1: collapsed to `repository.canSyncRemotely`, with the Checkvist settings caption switched to `manager.listId.isEmpty` instead.)
- ~~`NativeCheckvistSyncPlugin+Settings.swift:273` reaches *up* into `manager.isUsingOfflineStore` to decide a caption — settings UI shouldn't know whether a sibling plugin is active.~~ (Phase 1: replaced with `manager.listId.isEmpty`.)

### 5. Test coverage cliff

- Tested: command parser, due-date parsing, timer policies, recurrence, individual plugin sync logic, user-plugin manifest loading.
- **Untested**: AppCoordinator orchestration, `TaskRepository` state machine, sync flow (offline↔online), `TaskListViewModel` cache invalidation, undo/redo (`AppCoordinator+Undo.swift`), `TaskNavigationCoordinator`, all UI.

### 6. Other smells

- `KanbanManager.swift` (778 LOC) and `IntegrationCoordinator.swift` (556 LOC) are heavy and mix orchestration with state.
- MCP server (`Plugins/MCP/MCPServer.swift`, ~1,500 LOC) lives in-process — fine for iteration, but couples app and protocol lifecycles.
- `plugin-tests-support/PluginModelStubs.swift` exists because plugin code can't compile without app types — symptom of incomplete plugin/app separation.

## Phased Plan

Order matters: each phase removes blockers for the next. Don't reorder without updating this section.

### Phase 0 — Safety net (prerequisite)

Before refactoring `AppCoordinator` we need a regression harness for the behaviour we're about to move.

- [x] Add integration-style tests for `TaskRepository`: load, mutate, reorder, switch list, switch online/offline. Use the existing `OfflineTaskSyncPlugin` plus a fake `CheckvistSyncPlugin` to drive both branches.
- [x] Add tests for `AppCoordinator.taskAction` + reordering + undo paths.
- [x] Add a test for cache invalidation: mutate `tasks`, `availableLists`, `priorityTaskIdsByParentId`, assert `TaskListViewModel.cache` rebuilds (this will reveal the missing `availableLists` `didSet`).

### Phase 1 — De-duplicate plugin-switch state

Concrete, low-risk; removes the most-cited leak.

- [x] Move `isUsingOfflineStore`, `activeCredentials`, `activeSyncPlugin` to a single owner. Renamed to `canSyncRemotely` on `TaskRepository` (inverted boolean so the offline plugin no longer leaks into the public name); the duplicates in `AppCoordinator.swift` (`activeCredentials`) and `AppCoordinator+TaskScoping.swift` (`isUsingOfflineStore`) now forward to the repository.
- [x] Replace `if isUsingOfflineStore` callsites with intent-revealing methods on the repository — `canSyncRemotely`. `AppCoordinator+TaskSync.swift` and `SettingsView.swift` were updated. (Note: `hasCredentials` / `hasListSelection` / `canAttemptLogin` are still computed-property duplicates between `AppCoordinator+TaskScoping.swift` and `TaskRepository.swift`; left as-is because the plan didn't name them and Phase 3 will eat them when AppCoordinator decomposes.)
- [x] Remove the `manager.isUsingOfflineStore` reach from `NativeCheckvistSyncPlugin+Settings.swift:273`. Replaced with a direct `manager.listId.isEmpty` check, since the workspace caption only cares whether the user has picked a list.

### Phase 2 — Unify cache invalidation

Goal: one mechanism, no missed invalidations.

- [ ] Replace `onCacheRelevantChange` callbacks with a single `CacheInvalidationBus` (or an `@Observable` token whose mutation any consumer can react to). `TaskListViewModel`, `KanbanManager`, etc. subscribe; producers call one method.
- [ ] Audit every `var` on `TaskRepository` and `AppCoordinator`: each must either feed the bus or carry a comment explaining why it's exempt. Add `didSet` for `availableLists` and `isNetworkReachable`.
- [ ] Remove the now-redundant per-manager `onCacheRelevantChange` properties.

### Phase 3 — Decompose AppCoordinator

Phase 0 must be complete; without tests this is too dangerous.

Target shape:

- `AppCoordinator` shrinks to lifecycle wiring + composition (≤200 LOC).
- Behaviour moves to dedicated services consumed by views directly via `@Environment` / `@Observable`:
  - `TaskMutationService` ← `+TaskMutations`, `+QuickAdd`, `+Undo` (one undo stack, owned here).
  - `TaskNavigationService` ← `+Navigation`, `+TaskScoping`. Already partly exists as `TaskNavigationCoordinator.swift` — fold rather than duplicate.
  - `SyncService` ← `+TaskSync`, `+ReorderingAndTiming` reorder-flush logic.
  - `LifecycleController` ← `+StateAndLifecycle` setup/teardown.
- Forwarding properties on `AppCoordinator` are deleted; views read from the relevant service directly.
- Remove the `AppCoordinator+*.swift` extension pattern entirely — extensions exist to manage the size of one type, but the right move is to *not* have one type that big.

### Phase 4 — Split oversized views

- [ ] `PopoverView.swift` (2,068 LOC) → split by region: `PopoverHeader`, `TaskListPane`, `CommandPalette`, `KanbanPane`, `ModalOverlays`. Each view owns its own state binding to the relevant Phase-3 service.
- [ ] `SettingsView.swift` (1,473 LOC) → enforce the convention `docs/plugins.md` already mandates: `SettingsView` is a generic enumerator over `PluginSettingsPageProviding`. Any plugin-specific layout left in `SettingsView` moves to that plugin's `+Settings.swift`.
- [ ] `KanbanManager.swift` (778 LOC) → separate column-state ownership from filter/sort logic.

### Phase 5 — MCP isolation (optional, lower priority)

- [ ] Extract `MCPServer` into a separate executable target in `Package.swift`. App invokes it as a child process when `--mcp-server` is passed, or as an out-of-process server. Decouples MCP protocol churn from app release cycle.
- [ ] Delete `plugin-tests-support/PluginModelStubs.swift` once `BarTaskerPlugins` no longer needs app types — the stubs exist because of the leak Phase 1 starts to fix.

## Out of Scope

- Replacing `@Observable` / SwiftUI patterns. The concurrency model (`@MainActor` everywhere, async/await for I/O) is sound; don't churn it.
- `FocusCore/` package — sibling, unrelated, leave alone.
- SwiftLint config relaxation. The 1,500-LOC error limit is the *constraint*, not the problem; raising it would mask Phase 4.

## How to use this document

- When opening a PR that lands part of a phase, check the box and link the PR.
- When a finding turns out to be wrong or stale, edit the Findings section — don't leave drift between this doc and the code.
- New architectural problems get appended to Findings with a file:line citation; only promote to a phase once the fix is scoped.
