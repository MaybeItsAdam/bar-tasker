import Carbon.HIToolbox
import Combine
import OSLog
import SwiftUI

@MainActor
// swiftlint:disable type_body_length
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  private struct TitleCacheInputs: Equatable {
    let taskText: String
    let timerText: String?
    let maxWidth: CGFloat
    let timerLeading: Bool
  }

  private enum RegisteredHotkeyID: UInt32 {
    case togglePopover = 1
    case quickAdd = 2
  }

  private static let globalHotkeySignature = OSType(0x4356_464B)  // "CVFK"

  static private(set) var shared: AppDelegate!

  override init() {
    super.init()
    Self.shared = self
  }

  private let pluginRegistry = BarTaskerPluginRegistry.nativeFirst()
  lazy var checkvistManager: BarTaskerManager = BarTaskerManager(pluginRegistry: pluginRegistry)
  private var statusItem: NSStatusItem!
  private var window: NSWindow?
  private var preferencesWindow: NSWindow?
  private var preferencesNavState: SettingsNavState?
  private var keyMonitor: Any?
  private var clickMonitor: Any?
  private var globalHotkeyRef: EventHotKeyRef?
  private var quickAddHotkeyRef: EventHotKeyRef?
  private var cancellables = Set<AnyCancellable>()
  private var lastToggleTime: Date = Date.distantPast
  private var pendingPopoverResize: DispatchWorkItem?
  private var explicitQuitRequested = false
  private var lastAutoRefreshTime: Date = Date.distantPast
  private var cachedTitleInputs: TitleCacheInputs?
  private var cachedTitleResult: String?
  private var cachedGradientWidth: CGFloat?
  private var cachedGradientLayer: CAGradientLayer?
  private let logger = Logger(subsystem: "uk.co.maybeitsadam.bar-tasker", category: "keyboard")

  private var currentPopoverContentSize: NSSize {
    NSSize(
      width: PopoverLayout.width,
      height: PopoverLayout.preferredHeight(for: checkvistManager)
    )
  }

  #if DEBUG
    private var isRunningFromXcode: Bool {
      let env = ProcessInfo.processInfo.environment
      return env["XCODE_VERSION_ACTUAL"] != nil || env["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil
    }
  #endif

  func applicationDidFinishLaunching(_ notification: Notification) {
    if BarTaskerMCPServer.isLaunchMode(arguments: ProcessInfo.processInfo.arguments) {
      launchMCPServerMode()
      return
    }

    NSApp.setActivationPolicy(.accessory)
    applyAppTheme()
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.title = "…"
    statusItem.button?.action = #selector(clicked)
    statusItem.button?.target = self
    statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

    // Title sync — debounce rapid state changes to avoid redundant work.
    checkvistManager.objectWillChange
      .debounce(for: .milliseconds(16), scheduler: RunLoop.main)  // ~1 frame at 60Hz
      .sink { [weak self] _ in
        self?.updateTitle()
        self?.schedulePopoverResize()
      }
      .store(in: &cancellables)

    // Install shared Carbon event handler for hotkeys once
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, eventRef, _ -> OSStatus in
        guard let eventRef else { return noErr }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
          eventRef,
          EventParamName(kEventParamDirectObject),
          EventParamType(typeEventHotKeyID),
          nil,
          MemoryLayout<EventHotKeyID>.size,
          nil,
          &hotKeyID
        )
        guard status == noErr else { return noErr }
        Task { @MainActor in
          AppDelegate.shared.handleGlobalHotkeyPressed(id: hotKeyID.id)
        }
        return noErr
      }, 1, &eventType, nil, nil)

    // Global key monitor for shortcuts not handled by onKeyPress (j/k, hf, Ctrl+↑↓)
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, let popoverWindow = self.window, popoverWindow.isVisible else { return event }
      guard event.window === popoverWindow else { return event }
      return self.handleSupplementalKey(event: event) ? nil : event
    }

    // Register global hotkeys, debouncing rapid changes into a single re-registration.
    registerGlobalHotkeys()
    Publishers.MergeMany(
      checkvistManager.$globalHotkeyEnabled.dropFirst().map { _ in () }.eraseToAnyPublisher(),
      checkvistManager.$globalHotkeyKeyCode.dropFirst().map { _ in () }.eraseToAnyPublisher(),
      checkvistManager.$globalHotkeyModifiers.dropFirst().map { _ in () }.eraseToAnyPublisher(),
      checkvistManager.$quickAddHotkeyEnabled.dropFirst().map { _ in () }.eraseToAnyPublisher(),
      checkvistManager.$quickAddHotkeyKeyCode.dropFirst().map { _ in () }.eraseToAnyPublisher(),
      checkvistManager.$quickAddHotkeyModifiers.dropFirst().map { _ in () }.eraseToAnyPublisher()
    )
    .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
    .sink { [weak self] _ in
      self?.registerGlobalHotkeys()
    }
    .store(in: &cancellables)

    checkvistManager.$maxTitleWidth
      .dropFirst().receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.updateTitle()
      }
      .store(in: &cancellables)

    checkvistManager.$appTheme
      .dropFirst()
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.applyAppTheme()
      }
      .store(in: &cancellables)

    NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.scheduleAutoRefresh()
      }
      .store(in: &cancellables)

    NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.scheduleAutoRefresh()
      }
      .store(in: &cancellables)

    Task { [weak self] in
      try? await Task.sleep(nanoseconds: 500_000_000)
      guard let self else { return }
      #if DEBUG
        if self.isRunningFromXcode {
          self.showPopoverWindow()
        }
      #endif
      await self.checkvistManager.fetchTopTask()
      self.updateTitle()
    }
  }

  private func launchMCPServerMode() {
    NSApp.setActivationPolicy(.prohibited)
    Task.detached(priority: .userInitiated) {
      await BarTaskerMCPServer().run()
      await MainActor.run {
        NSApp.terminate(nil)
      }
    }
  }

  private func applyAppTheme() {
    switch checkvistManager.appTheme {
    case .system:
      NSApp.appearance = nil
    case .light:
      NSApp.appearance = NSAppearance(named: .aqua)
    case .dark:
      NSApp.appearance = NSAppearance(named: .darkAqua)
    }
  }

  // MARK: - Global Hotkeys

  private func handleGlobalHotkeyPressed(id: UInt32) {
    guard let registeredID = RegisteredHotkeyID(rawValue: id) else { return }
    switch registeredID {
    case .togglePopover:
      togglePopover()
    case .quickAdd:
      triggerQuickAddFromHotkey()
    }
  }

  private func registerGlobalHotkeys() {
    unregisterGlobalHotkeys()

    if checkvistManager.globalHotkeyEnabled {
      globalHotkeyRef = registerHotkey(
        id: .togglePopover,
        keyCode: checkvistManager.globalHotkeyKeyCode,
        modifiers: checkvistManager.globalHotkeyModifiers
      )
    }
    if checkvistManager.quickAddHotkeyEnabled {
      quickAddHotkeyRef = registerHotkey(
        id: .quickAdd,
        keyCode: checkvistManager.quickAddHotkeyKeyCode,
        modifiers: checkvistManager.quickAddHotkeyModifiers
      )
    }
  }

  private func registerHotkey(id: RegisteredHotkeyID, keyCode: Int, modifiers: Int)
    -> EventHotKeyRef?
  {
    var hotKeyRef: EventHotKeyRef?
    let hotKeyID = EventHotKeyID(signature: Self.globalHotkeySignature, id: id.rawValue)
    let status = RegisterEventHotKey(
      UInt32(keyCode),
      UInt32(modifiers),
      hotKeyID,
      GetApplicationEventTarget(),
      0,
      &hotKeyRef
    )
    return status == noErr ? hotKeyRef : nil
  }

  private func unregisterGlobalHotkeys() {
    if let ref = globalHotkeyRef {
      UnregisterEventHotKey(ref)
      globalHotkeyRef = nil
    }
    if let ref = quickAddHotkeyRef {
      UnregisterEventHotKey(ref)
      quickAddHotkeyRef = nil
    }
  }

  func updateTitle() {
    let rawTaskText = checkvistManager.currentTaskText
    let baseTaskText = menuBarDisplayTaskText(rawTaskText)
    let taskText =
      checkvistManager.pendingSyncMenuBarPrefix.isEmpty
      ? baseTaskText
      : "\(checkvistManager.pendingSyncMenuBarPrefix): \(baseTaskText)"
    if taskText.isEmpty {
      statusItem?.button?.attributedTitle = NSAttributedString(string: "…")
      statusItem?.button?.toolTip = nil
      statusItem?.length = NSStatusItem.variableLength
      statusItem?.button?.layer?.mask = nil
      return
    }

    let pStyle = NSMutableParagraphStyle()
    pStyle.lineBreakMode = .byClipping
    let menuBarFontSize = NSFont.menuBarFont(ofSize: 0).pointSize
    let font = BarTaskerTypography.taskNSFont(ofSize: menuBarFontSize)
    let horizontalPadding: CGFloat = 16
    let timerStr = checkvistManager.timerBarString
    let timerVisible = timerStr != nil

    let requestedMaxWidth: CGFloat = CGFloat(checkvistManager.maxTitleWidth)
    let maxWidth: CGFloat
    if let timerStr {
      let timerOnlyWidth = NSAttributedString(
        string: timerStr, attributes: [.font: font]
      ).size().width
      // Never allow settings width to hide an active timer.
      maxWidth = max(requestedMaxWidth, timerOnlyWidth + horizontalPadding)
    } else {
      maxWidth = requestedMaxWidth
    }

    let contentWidth = max(0, maxWidth - horizontalPadding)
    let titleInputs = TitleCacheInputs(
      taskText: taskText,
      timerText: timerStr,
      maxWidth: contentWidth,
      timerLeading: checkvistManager.timerBarLeading
    )
    let text: String
    if let cached = cachedTitleInputs, let cachedResult = cachedTitleResult,
      cached == titleInputs
    {
      text = cachedResult
    } else {
      text = fittedMenuTitle(
        taskText: taskText,
        timerStr: timerStr,
        maxContentWidth: contentWidth,
        font: font,
        timerLeading: checkvistManager.timerBarLeading
      )
      cachedTitleInputs = titleInputs
      cachedTitleResult = text
    }
    let displayText = text.isEmpty ? "…" : text

    let attrString = NSAttributedString(
      string: displayText, attributes: [.paragraphStyle: pStyle, .font: font])

    let textWidth = attrString.size().width
    let finalWidth = min(textWidth + horizontalPadding, maxWidth)

    statusItem?.length = finalWidth
    statusItem?.button?.attributedTitle = attrString
    statusItem?.button?.toolTip = nil
    statusItem?.button?.wantsLayer = true

    if timerVisible {
      // Timer text must remain legible; clipping is already handled on task text.
      statusItem?.button?.layer?.mask = nil
    } else if textWidth > finalWidth - 16 {
      // Reuse gradient layer if width hasn't changed.
      if cachedGradientWidth != finalWidth {
        let maskLayer = CAGradientLayer()
        maskLayer.frame = CGRect(x: 0, y: 0, width: finalWidth, height: 22)
        maskLayer.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        maskLayer.startPoint = CGPoint(x: 0.0, y: 0.5)
        maskLayer.endPoint = CGPoint(x: 1.0, y: 0.5)
        let fadeStart = (finalWidth - 24) / finalWidth
        maskLayer.locations = [0.0, NSNumber(value: fadeStart), 1.0]
        cachedGradientWidth = finalWidth
        cachedGradientLayer = maskLayer
      }
      statusItem?.button?.layer?.mask = cachedGradientLayer
    } else {
      statusItem?.button?.layer?.mask = nil
    }
  }

  private static let menuBarTagRegex: NSRegularExpression = {
    guard let regex = try? NSRegularExpression(pattern: "([@#][a-zA-Z0-9_\\-]+)") else {
      fatalError("Invalid regex pattern for menu bar tags.")
    }
    return regex
  }()

  private func menuBarDisplayTaskText(_ rawText: String) -> String {
    let range = NSRange(rawText.startIndex..., in: rawText)
    let withoutTags = Self.menuBarTagRegex.stringByReplacingMatches(
      in: rawText, range: range, withTemplate: "")
    let collapsedWhitespace = withoutTags.replacingOccurrences(
      of: "\\s+", with: " ", options: .regularExpression)
    return collapsedWhitespace.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func clippedMenuTitleTaskText(_ taskText: String, maxWidth: CGFloat, font: NSFont)
    -> String
  {
    func width(of text: String) -> CGFloat {
      NSAttributedString(string: text, attributes: [.font: font]).size().width
    }

    guard !taskText.isEmpty else { return "…" }
    guard maxWidth > 0 else { return String(taskText.prefix(1)) }

    if width(of: taskText) <= maxWidth { return taskText }
    let ellipsis = "…"
    if width(of: ellipsis) > maxWidth {
      // At very tight widths, keep at least one visible character.
      let chars = Array(taskText)
      var low = 1
      var high = chars.count
      var best = String(chars.prefix(1))
      while low <= high {
        let mid = (low + high) / 2
        let candidate = String(chars.prefix(mid))
        if width(of: candidate) <= maxWidth {
          best = candidate
          low = mid + 1
        } else {
          high = mid - 1
        }
      }
      return best
    }

    let chars = Array(taskText)
    var low = 0
    var high = chars.count
    var best = ellipsis

    while low <= high {
      let mid = (low + high) / 2
      let candidate = String(chars.prefix(mid)) + ellipsis
      if width(of: candidate) <= maxWidth {
        best = candidate
        low = mid + 1
      } else {
        high = mid - 1
      }
    }

    return best
  }

  private func fittedMenuTitle(
    taskText: String,
    timerStr: String?,
    maxContentWidth: CGFloat,
    font: NSFont,
    timerLeading: Bool
  ) -> String {
    func width(of text: String) -> CGFloat {
      NSAttributedString(string: text, attributes: [.font: font]).size().width
    }

    guard maxContentWidth > 0 else {
      if let timerStr, !timerStr.isEmpty { return String(timerStr.prefix(1)) }
      return String(taskText.prefix(1))
    }
    guard let timerStr, !timerStr.isEmpty else {
      return clippedMenuTitleTaskText(taskText, maxWidth: maxContentWidth, font: font)
    }

    if width(of: timerStr) > maxContentWidth {
      return clippedMenuTitleTaskText(timerStr, maxWidth: maxContentWidth, font: font)
    }

    let separator = " "
    let full =
      timerLeading ? "\(timerStr)\(separator)\(taskText)" : "\(taskText)\(separator)\(timerStr)"
    if width(of: full) <= maxContentWidth { return full }

    let chars = Array(taskText)
    let ellipsis = "…"
    var low = 0
    var high = chars.count
    var best: String = clippedMenuTitleTaskText(timerStr, maxWidth: maxContentWidth, font: font)

    while low <= high {
      let mid = (low + high) / 2
      let candidateTask: String
      if mid == chars.count {
        candidateTask = taskText
      } else if mid == 0 {
        candidateTask = ellipsis
      } else {
        candidateTask = String(chars.prefix(mid)) + ellipsis
      }

      let candidate =
        timerLeading
        ? "\(timerStr)\(separator)\(candidateTask)"
        : "\(candidateTask)\(separator)\(timerStr)"

      if width(of: candidate) <= maxContentWidth {
        best = candidate
        low = mid + 1
      } else {
        high = mid - 1
      }
    }

    return best
  }

  @MainActor func handleSupplementalKey(event: NSEvent) -> Bool {
    let router = KeyboardShortcutRouter(
      manager: checkvistManager,
      logger: logger,
      updateTitle: { [weak self] in self?.updateTitle() },
      closeWindow: { [weak self] in self?.closeWindow() }
    )
    return router.handle(event: event, popoverWindow: window)
  }

  // MARK: - Window

  private func makeWindowIfNeeded() -> BarTaskerPanel {
    if let existing = window as? BarTaskerPanel { return existing }

    let contentSize = currentPopoverContentSize
    let popoverWindow = BarTaskerPanel(
      contentRect: NSRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height),
      styleMask: [.nonactivatingPanel, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    // Ensure the window has no title bar and is transparent
    popoverWindow.titleVisibility = .hidden
    popoverWindow.titlebarAppearsTransparent = true
    popoverWindow.isOpaque = false
    popoverWindow.backgroundColor = .clear
    popoverWindow.hasShadow = true
    popoverWindow.level = .floating
    popoverWindow.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]

    let hostingController = NSHostingController(
      rootView: PopoverView()
        .font(BarTaskerTypography.interfaceFont)
        .environmentObject(checkvistManager))
    popoverWindow.contentViewController = hostingController

    popoverWindow.isMovableByWindowBackground = false
    window = popoverWindow

    // Monitor for clicks outside the window to dismiss it
    // Remove any prior click monitor before installing a new one.
    if let monitor = clickMonitor { NSEvent.removeMonitor(monitor) }
    clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
      [weak self] event in
      guard let self, let popoverWindow = self.window, popoverWindow.isVisible else { return }
      let clickLocation = event.locationInWindow
      // If the click is not inside our window bounds, close it
      if !popoverWindow.frame.contains(clickLocation) && event.window == nil {
        self.closeWindow()
      }
    }

    return popoverWindow
  }

  func closeWindow() {
    window?.orderOut(nil)
    if [.addSibling, .addChild, .quickAddDefault, .quickAddSpecific].contains(
      checkvistManager.quickEntryMode)
    {
      checkvistManager.quickEntryText = ""
      checkvistManager.quickEntryMode = .search
    }
    checkvistManager.isQuickEntryFocused = false
    updateTitle()  // Commit current selection as the menu bar title
  }

  @objc func clicked(_ sender: NSStatusBarButton) {
    if isSecondaryStatusItemClickEvent(NSApp.currentEvent) {
      showStatusItemContextMenu()
      return
    }
    togglePopover()
  }

  private func showStatusItemContextMenu() {
    let menu = NSMenu()
    menu.addItem(
      withTitle: "Preferences…",
      action: #selector(menuSettings),
      keyEquivalent: ""
    ).target = self
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "Quit Bar Tasker",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: ""
    )
    statusItem.menu = menu
    statusItem.button?.performClick(nil)
    statusItem.menu = nil
  }

  private func isSecondaryStatusItemClickEvent(_ event: NSEvent?) -> Bool {
    guard let event else { return false }
    if event.type == .rightMouseUp || event.type == .rightMouseDown {
      return true
    }
    // Treat Control-click as secondary click on macOS.
    return event.type == .leftMouseUp && event.modifierFlags.contains(.control)
  }

  @objc func menuSettings() {
    closeWindow()
    let window = makePreferencesWindowIfNeeded()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func makePreferencesWindowIfNeeded() -> NSWindow {
    if let preferencesWindow {
      return preferencesWindow
    }

    let navState = SettingsNavState()
    preferencesNavState = navState

    let rootView = SettingsView()
      .font(BarTaskerTypography.interfaceFont)
      .environmentObject(checkvistManager)
      .environmentObject(navState)
      .frame(minWidth: 720, idealWidth: 820, minHeight: 560, idealHeight: 660)
    let hostingController = NSHostingController(rootView: rootView)

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 820, height: 660),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "Preferences"
    window.titleVisibility = .hidden
    window.toolbarStyle = .preference
    let toolbar = NSToolbar(identifier: "BarTaskerPreferencesToolbar")
    toolbar.delegate = navState
    toolbar.displayMode = .iconAndLabel
    toolbar.allowsUserCustomization = false
    toolbar.selectedItemIdentifier = NSToolbarItem.Identifier(
      SettingsNavState.Pane.preferences.rawValue)
    navState.toolbar = toolbar
    window.toolbar = toolbar
    window.center()
    // Keep ARC ownership on our side; we explicitly nil `preferencesWindow` on close.
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    window.tabbingMode = .disallowed
    window.minSize = NSSize(width: 720, height: 560)
    window.maxSize = NSSize(width: 1200, height: 900)
    window.delegate = self
    window.contentViewController = hostingController
    window.setFrameAutosaveName("BarTaskerPreferencesWindowV2")
    preferencesWindow = window
    return window
  }

  func windowWillClose(_ notification: Notification) {
    guard let closingWindow = notification.object as? NSWindow else { return }
    if closingWindow === preferencesWindow {
      preferencesWindow = nil
      preferencesNavState = nil
    }
  }

  private func scheduleAutoRefresh() {
    let now = Date()
    guard
      AutoRefreshThrottlePolicy.shouldRefresh(
        needsInitialSetup: checkvistManager.needsInitialSetup,
        now: now,
        lastRefreshAt: lastAutoRefreshTime
      )
    else { return }
    lastAutoRefreshTime = now
    Task { [weak self] in
      await self?.checkvistManager.fetchTopTask()
      self?.updateTitle()
    }
  }

  @objc func menuQuit() {
    explicitQuitRequested = true
    NSApp.terminate(nil)
  }

  private func triggerQuickAddFromHotkey() {
    showPopoverWindow()
    _ = checkvistManager.beginQuickAddEntry()
    schedulePopoverResize()
  }

  private func showPopoverWindow() {
    let popoverWindow = makeWindowIfNeeded()
    guard let button = statusItem.button else { return }
    if popoverWindow.isVisible {
      popoverWindow.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    // Position the window directly below the status item, aligned to the right edge.
    let btnRect = button.convert(button.bounds, to: nil)
    guard let buttonWindow = button.window else { return }
    let screenRect = buttonWindow.convertToScreen(btnRect)
    let paddingY: CGFloat = 4
    let trX = screenRect.maxX + 10
    let trY = screenRect.minY - paddingY

    popoverWindow.setAnchoredTopRight(
      contentSize: currentPopoverContentSize, topRight: NSPoint(x: trX, y: trY), display: true)
    popoverWindow.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func togglePopover() {
    let now = Date()
    guard now.timeIntervalSince(lastToggleTime) > 0.2 else { return }
    lastToggleTime = now

    let popoverWindow = makeWindowIfNeeded()
    if popoverWindow.isVisible {
      closeWindow()
    } else {
      showPopoverWindow()
    }
  }

  private func updatePopoverSizeIfVisible() {
    guard let popoverWindow = window as? BarTaskerPanel, popoverWindow.isVisible else { return }
    let anchoredTopRight = NSPoint(x: popoverWindow.frame.maxX, y: popoverWindow.frame.maxY)
    popoverWindow.setAnchoredTopRight(
      contentSize: currentPopoverContentSize,
      topRight: anchoredTopRight,
      display: true
    )
  }

  private func schedulePopoverResize() {
    pendingPopoverResize?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      self?.updatePopoverSizeIfVisible()
    }
    pendingPopoverResize = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: workItem)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    switch AppTerminationPolicy.decision(explicitQuitRequested: explicitQuitRequested) {
    case .terminateNow:
      return .terminateNow
    case .cancel:
      break
    }
    // SwiftUI will try to gracefully terminate the app when the Settings view is closed
    // since we don't use MenuBarExtra. We must explicitly cancel this auto-termination.
    return .terminateCancel
  }

  func applicationWillTerminate(_ notification: Notification) {
    if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
    if let monitor = clickMonitor { NSEvent.removeMonitor(monitor) }
    pendingPopoverResize?.cancel()
    unregisterGlobalHotkeys()
  }
}
// swiftlint:enable type_body_length

class AnchorView: NSView {}

class BarTaskerPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  func setAnchoredTopRight(contentSize: NSSize, topRight: NSPoint, display: Bool) {
    let frameSize = frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
    let origin = NSPoint(x: topRight.x - frameSize.width, y: topRight.y - frameSize.height)
    super.setFrame(NSRect(origin: origin, size: frameSize), display: display)
  }
}
