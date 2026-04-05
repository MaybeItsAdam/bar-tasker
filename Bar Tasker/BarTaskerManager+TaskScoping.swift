import Foundation

extension BarTaskerManager {
  var hasCredentials: Bool {
    !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !remoteKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var canAttemptLogin: Bool {
    let hasUsername = !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    guard hasUsername else { return false }
    if hasCredentials { return true }
    return usesKeychainStorage
  }

  var hasListSelection: Bool {
    !listId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var isUsingOfflineStore: Bool { !hasListSelection }

  var offlineOpenTaskCount: Int {
    localTaskStore.load().openTasks.count
  }

  var quickAddSpecificParentTaskIdValue: Int? {
    let raw = quickAddSpecificParentTaskId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty, let value = Int(raw), value > 0 else { return nil }
    return value
  }

  var hasResolvedMCPServerCommand: Bool {
    !mcpServerCommandPath.isEmpty
  }

  var mcpClientConfigurationPreview: String {
    mcpIntegrationPlugin.makeClientConfigurationJSON(
      credentials: activeCredentials,
      listId: listId,
      redactSecrets: true
    )
  }

  var activePluginSettingsPages: [any PluginSettingsPageProviding] {
    [
      checkvistSyncPlugin as any BarTaskerPlugin,
      obsidianPlugin as any BarTaskerPlugin,
      googleCalendarPlugin as any BarTaskerPlugin,
      mcpIntegrationPlugin as any BarTaskerPlugin,
    ].compactMap { $0 as? any PluginSettingsPageProviding }
  }

  // Setup is non-blocking: the app can always run in offline-first mode.
  var needsInitialSetup: Bool { false }

  /// Tasks visible at the current level, sorted by position
  var currentLevelTasks: [CheckvistTask] {
    tasks.filter { ($0.parentId ?? 0) == currentParentId }
  }

  var currentTask: CheckvistTask? {
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
        searchText: searchText,
        hideFuture: hideFuture,
        shouldShowRootScopeSection: shouldShowRootScopeSection,
        isRootLevel: isRootLevel,
        rootTaskView: rootTaskView,
        selectedRootDueBucket: selectedRootDueBucket,
        selectedRootTag: selectedRootTag,
        taskById: cache.taskById,
        isDescendant: { [weak self] task, rootId in
          self?.isDescendant(task, of: rootId) ?? false
        },
        taskMatchesActiveRootScope: { [weak self] task in
          self?.taskMatchesActiveRootScope(task) ?? false
        },
        compareByPriorityThenPosition: { [weak self] lhs, rhs in
          self?.compareByPriorityThenPosition(lhs, rhs) ?? false
        },
        compareByRootDueBucket: { [weak self] lhs, rhs in
          self?.compareByRootDueBucket(lhs, rhs) ?? false
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
    if showTaskBreadcrumbContext {
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

  var isSearchFilterActive: Bool { !searchText.isEmpty && quickEntryMode == .search }

  var shouldShowDueSectionHeaders: Bool {
    isRootLevel && shouldShowRootScopeSection && rootTaskView == .due
      && selectedRootDueBucket == nil
  }

  private static let tagRegex: NSRegularExpression = {
    guard let regex = try? NSRegularExpression(pattern: "[@#][a-zA-Z0-9_\\-]+") else {
      fatalError("Failed to build task tag regex.")
    }
    return regex
  }()

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

  private func compareByPositionThenContent(_ lhs: CheckvistTask, _ rhs: CheckvistTask) -> Bool {
    switch (lhs.position, rhs.position) {
    case (.some(let leftPosition), .some(let rightPosition)) where leftPosition != rightPosition:
      return leftPosition < rightPosition
    default:
      break
    }
    return lhs.content.localizedCaseInsensitiveCompare(rhs.content) == .orderedAscending
  }

  private func compareByPriorityThenPosition(_ lhs: CheckvistTask, _ rhs: CheckvistTask) -> Bool {
    let leftPriority = priorityRank(for: lhs)
    let rightPriority = priorityRank(for: rhs)

    if let leftPriority, let rightPriority, leftPriority != rightPriority {
      return leftPriority < rightPriority
    }
    if leftPriority != nil && rightPriority == nil {
      return true
    }
    if leftPriority == nil && rightPriority != nil {
      return false
    }

    return compareByPositionThenContent(lhs, rhs)
  }

  private func compareByRootDueBucket(_ lhs: CheckvistTask, _ rhs: CheckvistTask) -> Bool {
    let leftBucket = rootDueBucket(for: lhs)
    let rightBucket = rootDueBucket(for: rhs)
    if leftBucket != rightBucket {
      return leftBucket.rawValue < rightBucket.rawValue
    }

    switch (lhs.dueDate, rhs.dueDate) {
    case (.some(let leftDate), .some(let rightDate)) where leftDate != rightDate:
      return leftDate < rightDate
    default:
      break
    }

    switch (lhs.position, rhs.position) {
    case (.some(let leftPosition), .some(let rightPosition)) where leftPosition != rightPosition:
      return leftPosition < rightPosition
    default:
      break
    }

    return lhs.content.localizedCaseInsensitiveCompare(rhs.content) == .orderedAscending
  }

  func rootDueBucket(for task: CheckvistTask) -> RootDueBucket {
    // Use pre-computed cache when available (hot path during filtering/sorting).
    if let cached = cache.rootDueBucket[task.id] { return cached }
    return Self.classifyDueBucket(task: task)
  }

  private static func classifyDueBucket(task: CheckvistTask) -> RootDueBucket {
    let dueText = task.due?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    guard !dueText.isEmpty else { return .noDueDate }
    if dueText == "asap" { return .asap }
    guard let dueDate = task.dueDate else { return .future }

    let calendar = Calendar.current
    let now = Date()
    let todayStart = calendar.startOfDay(for: now)
    if dueDate < todayStart { return .overdue }
    if calendar.isDateInToday(dueDate) { return .today }
    if calendar.isDateInTomorrow(dueDate) { return .tomorrow }
    guard let sevenDaysOut = calendar.date(byAdding: .day, value: 8, to: todayStart) else {
      return .future
    }
    if dueDate < sevenDaysOut { return .nextSevenDays }
    return .future
  }

  private static func computeRootDueBuckets(tasks: [CheckvistTask]) -> [Int: RootDueBucket] {
    Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, classifyDueBucket(task: $0)) })
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
      kanbanFilterTag = ""
      kanbanFilterSubtasks = false
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
      guard let currentIndex = options.firstIndex(of: kanbanFilterTag) else {
        kanbanFilterTag = ""
        return
      }
      let nextIndex = max(0, min(options.count - 1, currentIndex + direction))
      kanbanFilterTag = options[nextIndex]
      if !kanbanFilterTag.isEmpty { kanbanFilterSubtasks = false }
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
      kanbanFilterTag = options[index]
      if !kanbanFilterTag.isEmpty { kanbanFilterSubtasks = false }
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
    guard (1...Self.maxPriorityRank).contains(rank), let task = currentTask else { return }

    var updated = priorityTaskIds
    updated.removeAll { $0 == task.id }
    let insertIndex = min(max(rank - 1, 0), updated.count)
    updated.insert(task.id, at: insertIndex)
    if updated.count > Self.maxPriorityRank {
      updated = Array(updated.prefix(Self.maxPriorityRank))
    }
    savePriorityQueue(updated)
    errorMessage = nil

    if let newIndex = visibleTasks.firstIndex(where: { $0.id == task.id }) {
      currentSiblingIndex = newIndex
    }
  }

  @MainActor func sendCurrentTaskToPriorityBack() {
    guard let task = currentTask else { return }

    var updated = priorityTaskIds
    let wasPrioritized = updated.contains(task.id)
    updated.removeAll { $0 == task.id }

    if !wasPrioritized && updated.count >= Self.maxPriorityRank {
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
    guard priorityTaskIds.contains(task.id) else { return }
    savePriorityQueue(priorityTaskIds.filter { $0 != task.id })
    errorMessage = nil

    if let newIndex = visibleTasks.firstIndex(where: { $0.id == task.id }) {
      currentSiblingIndex = newIndex
    } else {
      clampSelectionToVisibleRange()
    }
  }

  /// Returns true if task is a descendant of the given parentId (or IS at that level)
  func isDescendant(_ task: CheckvistTask, of rootId: Int) -> Bool {
    if rootId == 0 { return true }  // root contains everything
    var pid = task.parentId ?? 0
    while pid != 0 {
      if pid == rootId { return true }
      pid = cache.taskById[pid]?.parentId ?? 0
    }
    return false
  }

  func invalidateCaches() {
    cache.invalidate()
  }

  func ensureVisibleTasksCacheValid() {
    guard cache.dirty, !cache.isRebuilding else { return }
    cache.isRebuilding = true
    defer { cache.isRebuilding = false }
    cache.taskById = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
    cache.tagsByTaskId = Self.extractTagsByTaskId(tasks: tasks)
    cache.rootDueBucket = Self.computeRootDueBuckets(tasks: tasks)
    cache.priorityRank = Dictionary(
      uniqueKeysWithValues: priorityTaskIds.enumerated().map { ($1, $0 + 1) })
    cache.dirty = false
    cache.visibleTasks = computeVisibleTasks()
    let nodes = tasks.map { BarTaskerTimerNode(id: $0.id, parentId: $0.parentId) }
    cache.childCount = BarTaskerTimerStore.childCountByTaskId(nodes: nodes)
    cache.rolledUpElapsed = BarTaskerTimerStore.rolledUpElapsedByTaskId(
      nodes: nodes, ownElapsed: timerByTaskId)
    cache.rootLevelTagNames = computeRootLevelTagNames(limit: 30)
  }

  /// Extract all lowercased tags from each task's content in a single pass.
  private static func extractTagsByTaskId(tasks: [CheckvistTask]) -> [Int: [String]] {
    var result: [Int: [String]] = [:]
    for task in tasks {
      let range = NSRange(task.content.startIndex..., in: task.content)
      let matches = tagRegex.matches(in: task.content, range: range)
      guard !matches.isEmpty else { continue }
      result[task.id] = matches.compactMap { match in
        Range(match.range, in: task.content).map { String(task.content[$0]).lowercased() }
      }
    }
    return result
  }
}
