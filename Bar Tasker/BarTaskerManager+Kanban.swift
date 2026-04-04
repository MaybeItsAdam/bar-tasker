import Foundation

extension BarTaskerManager {

  // MARK: - Task filtering for kanban columns

  /// Returns root-level tasks that belong to the given column.
  /// Column membership uses first-match semantics: a task belongs to the first column
  /// (in `allColumns` order) whose conditions it satisfies.
  func tasksForKanbanColumn(_ column: KanbanColumn, allColumns: [KanbanColumn]) -> [CheckvistTask] {
    var pool: [CheckvistTask]
    if kanbanFilterSubtasks && currentParentId != 0 {
      pool = tasks.filter { ($0.parentId ?? 0) == currentParentId }
    } else {
      pool = tasks.filter { $0.parentId == nil || $0.parentId == 0 }
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
    // Build a set of all tag-based and due-based conditions from earlier columns
    // so catch-all can exclude tasks already claimed.
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
    switch condition {
    case .tag(let name):
      return hasTag(task, tag: name)
    case .dueBucket(let raw):
      guard let bucket = RootDueBucket(rawValue: raw) else { return false }
      return rootDueBucket(for: task) == bucket
    case .catchAll:
      return true
    }
  }

  private func hasTag(_ task: CheckvistTask, tag: String) -> Bool {
    guard let tags = cache.tagsByTaskId[task.id] else { return false }
    let normalized = tag.hasPrefix("#") || tag.hasPrefix("@")
      ? tag.lowercased()
      : "#\(tag.lowercased())"
    return tags.contains(normalized)
  }

  private func sortedForKanban(_ tasks: [CheckvistTask], sortOrder: KanbanSortOrder) -> [CheckvistTask] {
    switch sortOrder {
    case .position:
      return tasks.sorted { lhs, rhs in
        switch (lhs.position, rhs.position) {
        case (.some(let l), .some(let r)) where l != r: return l < r
        default: return lhs.content.localizedCaseInsensitiveCompare(rhs.content) == .orderedAscending
        }
      }
    case .dueAscending:
      return tasks.sorted { lhs, rhs in
        switch (lhs.dueDate, rhs.dueDate) {
        case (.some(let l), .some(let r)): return l < r
        case (.some, .none): return true
        case (.none, .some): return false
        default: return lhs.content.localizedCaseInsensitiveCompare(rhs.content) == .orderedAscending
        }
      }
    case .dueDescending:
      return tasks.sorted { lhs, rhs in
        switch (lhs.dueDate, rhs.dueDate) {
        case (.some(let l), .some(let r)): return l > r
        case (.some, .none): return true
        case (.none, .some): return false
        default: return lhs.content.localizedCaseInsensitiveCompare(rhs.content) == .orderedAscending
        }
      }
    case .priorityAscending:
      return tasks.sorted { lhs, rhs in
        let lp = priorityRank(for: lhs)
        let rp = priorityRank(for: rhs)
        if let lp, let rp, lp != rp { return lp < rp }
        if lp != nil && rp == nil { return true }
        if lp == nil && rp != nil { return false }
        return lhs.content.localizedCaseInsensitiveCompare(rhs.content) == .orderedAscending
      }
    case .priorityThenDueAscending:
      return tasks.sorted { lhs, rhs in
        let lp = priorityRank(for: lhs)
        let rp = priorityRank(for: rhs)
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
        let lt = cache.tagsByTaskId[lhs.id] != nil
        let rt = cache.tagsByTaskId[rhs.id] != nil
        if lt != rt { return lt }
        return lhs.content.localizedCaseInsensitiveCompare(rhs.content) == .orderedAscending
      }
    case .alphabetical:
      return tasks.sorted {
        $0.content.localizedCaseInsensitiveCompare($1.content) == .orderedAscending
      }
    }
  }

  // MARK: - Moving tasks between columns

  /// Moves the currently selected task one column left or right and updates the task's
  /// tag / due-date to match the target column's first writable condition.
  /// The currently selected task in the focused kanban column.
  var currentKanbanTask: CheckvistTask? {
    guard kanbanColumns.indices.contains(kanbanFocusedColumnIndex) else { return nil }
    let col = kanbanColumns[kanbanFocusedColumnIndex]
    let colTasks = tasksForKanbanColumn(col, allColumns: kanbanColumns)
    guard !colTasks.isEmpty else { return nil }
    let idx = min(max(currentSiblingIndex, 0), colTasks.count - 1)
    return colTasks[idx]
  }

  @MainActor func moveCurrentTaskToKanbanColumn(direction: Int) async {
    guard rootTaskView == .kanban else { return }
    let columns = kanbanColumns
    guard !columns.isEmpty, let task = currentKanbanTask else { return }

    let currentColIndex = kanbanFocusedColumnIndex

    // Display is reversed, so visual right = lower array index.
    let targetIndex = currentColIndex - direction
    guard columns.indices.contains(targetIndex) else { return }
    let targetColumn = columns[targetIndex]

    guard let (newContent, newDue) = applyColumnConditions(
      to: task, targetColumn: targetColumn, allColumns: columns)
    else {
      errorMessage = "Can't move task into \"\(targetColumn.name)\" — no writable condition."
      return
    }

    // Shift focused column to follow the task
    kanbanFocusedColumnIndex = targetIndex
    currentSiblingIndex = 0

    if newContent != task.content || newDue != task.due {
      await updateTask(
        task: task,
        content: newContent != task.content ? newContent : nil,
        due: newDue != task.due ? newDue : nil
      )
    }
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
    let otherColumnTags: [String] = allColumns
      .filter { $0.id != targetColumn.id }
      .flatMap { col in
        col.conditions.compactMap {
          if case .tag(let t) = $0 { return t } else { return nil }
        }
      }
    for tag in otherColumnTags {
      content = content
        .replacingOccurrences(of: " #\(tag)", with: "")
        .replacingOccurrences(of: "#\(tag)", with: "")
        .trimmingCharacters(in: .whitespaces)
    }

    // Determine if the task's current column is due-bucket based.
    let currentColumn = columnForTask(task, in: allColumns)
    let sourceIsDueBased = currentColumn?.conditions.contains(where: {
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
      guard let bucket = RootDueBucket(rawValue: raw) else { return nil }
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

  @MainActor func moveTask(id taskId: Int, toColumn targetColumn: KanbanColumn) async {
    let columns = kanbanColumns
    guard let task = cache.taskById[taskId] else { return }
    guard let (newContent, newDue) = applyColumnConditions(
      to: task, targetColumn: targetColumn, allColumns: columns)
    else {
      errorMessage = "Can't move task into \"\(targetColumn.name)\" — no writable condition."
      return
    }
    if newContent != task.content || newDue != task.due {
      await updateTask(
        task: task,
        content: newContent != task.content ? newContent : nil,
        due: newDue != task.due ? newDue : nil
      )
    }
  }

  // MARK: - Column focus navigation (no task move)

  @MainActor func focusKanbanColumn(direction: Int) {
    guard rootTaskView == .kanban else { return }
    // Display is reversed, so visual right = lower array index.
    let next = kanbanFocusedColumnIndex - direction
    guard kanbanColumns.indices.contains(next) else { return }
    kanbanFocusedColumnIndex = next
    currentSiblingIndex = 0
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
