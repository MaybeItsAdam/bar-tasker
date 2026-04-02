import XCTest

@testable import BarTaskerCore

final class BarTaskerCommandEngineCommandParsingTests: XCTestCase {

  // MARK: - Simple commands

  func testParseSimpleKeywordCommands() {
    XCTAssertEqual(BarTaskerCommandEngine.parse("done"), .done)
    XCTAssertEqual(BarTaskerCommandEngine.parse("undone"), .undone)
    XCTAssertEqual(BarTaskerCommandEngine.parse("invalidate"), .invalidate)
    XCTAssertEqual(BarTaskerCommandEngine.parse("edit"), .edit)
    XCTAssertEqual(BarTaskerCommandEngine.parse("search"), .search)
    XCTAssertEqual(BarTaskerCommandEngine.parse("undo"), .undo)
    XCTAssertEqual(BarTaskerCommandEngine.parse("delete"), .delete)
    XCTAssertEqual(BarTaskerCommandEngine.parse("toggle timer"), .toggleTimer)
    XCTAssertEqual(BarTaskerCommandEngine.parse("pause timer"), .pauseTimer)
    XCTAssertEqual(BarTaskerCommandEngine.parse("toggle hide future"), .toggleHideFuture)
  }

  func testParseCaseInsensitive() {
    XCTAssertEqual(BarTaskerCommandEngine.parse("DONE"), .done)
    XCTAssertEqual(BarTaskerCommandEngine.parse("Done"), .done)
    XCTAssertEqual(BarTaskerCommandEngine.parse("  done  "), .done)
  }

  // MARK: - Navigation

  func testParseNavigationCommands() {
    XCTAssertEqual(BarTaskerCommandEngine.parse("add sibling"), .addSibling)
    XCTAssertEqual(BarTaskerCommandEngine.parse("add child"), .addChild)
    XCTAssertEqual(BarTaskerCommandEngine.parse("move up"), .moveUp)
    XCTAssertEqual(BarTaskerCommandEngine.parse("move down"), .moveDown)
    XCTAssertEqual(BarTaskerCommandEngine.parse("enter children"), .enterChildren)
    XCTAssertEqual(BarTaskerCommandEngine.parse("exit parent"), .exitParent)
    XCTAssertEqual(BarTaskerCommandEngine.parse("open link"), .openLink)
  }

  // MARK: - Preferences aliases

  func testParsePreferencesAliases() {
    XCTAssertEqual(BarTaskerCommandEngine.parse("preferences"), .openPreferences)
    XCTAssertEqual(BarTaskerCommandEngine.parse("prefs"), .openPreferences)
    XCTAssertEqual(BarTaskerCommandEngine.parse("settings"), .openPreferences)
  }

  // MARK: - Due date

  func testParseDueCommand() {
    XCTAssertEqual(BarTaskerCommandEngine.parse("due today"), .due("today"))
    XCTAssertEqual(BarTaskerCommandEngine.parse("due tomorrow 9am"), .due("tomorrow 9am"))
    XCTAssertEqual(BarTaskerCommandEngine.parse("due next week"), .due("next week"))
  }

  func testParseClearDue() {
    XCTAssertEqual(BarTaskerCommandEngine.parse("clear due"), .clearDue)
  }

  // MARK: - Tags

  func testParseTagCommand() {
    XCTAssertEqual(BarTaskerCommandEngine.parse("tag urgent"), .tag("urgent"))
    XCTAssertEqual(BarTaskerCommandEngine.parse("tag  spaced "), .tag("spaced"))
  }

  func testParseUntagCommand() {
    XCTAssertEqual(BarTaskerCommandEngine.parse("untag urgent"), .untag("urgent"))
  }

  // MARK: - List

  func testParseListCommand() {
    XCTAssertEqual(BarTaskerCommandEngine.parse("list my-list"), .list("my-list"))
  }

  // MARK: - Priority

  func testParsePriorityRanks() {
    for rank in 1...9 {
      XCTAssertEqual(BarTaskerCommandEngine.parse("priority \(rank)"), .priority(rank))
    }
  }

  func testParsePriorityOutOfRange() {
    // 0 and 10+ fall through to unknown (not in 1...9 range)
    XCTAssertEqual(BarTaskerCommandEngine.parse("priority 0"), .unknown("priority 0"))
    XCTAssertEqual(BarTaskerCommandEngine.parse("priority 10"), .unknown("priority 10"))
  }

  func testParsePriorityBack() {
    XCTAssertEqual(BarTaskerCommandEngine.parse("priority back"), .priorityBack)
    XCTAssertEqual(BarTaskerCommandEngine.parse("priority end"), .priorityBack)
  }

  func testParsePriorityClear() {
    XCTAssertEqual(BarTaskerCommandEngine.parse("priority clear"), .clearPriority)
    XCTAssertEqual(BarTaskerCommandEngine.parse("clear priority"), .clearPriority)
    XCTAssertEqual(BarTaskerCommandEngine.parse("unpriority"), .clearPriority)
  }

  // MARK: - Obsidian

  func testParseObsidianSyncAliases() {
    XCTAssertEqual(BarTaskerCommandEngine.parse("sync obsidian"), .syncObsidian)
    XCTAssertEqual(BarTaskerCommandEngine.parse("send to obsidian"), .syncObsidian)
    XCTAssertEqual(BarTaskerCommandEngine.parse("obsidian"), .syncObsidian)
  }

  func testParseObsidianNewWindowAliases() {
    XCTAssertEqual(BarTaskerCommandEngine.parse("open obsidian new window"), .syncObsidianNewWindow)
    XCTAssertEqual(BarTaskerCommandEngine.parse("obsidian new window"), .syncObsidianNewWindow)
    XCTAssertEqual(BarTaskerCommandEngine.parse("open in new window"), .syncObsidianNewWindow)
  }

  func testParseObsidianFolderCommands() {
    XCTAssertEqual(BarTaskerCommandEngine.parse("link obsidian folder"), .linkObsidianFolder)
    XCTAssertEqual(BarTaskerCommandEngine.parse("link folder"), .linkObsidianFolder)
    XCTAssertEqual(BarTaskerCommandEngine.parse("obsidian folder"), .linkObsidianFolder)

    XCTAssertEqual(BarTaskerCommandEngine.parse("create obsidian folder"), .createObsidianFolder)
    XCTAssertEqual(BarTaskerCommandEngine.parse("new obsidian folder"), .createObsidianFolder)
    XCTAssertEqual(BarTaskerCommandEngine.parse("make obsidian folder"), .createObsidianFolder)

    XCTAssertEqual(
      BarTaskerCommandEngine.parse("clear obsidian folder"), .clearObsidianFolderLink)
    XCTAssertEqual(
      BarTaskerCommandEngine.parse("unlink obsidian folder"), .clearObsidianFolderLink)
    XCTAssertEqual(BarTaskerCommandEngine.parse("clear folder link"), .clearObsidianFolderLink)
  }

  // MARK: - Google Calendar

  func testParseGoogleCalendarCommandAliases() {
    XCTAssertEqual(BarTaskerCommandEngine.parse("sync google calendar"), .syncGoogleCalendar)
    XCTAssertEqual(BarTaskerCommandEngine.parse("google calendar"), .syncGoogleCalendar)
    XCTAssertEqual(BarTaskerCommandEngine.parse("gcal"), .syncGoogleCalendar)
    XCTAssertEqual(BarTaskerCommandEngine.parse("open google calendar"), .syncGoogleCalendar)
    XCTAssertEqual(BarTaskerCommandEngine.parse("calendar"), .syncGoogleCalendar)
  }

  // MARK: - Unknown

  func testParseUnknownCommand() {
    XCTAssertEqual(BarTaskerCommandEngine.parse("gibberish"), .unknown("gibberish"))
    XCTAssertEqual(BarTaskerCommandEngine.parse(""), .unknown(""))
  }

  // MARK: - Suggestion filtering

  func testGoogleCalendarSuggestionIsAvailable() {
    let suggestions = BarTaskerCommandEngine.filteredSuggestions(query: "google")
    XCTAssertTrue(
      suggestions.contains(where: {
        $0.command == "sync google calendar" && $0.keybind == "gc" && $0.submitImmediately
      })
    )
  }

  func testFilteredSuggestionsReturnsAllForEmptyQuery() {
    let all = BarTaskerCommandEngine.filteredSuggestions(query: "")
    XCTAssertEqual(all.count, min(8, BarTaskerCommandEngine.suggestions.count))
  }

  func testFilteredSuggestionsMatchesLabel() {
    let results = BarTaskerCommandEngine.filteredSuggestions(query: "timer")
    XCTAssertTrue(results.contains(where: { $0.command == "toggle timer" }))
    XCTAssertTrue(results.contains(where: { $0.command == "pause timer" }))
  }

  // MARK: - Due date resolution edge cases

  func testResolveDueDateNoonAndMidnight() {
    let calendar = makeUTCCalendar()
    let now = makeDate(year: 2026, month: 4, day: 1, hour: 10, minute: 0, calendar: calendar)

    XCTAssertEqual(
      BarTaskerCommandEngine.resolveDueDate("today noon", now: now, calendar: calendar),
      "2026-04-01 12:00:00 +0000"
    )
    XCTAssertEqual(
      BarTaskerCommandEngine.resolveDueDate("today midnight", now: now, calendar: calendar),
      "2026-04-01 00:00:00 +0000"
    )
  }

  func testResolveDueDateTwelveHourFormats() {
    let calendar = makeUTCCalendar()
    let now = makeDate(year: 2026, month: 4, day: 1, hour: 10, minute: 0, calendar: calendar)

    XCTAssertEqual(
      BarTaskerCommandEngine.resolveDueDate("12pm", now: now, calendar: calendar),
      "2026-04-01 12:00:00 +0000"
    )
    XCTAssertEqual(
      BarTaskerCommandEngine.resolveDueDate("12am", now: now, calendar: calendar),
      "2026-04-01 00:00:00 +0000"
    )
    XCTAssertEqual(
      BarTaskerCommandEngine.resolveDueDate("1:30pm", now: now, calendar: calendar),
      "2026-04-01 13:30:00 +0000"
    )
  }

  func testResolveDueDateTwentyFourHourFormat() {
    let calendar = makeUTCCalendar()
    let now = makeDate(year: 2026, month: 4, day: 1, hour: 10, minute: 0, calendar: calendar)

    XCTAssertEqual(
      BarTaskerCommandEngine.resolveDueDate("23:45", now: now, calendar: calendar),
      "2026-04-01 23:45:00 +0000"
    )
    XCTAssertEqual(
      BarTaskerCommandEngine.resolveDueDate("0:00", now: now, calendar: calendar),
      "2026-04-01 00:00:00 +0000"
    )
  }

  func testResolveDueDateRelativeOffsets() {
    let calendar = makeUTCCalendar()
    let now = makeDate(year: 2026, month: 4, day: 1, hour: 10, minute: 0, calendar: calendar)

    XCTAssertEqual(
      BarTaskerCommandEngine.resolveDueDate("in 30m", now: now, calendar: calendar),
      "2026-04-01 10:30:00 +0000"
    )
    XCTAssertEqual(
      BarTaskerCommandEngine.resolveDueDate("in 2h", now: now, calendar: calendar),
      "2026-04-01 12:00:00 +0000"
    )
    XCTAssertEqual(
      BarTaskerCommandEngine.resolveDueDate("in 1 day", now: now, calendar: calendar),
      "2026-04-02 10:00:00 +0000"
    )
    XCTAssertEqual(
      BarTaskerCommandEngine.resolveDueDate("in 45 minutes", now: now, calendar: calendar),
      "2026-04-01 10:45:00 +0000"
    )
  }

  func testResolveDueDatePassthroughForUnrecognized() {
    let calendar = makeUTCCalendar()
    let now = makeDate(year: 2026, month: 4, day: 1, hour: 10, minute: 0, calendar: calendar)

    // Unrecognized input should pass through unchanged
    XCTAssertEqual(
      BarTaskerCommandEngine.resolveDueDate("asap", now: now, calendar: calendar),
      "asap"
    )
    XCTAssertEqual(
      BarTaskerCommandEngine.resolveDueDate("", now: now, calendar: calendar),
      ""
    )
  }

  func testResolveDueDateWeekdays() {
    let calendar = makeUTCCalendar()
    // 2026-04-01 is a Wednesday
    let now = makeDate(year: 2026, month: 4, day: 1, hour: 10, minute: 0, calendar: calendar)

    // Friday should be 2 days out
    XCTAssertEqual(
      BarTaskerCommandEngine.resolveDueDate("friday", now: now, calendar: calendar),
      "2026-04-03"
    )
    // Next month
    XCTAssertEqual(
      BarTaskerCommandEngine.resolveDueDate("next month", now: now, calendar: calendar),
      "2026-05-01"
    )
  }

  func testResolveDueDateWithAtPrefix() {
    let calendar = makeUTCCalendar()
    let now = makeDate(year: 2026, month: 4, day: 1, hour: 10, minute: 0, calendar: calendar)

    XCTAssertEqual(
      BarTaskerCommandEngine.resolveDueDate("today at 3pm", now: now, calendar: calendar),
      "2026-04-01 15:00:00 +0000"
    )
  }

  // MARK: - Helpers

  private func makeUTCCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    return calendar
  }

  private func makeDate(
    year: Int,
    month: Int,
    day: Int,
    hour: Int,
    minute: Int,
    calendar: Calendar
  ) -> Date {
    let components = DateComponents(
      calendar: calendar,
      timeZone: calendar.timeZone,
      year: year,
      month: month,
      day: day,
      hour: hour,
      minute: minute
    )
    return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
  }
}
