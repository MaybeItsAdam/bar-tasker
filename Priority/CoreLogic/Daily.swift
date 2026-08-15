import Foundation

/// A recurring thing you intend to do on a schedule — a habit, not a task.
///
/// Deliberately *not* a Checkvist task with a recurrence rule. A task models a
/// piece of work that exists until it is done; a daily models an intention that
/// resets. The difference shows up the moment you miss one: a recurring task
/// goes overdue and starts competing with real deadlines, whereas a missed daily
/// is simply a gap in the history. Nothing to clear, nothing to reschedule.
///
/// Because of that, a `Daily` carries no completion state at all. Whether it is
/// done is a question about *a particular day*, and the answer lives in the
/// append-only day log — see `DayLogAggregator.completedDailyIds`. Storing a
/// `isDoneToday` flag here would need clearing at rollover, and anything that
/// needs clearing at rollover eventually doesn't get cleared.
struct Daily: Codable, Equatable, Identifiable, Sendable {
  /// Stable across renames and reschedules, because the day log references it.
  /// A `String` rather than a `UUID` so log events stay readable by eye.
  let id: String
  var title: String
  /// Which weekdays this is expected on, in `Calendar` numbering (1 = Sunday).
  /// A full set means every day, which is the common case.
  var activeWeekdays: Set<Int>
  /// Manual display order. Habits are done in a routine order, so this is the
  /// user's arrangement rather than anything derived.
  var sortIndex: Int
  var createdAt: Date
  /// Set instead of deleting, so history that references this id still renders
  /// with a title rather than as an orphan.
  var archivedAt: Date?

  static let allWeekdays: Set<Int> = [1, 2, 3, 4, 5, 6, 7]
  static let mondayToFriday: Set<Int> = [2, 3, 4, 5, 6]

  init(
    id: String = UUID().uuidString,
    title: String,
    activeWeekdays: Set<Int> = Daily.allWeekdays,
    sortIndex: Int = 0,
    createdAt: Date = Date(),
    archivedAt: Date? = nil
  ) {
    self.id = id
    self.title = title
    self.activeWeekdays = activeWeekdays.isEmpty ? Daily.allWeekdays : activeWeekdays
    self.sortIndex = sortIndex
    self.createdAt = createdAt
    self.archivedAt = archivedAt
  }

  private enum CodingKeys: String, CodingKey {
    case id, title, activeWeekdays, sortIndex, createdAt, archivedAt
  }

  /// Hand-written purely to sort `activeWeekdays` on the way out.
  ///
  /// `Set` has no order, so the synthesised encoder emits whatever the hash
  /// happens to give — which changes between runs. That made every save a
  /// spurious diff in a file the user is invited to edit by hand, and made the
  /// file impossible to compare byte-for-byte against the one the MCP server
  /// writes (see `scripts/mcp_parity_check.py`). Decoding stays synthesised; a
  /// `Set` reads back from an array either way.
  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(title, forKey: .title)
    try container.encode(activeWeekdays.sorted(), forKey: .activeWeekdays)
    try container.encode(sortIndex, forKey: .sortIndex)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encodeIfPresent(archivedAt, forKey: .archivedAt)
  }

  var isArchived: Bool { archivedAt != nil }

  var isEveryDay: Bool { activeWeekdays == Daily.allWeekdays }

  /// Whether this is expected on the logical day beginning at `day`.
  ///
  /// Takes the *logical* day start, so a daily ticked at 01:00 under a 4am
  /// rollover is still measured against the weekday it belongs to rather than
  /// the one the wall clock has moved on to.
  func isDue(on day: Date, calendar: Calendar = .current) -> Bool {
    guard !isArchived else { return false }
    return activeWeekdays.contains(calendar.component(.weekday, from: day))
  }

  /// "Every day", "Weekdays", or an abbreviated list. Shown next to the title
  /// only when it isn't every day — the common case needs no annotation.
  var scheduleLabel: String {
    if isEveryDay { return "Every day" }
    if activeWeekdays == Daily.mondayToFriday { return "Weekdays" }
    let names = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    return activeWeekdays.sorted().map { names[$0] }.joined(separator: " ")
  }
}

/// The whole set of dailies, as persisted.
///
/// Wrapped in a struct rather than stored as a bare array so the file has a
/// version field from day one — the alternative is discovering you need one
/// after there is data in the wild.
struct DailyCollection: Codable, Equatable, Sendable {
  var version: Int
  var dailies: [Daily]

  init(dailies: [Daily] = []) {
    self.version = 1
    self.dailies = dailies
  }

  /// Active dailies in display order, filtered to those expected on `day`.
  func due(on day: Date, calendar: Calendar = .current) -> [Daily] {
    dailies
      .filter { $0.isDue(on: day, calendar: calendar) }
      .sorted { ($0.sortIndex, $0.createdAt) < ($1.sortIndex, $1.createdAt) }
  }

  /// Every non-archived daily in display order, regardless of schedule. What
  /// the settings editor lists.
  var active: [Daily] {
    dailies
      .filter { !$0.isArchived }
      .sorted { ($0.sortIndex, $0.createdAt) < ($1.sortIndex, $1.createdAt) }
  }

  func daily(withId id: String) -> Daily? {
    dailies.first { $0.id == id }
  }

  /// Appends at the end of the current order.
  mutating func add(_ daily: Daily) {
    var daily = daily
    daily.sortIndex = (dailies.map(\.sortIndex).max() ?? -1) + 1
    dailies.append(daily)
  }

  mutating func update(id: String, _ transform: (inout Daily) -> Void) {
    guard let index = dailies.firstIndex(where: { $0.id == id }) else { return }
    transform(&dailies[index])
  }

  /// Archives rather than removes, so past days that referenced it still render
  /// with a title instead of an orphaned id.
  mutating func archive(id: String, at date: Date = Date()) {
    update(id: id) { $0.archivedAt = date }
  }

  /// Moves a daily by `offset` places within the active order, renumbering the
  /// whole list so indices stay dense.
  mutating func move(id: String, by offset: Int) {
    var ordered = active
    guard let from = ordered.firstIndex(where: { $0.id == id }) else { return }
    let to = min(ordered.count - 1, max(0, from + offset))
    guard to != from else { return }
    let moved = ordered.remove(at: from)
    ordered.insert(moved, at: to)
    for (index, daily) in ordered.enumerated() {
      update(id: daily.id) { $0.sortIndex = index }
    }
  }
}
