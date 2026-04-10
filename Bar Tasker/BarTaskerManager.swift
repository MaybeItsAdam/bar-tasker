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
  @Published var rootTaskView: RootTaskView
  @Published var selectedRootDueBucketRawValue: Int
  @Published var selectedRootTag: String
  /// 0 = task list, 1 = root tabs (All/Due/Tags), 2 = root filter row (due buckets/tags)
  @Published var rootScopeFocusLevel: Int = 0
  @Published var keyBuffer: String = ""
  
  var orderedRootTaskViews: [RootTaskView] {
    if let data = UserDefaults.standard.data(forKey: "rootTaskViewOrder"),
       let rawValues = try? JSONDecoder().decode([Int].self, from: data) {
      let views = rawValues.compactMap { RootTaskView(rawValue: $0) }
      // Ensure all cases are present
      let allCases = RootTaskView.allCases
      if Set(views) == Set(allCases) && views.count == allCases.count {
        return views
      }
    }
    return RootTaskView.allCases
  }
  
  func saveRootTaskViewOrder(_ views: [RootTaskView]) {
    let rawValues = views.map { $0.rawValue }
    if let data = try? JSONEncoder().encode(rawValues) {
      UserDefaults.standard.set(data, forKey: "rootTaskViewOrder")
    }
  }
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

  // MARK: - Start Dates
  let startDates: StartDateManager

  // MARK: - Recurrence
  let recurrence: RecurrenceManager

  // MARK: - Timer
  let timer: TimerManager

  // MARK: - Integrations
  @Published var obsidianIntegrationEnabled: Bool
  @Published var googleCalendarIntegrationEnabled: Bool
  @Published var mcpIntegrationEnabled: Bool

  // MARK: - Kanban
  let kanban: KanbanManager

  let preferences: PreferencesManager
  @Published var onboardingCompleted: Bool
  @Published var activeOnboardingDialog: OnboardingDialog?
  @Published var obsidianInboxPath: String
  @Published var mcpServerCommandPath: String
  @Published var pendingObsidianSyncTaskIds: [Int]
  @Published var googleCalendarEventLinksByTaskKey: [String: String]
  @Published var isNetworkReachable: Bool = true

  /// Mutations that failed due to network unavailability, pending a retry when connectivity is restored.
  /// Keyed by taskId; later mutations overwrite earlier ones for the same task.
  var pendingTaskMutations: [Int: (content: String?, due: String?)] = [:]

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
      !preferences.ignoreKeychainInDebug
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
    self.preferences = PreferencesManager(preferencesStore: preferencesStore)

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
    self.mcpServerCommandPath = resolvedMCPIntegrationPlugin.serverCommandURL()?.path ?? ""
    self.rootTaskView =
      RootTaskView(rawValue: preferencesStore.int(.rootTaskView, default: 1)) ?? .due
    self.selectedRootDueBucketRawValue = preferencesStore.int(
      .selectedRootDueBucketRawValue, default: -1)
    self.selectedRootTag = preferencesStore.string(.selectedRootTag)
    self.kanban = KanbanManager(preferencesStore: preferencesStore)
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
    self.timer = TimerManager(preferencesStore: preferencesStore)
    self.startDates = StartDateManager(preferencesStore: preferencesStore)
    self.recurrence = RecurrenceManager(preferencesStore: preferencesStore)
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
    preferences.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
    timer.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
    kanban.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
    startDates.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
    recurrence.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
    kanban.dataSource = self
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

// MARK: - KanbanTaskDataSource conformance

extension BarTaskerManager: KanbanTaskDataSource {}

// MARK: - Kanban move orchestration (cross-cutting: kanban + task CRUD)

extension BarTaskerManager {
  @MainActor func moveCurrentTaskToKanbanColumn(direction: Int) async {
    guard let outcome = kanban.computeMoveCurrentTask(direction: direction) else { return }
    switch outcome {
    case .error(let msg):
      errorMessage = msg
    case .update(let task, let newContent, let newDue):
      await updateTask(task: task, content: newContent, due: newDue)
    }
  }

  @MainActor func moveTask(id taskId: Int, toColumn targetColumn: KanbanColumn) async {
    guard let outcome = kanban.computeMoveTask(id: taskId, toColumn: targetColumn) else { return }
    switch outcome {
    case .error(let msg):
      errorMessage = msg
    case .update(let task, let newContent, let newDue):
      await updateTask(task: task, content: newContent, due: newDue)
    }
  }
}
