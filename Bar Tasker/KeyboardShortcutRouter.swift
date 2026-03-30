import AppKit
import OSLog

@MainActor
struct KeyboardShortcutRouter {
  let manager: CheckvistManager
  let logger: Logger
  let updateTitle: () -> Void
  let closeWindow: () -> Void

  func handle(event: NSEvent, popoverWindow: NSWindow?) -> Bool {
    guard let popoverWindow, event.window === popoverWindow else { return false }

    let shift = event.modifierFlags.contains(.shift)
    let ctrl = event.modifierFlags.contains(.control)
    let cmd = event.modifierFlags.contains(.command)
    let option = event.modifierFlags.contains(.option)

    // We consider the user "typing" if they are explicitly focused in the text box.
    let isFocused = manager.isQuickEntryFocused
    let firstResponder = event.window?.firstResponder
    let typingInNativeTextField = firstResponder is NSTextView
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
    if typingInNativeTextField && !isFocused {
      // Do not steal keystrokes from settings text inputs inside the popover.
      manager.keyBuffer = ""
      return false
    }

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
    if cmd && !shift && !ctrl && !option && chars.lowercased() == "k" && !isFocused {
      manager.keyBuffer = ""
      manager.quickEntryMode = .command
      manager.filterText = ""
      manager.isQuickEntryFocused = true
      manager.commandSuggestionIndex = 0
      logger.log("Opened command palette via Cmd+K")
      return true
    }

    if manager.quickEntryMode == .command && isFocused {
      if event.keyCode == 125 {
        manager.selectNextCommandSuggestion(for: manager.filterText)
        return true
      }
      if event.keyCode == 126 {
        manager.selectPreviousCommandSuggestion(for: manager.filterText)
        return true
      }
      if event.keyCode == 36 {
        let suggestions = manager.filteredCommandSuggestions(query: manager.filterText)
        if suggestions.indices.contains(manager.commandSuggestionIndex) {
          let selected = suggestions[manager.commandSuggestionIndex]
          if selected.submitImmediately {
            manager.isQuickEntryFocused = false
            manager.quickEntryMode = .search
            manager.filterText = ""
            Task { await manager.executeCommandInput(selected.command) }
          } else {
            manager.filterText = selected.command
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
        manager.filterText = ""
        manager.quickEntryMode = .search
        manager.isQuickEntryFocused = false
        if event.keyCode == 53 { return true }  // Escape just cancels.
      }
    }

    // Root scope keyboard navigation:
    // Ctrl+←/→ switches root tabs. Ctrl+↑/↓ cycles Due bucket or Tag filter.
    if manager.shouldShowRootScopeSection && !isFocused && ctrl && !cmd && !option {
      if event.keyCode == 123 {
        manager.cycleRootTaskView(direction: -1)
        return true
      }
      if event.keyCode == 124 {
        manager.cycleRootTaskView(direction: 1)
        return true
      }
      if event.keyCode == 126 {
        manager.cycleRootScopeFilter(direction: -1)
        return true
      }
      if event.keyCode == 125 {
        manager.cycleRootScopeFilter(direction: 1)
        return true
      }
    }

    // Cmd+↑/↓ - reorder.
    if cmd && event.keyCode == 125 {
      Task { if let task = manager.currentTask { await manager.moveTask(task, direction: 1) } }
      return true
    }
    if cmd && event.keyCode == 126 {
      Task { if let task = manager.currentTask { await manager.moveTask(task, direction: -1) } }
      return true
    }

    // o / O - open selected task in Obsidian / new Obsidian window.
    if !cmd && !ctrl && !option && !isFocused && chars == "o" {
      Task {
        await manager.syncCurrentTaskToObsidian()
        updateTitle()
      }
      return true
    }
    if !cmd && !ctrl && !option && !isFocused && chars == "O" {
      Task {
        await manager.openCurrentTaskInNewObsidianWindow()
        updateTitle()
      }
      return true
    }

    // Up/Down arrows - list navigation + root scope navigation.
    if event.keyCode == 125 {
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
    if event.keyCode == 126 {
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
      if event.keyCode == 124 {
        if manager.rootScopeFocusLevel == 1 {
          manager.cycleRootTaskView(direction: 1)
        } else if manager.rootScopeFocusLevel == 2 {
          manager.cycleRootScopeFilter(direction: 1)
        }
        return true
      }
      if event.keyCode == 123 {
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
    if event.keyCode == 124 {
      if isFocused { return false }
      manager.rootScopeFocusLevel = 0
      manager.enterChildren()
      if !manager.filterText.isEmpty {
        manager.filterText = ""
        manager.quickEntryMode = .search
        manager.isQuickEntryFocused = false
      }
      return true
    }
    // Shift+← - un-focus (Checkvist), plain ← - exit to parent.
    if event.keyCode == 123 {
      if isFocused { return false }
      manager.rootScopeFocusLevel = 0
      if !manager.filterText.isEmpty {
        manager.filterText = ""
        manager.quickEntryMode = .search
        manager.isQuickEntryFocused = false
      }
      manager.exitToParent()
      updateTitle()
      return true
    }

    // Space - mark done; Shift+Space - invalidate.
    if event.keyCode == 49 && !isFocused && !ctrl && !cmd && !rootScopeFocused {
      if shift {
        Task {
          await manager.invalidateCurrentTask()
          updateTitle()
        }
      } else {
        Task {
          await manager.markCurrentTaskDone()
          updateTitle()
        }
      }
      return true
    }

    // Shift+Enter - add child; Enter - add sibling.
    if event.keyCode == 36 {
      if rootScopeFocused {
        manager.rootScopeFocusLevel = 0
        return true
      }
      if isFocused { return false }
      manager.quickEntryMode = shift ? .addChild : .addSibling
      manager.isQuickEntryFocused = true
      return true
    }

    // Tab / Shift+Tab - indent/unindent OR add child.
    if event.keyCode == 48 {
      if isFocused { return false }
      if rootScopeFocused { return true }
      if shift {
        Task { if let task = manager.currentTask { await manager.unindentTask(task) } }
      } else {
        manager.quickEntryMode = .addChild
        manager.isQuickEntryFocused = true
      }
      return true
    }

    // Escape - cancel input if active; otherwise close.
    if event.keyCode == 53 {
      if rootScopeFocused {
        manager.rootScopeFocusLevel = 0
        return true
      }
      if isFocused || manager.quickEntryMode != .search || !manager.filterText.isEmpty {
        manager.isQuickEntryFocused = false
        manager.quickEntryMode = .search
        manager.filterText = ""
        return true
      }
      closeWindow()
      return true
    }

    // F2 - edit task, cursor at end.
    if event.keyCode == 120 && !isFocused {
      manager.quickEntryMode = .editTask
      manager.editCursorAtEnd = true
      manager.filterText = manager.currentTask?.content ?? ""
      manager.isQuickEntryFocused = true
      return true
    }

    // Del (forward delete / Fn+Backspace) - delete task.
    if event.keyCode == 117 && !isFocused {
      if manager.confirmBeforeDelete {
        manager.pendingDeleteConfirmation = true
        manager.quickEntryMode = .command
        manager.commandSuggestionIndex = 0
        manager.filterText = ""
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
    if !shift && !ctrl && !cmd && !option && !isFocused {
      switch chars {
      case "q":
        manager.setRootTaskView(.all)
        updateTitle()
        return true
      case "w":
        manager.setRootTaskView(.due)
        updateTitle()
        return true
      case "e":
        manager.setRootTaskView(.tags)
        updateTitle()
        return true
      case "r":
        manager.setRootTaskView(.priority)
        updateTitle()
        return true
      default:
        break
      }
    }

    // z/x/c/v/b/n/m - lower root filter shortcuts (Due/Tags row options).
    if !shift && !ctrl && !cmd && !option && !isFocused && manager.rootScopeShowsFilterControls {
      let filterShortcutKeys = ["z", "x", "c", "v", "b", "n", "m"]
      if let filterIndex = filterShortcutKeys.firstIndex(of: chars) {
        manager.selectRootScopeFilter(at: filterIndex)
        updateTitle()
        return true
      }
    }

    // Two-key sequences.
    let sequenceStarters: Set<String> =
      manager.enableTaskContextShortcut
      ? ["d", "g", "s"] : ["d", "g"]
    if !manager.keyBuffer.isEmpty {
      let sequence = manager.keyBuffer + chars
      manager.keyBuffer = ""
      if !isFocused {
        switch sequence {
        case "dd":
          manager.quickEntryMode = .command
          manager.commandSuggestionIndex = 0
          manager.filterText = "due "
          manager.isQuickEntryFocused = true
          return true
        case "dt":
          manager.quickEntryMode = .command
          manager.commandSuggestionIndex = 0
          manager.filterText = "due today "
          manager.isQuickEntryFocused = true
          return true
        case "gg":
          manager.openTaskLink()
          return true
        case "gc":
          manager.openCurrentTaskInGoogleCalendar()
          return true
        case "gt":
          manager.quickEntryMode = .command
          manager.commandSuggestionIndex = 0
          manager.filterText = "tag "
          manager.isQuickEntryFocused = true
          return true
        case "gu":
          manager.quickEntryMode = .command
          manager.commandSuggestionIndex = 0
          manager.filterText = "untag "
          manager.isQuickEntryFocused = true
          return true
        case "sc":
          guard manager.enableTaskContextShortcut else { return false }
          manager.showTaskBreadcrumbContext.toggle()
          return true
        default:
          break
        }
      }
      return false
    }
    if sequenceStarters.contains(chars) && !shift && !ctrl && !isFocused {
      manager.keyBuffer = chars
      return true
    }

    // t - toggle timer.
    if chars == "t" && !shift && !ctrl && !isFocused {
      if manager.timerIsEnabled {
        manager.toggleTimerForCurrentTask()
      }
      return true
    }

    // p - pause/resume timer.
    if chars == "p" && !shift && !ctrl && !isFocused {
      if manager.timerIsEnabled {
        if manager.timerRunning { manager.pauseTimer() } else { manager.resumeTimer() }
      }
      return true
    }

    // j/k/u - Vim up/down navigation, undo.
    if chars == "u" && !shift && !ctrl && !isFocused {
      Task { await manager.undoLastAction() }
      return true
    }
    if chars == "j" && !shift && !ctrl && !isFocused {
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
    if chars == "k" && !shift && !ctrl && !isFocused {
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

    // h/l - Vim left/right navigation (parent / children).
    if chars == "h" && !shift && !ctrl && !isFocused {
      if rootScopeFocused {
        if manager.rootScopeFocusLevel == 1 {
          manager.cycleRootTaskView(direction: -1)
        } else if manager.rootScopeFocusLevel == 2 {
          manager.cycleRootScopeFilter(direction: -1)
        }
        return true
      }
      manager.rootScopeFocusLevel = 0
      if !manager.filterText.isEmpty {
        manager.filterText = ""
        manager.quickEntryMode = .search
        manager.isQuickEntryFocused = false
      }
      manager.exitToParent()
      updateTitle()
      return true
    }
    if chars == "l" && !shift && !ctrl && !isFocused {
      if rootScopeFocused {
        if manager.rootScopeFocusLevel == 1 {
          manager.cycleRootTaskView(direction: 1)
        } else if manager.rootScopeFocusLevel == 2 {
          manager.cycleRootScopeFilter(direction: 1)
        }
        return true
      }
      manager.rootScopeFocusLevel = 0
      manager.enterChildren()
      if !manager.filterText.isEmpty {
        manager.filterText = ""
        manager.quickEntryMode = .search
        manager.isQuickEntryFocused = false
      }
      return true
    }

    // H (Shift+h) - toggle hide future.
    if chars == "h" && shift && !ctrl && !isFocused {
      manager.hideFuture.toggle()
      return true
    }

    // Shift+L - fast list switch prompt.
    if chars == "l" && shift && !ctrl && !cmd && !isFocused {
      manager.quickEntryMode = .command
      manager.commandSuggestionIndex = 0
      manager.filterText = "list "
      manager.isQuickEntryFocused = true
      return true
    }

    // Shift+A - quick add using the configured quick add location.
    if chars == "a" && shift && !ctrl && !cmd && !option && !isFocused {
      _ = manager.beginQuickAddEntry()
      return true
    }

    // Forward-slash - focus search.
    if chars == "/" && !shift && !ctrl && !isFocused {
      manager.quickEntryMode = .search
      manager.isQuickEntryFocused = true
      return true
    }

    // 1-9 set priority rank, = sends to the back of prioritized tasks, - clears priority.
    if !shift && !ctrl && !cmd && !option && !isFocused && !rootScopeFocused {
      if chars == "-" {
        manager.clearPriorityForCurrentTask()
        updateTitle()
        return true
      }
      if chars == "=" {
        manager.sendCurrentTaskToPriorityBack()
        updateTitle()
        return true
      }
      if let priority = Int(chars), (1...CheckvistManager.maxPriorityRank).contains(priority) {
        manager.setPriorityForCurrentTask(priority)
        updateTitle()
        return true
      }
    }

    // i - insert, a - append.
    if chars == "i" && !shift && !ctrl && !isFocused {
      manager.quickEntryMode = .editTask
      manager.editCursorAtEnd = false
      manager.filterText = manager.currentTask?.content ?? ""
      manager.isQuickEntryFocused = true
      return true
    }
    if chars == "a" && !shift && !ctrl && !isFocused {
      manager.quickEntryMode = .editTask
      manager.editCursorAtEnd = true
      manager.filterText = manager.currentTask?.content ?? ""
      manager.isQuickEntryFocused = true
      return true
    }

    // : or ; - command mode.
    if (chars == ":" || chars == ";") && !ctrl && !isFocused {
      manager.quickEntryMode = .command
      manager.commandSuggestionIndex = 0
      manager.filterText = ""
      manager.isQuickEntryFocused = true
      return true
    }

    return false
  }
}
