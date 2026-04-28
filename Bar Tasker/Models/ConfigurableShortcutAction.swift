import Foundation

enum ConfigurableShortcutAction: String, CaseIterable, Identifiable {
  case openCommandPalette
  case rootCycleTabPrevious
  case rootCycleTabNext
  case rootCycleFilterPrevious
  case rootCycleFilterNext
  case moveTaskUp
  case moveTaskDown
  case openInObsidian
  case openInObsidianNewWindow
  case nextTask
  case previousTask
  case enterChildren
  case exitToParent
  case markDone
  case invalidateTask
  case addSibling
  case addChild
  case unindentTask
  case closeOrCancel
  case editTaskAtEnd
  case editTaskAtStart
  case deleteTask
  case rootTabAll
  case rootTabDue
  case rootTabTags
  case rootTabPriority
  case rootFilter1
  case rootFilter2
  case rootFilter3
  case rootFilter4
  case rootFilter5
  case rootFilter6
  case rootFilter7
  case sequenceDue
  case sequenceDueToday
  case sequenceStart
  case sequenceRepeat
  case sequenceOpenLink
  case sequenceGoogleCalendar
  case sequenceTag
  case sequenceUntag
  case sequenceToggleContext
  case toggleTimer
  case toggleTimerPause
  case undo
  case toggleHideFuture
  case quickListSwitch
  case quickAdd
  case focusSearch
  case clearPriority
  case clearAbsolutePriority
  case pushPriorityBack
  case setPriorityRank
  case setAbsolutePriorityRank
  case kanbanMoveLeft
  case kanbanMoveRight
  case kanbanFocusLeft
  case kanbanFocusRight
  case rootTabKanban
  case kanbanShowInAll
  case kanbanEnterTaskChildren
  case kanbanExitToTaskParent
  case kanbanFocusMode
  case rootTabMatrix
  case sequenceUrgency
  case sequenceImportance
  case sequenceMatrixCoord

  var id: String { rawValue }

  var title: String {
    switch self {
    case .openCommandPalette: return "Open command palette"
    case .rootCycleTabPrevious: return "Cycle root tab previous"
    case .rootCycleTabNext: return "Cycle root tab next"
    case .rootCycleFilterPrevious: return "Cycle root filter previous"
    case .rootCycleFilterNext: return "Cycle root filter next"
    case .moveTaskUp: return "Move task up"
    case .moveTaskDown: return "Move task down"
    case .openInObsidian: return "Open in Obsidian"
    case .openInObsidianNewWindow: return "Open in new Obsidian window"
    case .nextTask: return "Next task"
    case .previousTask: return "Previous task"
    case .enterChildren: return "Enter children"
    case .exitToParent: return "Exit to parent"
    case .markDone: return "Mark done"
    case .invalidateTask: return "Invalidate task"
    case .addSibling: return "Add sibling"
    case .addChild: return "Add child"
    case .unindentTask: return "Unindent task"
    case .closeOrCancel: return "Close/cancel"
    case .editTaskAtEnd: return "Edit task (end)"
    case .editTaskAtStart: return "Edit task (start)"
    case .deleteTask: return "Delete task"
    case .rootTabAll: return "Jump to root tab: All"
    case .rootTabDue: return "Jump to root tab: Due"
    case .rootTabTags: return "Jump to root tab: Tags"
    case .rootTabPriority: return "Jump to root tab: Priority"
    case .rootFilter1: return "Root filter slot 1"
    case .rootFilter2: return "Root filter slot 2"
    case .rootFilter3: return "Root filter slot 3"
    case .rootFilter4: return "Root filter slot 4"
    case .rootFilter5: return "Root filter slot 5"
    case .rootFilter6: return "Root filter slot 6"
    case .rootFilter7: return "Root filter slot 7"
    case .sequenceDue: return "Sequence: due"
    case .sequenceDueToday: return "Sequence: due today"
    case .sequenceStart: return "Sequence: start date"
    case .sequenceRepeat: return "Sequence: repeat"
    case .sequenceOpenLink: return "Sequence: open link"
    case .sequenceGoogleCalendar: return "Sequence: Google Calendar"
    case .sequenceTag: return "Sequence: tag"
    case .sequenceUntag: return "Sequence: untag"
    case .sequenceToggleContext: return "Sequence: toggle context"
    case .toggleTimer: return "Toggle timer"
    case .toggleTimerPause: return "Pause/resume timer"
    case .undo: return "Undo"
    case .toggleHideFuture: return "Toggle hide future"
    case .quickListSwitch: return "Quick list switch"
    case .quickAdd: return "Quick add"
    case .focusSearch: return "/"
    case .clearPriority: return "-"
    case .clearAbsolutePriority: return "Clear absolute priority"
    case .pushPriorityBack: return "Send priority to back"
    case .setPriorityRank: return "Set priority rank"
    case .setAbsolutePriorityRank: return "Set absolute priority rank"
    case .kanbanMoveLeft: return "Kanban: move task to previous column"
    case .kanbanMoveRight: return "Kanban: move task to next column"
    case .kanbanFocusLeft: return "Kanban: focus previous column"
    case .kanbanFocusRight: return "Kanban: focus next column"
    case .rootTabKanban: return "Jump to root tab: Kanban"
    case .kanbanShowInAll: return "Kanban: show task in All view"
    case .kanbanEnterTaskChildren: return "Kanban: drill into selected task's subtasks"
    case .kanbanExitToTaskParent: return "Kanban: pop up to parent scope"
    case .kanbanFocusMode: return "Focus selected task"
    case .rootTabMatrix: return "Jump to root tab: Matrix"
    case .sequenceUrgency: return "Sequence: urgency"
    case .sequenceImportance: return "Sequence: importance"
    case .sequenceMatrixCoord: return "Sequence: matrix coordinates"
    }
  }

  var category: String {
    switch self {
    case .nextTask, .previousTask, .enterChildren, .exitToParent, .rootCycleTabPrevious,
      .rootCycleTabNext, .rootCycleFilterPrevious, .rootCycleFilterNext, .rootTabAll, .rootTabDue,
      .rootTabTags, .rootTabPriority, .rootFilter1, .rootFilter2, .rootFilter3, .rootFilter4,
      .rootFilter5, .rootFilter6, .rootFilter7, .rootTabKanban,
      .kanbanFocusLeft, .kanbanFocusRight, .kanbanShowInAll,
      .kanbanEnterTaskChildren, .kanbanExitToTaskParent, .kanbanFocusMode, .rootTabMatrix:
      return "Navigation"
    case .markDone, .invalidateTask, .addSibling, .addChild, .unindentTask, .editTaskAtEnd,
      .editTaskAtStart, .deleteTask, .moveTaskUp, .moveTaskDown, .undo, .clearPriority,
      .clearAbsolutePriority, .pushPriorityBack, .setPriorityRank, .setAbsolutePriorityRank,
      .kanbanMoveLeft, .kanbanMoveRight:
      return "Task Actions"
    case .openCommandPalette, .closeOrCancel, .focusSearch, .sequenceDue, .sequenceDueToday,
      .sequenceStart, .sequenceRepeat, .sequenceTag, .sequenceUntag, .sequenceToggleContext,
      .quickListSwitch, .quickAdd, .sequenceUrgency, .sequenceImportance, .sequenceMatrixCoord:
      return "Entry & Commands"
    case .openInObsidian, .openInObsidianNewWindow, .sequenceOpenLink, .sequenceGoogleCalendar,
      .toggleTimer, .toggleTimerPause, .toggleHideFuture:
      return "Integrations & Timer"
    }
  }

  var defaultBinding: String {
    switch self {
    case .openCommandPalette: return "cmd+k,;,shift+;"
    case .rootCycleTabPrevious: return "ctrl+left"
    case .rootCycleTabNext: return "ctrl+right"
    case .rootCycleFilterPrevious: return "ctrl+up"
    case .rootCycleFilterNext: return "ctrl+down"
    case .moveTaskUp: return "cmd+up,cmd+k"
    case .moveTaskDown: return "cmd+down,cmd+j"
    case .openInObsidian: return "o"
    case .openInObsidianNewWindow: return "shift+o"
    case .nextTask: return "down,j"
    case .previousTask: return "up,k"
    case .enterChildren: return "right,l"
    case .exitToParent: return "left,h"
    case .markDone: return "space"
    case .invalidateTask: return "shift+space"
    case .addSibling: return "enter"
    case .addChild: return "shift+enter,tab"
    case .unindentTask: return "shift+tab"
    case .closeOrCancel: return "escape"
    case .editTaskAtEnd: return "f2,a"
    case .editTaskAtStart: return "i"
    case .deleteTask: return "delete"
    case .rootTabAll: return "q"
    case .rootTabDue: return "w"
    case .rootTabTags: return "e"
    case .rootTabPriority: return "r"
    case .rootFilter1: return "z"
    case .rootFilter2: return "x"
    case .rootFilter3: return "c"
    case .rootFilter4: return "v"
    case .rootFilter5: return "b"
    case .rootFilter6: return "n"
    case .rootFilter7: return "comma"
    case .sequenceDue: return "dd"
    case .sequenceDueToday: return "dt"
    case .sequenceStart: return "ds"
    case .sequenceRepeat: return "dr"
    case .sequenceOpenLink: return "gg"
    case .sequenceGoogleCalendar: return "gc"
    case .sequenceTag: return "gt"
    case .sequenceUntag: return "gu"
    case .sequenceToggleContext: return "sc"
    case .toggleTimer: return "p"
    case .toggleTimerPause: return "shift+p"
    case .undo: return "u"
    case .toggleHideFuture: return "shift+h"
    case .quickListSwitch: return "shift+l"
    case .quickAdd: return "shift+a"
    case .focusSearch: return "/"
    case .clearPriority: return "-"
    case .clearAbsolutePriority: return "ctrl+cmd+option+shift+-"
    case .pushPriorityBack: return "="
    case .setPriorityRank: return "1,2,3,4,5,6,7,8,9"
    case .setAbsolutePriorityRank:
      return
        "ctrl+cmd+option+shift+1,ctrl+cmd+option+shift+2,ctrl+cmd+option+shift+3,ctrl+cmd+option+shift+4,ctrl+cmd+option+shift+5,ctrl+cmd+option+shift+6,ctrl+cmd+option+shift+7,ctrl+cmd+option+shift+8,ctrl+cmd+option+shift+9"
    case .kanbanMoveLeft: return "cmd+left"
    case .kanbanMoveRight: return "cmd+right"
    case .kanbanFocusLeft: return "left,h"
    case .kanbanFocusRight: return "right,l"
    case .rootTabKanban: return "t"
    case .kanbanShowInAll: return "f"
    case .kanbanEnterTaskChildren: return "]"
    case .kanbanExitToTaskParent: return "["
    case .kanbanFocusMode: return "'"
    case .rootTabMatrix: return "y"
    case .sequenceUrgency: return "mu"
    case .sequenceImportance: return "mi"
    case .sequenceMatrixCoord: return "mm"
    }
  }
}
