import CoreGraphics
import XCTest

@testable import PriorityCore

/// The Daily view's height budget.
///
/// The checklist deliberately isn't sized from these numbers — it takes what is
/// left and scrolls — so what's pinned here is the *panel* side: what each
/// block costs, and the fact that the chart's cost is separable, which is what
/// lets the graph button move the bottom of the panel instead of squeezing the
/// list.
final class DailyChecklistLayoutTests: XCTestCase {

  private let bareReserved = DailyChecklistLayout.reservedHeight(
    showsChart: false, hasFullChartHistory: true,
    hasCompletions: false, isAddingDaily: false)

  func testAPanelSizedFromItsContentFitsEveryRow() {
    let panel = DailyChecklistLayout.contentHeight(reserved: bareReserved, count: 5)
    XCTAssertEqual(panel - bareReserved, 5 * DailyChecklistLayout.rowHeight)
  }

  /// The ground truth, taken by measuring the rendered view rather than adding
  /// up what the code looks like it should produce.
  ///
  /// With the popover at these numbers the Daily view came back as exactly
  /// `10 top + 43 headline + 10 spacing + 28 header + 240 list = 331`, and with
  /// the chart on, `+ 10 + 1 divider + 10 + 130 chart`. An estimate that is a
  /// few points under leaves the last row sliced through the middle; a few
  /// points over leaves a strip of bare panel under the list. Both were shipped
  /// before these were measured.
  func testTheReservedHeightsMatchWhatTheViewActuallyRenders() {
    XCTAssertEqual(bareReserved, 91)
    XCTAssertEqual(
      DailyChecklistLayout.reservedHeight(
        showsChart: true, hasFullChartHistory: false,
        hasCompletions: false, isAddingDaily: false),
      242
    )
  }

  /// Eight rows is the cap, so a long routine scrolls rather than growing the
  /// panel without limit.
  func testALongListStopsAtTheCap() {
    XCTAssertEqual(
      DailyChecklistLayout.preferredRowsHeight(count: 40), DailyChecklistLayout.listMaxHeight)
    XCTAssertEqual(
      DailyChecklistLayout.preferredRowsHeight(count: 8), DailyChecklistLayout.listMaxHeight)
  }

  /// An empty day still gets a row's worth of room for its "nothing recurring
  /// yet" line.
  func testAnEmptyListStillReservesARow() {
    XCTAssertEqual(
      DailyChecklistLayout.preferredRowsHeight(count: 0), DailyChecklistLayout.rowHeight)
  }

  /// The graph button's contract: turning the chart on costs exactly the chart
  /// block and nothing else, so a dragged height stored without it can have it
  /// added back to grow the panel by that much.
  func testTheChartIsSeparableFromEverythingElse() {
    let charted = DailyChecklistLayout.reservedHeight(
      showsChart: true, hasFullChartHistory: true,
      hasCompletions: false, isAddingDaily: false)
    XCTAssertEqual(
      charted - bareReserved,
      DailyChecklistLayout.chartBlockHeight(showsChart: true, hasFullChartHistory: true)
    )
  }

  /// A run-up chart carries the "collecting since" line underneath it, so it is
  /// taller than a full one — the panel has to reserve for the version showing.
  func testAPartialHistoryChartReservesMore() {
    XCTAssertGreaterThan(
      DailyChecklistLayout.chartBlockHeight(showsChart: true, hasFullChartHistory: false),
      DailyChecklistLayout.chartBlockHeight(showsChart: true, hasFullChartHistory: true)
    )
    XCTAssertEqual(
      DailyChecklistLayout.chartBlockHeight(showsChart: false, hasFullChartHistory: false), 0)
  }

  /// Each block that appears is reserved for, or the panel is too short for its
  /// own contents and the checklist is what gets squeezed.
  func testEveryOptionalBlockCostsHeight() {
    let withCompletions = DailyChecklistLayout.reservedHeight(
      showsChart: false, hasFullChartHistory: true,
      hasCompletions: true, isAddingDaily: false)
    let withAddField = DailyChecklistLayout.reservedHeight(
      showsChart: false, hasFullChartHistory: true,
      hasCompletions: false, isAddingDaily: true)

    // The completions list arrives with a divider above it, and a divider is a
    // stack child — so it costs the 10pt spacing on both sides too.
    XCTAssertEqual(
      withCompletions - bareReserved,
      DailyChecklistLayout.dividerBlockHeight + DailyChecklistLayout.completionsHeight)
    XCTAssertEqual(withAddField - bareReserved, DailyChecklistLayout.addFieldHeight)
  }
}
