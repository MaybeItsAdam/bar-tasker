import AppKit
import SwiftUI

// swiftlint:disable file_length
enum PopoverLayout {
  static let width: CGFloat = 400
  static let kanbanColumnWidth: CGFloat = 100
  static let minHeight: CGFloat = 220
  static let maxHeight: CGFloat = 520

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
  static let inlineEntryVerticalPadding: CGFloat = 7

  @MainActor
  static func preferredHeight(for manager: AppCoordinator) -> CGFloat {
    if manager.needsInitialSetup {
      return 430
    }

    let dividerHeight: CGFloat = 1

    // Top strip + first divider.
    var fixedHeight: CGFloat = topStripHeight + dividerHeight

    if !manager.breadcrumbs.isEmpty || manager.navigationState.currentParentId != 0 {
      fixedHeight += 30 + dividerHeight
    }
    if manager.shouldShowRootScopeSection {
      fixedHeight += (manager.rootScopeShowsFilterControls ? 72 : 40) + dividerHeight
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
      && (!manager.visibleTasks.isEmpty || !manager.quickEntry.searchText.isEmpty)
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
      let activeOnboardingDialog = manager.activeOnboardingDialog
    {
      switch activeOnboardingDialog {
      case .pluginSelection:
        fixedHeight += 156
      default:
        fixedHeight += 72
      }
    }
    if manager.repository.errorMessage != nil || manager.statusMessage != nil {
      fixedHeight += 20
    }

    if manager.taskListViewModel.rootTaskView == .kanban {
      return maxHeight
    }

    if manager.taskListViewModel.rootTaskView == .eisenhower {
      return min(maxHeight, fixedHeight + width)
    }

    let taskAreaHeight: CGFloat
    if manager.repository.isLoading && manager.repository.tasks.isEmpty {
      taskAreaHeight = 90
    } else if manager.visibleTasks.isEmpty {
      taskAreaHeight = 150
    } else {
      let visibleTasks = manager.visibleTasks
      let sectionRows = manager.taskListViewModel.rootDueSectionCount(in: visibleTasks)
      let visibleRows = CGFloat(min(visibleTasks.count + sectionRows, 8))
      taskAreaHeight = max(110, visibleRows * 34)
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

// swiftlint:disable type_body_length function_body_length
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

      if manager.shouldShowRootScopeSection {
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
        if manager.activeOnboardingDialog != nil {
          onboardingInlineBar()
        } else {
          if shouldShowBottomPrompt {
            quickEntryBar()
          }
        }
      }

    }
    .frame(width: panelWidth, height: panelHeight, alignment: .top)
    .background(themeColor(.panelBackground))
    .tint(manager.preferences.themeAccentColor)
    .clipShape(RoundedRectangle(cornerRadius: PopoverLayout.cornerRadius))
    .overlay(focusOverlay)
    .onAppear {
      manager.presentOnboardingDialogIfNeeded()
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

  var isAddMode: Bool {
    manager.quickEntry.quickEntryMode == .addSibling || manager.quickEntry.quickEntryMode == .addChild
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

  private var isRootFilteredView: Bool {
    manager.isRootLevel && manager.shouldShowRootScopeSection && taskListViewModel.rootTaskView != .all
  }

  /// True when the user has zero tasks anywhere — distinct from "filter excludes all tasks".
  private var hasNoTasksAtAll: Bool {
    repository.tasks.isEmpty
  }

  private var emptyStateTitle: String {
    if manager.isSearchFilterActive {
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
      case .all:
        break
      }
    }

    return "No tasks here"
  }

  private var emptyStateMessage: String? {
    if manager.isSearchFilterActive {
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
    case .all:
      return nil
    }
  }

  var shouldShowEmptyListComposer: Bool {
    let baseConditions =
      manager.visibleTasks.isEmpty
      && !repository.isLoading
      && !manager.quickEntry.pendingDeleteConfirmation
      && manager.activeOnboardingDialog == nil
      && !manager.isSearchFilterActive
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
      && (!manager.visibleTasks.isEmpty || !manager.quickEntry.searchText.isEmpty)
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
    case .addSibling, .addChild, .editTask, .command, .quickAddDefault, .quickAddSpecific:
      return Bindable(manager).quickEntry.quickEntryText
    }
  }

  var activePromptText: String {
    switch manager.quickEntry.quickEntryMode {
    case .search:
      return manager.quickEntry.searchText
    case .addSibling, .addChild, .editTask, .command, .quickAddDefault, .quickAddSpecific:
      return manager.quickEntry.quickEntryText
    }
  }

  func clearPrompt() {
    manager.quickEntry.isQuickEntryFocused = false
    switch manager.quickEntry.quickEntryMode {
    case .search:
      manager.quickEntry.searchText = ""
    case .addSibling, .addChild, .editTask, .command, .quickAddDefault, .quickAddSpecific:
      manager.quickEntry.quickEntryText = ""
      manager.quickEntry.quickEntryMode = .search
      manager.quickEntry.commandSuggestionIndex = 0
    }
  }

  @ViewBuilder
  private func onboardingInlineBar() -> some View {
    if let dialog = manager.activeOnboardingDialog {
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
              manager.dismissActiveOnboardingDialog(permanently: true)
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
          isOn: Binding(
            get: { manager.checkvistIntegrationEnabled },
            set: { on in
              manager.checkvistIntegrationEnabled = on
              if on && repository.username.isEmpty {
                AppDelegate.shared.menuSettings(pane: .plugins)
              }
            }
          ),
          prompt: manager.checkvistIntegrationEnabled && repository.username.isEmpty
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
          label: "Google Calendar",
          isOn: Bindable(manager).integrations.googleCalendarIntegrationEnabled,
          prompt: nil,
          onPromptTap: {}
        )
        pluginToggleRow(
          label: "MCP",
          isOn: Bindable(manager).integrations.mcpIntegrationEnabled,
          prompt: nil,
          onPromptTap: {}
        )
      }
      .font(.caption)

      HStack(spacing: 8) {
        Button("Done") {
          manager.completePluginSelectionOnboarding()
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

  // swiftlint:disable:next large_tuple
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
          manager.completePluginSelectionOnboarding()
        }
      )
    case .checkvist:
      return (
        "Connect Checkvist",
        "Sync your tasks to Checkvist, or keep working offline.",
        "Set Up",
        {
          AppDelegate.shared.menuSettings(pane: .plugins)
          manager.dismissActiveOnboardingDialog(permanently: true)
        }
      )
    case .obsidian:
      return (
        "Choose Obsidian Inbox",
        "Obsidian integration is enabled. Pick an inbox folder to finish setup.",
        "Choose Folder",
        {
          _ = manager.integrations.chooseObsidianInboxFolder()
          manager.dismissActiveOnboardingDialog(permanently: true)
        }
      )
    case .googleCalendar:
      return (
        "Enable Google Calendar",
        "Optional event handoff from task due details.",
        "Enable",
        {
          manager.integrations.googleCalendarIntegrationEnabled = true
          manager.dismissActiveOnboardingDialog(permanently: true)
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
          manager.dismissActiveOnboardingDialog(permanently: true)
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
          ForEach(manager.breadcrumbs) { crumb in
            Image(systemName: "chevron.right").font(.system(size: 8)).foregroundColor(
              themeColor(.textSecondary))
            Button(crumb.content) { manager.taskNavigationService.navigate(to: crumb) }
              .buttonStyle(PlainButtonStyle())
              .font(Typography.taskFont(size: 11))
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
        && manager.visibleTasks.isEmpty
        && navigationState.rootScopeFocusLevel == 0
      {
        navigationState.rootScopeFocusLevel = 1
      }
    }
    .onChange(of: manager.visibleTasks.count) { _, count in
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
    let visibleTasks = manager.visibleTasks

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
          let childCountsByTaskId = manager.childCountByTaskId()
          let elapsedByTaskId = manager.rolledUpElapsedByTaskId()
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

                taskRow(
                  task: task,
                  index: index,
                  childCount: childCountsByTaskId[task.id, default: 0],
                  elapsed: elapsedByTaskId[task.id, default: 0]
                )
                .id(task.id)

                if navigationState.currentSiblingIndex == index,
                  manager.quickEntry.quickEntryMode == .addSibling || manager.quickEntry.quickEntryMode == .addChild
                {
                  quickEntryBar(
                    verticalPadding: PopoverLayout.inlineEntryVerticalPadding,
                    leadingInset: manager.quickEntry.quickEntryMode == .addChild ? 20 : 0
                  )
                  .background(Color(NSColor.textBackgroundColor).opacity(0.3))
                  .overlay(alignment: .leading) {
                    Rectangle().fill(themeColor(.selectionForeground)).frame(width: 3)
                  }
                  .id("quickEntry")
                }
              }
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          .onChange(of: navigationState.currentSiblingIndex) { _, _ in
            if let currentTask = manager.currentTask {
              proxy.scrollTo(currentTask.id, anchor: .center)
            }
          }
          .onChange(of: manager.quickEntry.isQuickEntryFocused) { _, focused in
            if focused && [.addSibling, .addChild].contains(manager.quickEntry.quickEntryMode) {
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
        Image(systemName: manager.isSearchFilterActive ? "magnifyingglass" : "tray")
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
          font: Typography.taskNSFont(ofSize: 13),
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
      Text("Delete \"\(manager.currentTask?.content.prefix(30) ?? "")\"?")
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
    while pid != 0 {
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
// swiftlint:enable type_body_length function_body_length
// swiftlint:enable file_length
