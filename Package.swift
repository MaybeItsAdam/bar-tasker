// swift-tools-version: 6.0
import PackageDescription

let pluginTargetExcludes = [
  // Top-level non-source artefacts
  "ARCHITECTURE_IMPROVEMENT_PLAN.md",
  "Bar Tasker.xcodeproj",
  "DerivedData",
  "FocusCore",
  "README.md",
  "TODO.md",
  "build",
  "corelogic-tests",
  "docs",
  "extract.py",
  "extract_intent_handler.py",
  "fix_fetch.py",
  "fix_init.py",
  "fix_mutations.py",
  "fix_offline.py",
  "fix_task_sync.py",
  "plugin-tests",
  "rename_bartasker.py",
  "rewrite_scoping.py",
  "scripts",

  // App resources and the core target's own source tree
  "Bar Tasker/Assets.xcassets",
  "Bar Tasker/Bar Tasker.entitlements",
  "Bar Tasker/Bar Tasker.release.entitlements",
  "Bar Tasker/CoreLogic",

  // App-level source folders not needed by the plugins library
  "Bar Tasker/Managers",
  "Bar Tasker/Models",

  // App-level source files at Bar Tasker/ root
  "Bar Tasker/AppCoordinator+Navigation.swift",
  "Bar Tasker/AppCoordinator+QuickAdd.swift",
  "Bar Tasker/AppCoordinator+ReorderingAndTiming.swift",
  "Bar Tasker/AppCoordinator+StateAndLifecycle.swift",
  "Bar Tasker/AppCoordinator+TaskMutations.swift",
  "Bar Tasker/AppCoordinator+TaskScoping.swift",
  "Bar Tasker/AppCoordinator+TaskSync.swift",
  "Bar Tasker/AppCoordinator+Undo.swift",
  "Bar Tasker/AppCoordinator.swift",
  "Bar Tasker/AppDelegate.swift",
  "Bar Tasker/AppThemeColorSupport.swift",
  "Bar Tasker/CacheState.swift",
  "Bar Tasker/CommandExecutor.swift",
  "Bar Tasker/KanbanBoardView.swift",
  "Bar Tasker/KanbanColumn.swift",
  "Bar Tasker/KanbanSettingsView.swift",
  "Bar Tasker/KeyboardShortcutRouter.swift",
  "Bar Tasker/ListScopedPriorityStore.swift",
  "Bar Tasker/ListScopedTaskIDStore.swift",
  "Bar Tasker/LocalTaskStore.swift",
  "Bar Tasker/MainApp.swift",
  "Bar Tasker/NetworkReachabilityMonitor.swift",
  "Bar Tasker/PopoverView.swift",
  "Bar Tasker/PreferencesStore.swift",
  "Bar Tasker/RecurrenceRule.swift",
  "Bar Tasker/ReorderQueue.swift",
  "Bar Tasker/SettingsNavState.swift",
  "Bar Tasker/SettingsView.swift",
  "Bar Tasker/TaskNavigationCoordinator.swift",
  "Bar Tasker/TaskVisibilityEngine.swift",
  "Bar Tasker/Typography.swift",

  // Plugin subtrees / files that are app-only or conflict with PluginModelStubs
  "Bar Tasker/Plugins/MCP",
  "Bar Tasker/Plugins/Registry",
  "Bar Tasker/Plugins/Settings",
  "Bar Tasker/Plugins/Native/OfflineTaskSyncPlugin.swift",
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
        "Bar Tasker/Plugins/Protocols/PluginProtocols.swift",
        "Bar Tasker/Plugins/Native/Checkvist/NativeCheckvistSyncPlugin.swift",
        "Bar Tasker/Plugins/Native/Checkvist/CheckvistCredentialStore.swift",
        "Bar Tasker/Plugins/Native/Checkvist/CheckvistEndpoints.swift",
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
