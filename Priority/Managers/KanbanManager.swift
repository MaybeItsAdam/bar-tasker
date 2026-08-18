import Foundation
import OSLog
import Observation
import PriorityCore

/// Provides read-only access to task data that KanbanManager needs for filtering and sorting.
/// The coordinator conforms to this; KanbanManager never references the coordinator directly.
@MainActor
protocol KanbanTaskDataSource: AnyObject {
  var tasks: [CheckvistTask] { get }
  var currentParentId: Int { get set }
  var hideFuture: Bool { get }
  var currentSiblingIndex: Int { get set }
  var rootTaskView: RootTaskView { get }
  var cache: CacheState { get }
  func ensureVisibleTasksCacheValid()
  func rootDueBucket(for task: CheckvistTask) -> RootDueBucket
  func absolutePriorityRank(for task: CheckvistTask) -> Int?
  func priorityRank(for task: CheckvistTask) -> Int?
  func priorityPath(for task: CheckvistTask) -> String?
}

/// Describes the outcome of a kanban move so the coordinator can apply the actual task mutation.
enum KanbanMoveOutcome {
  case update(task: CheckvistTask, newContent: String?, newDue: String?)
  case error(String)
}

@MainActor
@Observable class KanbanManager {
  @ObservationIgnored private let logger = Logger(subsystem: "uk.co.maybeitsadam.priority", category: "kanban")
  @ObservationIgnored private let preferencesStore: PreferencesStore
  @ObservationIgnored private let cacheInvalidationBus: CacheInvalidationBus
  @ObservationIgnored weak var dataSource: KanbanTaskDataSource?

  var kanbanColumns: [KanbanColumn] {
    didSet {
      saveKanbanColumns(kanbanColumns)
      cacheInvalidationBus.invalidate()
    }
  }
  var kanbanFocusedColumnIndex: Int = 0 {
    didSet { cacheInvalidationBus.invalidate() }
  }
  /// Task ID of the selected card in kanban view. Decoupled from currentSiblingIndex
  /// so selection survives task-list refreshes and view switches.
  var kanbanSelectedTaskId: Int? {
    didSet { cacheInvalidationBus.invalidate() }
  }
  /// When true, kanban shows only subtasks of `currentParentId`
  var kanbanFilterSubtasks: Bool = false {
    didSet { cacheInvalidationBus.invalidate() }
  }
  /// When set, kanban shows the full subtree under this task ID (excluding the root task itself).
  /// This overrides `kanbanFilterSubtasks`.
  var kanbanFilterParentId: Int? {
    didSet { cacheInvalidationBus.invalidate() }
  }
  /// Column ID currently showing the inline add field (nil = none).
  var addingToColumnId: UUID?
  /// Text for the inline add field.
  var addText: String = ""
  /// Per-column manual order overlay. Maps column UUID string → ordered task IDs.
  /// Tasks listed here are sorted by this list within their column, taking
  /// precedence over the column's natural sort order. Tasks not in the list
  /// fall back to the column's natural sort. Lets users nudge cards up/down
  /// without mutating their underlying date/priority/etc.
  var manualOrderByColumnId: [String: [Int]] {
    didSet {
      saveManualOrders(manualOrderByColumnId)
      cacheInvalidationBus.invalidate()
    }
  }

  init(
    preferencesStore: PreferencesStore,
    cacheInvalidationBus: CacheInvalidationBus = CacheInvalidationBus()
  ) {
    self.preferencesStore = preferencesStore
    self.cacheInvalidationBus = cacheInvalidationBus
    let storedKanbanJson = preferencesStore.string(.kanbanColumns)
    if !storedKanbanJson.isEmpty,
      let data = storedKanbanJson.data(using: .utf8),
      let decoded = try? JSONDecoder().decode([KanbanColumn].self, from: data),
      !decoded.isEmpty
    {
      // Migration: Change Backlog .catchAll to .tag("backlog")
      var migrated = decoded
      for i in 0..<migrated.count where migrated[i].name.lowercased() == "backlog" {
        migrated[i].conditions = migrated[i].conditions.map { cond in
          if case .catchAll = cond { return .tag("backlog") }
          return cond
        }
      }
      self.kanbanColumns = migrated
    } else {
      self.kanbanColumns = KanbanColumn.defaults
    }

    let storedManualOrdersJson = preferencesStore.string(.kanbanManualOrderByColumnId)
    if !storedManualOrdersJson.isEmpty,
      let data = storedManualOrdersJson.data(using: .utf8),
      let decoded = try? JSONDecoder().decode([String: [Int]].self, from: data)
    {
      self.manualOrderByColumnId = decoded
    } else {
      self.manualOrderByColumnId = [:]
    }
  }

  private func saveManualOrders(_ orders: [String: [Int]]) {
    guard let data = try? JSONEncoder().encode(orders),
      let json = String(data: data, encoding: .utf8)
    else { return }
    preferencesStore.set(json, for: .kanbanManualOrderByColumnId)
  }

  // MARK: - Task filtering for kanban columns

  /// Returns tasks that belong to the given column within the active kanban scope.
  /// Column membership uses first-match semantics: a task belongs to the first column
  /// (in `allColumns` order) whose conditions it satisfies.
  func tasksForKanbanColumn(_ column: KanbanColumn, allColumns: [KanbanColumn]) -> [CheckvistTask] {
    guard let ds = dataSource else { return [] }
    ds.ensureVisibleTasksCacheValid()
    var pool: [CheckvistTask]
    if let parentId = kanbanFilterParentId {
      pool = subtreeTasks(in: ds.tasks, rootId: parentId, taskById: ds.cache.taskById)
    } else if kanbanFilterSubtasks && ds.currentParentId != 0 {
      pool = subtreeTasks(in: ds.tasks, rootId: ds.currentParentId, taskById: ds.cache.taskById)
    } else {
      // Root kanban scope shows all tasks in the tree; column rules decide visibility.
      pool = ds.tasks
    }

    // Discriminate: exclude completed tasks
    pool = pool.filter { $0.status == 0 }
    
    if ds.hideFuture {
      pool = pool.filter { task in
        guard let dueDate = task.dueDate else { return true }
        guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) else { return true }
        return Calendar.current.startOfDay(for: dueDate) <= Calendar.current.startOfDay(for: tomorrow)
      }
    }    
    let eligible = pool.filter { task in
      columnForTask(task, in: allColumns)?.id == column.id
    }
    let naturallySorted = sortedForKanban(eligible, sortOrder: column.sortOrder)
    return applyManualOrder(naturallySorted, column: column)
  }

  /// Reorders `tasks` so any task listed in the column's manual override comes
  /// first in the order specified there. Tasks not present in the override
  /// retain the natural-sort order they came in with.
  private func applyManualOrder(_ tasks: [CheckvistTask], column: KanbanColumn)
    -> [CheckvistTask]
  {
    let key = column.id.uuidString
    guard let order = manualOrderByColumnId[key], !order.isEmpty else { return tasks }
    var rankById: [Int: Int] = [:]
    for (idx, id) in order.enumerated() { rankById[id] = idx }
    var ranked: [CheckvistTask] = []
    var unranked: [CheckvistTask] = []
    for task in tasks {
      if rankById[task.id] != nil {
        ranked.append(task)
      } else {
        unranked.append(task)
      }
    }
    ranked.sort { (rankById[$0.id] ?? .max) < (rankById[$1.id] ?? .max) }
    return ranked + unranked
  }

  /// Move `taskId` one slot up or down in the column's manual order. The task
  /// is added to the override (if not present) using its current visible
  /// position as the starting rank. No underlying task attribute is changed —
  /// this is purely a per-user, per-column display preference.
  @MainActor func nudgeTaskInColumn(taskId: Int, in column: KanbanColumn, direction: Int) {
    guard direction == -1 || direction == 1 else { return }
    let key = column.id.uuidString
    let columnTasks = tasksForKanbanColumn(column, allColumns: kanbanColumns)
    guard let visibleIdx = columnTasks.firstIndex(where: { $0.id == taskId }) else { return }
    let newIdx = visibleIdx + direction
    guard columnTasks.indices.contains(newIdx) else { return }
    // Anchor the manual order to the current visible order so the override
    // mirrors what the user sees right before the move.
    var order = columnTasks.map(\.id)
    order.swapAt(visibleIdx, newIdx)
    manualOrderByColumnId[key] = order
  }

  /// Drop a task from every column's manual order. Used when a task is
  /// completed/deleted so stale IDs don't accumulate.
  @MainActor func clearManualOrderEntries(forTaskIds removed: Set<Int>) {
    guard !removed.isEmpty else { return }
    var changed = false
    var updated = manualOrderByColumnId
    for (key, ids) in updated {
      let filtered = ids.filter { !removed.contains($0) }
      if filtered.count != ids.count {
        if filtered.isEmpty {
          updated.removeValue(forKey: key)
        } else {
          updated[key] = filtered
        }
        changed = true
      }
    }
    if changed { manualOrderByColumnId = updated }
  }

  private func subtreeTasks(in tasks: [CheckvistTask], rootId: Int, taskById: [Int: CheckvistTask])
    -> [CheckvistTask]
  {
    KanbanFilter.subtreeTasks(in: tasks, rootId: rootId, taskById: taskById)
  }

  /// Returns the first column (in order) that a task matches.
  /// Only a *specific* condition (tag or due bucket) claims a task; `.catchAll`
  /// answers false, so it collects what no earlier column took.
  func columnForTask(_ task: CheckvistTask, in columns: [KanbanColumn]) -> KanbanColumn? {
    guard let ds = dataSource else { return nil }
    return KanbanFilter.column(
      for: task, in: columns,
      tagsByTaskId: ds.cache.tagsByTaskId,
      dueBucket: { ds.rootDueBucket(for: $0) })
  }

  private func taskMatchesKanbanColumn(
    _ task: CheckvistTask,
    column: KanbanColumn,
    includeCatchAll: Bool = true
  ) -> Bool {
    guard let ds = dataSource else { return false }
    return KanbanFilter.matchesColumn(
      task, column: column, includeCatchAll: includeCatchAll,
      tagsByTaskId: ds.cache.tagsByTaskId,
      dueBucket: { ds.rootDueBucket(for: $0) })
  }

  func taskMatchesCondition(_ task: CheckvistTask, condition: KanbanColumnCondition) -> Bool {
    guard let ds = dataSource else { return false }
    return KanbanFilter.matches(
      task, condition: condition,
      tagsByTaskId: ds.cache.tagsByTaskId,
      dueBucket: { ds.rootDueBucket(for: $0) })
  }

  // Note: sortedForKanban implementation moved to extension at the bottom of this file.

  // MARK: - Current kanban task

  /// The currently selected task in the focused kanban column.
  var currentKanbanTask: CheckvistTask? {
    let board = boardTasks()
    let placement = KanbanSelection.clamp(currentPlacement, in: board.grid)
    guard let selectedId = placement.selectedTaskId,
      let found = KanbanSelection.locate(selectedId, in: board.grid)
    else { return nil }
    return board.tasks[found.column][found.row]
  }

  // MARK: - Selection plumbing

  /// The board as `KanbanSelection` wants it: one row of task ids per column,
  /// in display order, alongside the tasks themselves.
  ///
  /// Built once per operation. The selection code used to re-filter and re-sort
  /// every column inside every lookup — `nextKanbanTask` alone called
  /// `tasksForKanbanColumn` once per column to resolve focus and then again to
  /// read the column it settled on.
  private func boardTasks() -> (tasks: [[CheckvistTask]], grid: [[Int]]) {
    let columns = kanbanColumns
    let tasks = columns.map { tasksForKanbanColumn($0, allColumns: columns) }
    return (tasks, tasks.map { $0.map(\.id) })
  }

  private var currentPlacement: KanbanSelection.Placement {
    KanbanSelection.Placement(
      focusedColumnIndex: kanbanFocusedColumnIndex,
      selectedTaskId: kanbanSelectedTaskId,
      siblingIndex: dataSource?.currentSiblingIndex ?? 0)
  }

  private func apply(_ placement: KanbanSelection.Placement) {
    kanbanFocusedColumnIndex = placement.focusedColumnIndex
    kanbanSelectedTaskId = placement.selectedTaskId
    dataSource?.currentSiblingIndex = placement.siblingIndex
  }

  // MARK: - Moving tasks between columns

  /// Computes the move for the currently selected task one column in `direction`.
  /// Returns nil if no move is possible, `.error` if the target has no writable condition,
  /// or `.success` with the mutation to apply.
  @MainActor func computeMoveCurrentTask(direction: Int) -> KanbanMoveOutcome? {
    guard let ds = dataSource, ds.rootTaskView == .kanban else { return nil }
    let columns = kanbanColumns
    guard !columns.isEmpty, let task = currentKanbanTask else { return nil }

    let currentColIndex = kanbanFocusedColumnIndex

    // Display is reversed, so visual right = lower array index.
    let targetIndex = currentColIndex - direction
    guard columns.indices.contains(targetIndex) else { return nil }
    let targetColumn = columns[targetIndex]

    guard
      let (newContent, newDue) = applyColumnConditions(
        to: task, targetColumn: targetColumn, allColumns: columns)
    else {
      return .error("Can't move task into \"\(targetColumn.name)\" — no writable condition.")
    }

    // Shift focused column to follow the task
    kanbanFocusedColumnIndex = targetIndex
    ds.currentSiblingIndex = 0
    kanbanSelectedTaskId = task.id

    if newContent != task.content || newDue != task.due {
      return .update(
        task: task,
        newContent: newContent != task.content ? newContent : nil,
        newDue: newDue != task.due ? newDue : nil
      )
    }
    return nil
  }

  /// Computes the move for a specific task to a target column.
  @MainActor func computeMoveTask(id taskId: Int, toColumn targetColumn: KanbanColumn)
    -> KanbanMoveOutcome?
  {
    guard let ds = dataSource else { return nil }
    let columns = kanbanColumns
    guard let task = ds.cache.taskById[taskId] else { return nil }
    guard
      let (newContent, newDue) = applyColumnConditions(
        to: task, targetColumn: targetColumn, allColumns: columns)
    else {
      return .error("Can't move task into \"\(targetColumn.name)\" — no writable condition.")
    }
    if newContent != task.content || newDue != task.due {
      return .update(
        task: task,
        newContent: newContent != task.content ? newContent : nil,
        newDue: newDue != task.due ? newDue : nil
      )
    }
    return nil
  }

  /// Computes the new content and due string needed to make `task` satisfy `targetColumn`.
  /// Returns nil if no writable condition exists.
  private func applyColumnConditions(
    to task: CheckvistTask,
    targetColumn: KanbanColumn,
    allColumns: [KanbanColumn]
  ) -> (content: String, due: String?)? {
    var content = task.content
    var due: String? = task.due

    // Strip tags that belong to other tag-based columns so there's no ambiguity.
    let otherColumnTags: [String] =
      allColumns
      .filter { $0.id != targetColumn.id }
      .flatMap { col in
        col.conditions.compactMap {
          if case .tag(let t) = $0 { return t } else { return nil }
        }
      }
    for tag in otherColumnTags {
      let escapedTag = NSRegularExpression.escapedPattern(for: tag)
      if let regex = try? NSRegularExpression(pattern: "(?i)(?:^|\\s)#\(escapedTag)\\b") {
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        content = regex.stringByReplacingMatches(in: content, range: range, withTemplate: "")
      }
      content =
        content
        .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    }

    // Determine if the task's current column is due-bucket based.
    let currentColumn = columnForTask(task, in: allColumns)
    let sourceIsDueBased =
      currentColumn?.conditions.contains(where: {
        if case .dueBucket = $0 { return true }
        return false
      }) ?? false

    // Preserve due when moving into a due-based column that already matches the task's bucket.
    // This avoids clobbering an existing date/time (e.g. moving within "Next 7 Days").
    if let ds = dataSource {
      let targetDueBuckets = targetColumn.conditions.compactMap { condition -> RootDueBucket? in
        guard case .dueBucket(let raw) = condition else { return nil }
        return RootDueBucket(rawValue: raw)
      }
      let existingDue = task.due?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if !targetDueBuckets.isEmpty, !existingDue.isEmpty {
        let currentBucket = ds.rootDueBucket(for: task)
        if targetDueBuckets.contains(currentBucket) {
          return (content, due)
        }
      }
    }

    // Find the first writable condition in the target column.
    guard let writableCondition = targetColumn.conditions.first(where: { $0.isWritable }) else {
      return nil
    }

    switch writableCondition {
    case .tag(let name):
      if !content.lowercased().contains("#\(name.lowercased())") {
        content = "\(content) #\(name)"
      }
      // Strip due date when moving out of a due-bucket column into a tag column.
      if sourceIsDueBased {
        due = ""
      }

    case .dueBucket(let raw):
      guard let bucket = RootDueBucket(rawValue: raw) else { return nil }
      switch bucket {
      case .today:
        due = CommandEngine.resolveDueDate("today")
      case .tomorrow:
        due = CommandEngine.resolveDueDate("tomorrow")
      case .nextSevenDays:
        // Pick a date 3 days out — comfortably inside the 7-day window.
        let cal = Calendar.current
        let target = cal.date(byAdding: .day, value: 3, to: cal.startOfDay(for: Date()))!
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        due = fmt.string(from: target)
      case .noDueDate:
        due = ""
      default:
        return nil  // non-writable bucket
      }

    case .catchAll:
      // Strip the due date so the task doesn't accidentally match a due-bucket column.
      due = ""
    }

    return (content, due)
  }

  // MARK: - Column focus navigation (no task move)

  @MainActor func focusKanbanColumn(direction: Int) {
    guard let ds = dataSource, ds.rootTaskView == .kanban else { return }
    guard
      let placement = KanbanSelection.focusColumn(
        from: kanbanFocusedColumnIndex, direction: direction, in: boardTasks().grid)
    else { return }
    apply(placement)
  }

  @MainActor func nextKanbanTask() {
    guard let placement = KanbanSelection.next(from: currentPlacement, in: boardTasks().grid)
    else { return }
    apply(placement)
  }

  @MainActor func previousKanbanTask() {
    guard let placement = KanbanSelection.previous(from: currentPlacement, in: boardTasks().grid)
    else { return }
    apply(placement)
  }

  // MARK: - Scope drill in/out

  /// Drills the kanban into the selected task's subtree so its children become
  /// the new sibling-pool. Selection moves to the first child if any.
  @MainActor func enterSelectedTaskAsScope() {
    guard let task = currentKanbanTask else { return }
    kanbanFilterParentId = task.id
    dataSource?.currentParentId = task.id
    // The board is re-read *after* the scope changes, so this is the new
    // subtree. No children leaves the scope drilled with nothing selected, so
    // the user sees an empty board rather than being silently bounced back.
    apply(KanbanSelection.firstAvailable(in: boardTasks().grid))
  }

  /// Pops the kanban scope up one level. If we're at root, restores selection to
  /// what was previously the parent task (so navigation feels reversible).
  @MainActor func exitToParentScope() {
    guard let ds = dataSource else { return }
    let currentScopeId: Int? =
      kanbanFilterParentId
      ?? (ds.currentParentId == 0 ? nil : ds.currentParentId)
    guard let currentFilterId = currentScopeId else { return }
    let parentTask = ds.cache.taskById[currentFilterId]
    let newParentId = parentTask?.parentId ?? 0
    kanbanFilterSubtasks = false
    kanbanFilterParentId = newParentId == 0 ? nil : newParentId
    ds.currentParentId = newParentId

    // Re-select the task we just popped out of so the user has context,
    // falling back to the first card on the board.
    let placement = KanbanSelection.select(
      parentTask?.id, in: boardTasks().grid, fallbackColumnIndex: kanbanFocusedColumnIndex)
    // An empty board leaves the selection alone rather than clearing it, as it
    // always has — `clampKanbanSelection` is what tidies a stale one.
    guard placement.selectedTaskId != nil else { return }
    apply(placement)
  }

  // MARK: - Scope navigation helpers

  /// Whether the current selection is at the first task in the focused column (or there are
  /// no tasks at all). Used by the keyboard router to decide whether UP arrow should enter
  /// the scope row instead of navigating within the column.
  var isAtTopOfFocusedColumn: Bool {
    KanbanSelection.isAtTopOfFocusedColumn(currentPlacement, in: boardTasks().grid)
  }

  // MARK: - Selection clamping

  /// Re-validate kanbanSelectedTaskId after task mutations (complete, delete, reorder).
  /// If the selected task no longer exists in any column, pick the nearest task in the
  /// focused column so the selection doesn't jump to an unrelated task.
  @MainActor func clampKanbanSelection() {
    guard dataSource != nil else { return }
    let placement = currentPlacement
    let clamped = KanbanSelection.clamp(placement, in: boardTasks().grid)
    // A still-valid selection comes back untouched; writing it anyway would
    // fire the observation bus on every mutation for no change.
    guard clamped != placement else { return }
    apply(clamped)
  }

  // MARK: - Kanban column persistence

  func loadKanbanColumns() -> [KanbanColumn] {
    guard
      let data = preferencesStore.string(.kanbanColumns).data(using: .utf8),
      !data.isEmpty,
      let decoded = try? JSONDecoder().decode([KanbanColumn].self, from: data),
      !decoded.isEmpty
    else {
      return KanbanColumn.defaults
    }
    return decoded
  }

  func saveKanbanColumns(_ columns: [KanbanColumn]) {
    guard let data = try? JSONEncoder().encode(columns),
      let json = String(data: data, encoding: .utf8)
    else { return }
    preferencesStore.set(json, for: .kanbanColumns)
  }

  // MARK: - Inline add

  /// Returns (content, due) with column attributes applied to raw user input.
  func contentAndDueForNewTask(rawContent: String, in column: KanbanColumn) -> (content: String, due: String?) {
    var content = rawContent
    var due: String?

    guard let condition = column.conditions.first(where: { $0.isWritable }) else {
      return (content, due)
    }

    switch condition {
    case .tag(let name):
      if !content.lowercased().contains("#\(name.lowercased())") {
        content = "\(content) #\(name)"
      }
    case .dueBucket(let raw):
      if let bucket = RootDueBucket(rawValue: raw) {
        switch bucket {
        case .today:
          due = CommandEngine.resolveDueDate("today")
        case .tomorrow:
          due = CommandEngine.resolveDueDate("tomorrow")
        case .nextSevenDays:
          let cal = Calendar.current
          let target = cal.date(byAdding: .day, value: 3, to: cal.startOfDay(for: Date()))!
          let fmt = DateFormatter()
          fmt.locale = Locale(identifier: "en_US_POSIX")
          fmt.dateFormat = "yyyy-MM-dd"
          due = fmt.string(from: target)
        default:
          break
        }
      }
    case .catchAll:
      break
    }

    return (content, due)
  }
}

// MARK: - Kanban Sorting Extension

extension KanbanManager {
  /// The board's orderings live in `KanbanFilter` (pure, in `PriorityCore`, and
  /// covered by `corelogic-tests/KanbanFilterTests.swift`). This gathers the
  /// ranks and tags they need from the data source once, rather than letting a
  /// comparator reach through it O(n log n) times.
  func sortedForKanban(
    _ tasks: [CheckvistTask],
    sortOrder: KanbanSortOrder
  ) -> [CheckvistTask] {
    guard let ds = dataSource else { return tasks }
    let cache = ds.cache
    return KanbanFilter.sorted(
      tasks,
      sortOrder: sortOrder,
      inputs: .init(
        absolutePriorityRank: cache.absolutePriorityRank,
        priorityRank: cache.priorityRank,
        tagsByTaskId: cache.tagsByTaskId
      )
    )
  }
}
