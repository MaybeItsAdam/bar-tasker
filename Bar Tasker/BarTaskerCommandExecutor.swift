import Foundation

@MainActor
final class BarTaskerCommandExecutor {
  private unowned let manager: BarTaskerCoordinator

  init(manager: BarTaskerCoordinator) {
    self.manager = manager
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  func execute(parsed: BarTaskerCommand) async {
    // Commands that do not require a current task
    switch parsed {
    case .openPreferences:
      AppDelegate.shared.menuSettings()
      return
    case .reloadCheckvistLists:
      _ = await manager.loadCheckvistLists(assignFirstIfMissing: false)
      return
    case .uploadOfflineTasks:
      if manager.availableLists.isEmpty {
        _ = await manager.loadCheckvistLists(assignFirstIfMissing: false)
      }
      let destinationListId =
        manager.listId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? manager.availableLists.first.map { String($0.id) } ?? ""
        : manager.listId
      guard !destinationListId.isEmpty else {
        manager.errorMessage = "No Checkvist list available for upload."
        return
      }
      _ = await manager.uploadOfflineTasksToCheckvist(destinationListId: destinationListId)
      return
    case .addSibling:
      manager.quickEntry.quickEntryMode = .addSibling
      manager.quickEntry.quickEntryText = ""
      manager.quickEntry.isQuickEntryFocused = true
      return
    case .chooseObsidianInbox:
      _ = manager.integrations.chooseObsidianInboxFolder()
      return
    case .clearObsidianInbox:
      manager.integrations.clearObsidianInboxFolder()
      return
    case .search:
      manager.quickEntry.quickEntryMode = .search
      manager.quickEntry.searchText = ""
      manager.quickEntry.isQuickEntryFocused = true
      return
    case .list(let query):
      guard !query.isEmpty else {
        manager.errorMessage = "Missing list query. Try: list inbox"
        return
      }
      if manager.availableLists.isEmpty {
        _ = await manager.fetchLists()
      }
      guard
        let found = manager.availableLists.first(where: { $0.name.lowercased().contains(query) })
      else {
        manager.errorMessage = "No list matching \"\(query)\"."
        return
      }
      manager.listId = "\(found.id)"
      manager.currentParentId = 0
      manager.currentSiblingIndex = 0
      manager.quickEntry.searchText = ""
      manager.quickEntry.quickEntryText = ""
      await manager.fetchTopTask()
      return
    case .undo:
      await manager.undoLastAction()
      return
    case .undone:
      if manager.lastUndo == nil {
        manager.errorMessage = "Nothing to undo."
      } else {
        await manager.undoLastAction()
      }
      return
    case .toggleHideFuture:
      manager.hideFuture.toggle()
      return
    case .pauseTimer:
      if manager.timer.timerRunning { manager.timer.pauseTimer() } else { manager.timer.resumeTimer() }
      return
    case .refreshMCPPath:
      manager.integrations.refreshMCPServerCommandPath()
      return
    case .copyMCPClientConfig:
      manager.integrations.copyMCPClientConfigurationToClipboard()
      return
    case .openMCPGuide:
      manager.integrations.openMCPServerGuide()
      return
    case .exitParent:
      manager.exitToParent()
      return
    case .unknown(let raw):
      manager.errorMessage = "Unknown command: \(raw)"
      return
    default:
      break
    }

    guard let task = manager.currentTask else {
      manager.errorMessage = "No task selected."
      return
    }

    // Commands that require a current task
    switch parsed {
    case .done:
      await manager.markCurrentTaskDone()
    case .invalidate:
      await manager.invalidateCurrentTask()
    case .due(let raw):
      guard !raw.isEmpty else {
        manager.errorMessage = "Missing due date/time. Try: due today 14:30"
        return
      }
      let resolved = manager.resolveDueDateWithConfig(raw)
      await manager.updateTask(task: task, due: resolved)
    case .clearDue:
      await manager.updateTask(task: task, due: "")
    case .setStart(let raw):
      guard !raw.isEmpty else {
        manager.errorMessage = "Missing start date/time. Try: start tomorrow 9am"
        return
      }
      manager.startDates.setStartDate(for: task, rawInput: raw)
    case .clearStart:
      manager.startDates.clearStartDate(for: task)
    case .setRecurrence(let raw):
      guard !raw.isEmpty else {
        manager.errorMessage = "Missing repeat rule. Try: repeat daily, repeat every 3 days"
        return
      }
      manager.setRecurrenceRule(raw, for: task)
    case .clearRecurrence:
      manager.clearRecurrenceRule(for: task)
    case .edit:
      manager.quickEntry.quickEntryMode = .editTask
      manager.quickEntry.editCursorAtEnd = true
      manager.quickEntry.quickEntryText = task.content
      manager.quickEntry.isQuickEntryFocused = true
    case .addChild:
      manager.quickEntry.quickEntryMode = .addChild
      manager.quickEntry.quickEntryText = ""
      manager.quickEntry.isQuickEntryFocused = true
    case .openLink:
      manager.integrations.openTaskLink(task: task)
    case .toggleTimer:
      manager.timer.toggleTimer(forTaskId: task.id)
    case .delete:
      if manager.preferences.confirmBeforeDelete {
        manager.quickEntry.pendingDeleteConfirmation = true
      } else {
        await manager.deleteTask(task)
      }
    case .moveUp:
      await manager.moveTask(task, direction: -1)
    case .moveDown:
      await manager.moveTask(task, direction: 1)
    case .enterChildren:
      manager.enterChildren()
    case .tag(let tagName):
      guard !tagName.isEmpty else {
        manager.errorMessage = "Missing tag name. Try: tag urgent"
        return
      }
      let tagged =
        task.content.contains("#\(tagName)") ? task.content : "\(task.content) #\(tagName)"
      await manager.updateTask(task: task, content: tagged)
    case .untag(let tagName):
      guard !tagName.isEmpty else {
        manager.errorMessage = "Missing tag name. Try: untag urgent"
        return
      }
      let cleaned = task.content.replacingOccurrences(of: " #\(tagName)", with: "")
        .replacingOccurrences(of: "#\(tagName)", with: "")
        .trimmingCharacters(in: .whitespaces)
      await manager.updateTask(task: task, content: cleaned)
    case .priority(let rank):
      manager.setPriorityForCurrentTask(rank)
    case .priorityBack:
      manager.sendCurrentTaskToPriorityBack()
    case .clearPriority:
      manager.clearPriorityForCurrentTask()
    case .syncObsidian:
      await manager.integrations.syncTaskToObsidian(taskId: nil, openMode: .standard)
    case .syncObsidianNewWindow:
      await manager.integrations.syncTaskToObsidian(taskId: nil, openMode: .newWindow)
    case .linkObsidianFolder:
      manager.integrations.linkTaskToObsidianFolder()
    case .createObsidianFolder:
      manager.integrations.createAndLinkTaskObsidianFolder()
    case .clearObsidianFolderLink:
      manager.integrations.clearTaskObsidianFolderLink()
    case .syncGoogleCalendar:
      manager.integrations.openTaskInGoogleCalendar()
    default:
      // Handled above
      break
    }
  }
}
