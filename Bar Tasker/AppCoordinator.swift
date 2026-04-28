import AppKit
import Foundation
import OSLog
import Observation
import ServiceManagement
import SwiftUI

@MainActor
@Observable class AppCoordinator {
  @ObservationIgnored let logger = Logger(
    subsystem: "uk.co.maybeitsadam.bar-tasker", category: "manager")

  let repository: TaskRepository
  let feedbackService: FeedbackService

  let navigationState: NavigationState

  var tasks: [CheckvistTask] {
    get { repository.tasks }
    set { repository.tasks = newValue }
  }
  var currentParentId: Int {
    get { navigationState.currentParentId }
    set {
      navigationState.currentParentId = newValue
      invalidateCaches()
    }
  }
  var currentSiblingIndex: Int {
    get { navigationState.currentSiblingIndex }
    set { navigationState.currentSiblingIndex = newValue }
  }
  var rootScopeFocusLevel: Int {
    get { navigationState.rootScopeFocusLevel }
    set { navigationState.rootScopeFocusLevel = newValue }
  }
  var listId: String {
    get { repository.listId }
    set { repository.listId = newValue }
  }
    var statusMessage: String? = nil {
    didSet {
      if statusMessage != nil {
        Task { @MainActor in
          try? await Task.sleep(for: .seconds(3))
          self.statusMessage = nil
        }
      }
    }
  }
  var errorMessage: String? {
    get { repository.errorMessage }
    set { repository.errorMessage = newValue }
  }
  var lastUndo: UndoableAction? {
    get { repository.lastUndo }
    set { repository.lastUndo = newValue }
  }

  var hideFuture: Bool {
    get { taskListViewModel.hideFuture }
    set { taskListViewModel.hideFuture = newValue }
  }
  var showChildrenInMenus: Bool {
    get { taskListViewModel.showChildrenInMenus }
    set { taskListViewModel.showChildrenInMenus = newValue }
  }
  var rootTaskView: RootTaskView {
    get { taskListViewModel.rootTaskView }
    set {
      taskListViewModel.rootTaskView = newValue
      preferencesStore.set(newValue.rawValue, for: .rootTaskView)
    }
  }
  var selectedRootDueBucketRawValue: Int {
    get { taskListViewModel.selectedRootDueBucketRawValue }
    set {
      taskListViewModel.selectedRootDueBucketRawValue = newValue
      preferencesStore.set(newValue, for: .selectedRootDueBucketRawValue)
    }
  }
  var selectedRootTag: String {
    get { taskListViewModel.selectedRootTag }
    set {
      taskListViewModel.selectedRootTag = newValue
      preferencesStore.set(newValue, for: .selectedRootTag)
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

  let preferences: PreferencesManager
  var onboardingCompleted: Bool {
    didSet { preferencesStore.set(onboardingCompleted, for: .onboardingCompleted) }
  }
  var activeOnboardingDialog: OnboardingDialog?

  @ObservationIgnored var dismissedOnboardingDialogs: Set<OnboardingDialog>

  var cache: CacheState {
    taskListViewModel.cache
  }

  var taskEisenhowerLevels: [Int: EisenhowerLevel] {
    repository.taskEisenhowerLevels
  }

  @ObservationIgnored var isApplyingLaunchAtLoginChange = false
  @ObservationIgnored let preferencesStore = PreferencesStore()
  let userPluginManager: UserPluginManager
  @ObservationIgnored lazy var commandExecutor = CommandExecutor(manager: self)
  @ObservationIgnored let reachabilityMonitor = NetworkReachabilityMonitor()
  var usesKeychainStorage: Bool { false }

  var activeCredentials: CheckvistCredentials {
    CheckvistCredentials(username: username, remoteKey: remoteKey)
  }

  var username: String {
    get { repository.username }
    set { repository.username = newValue }
  }
  var usernameLower: String { username.lowercased() }

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

    self.userPluginManager = UserPluginManager(
      builtInPluginIdentifiers: [
        resolvedCheckvistSyncPlugin.pluginIdentifier,
        resolvedObsidianPlugin.pluginIdentifier,
        resolvedGoogleCalendarPlugin.pluginIdentifier,
        resolvedMCPIntegrationPlugin.pluginIdentifier,
      ]
    )
    self.preferences = PreferencesManager(preferencesStore: preferencesStore)

    let initialRemoteKey = resolvedCheckvistSyncPlugin.startupRemoteKey(
      useKeychainStorageAtInit: false)

    let navigationState = NavigationState()
    self.navigationState = navigationState

    // Create task repository with all task-related state
    let repository = TaskRepository(
      preferencesStore: preferencesStore,
      checkvistSyncPlugin: resolvedCheckvistSyncPlugin,
      localTaskStore: resolvedLocalTaskStore,
      initialRemoteKey: initialRemoteKey
    )
    self.repository = repository

    let storedListId = preferencesStore.string(.checkvistListId)
    let storedUsername = preferencesStore.string(.checkvistUsername)
    let storedOnboardingCompletedFlag = preferencesStore.optionalBool(.onboardingCompleted)
    let storedPluginSelectionOnboardingCompletedFlag = preferencesStore.optionalBool(
      .pluginSelectionOnboardingCompleted)

    self.kanban = KanbanManager(preferencesStore: preferencesStore)
    self.focusSessionManager = FocusSessionManager(preferencesStore: preferencesStore)
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
    let timer = TimerManager(preferencesStore: preferencesStore)
    self.timer = timer
    self.startDates = StartDateManager(preferencesStore: preferencesStore)
    self.recurrence = RecurrenceManager(preferencesStore: preferencesStore)
    let quickEntry = QuickEntryManager()
    self.quickEntry = quickEntry
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

    self.taskListViewModel = TaskListViewModel(
      repository: repository,
      navigationState: navigationState,
      timer: timer,
      quickEntry: quickEntry
    )

    self.rootTaskView =
      RootTaskView(rawValue: preferencesStore.int(.rootTaskView, default: 1)) ?? .due
    self.selectedRootDueBucketRawValue = preferencesStore.int(
      .selectedRootDueBucketRawValue, default: -1)
    self.selectedRootTag = preferencesStore.string(.selectedRootTag)
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

extension AppCoordinator: KanbanTaskDataSource {}

extension AppCoordinator: IntegrationDataSource {}

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
    guard !listId.isEmpty else {
      errorMessage = "Choose a Checkvist list in Preferences to add tasks."
      return
    }

    let (content, due) = kanban.contentAndDueForNewTask(rawContent: trimmed, in: column)

    // Optimistic local insert
    let optimisticId = -Int.random(in: 1...1_000_000)
    let optimisticTask = CheckvistTask(
      id: optimisticId, content: content, status: 0, due: due,
      position: nil, parentId: nil, level: nil
    )
    tasks.append(optimisticTask)
    kanban.kanbanSelectedTaskId = optimisticId

    let listId = self.listId
    let credentials = self.activeCredentials
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
            self.lastUndo = .add(taskId: newTask.id)
            // Replace optimistic task with the real one.
            if let idx = self.tasks.firstIndex(where: { $0.id == optimisticId }) {
              self.tasks[idx] = CheckvistTask(
                id: newTask.id, content: content, status: 0, due: due,
                position: newTask.position, parentId: nil, level: nil
              )
            }
            self.kanban.kanbanSelectedTaskId = newTask.id
          } else {
            self.tasks.removeAll { $0.id == optimisticId }
            self.errorMessage = "Failed to add task."
          }
        }
      } catch {
        await MainActor.run { [weak self] in
          self?.tasks.removeAll { $0.id == optimisticId }
          self?.errorMessage = "Error adding task: \(error.localizedDescription)"
        }
      }
    }
  }

  /// Applies the move locally (immediate) and syncs to the server in the background.
  @MainActor private func applyOptimisticMoveAndSync(
    task: CheckvistTask, content: String?, due: String?
  ) {
    lastUndo = .update(taskId: task.id, oldContent: task.content, oldDue: task.due)

    guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
    let originalTask = tasks[index]
    tasks[index] = CheckvistTask(
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

    let listId = self.listId
    let credentials = self.activeCredentials
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
            if let idx = self.tasks.firstIndex(where: { $0.id == taskId }) {
              self.tasks[idx] = originalTask
            }
            self.errorMessage = "Failed to sync task move."
          }
        }
      } catch {
        await MainActor.run { [weak self] in
          guard let self else { return }
          if !self.repository.isNetworkReachable {
            self.repository.pendingTaskMutations[taskId] = (content: content, due: due)
          } else if let idx = self.tasks.firstIndex(where: { $0.id == taskId }) {
            self.tasks[idx] = originalTask
            self.errorMessage = "Failed to sync task move."
          }
        }
      }
    }
  }
}
