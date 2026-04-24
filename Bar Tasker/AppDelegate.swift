import AppKit
import Combine
import OSLog
import Observation
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
  private let logger = Logger(subsystem: "uk.co.maybeitsadam.bar-tasker", category: "appdelegate")

  #if DEBUG
    private var isRunningFromXcode: Bool {
      let env = ProcessInfo.processInfo.environment
      return env["XCODE_VERSION_ACTUAL"] != nil || env["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil
    }
  #endif

  func applicationDidFinishLaunching(_ notification: Notification) {
    if MCPServer.isLaunchMode(arguments: ProcessInfo.processInfo.arguments) {
      launchMCPServerMode()
      return
    }

    NSApp.setActivationPolicy(.accessory)
    applyAppTheme()

    menuBarController = MenuBarController(manager: checkvistManager)
    menuBarController.onShowSettings = { [weak self] in
      self?.menuSettings()
    }
    menuBarController.onQuit = { [weak self] in
      self?.menuQuit()
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
      await self.checkvistManager.fetchTopTask()
      self.menuBarController.updateTitle()
    }
  }

  private func launchMCPServerMode() {
    NSApp.setActivationPolicy(.prohibited)
    Task.detached(priority: .userInitiated) {
      await MCPServer().run()
      await MainActor.run {
        NSApp.terminate(nil)
      }
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
      self?.menuBarController.updateTitle()
    }
  }

  func menuQuit() {
    explicitQuitRequested = true
    NSApp.terminate(nil)
  }

  private func triggerQuickAddFromHotkey() {
    menuBarController.showPopoverWindow()
    _ = checkvistManager.beginQuickAddEntry()
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
    shortcutManager.unregisterGlobalHotkeys()
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
