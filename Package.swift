// swift-tools-version: 6.0
import PackageDescription

let pluginTargetExcludes = [
  // Top-level non-source artefacts
  "ARCHITECTURE_IMPROVEMENT_PLAN.md",
  "Bar Tasker.xcodeproj",
  "CLAUDE.md",
  "DerivedData",
  "FocusCore",
  "README.md",
  "applogic-support",
  "applogic-tests",
  "build",
  "corelogic-tests",
  "docs",
  "plugin-tests",
  "scripts",

  // App resources and the core target's own source tree
  "Bar Tasker/Assets.xcassets",
  "Bar Tasker/Bar Tasker.entitlements",
  "Bar Tasker/Bar Tasker.release.entitlements",
  "Bar Tasker/CoreLogic",
  "Bar Tasker/FocusSessionView.swift",

  // App-level source folders not needed by the plugins library
  "Bar Tasker/Managers",
  "Bar Tasker/Models",

  // App-level source files at Bar Tasker/ root
  "Bar Tasker/AppCoordinator.swift",
  "Bar Tasker/AppDelegate.swift",
  "Bar Tasker/AppThemeColorSupport.swift",
  "Bar Tasker/CacheInvalidationBus.swift",
  "Bar Tasker/CacheState.swift",
  "Bar Tasker/CommandExecutor.swift",
  "Bar Tasker/EisenhowerMatrixView.swift",
  "Bar Tasker/IntegrationDataSourceAdapter.swift",
  "Bar Tasker/KanbanBoardView.swift",
  "Bar Tasker/KanbanColumn.swift",
  "Bar Tasker/KanbanSettingsView.swift",
  "Bar Tasker/KanbanTaskDataSourceAdapter.swift",
  "Bar Tasker/KeyboardShortcutRouter.swift",
  "Bar Tasker/LifecycleController.swift",
  "Bar Tasker/ListScopedPriorityStore.swift",
  "Bar Tasker/ListScopedEisenhowerStore.swift",
  "Bar Tasker/ListScopedTaskIDStore.swift",
  "Bar Tasker/LocalTaskStore.swift",
  "Bar Tasker/MainApp.swift",
  "Bar Tasker/NetworkReachabilityMonitor.swift",
  "Bar Tasker/OnboardingService.swift",
  "Bar Tasker/PopoverView.swift",
  "Bar Tasker/PopoverView+QuickEntryBar.swift",
  "Bar Tasker/PopoverView+TaskRow.swift",
  "Bar Tasker/PreferencesStore.swift",
  "Bar Tasker/RecurrenceRule.swift",
  "Bar Tasker/ReorderQueue.swift",
  "Bar Tasker/SettingsNavState.swift",
  "Bar Tasker/SettingsView.swift",
  "Bar Tasker/SettingsView+DebugPane.swift",
  "Bar Tasker/SettingsView+KeybindingsPane.swift",
  "Bar Tasker/SettingsView+PreferencesPane.swift",
  "Bar Tasker/SettingsView+ThemePane.swift",
  "Bar Tasker/SyncService.swift",
  "Bar Tasker/TaskMutationService.swift",
  "Bar Tasker/TaskNavigationCoordinator.swift",
  "Bar Tasker/TaskTreeFormatter.swift",
  "Bar Tasker/TaskNavigationService.swift",
  "Bar Tasker/TaskVisibilityEngine.swift",
  "Bar Tasker/Typography.swift",
  "Bar Tasker/UndoService.swift",

  // Plugin subtrees / files that are app-only or conflict with PluginModelStubs
  "Bar Tasker/Plugins/MCP",
  "Bar Tasker/Plugins/Registry",
  "Bar Tasker/Plugins/Settings",
  "Bar Tasker/Plugins/Native/OfflineTaskSyncPlugin.swift",
  "Bar Tasker/Plugins/Native/Checkvist/CheckvistAPIClient.swift",
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

// Anything that is *not* an AppLogic source. Mirrors `pluginTargetExcludes` but
// keeps `Bar Tasker/Managers/TaskRepository.swift`, the priority/queue stores,
// `OfflineTaskSyncPlugin.swift`, etc. unblocked so SPM can pick them up.
let appLogicTargetExcludes = [
  // Top-level non-source artefacts (same set as pluginTargetExcludes; this
  // isn't shared because exclude entries are path-based and we'd risk drift).
  "ARCHITECTURE_IMPROVEMENT_PLAN.md",
  "Bar Tasker.xcodeproj",
  "CLAUDE.md",
  "DerivedData",
  "FocusCore",
  "README.md",
  "applogic-tests",
  "build",
  "corelogic-tests",
  "docs",
  "plugin-tests",
  "plugin-tests-support",
  "scripts",

  // App resources and other targets' source trees.
  "Bar Tasker/Assets.xcassets",
  "Bar Tasker/Bar Tasker.entitlements",
  "Bar Tasker/Bar Tasker.release.entitlements",
  "Bar Tasker/CoreLogic",
  "Bar Tasker/FocusSessionView.swift",

  // Bar Tasker/Managers — AppLogic only wants TaskRepository.swift from here;
  // the rest of the directory pulls in AppKit/SwiftUI and is excluded file-by-file.
  "Bar Tasker/Managers/FocusSessionManager.swift",
  "Bar Tasker/Managers/GlobalShortcutManager.swift",
  "Bar Tasker/Managers/IntegrationCoordinator.swift",
  "Bar Tasker/Managers/KanbanManager.swift",
  "Bar Tasker/Managers/MenuBarController.swift",
  "Bar Tasker/Managers/NavigationState.swift",
  "Bar Tasker/Managers/PreferencesManager.swift",
  "Bar Tasker/Managers/QuickEntryManager.swift",
  "Bar Tasker/Managers/RecurrenceManager.swift",
  "Bar Tasker/Managers/StartDateManager.swift",
  "Bar Tasker/Managers/TaskFilterEngine.swift",
  "Bar Tasker/Managers/TaskListViewModel.swift",
  "Bar Tasker/Managers/TimerManager.swift",

  // Models — AppLogic only wants UndoableAction.swift and CheckvistConnectionState.swift;
  // the rest are app-only enums.
  "Bar Tasker/Models/AppThemeModels.swift",
  "Bar Tasker/Models/CommandSuggestion.swift",
  "Bar Tasker/Models/ConfigurableShortcutAction.swift",
  "Bar Tasker/Models/OnboardingDialog.swift",
  "Bar Tasker/Models/QuickAddLocationMode.swift",
  "Bar Tasker/Models/QuickEntryMode.swift",
  "Bar Tasker/Models/RootDueBucket.swift",
  "Bar Tasker/Models/RootTaskView.swift",

  // App-level source files at Bar Tasker/ root that AppLogic does not need.
  "Bar Tasker/AppCoordinator.swift",
  "Bar Tasker/AppDelegate.swift",
  "Bar Tasker/AppThemeColorSupport.swift",
  "Bar Tasker/CacheState.swift",
  "Bar Tasker/CommandExecutor.swift",
  "Bar Tasker/EisenhowerMatrixView.swift",
  "Bar Tasker/FocusSessionView.swift",
  "Bar Tasker/IntegrationDataSourceAdapter.swift",
  "Bar Tasker/KanbanBoardView.swift",
  "Bar Tasker/KanbanColumn.swift",
  "Bar Tasker/KanbanSettingsView.swift",
  "Bar Tasker/KanbanTaskDataSourceAdapter.swift",
  "Bar Tasker/KeyboardShortcutRouter.swift",
  "Bar Tasker/LifecycleController.swift",
  "Bar Tasker/MainApp.swift",
  "Bar Tasker/NetworkReachabilityMonitor.swift",
  "Bar Tasker/OnboardingService.swift",
  "Bar Tasker/PopoverView.swift",
  "Bar Tasker/PopoverView+QuickEntryBar.swift",
  "Bar Tasker/PopoverView+TaskRow.swift",
  "Bar Tasker/RecurrenceRule.swift",
  "Bar Tasker/SettingsNavState.swift",
  "Bar Tasker/SettingsView.swift",
  "Bar Tasker/SettingsView+DebugPane.swift",
  "Bar Tasker/SettingsView+KeybindingsPane.swift",
  "Bar Tasker/SettingsView+PreferencesPane.swift",
  "Bar Tasker/SettingsView+ThemePane.swift",
  "Bar Tasker/SyncService.swift",
  "Bar Tasker/TaskMutationService.swift",
  "Bar Tasker/TaskNavigationService.swift",
  "Bar Tasker/TaskTreeFormatter.swift",
  "Bar Tasker/TaskVisibilityEngine.swift",
  "Bar Tasker/Typography.swift",

  // Plugin subtrees (AppLogic pulls OfflineTaskSyncPlugin.swift and
  // PluginProtocols.swift as sources; everything else is app-only or lives in
  // BarTaskerPlugins).
  "Bar Tasker/Plugins/MCP",
  "Bar Tasker/Plugins/Registry",
  "Bar Tasker/Plugins/Settings",
  "Bar Tasker/Plugins/Protocols/PluginProtocols.swift",
  "Bar Tasker/Plugins/Protocols/PluginSettingsPageProviding.swift",
  "Bar Tasker/Plugins/Native/Checkvist",
  "Bar Tasker/Plugins/Native/GoogleCalendar",
  "Bar Tasker/Plugins/Native/MCP",
  "Bar Tasker/Plugins/Native/Obsidian",
  "Bar Tasker/Plugins/User",
]

let package = Package(
  name: "bar-tasker-core",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "BarTaskerCore", targets: ["BarTaskerCore"]),
    .library(name: "BarTaskerPlugins", targets: ["BarTaskerPlugins"]),
    .library(name: "BarTaskerAppLogic", targets: ["BarTaskerAppLogic"]),
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
        "Bar Tasker/Plugins/Native/Checkvist/CheckvistModels.swift",
        "Bar Tasker/Plugins/Native/Checkvist/CheckvistTaskCachePayload.swift",
        "Bar Tasker/Plugins/Native/Checkvist/CheckvistSessionError.swift",
        "Bar Tasker/Plugins/Native/Obsidian/ObsidianOpenMode.swift",
        "Bar Tasker/Plugins/Native/Obsidian/NativeObsidianIntegrationPlugin.swift",
        "Bar Tasker/Plugins/Native/GoogleCalendar/NativeGoogleCalendarIntegrationPlugin.swift",
        "Bar Tasker/Plugins/Native/GoogleCalendar/GoogleCalendarOAuthTokenStore.swift",
        "Bar Tasker/Plugins/Native/MCP/NativeMCPIntegrationPlugin.swift",
        "Bar Tasker/Plugins/User/UserPluginManager.swift",
        "Bar Tasker/Plugins/User/UserPluginManifest.swift",
        "plugin-tests-support/PluginModelStubs.swift",
      ]
    ),
    // AppLogic hosts the headless-but-app-bound state machines (TaskRepository,
    // OfflineTaskSyncPlugin, the priority/queue/eisenhower stores, etc.) so they
    // can be exercised by `swift test` without spinning up the Xcode app target.
    // The Checkvist data types and `CheckvistSyncPlugin` protocol are
    // re-declared in `applogic-support/AppLogicSharedTypes.swift` because
    // promoting them out of `BarTaskerPlugins` would require making them
    // `public` — see the Phase 5.2 note in ARCHITECTURE_IMPROVEMENT_PLAN.md.
    .target(
      name: "BarTaskerAppLogic",
      path: ".",
      exclude: appLogicTargetExcludes,
      sources: [
        "Bar Tasker/Managers/TaskRepository.swift",
        "Bar Tasker/CacheInvalidationBus.swift",
        "Bar Tasker/UndoService.swift",
        "Bar Tasker/LocalTaskStore.swift",
        "Bar Tasker/ReorderQueue.swift",
        "Bar Tasker/TaskNavigationCoordinator.swift",
        "Bar Tasker/ListScopedPriorityStore.swift",
        "Bar Tasker/ListScopedTaskIDStore.swift",
        "Bar Tasker/ListScopedEisenhowerStore.swift",
        "Bar Tasker/Plugins/Native/OfflineTaskSyncPlugin.swift",
        "Bar Tasker/PreferencesStore.swift",
        "Bar Tasker/Models/UndoableAction.swift",
        "Bar Tasker/Models/CheckvistConnectionState.swift",
        "applogic-support/AppLogicSharedTypes.swift",
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
    .testTarget(
      name: "BarTaskerAppLogicTests",
      dependencies: ["BarTaskerAppLogic", "BarTaskerPlugins"],
      path: "applogic-tests"
    ),
  ]
)
