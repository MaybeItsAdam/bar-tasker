import Foundation

@MainActor
final class CommandExecutor {
  private unowned let manager: AppCoordinator

  init(manager: AppCoordinator) {
    self.manager = manager
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  func execute(parsed: Command) async {
    // Commands that do not require a current task
    switch parsed {
    case .openPreferences:
      AppDelegate.shared.menuSettings()
      return
    case .reloadCheckvistLists:
      _ = await manager.syncService.loadCheckvistLists(assignFirstIfMissing: false)
      return
    case .uploadOfflineTasks:
      if manager.repository.availableLists.isEmpty {
        _ = await manager.syncService.loadCheckvistLists(assignFirstIfMissing: false)
      }
      let destinationListId =
        manager.repository.listId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? manager.repository.availableLists.first.map { String($0.id) } ?? ""
        : manager.repository.listId
      guard !destinationListId.isEmpty else {
        manager.repository.errorMessage = "No Checkvist list available for upload."
        return
      }
      _ = await manager.syncService.uploadOfflineTasksToCheckvist(destinationListId: destinationListId)
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
        manager.repository.errorMessage = "Missing list query. Try: list inbox"
        return
      }
      if manager.repository.availableLists.isEmpty {
        _ = await manager.syncService.fetchLists()
      }
      guard
        let found = manager.repository.availableLists.first(where: { $0.name.lowercased().contains(query) })
      else {
        manager.repository.errorMessage = "No list matching \"\(query)\"."
        return
      }
      manager.repository.listId = "\(found.id)"
      manager.navigationState.currentParentId = 0
      manager.navigationState.currentSiblingIndex = 0
      manager.quickEntry.searchText = ""
      manager.quickEntry.quickEntryText = ""
      await manager.syncService.fetchTopTask()
      return
    case .undo:
      await manager.undoService.undo()
      return
    case .undone:
      if manager.undoService.lastAction == nil {
        manager.repository.errorMessage = "Nothing to undo."
      } else {
        await manager.undoService.undo()
      }
      return
    case .toggleHideFuture:
      manager.taskListViewModel.hideFuture.toggle()
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
      manager.taskNavigationService.exitToParent()
      return
    case .switchTab(let raw):
      let view: RootTaskView?
      switch raw {
      case "all": view = .all
      case "due": view = .due
      case "tags": view = .tags
      case "priority", "prio": view = .priority
      case "kanban", "board": view = .kanban
      case "eisenhower", "matrix": view = .eisenhower
      default: view = nil
      }
      if let view {
        manager.taskNavigationService.setRootTaskView(view)
      } else {
        manager.repository.errorMessage = "Unknown tab: \(raw). Try: tab all|due|tags|priority|kanban|eisenhower"
      }
      return
    case .cycleTab(let direction):
      manager.taskNavigationService.cycleRootTaskView(direction: direction)
      return
    case .cycleFilter(let direction):
      manager.taskNavigationService.cycleRootScopeFilter(direction: direction)
      return
    case .quickAdd:
      _ = manager.taskMutationService.beginQuickAddEntry()
      return
    case .kanbanMove(let direction):
      manager.taskListViewModel.rootTaskView = .kanban
      manager.moveCurrentTaskToKanbanColumn(direction: direction)
      return
    case .kanbanFocus(let direction):
      manager.taskListViewModel.rootTaskView = .kanban
      manager.kanban.focusKanbanColumn(direction: direction)
      return
    case .kanbanShowInAll:
      guard let task = manager.kanban.currentKanbanTask else {
        manager.repository.errorMessage = "No kanban task selected."
        return
      }
      let childCounts = manager.taskListViewModel.childCountByTaskId()
      manager.taskListViewModel.rootTaskView = .all
      manager.navigationState.rootScopeFocusLevel = 0
      if childCounts[task.id, default: 0] > 0 {
        manager.navigationState.currentParentId = task.id
        manager.navigationState.currentSiblingIndex = 0
      } else {
        manager.taskNavigationService.navigate(to: task)
      }
      return
    case .kanbanDrillIn:
      manager.taskListViewModel.rootTaskView = .kanban
      manager.kanban.enterSelectedTaskAsScope()
      return
    case .kanbanPopOut:
      manager.taskListViewModel.rootTaskView = .kanban
      manager.kanban.exitToParentScope()
      return
    case .kanbanFocusMode:
      guard let task = manager.taskListViewModel.currentTask else {
        manager.repository.errorMessage = "No task selected."
        return
      }
      manager.focusSessionManager.presentPrompt(forTaskId: task.id)
      return
    case .toggleContext:
      manager.preferences.showTaskBreadcrumbContext.toggle()
      return
    case .toggleChildrenInMenus:
      manager.taskListViewModel.showChildrenInMenus.toggle()
      manager.statusMessage =
        manager.taskListViewModel.showChildrenInMenus ? "Showing siblings + children" : "Showing siblings only"
      return
    case .editAtStart:
      guard let task = manager.taskListViewModel.currentTask else {
        manager.repository.errorMessage = "No task selected."
        return
      }
      manager.quickEntry.quickEntryMode = .editTask
      manager.quickEntry.editCursorAtEnd = false
      manager.quickEntry.quickEntryText = task.content
      manager.quickEntry.isQuickEntryFocused = true
      return
    case .openCommandPalette:
      manager.quickEntry.quickEntryMode = .command
      manager.quickEntry.quickEntryText = ""
      manager.quickEntry.commandSuggestionIndex = 0
      manager.quickEntry.isQuickEntryFocused = true
      return
    case .unknown(let raw):
      manager.repository.errorMessage = "Unknown command: \(raw)"
      return
    default:
      break
    }

    guard let task = manager.taskListViewModel.currentTask else {
      manager.repository.errorMessage = "No task selected."
      return
    }

    // Commands that require a current task
    switch parsed {
    case .done:
      await manager.taskMutationService.markCurrentTaskDone()
    case .invalidate:
      await manager.taskMutationService.invalidateCurrentTask()
    case .due(let raw):
      guard !raw.isEmpty else {
        manager.repository.errorMessage = "Missing due date/time. Try: due today 14:30"
        return
      }
      let resolved = manager.preferences.resolveDueDate(raw)
      await manager.taskMutationService.updateTask(task: task, due: resolved)
    case .clearDue:
      await manager.taskMutationService.updateTask(task: task, due: "")
    case .setStart(let raw):
      guard !raw.isEmpty else {
        manager.repository.errorMessage = "Missing start date/time. Try: start tomorrow 9am"
        return
      }
      manager.startDates.setStartDate(for: task, rawInput: raw)
    case .clearStart:
      manager.startDates.clearStartDate(for: task)
    case .setRecurrence(let raw):
      guard !raw.isEmpty else {
        manager.repository.errorMessage = "Missing repeat rule. Try: repeat daily, repeat every 3 days"
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
        await manager.taskMutationService.deleteTask(task)
      }
    case .moveUp:
      await manager.syncService.moveTask(task, direction: -1)
    case .moveDown:
      await manager.syncService.moveTask(task, direction: 1)
    case .enterChildren:
      manager.taskNavigationService.enterChildren()
    case .tag(let tagName):
      guard !tagName.isEmpty else {
        manager.repository.errorMessage = "Missing tag name. Try: tag urgent"
        return
      }
      let tagged =
        task.content.contains("#\(tagName)") ? task.content : "\(task.content) #\(tagName)"
      await manager.taskMutationService.updateTask(task: task, content: tagged)
      manager.statusMessage = "Added tag: #\(tagName)"
      manager.statusMessage = "Added tag: #\(tagName)"
    case .untag(let tagName):
      guard !tagName.isEmpty else {
        manager.repository.errorMessage = "Missing tag name. Try: untag urgent"
        return
      }
      let cleaned = task.content.replacingOccurrences(of: " #\(tagName)", with: "")
        .replacingOccurrences(of: "#\(tagName)", with: "")
        .trimmingCharacters(in: .whitespaces)
      await manager.taskMutationService.updateTask(task: task, content: cleaned)
      manager.statusMessage = "Removed tag: #\(tagName)"
      manager.statusMessage = "Removed tag: #\(tagName)"
    case .matrix(let u, let i):
      manager.repository.setUrgency(taskId: task.id, level: u)
      manager.repository.setImportance(taskId: task.id, level: i)
      manager.statusMessage = "Matrix: (\(u), \(i))"
      manager.statusMessage = "Matrix: (\(u), \(i))"
    case .setUrgency(let level):
      manager.repository.setUrgency(taskId: task.id, level: level)
      manager.statusMessage = "Urgency: \(level)"
      manager.statusMessage = "Urgency: \(level)"
    case .setImportance(let level):
      manager.repository.setImportance(taskId: task.id, level: level)
      manager.statusMessage = "Importance: \(level)"
      manager.statusMessage = "Importance: \(level)"
    case .priority(let rank):
      manager.taskMutationService.setPriorityForCurrentTask(rank)
    case .priorityBack:
      manager.taskMutationService.sendCurrentTaskToPriorityBack()
    case .clearPriority:
      manager.taskMutationService.clearPriorityForCurrentTask()
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
