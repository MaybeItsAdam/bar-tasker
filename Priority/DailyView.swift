import AppKit
import SwiftUI

/// The Daily root view: what today looks like, and what the recent run of days
/// looks like behind it.
///
/// Deliberately reads from the daily log rather than from the live task list.
/// Checkvist knows what is open right now; only the log knows what happened,
/// and "what happened" is the entire question this view answers.
struct DailyView: View {
  /// Shared with `PopoverView.panelHeight`, which reserves space for this
  /// section. Two independent guesses at the row height is how a view ends up
  /// with a nested scroll bar it was never meant to have.
  enum Layout {
    /// 13pt line box + `rowVerticalPadding` top and bottom.
    static let rowHeight: CGFloat = 30
    static let headerHeight: CGFloat = 26
    static let addFieldHeight: CGFloat = 32
    /// Eight rows before it scrolls. A morning routine is usually five to eight
    /// things, and scrolling a list you're working straight down is the one
    /// thing that makes it easy to lose your place.
    static let listMaxHeight: CGFloat = rowHeight * 8
    /// Taller than the shared 64pt: the chart is now shown from day one, so it
    /// spends its early life mostly flat and needs the height to read as a
    /// chart rather than as a rule.
    static let chartHeight: CGFloat = 84
  }

  @Environment(AppCoordinator.self) var manager

  @State private var hoveredBucketIndex: Int?
  /// Owned by the view rather than the manager: the router only needs to say
  /// "open the field", and where the caret goes after that is a view concern.
  @FocusState private var addFieldFocused: Bool

  private func themeColor(_ token: AppThemeColorToken) -> Color {
    manager.preferences.themeColor(for: token)
  }

  private var dailyLog: DailyLogManager { manager.dailyLog }

  var body: some View {
    // Read `revision` so recording an event re-renders the projections. The
    // log itself lives in the plugin and isn't observable — see DailyLogManager.
    let _ = dailyLog.revision
    let summary = dailyLog.summary()

    // No horizontal padding on the container: the dailies rows are full-bleed
    // like the task rows elsewhere, so their selection highlight reaches the
    // panel edge instead of floating in an inset box. Everything else insets
    // itself to the same `rowHorizontalPadding`.
    VStack(alignment: .leading, spacing: 10) {
      headline(summary)
        .padding(.horizontal, PopoverLayout.rowHorizontalPadding)
      // Above the chart on purpose: this is the part you act on, the chart is
      // the part you look at. Acting comes first.
      dailiesSection
      // Hidden from the dock's graph button, which makes this a plain
      // checklist for days you're only ticking things off.
      if manager.popoverChrome.showsDailyChart {
        Divider()
        chartSection
          .padding(.horizontal, PopoverLayout.rowHorizontalPadding)
      }
      if !summary.completed.isEmpty {
        Divider()
        completionsList(summary)
          .padding(.horizontal, PopoverLayout.rowHorizontalPadding)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
  }

  // MARK: - Headline

  /// The numbers stay visible as text at all times. Hover is an enhancement on
  /// the chart, never the only way to read a value.
  @ViewBuilder
  private func headline(_ summary: DayLogAggregator.DaySummary) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text("\(summary.completedCount)")
        .font(.system(size: 26, weight: .semibold))
        .foregroundColor(themeColor(.textPrimary))
      Text("done today")
        .font(.system(size: 13))
        .foregroundColor(themeColor(.textSecondary))
      Spacer()
      if summary.focusSeconds > 0 {
        statChip(
          value: DayLogFormatting.focusDuration(seconds: summary.focusSeconds),
          label: "focused"
        )
      }
      if let progress = dailyLog.dailyProgress {
        statChip(value: "\(progress.done)/\(progress.total)", label: "dailies")
      }
      if summary.plannedCount > 0 {
        statChip(value: "\(summary.unfinishedCount)", label: "left")
      }
    }
  }

  // MARK: - Dailies

  /// Today's recurring intentions, as a checklist.
  ///
  /// Built from the same measurements as `PopoverView.taskRow` — 13pt in the
  /// user's chosen task font, `PopoverLayout` row padding, full-bleed selection
  /// with the 3pt leading bar. These rows sit in the same popover as the task
  /// list and are read the same way, so they have no business being a smaller,
  /// separate visual language.
  @ViewBuilder
  private var dailiesSection: some View {
    let dailies = dailyLog.todaysDailies
    let completed = dailyLog.completedDailyIds()

    VStack(alignment: .leading, spacing: 0) {
      dailiesHeader

      if dailies.isEmpty && !dailyLog.isAddingDaily {
        emptyDailiesHint
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(dailies.enumerated()), id: \.element.id) { index, daily in
              dailyRow(
                daily,
                isDone: completed.contains(daily.id),
                isSelected: index == dailyLog.selectedDailyIndex
              )
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: Layout.listMaxHeight)
      }

      if dailyLog.isAddingDaily {
        addDailyField
      }
    }
  }

  /// Matches `PopoverView.dueSectionHeader`: uppercased, 10pt semibold, on the
  /// panel surface so it reads as a section rule rather than as content.
  @ViewBuilder
  private var dailiesHeader: some View {
    HStack(spacing: 6) {
      Text("DAILIES")
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(themeColor(.textSecondary))
      Spacer(minLength: 0)
      Button {
        dailyLog.isAddingDaily = true
      } label: {
        Image(systemName: "plus.circle.fill")
          .font(.system(size: 13))
          .foregroundColor(themeColor(.textSecondary))
      }
      .buttonStyle(.plain)
      .help("Add a daily (Return)")
      .accessibilityLabel("Add a daily")
    }
    .padding(.horizontal, PopoverLayout.rowHorizontalPadding)
    .padding(.top, 8)
    .padding(.bottom, 5)
    .background(themeColor(.panelSurface).opacity(0.7))
  }

  @ViewBuilder
  private func dailyRow(_ daily: Daily, isDone: Bool, isSelected: Bool) -> some View {
    HStack(alignment: .center, spacing: PopoverLayout.rowContentSpacing) {
      // Fixed-width icon slot, so titles line up with each other and with the
      // task rows in the other views rather than shifting with the glyph.
      Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
        .font(.system(size: 14))
        .foregroundColor(isDone ? themeColor(.success) : themeColor(.textMuted))
        .frame(width: PopoverLayout.rowIconWidth)

      Text(daily.title)
        .font(Typography.taskFont(size: 13, name: manager.preferences.appFontName))
        // Struck through *and* muted, so doneness never rests on colour alone.
        .strikethrough(isDone, color: themeColor(.textMuted))
        .foregroundColor(isDone ? themeColor(.textMuted) : themeColor(.textPrimary))
        .lineLimit(1)
        .truncationMode(.tail)

      Spacer(minLength: 0)

      if !daily.isEveryDay {
        Text(daily.scheduleLabel)
          .font(.system(size: 10, weight: .medium))
          .foregroundColor(themeColor(.textSecondary))
          .padding(.horizontal, 5)
          .padding(.vertical, 2)
          .background(
            RoundedRectangle(cornerRadius: 4)
              .fill(themeColor(.panelSurfaceElevated))
          )
      }
    }
    .padding(.horizontal, PopoverLayout.rowHorizontalPadding)
    .padding(.vertical, PopoverLayout.rowVerticalPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(isSelected ? themeColor(.selectionBackground).opacity(0.7) : Color.clear)
    .overlay(alignment: .leading) {
      Rectangle()
        .fill(isSelected ? themeColor(.selectionForeground) : Color.clear)
        .frame(width: 3)
    }
    .contentShape(Rectangle())
    // Click selects *and* ticks, because a daily has nothing else you'd click
    // it for — unlike a task row, where selection and completion are distinct.
    .onTapGesture {
      dailyLog.selectDaily(daily)
      dailyLog.toggleDaily(daily)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(daily.title), \(isDone ? "done" : "not done")")
    .accessibilityAddTraits(.isButton)
  }

  @ViewBuilder
  private var emptyDailiesHint: some View {
    Text("Nothing recurring yet. Press Return to add something you do every day.")
      .font(Typography.taskFont(size: 13, name: manager.preferences.appFontName))
      .foregroundColor(themeColor(.textMuted))
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, PopoverLayout.rowHorizontalPadding)
      .padding(.vertical, PopoverLayout.rowVerticalPadding)
  }

  @ViewBuilder
  private var addDailyField: some View {
    @Bindable var log = manager.dailyLog
    HStack(alignment: .center, spacing: PopoverLayout.rowContentSpacing) {
      Image(systemName: "plus")
        .font(.system(size: 14))
        .foregroundColor(themeColor(.textSecondary))
        .frame(width: PopoverLayout.rowIconWidth)
      TextField("New daily", text: $log.newDailyTitle)
        .textFieldStyle(.plain)
        .font(Typography.taskFont(size: 13, name: manager.preferences.appFontName))
        .foregroundColor(themeColor(.textPrimary))
        .focused($addFieldFocused)
        // Return keeps the field open so a routine can be typed in one go;
        // Escape is the way out. Adding five habits shouldn't need five clicks.
        .onSubmit { log.commitNewDaily() }
        .onExitCommand { log.cancelAddingDaily() }
        .onAppear { addFieldFocused = true }
    }
    .padding(.horizontal, PopoverLayout.rowHorizontalPadding)
    .padding(.vertical, PopoverLayout.inlineEntryVerticalPadding)
    .background(themeColor(.panelSurfaceElevated))
  }

  @ViewBuilder
  private func statChip(value: String, label: String) -> some View {
    VStack(alignment: .trailing, spacing: 0) {
      Text(value)
        .font(.system(size: 15, weight: .semibold))
        .foregroundColor(themeColor(.textPrimary))
      Text(label)
        .font(.system(size: 11))
        .foregroundColor(themeColor(.textSecondary))
    }
  }

  // MARK: - Chart

  /// Always drawn, from the first day.
  ///
  /// It used to be withheld until there were 14 days to plot, on the reasoning
  /// that a near-empty chart reads as broken. That was wrong: a flat run of
  /// days is a true statement about a history that has just started, and
  /// hiding it makes the view look unfinished instead. The "collecting since"
  /// line stays underneath while the window isn't full, so the flatline is
  /// explained rather than merely tolerated.
  @ViewBuilder
  private var chartSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      rangePicker
      chart(buckets: dailyLog.chartBuckets())
      if !dailyLog.hasFullChartHistory {
        Text(collectingSubtitle)
          .font(.system(size: 11))
          .foregroundColor(themeColor(.textMuted))
          .lineLimit(1)
      }
    }
  }

  /// One filter row above the chart, per the range it scopes.
  @ViewBuilder
  private var rangePicker: some View {
    HStack(spacing: 4) {
      Text(hoverLabel ?? "Completed per \(dailyLog.chartRange.bucketNoun)")
        .font(.system(size: 12))
        .foregroundColor(themeColor(.textSecondary))
        .lineLimit(1)
      Spacer(minLength: 8)
      ForEach(DailyChartRange.allCases) { range in
        Button {
          dailyLog.chartRange = range
          hoveredBucketIndex = nil
        } label: {
          Text(range.title)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
              dailyLog.chartRange == range
                ? themeColor(.selectionBackground) : Color.clear
            )
            .foregroundColor(
              dailyLog.chartRange == range
                ? themeColor(.selectionForeground) : themeColor(.textMuted)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(range.accessibilityTitle)
      }
    }
  }

  /// Columns, one per bucket. Not a line: completions are discrete counts with
  /// a lot of zeros, and a line would draw a slope through days nothing
  /// happened on. A day with no completions has to read as an absent bar.
  ///
  /// One hue for every bar — height already encodes magnitude, so shading
  /// taller bars darker would double-encode it and spend the only free channel
  /// on information the chart already shows. That channel goes to emphasis
  /// instead: today is the accent, every prior bucket is recessive, because the
  /// question is "today versus my normal".
  @ViewBuilder
  private func chart(buckets: [DayLogAggregator.Bucket]) -> some View {
    let maxCount = max(buckets.map(\.completed).max() ?? 0, 1)

    GeometryReader { proxy in
      let gap: CGFloat = 2
      let count = max(buckets.count, 1)
      let barWidth = max(1, (proxy.size.width - gap * CGFloat(count - 1)) / CGFloat(count))
      // Clamped, or the 4pt radius exceeds the bar width at the 90-day range
      // and the columns render as lollipops.
      let radius = min(4, barWidth / 2)

      HStack(alignment: .bottom, spacing: gap) {
        ForEach(Array(buckets.enumerated()), id: \.offset) { index, bucket in
          let isLast = index == buckets.count - 1
          let fraction = CGFloat(bucket.completed) / CGFloat(maxCount)
          // A bucket with work in it never rounds away to nothing.
          let height = bucket.completed == 0 ? 0 : max(2, fraction * (proxy.size.height - 1))

          VStack(spacing: 0) {
            Spacer(minLength: 0)
            UnevenRoundedRectangle(
              topLeadingRadius: radius,
              bottomLeadingRadius: 0,
              bottomTrailingRadius: 0,
              topTrailingRadius: radius
            )
            .fill(isLast ? themeColor(.focusRing) : themeColor(.textMuted).opacity(0.55))
            .frame(width: barWidth, height: height)
          }
          .frame(width: barWidth, height: proxy.size.height, alignment: .bottom)
          .contentShape(Rectangle())
          .onHover { inside in
            hoveredBucketIndex = inside ? index : (hoveredBucketIndex == index ? nil : hoveredBucketIndex)
          }
          .accessibilityLabel(
            "\(bucketLabel(bucket)): \(DayLogFormatting.pluralised(bucket.completed, "task", "tasks"))"
          )
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
      .overlay(alignment: .bottom) {
        // Solid hairline baseline, no gridlines — at this size a grid is noise,
        // and dashing it would read as a threshold that isn't there.
        Rectangle()
          .fill(themeColor(.panelDivider))
          .frame(height: 1)
      }
    }
    .frame(height: Layout.chartHeight)
  }

  private var hoverLabel: String? {
    guard let index = hoveredBucketIndex else { return nil }
    let buckets = dailyLog.chartBuckets()
    guard buckets.indices.contains(index) else { return nil }
    let bucket = buckets[index]
    return "\(bucketLabel(bucket)) — \(DayLogFormatting.pluralised(bucket.completed, "done", "done"))"
  }

  // Built once rather than per call: `bucketLabel` runs inside every bar's
  // accessibility label, so at the 90-day range a per-call formatter would mean
  // ninety allocations on each render. Same pattern as `ObsidianSyncService`.
  private static let dayLabelFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale.autoupdatingCurrent
    formatter.dateFormat = "EEE d MMM"
    return formatter
  }()

  /// Used for week-commencing labels and for the "collecting since" date.
  private static let shortDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale.autoupdatingCurrent
    formatter.dateFormat = "d MMM"
    return formatter
  }()

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale.autoupdatingCurrent
    formatter.timeStyle = .short
    formatter.dateStyle = .none
    return formatter
  }()

  private func bucketLabel(_ bucket: DayLogAggregator.Bucket) -> String {
    guard dailyLog.chartRange.isWeekly else {
      return Self.dayLabelFormatter.string(from: bucket.day)
    }
    return "w/c \(Self.shortDayFormatter.string(from: bucket.day))"
  }

  /// Shown under the chart while the window still reaches back further than the
  /// log does, so the flat left-hand side reads as "nothing recorded yet"
  /// rather than as "nothing done".
  private var collectingSubtitle: String {
    guard let firstDay = dailyLog.firstRecordedDay else {
      return "No history yet — today is day one."
    }
    return "Collecting since \(Self.shortDayFormatter.string(from: firstDay))."
  }

  // MARK: - Completions

  @ViewBuilder
  private func completionsList(_ summary: DayLogAggregator.DaySummary) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("DONE TODAY")
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(themeColor(.textSecondary))
        .padding(.bottom, 5)
      ScrollView {
        VStack(alignment: .leading, spacing: 4) {
          // Most recent first: the bottom of a long day is the part you're
          // actually checking.
          ForEach(Array(summary.completed.reversed().enumerated()), id: \.offset) { _, event in
            HStack(alignment: .center, spacing: 8) {
              Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(themeColor(.success))
                .frame(width: PopoverLayout.rowIconWidth)
              Text(event.title.isEmpty ? "(untitled)" : event.title)
                .font(Typography.taskFont(size: 12, name: manager.preferences.appFontName))
                .foregroundColor(themeColor(.textSecondary))
                .lineLimit(1)
                .truncationMode(.tail)
              Spacer(minLength: 0)
              Text(timeLabel(event.at))
                .font(.system(size: 11))
                .foregroundColor(themeColor(.textMuted))
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 96)
    }
  }

  private func timeLabel(_ date: Date) -> String {
    Self.timeFormatter.string(from: date)
  }
}
