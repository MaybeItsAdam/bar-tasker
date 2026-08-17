import CoreGraphics

/// How tall the Daily view's parts are.
///
/// Pure arithmetic, deliberately out of the view: `PopoverLayout.preferredHeight`
/// asks how tall the panel should be, and the dock's resize strip asks what the
/// chart contributes to that, so the numbers can't live in the view that draws
/// them.
///
/// The checklist itself is *not* sized from here. It takes the room left over,
/// up to `listMaxHeight`, and scrolls — which is why these numbers being a few
/// points out shows as a partially visible last row (a scroll affordance) and
/// never as a strip of bare panel under the list.
enum DailyChecklistLayout {
  // The block heights below are *measured*, not estimated — see the
  // `measuredHeight` diagnostic used to take them. Estimating them is how the
  // panel ended up 25pt shorter than its own contents, which shows as a row
  // sliced through the middle at the bottom of the list.

  /// 13pt line box + `rowVerticalPadding` top and bottom.
  ///
  /// 34pt rather than the 30 it started at, which sits with the 36pt a bare
  /// task row measures — a daily and a task share a panel and are read the same
  /// way, so they have no business being noticeably different heights. A tick
  /// target is also a thing you hit in a hurry.
  ///
  /// Applied as a fixed height rather than as padding: the schedule badge is a
  /// point taller than a bare title, so padded rows come out 34 or 35 depending
  /// on their content and the list stops landing on a clean grid.
  static let rowHeight: CGFloat = 34
  /// "DAILIES" + its 8pt top and 5pt bottom padding.
  static let headerHeight: CGFloat = 28
  /// The view's top padding, the "N done today" line, and the 10pt stack
  /// spacing under it.
  static let headlineBlockHeight: CGFloat = 10 + 43 + 10
  /// A `Divider` is a child of the stack, so it costs the 10pt spacing on
  /// *both* sides as well as its own hairline. Missing this is what made every
  /// estimate of the chart's cost 20pt short.
  static let dividerBlockHeight: CGFloat = 10 + 1 + 10
  /// The capped "done today" list, when the day has anything in it.
  static let completionsHeight: CGFloat = 128
  /// Two lines: the entry row, and the "Return adds · Esc cancels" hint under
  /// it. Reserved exactly while the field is open, so it has to move whenever
  /// the row does.
  static let addFieldHeight: CGFloat = 46
  /// Eight rows before it scrolls. A morning routine is usually five to eight
  /// things, and scrolling a list you're working straight down is the one thing
  /// that makes it easy to lose your place.
  static let listMaxHeight: CGFloat = rowHeight * 8
  /// Taller than the shared 64pt: the chart is shown from day one, so it spends
  /// its early life mostly flat and needs the height to read as a chart rather
  /// than as a rule.
  static let chartHeight: CGFloat = 84

  /// The chart with its divider: the range row above it, the chart itself, and
  /// the "collecting since" line below while the window isn't full. Zero when
  /// the dock's graph button is off, which is what makes hiding the graph
  /// shorten the panel by exactly this much.
  static func chartBlockHeight(showsChart: Bool, hasFullChartHistory: Bool) -> CGFloat {
    guard showsChart else { return 0 }
    return dividerBlockHeight + chartHeight + 30 + (hasFullChartHistory ? 0 : 16)
  }

  /// Everything in the view except the daily rows themselves.
  static func reservedHeight(
    showsChart: Bool,
    hasFullChartHistory: Bool,
    hasCompletions: Bool,
    isAddingDaily: Bool
  ) -> CGFloat {
    headlineBlockHeight + headerHeight
      + (isAddingDaily ? addFieldHeight : 0)
      + chartBlockHeight(showsChart: showsChart, hasFullChartHistory: hasFullChartHistory)
      + (hasCompletions ? dividerBlockHeight + completionsHeight : 0)
  }

  /// What the checklist would like: one row each, up to the cap.
  static func preferredRowsHeight(count: Int) -> CGFloat {
    min(listMaxHeight, max(rowHeight, CGFloat(count) * rowHeight))
  }

  /// The height the Daily view wants when nothing has been dragged: everything
  /// else, plus a row for every daily up to the cap.
  static func contentHeight(reserved: CGFloat, count: Int) -> CGFloat {
    reserved + preferredRowsHeight(count: count)
  }
}
