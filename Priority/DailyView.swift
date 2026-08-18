import AppKit
import PriorityCore
import SwiftUI

/// The Daily root view: what today looks like, and what the recent run of days
/// looks like behind it.
///
/// Deliberately reads from the daily log rather than from the live task list.
/// Checkvist knows what is open right now; only the log knows what happened,
/// and "what happened" is the entire question this view answers.
struct DailyView: View {
  /// The sizing arithmetic, which lives in `CoreLogic` so it can be tested
  /// without a window — see `DailyChecklistLayout`. `PopoverLayout` reads the
  /// same type when it decides how tall the panel should be.
  typealias Layout = DailyChecklistLayout

  @Environment(AppCoordinator.self) var manager

  @State private var hoveredBucketIndex: Int?
  /// Owned by the view rather than the manager: the router only needs to say
  /// "open the field", and where the caret goes after that is a view concern.
  @FocusState private var addFieldFocused: Bool
  /// Separate from `addFieldFocused` because the two fields can never be open
  /// at once but *can* hand over to each other, and one shared flag would leave
  /// the incoming field fighting the outgoing one for first responder.
  @FocusState private var editFieldFocused: Bool

  private func themeColor(_ token: AppThemeColorToken) -> Color {
    manager.preferences.themeColor(for: token)
  }

  private var dailyLog: DailyLogManager { manager.dailyLog }

  var body: some View {
    // Read `revision` so recording an event re-renders the projections. The
    // log itself lives in the plugin and isn't observable — see DailyLogManager.
    // `let _ =`, not `_ =`: inside a ViewBuilder the latter is parsed as a
    // view expression and fails to compile. swiftlint:disable:next redundant_discardable_let
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
      // Off unless the dock's list button is on. This view answers "what do I
      // do every day"; what you happened to close in the All list is a
      // different question, and having it always stacked underneath made the
      // checklist look like a footnote to it.
      if PopoverLayout.dailyShowsCompletions(for: manager) {
        Divider()
        completionsList(summary)
          .padding(.horizontal, PopoverLayout.rowHorizontalPadding)
      }
    }
    // Top only, and no trailing `Spacer`. A spacer of zero height still costs
    // the stack's 10pt spacing in front of it, so the two together left 20pt of
    // bare panel under the checklist — a grey bar between the last row and the
    // dock that no amount of sizing the list differently could remove.
    .padding(.top, 10)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        // `ScrollViewReader`, because the selection is moved by the keyboard
        // from `KeyboardShortcutRouter` and the list has no idea it happened.
        // Without this, j/↓ walks the cursor straight off the bottom of a
        // clipped list and the view sits still while it goes.
        ScrollViewReader { proxy in
          ScrollView {
            VStack(alignment: .leading, spacing: 0) {
              ForEach(Array(dailies.enumerated()), id: \.element.id) { index, daily in
                dailyRow(
                  daily,
                  isDone: completed.contains(daily.id),
                  isSelected: index == dailyLog.selectedDailyIndex
                )
                .id(daily.id)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          // Fills whatever room is left, and scrolls. Not a fixed height and
          // not a computed one: either leaves a strip of bare panel under the
          // last row, or overflows the window and pushes the dock off the
          // bottom. The eight-row cap lives in `preferredRowsHeight`, where it
          // decides how tall the *panel* gets when nothing has been dragged —
          // applying it here as well would cap a panel you deliberately dragged
          // taller, leaving the extra as dead space.
          .frame(maxHeight: .infinity)
          .onChange(of: dailyLog.selectedDailyIndex) { _, index in
            guard dailies.indices.contains(index) else { return }
            // No anchor: scroll the minimum needed to bring the row into view,
            // so walking down a list moves it a row at a time rather than
            // yanking the selection to the middle on every keypress.
            withAnimation(.easeOut(duration: 0.12)) {
              proxy.scrollTo(dailies[index].id)
            }
          }
        }
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
      // Toggles rather than only opening: a button that does nothing when the
      // field is already showing is a button that looks broken.
      Button {
        if dailyLog.isAddingDaily {
          dailyLog.cancelAddingDaily()
        } else {
          dailyLog.isAddingDaily = true
        }
      } label: {
        Image(systemName: dailyLog.isAddingDaily ? "xmark.circle.fill" : "plus.circle.fill")
          .font(.system(size: 13))
          .foregroundColor(themeColor(.textSecondary))
      }
      .buttonStyle(.plain)
      .help(
        dailyLog.isAddingDaily
          ? "Stop adding (Esc)"
          : "Add a daily (Return). Rename with a, delete with Delete."
      )
      .accessibilityLabel(dailyLog.isAddingDaily ? "Stop adding a daily" : "Add a daily")
    }
    .padding(.horizontal, PopoverLayout.rowHorizontalPadding)
    .padding(.top, 8)
    .padding(.bottom, 5)
    .background(themeColor(.panelSurface).opacity(0.7))
  }

  @ViewBuilder
  private func dailyRow(_ daily: Daily, isDone: Bool, isSelected: Bool) -> some View {
    let isCompleting = manager.celebration.completingDailyId == daily.id
    let isEditing = dailyLog.editingDailyId == daily.id
    // The tint/scale/strike half of the active preset only. A ticked daily
    // *stays* in the list, unlike a completed task, so the collapse-and-fade
    // half would fold the row shut and then spring it straight back.
    let treatment = manager.celebration.rowTreatment
    let reduceMotion = manager.celebration.prefersReducedMotion

    HStack(alignment: .center, spacing: PopoverLayout.rowContentSpacing) {
      // Fixed-width icon slot, so titles line up with each other and with the
      // task rows in the other views rather than shifting with the glyph.
      Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
        .font(.system(size: 14))
        .foregroundColor(isDone ? themeColor(.success) : themeColor(.textMuted))
        // The glyph swap is the moment a tick is actually felt, so it gets a
        // transition rather than a cut — and a pop on top of it while the
        // celebration runs. See `CelebrationRowTreatment.iconPop` for why the
        // emphasis lives here rather than on the row.
        .contentTransition(.symbolEffect(.replace))
        .scaleEffect(isCompleting ? treatment.iconPop : 1.0)
        .animation(CelebrationMotion.icon(reduceMotion: reduceMotion), value: isCompleting)
        .frame(width: PopoverLayout.rowIconWidth)

      if isEditing {
        editDailyField
      } else {
        Text(daily.title)
          .font(Typography.taskFont(size: 13, name: manager.preferences.appFontName))
          // Struck through *and* muted, so doneness never rests on colour alone.
          //
          // Suppressed while the celebration runs, so the drawn rule below can
          // perform it as a motion. This is the fix for the Daily view's
          // completion looking broken: `toggleDaily` records the tick and bumps
          // the revision *before* `onDailyTicked` fires, so the row was already
          // wearing its final strikethrough by the time the strike animation
          // started, and the animation had nothing left to say.
          .strikethrough(isDone && !isCompleting, color: themeColor(.textMuted))
          .foregroundColor(isDone ? themeColor(.textMuted) : themeColor(.textPrimary))
          .lineLimit(1)
          .truncationMode(.tail)
          .overlay(alignment: .center) {
            // The same drawn rule the task rows use, rather than the boolean
            // `.strikethrough` — a modifier SwiftUI cannot interpolate, and so
            // cannot animate. Presets that say removal is the effect opt out.
            if treatment.drawsStrikethrough {
              Rectangle()
                .fill(themeColor(.success).opacity(0.65))
                .frame(height: 1.5)
                .scaleEffect(x: isCompleting ? 1.0 : 0.001, y: 1, anchor: .leading)
                .animation(
                  CelebrationMotion.strike(reduceMotion: reduceMotion), value: isCompleting)
            }
          }
      }

      Spacer(minLength: 0)

      // Hidden while renaming: the field wants the width, and a schedule badge
      // is not something you can act on from the keyboard mid-edit anyway.
      if !daily.isEveryDay && !isEditing {
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
    // A fixed height, not padding: the schedule badge is a point taller than a
    // bare title, so padded rows come out 34 or 35 depending on their content
    // and the list stops landing on a clean grid.
    .frame(height: Layout.rowHeight)
    .frame(maxWidth: .infinity, alignment: .leading)
    .scaleEffect(isCompleting ? treatment.scale : 1.0)
    .background {
      // Layered, not swapped. The tint used to *replace* the selection
      // highlight for the length of the celebration, so ticking the row you
      // were sitting on made the cursor appear to leave and come back.
      ZStack {
        if isSelected { themeColor(.selectionBackground).opacity(0.7) }
        if isCompleting && treatment.tintOpacity > 0 {
          themeColor(.success).opacity(treatment.tintOpacity)
        }
      }
    }
    .overlay(alignment: .leading) {
      Rectangle()
        .fill(
          isCompleting && treatment != .none
            ? themeColor(.success)
            : isSelected ? themeColor(.selectionForeground) : Color.clear
        )
        .frame(width: 3)
    }
    // Below the background and the leading bar, deliberately: `.animation`
    // only covers what is already applied above it. Attached where it used to
    // be — directly under `scaleEffect` — it left the tint and the bar outside
    // its scope, so those snapped on and off while the row sprang, which is
    // most of why the effect read as a twitch.
    .animation(CelebrationMotion.row(reduceMotion: reduceMotion), value: isCompleting)
    .overlay {
      if isCompleting, let accent = manager.celebration.rowAccent(for: .daily(id: daily.id)) {
        accent
          .id(daily.id)
          .allowsHitTesting(false)
      }
    }
    .contentShape(Rectangle())
    // Click selects *and* ticks, because a daily has nothing else you'd click
    // it for — unlike a task row, where selection and completion are distinct.
    // Not while renaming, though: a click into the field would tick the thing
    // you are in the middle of naming.
    .onTapGesture {
      guard !isEditing else { return }
      dailyLog.selectDaily(daily)
      dailyLog.toggleDaily(daily)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(daily.title), \(isDone ? "done" : "not done")")
    .accessibilityAddTraits(.isButton)
  }

  /// Renaming a daily in place.
  ///
  /// A draft in the manager rather than a binding straight through to the
  /// store. Writing every keystroke through was how the settings editor did it,
  /// and it could not be typed in: the store trims what it is handed and
  /// rejects an empty result, so a trailing space was swallowed the moment it
  /// was typed and clearing the field snapped the old name back. See
  /// `DailyTitleEdit`.
  @ViewBuilder
  private var editDailyField: some View {
    @Bindable var log = manager.dailyLog
    TextField("Daily name", text: $log.editingDailyTitle)
      .textFieldStyle(.plain)
      .font(Typography.taskFont(size: 13, name: manager.preferences.appFontName))
      .foregroundColor(themeColor(.textPrimary))
      .focused($editFieldFocused)
      .onSubmit { log.commitDailyEdit() }
      // The fallback, not the mechanism — the popover's key router sees Escape
      // first. Same arrangement as the add field above.
      .onExitCommand { log.cancelDailyEdit() }
      .onAppear { editFieldFocused = true }
      // Clicking away commits rather than discarding. Abandoning what someone
      // just typed because they reached for the mouse is the wrong default;
      // Escape is there for when discarding is what they meant.
      .onChange(of: editFieldFocused) { _, focused in
        if !focused { log.commitDailyEdit() }
      }
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
    VStack(alignment: .leading, spacing: 3) {
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
          //
          // `onExitCommand` is the fallback, not the mechanism: the popover's
          // key router sees Escape first and cancels there. This stays for the
          // case where the field is focused without that router in play.
          .onSubmit { log.commitNewDaily() }
          .onExitCommand { log.cancelAddingDaily() }
          .onAppear { addFieldFocused = true }

        newDailyScheduleMenu

        Button {
          log.cancelAddingDaily()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(themeColor(.textSecondary))
        }
        .buttonStyle(.plain)
        .help("Cancel (Esc)")
        .accessibilityLabel("Cancel adding a daily")
      }
      Text("Return adds · Esc cancels")
        .font(.system(size: 10))
        .foregroundColor(themeColor(.textMuted))
        .padding(.leading, PopoverLayout.rowIconWidth + PopoverLayout.rowContentSpacing)
    }
    .padding(.horizontal, PopoverLayout.rowHorizontalPadding)
    .padding(.vertical, PopoverLayout.inlineEntryVerticalPadding)
    .background(themeColor(.panelSurfaceElevated))
  }

  /// The handful of schedules worth choosing *while typing a habit down*.
  ///
  /// Arbitrary weekday sets and arbitrary intervals live in
  /// `Preferences → Plugins → Daily Log`, which is the full editor. Putting
  /// seven day toggles and a stepper in this row would make the fast path —
  /// type a name, press Return — the slow one.
  @ViewBuilder
  private var newDailyScheduleMenu: some View {
    let log = manager.dailyLog
    let choices: [Daily.Schedule] = [
      .weekdays(Daily.allWeekdays),
      .weekdays(Daily.mondayToFriday),
      .weekdays(Daily.weekend),
      .everyNDays(2),
      .everyNDays(3),
      .everyNDays(7),
    ]

    Menu {
      ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
        Button {
          log.newDailySchedule = choice
        } label: {
          if log.newDailySchedule == choice {
            Label(Daily.scheduleLabel(for: choice), systemImage: "checkmark")
          } else {
            Text(Daily.scheduleLabel(for: choice))
          }
        }
      }
    } label: {
      Text(Daily.scheduleLabel(for: log.newDailySchedule))
        .font(.system(size: 10, weight: .medium))
        .foregroundColor(themeColor(.textSecondary))
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("How often the new daily repeats")
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
