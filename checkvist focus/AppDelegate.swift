import Carbon.HIToolbox
import Combine
import OSLog
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  static private(set) var shared: AppDelegate!

  override init() {
    super.init()
    Self.shared = self
  }

  lazy var checkvistManager: CheckvistManager = CheckvistManager()
  private var statusItem: NSStatusItem!
  private var window: NSWindow?
  private var preferencesWindow: NSWindow?
  private var keyMonitor: Any?
  private var clickMonitor: Any?
  private var globalHotkeyRef: EventHotKeyRef?
  private var cancellables = Set<AnyCancellable>()
  private var lastToggleTime: Date = Date.distantPast
  private var pendingPopoverResize: DispatchWorkItem?
  private var explicitQuitRequested = false
  private var lastAutoRefreshTime: Date = Date.distantPast
  private let logger = Logger(subsystem: "uk.co.maybeitsadam.checkvist-focus", category: "keyboard")

  private var currentPopoverContentSize: NSSize {
    NSSize(
      width: PopoverLayout.width,
      height: PopoverLayout.preferredHeight(for: checkvistManager)
    )
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.title = "…"
    statusItem.button?.action = #selector(clicked)
    statusItem.button?.target = self
    statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

    // Title sync
    checkvistManager.objectWillChange
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        DispatchQueue.main.async {
          self?.updateTitle()
          self?.schedulePopoverResize()
        }
      }
      .store(in: &cancellables)

    // Install shared Carbon event handler for hotkeys once
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, _, _ -> OSStatus in
        Task { @MainActor in
          AppDelegate.shared.togglePopover()
        }
        return noErr
      }, 1, &eventType, nil, nil)

    // Global key monitor for shortcuts not handled by onKeyPress (j/k, hf, Ctrl+↑↓)
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, let w = self.window, w.isVisible else { return event }
      guard event.window === w else { return event }
      return self.handleSupplementalKey(event: event) ? nil : event
    }

    // Register global hotkey if enabled
    if checkvistManager.globalHotkeyEnabled {
      registerGlobalHotkey()
    }
    checkvistManager.$globalHotkeyEnabled
      .dropFirst()
      .receive(on: RunLoop.main)
      .sink { [weak self] enabled in
        if enabled { self?.registerGlobalHotkey() } else { self?.unregisterGlobalHotkey() }
      }
      .store(in: &cancellables)

    // Re-register when hotkey key/modifiers change
    checkvistManager.$globalHotkeyKeyCode
      .dropFirst().receive(on: RunLoop.main)
      .sink { [weak self] _ in
        guard let self, self.checkvistManager.globalHotkeyEnabled else { return }
        self.registerGlobalHotkey()
      }
      .store(in: &cancellables)
    checkvistManager.$globalHotkeyModifiers
      .dropFirst().receive(on: RunLoop.main)
      .sink { [weak self] _ in
        guard let self, self.checkvistManager.globalHotkeyEnabled else { return }
        self.registerGlobalHotkey()
      }
      .store(in: &cancellables)

    checkvistManager.$maxTitleWidth
      .dropFirst().receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.updateTitle()
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
      if self.checkvistManager.needsInitialSetup {
        self.togglePopover()
      } else {
        await self.checkvistManager.fetchTopTask()
        self.updateTitle()
      }
    }
  }

  // MARK: - Global Hotkey (⌥Space by default)

  private func registerGlobalHotkey() {
    unregisterGlobalHotkey()

    let hotKeyID = EventHotKeyID(
      signature: OSType(0x4356_464B),  // "CVFK"
      id: 1)
    var ref: EventHotKeyRef?
    let keyCode = UInt32(checkvistManager.globalHotkeyKeyCode)
    let modifiers = UInt32(checkvistManager.globalHotkeyModifiers)
    let status = RegisterEventHotKey(
      keyCode, modifiers, hotKeyID,
      GetApplicationEventTarget(), 0, &ref)
    if status == noErr { globalHotkeyRef = ref }
  }

  private func unregisterGlobalHotkey() {
    if let ref = globalHotkeyRef {
      UnregisterEventHotKey(ref)
      globalHotkeyRef = nil
    }
  }

  func updateTitle() {
    DispatchQueue.main.async {
      let rawTaskText = self.checkvistManager.currentTaskText
      let baseTaskText = self.menuBarDisplayTaskText(rawTaskText)
      let taskText =
        self.checkvistManager.pendingSyncMenuBarPrefix.isEmpty
        ? baseTaskText
        : "\(self.checkvistManager.pendingSyncMenuBarPrefix): \(baseTaskText)"
      if taskText.isEmpty {
        self.statusItem?.button?.attributedTitle = NSAttributedString(string: "…")
        self.statusItem?.button?.toolTip = nil
        self.statusItem?.length = NSStatusItem.variableLength
        self.statusItem?.button?.layer?.mask = nil
        return
      }

      let pStyle = NSMutableParagraphStyle()
      pStyle.lineBreakMode = .byClipping
      let font = NSFont.menuBarFont(ofSize: 0)
      let horizontalPadding: CGFloat = 16
      let timerStr = self.checkvistManager.timerBarString
      let timerVisible = timerStr != nil

      let requestedMaxWidth: CGFloat = CGFloat(self.checkvistManager.maxTitleWidth)
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
      let text = self.fittedMenuTitle(
        taskText: taskText,
        timerStr: timerStr,
        maxContentWidth: contentWidth,
        font: font,
        timerLeading: self.checkvistManager.timerBarLeading
      )
      let displayText = text.isEmpty ? "…" : text

      let attrString = NSAttributedString(
        string: displayText, attributes: [.paragraphStyle: pStyle, .font: font])

      let textWidth = attrString.size().width
      let finalWidth = min(textWidth + horizontalPadding, maxWidth)

      self.statusItem?.length = finalWidth
      self.statusItem?.button?.attributedTitle = attrString
      self.statusItem?.button?.toolTip = nil
      self.statusItem?.button?.wantsLayer = true

      if timerVisible {
        // Timer text must remain legible; clipping is already handled on task text.
        self.statusItem?.button?.layer?.mask = nil
      } else if textWidth > finalWidth - 16 {
        let maskLayer = CAGradientLayer()
        maskLayer.frame = CGRect(x: 0, y: 0, width: finalWidth, height: 22)
        maskLayer.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        maskLayer.startPoint = CGPoint(x: 0.0, y: 0.5)
        maskLayer.endPoint = CGPoint(x: 1.0, y: 0.5)
        let fadeStart = (finalWidth - 24) / finalWidth
        maskLayer.locations = [0.0, NSNumber(value: fadeStart), 1.0]
        self.statusItem?.button?.layer?.mask = maskLayer
      } else {
        self.statusItem?.button?.layer?.mask = nil
      }
    }
  }

  private func menuBarDisplayTaskText(_ rawText: String) -> String {
    let pattern = "([@#][a-zA-Z0-9_\\-]+)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let range = NSRange(rawText.startIndex..., in: rawText)
    let withoutTags = regex.stringByReplacingMatches(in: rawText, range: range, withTemplate: "")
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

  private func makeWindowIfNeeded() -> FocusPanel {
    if let existing = window as? FocusPanel { return existing }

    let contentSize = currentPopoverContentSize
    let w = FocusPanel(
      contentRect: NSRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height),
      styleMask: [.nonactivatingPanel, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    // Ensure the window has no title bar and is transparent
    w.titleVisibility = .hidden
    w.titlebarAppearsTransparent = true
    w.isOpaque = false
    w.backgroundColor = .clear
    w.hasShadow = true
    w.level = .floating
    w.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]

    let hostingController = NSHostingController(
      rootView: PopoverView().environmentObject(checkvistManager))
    w.contentViewController = hostingController

    w.isMovableByWindowBackground = false
    window = w

    // Monitor for clicks outside the window to dismiss it
    clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
      [weak self] event in
      guard let self, let w = self.window, w.isVisible else { return }
      let clickLocation = event.locationInWindow
      // If the click is not inside our window bounds, close it
      if !w.frame.contains(clickLocation) && event.window == nil {
        self.closeWindow()
      }
    }

    return w
  }

  func closeWindow() {
    window?.orderOut(nil)
    if [.addSibling, .addChild].contains(checkvistManager.quickEntryMode) {
      checkvistManager.filterText = ""
      checkvistManager.quickEntryMode = .search
    }
    checkvistManager.isQuickEntryFocused = false
    updateTitle()  // Commit current selection as the menu bar title
  }

  @objc func clicked(_ sender: NSStatusBarButton) {
    guard let event = NSApp.currentEvent else { return }
    if event.type == .rightMouseUp {
      let menu = NSMenu()
      menu.addItem(withTitle: "Refresh", action: #selector(menuRefresh), keyEquivalent: "")
      let obsidianItem = NSMenuItem(
        title: "Open in Obsidian",
        action: #selector(menuSyncToObsidian),
        keyEquivalent: "O")
      obsidianItem.keyEquivalentModifierMask = [.command, .shift]
      menu.addItem(obsidianItem)
      let settingsItem = NSMenuItem(
        title: "Preferences...", action: #selector(menuSettings), keyEquivalent: ",")
      settingsItem.keyEquivalentModifierMask = [.command]
      menu.addItem(settingsItem)
      menu.addItem(.separator())
      menu.addItem(withTitle: "Quit", action: #selector(menuQuit), keyEquivalent: "q")

      // Allow menu items to trigger actions on self
      for item in menu.items { item.target = self }

      statusItem.menu = menu
      statusItem.button?.performClick(nil)
      statusItem.menu = nil
    } else {
      togglePopover()
    }
  }

  @objc func menuRefresh() {
    Task { [weak self] in
      await self?.checkvistManager.fetchTopTask()
      self?.updateTitle()
    }
  }

  @objc func menuSyncToObsidian() {
    Task { [weak self] in
      await self?.checkvistManager.syncCurrentTaskToObsidian()
      self?.updateTitle()
    }
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

    let rootView = SettingsView()
      .environmentObject(checkvistManager)
      .frame(minWidth: 560, idealWidth: 620, minHeight: 520, idealHeight: 620)
    let hostingController = NSHostingController(rootView: rootView)

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 620, height: 620),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "Preferences"
    window.center()
    // Keep ARC ownership on our side; we explicitly nil `preferencesWindow` on close.
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    window.tabbingMode = .disallowed
    window.delegate = self
    window.contentViewController = hostingController
    window.setFrameAutosaveName("CheckvistFocusPreferencesWindow")
    preferencesWindow = window
    return window
  }

  func windowWillClose(_ notification: Notification) {
    guard let closingWindow = notification.object as? NSWindow else { return }
    if closingWindow === preferencesWindow {
      preferencesWindow = nil
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

  func togglePopover() {
    let now = Date()
    guard now.timeIntervalSince(lastToggleTime) > 0.2 else { return }
    lastToggleTime = now

    let w = makeWindowIfNeeded()
    if w.isVisible {
      closeWindow()
    } else if let button = statusItem.button {
      // Position the window directly below the button, aligned to its right edge
      let btnRect = button.convert(button.bounds, to: nil)  // To window coords
      guard let buttonWindow = button.window else { return }
      let screenRect = buttonWindow.convertToScreen(btnRect)  // To screen coords

      let paddingY: CGFloat = 4  // Small gap below menu bar
      let trX = screenRect.maxX + 10  // Align right edges (slightly inset for aesthetics)
      let trY = screenRect.minY - paddingY

      w.setAnchoredTopRight(
        contentSize: currentPopoverContentSize, topRight: NSPoint(x: trX, y: trY), display: true)

      w.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  private func updatePopoverSizeIfVisible() {
    guard let w = window as? FocusPanel, w.isVisible else { return }
    let anchoredTopRight = NSPoint(x: w.frame.maxX, y: w.frame.maxY)
    w.setAnchoredTopRight(
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
    if let m = keyMonitor { NSEvent.removeMonitor(m) }
    if let m = clickMonitor { NSEvent.removeMonitor(m) }
    pendingPopoverResize?.cancel()
    unregisterGlobalHotkey()
  }
}

class AnchorView: NSView {}

class FocusPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  func setAnchoredTopRight(contentSize: NSSize, topRight: NSPoint, display: Bool) {
    let frameSize = frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
    let origin = NSPoint(x: topRight.x - frameSize.width, y: topRight.y - frameSize.height)
    super.setFrame(NSRect(origin: origin, size: frameSize), display: display)
  }
}
