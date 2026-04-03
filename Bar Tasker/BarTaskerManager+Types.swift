import Foundation

extension BarTaskerManager {
  enum RootDueBucket: Int, CaseIterable {
    case overdue
    case asap
    case today
    case tomorrow
    case nextSevenDays
    case future
    case noDueDate

    var title: String {
      switch self {
      case .overdue: return "Overdue"
      case .asap: return "ASAP"
      case .today: return "Today"
      case .tomorrow: return "Tomorrow"
      case .nextSevenDays: return "Next 7 days"
      case .future: return "Further in the future"
      case .noDueDate: return "No due date"
      }
    }
  }

  enum RootTaskView: Int, CaseIterable {
    case all
    case due
    case tags
    case priority

    var title: String {
      switch self {
      case .all: return "All"
      case .due: return "Due"
      case .tags: return "Tags"
      case .priority: return "Priority"
      }
    }
  }

  enum OnboardingDialog: String, CaseIterable, Identifiable {
    case pluginSelection
    case checkvist
    case obsidian
    case googleCalendar
    case mcp

    var id: String { rawValue }
  }

  enum UndoableAction {
    case add(taskId: Int)
    case markDone(taskId: Int)
    case invalidate(taskId: Int)
    case update(taskId: Int, oldContent: String, oldDue: String?)
    case restoreOfflineState(snapshot: OfflineTaskStateSnapshot)
  }

  enum QuickEntryMode {
    case search
    case addSibling
    case addChild
    case editTask
    case command
    case quickAddDefault
    case quickAddSpecific
  }

  enum QuickAddLocationMode: Int, CaseIterable {
    case defaultRoot
    case specificParentTask
  }

  enum TimerMode: Int, CaseIterable {
    case visible
    case hidden
    case disabled
  }

  enum AppTheme: Int, CaseIterable {
    case system
    case light
    case dark
  }

  enum ThemeAccentPreset: String, CaseIterable, Identifiable {
    case blue
    case green
    case orange
    case red
    case violet
    case slate
    case custom

    var id: String { rawValue }

    var title: String {
      switch self {
      case .blue: return "Blue"
      case .green: return "Green"
      case .orange: return "Orange"
      case .red: return "Red"
      case .violet: return "Violet"
      case .slate: return "Slate"
      case .custom: return "Custom"
      }
    }

    var hex: String {
      switch self {
      case .blue: return "#0A84FF"
      case .green: return "#30D158"
      case .orange: return "#FF9F0A"
      case .red: return "#FF453A"
      case .violet: return "#BF5AF2"
      case .slate: return "#8E8E93"
      case .custom: return Self.blue.hex
      }
    }
  }

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
    case pushPriorityBack
    case setPriorityRank

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
      case .focusSearch: return "Focus search"
      case .clearPriority: return "Clear priority"
      case .pushPriorityBack: return "Send priority to back"
      case .setPriorityRank: return "Set priority rank"
      }
    }

    var category: String {
      switch self {
      case .nextTask, .previousTask, .enterChildren, .exitToParent, .rootCycleTabPrevious,
        .rootCycleTabNext, .rootCycleFilterPrevious, .rootCycleFilterNext, .rootTabAll, .rootTabDue,
        .rootTabTags, .rootTabPriority, .rootFilter1, .rootFilter2, .rootFilter3, .rootFilter4,
        .rootFilter5, .rootFilter6, .rootFilter7:
        return "Navigation"
      case .markDone, .invalidateTask, .addSibling, .addChild, .unindentTask, .editTaskAtEnd,
        .editTaskAtStart, .deleteTask, .moveTaskUp, .moveTaskDown, .undo, .clearPriority,
        .pushPriorityBack, .setPriorityRank:
        return "Task Actions"
      case .openCommandPalette, .closeOrCancel, .focusSearch, .sequenceDue, .sequenceDueToday,
        .sequenceStart, .sequenceTag, .sequenceUntag, .sequenceToggleContext, .quickListSwitch,
        .quickAdd:
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
      case .moveTaskUp: return "cmd+up"
      case .moveTaskDown: return "cmd+down"
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
      case .rootFilter7: return "m"
      case .sequenceDue: return "dd"
      case .sequenceDueToday: return "dt"
      case .sequenceStart: return "ds"
      case .sequenceOpenLink: return "gg"
      case .sequenceGoogleCalendar: return "gc"
      case .sequenceTag: return "gt"
      case .sequenceUntag: return "gu"
      case .sequenceToggleContext: return "sc"
      case .toggleTimer: return "t"
      case .toggleTimerPause: return "p"
      case .undo: return "u"
      case .toggleHideFuture: return "shift+h"
      case .quickListSwitch: return "shift+l"
      case .quickAdd: return "shift+a"
      case .focusSearch: return "/"
      case .clearPriority: return "-"
      case .pushPriorityBack: return "="
      case .setPriorityRank: return "1,2,3,4,5,6,7,8,9"
      }
    }
  }

  struct CommandSuggestion {
    let label: String
    let command: String
    let preview: String
    let keybind: String?
    let submitImmediately: Bool
  }
}
