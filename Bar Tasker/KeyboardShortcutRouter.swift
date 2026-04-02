import AppKit
import OSLog

@MainActor
// swiftlint:disable type_body_length function_body_length cyclomatic_complexity
struct KeyboardShortcutRouter {
  let manager: BarTaskerManager
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
    func matches(_ action: BarTaskerManager.ConfigurableShortcutAction) -> Bool {
      manager.shortcutMatches(action: action, keyToken: keyToken)
    }

    let firstResponder = event.window?.firstResponder
    let typingInNativeTextField = firstResponder is NSTextView
    // The binding can drift briefly during AppKit focus changes; trust the native
    // first responder so Enter stays with the active text field.
    let isFocused = manager.isQuickEntryFocused || typingInNativeTextField
    if manager.needsInitialSetup {
      // During onboarding, let all key events through to the setup form.
      // Only handle Escape to close the window.
      manager.keyBuffer = ""
      if event.keyCode == 53 {
        closeWindow()
        return true
      }
      return false
    }
    if manager.activeOnboardingDialog != nil {
      // Do not trigger task shortcuts while onboarding UI is active.
      manager.keyBuffer = ""
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
    let canFocusRootScopeFromListTop =
      manager.shouldShowRootScopeSection
      && manager.currentSiblingIndex == 0
      && (!manager.visibleTasks.isEmpty || manager.currentParentId == 0)

    #if DEBUG
      if cmd && shift && !ctrl && !option && chars.lowercased() == "k" && !isFocused {
        manager.toggleDebugKeychainStorageMode()
        return true
      }
    #endif

    // Reliable fallback for command/actions prompt.
    if !isFocused && matches(.openCommandPalette) {
      manager.keyBuffer = ""
      manager.quickEntryMode = .command
      manager.quickEntryText = ""
      manager.isQuickEntryFocused = true
      manager.commandSuggestionIndex = 0
      logger.log("Opened command palette via Cmd+K")
      return true
    }

    if manager.quickEntryMode == .command && isFocused {
      if event.keyCode == 125 {
        manager.selectNextCommandSuggestion(for: manager.quickEntryText)
        return true
      }
      if event.keyCode == 126 {
        manager.selectPreviousCommandSuggestion(for: manager.quickEntryText)
        return true
      }
      if event.keyCode == 36 {
        let suggestions = manager.filteredCommandSuggestions(query: manager.quickEntryText)
        if suggestions.indices.contains(manager.commandSuggestionIndex) {
          let selected = suggestions[manager.commandSuggestionIndex]
          if selected.submitImmediately {
            manager.isQuickEntryFocused = false
            manager.quickEntryMode = .search
            manager.quickEntryText = ""
            Task { await manager.executeCommandInput(selected.command) }
          } else {
            manager.quickEntryText = selected.command
            manager.isQuickEntryFocused = true
          }
          return true
        }
      }
    }

    // Delete confirmation: Return confirms, anything else cancels.
    if manager.pendingDeleteConfirmation {
      if event.keyCode == 36 {  // Return - confirm delete.
        manager.pendingDeleteConfirmation = false
        Task {
          if let task = manager.currentTask {
            await manager.deleteTask(task)
            updateTitle()
          }
        }
        return true
      } else {
        manager.pendingDeleteConfirmation = false
        manager.quickEntryText = ""
        manager.quickEntryMode = .search
        manager.isQuickEntryFocused = false
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
          await manager.syncCurrentTaskToObsidian()
          updateTitle()
        }
      }
      return true
    }
    if !isFocused && matches(.openInObsidianNewWindow) {
      if !isRepeat {
        Task {
          await manager.openCurrentTaskInNewObsidianWindow()
          updateTitle()
        }
      }
      return true
    }

    // Up/Down arrows - list navigation + root scope navigation.
    if matches(.nextTask) {
      if rootScopeFocused {
        if manager.rootScopeFocusLevel == 1 && manager.rootScopeShowsFilterControls {
          manager.rootScopeFocusLevel = 2
        } else {
          manager.rootScopeFocusLevel = 0
        }
        return true
      }
      manager.nextTask()
      updateTitle()
      return true
    }
    if matches(.previousTask) {
      if rootScopeFocused {
        if manager.rootScopeFocusLevel == 2 {
          manager.rootScopeFocusLevel = 1
        }
        return true
      }
      if canFocusRootScopeFromListTop {
        manager.rootScopeFocusLevel = 1
        return true
      }
      manager.previousTask()
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

    // Shift+→ - focus/hoist (Checkvist), plain → - enter children.
    if matches(.enterChildren) {
      if isFocused { return false }
      manager.rootScopeFocusLevel = 0
      manager.enterChildren()
      if !manager.searchText.isEmpty {
        manager.searchText = ""
        manager.quickEntryMode = .search
        manager.isQuickEntryFocused = false
      }
      return true
    }
    // Shift+← - un-focus (Checkvist), plain ← - exit to parent.
    if matches(.exitToParent) {
      if isFocused { return false }
      manager.rootScopeFocusLevel = 0
      if !manager.searchText.isEmpty {
        manager.searchText = ""
        manager.quickEntryMode = .search
        manager.isQuickEntryFocused = false
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
      manager.quickEntryMode = .addSibling
      manager.quickEntryText = ""
      manager.isQuickEntryFocused = true
      return true
    }
    if matches(.addChild) {
      if rootScopeFocused {
        manager.rootScopeFocusLevel = 0
        return true
      }
      if isFocused { return false }
      manager.quickEntryMode = .addChild
      manager.quickEntryText = ""
      manager.isQuickEntryFocused = true
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
      if rootScopeFocused {
        manager.rootScopeFocusLevel = 0
        return true
      }
      if manager.quickEntryMode == .search {
        if isFocused || !manager.searchText.isEmpty {
          manager.isQuickEntryFocused = false
          manager.searchText = ""
          return true
        }
      } else if isFocused || !manager.quickEntryText.isEmpty {
        manager.isQuickEntryFocused = false
        manager.quickEntryMode = .search
        manager.quickEntryText = ""
        manager.commandSuggestionIndex = 0
        return true
      }
      closeWindow()
      return true
    }

    // F2 - edit task, cursor at end.
    if !isFocused && matches(.editTaskAtEnd) {
      manager.quickEntryMode = .editTask
      manager.editCursorAtEnd = true
      manager.quickEntryText = manager.currentTask?.content ?? ""
      manager.isQuickEntryFocused = true
      return true
    }

    // Del (forward delete / Fn+Backspace) - delete task.
    if !isFocused && matches(.deleteTask) {
      if isRepeat { return true }
      if manager.confirmBeforeDelete {
        manager.pendingDeleteConfirmation = true
        manager.quickEntryMode = .command
        manager.commandSuggestionIndex = 0
        manager.quickEntryText = ""
        manager.isQuickEntryFocused = false
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
    }

    // z/x/c/v/b/n/m - lower root filter shortcuts (Due/Tags row options).
    if !isFocused && manager.rootScopeShowsFilterControls {
      let rootFilterActions: [BarTaskerManager.ConfigurableShortcutAction] = [
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
    let sequenceActions: [BarTaskerManager.ConfigurableShortcutAction] = [
      .sequenceDue, .sequenceDueToday, .sequenceOpenLink, .sequenceGoogleCalendar, .sequenceTag,
      .sequenceUntag, .sequenceToggleContext,
    ]
    let sequenceTokens = sequenceActions.flatMap {
      manager.shortcutBinding(for: $0).split(separator: ",").map {
        String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      }
    }
    let sequenceStarters: Set<String> = Set(
      sequenceTokens.compactMap { token in
        guard token.count >= 2 else { return nil }
        return String(token.prefix(1))
      }
    )
    if !manager.keyBuffer.isEmpty {
      let sequence = manager.keyBuffer + chars
      manager.keyBuffer = ""
      if !isFocused {
        if manager.shortcutMatchesSequence(action: .sequenceDue, sequence: sequence) {
          manager.quickEntryMode = .command
          manager.commandSuggestionIndex = 0
          manager.quickEntryText = "due "
          manager.isQuickEntryFocused = true
          return true
        }
        if manager.shortcutMatchesSequence(action: .sequenceDueToday, sequence: sequence) {
          manager.quickEntryMode = .command
          manager.commandSuggestionIndex = 0
          manager.quickEntryText = "due today "
          manager.isQuickEntryFocused = true
          return true
        }
        if manager.shortcutMatchesSequence(action: .sequenceOpenLink, sequence: sequence) {
          manager.openTaskLink()
          return true
        }
        if manager.shortcutMatchesSequence(action: .sequenceGoogleCalendar, sequence: sequence) {
          manager.openCurrentTaskInGoogleCalendar()
          return true
        }
        if manager.shortcutMatchesSequence(action: .sequenceTag, sequence: sequence) {
          manager.quickEntryMode = .command
          manager.commandSuggestionIndex = 0
          manager.quickEntryText = "tag "
          manager.isQuickEntryFocused = true
          return true
        }
        if manager.shortcutMatchesSequence(action: .sequenceUntag, sequence: sequence) {
          manager.quickEntryMode = .command
          manager.commandSuggestionIndex = 0
          manager.quickEntryText = "untag "
          manager.isQuickEntryFocused = true
          return true
        }
        if manager.shortcutMatchesSequence(action: .sequenceToggleContext, sequence: sequence) {
          manager.showTaskBreadcrumbContext.toggle()
          return true
        }
      }
      return false
    }
    if sequenceStarters.contains(chars) && !shift && !ctrl && !isFocused {
      manager.keyBuffer = chars
      return true
    }

    // t - toggle timer.
    if !isFocused && matches(.toggleTimer) {
      if !isRepeat && manager.timerIsEnabled {
        manager.toggleTimerForCurrentTask()
      }
      return true
    }

    // p - pause/resume timer.
    if !isFocused && matches(.toggleTimerPause) {
      if !isRepeat && manager.timerIsEnabled {
        if manager.timerRunning { manager.pauseTimer() } else { manager.resumeTimer() }
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
      manager.quickEntryMode = .command
      manager.commandSuggestionIndex = 0
      manager.quickEntryText = "list "
      manager.isQuickEntryFocused = true
      return true
    }

    // Shift+A - quick add using the configured quick add location.
    if !isFocused && matches(.quickAdd) {
      _ = manager.beginQuickAddEntry()
      return true
    }

    // Forward-slash - focus search.
    if !isFocused && matches(.focusSearch) {
      manager.quickEntryMode = .search
      manager.isQuickEntryFocused = true
      return true
    }

    // 1-9 set priority rank, = sends to the back of prioritized tasks, - clears priority.
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
      if matches(.setPriorityRank),
        let priority = Int(chars),
        (1...BarTaskerManager.maxPriorityRank).contains(priority)
      {
        manager.setPriorityForCurrentTask(priority)
        updateTitle()
        return true
      }
    }

    // i - insert, a - append.
    if !isFocused && matches(.editTaskAtStart) {
      manager.quickEntryMode = .editTask
      manager.editCursorAtEnd = false
      manager.quickEntryText = manager.currentTask?.content ?? ""
      manager.isQuickEntryFocused = true
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
