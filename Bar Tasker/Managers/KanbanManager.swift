import Combine
import Foundation
import OSLog

/// Provides read-only access to task data that KanbanManager needs for filtering and sorting.
/// The coordinator conforms to this; KanbanManager never references the coordinator directly.
@MainActor
protocol KanbanTaskDataSource: AnyObject {
  var tasks: [CheckvistTask] { get }
  var currentParentId: Int { get }
  var currentSiblingIndex: Int { get set }
  var rootTaskView: BarTaskerManager.RootTaskView { get }
  var cache: BarTaskerCacheState { get }
  func ensureVisibleTasksCacheValid()
  func rootDueBucket(for task: CheckvistTask) -> BarTaskerManager.RootDueBucket
  func priorityRank(for task: CheckvistTask) -> Int?
}

/// Describes the outcome of a kanban move so the coordinator can apply the actual task mutation.
enum KanbanMoveOutcome {
  case update(task: CheckvistTask, newContent: String?, newDue: String?)
  case error(String)
}

@MainActor
class KanbanManager: ObservableObject {
  private let logger = Logger(subsystem: "uk.co.maybeitsadam.bar-tasker", category: "kanban")
  private let preferencesStore: BarTaskerPreferencesStore
  private var cancellables = Set<AnyCancellable>()
  weak var dataSource: KanbanTaskDataSource?

  @Published var kanbanColumns: [KanbanColumn]
  @Published var kanbanFocusedColumnIndex: Int = 0
  /// Task ID of the selected card in kanban view. Decoupled from currentSiblingIndex
  /// so selection survives task-list refreshes and view switches.
  @Published var kanbanSelectedTaskId: Int? = nil
  /// Active tag filter in kanban view (empty = no filter)
  @Published var kanbanFilterTag: String = ""
  /// When true, kanban shows only subtasks of `currentParentId`
  @Published var kanbanFilterSubtasks: Bool = false
  /// When set, kanban shows only direct children of this task ID (overrides kanbanFilterSubtasks)
  @Published var kanbanFilterParentId: Int? = nil

  init(preferencesStore: BarTaskerPreferencesStore) {
    self.preferencesStore = preferencesStore
    let storedKanbanJson = preferencesStore.string(.kanbanColumns)
    if !storedKanbanJson.isEmpty,
      let data = storedKanbanJson.data(using: .utf8),
      let decoded = try? JSONDecoder().decode([KanbanColumn].self, from: data),
      !decoded.isEmpty
    {
      self.kanbanColumns = decoded
    } else {
      self.kanbanColumns = KanbanColumn.defaults
    }
    setupBindings()
  }

  private func setupBindings() {
    $kanbanColumns
      .dropFirst()
      .sink { [weak self] columns in
        self?.saveKanbanColumns(columns)
      }
      .store(in: &cancellables)
  }

  // MARK: - Task filtering for kanban columns

  /// Returns root-level tasks that belong to the given column.
  /// Column membership uses first-match semantics: a task belongs to the first column
  /// (in `allColumns` order) whose conditions it satisfies.
  func tasksForKanbanColumn(_ column: KanbanColumn, allColumns: [KanbanColumn]) -> [CheckvistTask] {
    guard let ds = dataSource else { return [] }
    ds.ensureVisibleTasksCacheValid()
    var pool: [CheckvistTask]
    if let parentId = kanbanFilterParentId {
      pool = ds.tasks.filter { ($0.parentId ?? 0) == parentId }
    } else if kanbanFilterSubtasks && ds.currentParentId != 0 {
      pool = ds.tasks.filter { ($0.parentId ?? 0) == ds.currentParentId }
    } else {
      pool = ds.tasks.filter { $0.parentId == nil || $0.parentId == 0 }
    }
    if !kanbanFilterTag.isEmpty {
      pool = pool.filter { hasTag($0, tag: kanbanFilterTag) }
    }
    let eligible = pool.filter { task in
      columnForTask(task, in: allColumns)?.id == column.id
    }
    return sortedForKanban(eligible, sortOrder: column.sortOrder)
  }

  /// Returns the first column (in order) that a task matches.
  func columnForTask(_ task: CheckvistTask, in columns: [KanbanColumn]) -> KanbanColumn? {
    for column in columns {
      if taskMatchesKanbanColumn(task, column: column) {
        return column
      }
    }
    return nil
  }

  private func taskMatchesKanbanColumn(_ task: CheckvistTask, column: KanbanColumn) -> Bool {
    for condition in column.conditions {
      if taskMatchesCondition(task, condition: condition) {
        return true
      }
    }
    return false
  }

  func taskMatchesCondition(_ task: CheckvistTask, condition: KanbanColumnCondition) -> Bool {
    guard let ds = dataSource else { return false }
    switch condition {
    case .tag(let name):
      return hasTag(task, tag: name)
    case .dueBucket(let raw):
      guard let bucket = BarTaskerManager.RootDueBucket(rawValue: raw) else { return false }
      return ds.rootDueBucket(for: task) == bucket
    case .catchAll:
      return true
    }
  }

  private func hasTag(_ task: CheckvistTask, tag: String) -> Bool {
    guard let ds = dataSource else { return false }
    guard let tags = ds.cache.tagsByTaskId[task.id] else { return false }
    let normalized =
      tag.hasPrefix("#") || tag.hasPrefix("@")
      ? tag.lowercased()
      : "#\(tag.lowercased())"
    return tags.contains(normalized)
  }

  private func sortedForKanban(_ tasks: [CheckvistTask], sortOrder: KanbanSortOrder)
    -> [CheckvistTask]
  {
    guard let ds = dataSource else { return tasks }
    switch sortOrder {
    case .position:
      return tasks.sorted { lhs, rhs in
        switch (lhs.position, rhs.position) {
        case (.some(let l), .some(let r)) where l != r: return l < r
        default:
          return lhs.content.localizedCaseInsensitiveCompare(rhs.content) == .orderedAscending
        }
      }
    case .dueAscending:
      return tasks.sorted { lhs, rhs in
        switch (lhs.dueDate, rhs.dueDate) {
        case (.some(let l), .some(let r)): return l < r
        case (.some, .none): return true
        case (.none, .some): return false
        default:
          return lhs.content.localizedCaseInsensitiveCompare(rhs.content) == .orderedAscending
        }
      }
    case .dueDescending:
      return tasks.sorted { lhs, rhs in
        switch (lhs.dueDate, rhs.dueDate) {
        case (.some(let l), .some(let r)): return l > r
        case (.some, .none): return true
        case (.none, .some): return false
        default:
          return lhs.content.localizedCaseInsensitiveCompare(rhs.content) == .orderedAscending
        }
      }
    case .priorityAscending:
      return tasks.sorted { lhs, rhs in
        let lp = ds.priorityRank(for: lhs)
        let rp = ds.priorityRank(for: rhs)
        if let lp, let rp, lp != rp { return lp < rp }
        if lp != nil && rp == nil { return true }
        if lp == nil && rp != nil { return false }
        return lhs.content.localizedCaseInsensitiveCompare(rhs.content) == .orderedAscending
      }
    case .priorityThenDueAscending:
      return tasks.sorted { lhs, rhs in
        let lp = ds.priorityRank(for: lhs)
        let rp = ds.priorityRank(for: rhs)
        if let lp, let rp, lp != rp { return lp < rp }
        if lp != nil && rp == nil { return true }
        if lp == nil && rp != nil { return false }
        switch (lhs.dueDate, rhs.dueDate) {
        case (.some(let l), .some(let r)) where l != r: return l < r
        case (.some, .none): return true
        case (.none, .some): return false
        default: break
        }
        // tagged tasks before untagged
        let lt = ds.cache.tagsByTaskId[lhs.id] != nil
        let rt = ds.cache.tagsByTaskId[rhs.id] != nil
        if lt != rt { return lt }
        return lhs.content.localizedCaseInsensitiveCompare(rhs.content) == .orderedAscending
      }
    case .alphabetical:
      return tasks.sorted {
        $0.content.localizedCaseInsensitiveCompare($1.content) == .orderedAscending
      }
    }
  }

  // MARK: - Current kanban task

  /// The currently selected task in the focused kanban column.
  var currentKanbanTask: CheckvistTask? {
    guard let ds = dataSource else { return nil }
    let columns = kanbanColumns
    // Try to find the selected task in any visible kanban column.
    if let selectedId = kanbanSelectedTaskId {
      for col in columns {
        let colTasks = tasksForKanbanColumn(col, allColumns: columns)
        if let task = colTasks.first(where: { $0.id == selectedId }) {
          return task
        }
      }
    }
    // Fallback: pick from the focused column by index.
    guard columns.indices.contains(kanbanFocusedColumnIndex) else { return nil }
    let col = columns[kanbanFocusedColumnIndex]
    let colTasks = tasksForKanbanColumn(col, allColumns: columns)
    guard !colTasks.isEmpty else { return nil }
    let idx = min(max(ds.currentSiblingIndex, 0), colTasks.count - 1)
    return colTasks[idx]
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
    // Find the first writable condition in the target column.
    guard let writableCondition = targetColumn.conditions.first(where: { $0.isWritable }) else {
      return nil
    }

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
      content =
        content
        .replacingOccurrences(of: " #\(tag)", with: "")
        .replacingOccurrences(of: "#\(tag)", with: "")
        .trimmingCharacters(in: .whitespaces)
    }

    // Determine if the task's current column is due-bucket based.
    let currentColumn = columnForTask(task, in: allColumns)
    let sourceIsDueBased =
      currentColumn?.conditions.contains(where: {
        if case .dueBucket = $0 { return true }
        return false
      }) ?? false

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
      guard let bucket = BarTaskerManager.RootDueBucket(rawValue: raw) else { return nil }
      let calendar = Calendar.current
      let today = calendar.startOfDay(for: Date())
      let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
      }()
      switch bucket {
      case .today:
        due = formatter.string(from: today)
      case .tomorrow:
        due = formatter.string(from: calendar.date(byAdding: .day, value: 1, to: today)!)
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
    let columns = kanbanColumns
    // Display is reversed, so visual right = lower array index.
    var next = kanbanFocusedColumnIndex - direction
    // Skip empty columns in the navigation direction.
    while columns.indices.contains(next) {
      let colTasks = tasksForKanbanColumn(columns[next], allColumns: columns)
      if !colTasks.isEmpty { break }
      next -= direction
    }
    guard columns.indices.contains(next) else { return }
    kanbanFocusedColumnIndex = next
    ds.currentSiblingIndex = 0
    let colTasks = tasksForKanbanColumn(columns[next], allColumns: columns)
    kanbanSelectedTaskId = colTasks.first?.id
  }

  @MainActor func nextKanbanTask() {
    guard let ds = dataSource else { return }
    let columns = kanbanColumns
    let effectiveFocusedIndex = resolvedFocusedColumnIndex(for: columns)
    guard columns.indices.contains(effectiveFocusedIndex) else { return }
    let colTasks = tasksForKanbanColumn(columns[effectiveFocusedIndex], allColumns: columns)
    guard !colTasks.isEmpty else { return }
    let currentIdx: Int
    if let selectedId = kanbanSelectedTaskId,
      let idx = colTasks.firstIndex(where: { $0.id == selectedId })
    {
      currentIdx = idx
    } else {
      currentIdx = -1
    }
    let newIdx = min(currentIdx + 1, colTasks.count - 1)
    kanbanFocusedColumnIndex = effectiveFocusedIndex
    ds.currentSiblingIndex = newIdx
    kanbanSelectedTaskId = colTasks[newIdx].id
  }

  @MainActor func previousKanbanTask() {
    guard let ds = dataSource else { return }
    let columns = kanbanColumns
    let effectiveFocusedIndex = resolvedFocusedColumnIndex(for: columns)
    guard columns.indices.contains(effectiveFocusedIndex) else { return }
    let colTasks = tasksForKanbanColumn(columns[effectiveFocusedIndex], allColumns: columns)
    guard !colTasks.isEmpty else { return }
    let currentIdx: Int
    if let selectedId = kanbanSelectedTaskId,
      let idx = colTasks.firstIndex(where: { $0.id == selectedId })
    {
      currentIdx = idx
    } else {
      currentIdx = colTasks.count
    }
    let newIdx = max(currentIdx - 1, 0)
    kanbanFocusedColumnIndex = effectiveFocusedIndex
    ds.currentSiblingIndex = newIdx
    kanbanSelectedTaskId = colTasks[newIdx].id
  }

  /// Returns the column index that actually contains `kanbanSelectedTaskId`, falling back to
  /// `kanbanFocusedColumnIndex` if the selected task is not found elsewhere.
  private func resolvedFocusedColumnIndex(for columns: [KanbanColumn]) -> Int {
    guard let selectedId = kanbanSelectedTaskId else { return kanbanFocusedColumnIndex }
    for (idx, col) in columns.enumerated() {
      let colTasks = tasksForKanbanColumn(col, allColumns: columns)
      if colTasks.contains(where: { $0.id == selectedId }) {
        return idx
      }
    }
    return kanbanFocusedColumnIndex
  }

  // MARK: - Scope navigation helpers

  /// Whether the current selection is at the first task in the focused column (or there are
  /// no tasks at all). Used by the keyboard router to decide whether UP arrow should enter
  /// the scope row instead of navigating within the column.
  var isAtTopOfFocusedColumn: Bool {
    let columns = kanbanColumns
    let effectiveIdx = resolvedFocusedColumnIndex(for: columns)
    guard columns.indices.contains(effectiveIdx) else { return true }
    let colTasks = tasksForKanbanColumn(columns[effectiveIdx], allColumns: columns)
    guard let first = colTasks.first else { return true }
    return kanbanSelectedTaskId == nil || kanbanSelectedTaskId == first.id
  }

  // MARK: - Selection clamping

  /// Re-validate kanbanSelectedTaskId after task mutations (complete, delete, reorder).
  /// If the selected task no longer exists in any column, pick the nearest task in the
  /// focused column so the selection doesn't jump to an unrelated task.
  @MainActor func clampKanbanSelection() {
    guard let ds = dataSource else { return }
    let columns = kanbanColumns
    // Check whether the current selection is still valid.
    if let selectedId = kanbanSelectedTaskId {
      let stillExists = columns.contains { col in
        tasksForKanbanColumn(col, allColumns: columns).contains { $0.id == selectedId }
      }
      if stillExists { return }
    }
    // Selection is stale — pick the nearest task in the focused column.
    guard columns.indices.contains(kanbanFocusedColumnIndex) else {
      kanbanSelectedTaskId = nil
      ds.currentSiblingIndex = 0
      return
    }
    let colTasks = tasksForKanbanColumn(
      columns[kanbanFocusedColumnIndex], allColumns: columns)
    if colTasks.isEmpty {
      kanbanSelectedTaskId = nil
      ds.currentSiblingIndex = 0
    } else {
      let idx = min(max(ds.currentSiblingIndex, 0), colTasks.count - 1)
      kanbanSelectedTaskId = colTasks[idx].id
      ds.currentSiblingIndex = idx
    }
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
}
