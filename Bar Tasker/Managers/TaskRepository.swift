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
  @ObservationIgnored let priorityQueueStore: ListScopedPriorityStore
  @ObservationIgnored let absolutePriorityQueueStore: ListScopedTaskIDStore
  @ObservationIgnored let legacyPriorityQueueStore: ListScopedTaskIDStore

  // MARK: - Callbacks

  @ObservationIgnored var onCacheRelevantChange: (() -> Void)?
  @ObservationIgnored var onUsernameChanged: (() -> Void)?
  @ObservationIgnored var onRemoteKeyChanged: ((String) -> Void)?
  @ObservationIgnored var onListIdChanged: ((String) -> Void)?

  // MARK: - Constants

  /// Keyboard rank bounds (1...9); also used by legacy migration.
  static let maxPriorityRank = 9
  private static let priorityQueuesDefaultsKey = "priorityTaskIdsByListId"
  private static let scopedPriorityQueuesDefaultsKey = "priorityTaskIdsByParentIdByListId"
  private static let absolutePriorityQueuesDefaultsKey = "absolutePriorityTaskIdsByListId"

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
      loadAbsolutePriorityQueue(for: listId)
      onListIdChanged?(listId)
    }
  }
  var checkvistIntegrationEnabled: Bool {
    didSet {
      guard checkvistIntegrationEnabled != oldValue else { return }
      preferencesStore.set(checkvistIntegrationEnabled, for: .checkvistIntegrationEnabled)
      onCheckvistIntegrationEnabledChanged?()
    }
  }
  @ObservationIgnored var onCheckvistIntegrationEnabledChanged: (() -> Void)?

  // MARK: - UI State

  var isLoading: Bool = false
  var errorMessage: String? = nil
  var isNetworkReachable: Bool = true

  // MARK: - Undo

  var lastUndo: UndoableAction? = nil

  // MARK: - Priority

  /// Per-parent priority queues. Key = parent task id (0 = root). No cap per scope.
  var priorityTaskIdsByParentId: [Int: [Int]] {
    didSet { onCacheRelevantChange?() }
  }

  /// Convenience: flattened set of all prioritized task ids across every scope.
  var prioritizedTaskIds: Set<Int> {
    Set(priorityTaskIdsByParentId.values.flatMap { $0 })
  }
  /// Global absolute-priority queue across all tasks in the list.
  var absolutePriorityTaskIds: [Int] {
    didSet { onCacheRelevantChange?() }
  }
  var absolutePrioritizedTaskIds: Set<Int> {
    Set(absolutePriorityTaskIds)
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
  var isUsingOfflineStore: Bool { !checkvistIntegrationEnabled || !hasListSelection }
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
    self.priorityQueueStore = ListScopedPriorityStore(
      defaultsKey: Self.scopedPriorityQueuesDefaultsKey
    )
    self.absolutePriorityQueueStore = ListScopedTaskIDStore(
      defaultsKey: Self.absolutePriorityQueuesDefaultsKey
    )
    self.legacyPriorityQueueStore = ListScopedTaskIDStore(
      defaultsKey: Self.priorityQueuesDefaultsKey,
      maximumCount: Self.maxPriorityRank
    )

    let offlinePayload = localTaskStore.load()
    let storedUsername = preferencesStore.string(.checkvistUsername)
    let storedListId = preferencesStore.string(.checkvistListId)

    let hasLegacyCheckvist =
      !storedUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !storedListId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let storedIntegrationEnabled = preferencesStore.optionalBool(.checkvistIntegrationEnabled)
    let resolvedIntegrationEnabled = storedIntegrationEnabled ?? hasLegacyCheckvist

    self.checkvistIntegrationEnabled = resolvedIntegrationEnabled
    self.username = storedUsername
    self.listId = storedListId
    self.remoteKey = initialRemoteKey
    let isOfflineAtLaunch =
      !resolvedIntegrationEnabled
      || storedListId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    self.tasks = isOfflineAtLaunch ? offlinePayload.openTasks : []
    self.priorityTaskIdsByParentId = Self.loadScopedPriorities(
      scoped: priorityQueueStore,
      legacy: legacyPriorityQueueStore,
      listId: storedListId
    )
    self.absolutePriorityTaskIds = absolutePriorityQueueStore.load(for: storedListId)
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

  static func loadScopedPriorities(
    scoped: ListScopedPriorityStore,
    legacy: ListScopedTaskIDStore,
    listId: String
  ) -> [Int: [Int]] {
    let byParent = scoped.load(for: listId)
    if !byParent.isEmpty { return byParent }
    let legacyFlat = legacy.load(for: listId)
    guard !legacyFlat.isEmpty else { return [:] }
    // Migrate the legacy flat queue to root-scope. We don't have parentId info at this
    // point (tasks not loaded yet), so drop the legacy key into root. Re-scoping happens
    // on the next reconcile once tasks are loaded.
    return [0: legacyFlat]
  }

  func loadPriorityQueue(for listId: String) {
    priorityTaskIdsByParentId = Self.loadScopedPriorities(
      scoped: priorityQueueStore,
      legacy: legacyPriorityQueueStore,
      listId: listId
    )
  }

  func savePriorityQueue(_ queues: [Int: [Int]]) {
    var normalized: [Int: [Int]] = [:]
    for (parentId, ids) in queues {
      let dedup = ListScopedPriorityStore.normalizedQueue(ids)
      if !dedup.isEmpty { normalized[parentId] = dedup }
    }
    priorityTaskIdsByParentId = normalized
    guard !listId.isEmpty else { return }
    priorityQueueStore.save(normalized, for: listId)
  }

  func loadAbsolutePriorityQueue(for listId: String) {
    absolutePriorityTaskIds = absolutePriorityQueueStore.load(for: listId)
  }

  func saveAbsolutePriorityQueue(_ queue: [Int]) {
    let normalized = Self.normalizedTaskIdQueue(queue)
    absolutePriorityTaskIds = normalized
    guard !listId.isEmpty else { return }
    absolutePriorityQueueStore.save(normalized, for: listId)
  }

  @MainActor func setAbsolutePriority(taskId: Int, rank: Int) {
    guard taskId > 0, rank >= 1 else { return }
    var queue = absolutePriorityTaskIds.filter { $0 != taskId }
    let insertIndex = min(max(rank - 1, 0), queue.count)
    queue.insert(taskId, at: insertIndex)
    saveAbsolutePriorityQueue(queue)
  }

  @MainActor func clearAbsolutePriority(taskId: Int) {
    guard taskId > 0 else { return }
    guard absolutePriorityTaskIds.contains(taskId) else { return }
    saveAbsolutePriorityQueue(absolutePriorityTaskIds.filter { $0 != taskId })
  }

  @MainActor func removeTasksFromPriorityQueue(_ taskIds: Set<Int>) {
    guard !taskIds.isEmpty else { return }
    var changed = false
    var updated = priorityTaskIdsByParentId
    for (parentId, ids) in updated {
      let filtered = ids.filter { !taskIds.contains($0) }
      if filtered.count != ids.count {
        changed = true
        if filtered.isEmpty {
          updated.removeValue(forKey: parentId)
        } else {
          updated[parentId] = filtered
        }
      }
    }
    let filteredAbsolute = absolutePriorityTaskIds.filter { !taskIds.contains($0) }
    if filteredAbsolute.count != absolutePriorityTaskIds.count {
      changed = true
    }
    guard changed else { return }
    savePriorityQueue(updated)
    if filteredAbsolute != absolutePriorityTaskIds {
      saveAbsolutePriorityQueue(filteredAbsolute)
    }
  }

  @MainActor func reconcilePriorityQueueWithOpenTasks() {
    let tasksById = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
    let openTaskIds = Set(tasks.map(\.id))
    var updated: [Int: [Int]] = [:]
    var changed = false
    for (parentId, ids) in priorityTaskIdsByParentId {
      for id in ids {
        guard openTaskIds.contains(id) else { changed = true; continue }
        // Re-scope each task under its *actual* current parent. This keeps stored
        // queues coherent if a task was moved, and also normalizes legacy-migrated
        // queues that all landed under root scope.
        let actualParent = tasksById[id]?.parentId ?? 0
        if actualParent != parentId { changed = true }
        updated[actualParent, default: []].append(id)
      }
    }
    if changed {
      savePriorityQueue(updated)
    }

    let filteredAbsolute = absolutePriorityTaskIds.filter { openTaskIds.contains($0) }
    if filteredAbsolute != absolutePriorityTaskIds {
      saveAbsolutePriorityQueue(filteredAbsolute)
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
