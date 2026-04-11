import Foundation

extension BarTaskerCoordinator {
  // MARK: - Quick Add

  @MainActor
  func beginQuickAddEntry(preferSpecificLocation: Bool? = nil) -> Bool {
    let useSpecificLocation =
      preferSpecificLocation ?? (preferences.quickAddLocationMode == .specificParentTask)
    if useSpecificLocation && quickAddSpecificParentTaskIdValue == nil {
      errorMessage = "Set a valid Quick Add parent task ID in Preferences first."
      return false
    }

    quickEntry.pendingDeleteConfirmation = false
    quickEntry.commandSuggestionIndex = 0
    quickEntry.quickEntryMode = useSpecificLocation ? .quickAddSpecific : .quickAddDefault
    quickEntry.quickEntryText = ""
    quickEntry.isQuickEntryFocused = true
    return true
  }

  @MainActor
  func setQuickAddSpecificLocationToCurrentTask() {
    guard let currentTask else {
      errorMessage = "No task selected."
      return
    }
    preferences.quickAddSpecificParentTaskId = String(currentTask.id)
    preferences.quickAddLocationMode = .specificParentTask
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
      quickEntry.quickEntryMode = .search
      quickEntry.quickEntryText = ""
      quickEntry.isQuickEntryFocused = false
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
      let createdTask = try await repository.checkvistSyncPlugin.createTask(
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
      quickEntry.quickEntryMode = .search
      quickEntry.quickEntryText = ""
      quickEntry.isQuickEntryFocused = false
    } catch CheckvistSessionError.authenticationUnavailable {
      setAuthenticationRequiredErrorIfNeeded()
    } catch {
      errorMessage = "Quick add failed: \(error.localizedDescription)"
    }
  }
}
