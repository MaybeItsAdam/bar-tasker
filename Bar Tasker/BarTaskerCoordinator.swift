import AppKit
import Foundation
import Observation
import OSLog
import ServiceManagement
import SwiftUI

@MainActor
@Observable class BarTaskerCoordinator {
  @ObservationIgnored let logger = Logger(subsystem: "uk.co.maybeitsadam.bar-tasker", category: "manager")

  // MARK: - Task Repository

  let repository: TaskRepository

  // MARK: - Forwarding properties (heavily used across extensions + views)

  var tasks: [CheckvistTask] {
    get { repository.tasks }
    set { repository.tasks = newValue }
  }
  var currentParentId: Int {
    get { repository.currentParentId }
    set { repository.currentParentId = newValue }
  }
  var currentSiblingIndex: Int {
    get { repository.currentSiblingIndex }
    set { repository.currentSiblingIndex = newValue }
  }
  var listId: String {
    get { repository.listId }
    set { repository.listId = newValue }
  }
  var errorMessage: String? {
    get { repository.errorMessage }
    set { repository.errorMessage = newValue }
  }
  var lastUndo: UndoableAction? {
    get { repository.lastUndo }
    set { repository.lastUndo = newValue }
  }

  // MARK: - View / Filter State

  var hideFuture: Bool = false {
    didSet { invalidateCaches() }
  }
  var rootTaskView: RootTaskView {
    didSet {
      preferencesStore.set(rootTaskView.rawValue, for: .rootTaskView)
      invalidateCaches()
    }
  }
  var selectedRootDueBucketRawValue: Int {
    didSet {
      preferencesStore.set(selectedRootDueBucketRawValue, for: .selectedRootDueBucketRawValue)
      invalidateCaches()
    }
  }
  var selectedRootTag: String {
    didSet {
      preferencesStore.set(selectedRootTag, for: .selectedRootTag)
      invalidateCaches()
    }
  }
  /// 0 = task list, 1 = root tabs (All/Due/Tags), 2 = root filter row (due buckets/tags)
  var rootScopeFocusLevel: Int = 0
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

  // MARK: - Carbon hotkey constants
  enum CarbonKey {
    static let space = 49
    static let b = 11
  }
  enum CarbonModifier {
    static let option = 0x0800
    static let shiftOption = 0x0A00
  }

  // MARK: - Start Dates
  let startDates: StartDateManager

  // MARK: - Recurrence
  let recurrence: RecurrenceManager

  // MARK: - Timer
  let timer: TimerManager

  // MARK: - Integrations
  var integrations: IntegrationCoordinator

  // MARK: - Quick Entry
  var quickEntry: QuickEntryManager

  // MARK: - Kanban
  let kanban: KanbanManager

  let preferences: PreferencesManager
  var onboardingCompleted: Bool {
    didSet { preferencesStore.set(onboardingCompleted, for: .onboardingCompleted) }
  }
  var activeOnboardingDialog: OnboardingDialog?

  @ObservationIgnored var dismissedOnboardingDialogs: Set<OnboardingDialog>

  // MARK: - Computed property caches

  @ObservationIgnored var cache = BarTaskerCacheState()

  @ObservationIgnored var isApplyingLaunchAtLoginChange = false
  @ObservationIgnored let preferencesStore = BarTaskerPreferencesStore()
  let userPluginManager: UserPluginManager
  @ObservationIgnored lazy var commandExecutor = BarTaskerCommandExecutor(manager: self)
  @ObservationIgnored let reachabilityMonitor = NetworkReachabilityMonitor()
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

  var username: String {
    get { repository.username }
    set { repository.username = newValue }
  }
  var remoteKey: String {
    get { repository.remoteKey }
    set { repository.remoteKey = newValue }
  }
  var availableLists: [CheckvistList] {
    get { repository.availableLists }
    set { repository.availableLists = newValue }
  }
  var isLoading: Bool {
    get { repository.isLoading }
    set { repository.isLoading = newValue }
  }

  // swiftlint:disable function_body_length
  init(pluginRegistry: BarTaskerPluginRegistry) {
    let resolvedLocalTaskStore = LocalTaskStore()
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

    self.userPluginManager = UserPluginManager(
      builtInPluginIdentifiers: [
        resolvedCheckvistSyncPlugin.pluginIdentifier,
        resolvedObsidianPlugin.pluginIdentifier,
        resolvedGoogleCalendarPlugin.pluginIdentifier,
        resolvedMCPIntegrationPlugin.pluginIdentifier,
      ]
    )
    self.preferences = PreferencesManager(preferencesStore: preferencesStore)

    // Compute initial remote key before creating repository
    let useKeychainStorageAtInit: Bool
    #if DEBUG
      let ignoreAtInit = preferencesStore.bool(.ignoreKeychainInDebug, default: true)
      useKeychainStorageAtInit = !ignoreAtInit
    #else
      useKeychainStorageAtInit = true
    #endif

    let initialRemoteKey = resolvedCheckvistSyncPlugin.startupRemoteKey(
      useKeychainStorageAtInit: useKeychainStorageAtInit)

    // Create task repository with all task-related state
    self.repository = TaskRepository(
      preferencesStore: preferencesStore,
      checkvistSyncPlugin: resolvedCheckvistSyncPlugin,
      localTaskStore: resolvedLocalTaskStore,
      initialRemoteKey: initialRemoteKey
    )

    let storedListId = preferencesStore.string(.checkvistListId)
    let storedUsername = preferencesStore.string(.checkvistUsername)
    let storedOnboardingCompletedFlag = preferencesStore.optionalBool(.onboardingCompleted)
    let storedPluginSelectionOnboardingCompletedFlag = preferencesStore.optionalBool(
      .pluginSelectionOnboardingCompleted)

    self.rootTaskView =
      RootTaskView(rawValue: preferencesStore.int(.rootTaskView, default: 1)) ?? .due
    self.selectedRootDueBucketRawValue = preferencesStore.int(
      .selectedRootDueBucketRawValue, default: -1)
    self.selectedRootTag = preferencesStore.string(.selectedRootTag)
    self.kanban = KanbanManager(preferencesStore: preferencesStore)
    if let storedOnboarding = storedOnboardingCompletedFlag {
      self.onboardingCompleted = storedOnboarding
    } else {
      self.onboardingCompleted = !storedUsername.isEmpty && !storedListId.isEmpty
    }

    if storedPluginSelectionOnboardingCompletedFlag == nil {
      let storedObsidianIntegrationEnabled = preferencesStore.optionalBool(
        .obsidianIntegrationEnabled)
      let storedGoogleCalendarIntegrationEnabled = preferencesStore.optionalBool(
        .googleCalendarIntegrationEnabled)
      let storedMCPIntegrationEnabled = preferencesStore.optionalBool(.mcpIntegrationEnabled)
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
    self.quickEntry = QuickEntryManager()
    self.integrations = IntegrationCoordinator(
      preferencesStore: preferencesStore,
      obsidianPlugin: resolvedObsidianPlugin,
      googleCalendarPlugin: resolvedGoogleCalendarPlugin,
      mcpIntegrationPlugin: resolvedMCPIntegrationPlugin,
      initialListId: storedListId
    )
    self.activeOnboardingDialog = nil
    let persistedDismissedDialogs = preferencesStore.stringArray(.dismissedOnboardingDialogs)
    self.dismissedOnboardingDialogs = Set(
      persistedDismissedDialogs.compactMap(OnboardingDialog.init(rawValue:))
    )

    setupBindings()
    setupChildCallbacks()
    kanban.dataSource = self
    integrations.dataSource = self
    integrations.onIntegrationStateChanged = { [weak self] in
      self?.refreshOnboardingDialogState()
    }
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

extension BarTaskerCoordinator: KanbanTaskDataSource {}

// MARK: - IntegrationDataSource conformance

extension BarTaskerCoordinator: IntegrationDataSource {}

// MARK: - Kanban move orchestration (cross-cutting: kanban + task CRUD)

extension BarTaskerCoordinator {
  @MainActor func moveCurrentTaskToKanbanColumn(direction: Int) async {
    guard let outcome = kanban.computeMoveCurrentTask(direction: direction) else { return }
    switch outcome {
    case .error(let msg):
      repository.errorMessage = msg
    case .update(let task, let newContent, let newDue):
      await updateTask(task: task, content: newContent, due: newDue)
    }
  }

  @MainActor func moveTask(id taskId: Int, toColumn targetColumn: KanbanColumn) async {
    guard let outcome = kanban.computeMoveTask(id: taskId, toColumn: targetColumn) else { return }
    switch outcome {
    case .error(let msg):
      repository.errorMessage = msg
    case .update(let task, let newContent, let newDue):
      await updateTask(task: task, content: newContent, due: newDue)
    }
  }
}
