import Foundation

extension AppCoordinator {
  var hasCredentials: Bool {
    !repository.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !repository.remoteKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var canAttemptLogin: Bool {
    hasCredentials
  }

  var checkvistConnectionState: CheckvistConnectionState {
    if !hasCredentials { return .disconnected }
    if repository.availableLists.isEmpty {
      return repository.isLoading ? .connecting : .awaitingConnect
    }
    return .connected(listCount: repository.availableLists.count)
  }

  var hasListSelection: Bool {
    !repository.listId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var canSyncRemotely: Bool { repository.canSyncRemotely }

  var checkvistIntegrationEnabled: Bool {
    get { repository.checkvistIntegrationEnabled }
    set { repository.checkvistIntegrationEnabled = newValue }
  }

  var offlineOpenTaskCount: Int {
    repository.localTaskStore.load().openTasks.count
  }

  var quickAddSpecificParentTaskIdValue: Int? {
    let raw = preferences.quickAddSpecificParentTaskId.trimmingCharacters(
      in: .whitespacesAndNewlines)
    guard !raw.isEmpty, let value = Int(raw), value > 0 else { return nil }
    return value
  }

  var hasResolvedMCPServerCommand: Bool {
    !integrations.mcpServerCommandPath.isEmpty
  }

  var mcpClientConfigurationPreview: String {
    integrations.mcpIntegrationPlugin.makeClientConfigurationJSON(
      credentials: repository.activeCredentials,
      listId: repository.listId,
      redactSecrets: true
    )
  }

  var activePluginSettingsPages: [any PluginSettingsPageProviding] {
    [
      repository.checkvistSyncPlugin as any Plugin,
      integrations.obsidianPlugin as any Plugin,
      integrations.googleCalendarPlugin as any Plugin,
      integrations.mcpIntegrationPlugin as any Plugin,
    ].compactMap { $0 as? any PluginSettingsPageProviding }
  }

  // Setup is non-blocking: the app can always run in offline-first mode.
  var needsInitialSetup: Bool { false }

  /// Tasks visible at the current level, sorted by position
  var currentLevelTasks: [CheckvistTask] {
    repository.tasks.filter { ($0.parentId ?? 0) == navigationState.currentParentId }
  }

  var currentTask: CheckvistTask? {
    if taskListViewModel.rootTaskView == .kanban {
      return kanban.currentKanbanTask
    }
    let level = visibleTasks
    guard !level.isEmpty else { return nil }
    let clampedIndex = min(max(navigationState.currentSiblingIndex, 0), level.count - 1)
    return level[clampedIndex]
  }

  var currentTaskText: String { currentTask?.content ?? "" }

  /// Breadcrumb chain from root down to (but not including) current task
  var breadcrumbs: [CheckvistTask] {
    taskListViewModel.ensureVisibleTasksCacheValid()
    var result: [CheckvistTask] = []
    var parentId = navigationState.currentParentId
    while parentId != 0 {
      if let parent = taskListViewModel.cache.taskById[parentId] {
        result.append(parent)
        parentId = parent.parentId ?? 0
      } else {
        break
      }
    }
    result.reverse()
    return result
  }

  /// Children of the currently focused task
  var currentTaskChildren: [CheckvistTask] {
    guard let task = currentTask else { return [] }
    return repository.tasks.filter { ($0.parentId ?? 0) == task.id }
  }

  /// Visible tasks: searches recursively through subtasks when filter active.
  /// Cached and recomputed only when inputs change.
  /// Touch the observable inputs explicitly so SwiftUI re-subscribes on every
  /// read — the cache is `@ObservationIgnored`, so a body that only reads
  /// `cache.visibleTasks` would lose its observation after the first cache-hit
  /// render and ignore subsequent task mutations.
  var visibleTasks: [CheckvistTask] {
    _ = repository.tasks
    _ = navigationState.currentParentId
    _ = quickEntry.searchText
    _ = quickEntry.quickEntryMode
    _ = taskListViewModel.rootTaskView
    _ = taskListViewModel.selectedRootDueBucketRawValue
    _ = taskListViewModel.selectedRootTag
    _ = taskListViewModel.hideFuture
    _ = taskListViewModel.showChildrenInMenus
    taskListViewModel.ensureVisibleTasksCacheValid()
    return taskListViewModel.cache.visibleTasks
  }

  var isRootLevel: Bool { navigationState.currentParentId == 0 }

  var shouldShowRootScopeSection: Bool { !needsInitialSetup && !isSearchFilterActive }
  var rootScopeShowsFilterControls: Bool {
    guard shouldShowRootScopeSection && isRootLevel else { return false }
    switch taskListViewModel.rootTaskView {
    case .due, .tags:
      return true
    case .all, .priority, .kanban, .eisenhower:
      return false
    }
  }

  func shouldShowBreadcrumbPath(for task: CheckvistTask) -> Bool {
    let pid = task.parentId ?? 0
    if isRootLevel && shouldShowRootScopeSection && taskListViewModel.rootTaskView != .all {
      return pid != 0
    }
    if isSearchFilterActive {
      return pid != navigationState.currentParentId
    }
    if preferences.showTaskBreadcrumbContext {
      return pid != 0
    }
    return false
  }

  var isSearchFilterActive: Bool { quickEntry.isSearchFilterActive }
}