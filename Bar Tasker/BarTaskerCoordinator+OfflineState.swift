import Foundation

extension BarTaskerCoordinator {
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
    repository.rebuiltTask(
      task, content: content, status: status, due: due,
      position: position, parentId: parentId, level: level)
  }

  @MainActor func offlineStateSnapshot() -> OfflineTaskStateSnapshot {
    OfflineTaskStateSnapshot(
      openTasks: tasks,
      archivedTasks: archivedOfflineTasks(),
      nextTaskId: repository.nextOfflineTaskIdValue,
      currentParentId: currentParentId,
      currentSiblingIndex: currentSiblingIndex,
      priorityTaskIds: repository.priorityTaskIds,
      pendingObsidianSyncTaskIds: integrations.pendingObsidianSyncTaskIds,
      timerByTaskId: timer.timerByTaskId,
      timedTaskId: timer.timedTaskId,
      timerRunning: timer.timerRunning
    )
  }

  func archivedOfflineTasks() -> [CheckvistTask] {
    repository.archivedOfflineTasks()
  }

  func normalizeOfflineTasks(_ flatTasks: [CheckvistTask]) -> [CheckvistTask] {
    repository.normalizeOfflineTasks(flatTasks)
  }

  @MainActor func nextOfflineTaskId() -> Int {
    repository.nextOfflineTaskId()
  }

  @MainActor func persistOfflineTaskState() {
    tasks = normalizeOfflineTasks(tasks)

    let openTaskIds = Set(tasks.map(\.id))
    repository.offlineArchivedTasksById = repository.offlineArchivedTasksById.filter { !openTaskIds.contains($0.key) }

    repository.localTaskStore.save(
      OfflineTaskStorePayload(
        openTasks: tasks,
        archivedTasks: archivedOfflineTasks(),
        nextTaskId: max(repository.nextOfflineTaskIdValue, (openTaskIds.max() ?? 0) + 1)
      ))

    reconcilePriorityQueueWithOpenTasks()
    reconcilePendingObsidianSyncQueueWithOpenTasks()

    if currentParentId != 0 && !openTaskIds.contains(currentParentId) {
      currentParentId = 0
    }

    timer.stopTimerIfTaskRemoved(openTaskIds: openTaskIds)

    clampSelectionToVisibleRange()
  }

  @MainActor func restoreOfflineState(_ snapshot: OfflineTaskStateSnapshot) {
    tasks = normalizeOfflineTasks(snapshot.openTasks)
    repository.offlineArchivedTasksById = Dictionary(
      uniqueKeysWithValues: snapshot.archivedTasks.map { ($0.id, $0) })
    repository.nextOfflineTaskIdValue = max(snapshot.nextTaskId, 1)
    currentParentId = snapshot.currentParentId
    currentSiblingIndex = snapshot.currentSiblingIndex
    savePriorityQueue(snapshot.priorityTaskIds)
    integrations.savePendingObsidianSyncQueue(snapshot.pendingObsidianSyncTaskIds, listId: listId)
    timer.timerByTaskId = snapshot.timerByTaskId
    timer.timedTaskId = snapshot.timedTaskId
    if snapshot.timerRunning, timer.timedTaskId != nil {
      timer.resumeTimer()
    } else {
      timer.pauseTimer()
    }
    persistOfflineTaskState()
  }

  private func nextOptimisticTaskId() -> Int {
    repository.nextOptimisticTaskId()
  }
}
