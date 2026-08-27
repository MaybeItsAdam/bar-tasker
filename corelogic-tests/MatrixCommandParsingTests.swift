import XCTest

@testable import PriorityCore

/// `matrix <quadrant>` was documented in the README from the day the view
/// shipped, and only the two-number form was ever parsed — so the spelling the
/// manual taught was the one spelling that did nothing.
final class MatrixCommandParsingTests: XCTestCase {

  private func coordinate(_ command: String) -> (urgency: Double, importance: Double)? {
    guard case .matrix(let urgency, let importance) = CommandEngine.parse(command)
    else { return nil }
    return (urgency, importance)
  }

  func testEachQuadrantWordPlacesInThatQuadrant() {
    for quadrant in MatrixQuadrant.allCases {
      for word in quadrant.commandWords {
        guard let point = coordinate("matrix \(word)") else {
          return XCTFail("matrix \(word) did not parse")
        }
        XCTAssertEqual(
          MatrixGeometry.quadrant(urgency: point.urgency, importance: point.importance),
          quadrant,
          "matrix \(word)")
      }
    }
  }

  func testTheNumericFormStillParsesIncludingNegatives() {
    XCTAssertEqual(coordinate("matrix 5 -2")?.urgency, 5)
    XCTAssertEqual(coordinate("matrix 5 -2")?.importance, -2)
    XCTAssertEqual(coordinate("matrix -9 -9")?.urgency, -9)
  }

  func testOutOfRangeCoordinatesAreRejected() {
    XCTAssertNil(coordinate("matrix 12 3"))
  }

  func testBothSpellingsOfClearingReachTheUnsetSentinel() {
    XCTAssertEqual(coordinate("matrix clear")?.urgency, 0)
    XCTAssertEqual(coordinate("matrix clear")?.importance, 0)
    XCTAssertEqual(coordinate("clear matrix")?.urgency, 0)
  }
}
