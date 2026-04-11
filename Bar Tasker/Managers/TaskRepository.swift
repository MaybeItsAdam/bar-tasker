import Foundation
import Observation
import OSLog

@MainActor
@Observable class TaskRepository {
  @ObservationIgnored private let logger = Logger(
    subsystem: "uk.co.maybeitsadam.bar-tasker", category: "repository")

  // MARK: - Dependencies

  @ObservationIgnored let preferencesStore: BarTaskerPreferencesStore
  @ObservationIgnored let localTaskStore: LocalTaskStore
  @ObservationIgnored let checkvistSyncPlugin: any CheckvistSyncPlugin
  @ObservationIgnored let navigationCoordinator = TaskNavigationCoordinator()
  @ObservationIgnored let reorderQueue = BarTaskerReorderQueue()
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

  // MARK: - Navigation State

  var currentParentId: Int = 0 {
    didSet { onCacheRelevantChange?() }
  }
  var currentSiblingIndex: Int = 0

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
  @ObservationIgnored var offlineArchivedTasksById: [Int: CheckvistTask]
  @ObservationIgnored var nextOfflineTaskIdValue: Int
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
  var currentLevelTasks: [CheckvistTask] {
    tasks.filter { ($0.parentId ?? 0) == currentParentId }
  }

  // MARK: - Init

  // swiftlint:disable function_body_length
  init(
    preferencesStore: BarTaskerPreferencesStore,
    checkvistSyncPlugin: any CheckvistSyncPlugin,
    localTaskStore: LocalTaskStore,
    initialRemoteKey: String
  ) {
    self.preferencesStore = preferencesStore
    self.checkvistSyncPlugin = checkvistSyncPlugin
    self.localTaskStore = localTaskStore
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
    self.offlineArchivedTasksById = Dictionary(
      uniqueKeysWithValues: offlinePayload.archivedTasks.map { ($0.id, $0) })
    self.nextOfflineTaskIdValue = max(offlinePayload.nextTaskId, 1)
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

// MARK: - Offline Helpers

extension TaskRepository {
  func rebuiltTask(
    _ task: CheckvistTask,
    content: String,
    status: Int,
    due: String?,
    position: Int?,
    parentId: Int?,
    level: Int?
  ) -> CheckvistTask {
    CheckvistTask(
      id: task.id,
      content: content,
      status: status,
      due: due,
      position: position,
      parentId: parentId,
      level: level,
      notes: task.notes,
      updatedAt: task.updatedAt
    )
  }

  func archivedOfflineTasks() -> [CheckvistTask] {
    offlineArchivedTasksById.values.sorted { lhs, rhs in
      if lhs.id != rhs.id { return lhs.id < rhs.id }
      return lhs.content < rhs.content
    }
  }

  func normalizeOfflineTasks(_ flatTasks: [CheckvistTask]) -> [CheckvistTask] {
    guard !flatTasks.isEmpty else { return [] }

    let taskById = Dictionary(uniqueKeysWithValues: flatTasks.map { ($0.id, $0) })
    var childrenByParent: [Int: [(index: Int, task: CheckvistTask)]] = [:]

    for (index, task) in flatTasks.enumerated() {
      let parentId = task.parentId ?? 0
      childrenByParent[parentId, default: []].append((index: index, task: task))
    }

    func orderedChildren(for parentId: Int) -> [(index: Int, task: CheckvistTask)] {
      childrenByParent[parentId, default: []].sorted { lhs, rhs in
        let lhsPosition = lhs.task.position ?? Int.max
        let rhsPosition = rhs.task.position ?? Int.max
        if lhsPosition != rhsPosition { return lhsPosition < rhsPosition }
        return lhs.index < rhs.index
      }
    }

    var normalized: [CheckvistTask] = []

    func appendChildren(of parentId: Int, level: Int) {
      let children = orderedChildren(for: parentId)
      for (offset, entry) in children.enumerated() {
        let task = rebuiltTask(
          entry.task,
          content: entry.task.content,
          status: entry.task.status,
          due: entry.task.due,
          position: offset + 1,
          parentId: parentId == 0 ? nil : parentId,
          level: level
        )
        normalized.append(task)
        appendChildren(of: task.id, level: level + 1)
      }
    }

    let missingParentIds = Set(flatTasks.compactMap { $0.parentId }.filter { taskById[$0] == nil })
    let rootParentIds = Set([0]).union(missingParentIds).sorted()

    for rootId in rootParentIds {
      appendChildren(of: rootId, level: 0)
    }

    return normalized
  }

  @MainActor func nextOfflineTaskId() -> Int {
    let nextId = max(nextOfflineTaskIdValue, 1)
    nextOfflineTaskIdValue = nextId + 1
    return nextId
  }

  func nextOptimisticTaskId() -> Int {
    -Int.random(in: 1...1_000_000)
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
