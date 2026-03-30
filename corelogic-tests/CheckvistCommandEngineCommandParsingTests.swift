import XCTest

@testable import BarTaskerCore

final class CheckvistCommandEngineCommandParsingTests: XCTestCase {
  func testParseGoogleCalendarCommandAliases() {
    XCTAssertEqual(CheckvistCommandEngine.parse("sync google calendar"), .syncGoogleCalendar)
    XCTAssertEqual(CheckvistCommandEngine.parse("google calendar"), .syncGoogleCalendar)
    XCTAssertEqual(CheckvistCommandEngine.parse("gcal"), .syncGoogleCalendar)
    XCTAssertEqual(CheckvistCommandEngine.parse("open google calendar"), .syncGoogleCalendar)
  }

  func testGoogleCalendarSuggestionIsAvailable() {
    let suggestions = CheckvistCommandEngine.filteredSuggestions(query: "google")
    XCTAssertTrue(
      suggestions.contains(where: {
        $0.command == "sync google calendar" && $0.keybind == "gc" && $0.submitImmediately
      })
    )
  }
}
