import XCTest

@testable import BarTaskerCore

final class TimerStoreTests: XCTestCase {

  // MARK: - formatted()

  func testFormattedSeconds() {
    XCTAssertEqual(TimerStore.formatted(0), "0s")
    XCTAssertEqual(TimerStore.formatted(59), "59s")
  }

  func testFormattedMinutes() {
    XCTAssertEqual(TimerStore.formatted(60), "1.0m")
    XCTAssertEqual(TimerStore.formatted(594), "9.9m")
    XCTAssertEqual(TimerStore.formatted(600), "10m")
    XCTAssertEqual(TimerStore.formatted(3599), "59m")
  }

  func testFormattedHours() {
    XCTAssertEqual(TimerStore.formatted(3600), "1.0h")
    XCTAssertEqual(TimerStore.formatted(35640), "9.9h")
    XCTAssertEqual(TimerStore.formatted(36000), "10h")
  }

  // MARK: - childCountByTaskId()

  func testChildCountByTaskId() {
    let nodes = [
      TimerNode(id: 1, parentId: nil),
      TimerNode(id: 2, parentId: 1),
      TimerNode(id: 3, parentId: 1),
      TimerNode(id: 4, parentId: 2),
    ]
    let counts = TimerStore.childCountByTaskId(nodes: nodes)
    XCTAssertEqual(counts[1], 2)
    XCTAssertEqual(counts[2], 1)
    XCTAssertNil(counts[3])
    XCTAssertNil(counts[4])
  }

  // MARK: - rolledUpElapsedByTaskId()

  func testRolledUpElapsedSumsDescendants() {
    let nodes = [
      TimerNode(id: 1, parentId: nil),
      TimerNode(id: 2, parentId: 1),
      TimerNode(id: 3, parentId: 1),
    ]
    let elapsed: [Int: TimeInterval] = [1: 10, 2: 20, 3: 30]
    let rolled = TimerStore.rolledUpElapsedByTaskId(nodes: nodes, ownElapsed: elapsed)
    XCTAssertEqual(rolled[1], 60)  // 10 + 20 + 30
    XCTAssertEqual(rolled[2], 20)
    XCTAssertEqual(rolled[3], 30)
  }

  func testRolledUpElapsedWithNoOwnTime() {
    let nodes = [
      TimerNode(id: 1, parentId: nil),
      TimerNode(id: 2, parentId: 1),
    ]
    let elapsed: [Int: TimeInterval] = [2: 15]
    let rolled = TimerStore.rolledUpElapsedByTaskId(nodes: nodes, ownElapsed: elapsed)
    XCTAssertEqual(rolled[1], 15)
    XCTAssertEqual(rolled[2], 15)
  }
}
