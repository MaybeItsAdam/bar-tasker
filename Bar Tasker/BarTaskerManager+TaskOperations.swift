import AppKit
import OSLog
import SwiftUI

extension BarTaskerManager {
  // MARK: - Navigation

  @MainActor func nextTask() {
    guard
      let nextIndex = navigationCoordinator.nextSiblingIndex(
        currentSiblingIndex: currentSiblingIndex,
        visibleCount: visibleTasks.count)
    else { return }
    currentSiblingIndex = nextIndex
  }

  @MainActor func previousTask() {
    guard
      let previousIndex = navigationCoordinator.previousSiblingIndex(
        currentSiblingIndex: currentSiblingIndex,
        visibleCount: visibleTasks.count)
    else { return }
    currentSiblingIndex = previousIndex
  }

  /// Navigate into the current task's children
  @MainActor func enterChildren() {
    guard
      let selection = navigationCoordinator.enterChildren(
        currentTask: currentTask,
        childCount: currentTaskChildren.count)
    else { return }
    rootScopeFocusLevel = selection.rootScopeFocusLevel
    currentParentId = selection.currentParentId
    currentSiblingIndex = selection.currentSiblingIndex
  }

  /// Navigate back up to the parent level
  @MainActor func exitToParent() {
    guard
      let selection = navigationCoordinator.exitToParent(
        currentParentId: currentParentId,
        tasks: tasks)
    else { return }
    rootScopeFocusLevel = selection.rootScopeFocusLevel
    currentParentId = selection.currentParentId
    currentSiblingIndex = selection.currentSiblingIndex
  }

  @MainActor func navigateTo(task: CheckvistTask) {
    let selection = navigationCoordinator.navigate(to: task, tasks: tasks)
    rootScopeFocusLevel = selection.rootScopeFocusLevel
    currentParentId = selection.currentParentId
    currentSiblingIndex = selection.currentSiblingIndex
  }

  // MARK: - Offline Store

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

  @MainActor func offlineStateSnapshot() -> OfflineTaskStateSnapshot {
    OfflineTaskStateSnapshot(
      openTasks: tasks,
      archivedTasks: archivedOfflineTasks(),
      nextTaskId: nextOfflineTaskIdValue,
      currentParentId: currentParentId,
      currentSiblingIndex: currentSiblingIndex,
      priorityTaskIds: priorityTaskIds,
      pendingObsidianSyncTaskIds: pendingObsidianSyncTaskIds,
      timerByTaskId: timerByTaskId,
      timedTaskId: timedTaskId,
      timerRunning: timerRunning
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
      let parentId = task.parentId.flatMap { taskById[$0] != nil ? $0 : nil } ?? 0
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

    appendChildren(of: 0, level: 0)
    return normalized
  }

  @MainActor func nextOfflineTaskId() -> Int {
    let nextId = max(nextOfflineTaskIdValue, 1)
    nextOfflineTaskIdValue = nextId + 1
    return nextId
  }

  @MainActor func persistOfflineTaskState() {
    tasks = normalizeOfflineTasks(tasks)

    let openTaskIds = Set(tasks.map(\.id))
    offlineArchivedTasksById = offlineArchivedTasksById.filter { !openTaskIds.contains($0.key) }

    localTaskStore.save(
      OfflineTaskStorePayload(
        openTasks: tasks,
        archivedTasks: archivedOfflineTasks(),
        nextTaskId: max(nextOfflineTaskIdValue, (openTaskIds.max() ?? 0) + 1)
      ))

    reconcilePriorityQueueWithOpenTasks()
    reconcilePendingObsidianSyncQueueWithOpenTasks()

    if currentParentId != 0 && !openTaskIds.contains(currentParentId) {
      currentParentId = 0
    }

    if let activeTimerTaskId = timedTaskId, !openTaskIds.contains(activeTimerTaskId) {
      stopTimer()
    }

    clampSelectionToVisibleRange()
  }

  @MainActor func restoreOfflineState(_ snapshot: OfflineTaskStateSnapshot) {
    tasks = normalizeOfflineTasks(snapshot.openTasks)
    offlineArchivedTasksById = Dictionary(
      uniqueKeysWithValues: snapshot.archivedTasks.map { ($0.id, $0) })
    nextOfflineTaskIdValue = max(snapshot.nextTaskId, 1)
    currentParentId = snapshot.currentParentId
    currentSiblingIndex = snapshot.currentSiblingIndex
    savePriorityQueue(snapshot.priorityTaskIds)
    savePendingObsidianSyncQueue(snapshot.pendingObsidianSyncTaskIds)
    timerByTaskId = snapshot.timerByTaskId
    timedTaskId = snapshot.timedTaskId
    if snapshot.timerRunning, timedTaskId != nil {
      resumeTimer()
    } else {
      pauseTimer()
    }
    persistOfflineTaskState()
  }

  // MARK: - API

  @MainActor func login() async -> Bool {
    loadRemoteKeyFromKeychainIfNeeded()
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

  @MainActor func fetchTopTask() async {
    if isUsingOfflineStore {
      errorMessage = nil
      let payload = localTaskStore.load()
      tasks = normalizeOfflineTasks(payload.openTasks)
      offlineArchivedTasksById = Dictionary(
        uniqueKeysWithValues: payload.archivedTasks.map { ($0.id, $0) })
      let maxKnownTaskId = max(
        tasks.map(\.id).max() ?? 0,
        payload.archivedTasks.map(\.id).max() ?? 0
      )
      nextOfflineTaskIdValue = max(payload.nextTaskId, maxKnownTaskId + 1, 1)
      reconcilePriorityQueueWithOpenTasks()
      reconcilePendingObsidianSyncQueueWithOpenTasks()
      clampSelectionToVisibleRange()
      if let activeTimerTaskId = timedTaskId, !Set(tasks.map(\.id)).contains(activeTimerTaskId) {
        stopTimer()
      }
      return
    }

    guard !listId.isEmpty else { return }

    errorMessage = nil

    do {
      try await withLoadingState {
        let previousTasks = self.tasks
        let fetchedTasks = try await checkvistSyncPlugin.fetchOpenTasks(
          listId: listId,
          credentials: activeCredentials
        )

        self.tasks = fetchedTasks
        checkvistSyncPlugin.persistTaskCache(listId: listId, tasks: fetchedTasks)
        reconcilePriorityQueueWithOpenTasks()
        reconcilePendingObsidianSyncQueueWithOpenTasks()
        if currentSiblingIndex >= fetchedTasks.count { currentSiblingIndex = 0 }
        let latestOpenTaskIDs = Set(fetchedTasks.map(\.id))
        let previousTimerNodes = previousTasks.map {
          BarTaskerTimerNode(id: $0.id, parentId: $0.parentId)
        }
        self.timerByTaskId = TimerElapsedReassignmentPolicy.remapElapsed(
          previousNodes: previousTimerNodes,
          latestOpenTaskIDs: latestOpenTaskIDs,
          elapsedByTaskID: self.timerByTaskId
        )
        if let activeTimerTaskID = timedTaskId, !latestOpenTaskIDs.contains(activeTimerTaskID) {
          stopTimer()
        }
        if !listId.isEmpty && canAttemptLogin {
          onboardingCompleted = true
        }
      }
    } catch CheckvistSessionError.authenticationUnavailable {
      setAuthenticationRequiredErrorIfNeeded()
    } catch {
      logger.error("Fetch tasks failed: \(error.localizedDescription, privacy: .public)")
      errorMessage = "Failed to fetch tasks: \(error.localizedDescription)"
    }
  }

  @MainActor func markCurrentTaskDone() async {
    guard let task = currentTask else { return }
    // Multi-step haptic pattern for stronger tactile feedback.
    // Each sleep must propagate CancellationError so that navigating away
    // or switching tasks stops the sequence before taskAction fires.
    do {
      NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
      try await Task.sleep(nanoseconds: 60_000_000)
      NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
      // Spring the checkmark in.
      withAnimation(.spring(response: 0.28, dampingFraction: 0.45)) { completingTaskId = task.id }
      // Confirmation tap.
      try await Task.sleep(nanoseconds: 120_000_000)
      NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
      // Hold so strikethrough and pulse are visible.
      try await Task.sleep(nanoseconds: 360_000_000)
    } catch {
      // Cancelled — clean up animation state and bail out without completing.
      withAnimation { completingTaskId = nil }
      return
    }
    withAnimation { completingTaskId = nil }
    await taskAction(task, endpoint: "close")
    await createNextOccurrence(for: task)
  }

  /// POST to a Checkvist task action endpoint (close, reopen, invalidate)
  @MainActor private func taskAction(_ task: CheckvistTask, endpoint: String, isUndo: Bool = false)
    async
  {
    if isUsingOfflineStore {
      guard endpoint == "close" || endpoint == "invalidate" else { return }
      guard let removingRange = subtreeBlockRange(for: task.id, in: tasks) else { return }

      let removedTasks = Array(tasks[removingRange])
      let removedTaskIds = Set(removedTasks.map(\.id))
      let snapshot = offlineStateSnapshot()
      let archivedStatus = endpoint == "invalidate" ? -1 : 1

      tasks.removeSubrange(removingRange)
      for removedTask in removedTasks {
        let archivedTask = rebuiltTask(
          removedTask,
          content: removedTask.content,
          status: archivedStatus,
          due: removedTask.due,
          position: removedTask.position,
          parentId: removedTask.parentId,
          level: removedTask.level
        )
        offlineArchivedTasksById[removedTask.id] = archivedTask
      }
      timerByTaskId = timerByTaskId.filter { !removedTaskIds.contains($0.key) }
      removeTasksFromPriorityQueue(removedTaskIds)
      savePendingObsidianSyncQueue(
        pendingObsidianSyncTaskIds.filter { !removedTaskIds.contains($0) })
      persistOfflineTaskState()
      if !isUndo {
        lastUndo = .restoreOfflineState(snapshot: snapshot)
      }
      errorMessage = nil
      return
    }

    if !isUndo {
      if endpoint == "close" {
        lastUndo = .markDone(taskId: task.id)
      } else if endpoint == "invalidate" {
        lastUndo = .invalidate(taskId: task.id)
      }
    }

    guard let action = CheckvistTaskAction(rawValue: endpoint) else { return }
    let ancestorTaskIDsToKeepOpen =
      (!isUndo && endpoint == "close") ? ancestorTaskIDs(for: task, in: tasks) : []

    let optimisticSnapshot: OptimisticCompletionSnapshot? =
      (!isUndo && (endpoint == "close" || endpoint == "invalidate"))
      ? applyOptimisticCompletion(for: task.id) : nil

    do {
      let success = try await checkvistSyncPlugin.performTaskAction(
        listId: listId,
        taskId: task.id,
        action: action,
        credentials: activeCredentials
      )
      if success {
        await fetchTopTask()
        if !ancestorTaskIDsToKeepOpen.isEmpty {
          let reopenedAny = await reopenMissingAncestorTasksIfNeeded(ancestorTaskIDsToKeepOpen)
          if reopenedAny {
            await fetchTopTask()
          }
        }
      } else {
        if let optimisticSnapshot {
          restoreTasksSnapshot(optimisticSnapshot)
        }
        errorMessage = "Failed to \(endpoint) task."
      }
    } catch CheckvistSessionError.authenticationUnavailable {
      if let optimisticSnapshot {
        restoreTasksSnapshot(optimisticSnapshot)
      }
    } catch {
      if let optimisticSnapshot {
        restoreTasksSnapshot(optimisticSnapshot)
      }
      errorMessage = "Error: \(error.localizedDescription)"
    }
  }

  private func ancestorTaskIDs(for task: CheckvistTask, in taskList: [CheckvistTask]) -> [Int] {
    var taskByID: [Int: CheckvistTask] = [:]
    for listedTask in taskList {
      taskByID[listedTask.id] = listedTask
    }

    var ancestorIDs: [Int] = []
    var nextParentID = task.parentId ?? 0
    while nextParentID != 0 {
      ancestorIDs.append(nextParentID)
      guard let parent = taskByID[nextParentID] else { break }
      nextParentID = parent.parentId ?? 0
    }

    return ancestorIDs
  }

  @MainActor private func reopenMissingAncestorTasksIfNeeded(_ ancestorTaskIDs: [Int]) async -> Bool
  {
    let openTaskIDs = Set(tasks.map(\.id))
    let missingAncestorIDs = ancestorTaskIDs.filter { !openTaskIDs.contains($0) }
    guard !missingAncestorIDs.isEmpty else { return false }

    var reopenedAny = false
    for ancestorID in missingAncestorIDs {
      do {
        let success = try await checkvistSyncPlugin.performTaskAction(
          listId: listId,
          taskId: ancestorID,
          action: .reopen,
          credentials: activeCredentials
        )
        if success {
          reopenedAny = true
        }
      } catch CheckvistSessionError.authenticationUnavailable {
        setAuthenticationRequiredErrorIfNeeded()
        break
      } catch {
        if errorMessage == nil {
          errorMessage = "Task completed, but a parent task could not be kept open."
        }
      }
    }

    return reopenedAny
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

  @MainActor func switchCheckvistList(to rawListId: String) async {
    let trimmedListId = rawListId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedListId != listId else { return }

    listId = trimmedListId
    currentParentId = 0
    currentSiblingIndex = 0
    errorMessage = nil
    await fetchTopTask()
  }

  @MainActor func createCheckvistListAndSwitch(name: String) async -> Bool {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      errorMessage = "List name cannot be empty."
      return false
    }

    beginLoading()
    defer { endLoading() }

    do {
      guard
        let createdList = try await checkvistSyncPlugin.createList(
          name: trimmedName,
          credentials: activeCredentials
        )
      else {
        errorMessage = "Failed to create list."
        return false
      }

      _ = await fetchLists()
      selectList(createdList)
      errorMessage = "Created and switched to list: \(createdList.name)"
      await fetchTopTask()
      return true
    } catch CheckvistSessionError.authenticationUnavailable {
      setAuthenticationRequiredErrorIfNeeded()
      return false
    } catch {
      errorMessage = "Failed to create list: \(error.localizedDescription)"
      return false
    }
  }

  @MainActor func mergeOpenTasksBetweenLists(sourceListId: String, destinationListId: String) async
    -> Bool
  {
    let source = sourceListId.trimmingCharacters(in: .whitespacesAndNewlines)
    let destination = destinationListId.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !source.isEmpty, !destination.isEmpty else {
      errorMessage = "Choose both source and destination lists."
      return false
    }
    guard source != destination else {
      errorMessage = "Source and destination list must be different."
      return false
    }

    beginLoading()
    defer { endLoading() }

    do {
      let sourceTasks = try await checkvistSyncPlugin.fetchOpenTasks(
        listId: source,
        credentials: activeCredentials
      )
      guard !sourceTasks.isEmpty else {
        errorMessage = "Source list has no open tasks to merge."
        return false
      }

      let orderedTasks = sourceTasks.sorted { lhs, rhs in
        let lhsLevel = lhs.level ?? 0
        let rhsLevel = rhs.level ?? 0
        if lhsLevel != rhsLevel { return lhsLevel < rhsLevel }

        let lhsParent = lhs.parentId ?? 0
        let rhsParent = rhs.parentId ?? 0
        if lhsParent != rhsParent { return lhsParent < rhsParent }

        return (lhs.position ?? Int.max) < (rhs.position ?? Int.max)
      }

      let migrationResult = try await copyTasks(orderedTasks, to: destination)

      if destination == listId {
        await fetchTopTask()
      }

      errorMessage =
        migrationResult.skippedCount > 0
        ? "Merged \(migrationResult.mergedCount) tasks (\(migrationResult.skippedCount) skipped)."
        : "Merged \(migrationResult.mergedCount) tasks."
      return true
    } catch CheckvistSessionError.authenticationUnavailable {
      setAuthenticationRequiredErrorIfNeeded()
      return false
    } catch {
      errorMessage = "Failed to merge lists: \(error.localizedDescription)"
      return false
    }
  }

  @MainActor func selectList(_ list: CheckvistList) {
    listId = String(list.id)
  }

  @MainActor func uploadOfflineTasksToCheckvist(destinationListId: String) async -> Bool {
    let destination = destinationListId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !destination.isEmpty else {
      errorMessage = "Choose a Checkvist destination list."
      return false
    }

    let offlineTasks = normalizeOfflineTasks(localTaskStore.load().openTasks)
    guard !offlineTasks.isEmpty else {
      errorMessage = "No offline tasks are available to upload."
      return false
    }

    let loginSucceeded = await login()
    guard loginSucceeded else { return false }

    beginLoading()
    defer { endLoading() }

    do {
      let migrationResult = try await copyTasks(offlineTasks, to: destination)

      if destination == listId {
        await fetchTopTask()
      }

      errorMessage =
        migrationResult.skippedCount > 0
        ? "Uploaded \(migrationResult.mergedCount) offline tasks (\(migrationResult.skippedCount) skipped)."
        : "Uploaded \(migrationResult.mergedCount) offline tasks."
      return true
    } catch CheckvistSessionError.authenticationUnavailable {
      setAuthenticationRequiredErrorIfNeeded()
      return false
    } catch {
      errorMessage = "Failed to upload offline tasks: \(error.localizedDescription)"
      return false
    }
  }

  private func copyTasks(_ sourceTasks: [CheckvistTask], to destinationListId: String) async throws
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

  @MainActor func updateTask(
    task: CheckvistTask, content: String? = nil, due: String? = nil, isUndo: Bool = false
  ) async {
    if isUsingOfflineStore {
      guard let index = tasks.firstIndex(where: { $0.id == task.id }) else {
        errorMessage = "Task not found."
        return
      }

      let existingTask = tasks[index]
      let snapshot = offlineStateSnapshot()
      tasks[index] = rebuiltTask(
        existingTask,
        content: content ?? existingTask.content,
        status: existingTask.status,
        due: due ?? existingTask.due,
        position: existingTask.position,
        parentId: existingTask.parentId,
        level: existingTask.level
      )
      persistOfflineTaskState()
      if !isUndo {
        lastUndo = .restoreOfflineState(snapshot: snapshot)
      }
      errorMessage = nil
      return
    }

    if !isUndo {
      lastUndo = .update(taskId: task.id, oldContent: task.content, oldDue: task.due)
    }

    await runBooleanMutation(
      failureMessage: "Failed to update task.",
      action: {
        try await checkvistSyncPlugin.updateTask(
          listId: listId,
          taskId: task.id,
          content: content,
          due: due,
          credentials: activeCredentials
        )
      },
      onSuccess: { [weak self] in
        await self?.fetchTopTask()
      }
    )
  }

  @MainActor
  func addTask(
    content: String,
    insertAfterTask: CheckvistTask? = nil,
    insertAtTopOfCurrentLevel: Bool = false
  ) async {
    let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedContent.isEmpty else {
      errorMessage = "Task content cannot be empty."
      return
    }

    if isUsingOfflineStore {
      let snapshot = offlineStateSnapshot()
      let newTask = CheckvistTask(
        id: nextOfflineTaskId(),
        content: trimmedContent,
        status: 0,
        due: nil,
        position: nil,
        parentId: currentParentId == 0 ? nil : currentParentId,
        level: nil
      )

      var updatedTasks = tasks
      var insertIndex = updatedTasks.endIndex

      if insertAtTopOfCurrentLevel {
        if currentParentId == 0 {
          insertIndex =
            updatedTasks.firstIndex(where: { ($0.parentId ?? 0) == 0 }) ?? updatedTasks.endIndex
        } else if let parentRawIndex = updatedTasks.firstIndex(where: { $0.id == currentParentId })
        {
          insertIndex = parentRawIndex + 1
        }
      } else if let target = insertAfterTask ?? currentTask,
        let rawIndex = updatedTasks.firstIndex(where: { $0.id == target.id })
      {
        var endIndex = rawIndex + 1
        while endIndex < updatedTasks.count && isDescendant(updatedTasks[endIndex], of: target.id) {
          endIndex += 1
        }
        insertIndex = endIndex
      }

      updatedTasks.insert(newTask, at: min(max(insertIndex, 0), updatedTasks.count))
      tasks = updatedTasks
      persistOfflineTaskState()
      if let insertedIndex = currentLevelTasks.firstIndex(where: { $0.id == newTask.id }) {
        currentSiblingIndex = insertedIndex
      } else {
        clampSelectionToVisibleRange()
      }
      lastUndo = .restoreOfflineState(snapshot: snapshot)
      errorMessage = nil
      return
    }

    guard !listId.isEmpty else {
      errorMessage = "Choose a Checkvist list in Preferences to add tasks."
      presentOnboardingDialogIfNeeded()
      return
    }

    let optimisticTask = insertOptimisticSiblingTask(
      content: trimmedContent,
      afterTask: insertAfterTask,
      insertAtTopOfCurrentLevel: insertAtTopOfCurrentLevel
    )
    let optimisticTaskId = optimisticTask.id

    beginLoading()
    defer { endLoading() }
    errorMessage = nil

    // Find current position to insert right below
    var apiPosition = 0
    let target = insertAfterTask ?? currentTask
    if insertAtTopOfCurrentLevel {
      apiPosition = 1
    } else if let current = target {
      if let targetPos = current.position {
        apiPosition = targetPos + 1
      } else {
        let siblings = tasks.filter { ($0.parentId ?? 0) == currentParentId }
        if let idx = siblings.firstIndex(where: { $0.id == current.id }) {
          apiPosition = idx + 2
        }
      }
    } else {
      apiPosition = 1
    }

    let parentIdForCreate = currentParentId == 0 ? nil : currentParentId
    let positionForCreate: Int? = apiPosition > 0 ? apiPosition : nil

    do {
      let newTask = try await checkvistSyncPlugin.createTask(
        listId: listId,
        content: trimmedContent,
        parentId: parentIdForCreate,
        position: positionForCreate,
        credentials: activeCredentials
      )
      if let newTask {
        lastUndo = .add(taskId: newTask.id)
        await fetchTopTask()
      } else {
        removeOptimisticTask(id: optimisticTaskId)
        errorMessage = "Failed to add task."
      }
    } catch CheckvistSessionError.authenticationUnavailable {
      removeOptimisticTask(id: optimisticTaskId)
      setAuthenticationRequiredErrorIfNeeded()
    } catch {
      removeOptimisticTask(id: optimisticTaskId)
      errorMessage = "Error adding task: \(error.localizedDescription)"
    }
  }

  @MainActor func addTaskAsChild(content: String, parentId: Int) async {
    let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedContent.isEmpty else {
      errorMessage = "Task content cannot be empty."
      return
    }

    if isUsingOfflineStore {
      guard let parentRawIndex = tasks.firstIndex(where: { $0.id == parentId }) else {
        errorMessage = "Parent task not found."
        return
      }

      let snapshot = offlineStateSnapshot()
      let selectedTaskId = currentTask?.id
      let newTask = CheckvistTask(
        id: nextOfflineTaskId(),
        content: trimmedContent,
        status: 0,
        due: nil,
        position: nil,
        parentId: parentId,
        level: nil
      )

      tasks.insert(newTask, at: parentRawIndex + 1)
      persistOfflineTaskState()
      if let selectedTaskId,
        let visibleIndex = visibleTasks.firstIndex(where: { $0.id == selectedTaskId })
      {
        currentSiblingIndex = visibleIndex
      } else {
        clampSelectionToVisibleRange()
      }
      lastUndo = .restoreOfflineState(snapshot: snapshot)
      errorMessage = nil
      return
    }

    guard !listId.isEmpty else {
      errorMessage = "Choose a Checkvist list in Preferences to add tasks."
      presentOnboardingDialogIfNeeded()
      return
    }
    let optimisticTask = insertOptimisticChildTask(content: trimmedContent, parentId: parentId)
    let optimisticTaskId = optimisticTask.id

    beginLoading()
    defer { endLoading() }
    errorMessage = nil

    do {
      let newTask = try await checkvistSyncPlugin.createTask(
        listId: listId,
        content: trimmedContent,
        parentId: parentId,
        position: 1,
        credentials: activeCredentials
      )
      if let newTask {
        lastUndo = .add(taskId: newTask.id)
        await fetchTopTask()
      } else {
        removeOptimisticTask(id: optimisticTaskId)
        errorMessage = "Failed to add task."
      }
    } catch CheckvistSessionError.authenticationUnavailable {
      removeOptimisticTask(id: optimisticTaskId)
      setAuthenticationRequiredErrorIfNeeded()
    } catch {
      removeOptimisticTask(id: optimisticTaskId)
      errorMessage = "Error: \(error.localizedDescription)"
    }
  }

  @MainActor
  func beginQuickAddEntry(preferSpecificLocation: Bool? = nil) -> Bool {
    let useSpecificLocation =
      preferSpecificLocation ?? (quickAddLocationMode == .specificParentTask)
    if useSpecificLocation && quickAddSpecificParentTaskIdValue == nil {
      errorMessage = "Set a valid Quick Add parent task ID in Preferences first."
      return false
    }

    pendingDeleteConfirmation = false
    commandSuggestionIndex = 0
    quickEntryMode = useSpecificLocation ? .quickAddSpecific : .quickAddDefault
    quickEntryText = ""
    isQuickEntryFocused = true
    return true
  }

  @MainActor
  func setQuickAddSpecificLocationToCurrentTask() {
    guard let currentTask else {
      errorMessage = "No task selected."
      return
    }
    quickAddSpecificParentTaskId = String(currentTask.id)
    quickAddLocationMode = .specificParentTask
    errorMessage = nil
  }

  @MainActor
  func submitQuickAddTask(content: String, useSpecificLocation: Bool) async {
    let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedContent.isEmpty else { return }

    let parentTaskId: Int?
    if useSpecificLocation {
      guard let specificTaskId = quickAddSpecificParentTaskIdValue else {
        errorMessage = "Set a valid Quick Add parent task ID in Preferences first."
        return
      }
      parentTaskId = specificTaskId
    } else {
      parentTaskId = nil
    }

    if isUsingOfflineStore {
      if let parentTaskId, !tasks.contains(where: { $0.id == parentTaskId }) {
        errorMessage = "Quick Add parent task not found."
        return
      }

      let snapshot = offlineStateSnapshot()
      let newTask = CheckvistTask(
        id: nextOfflineTaskId(),
        content: normalizedContent,
        status: 0,
        due: nil,
        position: nil,
        parentId: parentTaskId,
        level: nil
      )

      var updatedTasks = tasks
      if let parentTaskId,
        let parentRawIndex = updatedTasks.firstIndex(where: { $0.id == parentTaskId })
      {
        updatedTasks.insert(newTask, at: parentRawIndex + 1)
      } else {
        let firstRootIndex =
          updatedTasks.firstIndex(where: { ($0.parentId ?? 0) == 0 }) ?? updatedTasks.endIndex
        updatedTasks.insert(newTask, at: firstRootIndex)
      }

      tasks = updatedTasks
      persistOfflineTaskState()
      lastUndo = .restoreOfflineState(snapshot: snapshot)
      quickEntryMode = .search
      quickEntryText = ""
      isQuickEntryFocused = false
      errorMessage = nil
      return
    }

    guard !listId.isEmpty else {
      errorMessage = "Choose a Checkvist list in Preferences to add tasks."
      presentOnboardingDialogIfNeeded()
      return
    }

    beginLoading()
    defer { endLoading() }
    errorMessage = nil

    do {
      let createdTask = try await checkvistSyncPlugin.createTask(
        listId: listId,
        content: normalizedContent,
        parentId: parentTaskId,
        position: 1,
        credentials: activeCredentials
      )
      guard let createdTask else {
        errorMessage = "Quick add failed."
        return
      }
      lastUndo = .add(taskId: createdTask.id)
      await fetchTopTask()
      quickEntryMode = .search
      quickEntryText = ""
      isQuickEntryFocused = false
    } catch CheckvistSessionError.authenticationUnavailable {
      setAuthenticationRequiredErrorIfNeeded()
    } catch {
      errorMessage = "Quick add failed: \(error.localizedDescription)"
    }
  }

  @MainActor
  private func insertOptimisticSiblingTask(
    content: String,
    afterTask: CheckvistTask?,
    insertAtTopOfCurrentLevel: Bool = false
  )
    -> CheckvistTask
  {
    let optimisticTask = CheckvistTask(
      id: nextOptimisticTaskId(),
      content: content,
      status: 0,
      due: nil,
      position: nil,
      parentId: currentParentId == 0 ? nil : currentParentId,
      level: nil
    )

    var insertIndex = tasks.endIndex
    if insertAtTopOfCurrentLevel {
      if currentParentId == 0 {
        insertIndex =
          tasks.firstIndex(where: { ($0.parentId ?? 0) == 0 }) ?? tasks.endIndex
      } else if let parentRawIndex = tasks.firstIndex(where: { $0.id == currentParentId }) {
        insertIndex = parentRawIndex + 1
      }
    } else if let target = afterTask, let rawIndex = tasks.firstIndex(where: { $0.id == target.id })
    {
      var endIndex = rawIndex + 1
      while endIndex < tasks.count && isDescendant(tasks[endIndex], of: target.id) {
        endIndex += 1
      }
      insertIndex = endIndex
    }

    if insertIndex <= tasks.endIndex {
      tasks.insert(optimisticTask, at: insertIndex)
    } else {
      tasks.append(optimisticTask)
    }

    if let insertedIndex = currentLevelTasks.firstIndex(where: { $0.id == optimisticTask.id }) {
      currentSiblingIndex = insertedIndex
    }
    return optimisticTask
  }

  @MainActor private func insertOptimisticChildTask(content: String, parentId: Int) -> CheckvistTask
  {
    let optimisticTask = CheckvistTask(
      id: nextOptimisticTaskId(),
      content: content,
      status: 0,
      due: nil,
      position: nil,
      parentId: parentId,
      level: nil
    )

    if let parentRawIdx = tasks.firstIndex(where: { $0.id == parentId }) {
      tasks.insert(optimisticTask, at: parentRawIdx + 1)
    } else {
      tasks.append(optimisticTask)
    }
    return optimisticTask
  }

  @MainActor private func removeOptimisticTask(id: Int) {
    guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
    tasks.remove(at: index)
    clampSelectionToVisibleRange()
  }

  @MainActor func clampSelectionToVisibleRange() {
    let maxIndex = max(visibleTasks.count - 1, 0)
    if currentSiblingIndex > maxIndex {
      currentSiblingIndex = maxIndex
    }
  }

  private struct OptimisticCompletionSnapshot {
    let tasks: [CheckvistTask]
    let priorityTaskIds: [Int]
    let timerByTaskId: [Int: TimeInterval]
    let pendingObsidianSyncTaskIds: [Int]
  }

  @MainActor private func applyOptimisticCompletion(for taskId: Int)
    -> OptimisticCompletionSnapshot?
  {
    guard let removingRange = subtreeBlockRange(for: taskId, in: tasks) else { return nil }
    let removedTaskIds = Set(tasks[removingRange].map(\.id))
    let snapshot = OptimisticCompletionSnapshot(
      tasks: tasks,
      priorityTaskIds: priorityTaskIds,
      timerByTaskId: timerByTaskId,
      pendingObsidianSyncTaskIds: pendingObsidianSyncTaskIds
    )
    tasks.removeSubrange(removingRange)
    removeTasksFromPriorityQueue(removedTaskIds)
    clampSelectionToVisibleRange()
    return snapshot
  }

  @MainActor private func restoreTasksSnapshot(_ snapshot: OptimisticCompletionSnapshot) {
    tasks = snapshot.tasks
    savePriorityQueue(snapshot.priorityTaskIds)
    timerByTaskId = snapshot.timerByTaskId
    savePendingObsidianSyncQueue(snapshot.pendingObsidianSyncTaskIds)
    clampSelectionToVisibleRange()
  }

  private func nextOptimisticTaskId() -> Int {
    -Int.random(in: 1...1_000_000)
  }

  // MARK: - Delete

  @MainActor func deleteTask(_ task: CheckvistTask, isUndo: Bool = false) async {
    if isUsingOfflineStore {
      guard let removingRange = subtreeBlockRange(for: task.id, in: tasks) else { return }
      let snapshot = offlineStateSnapshot()
      let removedTaskIds = Set(tasks[removingRange].map(\.id))
      tasks.removeSubrange(removingRange)
      timerByTaskId = timerByTaskId.filter { !removedTaskIds.contains($0.key) }
      removeTasksFromPriorityQueue(removedTaskIds)
      savePendingObsidianSyncQueue(
        pendingObsidianSyncTaskIds.filter { !removedTaskIds.contains($0) })
      persistOfflineTaskState()
      if !isUndo {
        lastUndo = .restoreOfflineState(snapshot: snapshot)
      }
      errorMessage = nil
      return
    }

    if !isUndo {
      lastUndo = nil  // Clear undo history since we don't support recovering hard-deleted tasks yet
    }

    beginLoading()
    defer { endLoading() }

    await runBooleanMutation(
      failureMessage: "Failed to delete task.",
      action: {
        try await checkvistSyncPlugin.deleteTask(
          listId: listId,
          taskId: task.id,
          credentials: activeCredentials
        )
      },
      onSuccess: { [weak self] in
        await self?.fetchTopTask()
      }
    )
  }

  // MARK: - Invalidate

  @MainActor func reopenCurrentTask() async {
    guard let task = currentTask else { return }
    await taskAction(task, endpoint: "reopen")
  }

  @MainActor func invalidateCurrentTask() async {
    guard let task = currentTask else { return }
    await taskAction(task, endpoint: "invalidate")
  }

  // MARK: - Undo Execution

  @MainActor func undoLastAction() async {
    guard let action = lastUndo else { return }
    lastUndo = nil

    switch action {
    case .restoreOfflineState(let snapshot):
      restoreOfflineState(snapshot)
    case .add(let taskId):
      let mockTask = CheckvistTask(
        id: taskId, content: "", status: 0, due: nil, position: nil, parentId: nil, level: nil)
      await deleteTask(mockTask, isUndo: true)
    case .markDone(let taskId), .invalidate(let taskId):
      let mockTask = CheckvistTask(
        id: taskId, content: "", status: 1, due: nil, position: nil, parentId: nil, level: nil)
      await taskAction(mockTask, endpoint: "reopen", isUndo: true)
    case .update(let taskId, let oldContent, let oldDue):
      let mockTask = CheckvistTask(
        id: taskId, content: "", status: 0, due: nil, position: nil, parentId: nil, level: nil)
      await updateTask(task: mockTask, content: oldContent, due: oldDue, isUndo: true)
    }
  }
}
