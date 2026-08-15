import AppKit
import Foundation
import OSLog
import Observation
import ServiceManagement
import SwiftUI

@MainActor
@Observable class AppCoordinator {
  @ObservationIgnored let logger = Logger(
    subsystem: "uk.co.maybeitsadam.priority", category: "manager")

  let repository: TaskRepository
  let feedbackService: FeedbackService
  @ObservationIgnored let cacheInvalidationBus: CacheInvalidationBus

  let navigationState: NavigationState

  var statusMessage: String? {
    didSet {
      if statusMessage != nil {
        Task { @MainActor in
          try? await Task.sleep(for: .seconds(3))
          self.statusMessage = nil
        }
      }
    }
  }

  var orderedRootTaskViews: [RootTaskView] {
    if let data = UserDefaults.standard.data(forKey: "rootTaskViewOrder"),
      let rawValues = try? JSONDecoder().decode([Int].self, from: data)
    {
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

  enum CarbonKey {
    static let space = 49
    static let b = 11
  }
  enum CarbonModifier {
    static let option = 0x0800
    static let shiftOption = 0x0A00
  }

  let startDates: StartDateManager

  let recurrence: RecurrenceManager

  let timer: TimerManager
  let taskListViewModel: TaskListViewModel

  var integrations: IntegrationCoordinator

  var quickEntry: QuickEntryManager

  let kanban: KanbanManager

  let focusSessionManager: FocusSessionManager

  let dailyLog: DailyLogManager
  /// Popover chrome — the dock row, the resize strip, per-view heights.
  let popoverChrome: PopoverChromeManager

  let preferences: PreferencesManager
  var onboardingService: OnboardingService!

  @ObservationIgnored var isApplyingLaunchAtLoginChange = false
  @ObservationIgnored let preferencesStore = PreferencesStore()
  let userPluginManager: UserPluginManager
  @ObservationIgnored lazy var commandExecutor = CommandExecutor(manager: self)
  @ObservationIgnored private(set) var lifecycle: LifecycleController!
  private(set) var undoService: UndoService!
  @ObservationIgnored private(set) var taskNavigationService: TaskNavigationService!
  @ObservationIgnored private(set) var taskMutationService: TaskMutationService!
  @ObservationIgnored private(set) var syncService: SyncService!
  /// Strong-held because `KanbanManager.dataSource` is `weak`. Bridges the
  /// kanban data-source protocol to repository/navigationState/taskListViewModel
  /// so AppCoordinator no longer has to conform to `KanbanTaskDataSource`.
  @ObservationIgnored private var kanbanDataSourceAdapter: KanbanTaskDataSourceAdapter!
  /// Strong-held because `IntegrationCoordinator.dataSource` is `weak`. Same
  /// role as `kanbanDataSourceAdapter` — bridges the protocol to
  /// repository/coordinator so AppCoordinator needn't conform.
  @ObservationIgnored private var integrationDataSourceAdapter: IntegrationDataSourceAdapter!
  /// Strong-held for the same reason as the two adapters above:
  /// `DailyLogManager.dataSource` is `weak`.
  @ObservationIgnored private var dailyLogDataSourceAdapter: DailyLogDataSourceAdapter!
  /// Owned here (rather than on `LifecycleController`) so `deinit`, which is
  /// nonisolated, can call `stop()` without hopping back onto the main actor.
  @ObservationIgnored let reachabilityMonitor = NetworkReachabilityMonitor()
  /// Where the Checkvist remote key is persisted.
  ///
  /// The key is password-equivalent, so release builds keep it in the keychain
  /// (matching `GoogleCalendarOAuthTokenStore`) rather than in the preferences
  /// plist, which is world-readable by anything running as the user. This was
  /// previously hardcoded to `false`, which not only stored the key in the clear
  /// but also actively migrated it *out* of the keychain on first launch.
  ///
  /// DEBUG builds keep the opt-out (defaulting to on, see `PreferencesManager`)
  /// because locally-signed dev builds get a new signing identity on each
  /// rebuild, which makes macOS prompt for keychain access every run.
  var usesKeychainStorage: Bool {
    #if DEBUG
      return !preferences.ignoreKeychainInDebug
    #else
      return true
    #endif
  }

  init(pluginRegistry: PluginRegistry, feedbackService: FeedbackService? = nil) {
    self.feedbackService = feedbackService ?? DefaultFeedbackService()
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
    let resolvedDailyLogPlugin =
      pluginRegistry.activeDailyLogPlugin
      ?? NativeDailyLogPlugin()

    self.userPluginManager = UserPluginManager(
      builtInPluginIdentifiers: [
        resolvedCheckvistSyncPlugin.pluginIdentifier,
        resolvedObsidianPlugin.pluginIdentifier,
        resolvedGoogleCalendarPlugin.pluginIdentifier,
        resolvedMCPIntegrationPlugin.pluginIdentifier,
        resolvedDailyLogPlugin.pluginIdentifier,
      ]
    )
    self.preferences = PreferencesManager(preferencesStore: preferencesStore)

    // Mirrors `usesKeychainStorage`, which can't be read yet because `self`
    // isn't fully initialized here.
    #if DEBUG
      let useKeychainStorageAtInit = !preferencesStore.bool(.ignoreKeychainInDebug, default: true)
    #else
      let useKeychainStorageAtInit = true
    #endif
    // Returns "" in keychain mode: the actual read is deferred out of the
    // launch path to `LifecycleController.start()`.
    let initialRemoteKey = resolvedCheckvistSyncPlugin.startupRemoteKey(
      useKeychainStorageAtInit: useKeychainStorageAtInit)

    let cacheInvalidationBus = CacheInvalidationBus()
    self.cacheInvalidationBus = cacheInvalidationBus

    let navigationState = NavigationState(cacheInvalidationBus: cacheInvalidationBus)
    self.navigationState = navigationState

    // Create task repository with all task-related state
    let repository = TaskRepository(
      preferencesStore: preferencesStore,
      checkvistSyncPlugin: resolvedCheckvistSyncPlugin,
      localTaskStore: resolvedLocalTaskStore,
      initialRemoteKey: initialRemoteKey,
      cacheInvalidationBus: cacheInvalidationBus
    )
    self.repository = repository

    let storedListId = preferencesStore.string(.checkvistListId)
    let storedUsername = preferencesStore.string(.checkvistUsername)
    let storedOnboardingCompletedFlag = preferencesStore.optionalBool(.onboardingCompleted)
    let storedPluginSelectionOnboardingCompletedFlag = preferencesStore.optionalBool(
      .pluginSelectionOnboardingCompleted)

    self.kanban = KanbanManager(
      preferencesStore: preferencesStore,
      cacheInvalidationBus: cacheInvalidationBus
    )
    self.focusSessionManager = FocusSessionManager(
      preferencesStore: preferencesStore,
      cacheInvalidationBus: cacheInvalidationBus
    )
    self.dailyLog = DailyLogManager(
      preferencesStore: preferencesStore,
      plugin: resolvedDailyLogPlugin
    )
    self.popoverChrome = PopoverChromeManager(preferencesStore: preferencesStore)
    // OnboardingService will compute onboardingCompleted in its init.

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
    let timer = TimerManager(
      preferencesStore: preferencesStore,
      cacheInvalidationBus: cacheInvalidationBus
    )
    self.timer = timer
    self.startDates = StartDateManager(
      preferencesStore: preferencesStore,
      cacheInvalidationBus: cacheInvalidationBus
    )
    self.recurrence = RecurrenceManager(preferencesStore: preferencesStore)
    let quickEntry = QuickEntryManager(cacheInvalidationBus: cacheInvalidationBus)
    self.quickEntry = quickEntry
    let integrations = IntegrationCoordinator(
      preferencesStore: preferencesStore,
      obsidianPlugin: resolvedObsidianPlugin,
      googleCalendarPlugin: resolvedGoogleCalendarPlugin,
      mcpIntegrationPlugin: resolvedMCPIntegrationPlugin,
      initialListId: storedListId
    )
    self.integrations = integrations
    self.onboardingService = OnboardingService(
      preferencesStore: preferencesStore,
      repository: repository,
      integrations: integrations
    )

    self.taskListViewModel = TaskListViewModel(
      repository: repository,
      navigationState: navigationState,
      timer: timer,
      quickEntry: quickEntry,
      kanban: kanban,
      preferences: preferences
    )

    self.taskNavigationService = TaskNavigationService(
      coordinator: self,
      repository: repository,
      navigationState: navigationState
    )
    self.taskMutationService = TaskMutationService(host: self, repository: repository)
    self.undoService = UndoService(performer: self.taskMutationService)
    self.syncService = SyncService(host: self, repository: repository)
    self.lifecycle = LifecycleController(
      coordinator: self,
      reachabilityMonitor: reachabilityMonitor
    )
    self.lifecycle.start()
    timer.onTick = { [weak self] taskId, elapsed in
      self?.focusSessionManager.handleTaskElapsed(elapsed, forTaskId: taskId)
    }
    focusSessionManager.onFocusBlockEnded = { [weak timer] in
      timer?.pauseTimer()
    }
    let kanbanDataSourceAdapter = KanbanTaskDataSourceAdapter(
      repository: repository,
      navigationState: navigationState,
      taskListViewModel: taskListViewModel
    )
    self.kanbanDataSourceAdapter = kanbanDataSourceAdapter
    kanban.dataSource = kanbanDataSourceAdapter
    let integrationDataSourceAdapter = IntegrationDataSourceAdapter(
      repository: repository,
      coordinator: self
    )
    self.integrationDataSourceAdapter = integrationDataSourceAdapter
    integrations.dataSource = integrationDataSourceAdapter
    integrations.onIntegrationStateChanged = { [weak self] in
      self?.onboardingService.refreshOnboardingDialogState()
    }
    let dailyLogDataSourceAdapter = DailyLogDataSourceAdapter(
      repository: repository,
      taskListViewModel: taskListViewModel,
      startDates: startDates
    )
    self.dailyLogDataSourceAdapter = dailyLogDataSourceAdapter
    dailyLog.dataSource = dailyLogDataSourceAdapter
    dailyLog.onError = { [weak self] message in
      self?.repository.errorMessage = message
    }
    // A finished focus block is the one piece of "what I did today" that no
    // task mutation records, so it's captured here rather than through the
    // `TaskMutationHost` seam.
    focusSessionManager.onFocusSessionCompleted = { [weak self] taskId, seconds in
      guard let self else { return }
      let title = self.repository.tasks.first { $0.id == taskId }?.content ?? ""
      self.dailyLog.recordFocusSession(taskId: taskId, title: title, seconds: seconds)
    }
    Task { @MainActor [weak self] in
      self?.onboardingService.presentOnboardingDialogIfNeeded()
      // Deferred rather than run inline: the data source is only wired a few
      // lines above, and this must not be the thing that snapshots an empty
      // plan before the task list has loaded. Covers launching without ever
      // opening the popover; `showPopoverWindow` handles the rest.
      self?.dailyLog.refreshForToday()
    }
  }

  convenience init() {
    self.init(pluginRegistry: .nativeFirst())
  }

  deinit {
    reachabilityMonitor.stop()
  }
}

extension TaskMutationService: UndoActionPerforming {}

extension AppCoordinator {
  // MARK: - Recurrence convenience

  /// `setRecurrenceRule` is kept here (rather than on `RecurrenceManager`)
  /// because parse failure surfaces through `errorMessage`, which is a
  /// coordinator-level concern. The other two are pass-throughs that exist
  /// only to spare callers a `.recurrence.` hop and could be inlined later.
  func recurrenceRule(for task: CheckvistTask) -> RecurrenceRule? {
    recurrence.recurrenceRule(for: task)
  }

  @MainActor func setRecurrenceRule(_ raw: String, for task: CheckvistTask) {
    if let error = recurrence.setRecurrenceRule(raw, for: task) {
      repository.errorMessage = error
    }
  }

  @MainActor func clearRecurrenceRule(for task: CheckvistTask) {
    recurrence.clearRecurrenceRule(for: task)
  }
}

extension AppCoordinator {
  @MainActor func moveCurrentTaskToKanbanColumn(direction: Int) {
    guard let outcome = kanban.computeMoveCurrentTask(direction: direction) else { return }
    switch outcome {
    case .error(let msg):
      repository.errorMessage = msg
    case .update(let task, let newContent, let newDue):
      applyOptimisticMoveAndSync(task: task, content: newContent, due: newDue)
    }
  }

  @MainActor func moveTask(id taskId: Int, toColumn targetColumn: KanbanColumn) {
    guard let outcome = kanban.computeMoveTask(id: taskId, toColumn: targetColumn) else { return }
    switch outcome {
    case .error(let msg):
      repository.errorMessage = msg
    case .update(let task, let newContent, let newDue):
      applyOptimisticMoveAndSync(task: task, content: newContent, due: newDue)
    }
  }

  /// Creates a new root-level task pre-configured for the given kanban column.
  @MainActor func addTaskInKanbanColumn(rawContent: String, column: KanbanColumn) {
    let trimmed = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    guard !repository.listId.isEmpty else {
      repository.errorMessage = "Choose a Checkvist list in Preferences to add tasks."
      return
    }

    let (content, due) = kanban.contentAndDueForNewTask(rawContent: trimmed, in: column)

    // Optimistic local insert. Shares the id sequence with
    // `TaskMutationService` so the two optimistic-insert paths can't hand out
    // the same placeholder id.
    let optimisticId = OptimisticTaskID.make()
    let optimisticTask = CheckvistTask(
      id: optimisticId, content: content, status: 0, due: due,
      position: nil, parentId: nil, level: nil
    )
    repository.tasks.append(optimisticTask)
    kanban.kanbanSelectedTaskId = optimisticId

    let listId = repository.listId
    let credentials = repository.activeCredentials
    let plugin = repository.activeSyncPlugin

    Task { [weak self] in
      do {
        let newTask = try await plugin.createTask(
          listId: listId, content: content, parentId: nil, position: nil,
          credentials: credentials
        )
        await MainActor.run { [weak self] in
          guard let self else { return }
          if let newTask {
            // If a due date was set, sync it to the server too.
            if let due, !due.isEmpty {
              let taskId = newTask.id
              Task {
                _ = try? await plugin.updateTask(
                  listId: listId, taskId: taskId, content: nil, due: due,
                  credentials: credentials
                )
              }
            }
            self.undoService.lastAction = .add(taskId: newTask.id)
            // Replace optimistic task with the real one.
            if let idx = self.repository.tasks.firstIndex(where: { $0.id == optimisticId }) {
              self.repository.tasks[idx] = CheckvistTask(
                id: newTask.id, content: content, status: 0, due: due,
                position: newTask.position, parentId: nil, level: nil
              )
            }
            self.kanban.kanbanSelectedTaskId = newTask.id
          } else {
            self.repository.tasks.removeAll { $0.id == optimisticId }
            self.repository.errorMessage = "Failed to add task."
          }
        }
      } catch {
        await MainActor.run { [weak self] in
          self?.repository.tasks.removeAll { $0.id == optimisticId }
          self?.repository.errorMessage = "Error adding task: \(error.localizedDescription)"
        }
      }
    }
  }

  /// Applies the move locally (immediate) and syncs to the server in the background.
  @MainActor func applyOptimisticMoveAndSync(
    task: CheckvistTask, content: String?, due: String?
  ) {
    undoService.lastAction = .update(
      taskId: task.id, oldContent: task.content, oldDue: task.due)

    guard let index = repository.tasks.firstIndex(where: { $0.id == task.id }) else { return }
    let originalTask = repository.tasks[index]
    repository.tasks[index] = CheckvistTask(
      id: originalTask.id,
      content: content ?? originalTask.content,
      status: originalTask.status,
      due: due ?? originalTask.due,
      position: originalTask.position,
      parentId: originalTask.parentId,
      level: originalTask.level,
      notes: originalTask.notes,
      updatedAt: originalTask.updatedAt
    )

    let listId = repository.listId
    let credentials = repository.activeCredentials
    let plugin = repository.activeSyncPlugin
    let taskId = task.id

    Task { [weak self] in
      do {
        let success = try await plugin.updateTask(
          listId: listId,
          taskId: taskId,
          content: content,
          due: due,
          credentials: credentials
        )
        if !success {
          await MainActor.run { [weak self] in
            guard let self else { return }
            if let idx = self.repository.tasks.firstIndex(where: { $0.id == taskId }) {
              self.repository.tasks[idx] = originalTask
            }
            self.repository.errorMessage = "Failed to sync task move."
          }
        }
      } catch {
        await MainActor.run { [weak self] in
          guard let self else { return }
          if !self.repository.isNetworkReachable {
            self.repository.pendingTaskMutations[taskId] = (content: content, due: due)
          } else if let idx = self.repository.tasks.firstIndex(where: { $0.id == taskId }) {
            self.repository.tasks[idx] = originalTask
            self.repository.errorMessage = "Failed to sync task move."
          }
        }
      }
    }
  }

  // MARK: - Keychain / Debug / Command execution

  func handleCredentialStorageModeChanged() {
    let current = repository.remoteKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if usesKeychainStorage {
      if !current.isEmpty {
        if let failure = repository.checkvistSyncPlugin.persistRemoteKey(
          current, useKeychainStorage: true)
        {
          repository.errorMessage = failure
        }
      } else {
        repository.hasAttemptedRemoteKeyBootstrap = false
        loadRemoteKeyFromKeychainIfNeeded()
      }
    } else {
      repository.checkvistSyncPlugin.persistRemoteKeyForDebugStorageMode(current)
    }
  }

  @MainActor func loadCredentialsFromKeychain() {
    repository.hasAttemptedRemoteKeyBootstrap = false
    loadRemoteKeyFromKeychainIfNeeded()
  }

  func loadRemoteKeyFromKeychainIfNeeded() {
    let currentState = RemoteKeyBootstrapState(
      remoteKey: repository.remoteKey,
      hasAttemptedBootstrap: repository.hasAttemptedRemoteKeyBootstrap
    )
    let nextState = RemoteKeyBootstrapPolicy.bootstrap(
      state: currentState,
      usesKeychainStorage: usesKeychainStorage,
      loadFromKeychain: { repository.checkvistSyncPlugin.loadRemoteKeyFromKeychain() }
    )
    repository.remoteKey = nextState.remoteKey
    repository.hasAttemptedRemoteKeyBootstrap = nextState.hasAttemptedBootstrap
  }

  @MainActor func toggleDebugKeychainStorageMode() {
    #if DEBUG
      preferences.ignoreKeychainInDebug.toggle()
      repository.errorMessage =
        preferences.ignoreKeychainInDebug
        ? "Dev mode: keychain disabled (no password prompts)."
        : "Dev mode: keychain enabled."
    #endif
  }

  @MainActor func resetOnboardingForDebug() {
    #if DEBUG
      repository.checkvistSyncPlugin.clearAuthentication()
      repository.errorMessage = nil
      let resetState = OnboardingResetPolicy.reset(
        OnboardingResetState(
          remoteKey: repository.remoteKey,
          onboardingCompleted: onboardingService.onboardingCompleted,
          username: repository.username,
          listId: repository.listId,
          availableListsCount: repository.availableLists.count,
          tasksCount: repository.tasks.count,
          currentParentId: navigationState.currentParentId,
          currentSiblingIndex: navigationState.currentSiblingIndex
        ))

      onboardingService.onboardingCompleted = resetState.onboardingCompleted
      repository.username = resetState.username
      repository.listId = resetState.listId
      repository.availableLists = []
      repository.tasks = []
      navigationState.currentParentId = resetState.currentParentId
      navigationState.currentSiblingIndex = resetState.currentSiblingIndex

      preferencesStore.remove(.checkvistUsername)
      preferencesStore.remove(.checkvistListId)
      preferencesStore.remove(.onboardingCompleted)
      preferencesStore.remove(.pluginSelectionOnboardingCompleted)
      onboardingService.dismissedOnboardingDialogs = []
      onboardingService.activeOnboardingDialog = nil
      preferencesStore.remove(.dismissedOnboardingDialogs)
      onboardingService.presentOnboardingDialogIfNeeded()
    #endif
  }

  @MainActor func executeCommandInput(_ input: String) async {
    let parsed = CommandEngine.parse(input)
    logger.log("Executing command: \(input, privacy: .public)")
    await commandExecutor.execute(parsed: parsed)
    if case .unknown(let raw) = parsed {
      logger.error("Unknown command: \(raw, privacy: .public)")
    }
  }

  // Setup is non-blocking: the app can always run in offline-first mode.
  var needsInitialSetup: Bool { false }

  var activePluginSettingsPages: [any PluginSettingsPageProviding] {
    [
      repository.checkvistSyncPlugin as any Plugin,
      integrations.obsidianPlugin as any Plugin,
      integrations.googleCalendarPlugin as any Plugin,
      integrations.mcpIntegrationPlugin as any Plugin,
      dailyLog.plugin as any Plugin,
    ].compactMap { $0 as? any PluginSettingsPageProviding }
  }
}
