import Foundation

extension AppCoordinator {
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


    guard !listId.isEmpty else {
      errorMessage = "Choose a Checkvist list in Preferences to add tasks."
      presentOnboardingDialogIfNeeded()
      return
    }

    beginLoading()
    defer { endLoading() }
    errorMessage = nil

    do {
      let createdTask = try await repository.activeSyncPlugin.createTask(
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
