import Foundation
import OSLog

extension AppCoordinator {
  // MARK: - Authentication & Fetch

  @MainActor func login() async -> Bool {
    await repository.login()
  }

  @MainActor func fetchTopTask() async {
    if canSyncRemotely && listId.isEmpty { return }

    errorMessage = nil

    do {
      try await withLoadingState {
        let previousTasks = self.tasks
        let fetchedTasks = try await self.repository.activeSyncPlugin.fetchOpenTasks(
          listId: self.listId,
          credentials: self.activeCredentials
        )

        self.tasks = fetchedTasks
        self.repository.activeSyncPlugin.persistTaskCache(listId: self.listId, tasks: fetchedTasks)
        self.reconcilePriorityQueueWithOpenTasks()
        self.reconcilePendingObsidianSyncQueueWithOpenTasks()
        if self.rootTaskView == .kanban {
          self.kanban.clampKanbanSelection()
        } else if self.currentSiblingIndex >= fetchedTasks.count {
          self.currentSiblingIndex = 0
        }
        self.focusSessionManager.clampForTasks(fetchedTasks)
        let latestOpenTaskIDs = Set(fetchedTasks.map(\.id))
        let previousTimerNodes = previousTasks.map {
          TimerNode(id: $0.id, parentId: $0.parentId)
        }
        self.timer.timerByTaskId = TimerElapsedReassignmentPolicy.remapElapsed(
          previousNodes: previousTimerNodes,
          latestOpenTaskIDs: latestOpenTaskIDs,
          elapsedByTaskID: self.timer.timerByTaskId
        )
        self.timer.stopTimerIfTaskRemoved(openTaskIds: latestOpenTaskIDs)
        if let filterParentId = self.kanban.kanbanFilterParentId,
          !latestOpenTaskIDs.contains(filterParentId)
        {
          self.kanban.kanbanFilterParentId = nil
          if self.rootTaskView == .kanban {
            self.currentParentId = 0
          }
        }
        if !self.listId.isEmpty && self.canAttemptLogin {
          self.onboardingCompleted = true
        }
      }
    } catch CheckvistSessionError.authenticationUnavailable {
      setAuthenticationRequiredErrorIfNeeded()
    } catch {
      logger.error("Fetch tasks failed: \(error.localizedDescription, privacy: .public)")
      errorMessage = "Failed to fetch tasks: \(error.localizedDescription)"
    }
  }

  // MARK: - List Management

  @MainActor func fetchLists() async -> Bool {
    await repository.fetchLists()
  }

  @MainActor func loadCheckvistLists(assignFirstIfMissing: Bool = false) async -> Bool {
    await repository.loadCheckvistLists(assignFirstIfMissing: assignFirstIfMissing)
  }

  @MainActor func switchCheckvistList(to rawListId: String) async {
    let trimmedListId = rawListId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedListId != listId else { return }

    listId = trimmedListId
    currentParentId = 0
    currentSiblingIndex = 0
    repository.pendingTaskMutations = [:]
    kanban.kanbanFilterParentId = nil
    kanban.kanbanSelectedTaskId = nil
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
        let createdList = try await repository.activeSyncPlugin.createList(
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
      let sourceTasks = try await repository.activeSyncPlugin.fetchOpenTasks(
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
    repository.selectList(list)
  }

  @MainActor func uploadOfflineTasksToCheckvist(destinationListId: String) async -> Bool {
    let destination = destinationListId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !destination.isEmpty else {
      errorMessage = "Choose a Checkvist destination list."
      return false
    }

    let offlineTasks = (try? await repository.offlineSyncPlugin.fetchOpenTasks(listId: "", credentials: activeCredentials)) ?? []
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
    try await repository.copyTasks(sourceTasks, to: destinationListId)
  }

  // MARK: - Offline Mutation Queue

  @MainActor func flushPendingTaskMutations() async {
    guard !repository.pendingTaskMutations.isEmpty else { return }
    let mutations = repository.pendingTaskMutations
    repository.pendingTaskMutations = [:]
    for (taskId, mutation) in mutations {
      guard let task = tasks.first(where: { $0.id == taskId }) else { continue }
      await updateTask(task: task, content: mutation.content, due: mutation.due)
    }
  }
}
