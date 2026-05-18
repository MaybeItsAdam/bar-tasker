import Foundation

extension AppCoordinator {
  var hasCredentials: Bool {
    !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !remoteKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var canAttemptLogin: Bool {
    hasCredentials
  }

  var checkvistConnectionState: CheckvistConnectionState {
    if !hasCredentials { return .disconnected }
    if availableLists.isEmpty {
      return isLoading ? .connecting : .awaitingConnect
    }
    return .connected(listCount: availableLists.count)
  }

  var hasListSelection: Bool {
    !listId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
      credentials: activeCredentials,
      listId: listId,
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
    tasks.filter { ($0.parentId ?? 0) == currentParentId }
  }

  var currentTask: CheckvistTask? {
    if rootTaskView == .kanban {
      return kanban.currentKanbanTask
    }
    let level = visibleTasks
    guard !level.isEmpty else { return nil }
    let clampedIndex = min(max(currentSiblingIndex, 0), level.count - 1)
    return level[clampedIndex]
  }

  var currentTaskText: String { currentTask?.content ?? "" }

  /// Breadcrumb chain from root down to (but not including) current task
  var breadcrumbs: [CheckvistTask] {
    taskListViewModel.ensureVisibleTasksCacheValid()
    var result: [CheckvistTask] = []
    var parentId = currentParentId
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
    return tasks.filter { ($0.parentId ?? 0) == task.id }
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

  var isRootLevel: Bool { currentParentId == 0 }

  var shouldShowRootScopeSection: Bool { !needsInitialSetup && !isSearchFilterActive }
  var rootScopeShowsFilterControls: Bool {
    guard shouldShowRootScopeSection && isRootLevel else { return false }
    switch rootTaskView {
    case .due, .tags:
      return true
    case .all, .priority, .kanban, .eisenhower:
      return false
    }
  }

  var selectedRootDueBucket: RootDueBucket? {
    get { RootDueBucket(rawValue: selectedRootDueBucketRawValue) }
    set { selectedRootDueBucketRawValue = newValue?.rawValue ?? -1 }
  }

  func shouldShowBreadcrumbPath(for task: CheckvistTask) -> Bool {
    let pid = task.parentId ?? 0
    if isRootLevel && shouldShowRootScopeSection && rootTaskView != .all {
      return pid != 0
    }
    if isSearchFilterActive {
      return pid != currentParentId
    }
    if preferences.showTaskBreadcrumbContext {
      return pid != 0
    }
    return false
  }

  func rootDueSectionHeader(atVisibleIndex index: Int, visibleTasks: [CheckvistTask]) -> String? {
    guard shouldShowDueSectionHeaders, visibleTasks.indices.contains(index) else { return nil }
    // Due-bucket section headers only apply to the matching portion of the list.
    // Remainder tasks get their own header via `remainderSectionHeader`.
    if let remainderStart = remainderStartIndex, index >= remainderStart { return nil }
    let currentBucket = rootDueBucket(for: visibleTasks[index])
    if index == 0 { return currentBucket.title }
    let previousBucket = rootDueBucket(for: visibleTasks[index - 1])
    return previousBucket == currentBucket ? nil : currentBucket.title
  }

  /// Exposes the boundary (if any) at which non-matching "remainder" tasks begin
  /// within `visibleTasks`. Computed by `TaskVisibilityEngine` for due/tags/priority
  /// root views.
  var remainderStartIndex: Int? {
    taskListViewModel.ensureVisibleTasksCacheValid()
    return taskListViewModel.cache.remainderStartIndex
  }

  /// Returns the header title to display just before the task at the given index, or
  /// nil when no remainder header belongs there. Only the boundary index produces a
  /// header. Other tasks return nil.
  func remainderSectionHeader(atVisibleIndex index: Int) -> String? {
    guard let start = remainderStartIndex, index == start else { return nil }
    switch rootTaskView {
    case .due:
      return start == 0 ? "All tasks" : "Other tasks"
    case .tags:
      return start == 0 ? "Untagged" : "Other tasks"
    case .priority:
      return start == 0 ? "Unprioritised" : "Other tasks"
    case .all, .kanban, .eisenhower:
      return nil
    }
  }

  func rootDueSectionCount(in visibleTasks: [CheckvistTask]) -> Int {
    guard shouldShowDueSectionHeaders, !visibleTasks.isEmpty else { return 0 }
    var total = 0
    var previousBucket: RootDueBucket?
    for task in visibleTasks {
      let bucket = rootDueBucket(for: task)
      if bucket != previousBucket {
        total += 1
        previousBucket = bucket
      }
    }
    return total
  }

  func rootLevelTagNames(limit: Int = 8) -> [String] {
    taskListViewModel.ensureVisibleTasksCacheValid()
    return Array(taskListViewModel.cache.rootLevelTagNames.prefix(limit))
  }

  func priorityRank(for task: CheckvistTask) -> Int? {
    taskListViewModel.ensureVisibleTasksCacheValid()
    return taskListViewModel.cache.priorityRank[task.id]
  }

  func absolutePriorityRank(for task: CheckvistTask) -> Int? {
    taskListViewModel.ensureVisibleTasksCacheValid()
    return taskListViewModel.cache.absolutePriorityRank[task.id]
  }

  func priorityPath(for task: CheckvistTask) -> String? {
    taskListViewModel.ensureVisibleTasksCacheValid()
    return taskListViewModel.cache.priorityPath[task.id]
  }

  func priorityBadgeLabel(for task: CheckvistTask) -> String? {
    if let absolute = absolutePriorityRank(for: task) {
      return "A\(absolute)"
    }
    if let scoped = priorityPath(for: task) {
      return "P\(scoped)"
    }
    return nil
  }

  func eisenhowerBadgeLabel(for task: CheckvistTask) -> String? {
    guard let level = repository.taskEisenhowerLevels[task.id],
      level.urgency != 0 || level.importance != 0
    else { return nil }
    return "M(\(formatEisenhowerCoordinate(level.urgency)),\(formatEisenhowerCoordinate(level.importance)))"
  }

  private func formatEisenhowerCoordinate(_ value: Double) -> String {
    if value.rounded() == value {
      return String(Int(value))
    }
    return String(format: "%.1f", value)
  }

  var isSearchFilterActive: Bool { quickEntry.isSearchFilterActive }

  var shouldShowDueSectionHeaders: Bool {
    isRootLevel && shouldShowRootScopeSection && rootTaskView == .due
      && selectedRootDueBucket == nil
  }

  private func hasAnyTag(_ task: CheckvistTask) -> Bool {
    taskListViewModel.cache.tagsByTaskId[task.id] != nil
  }

  private func hasTag(_ task: CheckvistTask, tag: String) -> Bool {
    guard let tags = taskListViewModel.cache.tagsByTaskId[task.id] else { return false }
    let normalized: String
    if tag.hasPrefix("#") || tag.hasPrefix("@") {
      normalized = tag.lowercased()
    } else {
      normalized = "#\(tag.lowercased())"
    }
    return tags.contains(normalized)
  }

  private func taskMatchesActiveRootScope(_ task: CheckvistTask) -> Bool {
    switch rootTaskView {
    case .all:
      return true
    case .due:
      if let selectedRootDueBucket {
        return rootDueBucket(for: task) == selectedRootDueBucket
      }
      return rootDueBucket(for: task) != .noDueDate
    case .tags:
      if selectedRootTag.isEmpty {
        return hasAnyTag(task)
      }
      return hasTag(task, tag: selectedRootTag)
    case .priority:
      return absolutePriorityRank(for: task) != nil || priorityRank(for: task) != nil
    case .kanban:
      return true
    case .eisenhower:
      return true
    }
  }

  func rootDueBucket(for task: CheckvistTask) -> RootDueBucket {
    if let cached = taskListViewModel.cache.rootDueBucket[task.id] { return cached }
    return TaskFilterEngine.classifyDueBucket(task: task)
  }


  @MainActor func setPriorityForCurrentTask(_ rank: Int) {
    guard rank >= 1, let task = currentTask else { return }

    let scopeId = task.parentId ?? 0
    var byParent = repository.priorityTaskIdsByParentId
    // Remove this task from any existing scope it may have previously lived in.
    for (pid, ids) in byParent {
      let filtered = ids.filter { $0 != task.id }
      if filtered.count != ids.count {
        if filtered.isEmpty { byParent.removeValue(forKey: pid) }
        else { byParent[pid] = filtered }
      }
    }
    var scope = byParent[scopeId] ?? []
    let insertIndex = min(max(rank - 1, 0), scope.count)
    scope.insert(task.id, at: insertIndex)
    byParent[scopeId] = scope
    savePriorityQueue(byParent)
    errorMessage = nil

    if let newIndex = visibleTasks.firstIndex(where: { $0.id == task.id }) {
      currentSiblingIndex = newIndex
    }
  }

  @MainActor func setAbsolutePriorityForCurrentTask(_ rank: Int) {
    guard rank >= 1, let task = currentTask else { return }
    repository.setAbsolutePriority(taskId: task.id, rank: rank)
    errorMessage = nil

    if let newIndex = visibleTasks.firstIndex(where: { $0.id == task.id }) {
      currentSiblingIndex = newIndex
    }
  }

  @MainActor func sendCurrentTaskToPriorityBack() {
    guard let task = currentTask else { return }

    let scopeId = task.parentId ?? 0
    var byParent = repository.priorityTaskIdsByParentId
    for (pid, ids) in byParent {
      let filtered = ids.filter { $0 != task.id }
      if filtered.count != ids.count {
        if filtered.isEmpty { byParent.removeValue(forKey: pid) }
        else { byParent[pid] = filtered }
      }
    }
    var scope = byParent[scopeId] ?? []
    scope.append(task.id)
    byParent[scopeId] = scope
    savePriorityQueue(byParent)
    errorMessage = nil

    if let newIndex = visibleTasks.firstIndex(where: { $0.id == task.id }) {
      currentSiblingIndex = newIndex
    }
  }

  @MainActor func clearPriorityForCurrentTask() {
    guard let task = currentTask else { return }
    guard repository.prioritizedTaskIds.contains(task.id) else { return }
    var byParent = repository.priorityTaskIdsByParentId
    for (pid, ids) in byParent {
      let filtered = ids.filter { $0 != task.id }
      if filtered.count != ids.count {
        if filtered.isEmpty { byParent.removeValue(forKey: pid) }
        else { byParent[pid] = filtered }
      }
    }
    savePriorityQueue(byParent)
    errorMessage = nil

    if let newIndex = visibleTasks.firstIndex(where: { $0.id == task.id }) {
      currentSiblingIndex = newIndex
    } else {
      taskNavigationService.clampSelectionToVisibleRange()
    }
  }

  @MainActor func clearAbsolutePriorityForCurrentTask() {
    guard let task = currentTask else { return }
    guard repository.absolutePrioritizedTaskIds.contains(task.id) else { return }
    repository.clearAbsolutePriority(taskId: task.id)
    errorMessage = nil

    if let newIndex = visibleTasks.firstIndex(where: { $0.id == task.id }) {
      currentSiblingIndex = newIndex
    } else {
      taskNavigationService.clampSelectionToVisibleRange()
    }
  }

  /// Returns true if task is a descendant of the given parentId (or IS at that level)
  func isDescendant(_ task: CheckvistTask, of rootId: Int) -> Bool {
    TaskFilterEngine.isDescendant(task, of: rootId, taskById: taskListViewModel.cache.taskById)
  }

  func invalidateCaches() {
    taskListViewModel.invalidateCaches()
  }

  func ensureVisibleTasksCacheValid() {
    taskListViewModel.ensureVisibleTasksCacheValid()
  }


}