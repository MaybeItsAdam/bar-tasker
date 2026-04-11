# BarTaskerManager Decomposition Plan

## Context

`BarTaskerManager` is a ~4,900-line god object with 63 `@Published` properties across 11 extension files. It owns authentication, task CRUD, navigation, filtering, kanban, timers, preferences, themes, hotkeys, integrations (Google Calendar, Obsidian, MCP), offline support, recurrence, and UI state — all in one `ObservableObject`. This makes the codebase hard to reason about, test, and extend.

The goal is to decompose it into focused domain managers composed under a thin coordinator, incrementally, keeping the app working at every step.

**Deployment target**: macOS 15.6 — supports `@Observable` (Observation framework).

## Progress Snapshot

- ✅ **Phase 1 complete**: `TimerManager` extracted, timer call sites rewired (`AppDelegate`, command executor, keyboard router, settings, popover), and project build succeeds.
- ✅ **Phase 2 complete**: shortcut/theme behavior moved into `PreferencesManager`, call sites switched to `manager.preferences`, and `BarTaskerManager+PreferencesProxy.swift` removed.
- ✅ **Phase 3 complete**: `KanbanManager` extracted with `KanbanTaskDataSource` protocol, all kanban state/logic moved, `BarTaskerManager+Kanban.swift` deleted, all call sites rewired.
- ✅ **Phase 4 complete**: `RecurrenceManager` and `StartDateManager` extracted, persistence self-contained, coordinator extensions retained for `createNextOccurrence` orchestration and convenience accessors.

---

## Target Architecture

```
BarTaskerCoordinator (@Observable, thin glue)
├── TimerManager           — timer state, elapsed time, display
├── PreferencesManager     — settings, themes, hotkeys, shortcuts, named times
├── KanbanManager          — columns, conditions, movement, sorting
├── RecurrenceManager      — rules, next-occurrence creation helpers
├── StartDateManager       — start dates, display labels
├── IntegrationCoordinator — Google Calendar, Obsidian, MCP managers
├── QuickEntryManager      — quick entry, search, command palette UI state
└── TaskRepository         — tasks, CRUD, offline/online, navigation, undo
```

All managers are `@MainActor`. Cross-cutting operations (e.g. `markDone` → repository + recurrence + timer) live on the coordinator. Domain managers never reference each other — only the coordinator references all of them.

---

## Design Decisions

1. **Stay on `ObservableObject` during extraction (Phases 1-5)**, using `objectWillChange` forwarding from each child manager. Migrate to `@Observable` in Phase 6 after all managers are extracted. This avoids mixing frameworks mid-refactor.

2. **Each manager owns its own persistence** via the shared `BarTaskerPreferencesStore`. This progressively dismantles the 250-line `setupBindings()` monolith.

3. **`fetchTopTask()` stays on the coordinator** — it's inherently cross-cutting (fetches tasks, reconciles priority queues, clamps kanban selection, remaps timer elapsed). After extraction, it delegates to each manager in ~20 lines.

4. **`CommandExecutor` receives the coordinator** and calls `coordinator.timer.toggleTimer()`, `coordinator.kanban.moveTask()`, etc.

5. **Cache stays on the coordinator** (or moves into TaskRepository in Phase 7). The visibility engine already takes a context struct; this extends naturally.

---

## Phase 1: Extract TimerManager (Completed)

**Risk**: Low — self-contained state, no API calls.

**Status**: ✅ Completed

**Create**: `Bar Tasker/Managers/TimerManager.swift`

**Move from BarTaskerManager.swift** (properties):
- `timedTaskId`, `timerByTaskId`, `timerRunning`, `timerBarLeading`, `timerMode`, `timerTask`

**Move from BarTaskerManager+ReorderingAndTiming.swift** (methods):
- `toggleTimerForCurrentTask()`, `pauseTimer()`, `resumeTimer()`, `stopTimer()`

**Move from BarTaskerManager+PreferencesAndShortcuts.swift** (methods):
- `formattedTimer()`, `timerBarString`, `timerIsEnabled`, `timerIsVisible`
- `totalElapsed(forTaskId:)`, `totalElapsed(for:)`, `rolledUpElapsedByTaskId()`

**Move from BarTaskerManager+StateAndLifecycle.swift** (bindings):
- `$timerBarLeading`, `$timerMode`, `$timerByTaskId` sinks

**Wire up**: `let timer = TimerManager(preferencesStore:)` on BarTaskerManager. Forward `timer.objectWillChange` → `self.objectWillChange`. Update all call sites (`self.timedTaskId` → `timer.timedTaskId`).

**Files to update**: `BarTaskerManager.swift`, `BarTaskerManager+ReorderingAndTiming.swift`, `BarTaskerManager+PreferencesAndShortcuts.swift`, `BarTaskerManager+StateAndLifecycle.swift`, `BarTaskerManager+TaskOperations.swift`, `BarTaskerCommandExecutor.swift`, `AppDelegate.swift`, `PopoverView.swift`

---

## Phase 2: Extract PreferencesManager (Completed)

**Risk**: Low — pure settings, no cross-cutting logic. Large property count but zero domain dependencies.

**Create**: `Bar Tasker/Managers/PreferencesManager.swift`

**Status**: ✅ Completed

**Completed so far**:
- `PreferencesManager` exists and owns moved preference properties + persistence bindings.
- `BarTaskerManager` now owns `let preferences = PreferencesManager(...)`.
- `preferences.objectWillChange` forwarding is wired.
- `AppDelegate` subscriptions for theme/max-width/hotkeys now observe `checkvistManager.preferences.$...`.
- Legacy preference sinks were removed from `BarTaskerManager+StateAndLifecycle.swift`.
- Shortcut/theme/export/import behavior methods moved from `BarTaskerManager+PreferencesAndShortcuts.swift` into `PreferencesManager`.
- Direct call sites now use `manager.preferences` for preference-owned APIs.
- Temporary compatibility proxy extension `BarTaskerManager+PreferencesProxy.swift` removed.

**Move** (~25 properties): `confirmBeforeDelete`, `launchAtLogin`, `ignoreKeychainInDebug`, `appTheme`, `themeAccentPreset`, `themeCustomAccentHex`, `themeColorTokenHexOverrides`, `globalHotkeyEnabled/KeyCode/Modifiers`, `quickAddHotkeyEnabled/KeyCode/Modifiers`, `quickAddLocationMode`, `quickAddSpecificParentTaskId`, `customizableShortcutsByAction`, `maxTitleWidth`, `namedTimeMorningHour/AfternoonHour/EveningHour/EodHour`, `showTaskBreadcrumbContext`

**Move methods**: All shortcut customization, all theme methods, `exportThemeJSON`, `importThemeJSON`, color token methods from `PreferencesAndShortcuts.swift`

**Move bindings**: ~30 sink subscriptions from `StateAndLifecycle.swift` (massive reduction)

**Files to update**: `BarTaskerManager.swift`, `BarTaskerManager+StateAndLifecycle.swift`, `BarTaskerManager+PreferencesAndShortcuts.swift` (mostly deleted), `BarTaskerCommandExecutor.swift`, `KeyboardShortcutRouter.swift`, `AppDelegate.swift`, `SettingsView.swift`, `PopoverView.swift`

---

## Phase 3: Extract KanbanManager (Completed)

**Risk**: Medium — depends on task data and cache for column filtering.

**Status**: ✅ Completed

**Create**: `Bar Tasker/Managers/KanbanManager.swift`

**Move** (properties): `kanbanColumns`, `kanbanFocusedColumnIndex`, `kanbanSelectedTaskId`, `kanbanFilterTag`, `kanbanFilterSubtasks`, `kanbanFilterParentId`

**Move** (methods — entire `BarTaskerManager+Kanban.swift`, ~392 lines): `tasksForKanbanColumn`, `columnForTask`, `taskMatchesCondition`, `currentKanbanTask`, `moveCurrentTaskToKanbanColumn`, `focusKanbanColumn`, `nextKanbanTask`, `previousKanbanTask`, `clampKanbanSelection`, `moveTask(id:toColumn:)`, persistence methods

**Design**: KanbanManager receives task/cache data via a `KanbanTaskDataSource` protocol (BarTaskerManager conforms). Move operations return a `KanbanMoveOutcome` enum; the coordinator handles the actual `updateTask` call and error message.

**Completed so far**:
- `KanbanManager` exists and owns all kanban state properties + column persistence bindings.
- `BarTaskerManager` now owns `let kanban = KanbanManager(...)` and conforms to `KanbanTaskDataSource`.
- `kanban.objectWillChange` forwarding is wired.
- All kanban logic (filtering, sorting, column matching, navigation, selection clamping) moved to `KanbanManager`.
- Move operations split: pure computation in `KanbanManager.computeMoveCurrentTask`/`computeMoveTask`, coordinator wrappers `moveCurrentTaskToKanbanColumn`/`moveTask(id:toColumn:)` handle `updateTask` + error.
- `BarTaskerManager+Kanban.swift` deleted.
- All call sites updated: `KanbanBoardView`, `KanbanSettingsView`, `PopoverView`, `KeyboardShortcutRouter`, `BarTaskerManager+TaskOperations`, `BarTaskerManager+TaskScoping`, `BarTaskerManager+StateAndLifecycle`.
- Kanban `$kanbanColumns` persistence sink moved to `KanbanManager.setupBindings()`.
- Cache invalidation publishers updated to observe `kanban.$kanbanColumns`, etc.

**Files updated**: `BarTaskerManager.swift`, `BarTaskerManager+Kanban.swift` (deleted), `BarTaskerManager+TaskOperations.swift`, `BarTaskerManager+TaskScoping.swift`, `BarTaskerManager+StateAndLifecycle.swift`, `KanbanBoardView.swift`, `KanbanSettingsView.swift`, `PopoverView.swift`, `KeyboardShortcutRouter.swift`

---

## Phase 4: Extract RecurrenceManager + StartDateManager (Completed)

**Risk**: Low — small, self-contained.

**Status**: ✅ Completed

**Create**: `Bar Tasker/Managers/RecurrenceManager.swift`, `Bar Tasker/Managers/StartDateManager.swift`

**RecurrenceManager**: `recurrenceRulesByTaskId`, `recurrenceRule(for:)`, `setRecurrenceRule`, `clearRecurrenceRule`, date parsing helpers, `computeNextOccurrence`, `transferRule`. Persistence is self-contained via `$recurrenceRulesByTaskId.sink`. Note: `createNextOccurrence(for:)` **stays on the coordinator** because it calls `addTask` and `updateTask`.

**StartDateManager**: `taskStartDatesByTaskId`, all methods from `BarTaskerManager+StartTime.swift`. `setStartDate` receives a `resolveDueDate` closure from the coordinator for date resolution with named-time preferences. Persistence is self-contained via `$taskStartDatesByTaskId.sink`.

**Completed so far**:
- `RecurrenceManager` exists and owns recurrence rule storage, parsing, validation, and persistence.
- `StartDateManager` exists and owns start date storage, display labels, date parsing, and persistence.
- `BarTaskerManager` now owns `let recurrence = RecurrenceManager(...)` and `let startDates = StartDateManager(...)`.
- `recurrence.objectWillChange` and `startDates.objectWillChange` forwarding is wired.
- `@Published var recurrenceRulesByTaskId` and `@Published var taskStartDatesByTaskId` removed from `BarTaskerManager`.
- `BarTaskerManager+Recurrence.swift` now delegates to `recurrence` for rule CRUD; `createNextOccurrence` remains as coordinator orchestration.
- `BarTaskerManager+StartTime.swift` now delegates to `startDates` for all accessors and mutations.
- Recurrence persistence sink removed from `BarTaskerManager+StateAndLifecycle.swift`.
- Cache invalidation publisher updated to observe `startDates.$taskStartDatesByTaskId`.
- All call sites (`PopoverView`, `BarTaskerCommandExecutor`) continue to work through the convenience methods on the coordinator extensions.

**Files updated**: `BarTaskerManager.swift`, `BarTaskerManager+Recurrence.swift` (rewritten as thin coordinator extension), `BarTaskerManager+StartTime.swift` (rewritten as thin coordinator extension), `BarTaskerManager+StateAndLifecycle.swift`

---

## Phase 5: Extract IntegrationCoordinator + QuickEntryManager (Completed)

**Risk**: Medium — integration code touches `errorMessage`, `tasks`, `listId`.

**Create**: `Bar Tasker/Managers/IntegrationCoordinator.swift`, `Bar Tasker/Managers/QuickEntryManager.swift`

**IntegrationCoordinator**: Absorbs `BarTaskerManager+Integrations.swift`. Holds `obsidianIntegrationEnabled`, `obsidianInboxPath`, `googleCalendarIntegrationEnabled`, `googleCalendarEventLinksByTaskKey`, `mcpIntegrationEnabled`, `mcpServerCommandPath`, `pendingObsidianSyncTaskIds`. Receives plugin references at init. Uses `IntegrationDataSource` protocol for decoupled access to tasks/listId/credentials. Methods return `String?` errors instead of setting `errorMessage` directly.

**QuickEntryManager**: `quickEntryText`, `quickEntryMode`, `isQuickEntryFocused`, `editCursorAtEnd`, `commandSuggestionIndex`, `searchText`, `keyBuffer`, `pendingDeleteConfirmation`, `completingTaskId`. Also: `filteredCommandSuggestions`, selection cycling methods, `isSearchFilterActive` computed property.

**Files updated**: `BarTaskerManager.swift`, `BarTaskerManager+Integrations.swift` (rewritten as thin delegation layer), `BarTaskerManager+PreferencesAndShortcuts.swift`, `BarTaskerManager+StateAndLifecycle.swift`, `BarTaskerManager+TaskOperations.swift`, `BarTaskerManager+TaskScoping.swift`, `BarTaskerCommandExecutor.swift`, `PopoverView.swift`, `KeyboardShortcutRouter.swift`, `KanbanBoardView.swift`, `SettingsView.swift`, plugin settings views

---

## Phase 6: Migrate to @Observable (Completed)

**Risk**: Medium-high (touches every file) but purely mechanical.

1. Convert each domain manager from `class X: ObservableObject` + `@Published` to `@Observable class X` + plain `var`
2. Convert `BarTaskerManager` itself to `@Observable class BarTaskerCoordinator`
3. Remove all `objectWillChange` forwarding
4. Replace Combine persistence sinks with `didSet` property observers:
   ```swift
   var timerBarLeading: Bool = false {
       didSet { preferencesStore.set(timerBarLeading, for: .timerBarLeading) }
   }
   ```
5. In views: `@EnvironmentObject var manager: BarTaskerManager` → `@Environment(BarTaskerCoordinator.self) var coordinator`
6. In `AppDelegate`: `.environmentObject(manager)` → `.environment(coordinator)`
7. Remove `import Combine` where no longer needed
8. Rename `BarTaskerManager` → `BarTaskerCoordinator`

---

## Phase 7: Extract TaskRepository (Completed)

**Risk**: High — core data layer, dual online/offline paths, most cross-cutting. Do last.

**Status**: ✅ Completed

**Completed**:
- `TaskRepository` (`@Observable @MainActor`) created in `Bar Tasker/Managers/TaskRepository.swift`.
- Owns all task data state: `tasks`, `availableLists`, `currentParentId`, `currentSiblingIndex`, `username`, `remoteKey`, `listId`, `isLoading`, `errorMessage`, `lastUndo`, `priorityTaskIds`, `isNetworkReachable`, offline state (`offlineArchivedTasksById`, `nextOfflineTaskIdValue`, `pendingTaskMutations`), and internal state (`loadingOperationCount`, `hasAttemptedRemoteKeyBootstrap`).
- Owns dependencies: `checkvistSyncPlugin`, `localTaskStore`, `navigationCoordinator`, `reorderQueue`, `priorityQueueStore`, `preferencesStore`.
- Owns pure helpers: `rebuiltTask`, `normalizeOfflineTasks`, `archivedOfflineTasks`, `nextOfflineTaskId`, `nextOptimisticTaskId`.
- Owns loading/error helpers: `beginLoading`, `endLoading`, `withLoadingState`, `setAuthenticationRequiredErrorIfNeeded`, `runBooleanMutation`.
- Owns priority queue: `normalizedTaskIdQueue`, `loadPriorityQueue`, `savePriorityQueue`, `removeTasksFromPriorityQueue`, `reconcilePriorityQueueWithOpenTasks`.
- Owns API methods: `login`, `fetchLists`, `loadCheckvistLists`, `selectList`, `copyTasks`.
- `BarTaskerCoordinator` now owns `let repository: TaskRepository` and exposes forwarding computed properties for all moved state (backward-compatible: all views, settings, and extensions work unchanged).
- Coordinator extension methods (TaskOperations, ReorderingAndTiming, TaskScoping) delegate to `repository.*` for moved implementations.
- `KeyboardShortcutRouter` updated: `BarTaskerCoordinator.maxPriorityRank` → `TaskRepository.maxPriorityRank`.
- Cross-cutting `didSet` side-effects on `username`, `remoteKey`, `listId` handled via `repository.onUsernameChanged`, `onRemoteKeyChanged`, `onListIdChanged` callbacks wired in `setupChildCallbacks()`.

**Create**: `Bar Tasker/Managers/TaskRepository.swift`

**Move**: `tasks`, `currentParentId`, `currentSiblingIndex`, `availableLists`, `username`, `remoteKey`, `listId`, `isLoading`, `errorMessage`, `lastUndo`, `priorityTaskIds`, offline state (`offlineArchivedTasksById`, `nextOfflineTaskIdValue`, `pendingTaskMutations`)

**Move methods**: All CRUD from `TaskOperations.swift` (addTask, updateTask, deleteTask, taskAction), navigation (nextTask, previousTask, enterChildren, exitToParent), offline state management (persistOfflineTaskState, normalizeOfflineTasks, offlineStateSnapshot, restoreOfflineState), fetch (fetchTopTask internals)

**Keep on coordinator**: `fetchTopTask()` orchestration wrapper, `markCurrentTaskDone()` orchestration (repository + recurrence + timer + animation)

**Consider**: Extract online/offline into a protocol `TaskSyncProvider` with two implementations, eliminating the `if isUsingOfflineStore` branches scattered through ~15 methods.

---

## Verification

After each phase:
1. **Build** — `xcodebuild build` must succeed with zero errors
2. **Run the app** — verify popover opens, task list loads, navigation works
3. **Test the extracted domain** — e.g. after Phase 1, toggle timer, verify it persists across restart
4. **Test cross-cutting** — e.g. after Phase 3, mark a task done from kanban view, verify it updates

After Phase 6 specifically:
- Verify SwiftUI view updates propagate through nested `@Observable` objects (e.g. changing `coordinator.timer.timerMode` updates the menu bar)
- Verify persistence via `didSet` fires correctly (change a setting, restart, verify it persists)

---

## File Creation Summary

```
Bar Tasker/Managers/
├── TimerManager.swift            (Phase 1)
├── PreferencesManager.swift      (Phase 2)
├── KanbanManager.swift           (Phase 3)
├── RecurrenceManager.swift       (Phase 4)
├── StartDateManager.swift        (Phase 4)
├── IntegrationCoordinator.swift  (Phase 5)
├── QuickEntryManager.swift       (Phase 5)
└── TaskRepository.swift          (Phase 7)
```

## Extension File Fate

| File | Fate |
|------|------|
| `BarTaskerManager+Types.swift` | Kept (type definitions stay, or move to respective managers) |
| `BarTaskerManager+StateAndLifecycle.swift` | Progressively shrinks → deleted in Phase 6 |
| `BarTaskerManager+TaskOperations.swift` | Shrinks phases 1-5 → absorbed into TaskRepository in Phase 7 |
| `BarTaskerManager+TaskScoping.swift` | Stays on coordinator (visibility/cache logic) or moves to TaskRepository |
| `BarTaskerManager+Kanban.swift` | Deleted in Phase 3 |
| `BarTaskerManager+Integrations.swift` | Rewritten as thin delegation layer in Phase 5 |
| `BarTaskerManager+PreferencesAndShortcuts.swift` | Rewritten as thin delegation layer in Phase 5 |
| `BarTaskerManager+PreferencesProxy.swift` | Deleted (Phase 2 complete) |
| `BarTaskerManager+Recurrence.swift` | Rewritten as thin coordinator extension in Phase 4 (orchestration for `createNextOccurrence`) |
| `BarTaskerManager+StartTime.swift` | Rewritten as thin coordinator extension in Phase 4 (convenience accessors) |
| `BarTaskerManager+ReorderingAndTiming.swift` | Timer methods removed in Phase 1, reorder methods stay until Phase 7 |
