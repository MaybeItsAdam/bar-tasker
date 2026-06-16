import AppKit
import OSLog

@MainActor
// swiftlint:disable type_body_length function_body_length cyclomatic_complexity
struct KeyboardShortcutRouter {
  let manager: AppCoordinator
  let logger: Logger
  let updateTitle: () -> Void
  let closeWindow: () -> Void

  func handle(event: NSEvent, popoverWindow: NSWindow?) -> Bool {
    guard let popoverWindow, event.window === popoverWindow else { return false }

    let shift = event.modifierFlags.contains(.shift)
    let ctrl = event.modifierFlags.contains(.control)
    let cmd = event.modifierFlags.contains(.command)
    let option = event.modifierFlags.contains(.option)
    let keyToken = Self.keyToken(
      event: event,
      charsIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
      shift: shift,
      ctrl: ctrl,
      cmd: cmd,
      option: option
    )
    func matches(_ action: ConfigurableShortcutAction) -> Bool {
      manager.preferences.shortcutMatches(action: action, keyToken: keyToken)
    }

    let firstResponder = event.window?.firstResponder
    let typingInNativeTextField = firstResponder is NSTextView
    // The binding can drift briefly during AppKit focus changes; trust the native
    // first responder so Enter stays with the active text field.
    let isFocused = manager.quickEntry.isQuickEntryFocused || typingInNativeTextField
    if manager.needsInitialSetup {
      // During onboarding, let all key events through to the setup form.
      // Only handle Escape to close the window.
      manager.quickEntry.keyBuffer = ""
      if event.keyCode == 53 {
        closeWindow()
        return true
      }
      return false
    }
    if manager.onboardingService.activeOnboardingDialog != nil {
      // Do not trigger task shortcuts while onboarding UI is active.
      manager.quickEntry.keyBuffer = ""
      if event.keyCode == 53 {
        closeWindow()
        return true
      }
      return false
    }
    if !isFocused, let phase = manager.focusSessionManager.phase {
      if event.keyCode == 53 {  // Escape always ends the whole session.
        manager.focusSessionManager.cancelSession()
        manager.timer.pauseTimer()
        updateTitle()
        return true
      }
      if event.keyCode == 36 {  // Enter advances the pomodoro flow.
        switch phase {
        case .running:
          break
        case .focusCompleted:
          manager.focusSessionManager.startBreak()
          return true
        case .breakRunning:
          manager.focusSessionManager.skipBreak()
          return true
        case .breakCompleted:
          if let taskId = manager.focusSessionManager.lastFocusedTaskId {
            let baseline = manager.timer.timerByTaskId[taskId, default: 0]
            if !manager.timer.timerIsEnabled {
              manager.timer.timerMode = .visible
            }
            if manager.timer.timedTaskId == taskId {
              if !manager.timer.timerRunning {
                manager.timer.resumeTimer()
              }
            } else {
              manager.timer.toggleTimer(forTaskId: taskId)
            }
            manager.focusSessionManager.startAnotherSession(baselineElapsed: baseline)
            updateTitle()
          }
          return true
        }
      }
      return true
    }
    if let focusTaskId = manager.focusSessionManager.promptTaskId {
      // Esc always cancels.
      if event.keyCode == 53 {
        manager.focusSessionManager.dismissPrompt()
        return true
      }
      // Enter starts the session.
      if event.keyCode == 36 {
        let baselineElapsed = manager.timer.timerByTaskId[focusTaskId, default: 0]
        if !manager.timer.timerIsEnabled {
          manager.timer.timerMode = .visible
        }
        if manager.timer.timedTaskId == focusTaskId {
          if !manager.timer.timerRunning {
            manager.timer.resumeTimer()
          }
        } else {
          manager.timer.toggleTimer(forTaskId: focusTaskId)
        }
        manager.focusSessionManager.startSession(baselineElapsed: baselineElapsed)
        updateTitle()
        return true
      }
      if !isFocused {
        // Up / Right increases, Down / Left decreases. Shift = step of 5.
        if event.keyCode == 126 || event.keyCode == 124 {
          manager.focusSessionManager.adjustDuration(by: shift ? 5 : 1)
          return true
        }
        if event.keyCode == 125 || event.keyCode == 123 {
          manager.focusSessionManager.adjustDuration(by: shift ? -5 : -1)
          return true
        }
        // Block other keys so they don't mutate the underlying view.
        return true
      }
      // Otherwise let the event through so the TextField can process digits.
      return false
    }
    let isRepeat = event.isARepeat
    let chars = event.charactersIgnoringModifiers ?? ""
    if !manager.taskListViewModel.shouldShowRootScopeSection && manager.navigationState.rootScopeFocusLevel != 0 {
      manager.navigationState.rootScopeFocusLevel = 0
    }
    let rootScopeFocused = manager.taskListViewModel.shouldShowRootScopeSection && manager.navigationState.rootScopeFocusLevel > 0
    // Allow UP arrow to enter the scope row when at the top of the current view.
    // In kanban mode, visibleTasks is intentionally empty (kanban uses per-column task lists),
    // so we check the focused column's first task instead.
    let canFocusRootScopeFromListTop: Bool
    if manager.taskListViewModel.rootTaskView == .kanban {
      canFocusRootScopeFromListTop =
        manager.taskListViewModel.shouldShowRootScopeSection
        && manager.kanban.isAtTopOfFocusedColumn
    } else {
      canFocusRootScopeFromListTop =
        manager.taskListViewModel.shouldShowRootScopeSection
        && manager.navigationState.currentSiblingIndex == 0
        && (!manager.taskListViewModel.visibleTasks.isEmpty || manager.navigationState.currentParentId == 0)
    }

    #if DEBUG
      if cmd && shift && !ctrl && !option && chars.lowercased() == "k" && !isFocused {
        manager.toggleDebugKeychainStorageMode()
        return true
      }
    #endif

    // Reliable fallback for command/actions prompt.
    if !isFocused && matches(.openCommandPalette) {
      manager.quickEntry.keyBuffer = ""
      manager.quickEntry.quickEntryMode = .command
      manager.quickEntry.quickEntryText = ""
      manager.quickEntry.isQuickEntryFocused = true
      manager.quickEntry.commandSuggestionIndex = 0
      logger.log("Opened command palette via Cmd+K")
      return true
    }

    if manager.quickEntry.quickEntryMode == .command && isFocused {
      if event.keyCode == 125 {
        manager.quickEntry.selectNextCommandSuggestion(for: manager.quickEntry.quickEntryText)
        return true
      }
      if event.keyCode == 126 {
        manager.quickEntry.selectPreviousCommandSuggestion(for: manager.quickEntry.quickEntryText)
        return true
      }
      if event.keyCode == 36 {
        let suggestions = manager.quickEntry.filteredCommandSuggestions(query: manager.quickEntry.quickEntryText)
        if suggestions.indices.contains(manager.quickEntry.commandSuggestionIndex) {
          let selected = suggestions[manager.quickEntry.commandSuggestionIndex]
          if selected.submitImmediately {
            manager.quickEntry.isQuickEntryFocused = false
            manager.quickEntry.quickEntryMode = .search
            manager.quickEntry.quickEntryText = ""
            Task { await manager.executeCommandInput(selected.command) }
          } else {
            manager.quickEntry.quickEntryText = selected.command
            manager.quickEntry.isQuickEntryFocused = true
          }
          return true
        }
      }
    }

    // Delete confirmation: Return confirms, anything else cancels.
    if manager.quickEntry.pendingDeleteConfirmation {
      if event.keyCode == 36 {  // Return - confirm delete.
        manager.quickEntry.pendingDeleteConfirmation = false
        Task {
          if let task = manager.taskListViewModel.currentTask {
            await manager.taskMutationService.deleteTask(task)
            updateTitle()
          }
        }
        return true
      } else {
        manager.quickEntry.pendingDeleteConfirmation = false
        manager.quickEntry.quickEntryText = ""
        manager.quickEntry.quickEntryMode = .search
        manager.quickEntry.isQuickEntryFocused = false
        if event.keyCode == 53 { return true }  // Escape just cancels.
      }
    }

    // Root scope keyboard navigation:
    // Ctrl+←/→ switches root tabs. Ctrl+↑/↓ cycles Due bucket or Tag filter.
    if manager.taskListViewModel.shouldShowRootScopeSection && !isFocused {
      if matches(.rootCycleTabPrevious) {
        manager.taskNavigationService.cycleRootTaskView(direction: -1)
        return true
      }
      if matches(.rootCycleTabNext) {
        manager.taskNavigationService.cycleRootTaskView(direction: 1)
        return true
      }
      if matches(.rootCycleFilterPrevious) {
        manager.taskNavigationService.cycleRootScopeFilter(direction: -1)
        return true
      }
      if matches(.rootCycleFilterNext) {
        manager.taskNavigationService.cycleRootScopeFilter(direction: 1)
        return true
      }
    }

    // Cmd+←/→ - move task to adjacent kanban column (kanban mode only).
    if manager.taskListViewModel.rootTaskView == .kanban && !isFocused {
      if matches(.kanbanMoveLeft) {
        if !isRepeat {
          manager.moveCurrentTaskToKanbanColumn(direction: -1)
        }
        return true
      }
      if matches(.kanbanMoveRight) {
        if !isRepeat {
          manager.moveCurrentTaskToKanbanColumn(direction: 1)
        }
        return true
      }
      if matches(.kanbanShowInAll) {
        if !isRepeat, let task = manager.kanban.currentKanbanTask {
          let childCounts = manager.taskListViewModel.childCountByTaskId()
          manager.taskListViewModel.rootTaskView = .all
          manager.navigationState.rootScopeFocusLevel = 0
          if childCounts[task.id, default: 0] > 0 {
            manager.navigationState.currentParentId = task.id
            manager.navigationState.currentSiblingIndex = 0
          } else {
            manager.taskNavigationService.navigate(to: task)
          }
        }
        return true
      }
    }

    // ] / [ - enter or exit the selected task as the current scope.
    // Works in every view: kanban uses its scoped drill, other views use the
    // shared parent-id navigation so the keybind behaves consistently.
    if !isFocused && !rootScopeFocused && matches(.kanbanEnterTaskChildren) {
      if !isRepeat {
        if manager.taskListViewModel.rootTaskView == .kanban {
          manager.kanban.enterSelectedTaskAsScope()
        } else {
          manager.taskNavigationService.enterChildren()
          if !manager.quickEntry.searchText.isEmpty {
            manager.quickEntry.searchText = ""
            manager.quickEntry.quickEntryMode = .search
            manager.quickEntry.isQuickEntryFocused = false
          }
        }
        updateTitle()
      }
      return true
    }
    if !isFocused && !rootScopeFocused && matches(.kanbanFocusMode) {
      if !isRepeat, let task = manager.taskListViewModel.currentTask {
        manager.focusSessionManager.presentPrompt(forTaskId: task.id)
        updateTitle()
      }
      return true
    }
    if !isFocused && !rootScopeFocused && matches(.kanbanExitToTaskParent) {
      if !isRepeat {
        if manager.taskListViewModel.rootTaskView == .kanban {
          manager.kanban.exitToParentScope()
        } else {
          if !manager.quickEntry.searchText.isEmpty {
            manager.quickEntry.searchText = ""
            manager.quickEntry.quickEntryMode = .search
            manager.quickEntry.isQuickEntryFocused = false
          }
          manager.taskNavigationService.exitToParent()
        }
        updateTitle()
      }
      return true
    }

    // Cmd+↑/↓ - reorder. Optimistic UI is applied synchronously in moveTask;
    // the API request is queued so key repeat coalesces into the reorder queue.
    if matches(.moveTaskDown) {
      Task { if let task = manager.taskListViewModel.currentTask { await manager.syncService.moveTask(task, direction: 1) } }
      return true
    }
    if matches(.moveTaskUp) {
      Task { if let task = manager.taskListViewModel.currentTask { await manager.syncService.moveTask(task, direction: -1) } }
      return true
    }

    // o / O - open selected task in Obsidian / new Obsidian window.
    if !isFocused && matches(.openInObsidian) {
      if !isRepeat {
        Task {
          await manager.integrations.syncTaskToObsidian(taskId: nil, openMode: .standard)
          updateTitle()
        }
      }
      return true
    }
    if !isFocused && matches(.openInObsidianNewWindow) {
      if !isRepeat {
        Task {
          await manager.integrations.syncTaskToObsidian(taskId: nil, openMode: .newWindow)
          updateTitle()
        }
      }
      return true
    }

    // Up/Down arrows - list navigation + root scope navigation.
    if !isFocused && matches(.nextTask) {
      if rootScopeFocused {
        if manager.navigationState.rootScopeFocusLevel == 1 && manager.taskListViewModel.rootScopeShowsFilterControls {
          manager.navigationState.rootScopeFocusLevel = 2
        } else {
          manager.navigationState.rootScopeFocusLevel = 0
        }
        return true
      }
      if manager.taskListViewModel.rootTaskView == .kanban {
        manager.kanban.nextKanbanTask()
      } else {
        manager.taskNavigationService.nextTask()
      }
      updateTitle()
      return true
    }
    if !isFocused && matches(.previousTask) {
      if rootScopeFocused {
        if manager.navigationState.rootScopeFocusLevel == 2 {
          manager.navigationState.rootScopeFocusLevel = 1
        }
        return true
      }
      if canFocusRootScopeFromListTop {
        manager.navigationState.rootScopeFocusLevel = manager.taskListViewModel.rootScopeShowsFilterControls ? 2 : 1
        return true
      }
      if manager.taskListViewModel.rootTaskView == .kanban {
        manager.kanban.previousKanbanTask()
      } else {
        manager.taskNavigationService.previousTask()
      }
      updateTitle()
      return true
    }

    if rootScopeFocused && !isFocused && !ctrl && !cmd && !option {
      if matches(.enterChildren) {
        if manager.navigationState.rootScopeFocusLevel == 1 {
          manager.taskNavigationService.cycleRootTaskView(direction: 1)
        } else if manager.navigationState.rootScopeFocusLevel == 2 {
          manager.taskNavigationService.cycleRootScopeFilter(direction: 1)
        }
        return true
      }
      if matches(.exitToParent) {
        if manager.navigationState.rootScopeFocusLevel == 1 {
          manager.taskNavigationService.cycleRootTaskView(direction: -1)
        } else if manager.navigationState.rootScopeFocusLevel == 2 {
          manager.taskNavigationService.cycleRootScopeFilter(direction: -1)
        }
        return true
      }
      if event.keyCode == 36 || event.keyCode == 53 {
        manager.navigationState.rootScopeFocusLevel = 0
        return true
      }
    }

    // In kanban mode, ←/→ (h/l) navigate between columns without moving the task.
    if manager.taskListViewModel.rootTaskView == .kanban && !isFocused && !rootScopeFocused {
      if matches(.kanbanFocusLeft) {
        manager.kanban.focusKanbanColumn(direction: -1)
        updateTitle()
        return true
      }
      if matches(.kanbanFocusRight) {
        manager.kanban.focusKanbanColumn(direction: 1)
        updateTitle()
        return true
      }
    }

    // Shift+→ - focus/hoist (Checkvist), plain → - enter children.
    if matches(.enterChildren) {
      if isFocused { return false }
      manager.navigationState.rootScopeFocusLevel = 0
      manager.taskNavigationService.enterChildren()
      if !manager.quickEntry.searchText.isEmpty {
        manager.quickEntry.searchText = ""
        manager.quickEntry.quickEntryMode = .search
        manager.quickEntry.isQuickEntryFocused = false
      }
      return true
    }
    // Shift+← - un-focus (Checkvist), plain ← - exit to parent.
    if matches(.exitToParent) {
      if isFocused { return false }
      manager.navigationState.rootScopeFocusLevel = 0
      if !manager.quickEntry.searchText.isEmpty {
        manager.quickEntry.searchText = ""
        manager.quickEntry.quickEntryMode = .search
        manager.quickEntry.isQuickEntryFocused = false
      }
      manager.taskNavigationService.exitToParent()
      updateTitle()
      return true
    }

    // Space - mark done; Shift+Space - invalidate.
    // Ignore key repeat to prevent multiple status changes.
    if !isFocused && !rootScopeFocused && matches(.invalidateTask) {
      if !isRepeat {
        Task {
          await manager.taskMutationService.invalidateCurrentTask()
          updateTitle()
        }
      }
      return true
    }
    if !isFocused && !rootScopeFocused && matches(.markDone) {
      if !isRepeat {
        Task {
          await manager.taskMutationService.markCurrentTaskDone()
          updateTitle()
        }
      }
      return true
    }

    if matches(.addSibling) {
      if rootScopeFocused {
        manager.navigationState.rootScopeFocusLevel = 0
        return true
      }
      if isFocused { return false }
      // In kanban mode, Enter opens the inline add field in the focused column.
      if manager.taskListViewModel.rootTaskView == .kanban {
        let columns = manager.kanban.kanbanColumns
        let idx = manager.kanban.kanbanFocusedColumnIndex
        if columns.indices.contains(idx) {
          manager.kanban.addingToColumnId = columns[idx].id
          manager.kanban.addText = ""
        }
        return true
      }
      manager.quickEntry.quickEntryMode = .addSibling
      manager.quickEntry.quickEntryText = ""
      manager.quickEntry.isQuickEntryFocused = true
      return true
    }
    if matches(.addChild) {
      if rootScopeFocused {
        manager.navigationState.rootScopeFocusLevel = 0
        return true
      }
      if isFocused { return false }
      manager.quickEntry.quickEntryMode = .addChild
      manager.quickEntry.quickEntryText = ""
      manager.quickEntry.isQuickEntryFocused = true
      return true
    }

    // Tab / Shift+Tab - indent/unindent OR add child.
    if matches(.unindentTask) {
      if isFocused { return false }
      if rootScopeFocused { return true }
      if !isRepeat {
        Task { if let task = manager.taskListViewModel.currentTask { await manager.syncService.unindentTask(task) } }
      }
      return true
    }
    if matches(.indentTask) {
      if isFocused { return false }
      if rootScopeFocused { return true }
      if !isRepeat {
        Task { if let task = manager.taskListViewModel.currentTask { await manager.syncService.indentTask(task) } }
      }
      return true
    }

    // Escape - cancel input if active; otherwise close.
    if matches(.closeOrCancel) {
      // Dismiss kanban inline add field first.
      if manager.kanban.addingToColumnId != nil {
        manager.kanban.addingToColumnId = nil
        manager.kanban.addText = ""
        return true
      }
      if rootScopeFocused {
        manager.navigationState.rootScopeFocusLevel = 0
        return true
      }
      if manager.quickEntry.quickEntryMode == .search {
        if isFocused || !manager.quickEntry.searchText.isEmpty {
          manager.quickEntry.isQuickEntryFocused = false
          manager.quickEntry.searchText = ""
          return true
        }
      } else if isFocused || !manager.quickEntry.quickEntryText.isEmpty {
        manager.quickEntry.isQuickEntryFocused = false
        manager.quickEntry.quickEntryMode = .search
        manager.quickEntry.quickEntryText = ""
        manager.quickEntry.commandSuggestionIndex = 0
        return true
      }
      closeWindow()
      return true
    }

    // F2 - edit task, cursor at end.
    if !isFocused && matches(.editTaskAtEnd) {
      manager.quickEntry.quickEntryMode = .editTask
      manager.quickEntry.editCursorAtEnd = true
      manager.quickEntry.quickEntryText = manager.taskListViewModel.currentTask?.content ?? ""
      manager.quickEntry.isQuickEntryFocused = true
      return true
    }

    // Copy task to clipboard
    if !isFocused && matches(.copyTask) {
      if !isRepeat, let task = manager.taskListViewModel.currentTask {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(task.content, forType: .string)
        manager.statusMessage = "Copied task to clipboard"
      }
      return true
    }

    // Del (forward delete / Fn+Backspace) - delete task.
    if !isFocused && matches(.deleteTask) {
      if isRepeat { return true }
      if manager.preferences.confirmBeforeDelete {
        manager.quickEntry.pendingDeleteConfirmation = true
        manager.quickEntry.quickEntryMode = .command
        manager.quickEntry.commandSuggestionIndex = 0
        manager.quickEntry.quickEntryText = ""
        manager.quickEntry.isQuickEntryFocused = false
      } else {
        Task {
          if let task = manager.taskListViewModel.currentTask {
            await manager.taskMutationService.deleteTask(task)
            updateTitle()
          }
        }
      }
      return true
    }

    // q/w/e/r - root tab shortcuts: All / Due / Tags / Priority.
    if !isFocused {
      if matches(.rootTabAll) {
        manager.taskNavigationService.setRootTaskView(.all)
        updateTitle()
        return true
      }
      if matches(.rootTabDue) {
        manager.taskNavigationService.setRootTaskView(.due)
        updateTitle()
        return true
      }
      if matches(.rootTabTags) {
        manager.taskNavigationService.setRootTaskView(.tags)
        updateTitle()
        return true
      }
      if matches(.rootTabPriority) {
        manager.taskNavigationService.setRootTaskView(.priority)
        updateTitle()
        return true
      }
      if matches(.rootTabKanban) {
        manager.taskNavigationService.setRootTaskView(.kanban)
        updateTitle()
        return true
      }
      if matches(.rootTabMatrix) {
        manager.taskNavigationService.setRootTaskView(.eisenhower)
        updateTitle()
        return true
      }
    }

    // z/x/c/v/b/n/m - lower root filter shortcuts (Due/Tags row options).
    if !isFocused && manager.taskListViewModel.rootScopeShowsFilterControls {
      let rootFilterActions: [ConfigurableShortcutAction] = [
        .rootFilter1, .rootFilter2, .rootFilter3, .rootFilter4, .rootFilter5, .rootFilter6,
        .rootFilter7,
      ]
      if let filterIndex = rootFilterActions.firstIndex(where: { matches($0) }) {
        manager.taskNavigationService.selectRootScopeFilter(at: filterIndex)
        updateTitle()
        return true
      }
    }

    // Two-key sequences.
    let sequenceActions: [ConfigurableShortcutAction] = [
      .sequenceDue, .sequenceDueToday, .sequenceStart, .sequenceRepeat, .sequenceOpenLink,
      .sequenceGoogleCalendar, .sequenceTag, .sequenceUntag, .sequenceToggleContext, .sequenceUrgency, .sequenceImportance, .sequenceMatrixCoord,
    ]
    let sequenceTokens = sequenceActions.flatMap {
      manager.preferences.shortcutBinding(for: $0).split(separator: ",").map {
        String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      }
    }
    let matrixSequenceStarters: Set<String> = Set(
      manager.preferences.shortcutBinding(for: .sequenceMatrixCoord).split(separator: ",").compactMap {
        let token = String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard token.count >= 2 else { return nil }
        return String(token.prefix(1))
      }
    )
    let sequenceStarters: Set<String> = Set(
      sequenceTokens.compactMap { token in
        guard token.count >= 2 else { return nil }
        return String(token.prefix(1))
      }
    )
    if !manager.quickEntry.keyBuffer.isEmpty {
      let normalizedChars = chars.lowercased()
      let bufferedSequence = manager.quickEntry.keyBuffer.lowercased()

      // Matrix quick-entry: m + <urgency 0-9> + <importance 0-9>
      if !isFocused,
        bufferedSequence.count == 1,
        matrixSequenceStarters.contains(bufferedSequence),
        normalizedChars.count == 1,
        normalizedChars.first?.isNumber == true
      {
        manager.quickEntry.keyBuffer = bufferedSequence + normalizedChars
        manager.statusMessage = "Matrix: (\(normalizedChars), _)"
        return true
      }
      if !isFocused,
        bufferedSequence.count == 2,
        let starter = bufferedSequence.first.map(String.init),
        matrixSequenceStarters.contains(starter),
        let urgencyDigit = bufferedSequence.last,
        urgencyDigit.isNumber,
        normalizedChars.count == 1,
        normalizedChars.first?.isNumber == true,
        let urgency = Double(String(urgencyDigit)),
        let importance = Double(normalizedChars)
      {
        manager.quickEntry.keyBuffer = ""
        if let task = manager.taskListViewModel.currentTask {
          manager.repository.setUrgency(taskId: task.id, level: urgency)
          manager.repository.setImportance(taskId: task.id, level: importance)
          manager.repository.errorMessage = nil
          manager.statusMessage = "Matrix: (\(Int(urgency)), \(Int(importance)))"
          updateTitle()
        } else {
          manager.repository.errorMessage = "No task selected."
        }
        return true
      }

      let sequence = bufferedSequence + normalizedChars
      manager.quickEntry.keyBuffer = ""
      if !isFocused {
        if manager.preferences.shortcutMatchesSequence(action: .sequenceDue, sequence: sequence) {
          manager.quickEntry.quickEntryMode = .command
          manager.quickEntry.commandSuggestionIndex = 0
          manager.quickEntry.quickEntryText = "due "
          manager.quickEntry.isQuickEntryFocused = true
          return true
        }
        if manager.preferences.shortcutMatchesSequence(action: .sequenceDueToday, sequence: sequence)
        {
          manager.quickEntry.quickEntryMode = .command
          manager.quickEntry.commandSuggestionIndex = 0
          manager.quickEntry.quickEntryText = "due today "
          manager.quickEntry.isQuickEntryFocused = true
          return true
        }
        if manager.preferences.shortcutMatchesSequence(action: .sequenceStart, sequence: sequence) {
          manager.quickEntry.quickEntryMode = .command
          manager.quickEntry.commandSuggestionIndex = 0
          manager.quickEntry.quickEntryText = "start "
          manager.quickEntry.isQuickEntryFocused = true
          return true
        }
        if manager.preferences.shortcutMatchesSequence(action: .sequenceRepeat, sequence: sequence) {
          manager.quickEntry.quickEntryMode = .command
          manager.quickEntry.commandSuggestionIndex = 0
          manager.quickEntry.quickEntryText = "repeat "
          manager.quickEntry.isQuickEntryFocused = true
          return true
        }
        if manager.preferences.shortcutMatchesSequence(action: .sequenceOpenLink, sequence: sequence)
        {
          if let task = manager.taskListViewModel.currentTask { manager.integrations.openTaskLink(task: task) }
          return true
        }
        if manager.preferences.shortcutMatchesSequence(
          action: .sequenceGoogleCalendar,
          sequence: sequence
        ) {
          manager.integrations.openTaskInGoogleCalendar()
          return true
        }
        if manager.preferences.shortcutMatchesSequence(action: .sequenceTag, sequence: sequence) {
          manager.quickEntry.quickEntryMode = .command
          manager.quickEntry.commandSuggestionIndex = 0
          manager.quickEntry.quickEntryText = "tag "
          manager.quickEntry.isQuickEntryFocused = true
          return true
        }
        if manager.preferences.shortcutMatchesSequence(action: .sequenceMatrixCoord, sequence: sequence)
        {
          manager.quickEntry.quickEntryMode = .command
          manager.quickEntry.commandSuggestionIndex = 0
          manager.quickEntry.quickEntryText = "matrix "
          manager.quickEntry.isQuickEntryFocused = true
          return true
        }
        if manager.preferences.shortcutMatchesSequence(action: .sequenceUrgency, sequence: sequence) {
          manager.quickEntry.quickEntryMode = .command
          manager.quickEntry.commandSuggestionIndex = 0
          manager.quickEntry.quickEntryText = "urgency "
          manager.quickEntry.isQuickEntryFocused = true
          return true
        }
        if manager.preferences.shortcutMatchesSequence(action: .sequenceImportance, sequence: sequence) {
          manager.quickEntry.quickEntryMode = .command
          manager.quickEntry.commandSuggestionIndex = 0
          manager.quickEntry.quickEntryText = "importance "
          manager.quickEntry.isQuickEntryFocused = true
          return true
        }
        if manager.preferences.shortcutMatchesSequence(action: .sequenceUntag, sequence: sequence) {
          manager.quickEntry.quickEntryMode = .command
          manager.quickEntry.commandSuggestionIndex = 0
          manager.quickEntry.quickEntryText = "untag "
          manager.quickEntry.isQuickEntryFocused = true
          return true
        }
        if manager.preferences.shortcutMatchesSequence(
          action: .sequenceToggleContext,
          sequence: sequence
        ) {
          manager.preferences.showTaskBreadcrumbContext.toggle()
          return true
        }
      }
      return false
    }
    if sequenceStarters.contains(chars.lowercased()) && !shift && !ctrl && !isFocused {
      manager.quickEntry.keyBuffer = chars.lowercased()
      return true
    }

    // p - toggle timer on current task.
    if !isFocused && matches(.toggleTimer) {
      if !isRepeat && manager.timer.timerIsEnabled {
        if let task = manager.taskListViewModel.currentTask {
          manager.timer.toggleTimer(forTaskId: task.id)
        }
      }
      return true
    }

    // shift+p - pause/resume timer.
    if !isFocused && matches(.toggleTimerPause) {
      if !isRepeat && manager.timer.timerIsEnabled {
        if manager.timer.timerRunning { manager.timer.pauseTimer() } else { manager.timer.resumeTimer() }
      }
      return true
    }

    // j/k/u - Vim up/down navigation, undo.
    if !isFocused && matches(.undo) {
      if !isRepeat { Task { await manager.undoService.undo() } }
      return true
    }

    // H (Shift+h) - toggle hide future.
    if !isFocused && matches(.toggleHideFuture) {
      manager.taskListViewModel.hideFuture.toggle()
      return true
    }

    // Shift+L - fast list switch prompt.
    if !isFocused && matches(.quickListSwitch) {
      manager.quickEntry.quickEntryMode = .command
      manager.quickEntry.commandSuggestionIndex = 0
      manager.quickEntry.quickEntryText = "list "
      manager.quickEntry.isQuickEntryFocused = true
      return true
    }

    // Shift+A - quick add using the configured quick add location.
    if !isFocused && matches(.quickAdd) {
      _ = manager.taskMutationService.beginQuickAddEntry()
      return true
    }

    // Forward-slash - focus search.
    if !isFocused && matches(.focusSearch) {
      manager.quickEntry.quickEntryMode = .search
      manager.quickEntry.isQuickEntryFocused = true
      return true
    }

    // 1-9 set scoped priority, Hyper+1-9 (Ctrl+Cmd+Option+Shift) set absolute priority,
    // = sends to the back of prioritized tasks, - clears priority.
    if !isFocused && !rootScopeFocused {
      if matches(.clearAbsolutePriority) {
        manager.taskMutationService.clearAbsolutePriorityForCurrentTask()
        updateTitle()
        return true
      }
      if matches(.clearPriority) {
        manager.taskMutationService.clearPriorityForCurrentTask()
        updateTitle()
        return true
      }
      if matches(.pushPriorityBack) {
        manager.taskMutationService.sendCurrentTaskToPriorityBack()
        updateTitle()
        return true
      }
      let keyCodePriority: Int? = {
        switch event.keyCode {
        case 18: return 1
        case 19: return 2
        case 20: return 3
        case 21: return 4
        case 23: return 5
        case 22: return 6
        case 26: return 7
        case 28: return 8
        case 25: return 9
        default: return nil
        }
      }()

      if matches(.setPriorityRank),
        let priority = Int(chars) ?? keyCodePriority,
        (1...TaskRepository.maxPriorityRank).contains(priority)
      {
        manager.taskMutationService.setPriorityForCurrentTask(priority)
        updateTitle()
        return true
      }
      if matches(.setAbsolutePriorityRank),
        let priority = Int(chars) ?? keyCodePriority,
        (1...TaskRepository.maxPriorityRank).contains(priority)
      {
        manager.taskMutationService.setAbsolutePriorityForCurrentTask(priority)
        updateTitle()
        return true
      }
    }

    // i - insert, a - append.
    if !isFocused && matches(.editTaskAtStart) {
      manager.quickEntry.quickEntryMode = .editTask
      manager.quickEntry.editCursorAtEnd = false
      manager.quickEntry.quickEntryText = manager.taskListViewModel.currentTask?.content ?? ""
      manager.quickEntry.isQuickEntryFocused = true
      return true
    }

    return false
  }

  private static func keyToken(
    event: NSEvent,
    charsIgnoringModifiers rawChars: String,
    shift: Bool,
    ctrl: Bool,
    cmd: Bool,
    option: Bool
  ) -> String {
    let keyNameByCode: [UInt16: String] = [
      18: "1",
      19: "2",
      20: "3",
      21: "4",
      23: "5",
      22: "6",
      26: "7",
      28: "8",
      25: "9",
      29: "0",
      27: "-",
      24: "=",
      49: "space",
      36: "enter",
      48: "tab",
      53: "escape",
      120: "f2",
      117: "delete",
      123: "left",
      124: "right",
      125: "down",
      126: "up",
    ]

    let chars = rawChars.trimmingCharacters(in: .whitespacesAndNewlines)
    let base =
      keyNameByCode[event.keyCode]
      ?? (chars.isEmpty ? "key\(event.keyCode)" : chars.lowercased())

    var parts: [String] = []
    if ctrl { parts.append("ctrl") }
    if cmd { parts.append("cmd") }
    if option { parts.append("option") }
    if shift { parts.append("shift") }
    parts.append(base)
    return parts.joined(separator: "+")
  }
}
// swiftlint:enable type_body_length function_body_length cyclomatic_complexity
