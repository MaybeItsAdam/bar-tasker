import AppKit
import SwiftUI

enum PopoverLayout {
  static let width: CGFloat = 360
  static let minHeight: CGFloat = 220
  static let maxHeight: CGFloat = 520
  static let cornerRadius: CGFloat = 10
  static let topStripHeight: CGFloat = 6
  static let rowHorizontalPadding: CGFloat = 14
  static let rowVerticalPadding: CGFloat = 7
  static let rowIconWidth: CGFloat = 16
  static let rowContentSpacing: CGFloat = 10
  static let rowTextFadeWidth: CGFloat = 18
  static let inlineEntryVerticalPadding: CGFloat = 7

  @MainActor
  static func preferredHeight(for manager: CheckvistManager) -> CGFloat {
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
    if !manager.pendingDeleteConfirmation
      && (manager.quickEntryMode == .search
        || manager.quickEntryMode == .quickAddDefault
        || manager.quickEntryMode == .quickAddSpecific)
      && (manager.isQuickEntryFocused || !manager.filterText.isEmpty)
    {
      fixedHeight += 40
    }
    if !manager.pendingDeleteConfirmation
      && (manager.quickEntryMode == .command
        && (manager.isQuickEntryFocused || !manager.filterText.isEmpty))
    {
      // Input row + autocomplete list block.
      fixedHeight += 220
    }
    if !manager.pendingDeleteConfirmation && manager.activeOnboardingDialog != nil {
      fixedHeight += 72
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
  override func keyDown(with event: NSEvent) {
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
    tf.font = .systemFont(ofSize: 13)
    tf.delegate = context.coordinator
    tf.onTab = onTab
    return tf
  }

  func updateNSView(_ tf: TabInterceptingTextField, context: Context) {
    let textChanged = tf.stringValue != text
    if textChanged {
      tf.stringValue = text
    }
    tf.placeholderString = placeholder
    tf.onTab = onTab

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
    init(_ p: QuickEntryField) { parent = p }

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

struct PopoverView: View {
  @EnvironmentObject var manager: CheckvistManager

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
          let shouldShowPrompt =
            ((manager.quickEntryMode == .search
              || manager.quickEntryMode == .quickAddDefault
              || manager.quickEntryMode == .quickAddSpecific)
              && (manager.isQuickEntryFocused || !manager.filterText.isEmpty))
            || (manager.quickEntryMode == .command
              && (manager.isQuickEntryFocused || !manager.filterText.isEmpty))
          if shouldShowPrompt {
            quickEntryBar()
          }
        }
      }

    }
    .frame(width: PopoverLayout.width, height: panelHeight, alignment: .top)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: PopoverLayout.cornerRadius))
    .onAppear {
      manager.presentOnboardingDialogIfNeeded()
    }
  }

  @ViewBuilder
  private func onboardingInlineBar() -> some View {
    if let dialog = manager.activeOnboardingDialog {
      let config = onboardingInlineContent(for: dialog)
      HStack(alignment: .top, spacing: 8) {
        VStack(alignment: .leading, spacing: 4) {
          Text(config.title)
            .font(.system(size: 12, weight: .semibold))
          Text(config.message)
            .font(.caption2)
            .foregroundColor(.secondary)
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
              .foregroundColor(.secondary)
              .frame(width: 16, height: 16)
              .background(Color.secondary.opacity(0.12))
              .clipShape(Circle())
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, PopoverLayout.rowHorizontalPadding)
      .padding(.vertical, 9)
      .background(Color.secondary.opacity(0.08))
    } else {
      EmptyView()
    }
  }

  private func onboardingInlineContent(for dialog: CheckvistManager.OnboardingDialog) -> (
    title: String, message: String, actionTitle: String, action: () -> Void
  ) {
    switch dialog {
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
        "Enable Obsidian",
        "Optional markdown export and folder linking.",
        "Enable",
        {
          manager.obsidianIntegrationEnabled = true
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
    }
  }

  // MARK: - Subviews

  var topBevelArea: some View {
    Color.secondary.opacity(0.08)
      .frame(height: PopoverLayout.topStripHeight)
  }

  var breadcrumbBar: some View {
    HStack(spacing: 4) {
      Button {
        manager.exitToParent()
      } label: {
        Image(systemName: "chevron.left").font(.caption).foregroundColor(.blue)
      }.buttonStyle(PlainButtonStyle())
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 4) {
          Button("All Tasks") {
            manager.currentParentId = 0
            manager.currentSiblingIndex = 0
          }.buttonStyle(PlainButtonStyle()).font(.caption2).foregroundColor(.blue)
          ForEach(manager.breadcrumbs) { crumb in
            Image(systemName: "chevron.right").font(.system(size: 8)).foregroundColor(.secondary)
            Button(crumb.content) { manager.navigateTo(task: crumb) }
              .buttonStyle(PlainButtonStyle()).font(.caption2).foregroundColor(.blue).lineLimit(1)
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
        .background(Color.orange.opacity(0.15)).foregroundColor(.orange).clipShape(Capsule())
      Spacer()
      Button {
        manager.hideFuture = false
      } label: {
        Image(systemName: "xmark").font(.caption2).foregroundColor(.secondary)
      }.buttonStyle(PlainButtonStyle())
    }
    .padding(.horizontal, 14).padding(.vertical, 4)
  }

  var rootScopeSection: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 0) {
        ForEach(
          Array(CheckvistManager.RootTaskView.allCases.enumerated()),
          id: \.element.rawValue
        ) { index, scope in
          if index > 0 {
            rootScopeSeparator()
          }
          rootScopeTabButton(scope)
        }
      }
      .background(Color.secondary.opacity(0.08))
      .overlay {
        Rectangle().stroke(Color.white.opacity(0.08), lineWidth: 1)
      }
      .overlay {
        Rectangle()
          .stroke(
            manager.rootScopeFocusLevel == 1 ? Color.accentColor.opacity(0.9) : Color.clear,
            lineWidth: 1
          )
      }

      if manager.rootTaskView == .due {
        let dueBuckets = CheckvistManager.RootDueBucket.allCases.filter { $0 != .noDueDate }
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
        .background(Color.secondary.opacity(0.08))
        .overlay {
          Rectangle().stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .overlay {
          Rectangle()
            .stroke(
              manager.rootScopeFocusLevel == 2 ? Color.accentColor.opacity(0.9) : Color.clear,
              lineWidth: 1
            )
        }
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
        .background(Color.secondary.opacity(0.08))
        .overlay {
          Rectangle().stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .overlay {
          Rectangle()
            .stroke(
              manager.rootScopeFocusLevel == 2 ? Color.accentColor.opacity(0.9) : Color.clear,
              lineWidth: 1
            )
        }
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
  func rootScopeTabButton(_ scope: CheckvistManager.RootTaskView) -> some View {
    let selected = manager.rootTaskView == scope
    Button {
      manager.setRootTaskView(scope)
      manager.rootScopeFocusLevel = 1
    } label: {
      Text(scope.title)
        .font(.system(size: 12, weight: .semibold))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(selected ? Color.accentColor.opacity(0.24) : Color.clear)
        .foregroundColor(selected ? Color.accentColor : .secondary)
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
        .background(isSelected ? Color.accentColor.opacity(0.24) : Color.clear)
        .foregroundColor(isSelected ? Color.accentColor : .secondary)
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder
  func rootScopeSeparator() -> some View {
    Rectangle()
      .fill(Color.white.opacity(0.08))
      .frame(width: 1, height: 20)
  }

  func scrollRootDueFilterIntoView(proxy: ScrollViewProxy) {
    let targetId: String
    if let bucket = manager.selectedRootDueBucket {
      targetId = "due-filter-\(bucket.rawValue)"
    } else {
      targetId = "due-filter-all"
    }
    DispatchQueue.main.async {
      withAnimation(.easeInOut(duration: 0.12)) {
        proxy.scrollTo(targetId, anchor: .center)
      }
    }
  }

  func scrollRootTagFilterIntoView(proxy: ScrollViewProxy) {
    let targetId =
      manager.selectedRootTag.isEmpty
      ? "tags-filter-all" : "tags-filter-\(manager.selectedRootTag)"
    DispatchQueue.main.async {
      withAnimation(.easeInOut(duration: 0.12)) {
        proxy.scrollTo(targetId, anchor: .center)
      }
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
        HStack {
          Spacer()
          VStack(spacing: 6) {
            Image(systemName: manager.filterText.isEmpty ? "checkmark.circle" : "magnifyingglass")
              .font(.title2).foregroundColor(.secondary)
            Text(manager.filterText.isEmpty ? "No tasks here" : "No matches")
              .foregroundColor(.secondary).font(.callout)
          }.padding(24)
          Spacer()
        }
        .frame(minHeight: 150)
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

                if manager.currentSiblingIndex == index && manager.quickEntryMode == .addSibling {
                  quickEntryBar(verticalPadding: PopoverLayout.inlineEntryVerticalPadding)
                    .background(Color(NSColor.textBackgroundColor).opacity(0.3))
                    .overlay(alignment: .leading) {
                      Rectangle().fill(Color.accentColor).frame(width: 3)
                    }
                    .id("quickEntry")
                } else if manager.currentSiblingIndex == index
                  && manager.quickEntryMode == .addChild
                {
                  quickEntryBar(
                    verticalPadding: PopoverLayout.inlineEntryVerticalPadding,
                    leadingInset: 20
                  )
                  .background(Color(NSColor.textBackgroundColor).opacity(0.3))
                  .overlay(alignment: .leading) {
                    Rectangle().fill(Color.accentColor).frame(width: 3)
                  }
                  .id("quickEntry")
                }
              }
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          .onChange(of: manager.currentSiblingIndex) { _, _ in
            if let t = manager.currentTask { proxy.scrollTo(t.id, anchor: .center) }
          }
          .onChange(of: manager.isQuickEntryFocused) { _, focused in
            if focused && [.addSibling, .addChild].contains(manager.quickEntryMode) {
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                proxy.scrollTo("quickEntry", anchor: .bottom)
              }
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  var deleteConfirmationBar: some View {
    HStack(spacing: 8) {
      Image(systemName: "trash")
        .foregroundColor(.red).font(.system(size: 13))
      Text("Delete \"\(manager.currentTask?.content.prefix(30) ?? "")\"?")
        .font(.system(size: 13)).foregroundColor(.primary).lineLimit(1)
      Spacer()
      Text("⏎ confirm  Esc cancel")
        .font(.caption2).foregroundColor(.secondary)
    }
    .padding(.horizontal, 14).padding(.vertical, 10)
    .background(Color.red.opacity(0.08))
  }

  @ViewBuilder
  func quickEntryBar(verticalPadding: CGFloat = 10, leadingInset: CGFloat = 0) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center, spacing: PopoverLayout.rowContentSpacing) {
        Image(systemName: iconForMode)
          .foregroundColor(.secondary)
          .font(.system(size: 13))
          .frame(width: PopoverLayout.rowIconWidth, height: 20, alignment: .center)

        QuickEntryField(
          text: $manager.filterText,
          isFocused: $manager.isQuickEntryFocused,
          placeholder: placeholderText,
          onSubmit: { submitAction() },
          onTab: { tabAction() },
          onEscape: { escapeAction() }
        )
        .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20, alignment: .leading)
        .onChange(of: manager.filterText) { _, q in
          if manager.quickEntryMode == .search {
            manager.currentSiblingIndex = 0
          } else if manager.quickEntryMode == .command {
            manager.commandSuggestionIndex = 0
          }
        }

        if !manager.filterText.isEmpty || manager.isQuickEntryFocused {
          Button {
            manager.filterText = ""
            manager.quickEntryMode = .search
            manager.isQuickEntryFocused = false
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundColor(.secondary)
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
                  manager.filterText = suggestion.command
                  if suggestion.submitImmediately {
                    manager.isQuickEntryFocused = false
                    manager.quickEntryMode = .search
                    manager.filterText = ""
                    Task { await manager.executeCommandInput(suggestion.command) }
                  } else {
                    manager.isQuickEntryFocused = true
                  }
                } label: {
                  HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                      Text(suggestion.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                      Text(suggestion.preview)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 8)
                    if let keybind = suggestion.keybind {
                      Text(keybind)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                  }
                  .padding(.horizontal, 9)
                  .padding(.vertical, 7)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .background(
                    idx == manager.commandSuggestionIndex
                      ? Color.accentColor.opacity(0.14) : Color.clear
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
          .onChange(of: manager.filterText) { _, _ in
            withAnimation(.easeInOut(duration: 0.12)) {
              proxy.scrollTo("cmd-suggestion-\(manager.commandSuggestionIndex)", anchor: .center)
            }
          }
        }
        .frame(maxHeight: 170)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7))
      }
    }
    .padding(.leading, PopoverLayout.rowHorizontalPadding + leadingInset)
    .padding(.trailing, PopoverLayout.rowHorizontalPadding)
    .padding(.vertical, verticalPadding)

    if let error = manager.errorMessage {
      Text(error).font(.caption2).foregroundColor(.red)
        .padding(.horizontal, 14).padding(.bottom, 6)
    }
  }

  // MARK: - Task Rows

  @ViewBuilder
  func dueSectionHeader(_ title: String) -> some View {
    HStack {
      Text(title.uppercased())
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(.secondary)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, PopoverLayout.rowHorizontalPadding)
    .padding(.top, 8)
    .padding(.bottom, 5)
    .background(Color.secondary.opacity(0.05))
  }

  @ViewBuilder
  func taskRow(task: CheckvistTask, index: Int, childCount: Int, elapsed: TimeInterval) -> some View
  {
    let isSelected = index == manager.currentSiblingIndex
    let isCompleting = manager.completingTaskId == task.id

    HStack(alignment: .top, spacing: PopoverLayout.rowContentSpacing) {
      Image(
        systemName: isCompleting
          ? "checkmark.circle.fill" : isSelected ? "largecircle.fill.circle" : "circle"
      )
      .foregroundColor(isCompleting ? .green : isSelected ? .accentColor : .secondary)
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
            && !(manager.quickEntryMode == .search && !manager.filterText.isEmpty)
          let path = breadcrumbPath(
            for: task,
            includeCurrentParent: includeCurrentParent
          )
          if !path.isEmpty {
            Text(path)
              .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
          }
        }

        // Inline edit: replace text with editable field when editing this task
        if isSelected && manager.quickEntryMode == .editTask && manager.isQuickEntryFocused {
          QuickEntryField(
            text: $manager.filterText,
            isFocused: $manager.isQuickEntryFocused,
            cursorAtEnd: manager.editCursorAtEnd,
            placeholder: "Edit task…",
            onSubmit: { submitAction() },
            onTab: {},
            onEscape: { escapeAction() }
          )
          .frame(height: 18)
          .frame(maxWidth: .infinity, alignment: .leading)
        } else {
          HStack(spacing: 6) {
            fadedTaskTitle(task: task)
            if task.hasNotes {
              Image(systemName: "text.alignleft")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
            }
          }
        }

        if let priority = manager.priorityRank(for: task) {
          priorityBadge(priority)
        }

        if manager.timerIsVisible && (elapsed > 0 || manager.timedTaskId == task.id) {
          timerBadge(
            elapsed: elapsed, running: manager.timedTaskId == task.id && manager.timerRunning)
        }

        if let due = task.due {
          dueBadge(due: due, overdue: task.isOverdue, today: task.isDueToday)
        }
      }
      .layoutPriority(1)
      .overlay(alignment: .center) {
        // Strikethrough line that draws left-to-right when completing
        Rectangle()
          .fill(Color.green.opacity(0.65))
          .frame(height: 1.5)
          .scaleEffect(x: isCompleting ? 1.0 : 0.001, y: 1, anchor: .leading)
          .animation(.easeOut(duration: 0.12), value: isCompleting)
      }

      if childCount > 0 {
        Button {
          manager.currentSiblingIndex = index
          manager.enterChildren()
          if !manager.filterText.isEmpty {
            manager.filterText = ""
            manager.quickEntryMode = .search
            manager.isQuickEntryFocused = false
          }
        } label: {
          HStack(spacing: 3) {
            Text("\(childCount)").font(.caption2).foregroundColor(.secondary)
            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundColor(.secondary)
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
        ? Color.green.opacity(0.12) : isSelected ? Color.accentColor.opacity(0.09) : Color.clear
    )
    .overlay(alignment: .leading) {
      Rectangle().fill(isCompleting ? Color.green : isSelected ? Color.accentColor : Color.clear)
        .frame(width: 3)
    }
    .contentShape(Rectangle())
    .onTapGesture {
      manager.rootScopeFocusLevel = 0
      manager.currentSiblingIndex = index
    }
    .contextMenu {
      Button("Mark Done ␣") {
        Task {
          manager.currentSiblingIndex = index
          await manager.markCurrentTaskDone()
        }
      }
      Button("Invalidate ⇧␣") {
        Task {
          manager.currentSiblingIndex = index
          await manager.invalidateCurrentTask()
        }
      }
      if childCount > 0 {
        Button("Enter Subtasks →") {
          manager.currentSiblingIndex = index
          manager.enterChildren()
          if !manager.filterText.isEmpty {
            manager.filterText = ""
            manager.quickEntryMode = .search
            manager.isQuickEntryFocused = false
          }
        }
      }
      Divider()
      Button("Edit i/a/F2") {
        manager.currentSiblingIndex = index
        manager.quickEntryMode = .editTask
        manager.editCursorAtEnd = true
        manager.filterText = task.content
        manager.isQuickEntryFocused = true
      }
      Button("Due Date/Time dd") {
        manager.currentSiblingIndex = index
        manager.quickEntryMode = .command
        manager.commandSuggestionIndex = 0
        manager.filterText = "due "
        manager.isQuickEntryFocused = true
      }
      Button("Tag tt") {
        manager.currentSiblingIndex = index
        manager.quickEntryMode = .command
        manager.commandSuggestionIndex = 0
        manager.filterText = "tag "
        manager.isQuickEntryFocused = true
      }
      Divider()
      Button("Move Up ⌘↑") { Task { await manager.moveTask(task, direction: -1) } }
      Button("Move Down ⌘↓") { Task { await manager.moveTask(task, direction: 1) } }
      Divider()
      Button("Indent ⇥") { Task { await manager.indentTask(task) } }
      Button("Unindent ⇧⇥") { Task { await manager.unindentTask(task) } }
      if manager.obsidianIntegrationEnabled {
        Divider()
        Button("Create & Link Obsidian Folder") {
          manager.currentSiblingIndex = index
          manager.createAndLinkCurrentTaskObsidianFolder(taskId: task.id)
        }
        Button("Link Obsidian Folder") {
          manager.currentSiblingIndex = index
          manager.linkCurrentTaskToObsidianFolder(taskId: task.id)
        }
        if manager.hasObsidianFolderLink(taskId: task.id) {
          Button("Clear Obsidian Folder Link") {
            manager.currentSiblingIndex = index
            manager.clearCurrentTaskObsidianFolderLink(taskId: task.id)
          }
        }
        Divider()
        Button("Open in Obsidian o") {
          manager.currentSiblingIndex = index
          Task { await manager.syncCurrentTaskToObsidian(taskId: task.id) }
        }
        Button("Open in New Obsidian Window O") {
          manager.currentSiblingIndex = index
          Task { await manager.openCurrentTaskInNewObsidianWindow(taskId: task.id) }
        }
      }
      if manager.googleCalendarIntegrationEnabled {
        Divider()
        Button("Add to Google Calendar gc") {
          manager.currentSiblingIndex = index
          manager.openCurrentTaskInGoogleCalendar(taskId: task.id)
        }
      }
      Divider()
      Button("Delete", role: .destructive) {
        manager.currentSiblingIndex = index
        if manager.confirmBeforeDelete {
          manager.pendingDeleteConfirmation = true
        } else {
          Task { await manager.deleteTask(task) }
        }
      }
    }
  }

  // MARK: - Helpers

  var iconForMode: String {
    switch manager.quickEntryMode {
    case .search:
      return manager.filterText.isEmpty
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
    case .search: return "Search or type to add… (⏎ sibling, ⇥ child)"
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

  var filteredCommandSuggestions: [CheckvistManager.CommandSuggestion] {
    manager.filteredCommandSuggestions(query: manager.filterText)
  }

  func submitAction() {
    if manager.quickEntryMode == .search {
      manager.isQuickEntryFocused = false
      return
    }

    if manager.filterText.isEmpty { return }
    switch manager.quickEntryMode {
    case .addSibling: submitSibling()
    case .addChild: submitChild()
    case .editTask:
      if let task = manager.currentTask {
        let newContent = manager.filterText
        escapeAction()
        Task { await manager.updateTask(task: task, content: newContent) }
      }
    case .command:
      let cmd = manager.filterText
      escapeAction()
      Task { await manager.executeCommandInput(cmd) }
    case .quickAddDefault:
      submitQuickAdd(useSpecificLocation: false)
    case .quickAddSpecific:
      submitQuickAdd(useSpecificLocation: true)
    default: break
    }
  }

  func tabAction() {
    if manager.filterText.isEmpty {
      // Empty Tab = prepare to add child
      manager.quickEntryMode = .addChild
      manager.isQuickEntryFocused = true
      return
    }
    submitChild()
  }

  func escapeAction() {
    manager.isQuickEntryFocused = false
    manager.quickEntryMode = .search
    manager.filterText = ""
    manager.commandSuggestionIndex = 0
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
    guard !manager.filterText.isEmpty else {
      // Dismiss if empty
      manager.filterText = ""
      manager.quickEntryMode = .search
      manager.isQuickEntryFocused = false
      return
    }
    let content = manager.filterText
    let targetTask = manager.currentTask
    Task { await manager.addTask(content: content, insertAfterTask: targetTask) }
  }

  func submitChild() {
    guard !manager.filterText.isEmpty, let parent = manager.currentTask else {
      // Dismiss if empty
      if manager.filterText.isEmpty {
        manager.filterText = ""
        manager.quickEntryMode = .search
        manager.isQuickEntryFocused = false
      }
      return
    }
    let content = manager.filterText
    Task { await manager.addTaskAsChild(content: content, parentId: parent.id) }
  }

  func submitQuickAdd(useSpecificLocation: Bool) {
    guard !manager.filterText.isEmpty else { return }
    let content = manager.filterText
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
    .background(running ? Color.blue.opacity(0.15) : Color.secondary.opacity(0.1))
    .foregroundColor(running ? .blue : .secondary)
    .clipShape(RoundedRectangle(cornerRadius: 4))
  }

  func formattedTimer(_ elapsed: TimeInterval) -> String {
    CheckvistManager.formattedTimer(elapsed)
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
    formatTaskContent(task.content)
  }

  @ViewBuilder
  func priorityBadge(_ priority: Int) -> some View {
    Text("P\(priority)")
      .font(.system(size: 10, weight: .semibold, design: .monospaced))
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(Color.accentColor.opacity(0.2))
      .foregroundColor(.accentColor)
  }

  @ViewBuilder
  func dueBadge(due: String, overdue: Bool, today: Bool) -> some View {
    Text(due).font(.caption2)
      .padding(.horizontal, 5).padding(.vertical, 2)
      .background(
        overdue
          ? Color.red.opacity(0.15)
          : today ? Color.orange.opacity(0.15) : Color.secondary.opacity(0.1)
      )
      .foregroundColor(overdue ? .red : today ? .orange : .secondary)
      .clipShape(RoundedRectangle(cornerRadius: 4))
  }

  /// Parses Checkvist #tags and @contexts and formats them as inline pills using concatenated Text views
  func formatTaskContent(_ text: String) -> Text {
    let pattern = "([@#][a-zA-Z0-9_\\-]+)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return Text(text).font(.system(size: 13)).foregroundColor(.primary)
    }

    let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    guard !matches.isEmpty else {
      return Text(text).font(.system(size: 13)).foregroundColor(.primary)
    }

    var resultText = Text("")
    var lastEnd = text.startIndex

    for match in matches {
      guard let matchRange = Range(match.range, in: text) else { continue }

      // Add preceding text
      if matchRange.lowerBound > lastEnd {
        let preceding = String(text[lastEnd..<matchRange.lowerBound])
        resultText = resultText + Text(preceding).font(.system(size: 13)).foregroundColor(.primary)
      }

      // Add the tag pill
      let tagStr = String(text[matchRange])

      // Markdown trick: We can't actually nest complex View backgrounds inside a concatenated Text in standard SwiftUI without iOS 15 AttributedString APIs,
      // but we CAN use basic inline styling like bolding and foreground colors.
      let tagText = Text(tagStr)
        .font(.system(size: 12, weight: .bold))
        .foregroundColor(.blue)

      resultText = resultText + tagText
      lastEnd = matchRange.upperBound
    }

    // Add trailing text
    if lastEnd < text.endIndex {
      let trailing = String(text[lastEnd..<text.endIndex])
      resultText = resultText + Text(trailing).font(.system(size: 13)).foregroundColor(.primary)
    }

    return resultText
  }

}
