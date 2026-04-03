import AppKit
import Foundation

extension BarTaskerManager {
  private func integrationTaskStorageKey(taskId: Int, listId: String) -> String {
    let normalizedListId = listId.trimmingCharacters(in: .whitespacesAndNewlines)
    let scope = normalizedListId.isEmpty ? "offline" : normalizedListId
    return "\(scope):\(taskId)"
  }

  @MainActor func hasGoogleCalendarEventLink(taskId: Int, listId explicitListId: String? = nil)
    -> Bool
  {
    let targetListId = explicitListId ?? listId
    let key = integrationTaskStorageKey(taskId: taskId, listId: targetListId)
    return googleCalendarEventLinksByTaskKey[key] != nil
  }

  @MainActor func googleCalendarEventLinkURL(
    taskId: Int,
    listId explicitListId: String? = nil
  ) -> URL? {
    let targetListId = explicitListId ?? listId
    let key = integrationTaskStorageKey(taskId: taskId, listId: targetListId)
    guard let rawValue = googleCalendarEventLinksByTaskKey[key], rawValue != "created" else {
      return nil
    }
    return URL(string: rawValue)
  }

  @MainActor private func recordGoogleCalendarEventLink(
    taskId: Int,
    listId: String,
    eventURL: URL?
  ) {
    let key = integrationTaskStorageKey(taskId: taskId, listId: listId)
    googleCalendarEventLinksByTaskKey[key] = eventURL?.absoluteString ?? "created"
    preferencesStore.set(googleCalendarEventLinksByTaskKey, for: .googleCalendarEventLinksByTaskKey)
  }

  // MARK: - Open Link

  @MainActor func openTaskLink() {
    guard let task = currentTask else { return }
    // Extract first URL from task content
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    else { return }
    let range = NSRange(task.content.startIndex..., in: task.content)
    if let match = detector.firstMatch(in: task.content, range: range),
      let url = match.url,
      let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    {
      NSWorkspace.shared.open(url)
    }
  }

  // MARK: - Google Calendar

  @MainActor private func ensureGoogleCalendarIntegrationEnabled() -> Bool {
    guard googleCalendarIntegrationEnabled else {
      errorMessage = "Enable Google Calendar integration in Preferences first."
      return false
    }
    return true
  }

  @MainActor func openCurrentTaskInGoogleCalendar(taskId explicitTaskId: Int? = nil) {
    guard ensureGoogleCalendarIntegrationEnabled() else { return }

    let selectedTask: CheckvistTask?
    if let explicitTaskId {
      selectedTask = tasks.first(where: { $0.id == explicitTaskId })
    } else {
      selectedTask = currentTask
    }
    guard let selectedTask else {
      errorMessage = "No task selected."
      return
    }

    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let outcome = try await googleCalendarPlugin.createEvent(
          task: selectedTask,
          listId: listId,
          now: Date()
        )
        recordGoogleCalendarEventLink(
          taskId: selectedTask.id,
          listId: listId,
          eventURL: outcome.urlToOpen
        )
        if let url = outcome.urlToOpen {
          NSWorkspace.shared.open(url)
        }
        if !outcome.usedGoogleCalendarAPI && outcome.urlToOpen == nil {
          errorMessage = "Could not create Google Calendar event."
        } else if outcome.usedGoogleCalendarAPI && outcome.urlToOpen == nil {
          errorMessage = "Google Calendar event created."
        } else {
          errorMessage = nil
        }
      } catch {
        if let localizedError = error as? LocalizedError,
          let message = localizedError.errorDescription
        {
          errorMessage = message
        } else {
          errorMessage = "Google Calendar action failed: \(error.localizedDescription)"
        }
      }
    }
  }

  @MainActor func openSavedGoogleCalendarEventLink(taskId explicitTaskId: Int? = nil) {
    guard ensureGoogleCalendarIntegrationEnabled() else { return }
    let targetTaskId = explicitTaskId ?? currentTask?.id
    guard let targetTaskId else {
      errorMessage = "No task selected."
      return
    }
    guard let url = googleCalendarEventLinkURL(taskId: targetTaskId) else {
      errorMessage = "No saved browser link for this Google Calendar event."
      return
    }
    NSWorkspace.shared.open(url)
    errorMessage = nil
  }

  // MARK: - MCP

  @MainActor private func ensureMCPIntegrationEnabled() -> Bool {
    guard mcpIntegrationEnabled else {
      errorMessage = "Enable MCP integration in Preferences first."
      return false
    }
    return true
  }

  @MainActor func refreshMCPServerCommandPath() {
    mcpServerCommandPath = mcpIntegrationPlugin.serverCommandURL()?.path ?? ""
  }

  @MainActor func copyMCPClientConfigurationToClipboard() {
    guard ensureMCPIntegrationEnabled() else { return }
    refreshMCPServerCommandPath()

    let config = mcpIntegrationPlugin.makeClientConfigurationJSON(
      credentials: activeCredentials,
      listId: listId,
      redactSecrets: false
    )
    NSPasteboard.general.clearContents()
    _ = NSPasteboard.general.setString(config, forType: .string)

    if mcpServerCommandPath.isEmpty {
      errorMessage =
        "MCP config copied with placeholder app path. Set BAR_TASKER_MCP_EXECUTABLE_PATH if your app is outside /Applications."
    } else {
      errorMessage = nil
    }
  }

  @MainActor func openMCPServerGuide() {
    guard ensureMCPIntegrationEnabled() else { return }
    guard let guideURL = mcpIntegrationPlugin.guideURL() else {
      errorMessage = "MCP guide not found. See docs/mcp-server.md in the repo."
      return
    }
    NSWorkspace.shared.open(guideURL)
    errorMessage = nil
  }

  // MARK: - Obsidian Sync

  @MainActor private func ensureObsidianIntegrationEnabled() -> Bool {
    guard obsidianIntegrationEnabled else {
      errorMessage = "Enable Obsidian integration in Preferences first."
      return false
    }
    return true
  }

  @discardableResult
  @MainActor func chooseObsidianInboxFolder() -> Bool {
    do {
      if let selectedPath = try obsidianPlugin.chooseInboxFolder() {
        obsidianInboxPath = selectedPath
        refreshOnboardingDialogState()
        errorMessage = nil
        return true
      }
      return false
    } catch {
      errorMessage = "Failed to save Obsidian folder access."
      return false
    }
  }

  @MainActor func clearObsidianInboxFolder() {
    obsidianPlugin.clearInboxFolder()
    obsidianInboxPath = ""
    refreshOnboardingDialogState()
  }

  @MainActor func linkCurrentTaskToObsidianFolder(taskId explicitTaskId: Int? = nil) {
    guard ensureObsidianIntegrationEnabled() else { return }
    guard
      let task = explicitTaskId.flatMap({ id in tasks.first(where: { $0.id == id }) })
        ?? currentTask
    else {
      errorMessage = "No task selected."
      return
    }

    do {
      if let linkedPath = try obsidianPlugin.chooseLinkedFolder(
        forTaskId: task.id,
        taskContent: task.content
      ) {
        _ = linkedPath
        errorMessage = nil
      }
    } catch {
      errorMessage = "Failed to link Obsidian folder."
    }
  }

  @MainActor func createAndLinkCurrentTaskObsidianFolder(taskId explicitTaskId: Int? = nil) {
    guard ensureObsidianIntegrationEnabled() else { return }
    guard
      let task = explicitTaskId.flatMap({ id in tasks.first(where: { $0.id == id }) })
        ?? currentTask
    else {
      errorMessage = "No task selected."
      return
    }

    do {
      if let createdPath = try obsidianPlugin.createAndLinkFolder(
        forTaskId: task.id,
        taskContent: task.content
      ) {
        _ = createdPath
        errorMessage = nil
      }
    } catch {
      errorMessage = "Failed to create and link Obsidian folder."
    }
  }

  @MainActor func clearCurrentTaskObsidianFolderLink(taskId explicitTaskId: Int? = nil) {
    guard let targetTaskId = explicitTaskId ?? currentTask?.id else {
      errorMessage = "No task selected."
      return
    }

    obsidianPlugin.clearLinkedFolder(forTaskId: targetTaskId)
    errorMessage = nil
  }

  @MainActor func hasObsidianFolderLink(taskId: Int) -> Bool {
    obsidianPlugin.hasLinkedFolder(forTaskId: taskId)
  }

  @MainActor func hasObsidianSyncedNote(task: CheckvistTask) -> Bool {
    let linkedFolderTaskId = obsidianLinkedFolderAncestorTaskId(for: task, taskList: tasks)
    return obsidianPlugin.hasSyncedNote(task: task, linkedFolderTaskId: linkedFolderTaskId)
  }

  private func obsidianLinkedFolderAncestorTaskId(
    for task: CheckvistTask, taskList: [CheckvistTask]
  ) -> Int? {
    let taskById = Dictionary(uniqueKeysWithValues: taskList.map { ($0.id, $0) })
    var candidateTask: CheckvistTask? = task

    while let current = candidateTask {
      if obsidianPlugin.hasLinkedFolder(forTaskId: current.id) {
        return current.id
      }

      guard let parentId = current.parentId, parentId != 0 else { break }
      candidateTask = taskById[parentId]
    }

    return nil
  }

  @MainActor func syncCurrentTaskToObsidian(taskId explicitTaskId: Int? = nil) async {
    await syncCurrentTaskToObsidian(taskId: explicitTaskId, openMode: .standard)
  }

  @MainActor func openCurrentTaskInNewObsidianWindow(taskId explicitTaskId: Int? = nil) async {
    await syncCurrentTaskToObsidian(taskId: explicitTaskId, openMode: .newWindow)
  }

  @MainActor private func syncCurrentTaskToObsidian(
    taskId explicitTaskId: Int? = nil,
    openMode: ObsidianOpenMode
  ) async {
    guard ensureObsidianIntegrationEnabled() else { return }
    guard let targetTaskId = explicitTaskId ?? currentTask?.id else {
      errorMessage = "No task selected."
      return
    }
    guard let task = tasks.first(where: { $0.id == targetTaskId }) ?? currentTask else {
      errorMessage = "Task not found."
      return
    }

    let linkedFolderTaskId = obsidianLinkedFolderAncestorTaskId(
      for: task, taskList: tasks)
    if linkedFolderTaskId == nil && obsidianInboxPath.isEmpty && !chooseObsidianInboxFolder() {
      return
    }

    do {
      _ = try obsidianPlugin.syncTask(
        task,
        listId: listId,
        linkedFolderTaskId: linkedFolderTaskId,
        openMode: openMode,
        syncDate: Date()
      )
      dequeuePendingObsidianSync(taskId: targetTaskId)
      errorMessage = nil
    } catch {
      enqueuePendingObsidianSync(taskId: targetTaskId)
      errorMessage =
        error.localizedDescription.isEmpty
        ? "Obsidian sync failed. Added to pending queue."
        : error.localizedDescription
    }
  }

  @MainActor func processPendingObsidianSyncQueue() async {
    guard obsidianIntegrationEnabled else { return }
    guard !pendingObsidianSyncTaskIds.isEmpty else { return }
    guard !hasPendingSyncProcessingTask else { return }
    hasPendingSyncProcessingTask = true
    defer { hasPendingSyncProcessingTask = false }

    let pendingTaskIds = pendingObsidianSyncTaskIds

    for taskId in pendingTaskIds {
      guard let task = tasks.first(where: { $0.id == taskId }) else {
        dequeuePendingObsidianSync(taskId: taskId)
        continue
      }
      do {
        let linkedFolderTaskId = obsidianLinkedFolderAncestorTaskId(for: task, taskList: tasks)
        _ = try obsidianPlugin.syncTask(
          task,
          listId: listId,
          linkedFolderTaskId: linkedFolderTaskId,
          openMode: .standard,
          syncDate: Date()
        )
        dequeuePendingObsidianSync(taskId: taskId)
      } catch {
        // Keep queued; we'll retry on the next connectivity transition.
      }
    }
  }
}
