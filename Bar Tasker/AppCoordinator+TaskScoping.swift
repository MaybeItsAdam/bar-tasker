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
    case .kanban:
      // The kanban filter row is only rendered when there are root-level tags.
      // Reporting `false` otherwise keeps the height calc and keyboard nav
      // consistent with the actual rendered chrome.
      return !rootLevelTagNames(limit: 1).isEmpty
    case .all, .priority, .eisenhower:
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

  func setRootTaskView(_ view: RootTaskView) {
    // Capture tree position BEFORE changing rootTaskView — `currentTask` dispatches
    // on `rootTaskView` and would otherwise return the kanban selection, not the
    // task the user had highlighted in the source view.
    let capturedParentId = currentParentId
    let capturedTask = currentTask
    rootTaskView = view
    // Preserve drill-in across view switches. Previously we reset currentParentId
    // to 0 which lost the user's subtask scope whenever they flipped tabs.
    // We also try to keep the same task selected by re-finding it in the new view.
    if let task = capturedTask,
      let newIndex = visibleTasks.firstIndex(where: { $0.id == task.id })
    {
      currentSiblingIndex = newIndex
    } else {
      currentSiblingIndex = 0
    }
    if view != .due {
      selectedRootDueBucket = nil
    }
    if view != .tags {
      selectedRootTag = ""
    }
    if view != .kanban {
      kanban.kanbanFilterSubtasks = false
      kanban.kanbanFilterParentId = nil
    } else {
      // Propagate the user's current tree position into the kanban filter so
      // switching views shows the same scope the user was browsing.
      let inheritedParentId: Int? = capturedParentId == 0 ? nil : capturedParentId
      kanban.kanbanFilterParentId = inheritedParentId
      kanban.kanbanFilterSubtasks = false
      // Seed the kanban selection from the task the user had highlighted.
      if let task = capturedTask {
        kanban.kanbanSelectedTaskId = task.id
      }
      // Ensure a valid selection when entering kanban. Search ALL columns for the
      // selected task — not just the focused column — since the task may have moved
      // to a different column while we were in another view.
      let cols = kanban.kanbanColumns
      var selectionValidInColumn: Int? = nil
      if let selectedId = kanban.kanbanSelectedTaskId {
        for (idx, col) in cols.enumerated() {
          let colTasks = kanban.tasksForKanbanColumn(col, allColumns: cols)
          if colTasks.contains(where: { $0.id == selectedId }) {
            selectionValidInColumn = idx
            break
          }
        }
      }
      if let validIdx = selectionValidInColumn {
        // Task is valid but may be in a different column; update focus to match.
        kanban.kanbanFocusedColumnIndex = validIdx
      } else {
        // Selection is stale — find the first non-empty column and select its first task.
        kanban.kanbanSelectedTaskId = nil
        for (idx, col) in cols.enumerated() {
          let colTasks = kanban.tasksForKanbanColumn(col, allColumns: cols)
          if let firstTask = colTasks.first {
            kanban.kanbanFocusedColumnIndex = idx
            kanban.kanbanSelectedTaskId = firstTask.id
            currentSiblingIndex = 0
            break
          }
        }
      }
    }
    if !(view == .due || view == .tags || view == .kanban), rootScopeFocusLevel > 1 {
      rootScopeFocusLevel = 1
    }
  }

  @MainActor func cycleRootTaskView(direction: Int) {
    let allViews = orderedRootTaskViews
    guard let currentIndex = allViews.firstIndex(of: rootTaskView) else { return }
    let nextIndex = max(0, min(allViews.count - 1, currentIndex + direction))
    guard nextIndex != currentIndex else { return }
    setRootTaskView(allViews[nextIndex])
  }

  @MainActor func cycleRootScopeFilter(direction: Int) {
    guard shouldShowRootScopeSection else { return }
    switch rootTaskView {
    case .all, .priority, .eisenhower, .kanban:
      return
    case .due:
      let options: [RootDueBucket?] = [nil] + RootDueBucket.allCases.filter { $0 != .noDueDate }
      guard let currentIndex = options.firstIndex(where: { $0 == selectedRootDueBucket }) else {
        selectedRootDueBucket = nil
        currentSiblingIndex = 0
        return
      }
      let nextIndex = max(0, min(options.count - 1, currentIndex + direction))
      selectedRootDueBucket = options[nextIndex]
      currentSiblingIndex = 0
    case .tags:
      let tags = rootLevelTagNames(limit: 30)
      let options = [""] + tags
      guard let currentIndex = options.firstIndex(of: selectedRootTag) else {
        selectedRootTag = ""
        currentSiblingIndex = 0
        return
      }
      let nextIndex = max(0, min(options.count - 1, currentIndex + direction))
      selectedRootTag = options[nextIndex]
      currentSiblingIndex = 0
    }
  }

  @MainActor func selectRootScopeFilter(at index: Int) {
    guard shouldShowRootScopeSection else { return }
    guard index >= 0 else { return }
    switch rootTaskView {
    case .all, .priority, .eisenhower, .kanban:
      return
    case .due:
      let options: [RootDueBucket?] = [nil] + RootDueBucket.allCases.filter { $0 != .noDueDate }
      guard options.indices.contains(index) else { return }
      selectedRootDueBucket = options[index]
      currentSiblingIndex = 0
      rootScopeFocusLevel = 2
    case .tags:
      let options = [""] + rootLevelTagNames(limit: 30)
      guard options.indices.contains(index) else { return }
      selectedRootTag = options[index]
      currentSiblingIndex = 0
      rootScopeFocusLevel = 2
    }
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
      clampSelectionToVisibleRange()
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
      clampSelectionToVisibleRange()
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