import AppKit
import PriorityCore
import SwiftUI

// swiftlint:disable file_length
enum PopoverLayout {
  static let width: CGFloat = 400
  static let kanbanColumnWidth: CGFloat = 100
  static let minHeight: CGFloat = 220
  static let maxHeight: CGFloat = 520
  /// The Daily view stacks a headline, a checklist, a chart and a completions
  /// list — four things worth seeing together — so it gets more room than the
  /// single scrolling list the shared cap was sized for.
  static let dailyMaxHeight: CGFloat = 680

  @MainActor
  static func preferredWidth(for manager: AppCoordinator) -> CGFloat {
    // Keep the popover width constant across views so the root tab bar doesn't
    // shift horizontally when switching to kanban. Kanban columns flex to fill.
    width
  }
  static let cornerRadius: CGFloat = 10
  static let topStripHeight: CGFloat = 6
  static let rootScopeHorizontalInset: CGFloat = 8
  static let rowHorizontalPadding: CGFloat = 14
  static let rowVerticalPadding: CGFloat = 7
  static let rowIconWidth: CGFloat = 16
  static let rowContentSpacing: CGFloat = 10
  static let rowTextFadeWidth: CGFloat = 18
  /// One level of outline indent. Narrow on purpose: the popover is 400pt wide
  /// and a deep subtree still has to leave room for the task itself.
  static let outlineIndentWidth: CGFloat = 14
  static let inlineEntryVerticalPadding: CGFloat = 7
  /// The bottom dock row, present in every view.
  static let dockHeight: CGFloat = 24
  /// The drag strip, shown only when the dock's resize button is on.
  static let resizeStripHeight: CGFloat = 8

  // Onboarding bar heights. `PopoverView` pins the panel to `preferredHeight`
  // and clips to a rounded rect, and the onboarding bar is the last element in
  // the stack — so under-reserving here doesn't scroll or compress anything, it
  // silently amputates the bottom of the bar. Both values are derived from the
  // bars' actual layout and rounded *up*; over-reserving only adds slack.

  /// `pluginSelectionOnboardingBar`: title, wrapped subtitle, four toggle rows,
  /// and the Done/Preferences row, in a `VStack(spacing: 10)` with 10pt of
  /// vertical padding either side.
  static let pluginSelectionOnboardingBarHeight: CGFloat = {
    let title: CGFloat = 15  // .system(size: 12, weight: .semibold)
    let subtitle: CGFloat = 28  // .caption2, wraps to two lines at this width
    let toggleRows: CGFloat = 4 * 16 + 3 * 6  // four .mini switches, 6pt apart
    let buttons: CGFloat = 24  // .controlSize(.small)
    let spacing: CGFloat = 3 * 10
    let padding: CGFloat = 2 * 10
    return title + subtitle + toggleRows + buttons + spacing + padding
  }()

  /// The single-action bars (Checkvist, Obsidian, …): title over a two-line
  /// message, with the action buttons alongside rather than below.
  static let compactOnboardingBarHeight: CGFloat = 72

  /// Everything the popover stacks *around* the current view: the top strip,
  /// the dock, and whichever bars and prompts are showing.
  ///
  /// Split out so a view can work out how much room it is actually being given
  /// — `preferredHeight` minus this — rather than measuring itself and feeding
  /// the answer back into its own layout.
  @MainActor
  static func fixedChromeHeight(for manager: AppCoordinator) -> CGFloat {
    let dividerHeight: CGFloat = 1

    // Top strip + first divider.
    var fixedHeight: CGFloat = topStripHeight + dividerHeight

    // The dock row is in every view, with a divider above it *and* one closing
    // the content area off. Missing that second hairline is small enough to
    // look like nothing and large enough to leave a visible strip of bare panel
    // under a view that sizes itself from what is left.
    fixedHeight += dividerHeight + dockHeight + dividerHeight
    if manager.popoverChrome.isResizeHandleVisible {
      fixedHeight += resizeStripHeight
    }

    if !manager.taskListViewModel.breadcrumbs.isEmpty || manager.navigationState.currentParentId != 0 {
      fixedHeight += 30 + dividerHeight
    }
    if manager.taskListViewModel.shouldShowRootScopeSection {
      // 27pt is measured; the filter-controls variant is still an estimate.
      fixedHeight += (manager.taskListViewModel.rootScopeShowsFilterControls ? 72 : 27) + dividerHeight
    }
    if manager.preferences.showTaskBreadcrumbContext {
      fixedHeight += 24 + dividerHeight
    }
    if manager.taskListViewModel.hideFuture {
      fixedHeight += 24 + dividerHeight
    }
    if manager.quickEntry.pendingDeleteConfirmation {
      fixedHeight += 40
    }
    let showsSearchPrompt =
      !manager.quickEntry.pendingDeleteConfirmation
      && manager.quickEntry.quickEntryMode == .search
      && (manager.quickEntry.isQuickEntryFocused || !manager.quickEntry.searchText.isEmpty)
      && (!manager.taskListViewModel.visibleTasks.isEmpty || !manager.quickEntry.searchText.isEmpty)
    let showsQuickAddPrompt =
      !manager.quickEntry.pendingDeleteConfirmation
      && (manager.quickEntry.quickEntryMode == .quickAddDefault
        || manager.quickEntry.quickEntryMode == .quickAddSpecific)
      && (manager.quickEntry.isQuickEntryFocused || !manager.quickEntry.quickEntryText.isEmpty)
    if showsSearchPrompt || showsQuickAddPrompt {
      fixedHeight += 40
    }
    if !manager.quickEntry.pendingDeleteConfirmation
      && (manager.quickEntry.quickEntryMode == .command
        && (manager.quickEntry.isQuickEntryFocused || !manager.quickEntry.quickEntryText.isEmpty))
    {
      // Input row + autocomplete list block.
      fixedHeight += 220
    }
    if !manager.quickEntry.pendingDeleteConfirmation,
      let activeOnboardingDialog = manager.onboardingService.activeOnboardingDialog
    {
      switch activeOnboardingDialog {
      case .pluginSelection:
        fixedHeight += pluginSelectionOnboardingBarHeight
      default:
        fixedHeight += compactOnboardingBarHeight
      }
    }
    if manager.repository.errorMessage != nil || manager.statusMessage != nil {
      fixedHeight += 20
    }

    return fixedHeight
  }

  /// Everything in the Daily view except the checklist rows.
  @MainActor
  static func dailyReservedHeight(for manager: AppCoordinator) -> CGFloat {
    DailyChecklistLayout.reservedHeight(
      showsChart: manager.popoverChrome.showsDailyChart,
      hasFullChartHistory: manager.dailyLog.hasFullChartHistory,
      showsCompletions: dailyShowsCompletions(for: manager),
      isAddingDaily: manager.dailyLog.isAddingDaily
    )
  }

  /// Whether the Daily view is actually drawing its completed-tasks list: the
  /// dock toggle is on *and* the day has something in it. Both halves have to
  /// agree with `DailyView`, so the condition lives here rather than being
  /// written out at each site.
  @MainActor
  static func dailyShowsCompletions(for manager: AppCoordinator) -> Bool {
    manager.popoverChrome.showsDailyCompletions
      && !manager.dailyLog.summary().completed.isEmpty
  }

  /// The chart and its range row — what a dragged Daily height has added to it
  /// when the graph is on, and taken off it before being stored. The same term
  /// `dailyReservedHeight` uses, so the two can't disagree about what the chart
  /// costs.
  @MainActor
  static func dailyChartBlockHeight(for manager: AppCoordinator) -> CGFloat {
    DailyChecklistLayout.chartBlockHeight(
      showsChart: manager.popoverChrome.showsDailyChart,
      hasFullChartHistory: manager.dailyLog.hasFullChartHistory
    )
  }

  /// Every Daily block the dock can switch on and off. A dragged height is
  /// stored without these, so toggling one grows or shrinks the panel by its
  /// own height rather than eating into the checklist.
  @MainActor
  static func dailyToggleableBlockHeight(for manager: AppCoordinator) -> CGFloat {
    DailyChecklistLayout.toggleableBlockHeight(
      showsChart: manager.popoverChrome.showsDailyChart,
      hasFullChartHistory: manager.dailyLog.hasFullChartHistory,
      showsCompletions: dailyShowsCompletions(for: manager)
    )
  }

  /// Converts a height the user has just dragged the panel to into the value
  /// that gets stored. The Daily view keeps its height free of the dock's
  /// optional blocks, so toggling one moves the panel rather than the checklist.
  @MainActor
  static func storedHeight(forDisplayed height: CGFloat, in manager: AppCoordinator) -> CGFloat {
    guard manager.taskListViewModel.rootTaskView == .daily else { return height }
    return height - dailyToggleableBlockHeight(for: manager)
  }

  @MainActor
  static func preferredHeight(for manager: AppCoordinator) -> CGFloat {
    if manager.needsInitialSetup {
      return 430
    }

    // A dragged height wins outright, and is checked before anything else
    // because the kanban branch below returns unconditionally — content-derived
    // sizing is a good default and a bad argument once the user has said what
    // they want.
    if let override = manager.popoverChrome.height(for: manager.taskListViewModel.rootTaskView) {
      // The Daily view's height is stored *without* its toggleable blocks, so
      // switching the graph or the done-today list on grows the panel by exactly
      // that block's height instead of taking the room out of the checklist.
      return override + dailyToggleableBlockHeight(for: manager)
    }

    let fixedHeight = fixedChromeHeight(for: manager)

    if manager.taskListViewModel.rootTaskView == .kanban {
      return maxHeight
    }

    if manager.taskListViewModel.rootTaskView == .eisenhower {
      return min(maxHeight, fixedHeight + width)
    }

    // Sized to its own content rather than the task count: headline, dailies
    // checklist, chart, and the capped completions list. The container has to
    // include the chart's baseline or the card grows a nested scroll bar.
    if manager.taskListViewModel.rootTaskView == .daily {
      // Sized by `DailyChecklistLayout` rather than here: the view divides the
      // same budget up again to decide how many whole rows its checklist can
      // show, and the two answers have to come from one set of numbers.
      let dailyContentHeight = DailyChecklistLayout.contentHeight(
        reserved: dailyReservedHeight(for: manager),
        count: manager.dailyLog.todaysDailies.count
      )
      // Its own ceiling: this view stacks four sections that are each worth
      // seeing at once, where the task views are one scrolling list that the
      // shared cap suits fine.
      return min(dailyMaxHeight, max(minHeight, fixedHeight + dailyContentHeight))
    }

    let taskAreaHeight: CGFloat
    if manager.repository.isLoading && manager.repository.tasks.isEmpty {
      taskAreaHeight = 90
    } else if manager.taskListViewModel.visibleTasks.isEmpty {
      taskAreaHeight = 150
    } else {
      let visibleTasks = manager.taskListViewModel.visibleTasks
      let sectionRows = manager.taskListViewModel.rootDueSectionCount(in: visibleTasks)
      let visibleRows = CGFloat(min(visibleTasks.count + sectionRows, 8))
      // 36pt is measured: a bare task row. One carrying a metadata line runs to
      // 40, so a full list still scrolls — but 34 was under every real row, and
      // the slack that used to hide it went when the chrome count was corrected.
      taskAreaHeight = max(110, visibleRows * 36)
    }

    return min(maxHeight, max(minHeight, fixedHeight + taskAreaHeight))
  }
}

struct MarqueeTextLine<Content: View>: View {
  let fadeWidth: CGFloat
  let content: () -> Content

  @State private var containerWidth: CGFloat = 0
  @State private var contentWidth: CGFloat = 0
  @State private var isHovering = false
  @State private var xOffset: CGFloat = 0

  private var shouldMarquee: Bool {
    isHovering && contentWidth > containerWidth + 1
  }

  private var overflowDistance: CGFloat {
    max(0, contentWidth - containerWidth)
  }

  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      ZStack(alignment: .leading) {
        if shouldMarquee {
          HStack(spacing: 28) {
            scrollingContent
            scrollingContent
          }
          .offset(x: xOffset)
          .onAppear {
            containerWidth = width
            startMarqueeIfNeeded()
          }
        } else {
          truncatingContent
        }
      }
      .mask(fadeMask)
      .contentShape(Rectangle())
      .clipped()
      .onAppear {
        containerWidth = width
      }
      .onChange(of: width) { _, newValue in
        containerWidth = newValue
        restartMarqueeIfNeeded()
      }
      .onHover { hovering in
        isHovering = hovering
        restartMarqueeIfNeeded()
      }
    }
    .frame(height: 22)
    .background(
      scrollingContent
        .hidden()
        .background(
          GeometryReader { proxy in
            Color.clear
              .onAppear { contentWidth = proxy.size.width }
              .onChange(of: proxy.size.width) { _, newValue in
                contentWidth = newValue
                restartMarqueeIfNeeded()
              }
          }
        )
    )
  }

  // Used for marquee animation and background width measurement — unconstrained width.
  private var scrollingContent: some View {
    content()
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
  }

  // Used for static display — respects the container width and truncates with a tail.
  private var truncatingContent: some View {
    content()
      .lineLimit(1)
      .truncationMode(.tail)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var fadeMask: some View {
    let safeFade = min(fadeWidth, max(0, containerWidth - 24))
    return HStack(spacing: 0) {
      Rectangle()
      LinearGradient(
        colors: [.black, .black.opacity(0)],
        startPoint: .leading,
        endPoint: .trailing
      )
      .frame(width: safeFade)
    }
  }

  private func restartMarqueeIfNeeded() {
    xOffset = 0
    guard shouldMarquee else { return }
    startMarqueeIfNeeded()
  }

  private func startMarqueeIfNeeded() {
    guard shouldMarquee else { return }
    let distance = overflowDistance + 28
    let duration = max(2.5, Double(distance / 28))
    withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
      xOffset = -distance
    }
  }
}

// MARK: - Tab-intercepting TextField wrapper
// Standard SwiftUI TextField sends Tab to focus-next. We need to intercept
// it and treat it as "add as child" instead.
class TabInterceptingTextField: NSTextField {
  var onTab: (() -> Void)?
  var onSubmit: (() -> Void)?
  var onEscape: (() -> Void)?

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36 || event.keyCode == 76 {
      onSubmit?()
      return
    }
    if event.keyCode == 53 {
      onEscape?()
      return
    }
    if event.keyCode == 48 {
      onTab?()
      return
    }  // 48 = Tab
    super.keyDown(with: event)
  }
}

struct QuickEntryField: NSViewRepresentable {
  @Binding var text: String
  @Binding var isFocused: Bool
  var cursorAtEnd: Bool = true  // true = append (cursor at end), false = insert (cursor at start)
  var font: NSFont = Typography.interfaceNSFont(ofSize: 13)
  var placeholder: String
  var onSubmit: () -> Void  // Enter
  var onTab: () -> Void  // Tab → add as child
  var onEscape: () -> Void  // Escape → clear

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> TabInterceptingTextField {
    let tf = TabInterceptingTextField()
    tf.placeholderString = placeholder
    tf.isBordered = false
    tf.drawsBackground = false
    tf.focusRingType = .none
    tf.font = font
    tf.delegate = context.coordinator
    tf.onTab = onTab
    tf.onSubmit = onSubmit
    tf.onEscape = onEscape
    return tf
  }

  func updateNSView(_ tf: TabInterceptingTextField, context: Context) {
    let textChanged = tf.stringValue != text
    if textChanged {
      tf.stringValue = text
    }
    tf.placeholderString = placeholder
    tf.font = font
    tf.onTab = onTab
    tf.onSubmit = onSubmit
    tf.onEscape = onEscape

    if isFocused {
      if let window = tf.window {
        let wasFocused = window.firstResponder == tf || window.firstResponder == tf.currentEditor()
        if !wasFocused {
          window.makeFirstResponder(tf)
        }
        // Position cursor after focus is established (editor now exists)
        if textChanged || !wasFocused {
          if cursorAtEnd {
            tf.currentEditor()?.moveToEndOfDocument(nil)
          } else {
            tf.currentEditor()?.moveToBeginningOfDocument(nil)
          }
        }
      } else {
        Task { @MainActor in
          tf.window?.makeFirstResponder(tf)
          if self.cursorAtEnd {
            tf.currentEditor()?.moveToEndOfDocument(nil)
          } else {
            tf.currentEditor()?.moveToBeginningOfDocument(nil)
          }
        }
      }
    } else {
      if let window = tf.window,
        window.firstResponder == tf || window.firstResponder == tf.currentEditor()
      {
        window.makeFirstResponder(nil)
      }
    }
  }

  class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: QuickEntryField
    init(_ quickEntryField: QuickEntryField) { parent = quickEntryField }

    func controlTextDidBeginEditing(_ obj: Notification) {
      Task { @MainActor in self.parent.isFocused = true }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
      Task { @MainActor in self.parent.isFocused = false }
    }

    func controlTextDidChange(_ obj: Notification) {
      if let tf = obj.object as? NSTextField {
        let currentText = tf.stringValue
        if currentText.hasSuffix("jk") {
          // Remove the 'jk' and trigger escape
          let stripped = String(currentText.dropLast(2))
          tf.stringValue = stripped
          parent.text = stripped
          parent.onEscape()
        } else {
          parent.text = currentText
        }
      }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool
    {
      if selector == #selector(NSResponder.insertNewline(_:)) {
        parent.onSubmit()
        return true
      }
      if selector == #selector(NSResponder.cancelOperation(_:)) {
        parent.onEscape()
        return true
      }
      return false
    }
  }
}

// MARK: - Popover View

// swiftlint:disable type_body_length
struct PopoverView: View {
  @Environment(AppCoordinator.self) var manager
  @Environment(NavigationState.self) var navigationState
  @Environment(TaskListViewModel.self) var taskListViewModel
  @Environment(TaskRepository.self) var repository

  func themeColor(_ token: AppThemeColorToken) -> Color {
    manager.preferences.themeColor(for: token)
  }

  var body: some View {
    let panelHeight = PopoverLayout.preferredHeight(for: manager)
    let panelWidth = PopoverLayout.preferredWidth(for: manager)

    VStack(alignment: .leading, spacing: 0) {
      topBevelArea
      Divider()

      if taskListViewModel.shouldShowRootScopeSection {
        rootScopeSection
        Divider()
      }

      if navigationState.currentParentId != 0 {
        breadcrumbBar
        Divider()
      }

      if taskListViewModel.hideFuture {
        hideFutureChip
        Divider()
      }

      // Task list / Kanban board — keyboard navigable
      if taskListViewModel.rootTaskView == .kanban {
        KanbanBoardView()
          .frame(maxHeight: .infinity, alignment: .top)
      } else if taskListViewModel.rootTaskView == .eisenhower {
        EisenhowerMatrixView()
          .frame(maxHeight: .infinity, alignment: .top)
      } else if taskListViewModel.rootTaskView == .daily {
        DailyView()
          .frame(maxHeight: .infinity, alignment: .top)
      } else {
        taskList
          .frame(maxHeight: .infinity, alignment: .top)
      }
      Divider()

      // Delete confirmation banner
      if manager.quickEntry.pendingDeleteConfirmation {
        deleteConfirmationBar
      }

      // Prompt + autocomplete at bottom so tasks remain visible above.
      if !manager.quickEntry.pendingDeleteConfirmation {
        if manager.onboardingService.activeOnboardingDialog != nil {
          onboardingInlineBar()
        } else {
          if shouldShowBottomPrompt {
            quickEntryBar()
          }
        }
      }

      if manager.popoverChrome.isResizeHandleVisible {
        resizeStrip
      }
      Divider()
      dockRow
    }
    .frame(width: panelWidth, height: panelHeight, alignment: .top)
    .background(themeColor(.panelBackground))
    .tint(manager.preferences.themeAccentColor)
    .clipShape(RoundedRectangle(cornerRadius: PopoverLayout.cornerRadius))
    .overlay(focusOverlay)
    .overlay(celebrationOverlay)
    .overlay(shortcutReferenceOverlay)
    .onAppear {
      manager.onboardingService.presentOnboardingDialogIfNeeded()
    }
    // Watch the composer visibility from a persistent parent so that when navigating
    // out of an empty scope (which unmounts `emptyStateView`), we still get a chance
    // to drop the auto-activated .addSibling mode. Otherwise the empty-list add bar
    // persists into scopes that already have tasks.
    .onChange(of: shouldShowEmptyListComposer) { _, isVisible in
      if isVisible {
        activateEmptyListComposerModeIfNeeded()
      } else {
        deactivateEmptyListComposerModeIfNeeded()
      }
    }
  }

  /// The keyboard reference, on `?`. Covers the whole panel rather than sitting
  /// beside the list: it is something you stop to read, and half a panel is not
  /// enough room to read it in.
  @ViewBuilder
  private var shortcutReferenceOverlay: some View {
    if manager.popoverChrome.showsShortcutReference {
      ShortcutReferenceOverlay()
        .transition(.opacity)
    }
  }

  /// The inline add field, wearing the same selection bar as the row it
  /// belongs to. Rendered above or below that row depending on the mode; which
  /// side is the caller's business, so this only has to line the field up.
  @ViewBuilder
  private func inlineComposer(atVisibleIndex index: Int) -> some View {
    quickEntryBar(
      verticalPadding: PopoverLayout.inlineEntryVerticalPadding,
      // Line the composer up with the row it belongs to, which is indented
      // once the outline is open.
      leadingInset: CGFloat(taskListViewModel.outlineDepth(atVisibleIndex: index))
        * PopoverLayout.outlineIndentWidth
        + (manager.quickEntry.quickEntryMode == .addChild ? 20 : 0)
    )
    .background(Color(NSColor.textBackgroundColor).opacity(0.3))
    .overlay(alignment: .leading) {
      Rectangle().fill(themeColor(.selectionForeground)).frame(width: 3)
    }
    .id("quickEntry")
  }

  var isAddMode: Bool {
    manager.quickEntry.quickEntryMode == .addSibling
      || manager.quickEntry.quickEntryMode == .addSiblingAbove
      || manager.quickEntry.quickEntryMode == .addChild
  }

  @ViewBuilder
  private var focusOverlay: some View {
    if let phase = manager.focusSessionManager.phase {
      let session = manager.focusSessionManager.session
      let taskId =
        session?.taskId ?? manager.focusSessionManager.lastFocusedTaskId
      let task = taskId.flatMap { taskListViewModel.cache.taskById[$0] }
      FocusSessionOverlay(task: task, phase: phase, session: session)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(themeColor(.panelBackground).opacity(0.92))
    } else if let promptId = manager.focusSessionManager.promptTaskId,
      let task = taskListViewModel.cache.taskById[promptId]
    {
      FocusPromptOverlay(task: task)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(themeColor(.panelBackground).opacity(0.92))
    }
  }

  /// The milestone half of a completion celebration.
  ///
  /// Panel-spanning rather than row-anchored because by the time it runs the row
  /// is gone — `applyOptimisticCompletion` has already removed the subtree — and
  /// in the `listCleared` case there is no row left at all. Never hit-testable:
  /// it is decoration over a list the user is still driving with the keyboard.
  ///
  /// Keyed on the flourish id so two milestones in a row each get their own
  /// `onAppear` instead of SwiftUI reusing the first one's view.
  @ViewBuilder
  private var celebrationOverlay: some View {
    if let flourish = manager.celebration.activeFlourish {
      flourish.view
        .id(flourish.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
  }

  private var isRootFilteredView: Bool {
    taskListViewModel.isRootLevel && taskListViewModel.shouldShowRootScopeSection && taskListViewModel.rootTaskView != .all
  }

  /// True when the user has zero tasks anywhere — distinct from "filter excludes all tasks".
  private var hasNoTasksAtAll: Bool {
    repository.tasks.isEmpty
  }

  private var emptyStateTitle: String {
    if taskListViewModel.isSearchFilterActive {
      return "No matches"
    }

    if hasNoTasksAtAll {
      return "No tasks yet"
    }

    if isRootFilteredView {
      switch taskListViewModel.rootTaskView {
      case .due:
        if let bucket = taskListViewModel.selectedRootDueBucket {
          return "No \(bucket.title.lowercased()) tasks"
        }
        return "No due tasks"
      case .tags:
        return taskListViewModel.selectedRootTag.isEmpty
          ? "No tagged tasks" : "No #\(taskListViewModel.selectedRootTag) tasks"
      case .priority:
        return "No priority tasks"
      case .kanban:
        return "No tasks"
      case .eisenhower:
        return "No tasks"
      case .daily:
        return "No tasks"
      case .all:
        break
      }
    }

    return "No tasks here"
  }

  private var emptyStateMessage: String? {
    if taskListViewModel.isSearchFilterActive {
      return "Refine or clear your search to see tasks."
    }

    if hasNoTasksAtAll {
      return repository.listId.isEmpty
        ? "Connect Checkvist in Preferences, then add your first task below."
        : "Add your first task below."
    }

    guard isRootFilteredView else { return nil }

    switch taskListViewModel.rootTaskView {
    case .due:
      if taskListViewModel.selectedRootDueBucket == nil {
        return "You have tasks, but none of them have a due date."
      }
      return "No tasks match this due filter."
    case .tags:
      if taskListViewModel.selectedRootTag.isEmpty {
        return "You have tasks, but none of them are tagged."
      }
      return "No tasks match this tag filter."
    case .priority:
      return "You have tasks, but none are currently prioritised."
    case .kanban:
      return nil
    case .eisenhower:
      return nil
    case .daily:
      return nil
    case .all:
      return nil
    }
  }

  var shouldShowEmptyListComposer: Bool {
    let baseConditions =
      taskListViewModel.visibleTasks.isEmpty
      && !repository.isLoading
      && !manager.quickEntry.pendingDeleteConfirmation
      && manager.onboardingService.activeOnboardingDialog == nil
      && !taskListViewModel.isSearchFilterActive
      && manager.quickEntry.quickEntryMode != .command
      && manager.quickEntry.quickEntryMode != .quickAddDefault
      && manager.quickEntry.quickEntryMode != .quickAddSpecific

    guard baseConditions else { return false }
    // Always offer the composer when there are zero tasks — otherwise the user
    // gets stranded on a filtered tab (default is .due) with no way in.
    return !isRootFilteredView || hasNoTasksAtAll
  }

  private var shouldShowBottomPrompt: Bool {
    let showsSearchPrompt =
      manager.quickEntry.quickEntryMode == .search
      && (manager.quickEntry.isQuickEntryFocused || !manager.quickEntry.searchText.isEmpty)
      && (!taskListViewModel.visibleTasks.isEmpty || !manager.quickEntry.searchText.isEmpty)
    let showsQuickAddPrompt =
      (manager.quickEntry.quickEntryMode == .quickAddDefault || manager.quickEntry.quickEntryMode == .quickAddSpecific)
      && (manager.quickEntry.isQuickEntryFocused || !manager.quickEntry.quickEntryText.isEmpty)
    let showsCommandPrompt =
      manager.quickEntry.quickEntryMode == .command
      && (manager.quickEntry.isQuickEntryFocused || !manager.quickEntry.quickEntryText.isEmpty)
    return showsSearchPrompt || showsQuickAddPrompt || showsCommandPrompt
  }

  var activePromptTextBinding: Binding<String> {
    switch manager.quickEntry.quickEntryMode {
    case .search:
      return Bindable(manager).quickEntry.searchText
    case .addSibling, .addSiblingAbove, .addChild, .editTask, .command, .quickAddDefault,
      .quickAddSpecific:
      return Bindable(manager).quickEntry.quickEntryText
    }
  }

  var activePromptText: String {
    switch manager.quickEntry.quickEntryMode {
    case .search:
      return manager.quickEntry.searchText
    case .addSibling, .addSiblingAbove, .addChild, .editTask, .command, .quickAddDefault,
      .quickAddSpecific:
      return manager.quickEntry.quickEntryText
    }
  }

  func clearPrompt() {
    manager.quickEntry.isQuickEntryFocused = false
    switch manager.quickEntry.quickEntryMode {
    case .search:
      manager.quickEntry.searchText = ""
    case .addSibling, .addSiblingAbove, .addChild, .editTask, .command, .quickAddDefault,
      .quickAddSpecific:
      manager.quickEntry.quickEntryText = ""
      manager.quickEntry.quickEntryMode = .search
      manager.quickEntry.commandSuggestionIndex = 0
    }
  }

  @ViewBuilder
  private func onboardingInlineBar() -> some View {
    if let dialog = manager.onboardingService.activeOnboardingDialog {
      if dialog == .pluginSelection {
        pluginSelectionOnboardingBar
      } else {
        let config = onboardingInlineContent(for: dialog)
        HStack(alignment: .top, spacing: 8) {
          VStack(alignment: .leading, spacing: 4) {
            Text(config.title)
              .font(.system(size: 12, weight: .semibold))
            Text(config.message)
              .font(.caption2)
              .foregroundColor(themeColor(.textSecondary))
              .lineLimit(2)
          }

          Spacer(minLength: 6)

          HStack(spacing: 6) {
            Button(config.actionTitle) {
              config.action()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
              manager.onboardingService.dismissActiveOnboardingDialog(permanently: true)
            } label: {
              Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(themeColor(.textSecondary))
                .frame(width: 16, height: 16)
                .background(themeColor(.panelSurfaceElevated))
                .clipShape(Circle())
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, PopoverLayout.rowHorizontalPadding)
        .padding(.vertical, 9)
        .background(themeColor(.panelSurface))
      }
    } else {
      EmptyView()
    }
  }

  private var pluginSelectionOnboardingBar: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Choose integrations")
        .font(.system(size: 12, weight: .semibold))

      Text("Enable integrations below. You can change these anytime in Preferences.")
        .font(.caption2)
        .foregroundColor(themeColor(.textSecondary))
        .fixedSize(horizontal: false, vertical: true)

      VStack(alignment: .leading, spacing: 6) {
        pluginToggleRow(
          label: "Checkvist",
          // Toggling on deliberately does *not* open Preferences. This bar is
          // where you pick several integrations at once, and jumping to a
          // window mid-list interrupts that. The "Connect to sync tasks" link
          // below appears in the same moment, so the way forward is still one
          // click away — and pressing Done surfaces the Connect Checkvist
          // prompt anyway. Matches the Obsidian row, which likewise waits.
          isOn: Binding(
            get: { manager.repository.checkvistIntegrationEnabled },
            set: { manager.repository.checkvistIntegrationEnabled = $0 }
          ),
          prompt: manager.repository.checkvistIntegrationEnabled
            && !manager.repository.hasCredentials
            ? "Connect to sync tasks" : nil,
          onPromptTap: { AppDelegate.shared.menuSettings(pane: .plugins) }
        )
        pluginToggleRow(
          label: "Obsidian",
          isOn: Bindable(manager).integrations.obsidianIntegrationEnabled,
          prompt: manager.integrations.obsidianIntegrationEnabled && manager.integrations.obsidianInboxPath.isEmpty
            ? "Choose inbox folder" : nil,
          onPromptTap: { _ = manager.integrations.chooseObsidianInboxFolder() }
        )
        pluginToggleRow(
          label: "AFFiNE",
          isOn: Bindable(manager).integrations.affineIntegrationEnabled,
          // Enabling it is not enough: the writing is done by a helper the user
          // installs themselves, so say so rather than failing at the first
          // export.
          prompt: manager.integrations.affineIntegrationEnabled
            && !manager.integrations.affinePlugin.isConfigured
            ? "Install affine-mcp" : nil,
          onPromptTap: { AppDelegate.shared.menuSettings(pane: .plugins) }
        )
        pluginToggleRow(
          label: "Google Calendar",
          isOn: Bindable(manager).integrations.googleCalendarIntegrationEnabled,
          prompt: nil,
          onPromptTap: {}
        )
        pluginToggleRow(
          label: "MCP",
          isOn: Bindable(manager).integrations.mcpIntegrationEnabled,
          // Enabling MCP alone does nothing visible — the server still has to be
          // registered with an AI client. Point at the page that does it in one
          // click, the same way the Checkvist and Obsidian rows do.
          prompt: manager.integrations.mcpIntegrationEnabled ? "Add to your AI client" : nil,
          onPromptTap: { AppDelegate.shared.menuSettings(pane: .plugins) }
        )
      }
      .font(.caption)

      HStack(spacing: 8) {
        Button("Done") {
          manager.onboardingService.completePluginSelectionOnboarding()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)

        Button("Preferences") {
          AppDelegate.shared.menuSettings()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)

        Spacer(minLength: 0)
      }
    }
    .padding(.horizontal, PopoverLayout.rowHorizontalPadding)
    .padding(.vertical, 10)
    .background(themeColor(.panelSurface))
  }

  private func pluginToggleRow(
    label: String,
    isOn: Binding<Bool>,
    prompt: String?,
    onPromptTap: @escaping () -> Void
  ) -> some View {
    HStack(spacing: 8) {
      Toggle(label, isOn: isOn)
        .toggleStyle(.switch)
        .controlSize(.mini)
      if let prompt {
        Button(prompt) { onPromptTap() }
          .font(.caption2)
          .buttonStyle(.plain)
          .foregroundColor(themeColor(.link))
      }
      Spacer(minLength: 0)
    }
  }

  private func onboardingInlineContent(for dialog: OnboardingDialog) -> (
    title: String, message: String, actionTitle: String, action: () -> Void
  ) {
    switch dialog {
    case .pluginSelection:
      return (
        "Choose integrations",
        "Enable or disable plugins in Preferences.",
        "Preferences",
        {
          AppDelegate.shared.menuSettings()
          manager.onboardingService.completePluginSelectionOnboarding()
        }
      )
    case .checkvist:
      return (
        "Connect Checkvist",
        "Sync your tasks to Checkvist, or keep working offline.",
        "Set Up",
        {
          AppDelegate.shared.menuSettings(pane: .plugins)
          manager.onboardingService.dismissActiveOnboardingDialog(permanently: true)
        }
      )
    case .obsidian:
      return (
        "Choose Obsidian Inbox",
        "Obsidian integration is enabled. Pick an inbox folder to finish setup.",
        "Choose Folder",
        {
          _ = manager.integrations.chooseObsidianInboxFolder()
          manager.onboardingService.dismissActiveOnboardingDialog(permanently: true)
        }
      )
    case .googleCalendar:
      return (
        "Enable Google Calendar",
        "Optional event handoff from task due details.",
        "Enable",
        {
          manager.integrations.googleCalendarIntegrationEnabled = true
          manager.onboardingService.dismissActiveOnboardingDialog(permanently: true)
        }
      )
    case .mcp:
      return (
        "Enable MCP",
        "Optional AI integrations using the built-in MCP server.",
        "Enable",
        {
          manager.integrations.mcpIntegrationEnabled = true
          manager.integrations.refreshMCPServerCommandPath()
          manager.onboardingService.dismissActiveOnboardingDialog(permanently: true)
        }
      )
    }
  }

  // MARK: - Subviews

  var topBevelArea: some View {
    themeColor(.panelSurface)
      .frame(height: PopoverLayout.topStripHeight)
  }

  var breadcrumbBar: some View {
    HStack(spacing: 4) {
      Button {
        if taskListViewModel.rootTaskView == .kanban {
          manager.kanban.exitToParentScope()
        } else {
          manager.taskNavigationService.exitToParent()
        }
      } label: {
        Image(systemName: "chevron.left").font(.caption).foregroundColor(themeColor(.link))
      }.buttonStyle(PlainButtonStyle())
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 4) {
          Button("All Tasks") {
            navigationState.currentParentId = 0
            navigationState.currentSiblingIndex = 0
            if taskListViewModel.rootTaskView == .kanban {
              manager.kanban.kanbanFilterSubtasks = false
              manager.kanban.kanbanFilterParentId = nil
            }
          }.buttonStyle(PlainButtonStyle()).font(.caption2).foregroundColor(themeColor(.link))
          ForEach(taskListViewModel.breadcrumbs) { crumb in
            Image(systemName: "chevron.right").font(.system(size: 8)).foregroundColor(
              themeColor(.textSecondary))
            Button(crumb.content) { manager.taskNavigationService.navigate(to: crumb) }
              .buttonStyle(PlainButtonStyle())
              .font(Typography.taskFont(size: 11, name: manager.preferences.appFontName))
              .foregroundColor(themeColor(.link))
              .lineLimit(1)
          }
        }
      }
    }
    .padding(.horizontal, 14).padding(.vertical, 6)
  }

  var hideFutureChip: some View {
    HStack {
      Label("Hide Future", systemImage: "clock")
        .font(.caption2).padding(.horizontal, 6).padding(.vertical, 3)
        .background(themeColor(.warning).opacity(0.15))
        .foregroundColor(themeColor(.warning))
        .clipShape(Capsule())
      Spacer()
      Button {
        taskListViewModel.hideFuture = false
      } label: {
        Image(systemName: "xmark").font(.caption2).foregroundColor(themeColor(.textSecondary))
      }.buttonStyle(PlainButtonStyle())
    }
    .padding(.horizontal, 14).padding(.vertical, 4)
  }

  var rootScopeSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 0) {
        ForEach(
          Array(manager.orderedRootTaskViews.enumerated()),
          id: \.element.rawValue
        ) { index, scope in
          if index > 0 {
            rootScopeSeparator()
          }
          rootScopeTabButton(scope)
        }
      }
      .frame(maxWidth: .infinity)
      .background(themeColor(.panelSurface))
      .overlay {
        Rectangle().stroke(themeColor(.panelDivider), lineWidth: 1)
      }
      .overlay(alignment: .bottom) {
        if navigationState.rootScopeFocusLevel == 1 {
          Rectangle()
            .fill(themeColor(.focusRing))
            .frame(height: 2)
        }
      }

      if taskListViewModel.rootTaskView == .due {
        let dueBuckets = RootDueBucket.allCases.filter { $0 != .noDueDate }
        ScrollViewReader { proxy in
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
              rootScopeChip(
                title: "All due",
                isSelected: taskListViewModel.selectedRootDueBucket == nil
              ) {
                taskListViewModel.selectedRootDueBucket = nil
                navigationState.currentSiblingIndex = 0
                navigationState.rootScopeFocusLevel = 2
              }
              .id("due-filter-all")

              if !dueBuckets.isEmpty {
                rootScopeSeparator()
              }

              ForEach(Array(dueBuckets.enumerated()), id: \.element.rawValue) { index, bucket in
                if index > 0 {
                  rootScopeSeparator()
                }
                rootScopeChip(
                  title: bucket.title,
                  isSelected: taskListViewModel.selectedRootDueBucket == bucket
                ) {
                  taskListViewModel.selectedRootDueBucket = bucket
                  navigationState.currentSiblingIndex = 0
                  navigationState.rootScopeFocusLevel = 2
                }
                .id("due-filter-\(bucket.rawValue)")
              }
            }
          }
          .onAppear {
            scrollRootDueFilterIntoView(proxy: proxy)
          }
          .onChange(of: taskListViewModel.selectedRootDueBucketRawValue) { _, _ in
            scrollRootDueFilterIntoView(proxy: proxy)
          }
        }
        .background(themeColor(.panelSurface))
        .overlay {
          Rectangle().stroke(themeColor(.panelDivider), lineWidth: 1)
        }
        .overlay(alignment: .bottom) {
          if navigationState.rootScopeFocusLevel == 2 {
            Rectangle()
              .fill(themeColor(.focusRing))
              .frame(height: 2)
          }
        }
      } else if taskListViewModel.rootTaskView == .tags {
        let tags = taskListViewModel.rootLevelTagNames(limit: 30)
        ScrollViewReader { proxy in
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
              rootScopeChip(
                title: "All tags",
                isSelected: taskListViewModel.selectedRootTag.isEmpty
              ) {
                taskListViewModel.selectedRootTag = ""
                navigationState.currentSiblingIndex = 0
                navigationState.rootScopeFocusLevel = 2
              }
              .id("tags-filter-all")

              if !tags.isEmpty {
                rootScopeSeparator()
              }

              ForEach(Array(tags.enumerated()), id: \.element) { index, tag in
                if index > 0 {
                  rootScopeSeparator()
                }
                rootScopeChip(
                  title: tag,
                  isSelected: taskListViewModel.selectedRootTag == tag
                ) {
                  taskListViewModel.selectedRootTag = tag
                  navigationState.currentSiblingIndex = 0
                  navigationState.rootScopeFocusLevel = 2
                }
                .id("tags-filter-\(tag)")
              }
            }
          }
          .onAppear {
            scrollRootTagFilterIntoView(proxy: proxy)
          }
          .onChange(of: taskListViewModel.selectedRootTag) { _, _ in
            scrollRootTagFilterIntoView(proxy: proxy)
          }
        }
        .background(themeColor(.panelSurface))
        .overlay {
          Rectangle().stroke(themeColor(.panelDivider), lineWidth: 1)
        }
        .overlay(alignment: .bottom) {
          if navigationState.rootScopeFocusLevel == 2 {
            Rectangle()
              .fill(themeColor(.focusRing))
              .frame(height: 2)
          }
        }
      }
    }
    .onAppear {
      if taskListViewModel.rootTaskView != .kanban
        && navigationState.currentParentId == 0
        && taskListViewModel.visibleTasks.isEmpty
        && navigationState.rootScopeFocusLevel == 0
      {
        navigationState.rootScopeFocusLevel = 1
      }
    }
    .onChange(of: taskListViewModel.visibleTasks.count) { _, count in
      if taskListViewModel.rootTaskView != .kanban
        && navigationState.currentParentId == 0
        && count == 0
        && navigationState.rootScopeFocusLevel == 0
      {
        navigationState.rootScopeFocusLevel = 1
      }
    }
  }

  @ViewBuilder
  func rootScopeTabButton(_ scope: RootTaskView) -> some View {
    let selected = taskListViewModel.rootTaskView == scope
    Button {
      manager.taskNavigationService.setRootTaskView(scope)
      navigationState.rootScopeFocusLevel = 1
    } label: {
      Text(scope.title)
        .font(.system(size: 12, weight: .semibold))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(selected ? themeColor(.selectionBackground) : Color.clear)
        .foregroundColor(selected ? themeColor(.selectionForeground) : themeColor(.textSecondary))
    }
    .buttonStyle(.plain)
    .contentShape(Rectangle())
  }

  @ViewBuilder
  func rootScopeChip(
    title: String,
    isSelected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(isSelected ? themeColor(.selectionBackground) : Color.clear)
        .foregroundColor(
          isSelected ? themeColor(.selectionForeground) : themeColor(.textSecondary))
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder
  func rootScopeSeparator() -> some View {
    Rectangle()
      .fill(themeColor(.panelDivider))
      .frame(width: 1, height: 20)
  }

  func scrollRootDueFilterIntoView(proxy: ScrollViewProxy) {
    let targetId: String
    if let bucket = taskListViewModel.selectedRootDueBucket {
      targetId = "due-filter-\(bucket.rawValue)"
    } else {
      targetId = "due-filter-all"
    }
    withAnimation(.easeInOut(duration: 0.12)) {
      proxy.scrollTo(targetId, anchor: .center)
    }
  }

  func scrollRootTagFilterIntoView(proxy: ScrollViewProxy) {
    let targetId =
      taskListViewModel.selectedRootTag.isEmpty
      ? "tags-filter-all" : "tags-filter-\(taskListViewModel.selectedRootTag)"
    withAnimation(.easeInOut(duration: 0.12)) {
      proxy.scrollTo(targetId, anchor: .center)
    }
  }

  var taskList: some View {
    let visibleTasks = taskListViewModel.visibleTasks

    return Group {
      if repository.isLoading && repository.tasks.isEmpty {
        HStack {
          Spacer()
          ProgressView().padding(24)
          Spacer()
        }
      } else if visibleTasks.isEmpty {
        emptyStateView
      } else {
        ScrollViewReader { proxy in
          let childCountsByTaskId = taskListViewModel.childCountByTaskId()
          let elapsedByTaskId = taskListViewModel.rolledUpElapsedByTaskId()
          ScrollView {
            VStack(alignment: .leading, spacing: 0) {
              ForEach(Array(visibleTasks.enumerated()), id: \.element.id) { index, task in
                if let remainderHeader = taskListViewModel.remainderSectionHeader(
                  atVisibleIndex: index)
                {
                  dueSectionHeader(remainderHeader)
                }
                if let sectionHeader = taskListViewModel.rootDueSectionHeader(
                  atVisibleIndex: index, visibleTasks: visibleTasks)
                {
                  dueSectionHeader(sectionHeader)
                }

                // Option+Enter composes *above* the selection, so its field
                // has to sit above the row too — a composer that inserts one
                // way while appearing to insert the other is worse than not
                // having the binding.
                if navigationState.currentSiblingIndex == index,
                  manager.quickEntry.quickEntryMode == .addSiblingAbove
                {
                  inlineComposer(atVisibleIndex: index)
                }

                taskRow(
                  task: task,
                  index: index,
                  childCount: childCountsByTaskId[task.id, default: 0],
                  elapsed: elapsedByTaskId[task.id, default: 0],
                  depth: taskListViewModel.outlineDepth(atVisibleIndex: index)
                )
                .id(task.id)

                if navigationState.currentSiblingIndex == index,
                  manager.quickEntry.quickEntryMode == .addSibling
                    || manager.quickEntry.quickEntryMode == .addChild
                {
                  inlineComposer(atVisibleIndex: index)
                }
              }
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          .onChange(of: navigationState.currentSiblingIndex) { _, _ in
            if let currentTask = taskListViewModel.currentTask {
              proxy.scrollTo(currentTask.id, anchor: .center)
            }
          }
          .onChange(of: manager.quickEntry.isQuickEntryFocused) { _, focused in
            if focused,
              [.addSibling, .addSiblingAbove, .addChild].contains(manager.quickEntry.quickEntryMode)
            {
              Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                // Keep the inline composer visually attached to its task row.
                proxy.scrollTo("quickEntry", anchor: .center)
              }
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  @ViewBuilder
  private var emptyStateView: some View {
    HStack {
      Spacer()
      VStack(spacing: 10) {
        Image(systemName: taskListViewModel.isSearchFilterActive ? "magnifyingglass" : "tray")
          .font(.title2)
          .foregroundColor(themeColor(.textSecondary))
        Text(emptyStateTitle)
          .foregroundColor(themeColor(.textSecondary))
          .font(.callout)
        if let emptyStateMessage {
          Text(emptyStateMessage)
            .foregroundColor(themeColor(.textSecondary))
            .font(.caption)
            .multilineTextAlignment(.center)
        }
        if shouldShowEmptyListComposer {
          emptyListComposer
        }
      }
      .padding(24)
      Spacer()
    }
    .frame(minHeight: 150)
    .onAppear {
      activateEmptyListComposerModeIfNeeded()
    }
  }

  @ViewBuilder
  private var emptyListComposer: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center, spacing: PopoverLayout.rowContentSpacing) {
        Image(systemName: "plus.square")
          .foregroundColor(themeColor(.textSecondary))
          .font(.system(size: 13))
          .frame(width: PopoverLayout.rowIconWidth, height: 20, alignment: .center)

        QuickEntryField(
          text: Bindable(manager).quickEntry.quickEntryText,
          isFocused: Bindable(manager).quickEntry.isQuickEntryFocused,
          font: Typography.taskNSFont(ofSize: 13, name: manager.preferences.appFontName),
          placeholder: "Add first task",
          onSubmit: { submitEmptyStateAdd() },
          onTab: { submitEmptyStateAdd() },
          onEscape: { escapeEmptyStateAdd() }
        )
        .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20, alignment: .leading)

        if !manager.quickEntry.quickEntryText.isEmpty || manager.quickEntry.isQuickEntryFocused {
          Button {
            escapeEmptyStateAdd()
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundColor(themeColor(.textSecondary))
              .frame(width: 16, height: 20)
          }
          .buttonStyle(.plain)
        }

        if repository.isLoading {
          ProgressView().scaleEffect(0.6).frame(width: 16, height: 20)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background(themeColor(.panelSurface))
      .clipShape(RoundedRectangle(cornerRadius: 8))

      if let error = repository.errorMessage {
        Text(error)
          .font(.caption2)
          .foregroundColor(themeColor(.danger))
          .frame(maxWidth: .infinity, alignment: .leading)
      } else if let status = manager.statusMessage {
        Text(status)
          .font(.caption2)
          .foregroundColor(themeColor(.link))
          .padding(.horizontal, 14)
          .padding(.bottom, 6)
      }
    }
    .frame(maxWidth: 240)
  }

  var deleteConfirmationBar: some View {
    HStack(spacing: 8) {
      Image(systemName: "trash")
        .foregroundColor(themeColor(.danger)).font(.system(size: 13))
      Text("Delete \"\(taskListViewModel.currentTask?.content.prefix(30) ?? "")\"?")
        .font(.system(size: 13)).foregroundColor(themeColor(.textPrimary)).lineLimit(1)
      Spacer()
      Text("⏎ confirm  Esc cancel")
        .font(.caption2).foregroundColor(themeColor(.textSecondary))
    }
    .padding(.horizontal, 14).padding(.vertical, 10)
    .background(themeColor(.danger).opacity(0.08))
  }

  func breadcrumbPath(for task: CheckvistTask, includeCurrentParent: Bool = false) -> String {
    var parts: [String] = []
    var pid = task.parentId ?? 0
    // See `TaskFilterEngine.isDescendant` for why the visited set is here.
    var seen: Set<Int> = []
    while pid != 0, seen.insert(pid).inserted {
      if !includeCurrentParent && pid == navigationState.currentParentId {
        break
      }
      if let parent = repository.tasks.first(where: { $0.id == pid }) {
        parts.insert(parent.content, at: 0)
        pid = parent.parentId ?? 0
      } else {
        break
      }
    }
    return parts.joined(separator: " › ")
  }
}
// swiftlint:enable type_body_length
// swiftlint:enable file_length
