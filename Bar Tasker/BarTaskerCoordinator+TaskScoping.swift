import Foundation

extension BarTaskerCoordinator {
  var hasCredentials: Bool {
    !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !remoteKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var canAttemptLogin: Bool {
    hasCredentials
  }

  var hasListSelection: Bool {
    !listId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var isUsingOfflineStore: Bool { !hasListSelection }

  var offlineOpenTaskCount: Int {
    repository.localTaskStore.load().openTasks.count
  }

  var quickAddSpecificParentTaskIdValue: Int? {
    let raw = preferences.quickAddSpecificParentTaskId.trimmingCharacters(in: .whitespacesAndNewlines)
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
      repository.checkvistSyncPlugin as any BarTaskerPlugin,
      integrations.obsidianPlugin as any BarTaskerPlugin,
      integrations.googleCalendarPlugin as any BarTaskerPlugin,
      integrations.mcpIntegrationPlugin as any BarTaskerPlugin,
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
    ensureVisibleTasksCacheValid()
    var result: [CheckvistTask] = []
    var parentId = currentParentId
    while parentId != 0 {
      if let parent = cache.taskById[parentId] {
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
  /// Cached and recomputed only when inputs change (via `objectWillChange`).
  var visibleTasks: [CheckvistTask] {
    ensureVisibleTasksCacheValid()
    return cache.visibleTasks
  }

  private func computeVisibleTasks() -> [CheckvistTask] {
    BarTaskerTaskVisibilityEngine.computeVisibleTasks(
      in: .init(
        tasks: tasks,
        currentLevelTasks: currentLevelTasks,
        currentParentId: currentParentId,
        isSearchFilterActive: isSearchFilterActive,
        searchText: quickEntry.searchText,
        hideFuture: hideFuture,
        shouldShowRootScopeSection: shouldShowRootScopeSection,
        isRootLevel: isRootLevel,
        rootTaskView: rootTaskView,
        selectedRootDueBucket: selectedRootDueBucket,
        selectedRootTag: selectedRootTag,
        taskById: cache.taskById,
        isDescendant: { [weak self] task, rootId in
          guard let self else { return false }
          return TaskFilterEngine.isDescendant(task, of: rootId, taskById: cache.taskById)
        },
        taskMatchesActiveRootScope: { [weak self] task in
          self?.taskMatchesActiveRootScope(task) ?? false
        },
        compareByPriorityThenPosition: { [weak self] lhs, rhs in
          guard let self else { return false }
          return TaskFilterEngine.compareByPriorityThenPosition(
            lhs, rhs, priorityRankById: cache.priorityRank)
        },
        compareByRootDueBucket: { [weak self] lhs, rhs in
          guard let self else { return false }
          return TaskFilterEngine.compareByRootDueBucket(
            lhs, rhs, rootDueBucketById: cache.rootDueBucket)
        },
        hasAnyTag: { [weak self] task in
          self?.hasAnyTag(task) ?? false
        },
        hasTag: { [weak self] task, tag in
          self?.hasTag(task, tag: tag) ?? false
        },
        rootDueBucket: { [weak self] task in
          self?.rootDueBucket(for: task) ?? .noDueDate
        }
      ))
  }

  var isRootLevel: Bool { currentParentId == 0 }

  var shouldShowRootScopeSection: Bool { !needsInitialSetup && !isSearchFilterActive }
  var rootScopeShowsFilterControls: Bool {
    shouldShowRootScopeSection && isRootLevel
      && (rootTaskView == .due || rootTaskView == .tags || rootTaskView == .kanban)
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
    let currentBucket = rootDueBucket(for: visibleTasks[index])
    if index == 0 { return currentBucket.title }
    let previousBucket = rootDueBucket(for: visibleTasks[index - 1])
    return previousBucket == currentBucket ? nil : currentBucket.title
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
    ensureVisibleTasksCacheValid()
    return Array(cache.rootLevelTagNames.prefix(limit))
  }

  private func computeRootLevelTagNames(limit: Int) -> [String] {
    var counts: [String: Int] = [:]
    for tags in cache.tagsByTaskId.values {
      for tag in tags {
        counts[tag, default: 0] += 1
      }
    }
    return
      counts
      .sorted { lhs, rhs in
        if lhs.value != rhs.value { return lhs.value > rhs.value }
        return lhs.key < rhs.key
      }
      .prefix(limit)
      .map(\.key)
  }

  func priorityRank(for task: CheckvistTask) -> Int? {
    ensureVisibleTasksCacheValid()
    return cache.priorityRank[task.id]
  }

  var isSearchFilterActive: Bool { quickEntry.isSearchFilterActive }

  var shouldShowDueSectionHeaders: Bool {
    isRootLevel && shouldShowRootScopeSection && rootTaskView == .due
      && selectedRootDueBucket == nil
  }

  private func hasAnyTag(_ task: CheckvistTask) -> Bool {
    cache.tagsByTaskId[task.id] != nil
  }

  private func hasTag(_ task: CheckvistTask, tag: String) -> Bool {
    guard let tags = cache.tagsByTaskId[task.id] else { return false }
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
      return priorityRank(for: task) != nil
    case .kanban:
      return true
    }
  }

  func rootDueBucket(for task: CheckvistTask) -> RootDueBucket {
    if let cached = cache.rootDueBucket[task.id] { return cached }
    return TaskFilterEngine.classifyDueBucket(task: task)
  }

  func setRootTaskView(_ view: RootTaskView) {
    rootTaskView = view
    if currentParentId != 0 {
      currentParentId = 0
    }
    currentSiblingIndex = 0
    if view != .due {
      selectedRootDueBucket = nil
    }
    if view != .tags {
      selectedRootTag = ""
    }
    if view != .kanban {
      kanban.kanbanFilterTag = ""
      kanban.kanbanFilterSubtasks = false
      kanban.kanbanFilterParentId = nil
    } else {
      // Clear stale root-scope focus so column navigation works immediately.
      rootScopeFocusLevel = 0
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
    case .all, .priority:
      return
    case .kanban:
      let tags = rootLevelTagNames(limit: 30)
      // options: "all", each tag (tag filter cycling; subtasks toggled separately)
      let options = [""] + tags
      guard let currentIndex = options.firstIndex(of: kanban.kanbanFilterTag) else {
        kanban.kanbanFilterTag = ""
        return
      }
      let nextIndex = max(0, min(options.count - 1, currentIndex + direction))
      kanban.kanbanFilterTag = options[nextIndex]
      if !kanban.kanbanFilterTag.isEmpty { kanban.kanbanFilterSubtasks = false; kanban.kanbanFilterParentId = nil }
      currentSiblingIndex = 0
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
    case .all, .priority:
      return
    case .kanban:
      let tags = rootLevelTagNames(limit: 30)
      let options = [""] + tags
      guard options.indices.contains(index) else { return }
      kanban.kanbanFilterTag = options[index]
      if !kanban.kanbanFilterTag.isEmpty { kanban.kanbanFilterSubtasks = false; kanban.kanbanFilterParentId = nil }
      currentSiblingIndex = 0
      rootScopeFocusLevel = 2
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
    guard (1...TaskRepository.maxPriorityRank).contains(rank), let task = currentTask else { return }

    var updated = repository.priorityTaskIds
    updated.removeAll { $0 == task.id }
    let insertIndex = min(max(rank - 1, 0), updated.count)
    updated.insert(task.id, at: insertIndex)
    if updated.count > TaskRepository.maxPriorityRank {
      updated = Array(updated.prefix(TaskRepository.maxPriorityRank))
    }
    savePriorityQueue(updated)
    errorMessage = nil

    if let newIndex = visibleTasks.firstIndex(where: { $0.id == task.id }) {
      currentSiblingIndex = newIndex
    }
  }

  @MainActor func sendCurrentTaskToPriorityBack() {
    guard let task = currentTask else { return }

    var updated = repository.priorityTaskIds
    let wasPrioritized = updated.contains(task.id)
    updated.removeAll { $0 == task.id }

    if !wasPrioritized && updated.count >= TaskRepository.maxPriorityRank {
      errorMessage = "Priority slots full (1-9). Press 1-9 to replace one."
      return
    }

    updated.append(task.id)
    savePriorityQueue(updated)
    errorMessage = nil

    if let newIndex = visibleTasks.firstIndex(where: { $0.id == task.id }) {
      currentSiblingIndex = newIndex
    }
  }

  @MainActor func clearPriorityForCurrentTask() {
    guard let task = currentTask else { return }
    guard repository.priorityTaskIds.contains(task.id) else { return }
    savePriorityQueue(repository.priorityTaskIds.filter { $0 != task.id })
    errorMessage = nil

    if let newIndex = visibleTasks.firstIndex(where: { $0.id == task.id }) {
      currentSiblingIndex = newIndex
    } else {
      clampSelectionToVisibleRange()
    }
  }

  /// Returns true if task is a descendant of the given parentId (or IS at that level)
  func isDescendant(_ task: CheckvistTask, of rootId: Int) -> Bool {
    TaskFilterEngine.isDescendant(task, of: rootId, taskById: cache.taskById)
  }

  func invalidateCaches() {
    cache.invalidate()
  }

  func ensureVisibleTasksCacheValid() {
    guard cache.dirty, !cache.isRebuilding else { return }
    cache.isRebuilding = true
    defer { cache.isRebuilding = false }
    cache.taskById = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
    cache.tagsByTaskId = TaskFilterEngine.extractTagsByTaskId(tasks: tasks)
    cache.rootDueBucket = TaskFilterEngine.computeRootDueBuckets(tasks: tasks)
    cache.priorityRank = Dictionary(
      uniqueKeysWithValues: repository.priorityTaskIds.enumerated().map { ($1, $0 + 1) })
    cache.dirty = false
    cache.visibleTasks = computeVisibleTasks()
    let nodes = tasks.map { BarTaskerTimerNode(id: $0.id, parentId: $0.parentId) }
    cache.childCount = BarTaskerTimerStore.childCountByTaskId(nodes: nodes)
    cache.rolledUpElapsed = BarTaskerTimerStore.rolledUpElapsedByTaskId(
      nodes: nodes, ownElapsed: timer.timerByTaskId)
    cache.rootLevelTagNames = computeRootLevelTagNames(limit: 30)
  }

}
