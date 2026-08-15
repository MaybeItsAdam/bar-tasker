import Foundation

/// Pure, stateless filter and sort functions for task visibility computation.
/// Extracted from `AppCoordinator+TaskScoping` so the algorithms can be
/// reasoned about and tested without coordinator state.
struct TaskFilterEngine {

  // MARK: - Due bucket classification

  static func classifyDueBucket(task: CheckvistTask) -> RootDueBucket {
    let dueText = task.due?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    guard !dueText.isEmpty else { return .noDueDate }
    if dueText == "asap" { return .asap }
    if dueText == "today" { return .today }
    if dueText == "tomorrow" || dueText == "tmr" { return .tomorrow }
    if dueText == "next week" || dueText == "next 7 days" { return .nextSevenDays }
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

  static func computeRootDueBuckets(tasks: [CheckvistTask]) -> [Int: RootDueBucket] {
    Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, classifyDueBucket(task: $0)) })
  }

  // MARK: - Tag extraction

  static let tagRegex: NSRegularExpression = {
    guard let regex = try? NSRegularExpression(pattern: "[@#][a-zA-Z0-9_\\-]+") else {
      fatalError("Failed to build task tag regex.")
    }
    return regex
  }()

  static func extractTagsByTaskId(tasks: [CheckvistTask]) -> [Int: [String]] {
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

  // MARK: - Ancestry

  static func isDescendant(
    _ task: CheckvistTask,
    of rootId: Int,
    taskById: [Int: CheckvistTask]
  ) -> Bool {
    if rootId == 0 { return true }
    var pid = task.parentId ?? 0
    while pid != 0 {
      if pid == rootId { return true }
      pid = taskById[pid]?.parentId ?? 0
    }
    return false
  }

  // MARK: - Comparators

  static func compareByPositionThenContent(_ lhs: CheckvistTask, _ rhs: CheckvistTask) -> Bool {
    switch (lhs.position, rhs.position) {
    case (.some(let leftPosition), .some(let rightPosition)) where leftPosition != rightPosition:
      return leftPosition < rightPosition
    default:
      break
    }
    return lhs.content.localizedCaseInsensitiveCompare(rhs.content) == .orderedAscending
  }

  static func compareByPriorityThenPosition(
    _ lhs: CheckvistTask,
    _ rhs: CheckvistTask,
    priorityRankById: [Int: Int],
    absolutePriorityRankById: [Int: Int]
  ) -> Bool {
    let leftAbsolute = absolutePriorityRankById[lhs.id]
    let rightAbsolute = absolutePriorityRankById[rhs.id]

    if let leftAbsolute, let rightAbsolute, leftAbsolute != rightAbsolute {
      return leftAbsolute < rightAbsolute
    }
    if leftAbsolute != nil && rightAbsolute == nil { return true }
    if leftAbsolute == nil && rightAbsolute != nil { return false }

    let leftPriority = priorityRankById[lhs.id]
    let rightPriority = priorityRankById[rhs.id]

    if let leftPriority, let rightPriority, leftPriority != rightPriority {
      return leftPriority < rightPriority
    }
    if leftPriority != nil && rightPriority == nil { return true }
    if leftPriority == nil && rightPriority != nil { return false }

    return compareByPositionThenContent(lhs, rhs)
  }

  static func compareByRootDueBucket(
    _ lhs: CheckvistTask,
    _ rhs: CheckvistTask,
    rootDueBucketById: [Int: RootDueBucket]
  ) -> Bool {
    let leftBucket = rootDueBucketById[lhs.id] ?? classifyDueBucket(task: lhs)
    let rightBucket = rootDueBucketById[rhs.id] ?? classifyDueBucket(task: rhs)
    if leftBucket != rightBucket {
      return leftBucket.rawValue < rightBucket.rawValue
    }

    switch (lhs.dueDate, rhs.dueDate) {
    case (.some(let leftDate), .some(let rightDate)) where leftDate != rightDate:
      return leftDate < rightDate
    default:
      break
    }

    return compareByPositionThenContent(lhs, rhs)
  }
}
