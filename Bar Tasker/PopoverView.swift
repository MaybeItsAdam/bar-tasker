import AppKit
import SwiftUI

// swiftlint:disable file_length
enum PopoverLayout {
  static let width: CGFloat = 360
  static let minHeight: CGFloat = 220
  static let maxHeight: CGFloat = 520
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
  static func preferredHeight(for manager: BarTaskerManager) -> CGFloat {
    if manager.needsInitialSetup {
      return 430
    }

    let dividerHeight: CGFloat = 1

    // Top strip + first divider.
    var fixedHeight: CGFloat = topStripHeight + dividerHeight

    if !manager.breadcrumbs.isEmpty || manager.currentParentId != 0 {
      fixedHeight += 30 + dividerHeight
    }
    if manager.shouldShowRootScopeSection {
      fixedHeight += (manager.rootScopeShowsFilterControls ? 72 : 40) + dividerHeight
    }
    if manager.showTaskBreadcrumbContext {
      fixedHeight += 24 + dividerHeight
    }
    if manager.hideFuture {
      fixedHeight += 24 + dividerHeight
    }
    if manager.pendingDeleteConfirmation {
      fixedHeight += 40
    }
    let showsSearchPrompt =
      !manager.pendingDeleteConfirmation
      && manager.quickEntryMode == .search
      && (manager.isQuickEntryFocused || !manager.searchText.isEmpty)
      && (!manager.visibleTasks.isEmpty || !manager.searchText.isEmpty)
    let showsQuickAddPrompt =
      !manager.pendingDeleteConfirmation
      && (manager.quickEntryMode == .quickAddDefault
        || manager.quickEntryMode == .quickAddSpecific)
      && (manager.isQuickEntryFocused || !manager.quickEntryText.isEmpty)
    if showsSearchPrompt || showsQuickAddPrompt {
      fixedHeight += 40
    }
    if !manager.pendingDeleteConfirmation
      && (manager.quickEntryMode == .command
        && (manager.isQuickEntryFocused || !manager.quickEntryText.isEmpty))
    {
      // Input row + autocomplete list block.
      fixedHeight += 220
    }
    if !manager.pendingDeleteConfirmation,
      let activeOnboardingDialog = manager.activeOnboardingDialog
    {
      switch activeOnboardingDialog {
      case .pluginSelection:
        fixedHeight += 156
      default:
        fixedHeight += 72
      }
    }
    if manager.errorMessage != nil {
      fixedHeight += 20
    }

    let taskAreaHeight: CGFloat
    if manager.isLoading && manager.tasks.isEmpty {
      taskAreaHeight = 90
    } else if manager.visibleTasks.isEmpty {
      taskAreaHeight = 150
    } else {
      let visibleTasks = manager.visibleTasks
      let sectionRows = manager.rootDueSectionCount(in: visibleTasks)
      let visibleRows = CGFloat(min(visibleTasks.count + sectionRows, 8))
      taskAreaHeight = max(110, visibleRows * 34)
    }

    return min(maxHeight, max(minHeight, fixedHeight + taskAreaHeight))
  }
}

private struct MarqueeTextLine<Content: View>: View {
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
            marqueeContent
            marqueeContent
          }
          .offset(x: xOffset)
          .onAppear {
            containerWidth = width
            startMarqueeIfNeeded()
          }
        } else {
          marqueeContent
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .mask(fadeMask)
      .contentShape(Rectangle())
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
      marqueeContent
        .fixedSize(horizontal: true, vertical: false)
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

  private var marqueeContent: some View {
    content()
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
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
  var font: NSFont = BarTaskerTypography.interfaceNSFont(ofSize: 13)
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
        DispatchQueue.main.async {
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
      DispatchQueue.main.async { self.parent.isFocused = true }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
      DispatchQueue.main.async { self.parent.isFocused = false }
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
  @EnvironmentObject var manager: BarTaskerManager

  private func themeColor(_ token: BarTaskerThemeColorToken) -> Color {
    manager.themeColor(for: token)
  }

  var body: some View {
    let panelHeight = PopoverLayout.preferredHeight(for: manager)

    VStack(alignment: .leading, spacing: 0) {
      topBevelArea
      Divider()

      if manager.shouldShowRootScopeSection {
        rootScopeSection
        Divider()
      }

      if manager.currentParentId != 0 {
        breadcrumbBar
        Divider()
      }

      if manager.hideFuture {
        hideFutureChip
        Divider()
      }

      // Task list — keyboard navigable
      taskList
        .frame(maxHeight: .infinity, alignment: .top)
      Divider()

      // Delete confirmation banner
      if manager.pendingDeleteConfirmation {
        deleteConfirmationBar
      }

      // Prompt + autocomplete at bottom so tasks remain visible above.
      if !manager.pendingDeleteConfirmation {
        if manager.activeOnboardingDialog != nil {
          onboardingInlineBar()
        } else {
          if shouldShowBottomPrompt {
            quickEntryBar()
          }
        }
      }

    }
    .frame(width: PopoverLayout.width, height: panelHeight, alignment: .top)
    .background(themeColor(.panelBackground))
    .tint(manager.themeAccentColor)
    .clipShape(RoundedRectangle(cornerRadius: PopoverLayout.cornerRadius))
    .onAppear {
      manager.presentOnboardingDialogIfNeeded()
    }
  }

  private var isAddMode: Bool {
    manager.quickEntryMode == .addSibling || manager.quickEntryMode == .addChild
  }

  private var isRootFilteredView: Bool {
    manager.isRootLevel && manager.shouldShowRootScopeSection && manager.rootTaskView != .all
  }

  private var emptyStateTitle: String {
    if manager.isSearchFilterActive {
      return "No matches"
    }

    if isRootFilteredView {
      switch manager.rootTaskView {
      case .due:
        if let bucket = manager.selectedRootDueBucket {
          return "No \(bucket.title.lowercased()) tasks"
        }
        return "No due tasks"
      case .tags:
        return manager.selectedRootTag.isEmpty
          ? "No tagged tasks" : "No #\(manager.selectedRootTag) tasks"
      case .priority:
        return "No priority tasks"
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

    guard isRootFilteredView else { return nil }

    switch manager.rootTaskView {
    case .due:
      if manager.selectedRootDueBucket == nil {
        return "You have tasks, but none of them have a due date."
      }
      return "No tasks match this due filter."
    case .tags:
      if manager.selectedRootTag.isEmpty {
        return "You have tasks, but none of them are tagged."
      }
      return "No tasks match this tag filter."
    case .priority:
      return "You have tasks, but none are currently prioritised."
    case .all:
      return nil
    }
  }

  private var shouldShowEmptyListComposer: Bool {
    manager.visibleTasks.isEmpty
      && !isRootFilteredView
      && !manager.isLoading
      && !manager.pendingDeleteConfirmation
      && manager.activeOnboardingDialog == nil
      && !manager.isSearchFilterActive
      && manager.quickEntryMode != .command
      && manager.quickEntryMode != .quickAddDefault
      && manager.quickEntryMode != .quickAddSpecific
  }

  private var shouldShowBottomPrompt: Bool {
    let showsSearchPrompt =
      manager.quickEntryMode == .search
      && (manager.isQuickEntryFocused || !manager.searchText.isEmpty)
      && (!manager.visibleTasks.isEmpty || !manager.searchText.isEmpty)
    let showsQuickAddPrompt =
      (manager.quickEntryMode == .quickAddDefault || manager.quickEntryMode == .quickAddSpecific)
      && (manager.isQuickEntryFocused || !manager.quickEntryText.isEmpty)
    let showsCommandPrompt =
      manager.quickEntryMode == .command
      && (manager.isQuickEntryFocused || !manager.quickEntryText.isEmpty)
    return showsSearchPrompt || showsQuickAddPrompt || showsCommandPrompt
  }

  private var activePromptTextBinding: Binding<String> {
    switch manager.quickEntryMode {
    case .search:
      return $manager.searchText
    case .addSibling, .addChild, .editTask, .command, .quickAddDefault, .quickAddSpecific:
      return $manager.quickEntryText
    }
  }

  private var activePromptText: String {
    switch manager.quickEntryMode {
    case .search:
      return manager.searchText
    case .addSibling, .addChild, .editTask, .command, .quickAddDefault, .quickAddSpecific:
      return manager.quickEntryText
    }
  }

  private func clearPrompt() {
    manager.isQuickEntryFocused = false
    switch manager.quickEntryMode {
    case .search:
      manager.searchText = ""
    case .addSibling, .addChild, .editTask, .command, .quickAddDefault, .quickAddSpecific:
      manager.quickEntryText = ""
      manager.quickEntryMode = .search
      manager.commandSuggestionIndex = 0
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
    VStack(alignment: .leading, spacing: 8) {
      Text("Choose integrations")
        .font(.system(size: 12, weight: .semibold))

      Text("Enable or disable native plugins now. You can change this anytime in Preferences.")
        .font(.caption2)
        .foregroundColor(themeColor(.textSecondary))
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 10) {
        Toggle("Obsidian", isOn: $manager.obsidianIntegrationEnabled)
        Toggle("Google Calendar", isOn: $manager.googleCalendarIntegrationEnabled)
        Toggle("MCP", isOn: $manager.mcpIntegrationEnabled)
      }
      .font(.caption)
      .toggleStyle(.switch)

      HStack(spacing: 8) {
        Button("Continue") {
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

  // swiftlint:disable:next large_tuple
  private func onboardingInlineContent(for dialog: BarTaskerManager.OnboardingDialog) -> (
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
        "Optional. You can keep using Bar Tasker offline and connect anytime in Preferences.",
        "Preferences",
        {
          AppDelegate.shared.menuSettings()
          manager.dismissActiveOnboardingDialog(permanently: true)
        }
      )
    case .obsidian:
      return (
        "Choose Obsidian Inbox",
        "Obsidian integration is enabled. Pick an inbox folder to finish setup.",
        "Choose Folder",
        {
          _ = manager.chooseObsidianInboxFolder()
          manager.dismissActiveOnboardingDialog(permanently: true)
        }
      )
    case .googleCalendar:
      return (
        "Enable Google Calendar",
        "Optional event handoff from task due details.",
        "Enable",
        {
          manager.googleCalendarIntegrationEnabled = true
          manager.dismissActiveOnboardingDialog(permanently: true)
        }
      )
    case .mcp:
      return (
        "Enable MCP",
        "Optional AI integrations using the built-in MCP server.",
        "Enable",
        {
          manager.mcpIntegrationEnabled = true
          manager.refreshMCPServerCommandPath()
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
        manager.exitToParent()
      } label: {
        Image(systemName: "chevron.left").font(.caption).foregroundColor(themeColor(.link))
      }.buttonStyle(PlainButtonStyle())
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 4) {
          Button("All Tasks") {
            manager.currentParentId = 0
            manager.currentSiblingIndex = 0
          }.buttonStyle(PlainButtonStyle()).font(.caption2).foregroundColor(themeColor(.link))
          ForEach(manager.breadcrumbs) { crumb in
            Image(systemName: "chevron.right").font(.system(size: 8)).foregroundColor(
              themeColor(.textSecondary))
            Button(crumb.content) { manager.navigateTo(task: crumb) }
              .buttonStyle(PlainButtonStyle())
              .font(BarTaskerTypography.taskFont(size: 11))
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
        manager.hideFuture = false
      } label: {
        Image(systemName: "xmark").font(.caption2).foregroundColor(themeColor(.textSecondary))
      }.buttonStyle(PlainButtonStyle())
    }
    .padding(.horizontal, 14).padding(.vertical, 4)
  }

  var rootScopeSection: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 0) {
        ForEach(
          Array(BarTaskerManager.RootTaskView.allCases.enumerated()),
          id: \.element.rawValue
        ) { index, scope in
          if index > 0 {
            rootScopeSeparator()
          }
          rootScopeTabButton(scope)
        }
      }
      .background(themeColor(.panelSurface))
      .overlay {
        Rectangle().stroke(themeColor(.panelDivider), lineWidth: 1)
      }
      .overlay {
        Rectangle()
          .stroke(
            manager.rootScopeFocusLevel == 1 ? themeColor(.focusRing) : Color.clear,
            lineWidth: 1
          )
      }
      .padding(.horizontal, PopoverLayout.rootScopeHorizontalInset)

      if manager.rootTaskView == .due {
        let dueBuckets = BarTaskerManager.RootDueBucket.allCases.filter { $0 != .noDueDate }
        ScrollViewReader { proxy in
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
              rootScopeChip(
                title: "All due",
                isSelected: manager.selectedRootDueBucket == nil
              ) {
                manager.selectedRootDueBucket = nil
                manager.currentSiblingIndex = 0
                manager.rootScopeFocusLevel = 2
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
                  isSelected: manager.selectedRootDueBucket == bucket
                ) {
                  manager.selectedRootDueBucket = bucket
                  manager.currentSiblingIndex = 0
                  manager.rootScopeFocusLevel = 2
                }
                .id("due-filter-\(bucket.rawValue)")
              }
            }
          }
          .onAppear {
            scrollRootDueFilterIntoView(proxy: proxy)
          }
          .onChange(of: manager.selectedRootDueBucketRawValue) { _, _ in
            scrollRootDueFilterIntoView(proxy: proxy)
          }
        }
        .background(themeColor(.panelSurface))
        .overlay {
          Rectangle().stroke(themeColor(.panelDivider), lineWidth: 1)
        }
        .overlay {
          Rectangle()
            .stroke(
              manager.rootScopeFocusLevel == 2 ? themeColor(.focusRing) : Color.clear,
              lineWidth: 1
            )
        }
        .padding(.horizontal, PopoverLayout.rootScopeHorizontalInset)
      } else if manager.rootTaskView == .tags {
        let tags = manager.rootLevelTagNames(limit: 30)
        ScrollViewReader { proxy in
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
              rootScopeChip(
                title: "All tags",
                isSelected: manager.selectedRootTag.isEmpty
              ) {
                manager.selectedRootTag = ""
                manager.currentSiblingIndex = 0
                manager.rootScopeFocusLevel = 2
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
                  isSelected: manager.selectedRootTag == tag
                ) {
                  manager.selectedRootTag = tag
                  manager.currentSiblingIndex = 0
                  manager.rootScopeFocusLevel = 2
                }
                .id("tags-filter-\(tag)")
              }
            }
          }
          .onAppear {
            scrollRootTagFilterIntoView(proxy: proxy)
          }
          .onChange(of: manager.selectedRootTag) { _, _ in
            scrollRootTagFilterIntoView(proxy: proxy)
          }
        }
        .background(themeColor(.panelSurface))
        .overlay {
          Rectangle().stroke(themeColor(.panelDivider), lineWidth: 1)
        }
        .overlay {
          Rectangle()
            .stroke(
              manager.rootScopeFocusLevel == 2 ? themeColor(.focusRing) : Color.clear,
              lineWidth: 1
            )
        }
        .padding(.horizontal, PopoverLayout.rootScopeHorizontalInset)
      }
    }
    .onAppear {
      if manager.currentParentId == 0
        && manager.visibleTasks.isEmpty
        && manager.rootScopeFocusLevel == 0
      {
        manager.rootScopeFocusLevel = 1
      }
    }
    .onChange(of: manager.visibleTasks.count) { _, count in
      if manager.currentParentId == 0
        && count == 0
        && manager.rootScopeFocusLevel == 0
      {
        manager.rootScopeFocusLevel = 1
      }
    }
  }

  @ViewBuilder
  func rootScopeTabButton(_ scope: BarTaskerManager.RootTaskView) -> some View {
    let selected = manager.rootTaskView == scope
    Button {
      manager.setRootTaskView(scope)
      manager.rootScopeFocusLevel = 1
    } label: {
      Text(scope.title)
        .font(.system(size: 12, weight: .semibold))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
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
    if let bucket = manager.selectedRootDueBucket {
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
      manager.selectedRootTag.isEmpty
      ? "tags-filter-all" : "tags-filter-\(manager.selectedRootTag)"
    withAnimation(.easeInOut(duration: 0.12)) {
      proxy.scrollTo(targetId, anchor: .center)
    }
  }

  var taskList: some View {
    let visibleTasks = manager.visibleTasks

    return Group {
      if manager.isLoading && manager.tasks.isEmpty {
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
                if let sectionHeader = manager.rootDueSectionHeader(
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

                if manager.currentSiblingIndex == index,
                  manager.quickEntryMode == .addSibling || manager.quickEntryMode == .addChild
                {
                  quickEntryBar(
                    verticalPadding: PopoverLayout.inlineEntryVerticalPadding,
                    leadingInset: manager.quickEntryMode == .addChild ? 20 : 0
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
          .onChange(of: manager.currentSiblingIndex) { _, _ in
            if let currentTask = manager.currentTask {
              proxy.scrollTo(currentTask.id, anchor: .center)
            }
          }
          .onChange(of: manager.isQuickEntryFocused) { _, focused in
            if focused && [.addSibling, .addChild].contains(manager.quickEntryMode) {
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
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
    .onChange(of: shouldShowEmptyListComposer) { _, isVisible in
      if isVisible {
        activateEmptyListComposerModeIfNeeded()
      }
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
          text: $manager.quickEntryText,
          isFocused: $manager.isQuickEntryFocused,
          font: BarTaskerTypography.taskNSFont(ofSize: 13),
          placeholder: "Add first task",
          onSubmit: { submitEmptyStateAdd() },
          onTab: { submitEmptyStateAdd() },
          onEscape: { escapeEmptyStateAdd() }
        )
        .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20, alignment: .leading)

        if !manager.quickEntryText.isEmpty || manager.isQuickEntryFocused {
          Button {
            escapeEmptyStateAdd()
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundColor(themeColor(.textSecondary))
              .frame(width: 16, height: 20)
          }
          .buttonStyle(.plain)
        }

        if manager.isLoading {
          ProgressView().scaleEffect(0.6).frame(width: 16, height: 20)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background(themeColor(.panelSurface))
      .clipShape(RoundedRectangle(cornerRadius: 8))

      if let error = manager.errorMessage {
        Text(error)
          .font(.caption2)
          .foregroundColor(themeColor(.danger))
          .frame(maxWidth: .infinity, alignment: .leading)
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

  @ViewBuilder
  func quickEntryBar(verticalPadding: CGFloat = 10, leadingInset: CGFloat = 0) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center, spacing: PopoverLayout.rowContentSpacing) {
        Image(systemName: iconForMode)
          .foregroundColor(themeColor(.textSecondary))
          .font(.system(size: 13))
          .frame(width: PopoverLayout.rowIconWidth, height: 20, alignment: .center)

        QuickEntryField(
          text: activePromptTextBinding,
          isFocused: $manager.isQuickEntryFocused,
          font: quickEntryNSFont,
          placeholder: placeholderText,
          onSubmit: { submitAction() },
          onTab: { tabAction() },
          onEscape: { escapeAction() }
        )
        .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20, alignment: .leading)
        .onChange(of: manager.searchText) { _, _ in
          if manager.quickEntryMode == .search { manager.currentSiblingIndex = 0 }
        }
        .onChange(of: manager.quickEntryText) { _, _ in
          if manager.quickEntryMode == .command { manager.commandSuggestionIndex = 0 }
        }

        if !activePromptText.isEmpty || manager.isQuickEntryFocused {
          Button {
            clearPrompt()
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundColor(themeColor(.textSecondary))
              .frame(width: 16, height: 20)
          }.buttonStyle(PlainButtonStyle())
        }

        if manager.isLoading {
          ProgressView().scaleEffect(0.6).frame(width: 16, height: 20)
        }
      }

      if manager.quickEntryMode == .command && manager.isQuickEntryFocused {
        ScrollViewReader { proxy in
          ScrollView {
            VStack(alignment: .leading, spacing: 0) {
              ForEach(Array(filteredCommandSuggestions.enumerated()), id: \.element.label) {
                idx, suggestion in
                Button {
                  manager.quickEntryText = suggestion.command
                  if suggestion.submitImmediately {
                    manager.isQuickEntryFocused = false
                    manager.quickEntryMode = .search
                    manager.quickEntryText = ""
                    Task { await manager.executeCommandInput(suggestion.command) }
                  } else {
                    manager.isQuickEntryFocused = true
                  }
                } label: {
                  HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                      Text(suggestion.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(themeColor(.textPrimary))
                      Text(suggestion.preview)
                        .font(.system(size: 10))
                        .foregroundColor(themeColor(.textSecondary))
                    }
                    Spacer(minLength: 8)
                    if let keybind = suggestion.keybind {
                      Text(keybind)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(themeColor(.textSecondary))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(themeColor(.panelSurfaceElevated))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                  }
                  .padding(.horizontal, 9)
                  .padding(.vertical, 7)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .background(
                    idx == manager.commandSuggestionIndex
                      ? themeColor(.selectionBackground) : Color.clear
                  )
                }
                .buttonStyle(.plain)
                .id("cmd-suggestion-\(idx)")
                if suggestion.label != filteredCommandSuggestions.last?.label {
                  Divider().opacity(0.35)
                }
              }
            }
          }
          .onChange(of: manager.commandSuggestionIndex) { _, idx in
            withAnimation(.easeInOut(duration: 0.12)) {
              proxy.scrollTo("cmd-suggestion-\(idx)", anchor: .center)
            }
          }
          .onChange(of: manager.quickEntryText) { _, _ in
            withAnimation(.easeInOut(duration: 0.12)) {
              proxy.scrollTo("cmd-suggestion-\(manager.commandSuggestionIndex)", anchor: .center)
            }
          }
        }
        .frame(maxHeight: 170)
        .background(themeColor(.panelSurface))
        .clipShape(RoundedRectangle(cornerRadius: 7))
      }
    }
    .padding(.leading, PopoverLayout.rowHorizontalPadding + leadingInset)
    .padding(.trailing, PopoverLayout.rowHorizontalPadding)
    .padding(.vertical, verticalPadding)

    if let error = manager.errorMessage {
      Text(error).font(.caption2).foregroundColor(themeColor(.danger))
        .padding(.horizontal, 14).padding(.bottom, 6)
    }
  }

  // MARK: - Task Rows

  @ViewBuilder
  func dueSectionHeader(_ title: String) -> some View {
    HStack {
      Text(title.uppercased())
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(themeColor(.textSecondary))
      Spacer(minLength: 0)
    }
    .padding(.horizontal, PopoverLayout.rowHorizontalPadding)
    .padding(.top, 8)
    .padding(.bottom, 5)
    .background(themeColor(.panelSurface).opacity(0.7))
  }

  @ViewBuilder
  func taskRow(task: CheckvistTask, index: Int, childCount: Int, elapsed: TimeInterval) -> some View
  {
    let isSelected = index == manager.currentSiblingIndex
    let showsInlineComposer = isSelected && isAddMode
    let listFocusIsActive = manager.rootScopeFocusLevel == 0
    let showsSelectedStyling = isSelected && !showsInlineComposer && listFocusIsActive
    let showsInactiveSelection = isSelected && !showsInlineComposer && !listFocusIsActive
    let isCompleting = manager.completingTaskId == task.id
    let hasObsidianNoteLink = manager.hasObsidianSyncedNote(task: task)
    let hasGoogleCalendarLink = manager.hasGoogleCalendarEventLink(taskId: task.id)

    HStack(alignment: .top, spacing: PopoverLayout.rowContentSpacing) {
      Image(
        systemName: isCompleting
          ? "checkmark.circle.fill" : showsSelectedStyling ? "largecircle.fill.circle" : "circle"
      )
      .foregroundColor(
        isCompleting
          ? themeColor(.success)
          : showsSelectedStyling ? themeColor(.selectionForeground) : themeColor(.textSecondary)
      )
      .font(.system(size: 14))
      .frame(width: PopoverLayout.rowIconWidth, alignment: .center)
      .padding(.top, 1)
      .scaleEffect(isCompleting ? 1.35 : 1.0)
      .animation(.spring(response: 0.28, dampingFraction: 0.45), value: isCompleting)
      .symbolEffect(.bounce, value: isCompleting)
      .onTapGesture {
        Task {
          manager.rootScopeFocusLevel = 0
          manager.currentSiblingIndex = index
          await manager.markCurrentTaskDone()
        }
      }

      VStack(alignment: .leading, spacing: 3) {
        if manager.shouldShowBreadcrumbPath(for: task) {
          let includeCurrentParent =
            manager.showTaskBreadcrumbContext
            && !(manager.quickEntryMode == .search && !manager.searchText.isEmpty)
          let path = breadcrumbPath(
            for: task,
            includeCurrentParent: includeCurrentParent
          )
          if !path.isEmpty {
            Text(path)
              .font(.system(size: 10)).foregroundColor(themeColor(.textSecondary)).lineLimit(1)
          }
        }

        // Inline edit: replace text with editable field when editing this task
        if isSelected && manager.quickEntryMode == .editTask && manager.isQuickEntryFocused {
          QuickEntryField(
            text: $manager.quickEntryText,
            isFocused: $manager.isQuickEntryFocused,
            cursorAtEnd: manager.editCursorAtEnd,
            font: BarTaskerTypography.taskNSFont(ofSize: 13),
            placeholder: "Edit task…",
            onSubmit: { submitAction() },
            onTab: {},
            onEscape: { escapeAction() }
          )
          .frame(height: 18)
          .frame(maxWidth: .infinity, alignment: .leading)
        } else {
          HStack(alignment: .center, spacing: 6) {
            fadedTaskTitle(task: task)
            taskInlineMetadata(task: task, elapsed: elapsed)
            if task.hasNotes {
              Image(systemName: "text.alignleft")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(themeColor(.textSecondary))
                .help("Task has notes")
            }
            if hasObsidianNoteLink {
              Button {
                manager.rootScopeFocusLevel = 0
                manager.currentSiblingIndex = index
                Task {
                  if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    await manager.openCurrentTaskInNewObsidianWindow(taskId: task.id)
                  } else {
                    await manager.syncCurrentTaskToObsidian(taskId: task.id)
                  }
                }
              } label: {
                Image("ObsidianBadge")
                  .renderingMode(.template)
                  .resizable()
                  .interpolation(.high)
                  .scaledToFit()
                  .frame(width: 12, height: 12)
                  .foregroundColor(themeColor(.textSecondary))
              }
              .buttonStyle(.plain)
              .help("Open linked Obsidian note. Shift-click opens in a new window")
            }
            if hasGoogleCalendarLink {
              Button {
                manager.rootScopeFocusLevel = 0
                manager.currentSiblingIndex = index
                manager.openSavedGoogleCalendarEventLink(taskId: task.id)
              } label: {
                Image(systemName: "calendar.badge.checkmark")
                  .font(.system(size: 10, weight: .semibold))
                  .foregroundColor(themeColor(.textSecondary))
              }
              .buttonStyle(.plain)
              .help("Open linked Google Calendar event")
            }
          }
        }
      }
      .layoutPriority(1)
      .overlay(alignment: .center) {
        // Strikethrough line that draws left-to-right when completing
        Rectangle()
          .fill(themeColor(.success).opacity(0.65))
          .frame(height: 1.5)
          .scaleEffect(x: isCompleting ? 1.0 : 0.001, y: 1, anchor: .leading)
          .animation(.easeOut(duration: 0.12), value: isCompleting)
      }

      if childCount > 0 {
        Button {
          manager.currentSiblingIndex = index
          manager.enterChildren()
          if !manager.searchText.isEmpty {
            manager.searchText = ""
            manager.quickEntryMode = .search
            manager.isQuickEntryFocused = false
          }
        } label: {
          HStack(spacing: 3) {
            Text("\(childCount)").font(.caption2).foregroundColor(themeColor(.textSecondary))
            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundColor(
              themeColor(.textSecondary))
          }
        }.buttonStyle(PlainButtonStyle()).help("Enter subtasks (→)")
      }
    }
    .padding(.horizontal, PopoverLayout.rowHorizontalPadding)
    .padding(.vertical, PopoverLayout.rowVerticalPadding)
    .scaleEffect(isCompleting ? 1.01 : 1.0)
    .animation(.spring(response: 0.3, dampingFraction: 0.5), value: isCompleting)
    .background(
      isCompleting
        ? themeColor(.success).opacity(0.12)
        : showsSelectedStyling
          ? themeColor(.selectionBackground).opacity(0.7)
          : showsInactiveSelection ? themeColor(.selectionBackground).opacity(0.28) : Color.clear
    )
    .overlay(alignment: .leading) {
      Rectangle().fill(
        isCompleting
          ? themeColor(.success)
          : showsSelectedStyling ? themeColor(.selectionForeground) : Color.clear
      )
      .frame(width: 3)
    }
    .contentShape(Rectangle())
    .onTapGesture {
      manager.rootScopeFocusLevel = 0
      manager.currentSiblingIndex = index
    }
  }

  // MARK: - Helpers

  var iconForMode: String {
    switch manager.quickEntryMode {
    case .search:
      return manager.searchText.isEmpty
        ? "magnifyingglass" : "line.3.horizontal.decrease.circle.fill"
    case .addSibling: return "plus.square"
    case .addChild: return "arrow.turn.down.right"
    case .editTask: return "pencil"
    case .command: return "terminal"
    case .quickAddDefault: return "plus.circle"
    case .quickAddSpecific: return "plus.circle.fill"
    }
  }

  var placeholderText: String {
    switch manager.quickEntryMode {
    case .search: return "Search tasks…"
    case .addSibling: return "Add task"
    case .addChild: return "Add task"
    case .editTask: return "Edit task..."
    case .command:
      return
        "Action… (done, due [date/time], tag [name], priority [1-9], google calendar)"
    case .quickAddDefault:
      return "Quick add to list root"
    case .quickAddSpecific:
      if let taskId = manager.quickAddSpecificParentTaskIdValue {
        return "Quick add under task #\(taskId)"
      }
      return "Quick add under specific task (set parent ID in Preferences)"
    }
  }

  var quickEntryNSFont: NSFont {
    switch manager.quickEntryMode {
    case .addSibling, .addChild, .editTask, .quickAddDefault, .quickAddSpecific:
      return BarTaskerTypography.taskNSFont(ofSize: 13)
    case .search, .command:
      return BarTaskerTypography.interfaceNSFont(ofSize: 13)
    }
  }

  var filteredCommandSuggestions: [BarTaskerManager.CommandSuggestion] {
    manager.filteredCommandSuggestions(query: manager.quickEntryText)
  }

  func submitAction() {
    switch manager.quickEntryMode {
    case .search:
      manager.isQuickEntryFocused = false
    case .addSibling: submitSibling()
    case .addChild: submitChild()
    case .editTask:
      guard !manager.quickEntryText.isEmpty else { return }
      if let task = manager.currentTask {
        let newContent = manager.quickEntryText
        escapeAction()
        Task { await manager.updateTask(task: task, content: newContent) }
      }
    case .command:
      guard !manager.quickEntryText.isEmpty else { return }
      let cmd = manager.quickEntryText
      escapeAction()
      Task { await manager.executeCommandInput(cmd) }
    case .quickAddDefault:
      submitQuickAdd(useSpecificLocation: false)
    case .quickAddSpecific:
      submitQuickAdd(useSpecificLocation: true)
    }
  }

  func tabAction() {
    switch manager.quickEntryMode {
    case .addSibling, .addChild:
      if manager.quickEntryText.isEmpty {
        manager.quickEntryMode = .addChild
        manager.isQuickEntryFocused = true
        return
      }
      submitChild()
    case .search, .editTask, .command, .quickAddDefault, .quickAddSpecific:
      return
    }
  }

  func escapeAction() {
    manager.isQuickEntryFocused = false
    switch manager.quickEntryMode {
    case .search:
      manager.searchText = ""
    case .addSibling, .addChild, .editTask, .command, .quickAddDefault, .quickAddSpecific:
      manager.quickEntryMode = .search
      manager.quickEntryText = ""
      manager.commandSuggestionIndex = 0
    }
  }

  func escapeEmptyStateAdd() {
    manager.isQuickEntryFocused = false
    manager.quickEntryText = ""
    activateEmptyListComposerModeIfNeeded()
  }

  func submitEmptyStateAdd() {
    manager.quickEntryMode = .addSibling
    submitSibling()
  }

  func activateEmptyListComposerModeIfNeeded() {
    guard shouldShowEmptyListComposer else { return }
    if manager.quickEntryMode == .search {
      manager.quickEntryMode = .addSibling
    }
  }

  func breadcrumbPath(for task: CheckvistTask, includeCurrentParent: Bool = false) -> String {
    var parts: [String] = []
    var pid = task.parentId ?? 0
    while pid != 0 {
      if !includeCurrentParent && pid == manager.currentParentId {
        break
      }
      if let parent = manager.tasks.first(where: { $0.id == pid }) {
        parts.insert(parent.content, at: 0)
        pid = parent.parentId ?? 0
      } else {
        break
      }
    }
    return parts.joined(separator: " › ")
  }

  func submitSibling() {
    guard !manager.quickEntryText.isEmpty else {
      // Dismiss if empty
      manager.quickEntryText = ""
      manager.quickEntryMode = .search
      manager.isQuickEntryFocused = false
      return
    }
    let content = manager.quickEntryText
    let targetTask = manager.currentTask
    let shouldPreserveAddMode = manager.quickEntryMode == .addSibling
    manager.quickEntryText = ""
    manager.errorMessage = nil
    if shouldPreserveAddMode {
      manager.isQuickEntryFocused = true
    }
    Task { await manager.addTask(content: content, insertAfterTask: targetTask) }
  }

  func submitTopLevelAdd() {
    guard !manager.quickEntryText.isEmpty else {
      manager.isQuickEntryFocused = false
      return
    }
    let content = manager.quickEntryText
    manager.quickEntryText = ""
    manager.errorMessage = nil
    manager.isQuickEntryFocused = true
    Task { await manager.addTask(content: content, insertAtTopOfCurrentLevel: true) }
  }

  func submitChild() {
    guard !manager.quickEntryText.isEmpty, let parent = manager.currentTask else {
      // Dismiss if empty
      if manager.quickEntryText.isEmpty {
        manager.quickEntryText = ""
        manager.quickEntryMode = .search
        manager.isQuickEntryFocused = false
      }
      return
    }
    let content = manager.quickEntryText
    manager.quickEntryText = ""
    manager.errorMessage = nil
    manager.isQuickEntryFocused = true
    Task { await manager.addTaskAsChild(content: content, parentId: parent.id) }
  }

  func submitQuickAdd(useSpecificLocation: Bool) {
    guard !manager.quickEntryText.isEmpty else { return }
    let content = manager.quickEntryText
    Task {
      await manager.submitQuickAddTask(content: content, useSpecificLocation: useSpecificLocation)
    }
  }

  @ViewBuilder
  func timerBadge(elapsed: TimeInterval, running: Bool) -> some View {
    HStack(spacing: 3) {
      Image(systemName: running ? "timer" : "pause.circle")
        .font(.system(size: 9))
      Text(formattedTimer(elapsed))
        .font(.system(size: 10, weight: .medium, design: .monospaced))
    }
    .padding(.horizontal, 5).padding(.vertical, 2)
    .background(running ? themeColor(.link).opacity(0.15) : themeColor(.panelSurfaceElevated))
    .foregroundColor(running ? themeColor(.link) : themeColor(.textSecondary))
    .clipShape(RoundedRectangle(cornerRadius: 4))
  }

  func formattedTimer(_ elapsed: TimeInterval) -> String {
    BarTaskerManager.formattedTimer(elapsed)
  }

  @ViewBuilder
  func fadedTaskTitle(task: CheckvistTask) -> some View {
    MarqueeTextLine(fadeWidth: PopoverLayout.rowTextFadeWidth) {
      inlineTaskContent(task: task)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  func inlineTaskContent(task: CheckvistTask) -> Text {
    formatTaskContent(taskDisplayTitle(task.content))
  }

  func taskDisplayTitle(_ text: String) -> String {
    let pattern = "([@#][a-zA-Z0-9_\\-]+)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    let range = NSRange(text.startIndex..., in: text)
    let stripped = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    let normalized =
      stripped
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? text : normalized
  }

  func taskMetadataTokens(_ text: String) -> [String] {
    let pattern = "([@#][a-zA-Z0-9_\\-]+)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    let matches = regex.matches(in: text, range: range)
    return matches.compactMap { match in
      guard let matchRange = Range(match.range, in: text) else { return nil }
      return String(text[matchRange])
    }
  }

  @ViewBuilder
  func taskInlineMetadata(task: CheckvistTask, elapsed: TimeInterval) -> some View {
    let metadataTokens = taskMetadataTokens(task.content)
    let startLabel = manager.startDateLabel(for: task)
    if !metadataTokens.isEmpty
      || manager.priorityRank(for: task) != nil
      || (manager.timerIsVisible && (elapsed > 0 || manager.timedTaskId == task.id))
      || task.due != nil
      || startLabel != nil
    {
      HStack(spacing: 4) {
        ForEach(metadataTokens, id: \.self) { token in
          metadataTokenBadge(token)
        }
        if let priority = manager.priorityRank(for: task) {
          priorityBadge(priority)
        }
        if manager.timerIsVisible && (elapsed > 0 || manager.timedTaskId == task.id) {
          timerBadge(
            elapsed: elapsed, running: manager.timedTaskId == task.id && manager.timerRunning)
        }
        if let label = startLabel {
          startBadge(label: label, isFuture: manager.startDateIsInFuture(for: task))
        }
        if let due = task.due {
          dueBadge(due: due, overdue: task.isOverdue, today: task.isDueToday)
        }
      }
      .fixedSize(horizontal: true, vertical: false)
    }
  }

  @ViewBuilder
  func priorityBadge(_ priority: Int) -> some View {
    Text("P\(priority)")
      .font(.system(size: 10, weight: .semibold, design: .monospaced))
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(themeColor(.selectionBackground))
      .foregroundColor(themeColor(.selectionForeground))
      .clipShape(RoundedRectangle(cornerRadius: 4))
  }

  @ViewBuilder
  func startBadge(label: String, isFuture: Bool) -> some View {
    HStack(spacing: 3) {
      Image(systemName: "play.fill")
        .font(.system(size: 8))
      Text(label)
        .font(.caption2)
    }
    .padding(.horizontal, 5).padding(.vertical, 2)
    .background(
      isFuture
        ? themeColor(.accent).opacity(0.12)
        : themeColor(.panelSurfaceElevated)
    )
    .foregroundColor(
      isFuture ? themeColor(.accent) : themeColor(.textSecondary)
    )
    .clipShape(RoundedRectangle(cornerRadius: 4))
  }

  @ViewBuilder
  func dueBadge(due: String, overdue: Bool, today: Bool) -> some View {
    Text(due).font(.caption2)
      .padding(.horizontal, 5).padding(.vertical, 2)
      .background(
        overdue
          ? themeColor(.danger).opacity(0.15)
          : today ? themeColor(.warning).opacity(0.15) : themeColor(.panelSurfaceElevated)
      )
      .foregroundColor(
        overdue
          ? themeColor(.danger)
          : today ? themeColor(.warning) : themeColor(.textSecondary)
      )
      .clipShape(RoundedRectangle(cornerRadius: 4))
  }

  @ViewBuilder
  func metadataTokenBadge(_ token: String) -> some View {
    Text(token)
      .font(.system(size: 10, weight: .medium))
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(themeColor(.panelSurfaceElevated))
      .foregroundColor(themeColor(.textSecondary))
      .clipShape(RoundedRectangle(cornerRadius: 4))
  }

  /// Parses Checkvist #tags and @contexts and formats them as inline pills using concatenated Text views
  // swiftlint:disable shorthand_operator
  func formatTaskContent(_ text: String) -> Text {
    let pattern = "([@#][a-zA-Z0-9_\\-]+)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return Text(text).font(BarTaskerTypography.taskFont(size: 13)).foregroundColor(
        themeColor(.textPrimary))
    }

    let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    guard !matches.isEmpty else {
      return Text(text).font(BarTaskerTypography.taskFont(size: 13)).foregroundColor(
        themeColor(.textPrimary))
    }

    var resultText = Text("")
    var lastEnd = text.startIndex

    for match in matches {
      guard let matchRange = Range(match.range, in: text) else { continue }

      // Add preceding text
      if matchRange.lowerBound > lastEnd {
        let preceding = String(text[lastEnd..<matchRange.lowerBound])
        resultText =
          resultText
          + Text(preceding).font(BarTaskerTypography.taskFont(size: 13))
          .foregroundColor(themeColor(.textPrimary))
      }

      // Add the tag pill
      let tagStr = String(text[matchRange])

      // Markdown trick: We can't actually nest complex View backgrounds inside a concatenated Text in standard SwiftUI without iOS 15 AttributedString APIs,
      // but we CAN use basic inline styling like bolding and foreground colors.
      let tagText = Text(tagStr)
        .font(BarTaskerTypography.taskFont(size: 12, weight: .bold))
        .foregroundColor(themeColor(.link))

      resultText = resultText + tagText
      lastEnd = matchRange.upperBound
    }

    // Add trailing text
    if lastEnd < text.endIndex {
      let trailing = String(text[lastEnd..<text.endIndex])
      resultText =
        resultText
        + Text(trailing).font(BarTaskerTypography.taskFont(size: 13))
        .foregroundColor(themeColor(.textPrimary))
    }

    return resultText
  }
  // swiftlint:enable shorthand_operator

}
// swiftlint:enable type_body_length function_body_length
// swiftlint:enable file_length
