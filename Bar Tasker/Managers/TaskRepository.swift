import Foundation
import OSLog
import Observation

@MainActor
@Observable class TaskRepository {
  @ObservationIgnored private let logger = Logger(
    subsystem: "uk.co.maybeitsadam.bar-tasker", category: "repository")

  // MARK: - Dependencies

  @ObservationIgnored let preferencesStore: PreferencesStore
  @ObservationIgnored let localTaskStore: LocalTaskStore
  @ObservationIgnored let checkvistSyncPlugin: any CheckvistSyncPlugin
  @ObservationIgnored let offlineSyncPlugin: OfflineTaskSyncPlugin
  @ObservationIgnored let navigationCoordinator = TaskNavigationCoordinator()
  @ObservationIgnored let reorderQueue = ReorderQueue()
  @ObservationIgnored let priorityQueueStore: ListScopedTaskIDStore

  // MARK: - Callbacks

  @ObservationIgnored var onCacheRelevantChange: (() -> Void)?
  @ObservationIgnored var onUsernameChanged: (() -> Void)?
  @ObservationIgnored var onRemoteKeyChanged: ((String) -> Void)?
  @ObservationIgnored var onListIdChanged: ((String) -> Void)?

  // MARK: - Constants

  static let maxPriorityRank = 9
  private static let priorityQueuesDefaultsKey = "priorityTaskIdsByListId"

  // MARK: - Task Data

  var tasks: [CheckvistTask] = [] {
    didSet { onCacheRelevantChange?() }
  }
  var availableLists: [CheckvistList] = []

  // MARK: - Auth / Connection

  var username: String {
    didSet {
      preferencesStore.set(username, for: .checkvistUsername)
      onUsernameChanged?()
    }
  }
  var remoteKey: String {
    didSet {
      guard remoteKey != oldValue else { return }
      onRemoteKeyChanged?(remoteKey)
    }
  }
  var listId: String {
    didSet {
      preferencesStore.set(listId, for: .checkvistListId)
      loadPriorityQueue(for: listId)
      onListIdChanged?(listId)
    }
  }

  // MARK: - UI State

  var isLoading: Bool = false
  var errorMessage: String? = nil
  var isNetworkReachable: Bool = true

  // MARK: - Undo

  var lastUndo: UndoableAction? = nil

  // MARK: - Priority

  var priorityTaskIds: [Int] {
    didSet { onCacheRelevantChange?() }
  }

  // MARK: - Offline State

  @ObservationIgnored var pendingTaskMutations: [Int: (content: String?, due: String?)] = [:]
  @ObservationIgnored var loadingOperationCount: Int = 0
  @ObservationIgnored var hasAttemptedRemoteKeyBootstrap: Bool = false

  // MARK: - Computed Properties

  var hasCredentials: Bool {
    !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !remoteKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  var canAttemptLogin: Bool { hasCredentials }
  var hasListSelection: Bool {
    !listId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  var isUsingOfflineStore: Bool { !hasListSelection }
  var offlineOpenTaskCount: Int { localTaskStore.load().openTasks.count }
  var activeCredentials: CheckvistCredentials {
    CheckvistCredentials(username: username, remoteKey: remoteKey)
  }
  var activeSyncPlugin: any CheckvistSyncPlugin {
    isUsingOfflineStore ? offlineSyncPlugin : checkvistSyncPlugin
  }

  // MARK: - Init

  // swiftlint:disable function_body_length
  init(
    preferencesStore: PreferencesStore,
    checkvistSyncPlugin: any CheckvistSyncPlugin,
    localTaskStore: LocalTaskStore,
    initialRemoteKey: String
  ) {
    self.preferencesStore = preferencesStore
    self.checkvistSyncPlugin = checkvistSyncPlugin
    self.localTaskStore = localTaskStore
    self.offlineSyncPlugin = OfflineTaskSyncPlugin(localStore: localTaskStore)
    self.priorityQueueStore = ListScopedTaskIDStore(
      defaultsKey: Self.priorityQueuesDefaultsKey,
      maximumCount: Self.maxPriorityRank
    )

    let offlinePayload = localTaskStore.load()
    let storedUsername = preferencesStore.string(.checkvistUsername)
    let storedListId = preferencesStore.string(.checkvistListId)

    self.username = storedUsername
    self.listId = storedListId
    self.remoteKey = initialRemoteKey
    self.tasks =
      storedListId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? offlinePayload.openTasks : []
    self.priorityTaskIds = priorityQueueStore.load(for: storedListId)
  }
  // swiftlint:enable function_body_length
}

// MARK: - Loading Helpers

extension TaskRepository {
  @MainActor func beginLoading() {
    loadingOperationCount += 1
    isLoading = true
  }

  @MainActor func endLoading() {
    loadingOperationCount = max(loadingOperationCount - 1, 0)
    isLoading = loadingOperationCount > 0
  }

  @MainActor func withLoadingState<T>(_ operation: () async throws -> T) async rethrows -> T {
    beginLoading()
    defer { endLoading() }
    return try await operation()
  }

  @MainActor func setAuthenticationRequiredErrorIfNeeded() {
    if errorMessage == nil {
      errorMessage = "Authentication required."
    }
  }

  @MainActor func runBooleanMutation(
    failureMessage: String,
    errorMessageBuilder: @escaping (Error) -> String = { "Error: \($0.localizedDescription)" },
    action: () async throws -> Bool,
    onSuccess: @MainActor () async -> Void
  ) async {
    do {
      let success = try await action()
      if success {
        await onSuccess()
      } else {
        errorMessage = failureMessage
      }
    } catch CheckvistSessionError.authenticationUnavailable {
      setAuthenticationRequiredErrorIfNeeded()
    } catch {
      self.errorMessage = errorMessageBuilder(error)
    }
  }
}

// MARK: - Priority Queue

extension TaskRepository {
  static func normalizedTaskIdQueue(_ queue: [Int], maximumCount: Int? = nil) -> [Int] {
    var seen = Set<Int>()
    var normalized: [Int] = []
    for taskId in queue where taskId > 0 && !seen.contains(taskId) {
      seen.insert(taskId)
      normalized.append(taskId)
    }
    if let maximumCount, normalized.count > maximumCount {
      return Array(normalized.prefix(maximumCount))
    }
    return normalized
  }

  func loadPriorityQueue(for listId: String) {
    priorityTaskIds = priorityQueueStore.load(for: listId)
  }

  func savePriorityQueue(_ queue: [Int]) {
    let normalized = Self.normalizedTaskIdQueue(queue, maximumCount: Self.maxPriorityRank)
    priorityTaskIds = normalized
    guard !listId.isEmpty else { return }
    priorityQueueStore.save(normalized, for: listId)
  }

  @MainActor func removeTasksFromPriorityQueue(_ taskIds: Set<Int>) {
    guard !taskIds.isEmpty else { return }
    let filtered = priorityTaskIds.filter { !taskIds.contains($0) }
    guard filtered != priorityTaskIds else { return }
    savePriorityQueue(filtered)
  }

  @MainActor func reconcilePriorityQueueWithOpenTasks() {
    let openTaskIds = Set(tasks.map(\.id))
    let filtered = priorityTaskIds.filter { openTaskIds.contains($0) }
    if filtered != priorityTaskIds {
      savePriorityQueue(filtered)
    }
  }
}

// MARK: - API

extension TaskRepository {
  @MainActor func login() async -> Bool {
    let credentials = activeCredentials
    guard !credentials.normalizedUsername.isEmpty, !credentials.normalizedRemoteKey.isEmpty else {
      errorMessage = "Username or Remote Key is missing."
      return false
    }

    errorMessage = nil

    do {
      return try await withLoadingState {
        let success = try await checkvistSyncPlugin.login(credentials: credentials)
        guard success else {
          errorMessage = "Login failed. Check your credentials."
          return false
        }
        return true
      }
    } catch {
      errorMessage = "Network error: \(error.localizedDescription)"
      return false
    }
  }

  @MainActor func fetchLists() async -> Bool {
    do {
      let lists = try await checkvistSyncPlugin.fetchLists(credentials: activeCredentials)
      self.availableLists = lists
      return true
    } catch CheckvistSessionError.authenticationUnavailable {
      setAuthenticationRequiredErrorIfNeeded()
      return false
    } catch {
      self.errorMessage = "Failed to fetch lists: \(error.localizedDescription)"
      return false
    }
  }

  @MainActor func loadCheckvistLists(assignFirstIfMissing: Bool = false) async -> Bool {
    let success = await login()
    guard success else { return false }
    let didFetchLists = await fetchLists()
    guard didFetchLists else { return false }

    if assignFirstIfMissing, listId.isEmpty, let first = availableLists.first {
      listId = String(first.id)
    }
    return true
  }

  @MainActor func selectList(_ list: CheckvistList) {
    listId = String(list.id)
  }

  func copyTasks(_ sourceTasks: [CheckvistTask], to destinationListId: String) async throws
    -> (mergedCount: Int, skippedCount: Int)
  {
    var migratedBySourceTaskID: [Int: Int] = [:]
    var mergedCount = 0
    var skippedCount = 0

    for sourceTask in sourceTasks {
      let resolvedParentID = sourceTask.parentId.flatMap { migratedBySourceTaskID[$0] }
      guard
        let created = try await checkvistSyncPlugin.createTask(
          listId: destinationListId,
          content: sourceTask.content,
          parentId: resolvedParentID,
          position: nil,
          credentials: activeCredentials
        )
      else {
        skippedCount += 1
        continue
      }

      migratedBySourceTaskID[sourceTask.id] = created.id
      if let due = sourceTask.due, !due.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        _ = try await checkvistSyncPlugin.updateTask(
          listId: destinationListId,
          taskId: created.id,
          content: nil,
          due: due,
          credentials: activeCredentials
        )
      }
      mergedCount += 1
    }

    return (mergedCount, skippedCount)
  }
}
