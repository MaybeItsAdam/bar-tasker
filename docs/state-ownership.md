# State Ownership Map

> Navigation reference for "where does this piece of state actually live, who derives
> from it, and what happens when it changes." Written to cut through the
> `AppCoordinator` forwarding layer — many properties you reach through
> `AppCoordinator` are getters/setters into one of the objects below.
>
> Keep this current when state moves between owners (it's the thing the Phase-3
> decomposition in `ARCHITECTURE_IMPROVEMENT_PLAN.md` is gradually making true).

## The data-flow spine (read this first)

```
 raw truth                         fan-out            derived view              UI
┌────────────────────┐         ┌──────────────┐   ┌──────────────────┐   ┌───────────┐
│ TaskRepository      │ didSet  │ Cache        │   │ TaskListViewModel │   │ SwiftUI   │
│ NavigationState     │────────▶│ Invalidation │──▶│ .cache (CacheState)│─▶│ views     │
│ + feature managers  │ .invalidate()  Bus     │   │ rebuilt lazily    │   │ (@Observable)
└────────────────────┘         └──────────────┘   └──────────────────┘   └───────────┘
```

1. A cache-relevant `var` changes on a producer → its `didSet` calls `cacheInvalidationBus.invalidate()`.
2. The bus (`CacheInvalidationBus.swift`) fans out to its one subscriber: `AppCoordinator`
   (registered in `LifecycleController`), which calls `TaskListViewModel.invalidateCaches()`.
3. `TaskListViewModel.ensureVisibleTasksCacheValid()` rebuilds the *entire* derived cache
   (visible tasks, tag index, due buckets, priority ranks, rolled-up timer elapsed) from the
   raw state, delegating math to the pure engines (`TaskVisibilityEngine`, `TaskFilterEngine`,
   `TimerStore`).
4. Views observe and re-render.

Invalidation is coarse: any producer change marks the whole cache dirty and triggers a full
rebuild. Fine for menu-bar-sized lists; not granular.

## Owners

### `TaskRepository` — the source of truth for tasks, auth, lists
Raw state (each cache-relevant `var` fires the bus from `didSet`):

| State | Fires bus | Notes |
|---|---|---|
| `tasks: [CheckvistTask]` | ✓ | the list itself |
| `availableLists: [CheckvistList]` | ✓ | |
| `priorityTaskIdsByParentId: [Int:[Int]]` | ✓ | per-parent priority queues (0 = root) |
| `absolutePriorityTaskIds: [Int]` | ✓ | global absolute-priority queue |
| `taskEisenhowerLevels: [Int:EisenhowerLevel]` | ✓ | |
| `checkvistIntegrationEnabled: Bool` | ✓ | also persists + fires `onCheckvistIntegrationEnabledChanged` |
| `isNetworkReachable: Bool` | ✓ | offline↔online transitions |
| `username` / `remoteKey` / `listId` | — | persist to prefs + fire `onUsernameChanged`/`onRemoteKeyChanged`/`onListIdChanged`; `listId` also reloads priority/eisenhower queues |
| `isLoading` / `errorMessage` | — | UI status, not cache-relevant |
| `pendingTaskMutations/Creates/Actions/Deletes` | — | `@ObservationIgnored` offline replay queues; write-through to `PendingOfflineWorkStore` via the `enqueuePending*` helpers |

Derived (don't re-derive these elsewhere — Finding 3/4 in the plan):
`hasCredentials`, `canAttemptLogin`, `hasListSelection`, **`canSyncRemotely`** (the single
source of truth for online vs. offline routing), `activeCredentials`, **`activeSyncPlugin`**
(returns Checkvist plugin or `OfflineTaskSyncPlugin` — callers never branch on online/offline
themselves), `prioritizedTaskIds`, `absolutePrioritizedTaskIds`, `hasPendingOfflineWork`,
`offlineOpenTaskCount`.

### `NavigationState` — where the user is in the tree
| State | Fires bus |
|---|---|
| `currentParentId: Int` | ✓ |
| `currentSiblingIndex: Int` | — |
| `rootScopeFocusLevel: Int` | — |
| `isPopoverVisible: Bool` | — |

### `TaskListViewModel` — the derived view + the view-shaping toggles
Owns the toggles that shape what's visible, *and* the rebuilt `cache`. These `didSet`s call
`invalidateCaches()` **directly** (not via the bus — the VM is the bus's consumer):
`hideFuture`, `rootTaskView`, `selectedRootDueBucketRawValue`, `selectedRootTag`,
`showChildrenInMenus`. `cache: CacheState` is `@ObservationIgnored` and rebuilt by
`ensureVisibleTasksCacheValid()`.

Also owns the cache-derived view helpers consolidated here in step 3.7d (they read the
`cache` directly rather than forwarding through `AppCoordinator`): `priorityBadgeLabel` /
`eisenhowerBadgeLabel` / `priorityRank` / `absolutePriorityRank` / `priorityPath`,
`rootDueBucket`, `rootDueSectionHeader` / `remainderSectionHeader` / `rootDueSectionCount` /
`remainderStartIndex`, `rootLevelTagNames`, and `isDescendant`. Views read these via
`@Environment(TaskListViewModel.self)`.


### Feature managers (each owns its slice + persists to `PreferencesStore`)
| Manager | Owns | Cache-relevant |
|---|---|---|
| `TimerManager` | `timedTaskId`, `timerByTaskId`, `timerRunning`; `timerMode`/`timerBarLeading` (prefs-backed) | `timerByTaskId` feeds rolled-up elapsed in the cache |
| `KanbanManager` | `kanbanColumns`, `kanbanFocusedColumnIndex`, `kanbanSelectedTaskId`, `kanbanFilterSubtasks`, `kanbanFilterParentId`, `addingToColumnId`, `addText`, `manualOrderByColumnId` | reads tasks/cache via `dataSource` (the coordinator) |
| `QuickEntryManager` | `searchText` (fires bus), `quickEntryText`, `quickEntryMode`, `isQuickEntryFocused`, `editCursorAtEnd`, `pendingDeleteConfirmation`, `completingTaskId`, `commandSuggestionIndex`, `keyBuffer` | `searchText`/mode drive `isSearchFilterActive` → visibility |
| `FocusSessionManager` | `promptTaskId`, `session`, `phase`, `durationMinutes`, `breakDurationMinutes`, `lastFocusedTaskId` | drives focus alerts; pauses timer via `onFocusBlockEnded` |
| `StartDateManager` | `taskStartDatesByTaskId` | yes (affects `hideFuture` visibility) |
| `RecurrenceManager` | `recurrenceRulesByTaskId` | no (consulted on completion) |
| `PreferencesManager` | all prefs-backed settings: theme, hotkeys, shortcuts, named-time hours, `confirmBeforeDelete`, `launchAtLogin`, `maxTitleWidth`, etc. | no |
| `IntegrationCoordinator` | `obsidian/googleCalendar/mcpIntegrationEnabled`, `obsidianInboxPath`, `mcpServerCommandPath`, `pendingObsidianSyncTaskIds`, `googleCalendarEventLinksByTaskKey` | reads tasks/listId/currentTask/credentials via `dataSource` |

### `AppCoordinator` — genuinely owns (everything else is forwarding)
`statusMessage` (auto-clears after 3s), `onboardingCompleted`, `activeOnboardingDialog`,
`dismissedOnboardingDialogs`, `isApplyingLaunchAtLoginChange`, `orderedRootTaskViews`
(stored directly in `UserDefaults`), and the extracted **services**: `taskNavigationService`,
`taskMutationService`, `syncService`, `undoService`, `lifecycle`, plus `commandExecutor` and
`reachabilityMonitor`.

The Phase-3 forwarder cull is finished: `AppCoordinator` no longer re-exposes
`tasks` / `currentParentId` / `hideFuture` / `username` / `listId` / `availableLists` /
`cache` / `activeCredentials` / `errorMessage` / `isLoading` / `remoteKey` /
`taskEisenhowerLevels` etc. Read those directly from their owner: views via
`@Environment(TaskRepository.self)` / `@Environment(NavigationState.self)` /
`@Environment(TaskListViewModel.self)`; non-view callers via `manager.repository.X` /
`manager.navigationState.X` / `manager.taskListViewModel.X`. The Phase-3 services
(`SyncService`, `TaskMutationService`, `TaskNavigationService`) all take a strong
`TaskRepository` reference in their initializers and read auth/list state from there
directly — no coordinator forwarder hop.

## Cache-invalidation producer list (who fires the bus)

`TaskRepository` (`tasks`, `availableLists`, `priorityTaskIdsByParentId`,
`absolutePriorityTaskIds`, `taskEisenhowerLevels`, `checkvistIntegrationEnabled`,
`isNetworkReachable`), `NavigationState` (`currentParentId`), `QuickEntryManager`
(`searchText`), `TimerManager` (`timerByTaskId`), `StartDateManager` (`taskStartDatesByTaskId`),
`KanbanManager`, `FocusSessionManager`. The lone **subscriber** is `AppCoordinator` →
`TaskListViewModel.invalidateCaches()`.

`TaskListViewModel`'s own view-shaping toggles bypass the bus and call `invalidateCaches()`
directly, because the VM *is* the thing the bus ultimately notifies.

## How a mutation flows (worked example: mark current task done)

1. View / keybind → `AppCoordinator.markCurrentTaskDone()` (forwarder) → `TaskMutationService`.
2. Service mutates `repository.tasks` optimistically → `didSet` fires the bus → cache rebuilds → UI updates immediately.
3. Service calls `repository.activeSyncPlugin.performTaskAction(...)` async.
   - Online success: done.
   - Offline / failure: roll back the local mutation **or** stash it in `repository.pendingTask*`
     (write-through to disk). On reconnect, `SyncService.flushPendingTaskMutations()` replays.

This optimistic-then-sync-then-rollback-or-enqueue shape recurs across mutations; see
`AppCoordinator.applyOptimisticMoveAndSync` and the `TaskMutationService` mutation methods.
</content>
</invoke>
