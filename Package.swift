// swift-tools-version: 6.0
import PackageDescription

let pluginTargetExcludes = [
  "Bar Tasker/Assets.xcassets",
  "Bar Tasker/Bar Tasker.entitlements",
  "Bar Tasker/Bar Tasker.release.entitlements",
  "Bar Tasker/CoreLogic",
  "Bar Tasker/AppDelegate.swift",
  "Bar Tasker/BarTaskerApp.swift",
  "Bar Tasker/BarTaskerCacheState.swift",
  "Bar Tasker/BarTaskerCommandExecutor.swift",
  "Bar Tasker/BarTaskerCoordinator.swift",
  "Bar Tasker/BarTaskerCoordinator+Navigation.swift",
  "Bar Tasker/BarTaskerCoordinator+OfflineState.swift",
  "Bar Tasker/BarTaskerCoordinator+QuickAdd.swift",
  "Bar Tasker/BarTaskerCoordinator+ReorderingAndTiming.swift",
  "Bar Tasker/BarTaskerCoordinator+StateAndLifecycle.swift",
  "Bar Tasker/BarTaskerCoordinator+TaskMutations.swift",
  "Bar Tasker/BarTaskerCoordinator+TaskScoping.swift",
  "Bar Tasker/BarTaskerCoordinator+TaskSync.swift",
  "Bar Tasker/BarTaskerCoordinator+Types.swift",
  "Bar Tasker/Models",
  "Bar Tasker/BarTaskerCoordinator+Undo.swift",
  "Bar Tasker/BarTaskerPreferencesStore.swift",
  "Bar Tasker/BarTaskerReorderQueue.swift",
  "Bar Tasker/BarTaskerTaskVisibilityEngine.swift",
  "Bar Tasker/BarTaskerTheme.swift",
  "Bar Tasker/BarTaskerTypography.swift",
  "Bar Tasker/KeyboardShortcutRouter.swift",
  "Bar Tasker/ListScopedTaskIDStore.swift",
  "Bar Tasker/LocalTaskStore.swift",
  "Bar Tasker/NetworkReachabilityMonitor.swift",
  "Bar Tasker/Plugins/MCP/BarTaskerMCPServer.swift",
  "Bar Tasker/Plugins/Native/Checkvist/CheckvistAPIClient.swift",
  "Bar Tasker/Plugins/Native/Checkvist/CheckvistModels.swift",
  "Bar Tasker/Plugins/Native/Checkvist/CheckvistSession.swift",
  "Bar Tasker/Plugins/Native/Checkvist/CheckvistTaskRepository.swift",
  "Bar Tasker/Plugins/Native/Checkvist/NativeCheckvistSyncPlugin+Settings.swift",
  "Bar Tasker/Plugins/Native/GoogleCalendar/GoogleOAuthLoopbackReceiver.swift",
  "Bar Tasker/Plugins/Native/GoogleCalendar/NativeGoogleCalendarIntegrationPlugin+Settings.swift",
  "Bar Tasker/Plugins/Native/MCP/NativeMCPIntegrationPlugin+Settings.swift",
  "Bar Tasker/Plugins/Native/Obsidian/NativeObsidianIntegrationPlugin+Settings.swift",
  "Bar Tasker/Plugins/Native/Obsidian/ObsidianSyncService.swift",
  "Bar Tasker/Plugins/Protocols/PluginSettingsPageProviding.swift",
  "Bar Tasker/Plugins/Registry/BarTaskerPluginRegistry.swift",
  "Bar Tasker/PopoverView.swift",
  "Bar Tasker/SettingsNavState.swift",
  "Bar Tasker/SettingsView.swift",
  "Bar Tasker/TaskNavigationCoordinator.swift",
  "Bar Tasker.xcodeproj",
  "README.md",
  "TODO.md",
  "build",
  "DerivedData",
  "corelogic-tests",
  "docs",
  "plugin-tests",
  "scripts",
]

let package = Package(
  name: "bar-tasker-core",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "BarTaskerCore", targets: ["BarTaskerCore"]),
    .library(name: "BarTaskerPlugins", targets: ["BarTaskerPlugins"]),
  ],
  targets: [
    .target(
      name: "BarTaskerCore",
      path: "Bar Tasker/CoreLogic"
    ),
    .target(
      name: "BarTaskerPlugins",
      path: ".",
      exclude: pluginTargetExcludes,
      sources: [
        "Bar Tasker/Plugins/Protocols/BarTaskerPluginProtocols.swift",
        "Bar Tasker/Plugins/Native/Checkvist/NativeCheckvistSyncPlugin.swift",
        "Bar Tasker/Plugins/Native/Checkvist/CheckvistCredentialStore.swift",
        "Bar Tasker/Plugins/Native/Obsidian/NativeObsidianIntegrationPlugin.swift",
        "Bar Tasker/Plugins/Native/GoogleCalendar/NativeGoogleCalendarIntegrationPlugin.swift",
        "Bar Tasker/Plugins/Native/GoogleCalendar/GoogleCalendarOAuthTokenStore.swift",
        "Bar Tasker/Plugins/Native/MCP/NativeMCPIntegrationPlugin.swift",
        "Bar Tasker/Plugins/User/UserPluginManager.swift",
        "Bar Tasker/Plugins/User/UserPluginManifest.swift",
        "plugin-tests-support/PluginModelStubs.swift",
      ]
    ),
    .testTarget(
      name: "BarTaskerCoreTests",
      dependencies: ["BarTaskerCore"],
      path: "corelogic-tests"
    ),
    .testTarget(
      name: "BarTaskerPluginTests",
      dependencies: ["BarTaskerPlugins"],
      path: "plugin-tests"
    ),
  ]
)
