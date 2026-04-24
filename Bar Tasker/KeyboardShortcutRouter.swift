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
    if manager.activeOnboardingDialog != nil {
      // Do not trigger task shortcuts while onboarding UI is active.
      manager.quickEntry.keyBuffer = ""
      if event.keyCode == 53 {
        closeWindow()
        return true
      }
      return false
    }
    let isRepeat = event.isARepeat
    let chars = event.charactersIgnoringModifiers ?? ""
    if !manager.shouldShowRootScopeSection && manager.rootScopeFocusLevel != 0 {
      manager.rootScopeFocusLevel = 0
    }
    let rootScopeFocused = manager.shouldShowRootScopeSection && manager.rootScopeFocusLevel > 0
    // Allow UP arrow to enter the scope row when at the top of the current view.
    // In kanban mode, visibleTasks is intentionally empty (kanban uses per-column task lists),
    // so we check the focused column's first task instead.
    let canFocusRootScopeFromListTop: Bool
    if manager.rootTaskView == .kanban {
      canFocusRootScopeFromListTop =
        manager.shouldShowRootScopeSection
        && manager.kanban.isAtTopOfFocusedColumn
    } else {
      canFocusRootScopeFromListTop =
        manager.shouldShowRootScopeSection
        && manager.currentSiblingIndex == 0
        && (!manager.visibleTasks.isEmpty || manager.currentParentId == 0)
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
          if let task = manager.currentTask {
            await manager.deleteTask(task)
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
    if manager.shouldShowRootScopeSection && !isFocused {
      if matches(.rootCycleTabPrevious) {
        manager.cycleRootTaskView(direction: -1)
        return true
      }
      if matches(.rootCycleTabNext) {
        manager.cycleRootTaskView(direction: 1)
        return true
      }
      if matches(.rootCycleFilterPrevious) {
        manager.cycleRootScopeFilter(direction: -1)
        return true
      }
      if matches(.rootCycleFilterNext) {
        manager.cycleRootScopeFilter(direction: 1)
        return true
      }
    }

    // Cmd+←/→ - move task to adjacent kanban column (kanban mode only).
    if manager.rootTaskView == .kanban && !isFocused {
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
          let childCounts = manager.childCountByTaskId()
          manager.rootTaskView = .all
          manager.rootScopeFocusLevel = 0
          if childCounts[task.id, default: 0] > 0 {
            manager.currentParentId = task.id
            manager.currentSiblingIndex = 0
          } else {
            manager.navigateTo(task: task)
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
        if manager.rootTaskView == .kanban {
          manager.kanban.enterSelectedTaskAsScope()
        } else {
          manager.enterChildren()
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
    if !isFocused && !rootScopeFocused && matches(.kanbanExitToTaskParent) {
      if !isRepeat {
        if manager.rootTaskView == .kanban {
          manager.kanban.exitToParentScope()
        } else {
          if !manager.quickEntry.searchText.isEmpty {
            manager.quickEntry.searchText = ""
            manager.quickEntry.quickEntryMode = .search
            manager.quickEntry.isQuickEntryFocused = false
          }
          manager.exitToParent()
        }
        updateTitle()
      }
      return true
    }

    // Cmd+↑/↓ - reorder (ignore key repeat to prevent rapid-fire API calls).
    if matches(.moveTaskDown) {
      if !isRepeat {
        Task { if let task = manager.currentTask { await manager.moveTask(task, direction: 1) } }
      }
      return true
    }
    if matches(.moveTaskUp) {
      if !isRepeat {
        Task { if let task = manager.currentTask { await manager.moveTask(task, direction: -1) } }
      }
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
        if manager.rootScopeFocusLevel == 1 && manager.rootScopeShowsFilterControls {
          manager.rootScopeFocusLevel = 2
        } else {
          manager.rootScopeFocusLevel = 0
        }
        return true
      }
      if manager.rootTaskView == .kanban {
        manager.kanban.nextKanbanTask()
      } else {
        manager.nextTask()
      }
      updateTitle()
      return true
    }
    if !isFocused && matches(.previousTask) {
      if rootScopeFocused {
        if manager.rootScopeFocusLevel == 2 {
          manager.rootScopeFocusLevel = 1
        }
        return true
      }
      if canFocusRootScopeFromListTop {
        manager.rootScopeFocusLevel = manager.rootScopeShowsFilterControls ? 2 : 1
        return true
      }
      if manager.rootTaskView == .kanban {
        manager.kanban.previousKanbanTask()
      } else {
        manager.previousTask()
      }
      updateTitle()
      return true
    }

    if rootScopeFocused && !isFocused && !ctrl && !cmd && !option {
      if matches(.enterChildren) {
        if manager.rootScopeFocusLevel == 1 {
          manager.cycleRootTaskView(direction: 1)
        } else if manager.rootScopeFocusLevel == 2 {
          manager.cycleRootScopeFilter(direction: 1)
        }
        return true
      }
      if matches(.exitToParent) {
        if manager.rootScopeFocusLevel == 1 {
          manager.cycleRootTaskView(direction: -1)
        } else if manager.rootScopeFocusLevel == 2 {
          manager.cycleRootScopeFilter(direction: -1)
        }
        return true
      }
      if event.keyCode == 36 || event.keyCode == 53 {
        manager.rootScopeFocusLevel = 0
        return true
      }
    }

    // In kanban mode, ←/→ (h/l) navigate between columns without moving the task.
    if manager.rootTaskView == .kanban && !isFocused && !rootScopeFocused {
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
      manager.rootScopeFocusLevel = 0
      manager.enterChildren()
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
      manager.rootScopeFocusLevel = 0
      if !manager.quickEntry.searchText.isEmpty {
        manager.quickEntry.searchText = ""
        manager.quickEntry.quickEntryMode = .search
        manager.quickEntry.isQuickEntryFocused = false
      }
      manager.exitToParent()
      updateTitle()
      return true
    }

    // Space - mark done; Shift+Space - invalidate.
    // Ignore key repeat to prevent multiple status changes.
    if !isFocused && !rootScopeFocused && matches(.invalidateTask) {
      if !isRepeat {
        Task {
          await manager.invalidateCurrentTask()
          updateTitle()
        }
      }
      return true
    }
    if !isFocused && !rootScopeFocused && matches(.markDone) {
      if !isRepeat {
        Task {
          await manager.markCurrentTaskDone()
          updateTitle()
        }
      }
      return true
    }

    if matches(.addSibling) {
      if rootScopeFocused {
        manager.rootScopeFocusLevel = 0
        return true
      }
      if isFocused { return false }
      // In kanban mode, Enter opens the inline add field in the focused column.
      if manager.rootTaskView == .kanban {
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
        manager.rootScopeFocusLevel = 0
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
        Task { if let task = manager.currentTask { await manager.unindentTask(task) } }
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
        manager.rootScopeFocusLevel = 0
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
      manager.quickEntry.quickEntryText = manager.currentTask?.content ?? ""
      manager.quickEntry.isQuickEntryFocused = true
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
          if let task = manager.currentTask {
            await manager.deleteTask(task)
            updateTitle()
          }
        }
      }
      return true
    }

    // q/w/e/r - root tab shortcuts: All / Due / Tags / Priority.
    if !isFocused {
      if matches(.rootTabAll) {
        manager.setRootTaskView(.all)
        updateTitle()
        return true
      }
      if matches(.rootTabDue) {
        manager.setRootTaskView(.due)
        updateTitle()
        return true
      }
      if matches(.rootTabTags) {
        manager.setRootTaskView(.tags)
        updateTitle()
        return true
      }
      if matches(.rootTabPriority) {
        manager.setRootTaskView(.priority)
        updateTitle()
        return true
      }
      if matches(.rootTabKanban) {
        manager.setRootTaskView(.kanban)
        updateTitle()
        return true
      }
    }

    // z/x/c/v/b/n/m - lower root filter shortcuts (Due/Tags row options).
    if !isFocused && manager.rootScopeShowsFilterControls {
      let rootFilterActions: [ConfigurableShortcutAction] = [
        .rootFilter1, .rootFilter2, .rootFilter3, .rootFilter4, .rootFilter5, .rootFilter6,
        .rootFilter7,
      ]
      if let filterIndex = rootFilterActions.firstIndex(where: { matches($0) }) {
        manager.selectRootScopeFilter(at: filterIndex)
        updateTitle()
        return true
      }
    }

    // Two-key sequences.
    let sequenceActions: [ConfigurableShortcutAction] = [
      .sequenceDue, .sequenceDueToday, .sequenceStart, .sequenceRepeat, .sequenceOpenLink,
      .sequenceGoogleCalendar, .sequenceTag, .sequenceUntag, .sequenceToggleContext,
    ]
    let sequenceTokens = sequenceActions.flatMap {
      manager.preferences.shortcutBinding(for: $0).split(separator: ",").map {
        String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      }
    }
    let sequenceStarters: Set<String> = Set(
      sequenceTokens.compactMap { token in
        guard token.count >= 2 else { return nil }
        return String(token.prefix(1))
      }
    )
    if !manager.quickEntry.keyBuffer.isEmpty {
      let sequence = manager.quickEntry.keyBuffer + chars
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
          if let task = manager.currentTask { manager.integrations.openTaskLink(task: task) }
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
    if sequenceStarters.contains(chars) && !shift && !ctrl && !isFocused {
      manager.quickEntry.keyBuffer = chars
      return true
    }

    // p - toggle timer on current task.
    if !isFocused && matches(.toggleTimer) {
      if !isRepeat && manager.timer.timerIsEnabled {
        if let task = manager.currentTask {
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
      if !isRepeat { Task { await manager.undoLastAction() } }
      return true
    }

    // H (Shift+h) - toggle hide future.
    if !isFocused && matches(.toggleHideFuture) {
      manager.hideFuture.toggle()
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
      _ = manager.beginQuickAddEntry()
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
      if matches(.clearPriority) {
        manager.clearPriorityForCurrentTask()
        updateTitle()
        return true
      }
      if matches(.pushPriorityBack) {
        manager.sendCurrentTaskToPriorityBack()
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
        manager.setPriorityForCurrentTask(priority)
        updateTitle()
        return true
      }
      if matches(.setAbsolutePriorityRank),
        let priority = Int(chars) ?? keyCodePriority,
        (1...TaskRepository.maxPriorityRank).contains(priority)
      {
        manager.setAbsolutePriorityForCurrentTask(priority)
        updateTitle()
        return true
      }
    }

    // i - insert, a - append.
    if !isFocused && matches(.editTaskAtStart) {
      manager.quickEntry.quickEntryMode = .editTask
      manager.quickEntry.editCursorAtEnd = false
      manager.quickEntry.quickEntryText = manager.currentTask?.content ?? ""
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
