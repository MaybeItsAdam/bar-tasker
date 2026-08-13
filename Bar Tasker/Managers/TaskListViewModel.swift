import Foundation
import Observation

@MainActor
@Observable final class TaskListViewModel {
  // MARK: - Dependencies
  @ObservationIgnored private let repository: TaskRepository
  @ObservationIgnored private let navigationState: NavigationState
  @ObservationIgnored private let timer: TimerManager
  @ObservationIgnored private let quickEntry: QuickEntryManager
  @ObservationIgnored private let preferencesStore: PreferencesStore
  @ObservationIgnored private let preferences: PreferencesManager
  @ObservationIgnored private weak var kanban: KanbanManager?

  // MARK: - State
  var hideFuture: Bool = false {
    didSet { invalidateCaches() }
  }

  // The three view-shaping selections below own their own persistence: each
  // `didSet` writes through to `PreferencesStore`. (Previously the persistence
  // lived on `AppCoordinator`'s forwarder setters; moving it here lets those
  // forwarders be pure pass-throughs and eventually deleted.) Assignments made
  // in `init` deliberately don't fire these observers, so loading the persisted
  // value on launch doesn't write it straight back.
  var rootTaskView: RootTaskView = .all {
    didSet {
      preferencesStore.set(rootTaskView.rawValue, for: .rootTaskView)
      invalidateCaches()
    }
  }

  var selectedRootDueBucketRawValue: Int = -1 {
    didSet {
      preferencesStore.set(selectedRootDueBucketRawValue, for: .selectedRootDueBucketRawValue)
      invalidateCaches()
    }
  }

  var selectedRootTag: String = "" {
    didSet {
      preferencesStore.set(selectedRootTag, for: .selectedRootTag)
      invalidateCaches()
    }
  }

  /// Typed wrapper over `selectedRootDueBucketRawValue` (−1 == "no selection").
  /// Lived on `AppCoordinator` previously; moved here so the raw forwarder can
  /// be deleted and views read the selection from its real owner.
  var selectedRootDueBucket: RootDueBucket? {
    get { RootDueBucket(rawValue: selectedRootDueBucketRawValue) }
    set { selectedRootDueBucketRawValue = newValue?.rawValue ?? -1 }
  }

  /// When true, non-kanban menus (Due, Tags, Priority, Eisenhower) show the entire
  /// subtree under `currentParentId` (siblings of the selection plus all of their
  /// descendants), matching kanban filtering. When false, they show only direct
  /// children of `currentParentId`. The All view is unaffected.
  var showChildrenInMenus: Bool = true {
    didSet { invalidateCaches() }
  }

  @ObservationIgnored private var cacheStorage = CacheState()

  /// Up-to-date view of the derived caches.
  ///
  /// Reading this rebuilds lazily if anything has invalidated since the last
  /// read, so external callers (`PopoverView`, `KanbanManager`,
  /// `KanbanTaskDataSourceAdapter`) can't observe a stale snapshot. Previously
  /// `invalidateCaches()` rebuilt eagerly, which kept those readers correct
  /// only by accident and made every single mutation of `tasks` — plus each
  /// priority/eisenhower/timer write that follows it — pay for a full
  /// recompute. Internal code should use `cacheStorage` directly to avoid
  /// re-entering the validity check on hot paths.
  var cache: CacheState {
    ensureVisibleTasksCacheValid()
    return cacheStorage
  }

  init(
    repository: TaskRepository,
    navigationState: NavigationState,
    timer: TimerManager,
    quickEntry: QuickEntryManager,
    kanban: KanbanManager?,
    preferences: PreferencesManager
  ) {
    self.repository = repository
    self.navigationState = navigationState
    self.timer = timer
    self.quickEntry = quickEntry
    self.kanban = kanban
    self.preferences = preferences
    self.preferencesStore = preferences.preferencesStore

    // Load persisted view-shaping state. These assignments run inside `init`,
    // so the `didSet` write-throughs above don't fire.
    self.rootTaskView =
      RootTaskView(rawValue: preferencesStore.int(.rootTaskView, default: 1)) ?? .due
    self.selectedRootDueBucketRawValue = preferencesStore.int(
      .selectedRootDueBucketRawValue, default: -1)
    self.selectedRootTag = preferencesStore.string(.selectedRootTag)
  }

  /// Marks the derived caches stale. The rebuild is deferred to the next read
  /// of `cache` (or of any accessor that calls
  /// `ensureVisibleTasksCacheValid`), so a burst of writes — e.g. a delete,
  /// which touches `tasks`, both priority queues and the eisenhower levels —
  /// costs one recompute instead of one per write.
  func invalidateCaches() {
    cacheStorage.invalidate()
  }

  func ensureVisibleTasksCacheValid() {
    guard cacheStorage.dirty, !cacheStorage.isRebuilding else { return }
    cacheStorage.isRebuilding = true
    defer { cacheStorage.isRebuilding = false }

    let tasks = repository.tasks
    cacheStorage.taskById = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
    cacheStorage.tagsByTaskId = TaskFilterEngine.extractTagsByTaskId(tasks: tasks)
    cacheStorage.rootDueBucket = TaskFilterEngine.computeRootDueBuckets(tasks: tasks)
    var rankByTaskId: [Int: Int] = [:]
    for (_, ids) in repository.priorityTaskIdsByParentId {
      for (idx, id) in ids.enumerated() {
        rankByTaskId[id] = idx + 1
      }
    }
    var absoluteRankByTaskId: [Int: Int] = [:]
    for (idx, id) in repository.absolutePriorityTaskIds.enumerated() {
      absoluteRankByTaskId[id] = idx + 1
    }
    cacheStorage.priorityRank = rankByTaskId
    cacheStorage.absolutePriorityRank = absoluteRankByTaskId
    cacheStorage.priorityPath = Self.computePriorityPaths(
      rankByTaskId: rankByTaskId,
      taskById: cacheStorage.taskById
    )
    cacheStorage.dirty = false
    let visibility = computeVisibility()
    cacheStorage.visibleTasks = visibility.tasks
    cacheStorage.remainderStartIndex = visibility.remainderStartIndex
    let nodes = tasks.map { TimerNode(id: $0.id, parentId: $0.parentId) }
    cacheStorage.childCount = TimerStore.childCountByTaskId(nodes: nodes)
    cacheStorage.rolledUpElapsed = TimerStore.rolledUpElapsedByTaskId(
      nodes: nodes, ownElapsed: timer.timerByTaskId)
    cacheStorage.rootLevelTagNames = computeRootLevelTagNames(limit: 30)
  }

  private func computeVisibility() -> TaskVisibilityEngine.Result {
    let tasks = repository.tasks
    let currentParentId = navigationState.currentParentId
    let currentLevelTasks = tasks.filter { ($0.parentId ?? 0) == currentParentId }
    let isRootLevel = currentParentId == 0
    let isSearchFilterActive = quickEntry.isSearchFilterActive
    let shouldShowRootScopeSection = !isSearchFilterActive

    return TaskVisibilityEngine.compute(
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
        showChildrenInMenus: showChildrenInMenus,
        selectedRootDueBucket: RootDueBucket(rawValue: selectedRootDueBucketRawValue),
        selectedRootTag: selectedRootTag,
        taskById: cacheStorage.taskById,
        isDescendant: { task, rootId in
          TaskFilterEngine.isDescendant(task, of: rootId, taskById: self.cacheStorage.taskById)
        },
        taskMatchesActiveRootScope: { [weak self] task in
          self?.taskMatchesActiveRootScope(task) ?? false
        },
        isAbsolutePrioritized: { [weak self] task in
          self?.cacheStorage.absolutePriorityRank[task.id] != nil
        },
        compareByPriorityThenPosition: { lhs, rhs in
          TaskFilterEngine.compareByPriorityThenPosition(
            lhs,
            rhs,
            priorityRankById: self.cacheStorage.priorityRank,
            absolutePriorityRankById: self.cacheStorage.absolutePriorityRank
          )
        },
        compareByRootDueBucket: { lhs, rhs in
          TaskFilterEngine.compareByRootDueBucket(
            lhs, rhs, rootDueBucketById: self.cacheStorage.rootDueBucket)
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
  private func computeRootLevelTagNames(limit: Int) -> [String] {
    var counts: [String: Int] = [:]
    for tags in cacheStorage.tagsByTaskId.values {
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

  func rootDueBucket(for task: CheckvistTask) -> RootDueBucket {
    if let cached = cacheStorage.rootDueBucket[task.id] { return cached }
    return TaskFilterEngine.classifyDueBucket(task: task)
  }

  private func hasAnyTag(_ task: CheckvistTask) -> Bool {
    cacheStorage.tagsByTaskId[task.id] != nil
  }

  private func hasTag(_ task: CheckvistTask, tag: String) -> Bool {
    guard let tags = cacheStorage.tagsByTaskId[task.id] else { return false }
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
    case .all: return true
    case .due:
      let bucket = rootDueBucket(for: task)
      if selectedRootDueBucketRawValue != -1 {
        return bucket == RootDueBucket(rawValue: selectedRootDueBucketRawValue)
      }
      return bucket != .noDueDate
    case .tags:
      if selectedRootTag.isEmpty { return hasAnyTag(task) }
      return hasTag(task, tag: selectedRootTag)
    case .priority:
      return cacheStorage.absolutePriorityRank[task.id] != nil || cacheStorage.priorityRank[task.id] != nil
    case .kanban:
      return true
    case .eisenhower:
      return true
    }
  }

  // MARK: - View-derived badge / section helpers
  // Consolidated from `AppCoordinator+TaskScoping` (Phase 3 follow-up): these read
  // purely from the rebuilt `cache` (+ `repository`/`navigationState`/`quickEntry`
  // this VM already owns), so they belong with the cache rather than forwarded
  // through the coordinator. Views read them via `@Environment(TaskListViewModel.self)`.

  func priorityRank(for task: CheckvistTask) -> Int? {
    ensureVisibleTasksCacheValid()
    return cacheStorage.priorityRank[task.id]
  }

  func absolutePriorityRank(for task: CheckvistTask) -> Int? {
    ensureVisibleTasksCacheValid()
    return cacheStorage.absolutePriorityRank[task.id]
  }

  func priorityPath(for task: CheckvistTask) -> String? {
    ensureVisibleTasksCacheValid()
    return cacheStorage.priorityPath[task.id]
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

  /// Exposes the boundary (if any) at which non-matching "remainder" tasks begin
  /// within `visibleTasks`. Computed by `TaskVisibilityEngine` for due/tags/priority
  /// root views.
  var remainderStartIndex: Int? {
    ensureVisibleTasksCacheValid()
    return cacheStorage.remainderStartIndex
  }

  var isRootLevel: Bool { navigationState.currentParentId == 0 }

  var shouldShowRootScopeSection: Bool { !quickEntry.isSearchFilterActive }

  var rootScopeShowsFilterControls: Bool {
    guard shouldShowRootScopeSection && isRootLevel else { return false }
    switch rootTaskView {
    case .due, .tags:
      return true
    case .all, .priority, .kanban, .eisenhower:
      return false
    }
  }

  private var shouldShowDueSectionHeaders: Bool {
    isRootLevel && shouldShowRootScopeSection && rootTaskView == .due
      && selectedRootDueBucket == nil
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

  /// Returns the header title to display just before the task at the given index, or
  /// nil when no remainder header belongs there. Only the boundary index produces a
  /// header.
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
    ensureVisibleTasksCacheValid()
    return Array(cacheStorage.rootLevelTagNames.prefix(limit))
  }

  /// Returns true if task is a descendant of the given parentId (or IS at that level).
  ///
  /// Ensures the cache first: `taskById` has to reflect the *current* task list
  /// or callers such as `subtreeBlockRange` compute a wrong range. This used to
  /// be correct only because `invalidateCaches()` rebuilt eagerly.
  func isDescendant(_ task: CheckvistTask, of rootId: Int) -> Bool {
    ensureVisibleTasksCacheValid()
    return TaskFilterEngine.isDescendant(task, of: rootId, taskById: cacheStorage.taskById)
  }

  /// Computes a hierarchical priority path per ranked task. For each ranked task, walks
  /// from the root of its ancestor chain down to itself; each ancestor contributes its
  /// own rank-in-parent-scope or "=" if unranked in that scope.
  static func computePriorityPaths(
    rankByTaskId: [Int: Int],
    taskById: [Int: CheckvistTask]
  ) -> [Int: String] {
    var result: [Int: String] = [:]
    for taskId in rankByTaskId.keys {
      guard let task = taskById[taskId] else { continue }
      var chain: [CheckvistTask] = []
      var cursor: CheckvistTask? = task
      while let current = cursor {
        chain.append(current)
        if let pid = current.parentId, pid != 0, let parent = taskById[pid] {
          cursor = parent
        } else {
          cursor = nil
        }
      }
      chain.reverse()  // root-first
      let segments: [String] = chain.map { node in
        if let rank = rankByTaskId[node.id] { return String(rank) }
        return "="
      }
      result[taskId] = segments.joined(separator: ".")
    }
    return result
  }

  // MARK: - Task Scoping & Timing Helpers

  /// Tasks visible at the current level, sorted by position
  var currentLevelTasks: [CheckvistTask] {
    repository.tasks.filter { ($0.parentId ?? 0) == navigationState.currentParentId }
  }

  var currentTask: CheckvistTask? {
    if rootTaskView == .kanban {
      return kanban?.currentKanbanTask
    }
    let level = visibleTasks
    guard !level.isEmpty else { return nil }
    let clampedIndex = min(max(navigationState.currentSiblingIndex, 0), level.count - 1)
    return level[clampedIndex]
  }

  var currentTaskText: String { currentTask?.content ?? "" }

  /// Breadcrumb chain from root down to (but not including) current task
  var breadcrumbs: [CheckvistTask] {
    ensureVisibleTasksCacheValid()
    var result: [CheckvistTask] = []
    var parentId = navigationState.currentParentId
    while parentId != 0 {
      if let parent = cacheStorage.taskById[parentId] {
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

  var visibleTasks: [CheckvistTask] {
    _ = repository.tasks
    _ = navigationState.currentParentId
    _ = quickEntry.searchText
    _ = quickEntry.quickEntryMode
    _ = rootTaskView
    _ = selectedRootDueBucketRawValue
    _ = selectedRootTag
    _ = hideFuture
    _ = showChildrenInMenus
    ensureVisibleTasksCacheValid()
    return cacheStorage.visibleTasks
  }

  func shouldShowBreadcrumbPath(for task: CheckvistTask) -> Bool {
    let pid = task.parentId ?? 0
    if isRootLevel && shouldShowRootScopeSection && rootTaskView != .all {
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

  func subtreeBlockRange(for taskId: Int, in flatTasks: [CheckvistTask]) -> Range<Int>? {
    ensureVisibleTasksCacheValid()
    guard let start = flatTasks.firstIndex(where: { $0.id == taskId }) else { return nil }

    var end = start + 1
    while end < flatTasks.count {
      let candidate = flatTasks[end]
      if isDescendant(candidate, of: taskId) {
        end += 1
      } else {
        break
      }
    }
    return start..<end
  }

  func totalElapsed(forTaskId taskId: Int) -> TimeInterval {
    rolledUpElapsedByTaskId()[taskId] ?? 0
  }

  func totalElapsed(for task: CheckvistTask) -> TimeInterval {
    totalElapsed(forTaskId: task.id)
  }

  func childCountByTaskId() -> [Int: Int] {
    ensureVisibleTasksCacheValid()
    return cacheStorage.childCount
  }

  func rolledUpElapsedByTaskId() -> [Int: TimeInterval] {
    // Touch the observable dictionary so SwiftUI re-renders on per-second
    // ticks. Without this, callers only read the @ObservationIgnored cache
    // and never establish a dependency on `timer.timerByTaskId`.
    _ = timer.timerByTaskId
    ensureVisibleTasksCacheValid()
    return cacheStorage.rolledUpElapsed
  }
}
