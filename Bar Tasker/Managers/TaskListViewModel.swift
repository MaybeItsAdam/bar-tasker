import Foundation
import Observation

@MainActor
@Observable final class TaskListViewModel {
  // MARK: - Dependencies
  @ObservationIgnored private let repository: TaskRepository
  @ObservationIgnored private let navigationState: NavigationState
  @ObservationIgnored private let timer: TimerManager
  @ObservationIgnored private let quickEntry: QuickEntryManager

  // MARK: - State
  var hideFuture: Bool = false {
    didSet { invalidateCaches() }
  }

  var rootTaskView: RootTaskView = .all {
    didSet { invalidateCaches() }
  }

  var selectedRootDueBucketRawValue: Int = -1 {
    didSet { invalidateCaches() }
  }

  var selectedRootTag: String = "" {
    didSet { invalidateCaches() }
  }

  @ObservationIgnored var cache = CacheState()

  init(
    repository: TaskRepository,
    navigationState: NavigationState,
    timer: TimerManager,
    quickEntry: QuickEntryManager
  ) {
    self.repository = repository
    self.navigationState = navigationState
    self.timer = timer
    self.quickEntry = quickEntry
  }

  func invalidateCaches() {
    cache.invalidate()
    ensureVisibleTasksCacheValid()
  }

  func ensureVisibleTasksCacheValid() {
    guard cache.dirty, !cache.isRebuilding else { return }
    cache.isRebuilding = true
    defer { cache.isRebuilding = false }

    let tasks = repository.tasks
    cache.taskById = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
    cache.tagsByTaskId = TaskFilterEngine.extractTagsByTaskId(tasks: tasks)
    cache.rootDueBucket = TaskFilterEngine.computeRootDueBuckets(tasks: tasks)
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
    cache.priorityRank = rankByTaskId
    cache.absolutePriorityRank = absoluteRankByTaskId
    cache.priorityPath = Self.computePriorityPaths(
      rankByTaskId: rankByTaskId,
      taskById: cache.taskById
    )
    cache.dirty = false
    let visibility = computeVisibility()
    cache.visibleTasks = visibility.tasks
    cache.remainderStartIndex = visibility.remainderStartIndex
    let nodes = tasks.map { TimerNode(id: $0.id, parentId: $0.parentId) }
    cache.childCount = TimerStore.childCountByTaskId(nodes: nodes)
    cache.rolledUpElapsed = TimerStore.rolledUpElapsedByTaskId(
      nodes: nodes, ownElapsed: timer.timerByTaskId)
    cache.rootLevelTagNames = computeRootLevelTagNames(limit: 30)
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
        selectedRootDueBucket: RootDueBucket(rawValue: selectedRootDueBucketRawValue),
        selectedRootTag: selectedRootTag,
        taskById: cache.taskById,
        isDescendant: { task, rootId in
          TaskFilterEngine.isDescendant(task, of: rootId, taskById: self.cache.taskById)
        },
        taskMatchesActiveRootScope: { [weak self] task in
          self?.taskMatchesActiveRootScope(task) ?? false
        },
        isAbsolutePrioritized: { [weak self] task in
          self?.cache.absolutePriorityRank[task.id] != nil
        },
        compareByPriorityThenPosition: { lhs, rhs in
          TaskFilterEngine.compareByPriorityThenPosition(
            lhs,
            rhs,
            priorityRankById: self.cache.priorityRank,
            absolutePriorityRankById: self.cache.absolutePriorityRank
          )
        },
        compareByRootDueBucket: { lhs, rhs in
          TaskFilterEngine.compareByRootDueBucket(
            lhs, rhs, rootDueBucketById: self.cache.rootDueBucket)
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

  func rootDueBucket(for task: CheckvistTask) -> RootDueBucket {
    if let cached = cache.rootDueBucket[task.id] { return cached }
    return TaskFilterEngine.classifyDueBucket(task: task)
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
      return cache.absolutePriorityRank[task.id] != nil || cache.priorityRank[task.id] != nil
    case .kanban:
      return true
    case .eisenhower:
      return true
    }
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
}
