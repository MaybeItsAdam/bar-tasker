import AppKit
import PriorityCore

/// The side of the modal gates that touches the app.
///
/// `ShortcutGate` in `PriorityCore` decides *whether* a key is claimed and by
/// which modal state; everything here is the doing. Split out so
/// `KeyboardShortcutRouter.swift` stays under the file-length limit rather than
/// adding to the standing warnings.
@MainActor
extension KeyboardShortcutRouter {

  /// Translates the app's focus-session phase into the shape `ShortcutGate`
  /// reasons about. The gate does not care when a break ends, only that one is
  /// running, so the associated value is dropped here rather than duplicated
  /// into `PriorityCore`.
  static func gatePhase(_ phase: FocusSessionManager.Phase) -> ShortcutGate.FocusPhase {
    switch phase {
    case .running: return .running
    case .focusCompleted: return .focusCompleted
    case .breakRunning: return .breakRunning
    case .breakCompleted: return .breakCompleted
    }
  }

  /// Performs what a gate decided. Every case is a side effect the gate itself
  /// stays free of.
  func perform(_ action: ShortcutGate.Action) {
    switch action {
    case .clearKeySequenceBuffer:
      manager.quickEntry.keyBuffer = ""
    case .closeWindow:
      closeWindow()
    case .cancelFocusSession:
      manager.focusSessionManager.cancelSession()
      manager.timer.pauseTimer()
      updateTitle()
    case .startBreak:
      manager.focusSessionManager.startBreak()
    case .skipBreak:
      manager.focusSessionManager.skipBreak()
    case .startAnotherSession:
      guard let taskId = manager.focusSessionManager.lastFocusedTaskId else { return }
      let baseline = resumeTimer(forTaskId: taskId)
      manager.focusSessionManager.startAnotherSession(baselineElapsed: baseline)
      updateTitle()
    case .dismissFocusPrompt:
      manager.focusSessionManager.dismissPrompt()
    case .startFocusSession:
      guard let taskId = manager.focusSessionManager.promptTaskId else { return }
      let baseline = resumeTimer(forTaskId: taskId)
      manager.focusSessionManager.startSession(baselineElapsed: baseline)
      updateTitle()
    case .adjustFocusDuration(let minutes):
      manager.focusSessionManager.adjustDuration(by: minutes)
    }
  }

  /// Puts the timer back on `taskId` and returns the elapsed time to carry into
  /// the new session, so a second session continues the first one's total
  /// rather than restarting it.
  func resumeTimer(forTaskId taskId: Int) -> TimeInterval {
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
    return baseline
  }

  /// Drops an active search filter so a scope change lands in the real list
  /// rather than inside the results of a search the user has moved on from.
  func clearSearchFilter() {
    guard !manager.quickEntry.searchText.isEmpty else { return }
    manager.quickEntry.searchText = ""
    manager.quickEntry.quickEntryMode = .search
    manager.quickEntry.isQuickEntryFocused = false
  }
}
