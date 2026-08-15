import Foundation

// MARK: - KanbanColumnCondition

enum KanbanColumnCondition: Codable, Hashable {
  /// Task has this tag in its content (without the # prefix).
  case tag(String)
  /// Task falls in this due bucket (stored as RootDueBucket.rawValue).
  case dueBucket(Int)
  /// Catch-all: matches any task not already claimed by an earlier column.
  case catchAll

  var displayTitle: String {
    switch self {
    case .tag(let name): return "#\(name)"
    case .dueBucket(let raw):
      return RootDueBucket(rawValue: raw)?.title ?? "Due bucket \(raw)"
    case .catchAll: return "Everything else"
    }
  }

  /// Whether moving a task into this condition is actionable (can set a due date or tag).
  var isWritable: Bool {
    switch self {
    case .tag: return true
    case .dueBucket(let raw):
      guard let bucket = RootDueBucket(rawValue: raw) else { return false }
      switch bucket {
      case .today, .tomorrow, .nextSevenDays, .noDueDate: return true
      default: return false
      }
    case .catchAll: return true
    }
  }
}

// MARK: - KanbanSortOrder

enum KanbanSortOrder: String, Codable, CaseIterable, Identifiable {
  case position
  case dueAscending
  case dueDescending
  case priorityAscending
  case priorityThenDueAscending
  case alphabetical

  var id: String { rawValue }

  var title: String {
    switch self {
    case .position: return "Default order"
    case .dueAscending: return "Due date (earliest first)"
    case .dueDescending: return "Due date (latest first)"
    case .priorityAscending: return "Priority (highest first)"
    case .priorityThenDueAscending: return "Priority, then due date"
    case .alphabetical: return "Alphabetical"
    }
  }
}

// MARK: - KanbanColumn

struct KanbanColumn: Identifiable, Codable {
  var id: UUID
  var name: String
  /// A task matches this column if it satisfies ANY of these conditions (OR logic).
  /// Columns are evaluated in order; a task belongs to the first column it matches.
  var conditions: [KanbanColumnCondition]
  var sortOrder: KanbanSortOrder

  init(
    id: UUID = UUID(),
    name: String,
    conditions: [KanbanColumnCondition],
    sortOrder: KanbanSortOrder = .position
  ) {
    self.id = id
    self.name = name
    self.conditions = conditions
    self.sortOrder = sortOrder
  }

  // Stored in evaluation order (specific first, catch-all last).
  // The board displays them reversed so Today is on the right.
  static var defaults: [KanbanColumn] {
    [
      KanbanColumn(
        name: "Today",
        conditions: [
          .dueBucket(RootDueBucket.asap.rawValue),
          .dueBucket(RootDueBucket.overdue.rawValue),
          .dueBucket(RootDueBucket.today.rawValue),
        ],
        sortOrder: .priorityThenDueAscending
      ),
      KanbanColumn(
        name: "Next 7 Days",
        conditions: [
          .dueBucket(RootDueBucket.tomorrow.rawValue),
          .dueBucket(RootDueBucket.nextSevenDays.rawValue),
        ],
        sortOrder: .priorityThenDueAscending
      ),
      KanbanColumn(
        name: "Waiting On",
        conditions: [.tag("waiting")],
        sortOrder: .priorityThenDueAscending
      ),
      KanbanColumn(
        name: "Backlog",
        conditions: [.tag("backlog")],
        sortOrder: .priorityThenDueAscending
      ),
    ]
  }
}
