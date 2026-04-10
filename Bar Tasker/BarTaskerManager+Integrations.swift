import AppKit
import Foundation

extension BarTaskerManager {

  // MARK: - Convenience accessors (delegate to IntegrationCoordinator)

  @MainActor func hasGoogleCalendarEventLink(taskId: Int, listId explicitListId: String? = nil)
    -> Bool
  {
    integrations.hasGoogleCalendarEventLink(
      taskId: taskId, listId: explicitListId ?? listId)
  }

  @MainActor func googleCalendarEventLinkURL(
    taskId: Int,
    listId explicitListId: String? = nil
  ) -> URL? {
    integrations.googleCalendarEventLinkURL(
      taskId: taskId, listId: explicitListId ?? listId)
  }

  @MainActor func openTaskLink() {
    guard let task = currentTask else { return }
    integrations.openTaskLink(task: task)
  }

  @MainActor func openCurrentTaskInGoogleCalendar(taskId explicitTaskId: Int? = nil) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      let err = await self.integrations.openTaskInGoogleCalendarAsync(taskId: explicitTaskId)
      if let err {
        self.errorMessage = err
      } else {
        self.errorMessage = nil
      }
    }
  }

  @MainActor func openSavedGoogleCalendarEventLink(taskId explicitTaskId: Int? = nil) {
    if let err = integrations.openSavedGoogleCalendarEventLink(taskId: explicitTaskId) {
      errorMessage = err
    } else {
      errorMessage = nil
    }
  }

  @MainActor func refreshMCPServerCommandPath() {
    integrations.refreshMCPServerCommandPath()
  }

  @MainActor func copyMCPClientConfigurationToClipboard() {
    if let err = integrations.copyMCPClientConfigurationToClipboard() {
      errorMessage = err
    } else {
      errorMessage = nil
    }
  }

  @MainActor func openMCPServerGuide() {
    if let err = integrations.openMCPServerGuide() {
      errorMessage = err
    } else {
      errorMessage = nil
    }
  }

  @discardableResult
  @MainActor func chooseObsidianInboxFolder() -> Bool {
    let result = integrations.chooseObsidianInboxFolder()
    if let err = result.error {
      errorMessage = err
    } else {
      errorMessage = nil
    }
    return result.success
  }

  @MainActor func clearObsidianInboxFolder() {
    integrations.clearObsidianInboxFolder()
  }

  @MainActor func linkCurrentTaskToObsidianFolder(taskId explicitTaskId: Int? = nil) {
    if let err = integrations.linkTaskToObsidianFolder(taskId: explicitTaskId) {
      errorMessage = err
    } else {
      errorMessage = nil
    }
  }

  @MainActor func createAndLinkCurrentTaskObsidianFolder(taskId explicitTaskId: Int? = nil) {
    if let err = integrations.createAndLinkTaskObsidianFolder(taskId: explicitTaskId) {
      errorMessage = err
    } else {
      errorMessage = nil
    }
  }

  @MainActor func clearCurrentTaskObsidianFolderLink(taskId explicitTaskId: Int? = nil) {
    if let err = integrations.clearTaskObsidianFolderLink(taskId: explicitTaskId) {
      errorMessage = err
    } else {
      errorMessage = nil
    }
  }

  @MainActor func hasObsidianFolderLink(taskId: Int) -> Bool {
    integrations.hasObsidianFolderLink(taskId: taskId)
  }

  @MainActor func hasObsidianSyncedNote(task: CheckvistTask) -> Bool {
    integrations.hasObsidianSyncedNote(task: task, tasks: tasks)
  }

  @MainActor func syncCurrentTaskToObsidian(taskId explicitTaskId: Int? = nil) async {
    if let err = await integrations.syncTaskToObsidian(
      taskId: explicitTaskId, openMode: .standard)
    {
      errorMessage = err
    } else {
      errorMessage = nil
    }
  }

  @MainActor func openCurrentTaskInNewObsidianWindow(taskId explicitTaskId: Int? = nil) async {
    if let err = await integrations.syncTaskToObsidian(
      taskId: explicitTaskId, openMode: .newWindow)
    {
      errorMessage = err
    } else {
      errorMessage = nil
    }
  }

  @MainActor func processPendingObsidianSyncQueue() async {
    await integrations.processPendingObsidianSyncQueue()
  }

  // MARK: - Convenience for pending sync queue (delegates to IntegrationCoordinator)

  func savePendingObsidianSyncQueue(_ queue: [Int]) {
    integrations.savePendingObsidianSyncQueue(queue, listId: listId)
  }

  @MainActor func enqueuePendingObsidianSync(taskId: Int) {
    integrations.enqueuePendingObsidianSync(taskId: taskId, listId: listId)
  }

  @MainActor func dequeuePendingObsidianSync(taskId: Int) {
    integrations.dequeuePendingObsidianSync(taskId: taskId, listId: listId)
  }
}
