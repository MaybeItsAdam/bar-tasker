import AppKit
import Combine
import Foundation
import OSLog
import ServiceManagement
import SwiftUI

@MainActor
class BarTaskerManager: ObservableObject {
  let logger = Logger(subsystem: "uk.co.maybeitsadam.bar-tasker", category: "manager")

  @Published var username: String
  @Published var remoteKey: String
  @Published var listId: String

  /// All tasks (flat, from API)
  @Published var tasks: [CheckvistTask] = []

  /// User's available lists from the API
  @Published var availableLists: [CheckvistList] = []

  /// The parent ID of the level currently being viewed (0 = root)
  @Published var currentParentId: Int = 0

  /// Index within the current level's sibling list
  @Published var currentSiblingIndex: Int = 0

  @Published var isLoading: Bool = false
  @Published var errorMessage: String? = nil

  // MARK: - Undo
  @Published var lastUndo: UndoableAction? = nil

  @Published var searchText: String = ""
  @Published var quickEntryText: String = ""
  @Published var hideFuture: Bool = false
  @Published var showTaskBreadcrumbContext: Bool
  @Published var rootTaskView: RootTaskView
  @Published var selectedRootDueBucketRawValue: Int
  @Published var selectedRootTag: String
  /// 0 = task list, 1 = root tabs (All/Due/Tags), 2 = root filter row (due buckets/tags)
  @Published var rootScopeFocusLevel: Int = 0
  @Published var keyBuffer: String = ""
  @Published var quickEntryMode: QuickEntryMode = .search
  @Published var isQuickEntryFocused: Bool = false
  @Published var editCursorAtEnd: Bool = true  // true = append (a), false = insert (i)
  @Published var pendingDeleteConfirmation: Bool = false
  @Published var completingTaskId: Int? = nil
  @Published var commandSuggestionIndex: Int = 0
  @Published var priorityTaskIds: [Int]

  static let commandSuggestions: [CommandSuggestion] = BarTaskerCommandEngine.suggestions.map {
    .init(
      label: $0.label,
      command: $0.command,
      preview: $0.preview,
      keybind: $0.keybind,
      submitImmediately: $0.submitImmediately
    )
  }
  static let maxPriorityRank = 9

  // MARK: - Carbon hotkey constants
  enum CarbonKey {
    static let space = 49
    static let b = 11
  }
  enum CarbonModifier {
    static let option = 0x0800
    static let shiftOption = 0x0A00
  }
  private static let priorityQueuesDefaultsKey = "priorityTaskIdsByListId"
  private static let pendingObsidianSyncDefaultsKey = "pendingObsidianSyncTaskIdsByListId"

  // MARK: - Timer
  @Published var timedTaskId: Int? = nil
  @Published var timerByTaskId: [Int: TimeInterval] = [:]
  @Published var timerRunning: Bool = false
  @Published var timerBarLeading: Bool
  @Published var timerMode: TimerMode
  var timerTask: Task<Void, Never>? = nil

  // MARK: - Settings
  @Published var confirmBeforeDelete: Bool
  @Published var launchAtLogin: Bool
  @Published var ignoreKeychainInDebug: Bool
  @Published var obsidianIntegrationEnabled: Bool
  @Published var googleCalendarIntegrationEnabled: Bool
  @Published var mcpIntegrationEnabled: Bool
  @Published var appTheme: AppTheme
  @Published var themeAccentPreset: ThemeAccentPreset
  @Published var themeCustomAccentHex: String
  @Published var themeColorTokenHexOverrides: [String: String]
  @Published var globalHotkeyEnabled: Bool
  /// Carbon keyCode for the global hotkey (default 49 = Space)
  @Published var globalHotkeyKeyCode: Int
  /// Carbon modifier mask (default 0x0800 = optionKey i.e. ⌥)
  @Published var globalHotkeyModifiers: Int
  @Published var quickAddHotkeyEnabled: Bool
  /// Carbon keyCode for the quick add hotkey (default 11 = B)
  @Published var quickAddHotkeyKeyCode: Int
  /// Carbon modifier mask (default 0x0A00 = shift+option)
  @Published var quickAddHotkeyModifiers: Int
  @Published var quickAddLocationMode: QuickAddLocationMode
  @Published var quickAddSpecificParentTaskId: String
  @Published var customizableShortcutsByAction: [String: String]

  /// Max width of the menu bar text
  @Published var maxTitleWidth: Double
  @Published var onboardingCompleted: Bool
  @Published var activeOnboardingDialog: OnboardingDialog?
  @Published var obsidianInboxPath: String
  @Published var mcpServerCommandPath: String
  @Published var pendingObsidianSyncTaskIds: [Int]
  @Published var googleCalendarEventLinksByTaskKey: [String: String]
  @Published var isNetworkReachable: Bool = true

  var dismissedOnboardingDialogs: Set<OnboardingDialog>
  var offlineArchivedTasksById: [Int: CheckvistTask]
  var nextOfflineTaskIdValue: Int

  // MARK: - Computed property caches

  var cache = BarTaskerCacheState()

  var loadingOperationCount: Int = 0
  var cancellables = Set<AnyCancellable>()
  let reorderQueue = BarTaskerReorderQueue()
  var hasPendingSyncProcessingTask = false
  var isApplyingLaunchAtLoginChange = false
  var hasAttemptedRemoteKeyBootstrap = false
  let preferencesStore = BarTaskerPreferencesStore()
  let localTaskStore: LocalTaskStore
  let checkvistSyncPlugin: any CheckvistSyncPlugin
  let obsidianPlugin: any ObsidianIntegrationPlugin
  let googleCalendarPlugin: any GoogleCalendarIntegrationPlugin
  let mcpIntegrationPlugin: any MCPIntegrationPlugin
  let userPluginManager: UserPluginManager
  lazy var commandExecutor = BarTaskerCommandExecutor(manager: self)
  let navigationCoordinator = TaskNavigationCoordinator()
  let reachabilityMonitor = NetworkReachabilityMonitor()
  let priorityQueueStore = ListScopedTaskIDStore(
    defaultsKey: BarTaskerManager.priorityQueuesDefaultsKey,
    maximumCount: BarTaskerManager.maxPriorityRank
  )
  let pendingSyncQueueStore = ListScopedTaskIDStore(
    defaultsKey: BarTaskerManager.pendingObsidianSyncDefaultsKey
  )
  var usesKeychainStorage: Bool {
    #if DEBUG
      !ignoreKeychainInDebug
    #else
      true
    #endif
  }

  var activeCredentials: CheckvistCredentials {
    CheckvistCredentials(username: username, remoteKey: remoteKey)
  }

  // swiftlint:disable function_body_length
  init(pluginRegistry: BarTaskerPluginRegistry) {
    let resolvedLocalTaskStore = LocalTaskStore()
    let offlinePayload = resolvedLocalTaskStore.load()
    let resolvedCheckvistSyncPlugin =
      pluginRegistry.activeCheckvistSyncPlugin ?? NativeCheckvistSyncPlugin()
    let resolvedObsidianPlugin =
      pluginRegistry.activeObsidianPlugin
      ?? NativeObsidianIntegrationPlugin()
    let resolvedGoogleCalendarPlugin =
      pluginRegistry.activeGoogleCalendarPlugin
      ?? NativeGoogleCalendarIntegrationPlugin()
    let resolvedMCPIntegrationPlugin =
      pluginRegistry.activeMCPIntegrationPlugin
      ?? NativeMCPIntegrationPlugin()
    self.checkvistSyncPlugin = resolvedCheckvistSyncPlugin
    self.localTaskStore = resolvedLocalTaskStore
    self.obsidianPlugin = resolvedObsidianPlugin
    self.googleCalendarPlugin = resolvedGoogleCalendarPlugin
    self.mcpIntegrationPlugin = resolvedMCPIntegrationPlugin
    self.userPluginManager = UserPluginManager(
      builtInPluginIdentifiers: [
        resolvedCheckvistSyncPlugin.pluginIdentifier,
        resolvedObsidianPlugin.pluginIdentifier,
        resolvedGoogleCalendarPlugin.pluginIdentifier,
        resolvedMCPIntegrationPlugin.pluginIdentifier,
      ]
    )

    let storedUsername = preferencesStore.string(.checkvistUsername)
    let storedListId = preferencesStore.string(.checkvistListId)
    let storedOnboardingCompletedFlag = preferencesStore.optionalBool(.onboardingCompleted)
    let storedPluginSelectionOnboardingCompletedFlag = preferencesStore.optionalBool(
      .pluginSelectionOnboardingCompleted)
    let storedObsidianIntegrationEnabled = preferencesStore.optionalBool(
      .obsidianIntegrationEnabled)
    let storedGoogleCalendarIntegrationEnabled = preferencesStore.optionalBool(
      .googleCalendarIntegrationEnabled)
    let storedMCPIntegrationEnabled = preferencesStore.optionalBool(.mcpIntegrationEnabled)
    let storedObsidianInboxPath = resolvedObsidianPlugin.inboxPath
    self.username = storedUsername
    self.listId = storedListId
    self.tasks =
      storedListId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? offlinePayload.openTasks : []
    self.offlineArchivedTasksById = Dictionary(
      uniqueKeysWithValues: offlinePayload.archivedTasks.map { ($0.id, $0) })
    self.nextOfflineTaskIdValue = max(offlinePayload.nextTaskId, 1)
    self.pendingObsidianSyncTaskIds = pendingSyncQueueStore.load(for: storedListId)
    self.googleCalendarEventLinksByTaskKey = preferencesStore.stringDictionary(
      .googleCalendarEventLinksByTaskKey)
    self.priorityTaskIds = priorityQueueStore.load(for: storedListId)
    self.obsidianInboxPath = storedObsidianInboxPath
    self.obsidianIntegrationEnabled =
      storedObsidianIntegrationEnabled
      ?? preferencesStore.bool(.obsidianIntegrationEnabled, default: false)
    self.googleCalendarIntegrationEnabled =
      storedGoogleCalendarIntegrationEnabled
      ?? preferencesStore.bool(.googleCalendarIntegrationEnabled, default: false)
    self.mcpIntegrationEnabled =
      storedMCPIntegrationEnabled
      ?? preferencesStore.bool(.mcpIntegrationEnabled, default: false)
    self.appTheme =
      AppTheme(rawValue: preferencesStore.int(.appThemeRawValue, default: 0))
      ?? .system
    self.themeAccentPreset =
      ThemeAccentPreset(
        rawValue: preferencesStore.string(
          .themeAccentPresetRawValue,
          default: ThemeAccentPreset.blue.rawValue
        )
      )
      ?? .blue
    self.themeCustomAccentHex =
      BarTaskerThemeColorCodec.normalizedHex(
        preferencesStore.string(.themeCustomAccentHex, default: ThemeAccentPreset.blue.hex)
      ) ?? ThemeAccentPreset.blue.hex
    self.themeColorTokenHexOverrides =
      Self.normalizedThemeColorTokenHexOverrides(
        preferencesStore.stringDictionary(.themeColorTokenHexOverrides)
      )
    self.mcpServerCommandPath = resolvedMCPIntegrationPlugin.serverCommandURL()?.path ?? ""
    self.confirmBeforeDelete = preferencesStore.bool(.confirmBeforeDelete, default: true)
    self.showTaskBreadcrumbContext = preferencesStore.bool(
      .showTaskBreadcrumbContext, default: false)
    self.rootTaskView =
      RootTaskView(rawValue: preferencesStore.int(.rootTaskView, default: 1)) ?? .due
    self.selectedRootDueBucketRawValue = preferencesStore.int(
      .selectedRootDueBucketRawValue, default: -1)
    self.selectedRootTag = preferencesStore.string(.selectedRootTag)
    self.launchAtLogin = preferencesStore.bool(.launchAtLogin, default: false)
    #if DEBUG
      self.ignoreKeychainInDebug =
        preferencesStore.bool(
          .ignoreKeychainInDebug,
          default: true
        )
    #else
      self.ignoreKeychainInDebug = true
    #endif
    self.globalHotkeyEnabled = preferencesStore.bool(.globalHotkeyEnabled, default: false)
    self.globalHotkeyKeyCode = preferencesStore.int(.globalHotkeyKeyCode, default: CarbonKey.space)
    self.globalHotkeyModifiers = preferencesStore.int(
      .globalHotkeyModifiers, default: CarbonModifier.option)
    self.quickAddHotkeyEnabled = preferencesStore.bool(.quickAddHotkeyEnabled, default: false)
    self.quickAddHotkeyKeyCode = preferencesStore.int(.quickAddHotkeyKeyCode, default: CarbonKey.b)
    self.quickAddHotkeyModifiers = preferencesStore.int(
      .quickAddHotkeyModifiers, default: CarbonModifier.shiftOption)
    self.quickAddLocationMode =
      QuickAddLocationMode(
        rawValue: preferencesStore.int(.quickAddLocationModeRawValue, default: 0))
      ?? .defaultRoot
    self.quickAddSpecificParentTaskId = preferencesStore.string(.quickAddSpecificParentTaskId)
    let persistedShortcutOverrides = preferencesStore.stringDictionary(
      .customizableShortcutsByAction)
    self.customizableShortcutsByAction = persistedShortcutOverrides
    self.maxTitleWidth = preferencesStore.double(.maxTitleWidth, default: 150.0)
    if let storedOnboarding = storedOnboardingCompletedFlag {
      self.onboardingCompleted = storedOnboarding
    } else {
      // Existing installs with saved account + list skip onboarding by default.
      self.onboardingCompleted = !storedUsername.isEmpty && !storedListId.isEmpty
    }

    if storedPluginSelectionOnboardingCompletedFlag == nil {
      let hasLegacyState =
        storedOnboardingCompletedFlag != nil
        || !storedUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !storedListId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || storedObsidianIntegrationEnabled != nil
        || storedGoogleCalendarIntegrationEnabled != nil
        || storedMCPIntegrationEnabled != nil
      if hasLegacyState {
        preferencesStore.set(true, for: .pluginSelectionOnboardingCompleted)
      }
    }
    self.timerBarLeading = preferencesStore.bool(.timerBarLeading, default: false)
    self.timerMode = TimerMode(rawValue: preferencesStore.int(.timerMode, default: 0)) ?? .visible
    self.timerByTaskId = Self.timerDictionaryFromDefaults(preferencesStore: preferencesStore)
    self.activeOnboardingDialog = nil
    let persistedDismissedDialogs = preferencesStore.stringArray(.dismissedOnboardingDialogs)
    self.dismissedOnboardingDialogs = Set(
      persistedDismissedDialogs.compactMap(OnboardingDialog.init(rawValue:))
    )

    let useKeychainStorageAtInit: Bool
    #if DEBUG
      let ignoreAtInit = preferencesStore.bool(.ignoreKeychainInDebug, default: true)
      useKeychainStorageAtInit = !ignoreAtInit
    #else
      useKeychainStorageAtInit = true
    #endif

    self.remoteKey = resolvedCheckvistSyncPlugin.startupRemoteKey(
      useKeychainStorageAtInit: useKeychainStorageAtInit)

    setupBindings()
    setupNetworkMonitor()
    Task { @MainActor [weak self] in
      self?.presentOnboardingDialogIfNeeded()
    }
  }

  convenience init() {
    self.init(pluginRegistry: .nativeFirst())
  }

  deinit {
    reachabilityMonitor.stop()
  }
  // swiftlint:enable function_body_length
}
