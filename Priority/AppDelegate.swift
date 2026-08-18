import AppKit
import Combine
import OSLog
import Observation
import PriorityCore
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

  static private(set) var shared: AppDelegate!

  override init() {
    super.init()
    Self.shared = self
  }

  private let pluginRegistry = PluginRegistry.nativeFirst()
  lazy var checkvistManager: AppCoordinator = AppCoordinator(
    pluginRegistry: pluginRegistry)

  private(set) var menuBarController: MenuBarController!
  private(set) var shortcutManager: GlobalShortcutManager!

  private var preferencesWindow: NSWindow?
  private var preferencesNavState: SettingsNavState?
  private var cancellables = Set<AnyCancellable>()
  private var explicitQuitRequested = false
  private var lastAutoRefreshTime: Date = Date.distantPast
  private let logger = Logger(subsystem: "uk.co.maybeitsadam.priority", category: "appdelegate")

  #if DEBUG
    private var isRunningFromXcode: Bool {
      let env = ProcessInfo.processInfo.environment
      return env["XCODE_VERSION_ACTUAL"] != nil || env["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil
    }
  #endif

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Before anything reads preferences or the day log — including the MCP
    // server, which reads both and would otherwise answer from an empty store
    // for any client that launched it before the app had ever been opened.
    LegacyNameMigration.runIfNeeded()

    NSApp.setActivationPolicy(.accessory)
    applyAppTheme()

    menuBarController = MenuBarController(manager: checkvistManager)
    menuBarController.onShowSettings = { [weak self] in
      self?.menuSettings()
    }
    menuBarController.onQuit = { [weak self] in
      self?.menuQuit()
    }

    checkvistManager.focusSessionManager.onAlert = { [weak self] in
      guard let self else { return }
      self.menuBarController.showPopoverWindow()
      if let sound = NSSound(named: NSSound.Name("Glass")) {
        sound.play()
      } else {
        NSSound.beep()
      }
    }

    shortcutManager = GlobalShortcutManager(manager: checkvistManager)
    shortcutManager.onTogglePopover = { [weak self] in
      self?.menuBarController.togglePopover()
    }
    shortcutManager.onQuickAdd = { [weak self] in
      self?.triggerQuickAddFromHotkey()
    }

    observeForAppThemeChanges()

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
          self.menuBarController.showPopoverWindow()
        }
      #endif
      await self.checkvistManager.syncService.fetchTopTask()
      self.menuBarController.updateTitle()
    }
  }

  private func applyAppTheme() {
    switch checkvistManager.preferences.appTheme {
    case .system:
      NSApp.appearance = nil
    case .light:
      NSApp.appearance = NSAppearance(named: .aqua)
    case .dark:
      NSApp.appearance = NSAppearance(named: .darkAqua)
    }
  }

  func menuSettings() {
    menuSettings(pane: nil)
  }

  func menuSettings(pane: SettingsNavState.Pane?) {
    menuBarController.closeWindow()
    let window = makePreferencesWindowIfNeeded()
    if let pane {
      preferencesNavState?.select(pane: pane)
    }
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
      .font(Typography.interfaceFont)
      .environment(checkvistManager)
      .environment(navState)
      .frame(minWidth: 720, idealWidth: 820, minHeight: 560, idealHeight: 660)
    let hostingController = NSHostingController(rootView: rootView)

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 820, height: 660),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Preferences"
    window.titleVisibility = .hidden
    window.toolbarStyle = .preference
    let toolbar = NSToolbar(identifier: "PriorityPreferencesToolbar")
    toolbar.delegate = navState
    toolbar.displayMode = .iconAndLabel
    toolbar.allowsUserCustomization = false
    toolbar.selectedItemIdentifier = NSToolbarItem.Identifier(
      SettingsNavState.Pane.preferences.rawValue)
    navState.toolbar = toolbar
    window.toolbar = toolbar
    window.center()
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    window.tabbingMode = .disallowed
    window.delegate = self
    window.contentViewController = hostingController
    window.setFrameAutosaveName("PriorityPreferencesWindowV2")
    Self.enforceMinimumContentSize(of: window)
    preferencesWindow = window
    return window
  }

  /// Minimum *content* size the settings root asks for, matching the
  /// `.frame(minWidth:minHeight:)` on `SettingsView` above.
  private static let preferencesMinContentSize = NSSize(width: 720, height: 560)
  private static let preferencesMaxContentSize = NSSize(width: 1200, height: 900)

  /// Converts the SwiftUI root's minimum *content* size into the window's
  /// `minSize`, which is a *frame* measurement, and grows the window if the
  /// autosaved frame came back smaller than that.
  ///
  /// These are two different quantities and the old code conflated them: it set
  /// `minSize` to 720x560 — the content minimum — while the frame also carries a
  /// 28pt titlebar and a 52pt preference-style toolbar. Worse, `minSize` does
  /// nothing on a window without `.resizable` in its mask, so nothing enforced
  /// it at all. A restored frame of 720x612 left only 532pt of content for a
  /// view that cannot shrink below 560, and SwiftUI simply overflowed and
  /// clipped — which is what cut the plugin sidebar's button bar off the bottom.
  private static func enforceMinimumContentSize(of window: NSWindow) {
    // Measured rather than hardcoded: the toolbar style, and therefore the
    // chrome height, is not ours to predict across OS versions.
    let chrome = window.frame.height - window.contentLayoutRect.height
    guard chrome >= 0 else { return }

    window.minSize = NSSize(
      width: preferencesMinContentSize.width,
      height: preferencesMinContentSize.height + chrome
    )
    window.maxSize = NSSize(
      width: preferencesMaxContentSize.width,
      height: preferencesMaxContentSize.height + chrome
    )

    var frame = window.frame
    frame.size.width = max(frame.width, window.minSize.width)
    frame.size.height = max(frame.height, window.minSize.height)
    if frame.size != window.frame.size {
      // Keep the top-left pin so the window grows downward rather than
      // appearing to jump when a stale small frame is corrected.
      frame.origin.y = window.frame.maxY - frame.height
      window.setFrame(frame, display: false)
    }
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
      await self?.checkvistManager.syncService.fetchTopTask()
      self?.menuBarController.updateTitle()
    }
  }

  func menuQuit() {
    explicitQuitRequested = true
    NSApp.terminate(nil)
  }

  private func triggerQuickAddFromHotkey() {
    menuBarController.showPopoverWindow()
    _ = checkvistManager.taskMutationService.beginQuickAddEntry()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    switch AppTerminationPolicy.decision(explicitQuitRequested: explicitQuitRequested) {
    case .terminateNow:
      return .terminateNow
    case .cancel:
      break
    }
    return .terminateCancel
  }

  func applicationWillTerminate(_ notification: Notification) {
    // Optional because termination can arrive before the manager is built —
    // reaching through an implicitly-unwrapped optional here used to crash the
    // MCP server on shutdown, back when `--mcp-server` ran inside this app.
    shortcutManager?.unregisterGlobalHotkeys()
  }

  private func observeForAppThemeChanges() {
    withObservationTracking {
      _ = self.checkvistManager.preferences.appTheme
    } onChange: {
      Task { @MainActor [weak self] in
        self?.applyAppTheme()
        self?.observeForAppThemeChanges()
      }
    }
  }
}
