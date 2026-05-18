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

- ~~**Callback hooks** — `TaskRepository.onCacheRelevantChange` wired in `AppCoordinator+StateAndLifecycle.swift:26`; same hook on `KanbanManager`, `QuickEntryManager`, `TimerManager`, `FocusSessionManager`, `StartDateManager` (lines 51–66).~~ (Phase 2: replaced by `CacheInvalidationBus`; the per-manager `onCacheRelevantChange` properties are gone.)
- ~~**`didSet` observers** — `AppCoordinator.currentParentId` calls `invalidateCaches()` directly (line 26); `TaskRepository.tasks/priorityTaskIdsByParentId/absolutePriorityTaskIds/taskEisenhowerLevels` fire the hook from `didSet`.~~ (Phase 2: `currentParentId`'s `didSet` lives on `NavigationState` and fires the bus; `TaskRepository`'s `didSet`s call `bus.invalidate()`.)

Gaps:

- ~~`TaskRepository.availableLists` has **no** `didSet` — UI consumes it (SettingsView, connection state) but stale state isn't invalidated.~~ (Phase 2: `didSet` added; fires bus.)
- ~~`TaskRepository.isNetworkReachable` has no hook — offline→online transitions rely on explicit polling/sync calls.~~ (Phase 2: `didSet` added; fires bus.)
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
- [x] Add tests for reordering paths (`ReorderQueueTests`). Undo paths gained coverage in step 3.2 once `UndoService` was extracted behind the `UndoActionPerforming` protocol — see `applogic-tests/UndoServiceTests.swift`. **Still missing:** `AppCoordinator.taskAction` itself isn't directly tested because it lives in `+TaskMutations.swift` (app-only, outside `BarTaskerAppLogic`); the existing TaskRepository tests cover the underlying state-machine but not the coordinator-level orchestration. Promote that coverage when `TaskMutationService` is extracted in step 3.4 (the service should land in `BarTaskerAppLogic` so it can be tested directly).
- [x] Add a test for cache invalidation: mutate `tasks`, `availableLists`, `priorityTaskIdsByParentId`, assert `TaskListViewModel.cache` rebuilds (this will reveal the missing `availableLists` `didSet`).

### Phase 1 — De-duplicate plugin-switch state

Concrete, low-risk; removes the most-cited leak.

- [x] Move `isUsingOfflineStore`, `activeCredentials`, `activeSyncPlugin` to a single owner. Renamed to `canSyncRemotely` on `TaskRepository` (inverted boolean so the offline plugin no longer leaks into the public name); the duplicates in `AppCoordinator.swift` (`activeCredentials`) and `AppCoordinator+TaskScoping.swift` (`isUsingOfflineStore`) now forward to the repository.
- [x] Replace `if isUsingOfflineStore` callsites with intent-revealing methods on the repository — `canSyncRemotely`. `AppCoordinator+TaskSync.swift` and `SettingsView.swift` were updated. (Note: `hasCredentials` / `hasListSelection` / `canAttemptLogin` are still computed-property duplicates between `AppCoordinator+TaskScoping.swift` and `TaskRepository.swift`; left as-is because the plan didn't name them and Phase 3 will eat them when AppCoordinator decomposes.)
- [x] Remove the `manager.isUsingOfflineStore` reach from `NativeCheckvistSyncPlugin+Settings.swift:273`. Replaced with a direct `manager.listId.isEmpty` check, since the workspace caption only cares whether the user has picked a list.

### Phase 2 — Unify cache invalidation

Goal: one mechanism, no missed invalidations.

- [x] Replaced `onCacheRelevantChange` callbacks with a single `CacheInvalidationBus` (`Bar Tasker/CacheInvalidationBus.swift`). Producers (`TaskRepository`, `NavigationState`, `KanbanManager`, `QuickEntryManager`, `TimerManager`, `StartDateManager`, `FocusSessionManager`) take the bus at init and call `bus.invalidate()` from their `didSet`s. The lone subscriber today (`AppCoordinator`) registers once in `setupChildCallbacks` and routes into `TaskListViewModel.invalidateCaches()`. The bus's `init` is `nonisolated` so `@MainActor` managers can keep a `CacheInvalidationBus()` default value on the parameter.
- [x] Audited every `var` on `TaskRepository` and `AppCoordinator`. Added `didSet` for `availableLists` and `isNetworkReachable` (both fire the bus). `checkvistIntegrationEnabled` also fires the bus from `didSet`, so `setupChildCallbacks` no longer reaches into `invalidateCaches()` from its callback. Vars that don't drive task-visibility caches (`isLoading`, `errorMessage`, `lastUndo`, the auth-credential vars whose downstream effect already routes through `tasks`/priority-queue reload) are intentionally exempt and remain unhooked. The previously-XCTExpectFailure'd cases in `TaskRepositoryCacheInvalidationTests` now pass without the wrapper.
- [x] Removed the per-manager `onCacheRelevantChange` properties and the AppCoordinator-side `currentParentId` setter no longer calls `invalidateCaches()` (NavigationState fires the bus from its own `didSet`).

### Phase 3 — Decompose AppCoordinator

Phase 0 must be complete; without tests this is too dangerous.

Target shape:

- `AppCoordinator` shrinks to lifecycle wiring + composition (≤200 LOC).
- Behaviour moves to dedicated services consumed by views directly via `@Environment` / `@Observable`:
  - `TaskMutationService` ← `+TaskMutations`, `+QuickAdd`, `+Undo` (one undo stack, owned here). **Done (steps 3.2 + 3.4):**
    - **Undo half (step 3.2):** split out into `Bar Tasker/UndoService.swift` (owns `lastAction` and the rewind switch, replacing the misplaced `TaskRepository.lastUndo` slot). Depends on the new `UndoActionPerforming` protocol rather than `AppCoordinator` directly, which let it move into `BarTaskerAppLogic` — `applogic-tests/UndoServiceTests.swift` covers record/clear and the rewind dispatch for every `UndoableAction` case (10 new tests). `+Undo.swift` is deleted.
    - **Mutation half (step 3.4):** new `Bar Tasker/TaskMutationService.swift` owns mark-done / reopen / invalidate / `taskAction`, `updateTask`, `addTask`, `addTaskAsChild`, `deleteTask`, `createNextOccurrence`, and the QuickAdd flow (`beginQuickAddEntry`, `setQuickAddSpecificLocationToCurrentTask`, `submitQuickAddTask`). `+TaskMutations.swift` and `+QuickAdd.swift` are forwarding shims; the recurrence convenience accessors (`recurrenceRule(for:)`, `setRecurrenceRule`, `clearRecurrenceRule`) stay in `+TaskMutations.swift` since they're already one-liners over `recurrence`.
    - **App-only, not promoted to AppLogic.** `markCurrentTaskDone` drives `NSHapticFeedbackManager` and `withAnimation`, and the rest of the service touches ~15 coordinator-owned helpers (`fetchTopTask`, `subtreeBlockRange`, `isDescendant`, `clampSelectionToVisibleRange`, `presentOnboardingDialogIfNeeded`, `setAuthenticationRequiredErrorIfNeeded`, `reconcilePendingObsidianSyncQueueWithOpenTasks`, `removeTasksFromPriorityQueue`, `savePriorityQueue`, `beginLoading` / `endLoading`, `currentTask`, `currentParentId`, `currentLevelTasks`, `quickAddSpecificParentTaskIdValue`, `activeCredentials`). Backfilling `taskAction` tests in `BarTaskerAppLogic` therefore needs a separate refactor that abstracts haptics + animation behind a protocol and breaks the coordinator dependency surface — call out as future work.
    - AppCoordinator still exposes the original method names as forwarding shims so existing keybindings, `CommandExecutor`, and view call sites keep working — those move in the forwarding cull.
  - `TaskNavigationService` ← `+Navigation`, `+TaskScoping`. **Partly done (step 3.3):** new `Bar Tasker/TaskNavigationService.swift` owns the navigation actions (next/prev, enter/exit, navigate-to, clamp) and the four root-task view-switch operations (`setRootTaskView`, `cycleRootTaskView`, `cycleRootScopeFilter`, `selectRootScopeFilter`), wrapping the pure-logic `TaskNavigationCoordinator` struct. `+Navigation.swift` is now a forwarding shim; the four moved methods in `+TaskScoping.swift` are forwarders too. `TaskRepository.navigationCoordinator` is gone — the service holds its own logic instance. **Not yet moved out of `+TaskScoping.swift`:** the connection-state derivations (`hasCredentials`, `canAttemptLogin`, `checkvistConnectionState`, `canSyncRemotely`), priority-on-current-task mutations (`setPriorityForCurrentTask` etc.), plugin/MCP view-helpers, and the cache/badge accessors. Those belong to later steps (`SyncService`, `TaskMutationService`) or to view-side cleanup.
  - `SyncService` ← `+TaskSync`, `+ReorderingAndTiming` reorder-flush logic. **Done (step 3.5):** new `Bar Tasker/SyncService.swift` owns the network-facing surface — login, `fetchTopTask`, list management (`fetchLists`, `loadCheckvistLists`, `switchCheckvistList`, `createCheckvistListAndSwitch`, `mergeOpenTasksBetweenLists`, `selectList`, `uploadOfflineTasksToCheckvist`), the offline-mutation flush, and the reorder/move surface (`moveTask` + per-view strategies, the reorder queue lifecycle, `indentTask`, `unindentTask`). `+TaskSync.swift` is now a 45-line forwarding shim. `+ReorderingAndTiming.swift` is a mixed file: forwarders for the reorder/indent surface, plus the helpers that *didn't* move because other services still call them through the coordinator (`subtreeBlockRange`, the timer/cache roll-up accessors, `executeCommandInput`, the date-resolver helpers). Renaming or splitting that residual file belongs to the post-cull cleanup.
  - `LifecycleController` ← `+StateAndLifecycle` setup/teardown. **Done (step 3.1):** new `Bar Tasker/LifecycleController.swift` owns the cache-bus subscription, repository/manager-callback wiring, and the network-monitor lifecycle. AppCoordinator constructs it in `init` and calls `lifecycle.start()`; `reachabilityMonitor` stays on AppCoordinator so the nonisolated `deinit` can stop it without an actor hop. The four other concerns previously crammed into `+StateAndLifecycle.swift` (priority-queue forwarding, loading helpers, keychain bootstrap, onboarding dialogs) remain in that extension for now — they belong to later services in this phase.
- ~~Forwarding properties on `AppCoordinator` are deleted; views read from the relevant service directly.~~ **Method forwarders culled (step 3.6).** Property forwarders (`tasks`, `currentParentId`, `currentSiblingIndex`, `rootScopeFocusLevel`, `listId`, `errorMessage`, `hideFuture`, `showChildrenInMenus`, `rootTaskView`, `selectedRootDueBucketRawValue`, `selectedRootTag`, `username`, `remoteKey`, `availableLists`, `isLoading`, `taskEisenhowerLevels`, `cache`, `activeCredentials`) are **deferred**: ~600 mechanical edits across ~15 files for what is, in this form, just a rephrasing of the same coupling (`manager.X` → `manager.subobj.X` still routes through the god object). The real architectural win — views taking `repository`/`navigationState`/services as separate `@Environment` objects — is bigger than a rename and belongs alongside the Phase-4 view splits. Three setters (`rootTaskView`, `selectedRootDueBucketRawValue`, `selectedRootTag`) also have persistence side-effects that would need to move into `TaskListViewModel`'s `didSet`s first; that's the gating piece of work when this is picked up again.
- ~~Remove the `AppCoordinator+*.swift` extension pattern entirely~~ — **Partially done.** Five extension files are gone (`+Navigation`, `+TaskSync`, `+TaskMutations`, `+QuickAdd`, `+Undo`). Three remain (`+ReorderingAndTiming`, `+StateAndLifecycle`, `+TaskScoping`) holding helpers that other services still reach through the coordinator (`subtreeBlockRange`, timer/cache roll-ups, command/date helpers, priority-queue forwarding, loading bracket, keychain bootstrap, onboarding dialogs, connection-state derivations, priority-on-current-task mutations). They'll get further trimming when the property cull / `@Environment` migration runs.

### Phase 3 outcome (step 3.6 — method forwarder cull)

After Layers 1–4 of the cull every method forwarder pointing at a new service is gone:
- `manager.lastUndo` / `undoLastAction()` → `manager.undoService.lastAction` / `.undo()`
- `manager.nextTask()` / `previousTask()` / `enterChildren()` / `exitToParent()` / `navigateTo(task:)` / `clampSelectionToVisibleRange()` → `manager.taskNavigationService.X` (with `navigateTo(task:)` → `navigate(to:)`)
- `manager.setRootTaskView(_:)` / `cycleRootTaskView(direction:)` / `cycleRootScopeFilter(direction:)` / `selectRootScopeFilter(at:)` → `manager.taskNavigationService.X`
- `manager.markCurrentTaskDone()` / `reopenCurrentTask()` / `invalidateCurrentTask()` / `taskAction(_:endpoint:isUndo:)` / `updateTask(...)` / `addTask(...)` / `addTaskAsChild(...)` / `deleteTask(_:isUndo:)` / `createNextOccurrence(for:)` / `beginQuickAddEntry(...)` / `setQuickAddSpecificLocationToCurrentTask()` / `submitQuickAddTask(...)` → `manager.taskMutationService.X`
- `manager.login()` / `fetchTopTask()` / `fetchLists()` / `loadCheckvistLists(...)` / `switchCheckvistList(to:)` / `createCheckvistListAndSwitch(name:)` / `mergeOpenTasksBetweenLists(...)` / `selectList(_:)` / `uploadOfflineTasksToCheckvist(...)` / `flushPendingTaskMutations()` → `manager.syncService.X`
- `manager.moveTask(_:direction:)` / `movePriorityTask(_:direction:)` / `indentTask(_:)` / `unindentTask(_:)` → `manager.syncService.X` (the kanban `moveTask(id:toColumn:)` overload stays on AppCoordinator — it's a real method, not a forwarder)

Wiring side-effect: `UndoActionPerforming` conformance moved from `AppCoordinator` to `TaskMutationService` (which actually owns those methods now). `AppCoordinator.init` constructs `taskMutationService` first, then `UndoService(performer: self.taskMutationService)`.

Internal callers in services also retargeted: `TaskMutationService` calls `coordinator.taskNavigationService.clampSelectionToVisibleRange()` and `coordinator.syncService.fetchTopTask()` directly; `SyncService` calls `coordinator.taskMutationService.updateTask(...)`; `LifecycleController` calls `coordinator.syncService.flushPendingTaskMutations()`; `AppDelegate` calls `checkvistManager.syncService.fetchTopTask()` and `checkvistManager.taskMutationService.beginQuickAddEntry()`.

### Phase 4 — Split oversized views

- [x] `PopoverView.swift` (2,068 LOC) → **done.** Split into the main shell (1,273 LOC) plus two extension files: `PopoverView+TaskRow.swift` (451 LOC — `taskRow`, `dueSectionHeader`, and every badge: timer/priority/matrix/start/recurrence/due/metadata-token, plus `formatTaskContent` and the inline-tag formatter) and `PopoverView+QuickEntryBar.swift` (359 LOC — `quickEntryBar`, the icon/placeholder/font/sequence-hint helpers, and the submit/escape/tab/empty-list-composer actions). `MarqueeTextLine` and several helpers (`themeColor`, `isAddMode`, `activePromptText`, `activePromptTextBinding`, `clearPrompt`, `shouldShowEmptyListComposer`) dropped `private` so the extensions can see them. `breadcrumbPath(for:includeCurrentParent:)` stays in `PopoverView.swift` because both extensions need it. The full plan-vision split (`PopoverHeader`, dedicated `TaskListPane`, separate overlay file) wasn't necessary to clear the lint error limit — those further splits are available if `PopoverView.swift` grows again.
- [x] `SettingsView.swift` (1,473 LOC) → **done.** Main file is now 517 LOC; the four panes live as extensions in their own files: `SettingsView+DebugPane.swift` (19 LOC), `SettingsView+ThemePane.swift` (189 LOC), `SettingsView+KeybindingsPane.swift` (457 LOC), `SettingsView+PreferencesPane.swift` (316 LOC). The pane bodies stay as `var <pane>Pane: some View` on `SettingsView` so `selectedPaneContent` dispatches normally — `@State` properties have to live on the original struct, so they were upgraded from `private` to internal. The plugins pane stays in the main file (it already enumerates plugins generically via `pluginCards` / `userPluginCards`).
- [x] **Plugin status-label convention fix** (called out in `docs/plugins.md`): `SettingsView.pluginStatusLabel(for:)` had a switch on plugin identifier (`"native.checkvist.sync"` → `checkvistManager.checkvistIntegrationEnabled`, etc.). Replaced with a new `sidebarStatusLabel(manager:)` requirement on `PluginSettingsPageProviding` (default = `"Built-in plugin"`); each of the four native plugins overrides it in its `+Settings.swift` to report Enabled/Disabled against its own toggle state. `SettingsView` now calls `page.plugin.sidebarStatusLabel(manager: checkvistManager)` with no plugin-aware branching.
- [ ] `KanbanManager.swift` (778 LOC) → separate column-state ownership from filter/sort logic. **Deferred.** Currently 30 LOC under the SwiftLint warning (`file_length: 800`); no lint pressure. The split is still desirable for testability — pure filter/sort helpers (`subtreeTasks`, `columnForTask`, `taskMatchesCondition`, `sortedForKanban`) want to live in a `KanbanFilter` namespace that takes its inputs as parameters instead of reaching through `dataSource`. Promote when filter logic grows or when adding column tests.

### Phase 5 — MCP isolation (optional, lower priority)

- [ ] Extract `MCPServer` into a separate executable target in `Package.swift`. App invokes it as a child process when `--mcp-server` is passed, or as an out-of-process server. Decouples MCP protocol churn from app release cycle. **Deferred.** The current in-process design works (1042-LOC `MCPServer.swift` with stdin/stdout JSON-RPC) and the change has real user-facing surface: MCP client configurations generated by `NativeMCPIntegrationPlugin.makeClientConfigurationJSON` currently point at `bar-tasker --mcp-server`; extraction would either move that target to a new binary (requiring all installed clients to update their configs) or keep the app as the entry point with a child-process indirection (limited cleanup benefit). Worth picking up when: (a) MCP protocol versions start churning faster than the app's release cadence, or (b) the in-process server starts blocking the main loop / leaking AppCoordinator state.
- [x] **Done (step 5.2):** Promoted the canonical Checkvist data types (`CheckvistNote`, `CheckvistTask`, `CheckvistList`, plus the freshly-extracted `CheckvistTaskCachePayload`, `CheckvistSessionError`, `ObsidianOpenMode`) into `BarTaskerPlugins` sources by un-excluding `CheckvistModels.swift` and splitting `CheckvistTaskCachePayload` / `CheckvistSessionError` / `ObsidianOpenMode` into focused files under their plugin folders. Removed the six duplicate type definitions from `plugin-tests-support/PluginModelStubs.swift`; what remains there is the four genuine app-service fakes (`ObsidianSyncService`, `CheckvistSession`, `CheckvistTaskRepository`, `GoogleOAuthLoopbackReceiver`) the plugin code reaches into directly — the file header now describes that accurately.

  Also marked `CheckvistModels.swift`'s two static date-formatter arrays `nonisolated(unsafe)` (they were fine in the Xcode build but tripped SPM's strict concurrency check once the file landed in the plugin target).

  **Not done (separate concern):**
  - `applogic-support/AppLogicSharedTypes.swift` still re-declares the Checkvist types for `BarTaskerAppLogic`. Sharing them via `import BarTaskerPlugins` would require turning every imported type (`Plugin`, `CheckvistSyncPlugin`, `CheckvistTask` and friends) `public` — that meaningfully broadens the plugin library's API surface and is left as follow-on work.
  - The four service fakes in `PluginModelStubs.swift` still exist because the plugin code references the concrete service types (`ObsidianSyncService`, `CheckvistSession`, etc.) directly. Eliminating those requires introducing protocol seams for those services first — a structural refactor outside Phase 5.2's documented scope.

## Out of Scope

- Replacing `@Observable` / SwiftUI patterns. The concurrency model (`@MainActor` everywhere, async/await for I/O) is sound; don't churn it.
- `FocusCore/` package — sibling, unrelated, leave alone.
- SwiftLint config relaxation. The 1,500-LOC error limit is the *constraint*, not the problem; raising it would mask Phase 4.

## How to use this document

- When opening a PR that lands part of a phase, check the box and link the PR.
- When a finding turns out to be wrong or stale, edit the Findings section — don't leave drift between this doc and the code.
- New architectural problems get appended to Findings with a file:line citation; only promote to a phase once the fix is scoped.
