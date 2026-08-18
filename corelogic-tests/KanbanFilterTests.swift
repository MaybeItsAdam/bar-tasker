import XCTest

@testable import PriorityCore

/// `KanbanFilter` decides which column a card lands in and where it sits in
/// that column. It lived on `KanbanManager`, reading everything through a weak
/// data source back to the coordinator, so none of it could be reached from a
/// test — in the one view whose entire purpose is that placement.
final class KanbanFilterTests: XCTestCase {

  private func bucket(_ map: [Int: RootDueBucket]) -> (FixtureTask) -> RootDueBucket {
    { map[$0.id] ?? .noDueDate }
  }

  private func day(offset: Int) -> Date {
    let calendar = Calendar.current
    return calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: Date()))!
  }

  // MARK: - Tag matching

  func testABareConditionNameMatchesTheHashtagForm() {
    let task = FixtureTask(id: 1)
    XCTAssertTrue(
      KanbanFilter.hasTag(task, tag: "waiting", tagsByTaskId: [1: ["#waiting"]]))
  }

  func testASigilledConditionMatchesOnlyThatForm() {
    let task = FixtureTask(id: 1)
    XCTAssertTrue(KanbanFilter.hasTag(task, tag: "@waiting", tagsByTaskId: [1: ["@waiting"]]))
    XCTAssertFalse(
      KanbanFilter.hasTag(task, tag: "@waiting", tagsByTaskId: [1: ["#waiting"]]),
      "an explicit mention must not be satisfied by a hashtag")
  }

  func testTagMatchingIsCaseInsensitive() {
    XCTAssertTrue(
      KanbanFilter.hasTag(FixtureTask(id: 1), tag: "Waiting", tagsByTaskId: [1: ["#waiting"]]))
  }

  func testATaskWithNoTagsMatchesNoTagCondition() {
    XCTAssertFalse(KanbanFilter.hasTag(FixtureTask(id: 1), tag: "waiting", tagsByTaskId: [:]))
  }

  // MARK: - Conditions

  func testADueBucketConditionMatchesThatBucket() {
    let task = FixtureTask(id: 1)
    XCTAssertTrue(
      KanbanFilter.matches(
        task, condition: .dueBucket(RootDueBucket.today.rawValue),
        tagsByTaskId: [:], dueBucket: bucket([1: .today])))
    XCTAssertFalse(
      KanbanFilter.matches(
        task, condition: .dueBucket(RootDueBucket.today.rawValue),
        tagsByTaskId: [:], dueBucket: bucket([1: .future])))
  }

  func testAnUnrecognisedDueBucketRawValueMatchesNothing() {
    XCTAssertFalse(
      KanbanFilter.matches(
        FixtureTask(id: 1), condition: .dueBucket(999),
        tagsByTaskId: [:], dueBucket: bucket([1: .today])))
  }

  /// The catch-all deliberately claims nothing here. It is the caller's job to
  /// use it as "whatever no earlier column took" — if it matched eagerly, the
  /// first catch-all column would swallow the entire board.
  func testTheCatchAllConditionClaimsNothingOnItsOwn() {
    XCTAssertFalse(
      KanbanFilter.matches(
        FixtureTask(id: 1), condition: .catchAll,
        tagsByTaskId: [1: ["#anything"]], dueBucket: bucket([1: .today])))
  }

  func testAColumnMatchesWhenAnyOneOfItsConditionsDoes() {
    let column = KanbanColumn(
      name: "Today",
      conditions: [
        .dueBucket(RootDueBucket.overdue.rawValue),
        .dueBucket(RootDueBucket.today.rawValue),
      ])

    XCTAssertTrue(
      KanbanFilter.matchesColumn(
        FixtureTask(id: 1), column: column,
        tagsByTaskId: [:], dueBucket: bucket([1: .today])))
    XCTAssertFalse(
      KanbanFilter.matchesColumn(
        FixtureTask(id: 1), column: column,
        tagsByTaskId: [:], dueBucket: bucket([1: .tomorrow])))
  }

  func testExcludingTheCatchAllSkipsOnlyThatCondition() {
    let column = KanbanColumn(
      name: "Mixed", conditions: [.catchAll, .tag("waiting")])

    XCTAssertTrue(
      KanbanFilter.matchesColumn(
        FixtureTask(id: 1), column: column, includeCatchAll: false,
        tagsByTaskId: [1: ["#waiting"]], dueBucket: bucket([:])),
      "the tag condition still applies")
  }

  // MARK: - Column assignment

  func testATaskLandsInTheFirstColumnThatClaimsIt() {
    let columns = [
      KanbanColumn(name: "Today", conditions: [.dueBucket(RootDueBucket.today.rawValue)]),
      KanbanColumn(name: "Waiting", conditions: [.tag("waiting")]),
    ]

    let assigned = KanbanFilter.column(
      for: FixtureTask(id: 1), in: columns,
      tagsByTaskId: [1: ["#waiting"]], dueBucket: bucket([1: .today]))

    XCTAssertEqual(
      assigned?.name, "Today",
      "column order is the tie-break when a task matches more than one")
  }

  func testATaskMatchingNoColumnIsUnassigned() {
    let columns = [KanbanColumn(name: "Waiting", conditions: [.tag("waiting")])]

    XCTAssertNil(
      KanbanFilter.column(
        for: FixtureTask(id: 1), in: columns,
        tagsByTaskId: [:], dueBucket: bucket([1: .today])))
  }

  func testTheShippedDefaultColumnsPlaceATodayTaskInToday() {
    let assigned = KanbanFilter.column(
      for: FixtureTask(id: 1), in: KanbanColumn.defaults,
      tagsByTaskId: [:], dueBucket: bucket([1: .today]))

    XCTAssertEqual(assigned?.name, "Today")
  }

  func testTheShippedDefaultColumnsPlaceAWaitingTaskInWaitingOn() {
    let assigned = KanbanFilter.column(
      for: FixtureTask(id: 1), in: KanbanColumn.defaults,
      tagsByTaskId: [1: ["#waiting"]], dueBucket: bucket([1: .noDueDate]))

    XCTAssertEqual(assigned?.name, "Waiting On")
  }

  // MARK: - Subtree

  func testSubtreeTasksExcludesTheRootItself() {
    let tasks = [
      FixtureTask(id: 1),
      FixtureTask(id: 2, parentId: 1),
      FixtureTask(id: 3, parentId: 2),
      FixtureTask(id: 4),
    ]
    let byId = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })

    let subtree = KanbanFilter.subtreeTasks(in: tasks, rootId: 1, taskById: byId)

    XCTAssertEqual(subtree.map(\.id), [2, 3])
  }

  // MARK: - Ordering

  func testPositionOrderPutsUnpositionedTasksLast() {
    let tasks = [
      FixtureTask(id: 1, content: "no position"),
      FixtureTask(id: 2, content: "second", position: 2),
      FixtureTask(id: 3, content: "first", position: 1),
    ]

    let sorted = KanbanFilter.sorted(tasks, sortOrder: .position, inputs: .init())

    XCTAssertEqual(
      sorted.map(\.id), [3, 2, 1],
      "the board treats a missing position as last, unlike the list comparator")
  }

  func testDueAscendingOrdersByDateAndKeepsUndatedLast() {
    let tasks = [
      FixtureTask(id: 1, content: "undated", position: 1),
      FixtureTask(id: 2, content: "later", dueDate: day(offset: 5), position: 2),
      FixtureTask(id: 3, content: "sooner", dueDate: day(offset: 1), position: 3),
    ]

    let sorted = KanbanFilter.sorted(tasks, sortOrder: .dueAscending, inputs: .init())

    XCTAssertEqual(sorted.map(\.id), [3, 2, 1])
  }

  /// "Latest first" reverses the dates. It must not promote undated tasks —
  /// they have no date to be latest.
  func testDueDescendingReversesTheDatesButKeepsUndatedLast() {
    let tasks = [
      FixtureTask(id: 1, content: "undated", position: 1),
      FixtureTask(id: 2, content: "later", dueDate: day(offset: 5), position: 2),
      FixtureTask(id: 3, content: "sooner", dueDate: day(offset: 1), position: 3),
    ]

    let sorted = KanbanFilter.sorted(tasks, sortOrder: .dueDescending, inputs: .init())

    XCTAssertEqual(sorted.map(\.id), [2, 3, 1])
  }

  func testPriorityOrderPutsAbsoluteRanksAheadOfScopedOnes() {
    let tasks = [
      FixtureTask(id: 1, content: "scoped", position: 1),
      FixtureTask(id: 2, content: "absolute", position: 2),
      FixtureTask(id: 3, content: "unranked", position: 3),
    ]

    let sorted = KanbanFilter.sorted(
      tasks, sortOrder: .priorityAscending,
      inputs: .init(absolutePriorityRank: [2: 1], priorityRank: [1: 1]))

    XCTAssertEqual(sorted.map(\.id), [2, 1, 3])
  }

  func testEquallyRankedTasksFallBackToPosition() {
    let tasks = [
      FixtureTask(id: 1, content: "b", position: 2),
      FixtureTask(id: 2, content: "a", position: 1),
    ]

    let sorted = KanbanFilter.sorted(
      tasks, sortOrder: .priorityAscending,
      inputs: .init(priorityRank: [1: 1, 2: 1]))

    XCTAssertEqual(sorted.map(\.id), [2, 1])
  }

  func testPriorityThenDueUsesDueOnlyAfterPriorityTies() {
    let tasks = [
      FixtureTask(id: 1, content: "ranked but later", dueDate: day(offset: 9), position: 1),
      FixtureTask(id: 2, content: "unranked and sooner", dueDate: day(offset: 1), position: 2),
    ]

    let sorted = KanbanFilter.sorted(
      tasks, sortOrder: .priorityThenDueAscending,
      inputs: .init(priorityRank: [1: 1]))

    XCTAssertEqual(sorted.map(\.id), [1, 2], "priority wins before the date is consulted")
  }

  /// The last tie-break before position: with equal rank and equal date, a
  /// task carrying a tag is the more actionable one.
  func testPriorityThenDueBreaksRemainingTiesWithTagPresence() {
    let sameDate = day(offset: 2)
    let tasks = [
      FixtureTask(id: 1, content: "untagged", dueDate: sameDate, position: 1),
      FixtureTask(id: 2, content: "tagged", dueDate: sameDate, position: 2),
    ]

    let sorted = KanbanFilter.sorted(
      tasks, sortOrder: .priorityThenDueAscending,
      inputs: .init(tagsByTaskId: [2: ["#waiting"]]))

    XCTAssertEqual(sorted.map(\.id), [2, 1])
  }

  func testAlphabeticalIgnoresCaseAndFallsBackToPosition() {
    let tasks = [
      FixtureTask(id: 1, content: "banana", position: 2),
      FixtureTask(id: 2, content: "Apple", position: 3),
      FixtureTask(id: 3, content: "apple", position: 1),
    ]

    let sorted = KanbanFilter.sorted(tasks, sortOrder: .alphabetical, inputs: .init())

    XCTAssertEqual(sorted.map(\.id), [3, 2, 1])
  }

  func testEverySortOrderIsTotalAndLosesNothing() {
    let tasks = (1...6).map {
      FixtureTask(
        id: $0, content: "task \($0)",
        dueDate: $0.isMultiple(of: 2) ? day(offset: $0) : nil,
        position: $0.isMultiple(of: 3) ? nil : $0)
    }
    let inputs = KanbanFilter.SortInputs(
      absolutePriorityRank: [2: 1], priorityRank: [4: 1, 5: 2],
      tagsByTaskId: [3: ["#x"]])

    for order in KanbanSortOrder.allCases {
      let sorted = KanbanFilter.sorted(tasks, sortOrder: order, inputs: inputs)
      XCTAssertEqual(
        sorted.map(\.id).sorted(), tasks.map(\.id).sorted(),
        "\(order.rawValue) dropped or duplicated a card")
    }
  }
}
