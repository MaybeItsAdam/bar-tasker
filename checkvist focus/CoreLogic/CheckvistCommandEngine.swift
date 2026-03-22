import Foundation

struct CheckvistCommandSuggestion: Equatable {
  let label: String
  let command: String
  let preview: String
  let keybind: String?
  let submitImmediately: Bool
}

enum CheckvistCommand: Equatable {
  case done
  case undone
  case invalidate
  case due(String)
  case clearDue
  case edit
  case search
  case addSibling
  case addChild
  case openLink
  case undo
  case toggleTimer
  case pauseTimer
  case toggleHideFuture
  case delete
  case moveUp
  case moveDown
  case enterChildren
  case exitParent
  case tag(String)
  case untag(String)
  case list(String)
  case priority(Int)
  case priorityBack
  case clearPriority
  case syncObsidian
  case syncObsidianNewWindow
  case linkObsidianFolder
  case createObsidianFolder
  case clearObsidianFolderLink
  case unknown(String)
}

enum CheckvistCommandEngine {
  static let suggestions: [CheckvistCommandSuggestion] = [
    .init(
      label: "Mark done", command: "done", preview: "Close selected task", keybind: "Space",
      submitImmediately: true),
    .init(
      label: "Mark undone", command: "undone", preview: "Undo last completion/action", keybind: "u",
      submitImmediately: true),
    .init(
      label: "Invalidate task", command: "invalidate", preview: "Invalidate selected task",
      keybind: "Shift+Space", submitImmediately: true),
    .init(
      label: "Due today", command: "due today", preview: "Set due date to today", keybind: "dd",
      submitImmediately: true),
    .init(
      label: "Due tomorrow", command: "due tomorrow", preview: "Set due date to tomorrow",
      keybind: "dd", submitImmediately: true),
    .init(
      label: "Due next week", command: "due next week", preview: "Set due date to next week",
      keybind: "dd", submitImmediately: true),
    .init(
      label: "Clear due date", command: "clear due", preview: "Remove due date", keybind: "dd",
      submitImmediately: true),
    .init(
      label: "Add tag", command: "tag ", preview: "Append #tag to task", keybind: "gt",
      submitImmediately: false),
    .init(
      label: "Remove tag", command: "untag ", preview: "Remove #tag from task", keybind: "gu",
      submitImmediately: false),
    .init(
      label: "Set priority", command: "priority 1",
      preview: "Set selected task priority (1-9)", keybind: "1-9", submitImmediately: false),
    .init(
      label: "Send to priority back", command: "priority back",
      preview: "Move selected task to end of priority list", keybind: "=",
      submitImmediately: true),
    .init(
      label: "Clear priority", command: "clear priority",
      preview: "Remove selected task from priority list", keybind: "-",
      submitImmediately: true),
    .init(
      label: "Open in Obsidian", command: "sync obsidian",
      preview: "Write selected task and notes, then open it in Obsidian", keybind: "o",
      submitImmediately: true),
    .init(
      label: "Open in Obsidian (New Window)", command: "open obsidian new window",
      preview: "Write selected task and open it in a new Obsidian window", keybind: "O",
      submitImmediately: true),
    .init(
      label: "Link Obsidian folder", command: "link obsidian folder",
      preview: "Choose a folder for this task and its subtasks", keybind: nil,
      submitImmediately: true),
    .init(
      label: "Create Obsidian folder", command: "create obsidian folder",
      preview: "Create and link a new folder for this task subtree", keybind: nil,
      submitImmediately: true),
    .init(
      label: "Clear Obsidian folder link", command: "clear obsidian folder",
      preview: "Remove the linked folder for this task subtree", keybind: nil,
      submitImmediately: true),
    .init(
      label: "Switch list", command: "list ", preview: "Find and switch list", keybind: "Shift+L",
      submitImmediately: false),
    .init(
      label: "Edit task", command: "edit", preview: "Edit selected task",
      keybind: "i / a / F2", submitImmediately: true),
    .init(
      label: "Focus search", command: "search", preview: "Search tasks", keybind: "/",
      submitImmediately: true),
    .init(
      label: "Add sibling task", command: "add sibling", preview: "Create sibling below selection",
      keybind: "Enter", submitImmediately: true),
    .init(
      label: "Add child task", command: "add child", preview: "Create child under selection",
      keybind: "Shift+Enter / Tab", submitImmediately: true),
    .init(
      label: "Open first link", command: "open link", preview: "Open first URL in task text",
      keybind: "gg", submitImmediately: true),
    .init(
      label: "Undo last action", command: "undo", preview: "Undo add/complete/edit", keybind: "u",
      submitImmediately: true),
    .init(
      label: "Toggle timer", command: "toggle timer",
      preview: "Start/switch timer on selected task",
      keybind: "t", submitImmediately: true),
    .init(
      label: "Pause/resume timer", command: "pause timer", preview: "Pause or resume active timer",
      keybind: "p", submitImmediately: true),
    .init(
      label: "Toggle hide future", command: "toggle hide future",
      preview: "Show/hide future tasks", keybind: "Shift+H", submitImmediately: true),
    .init(
      label: "Delete selected task", command: "delete", preview: "Delete current task",
      keybind: "Del", submitImmediately: true),
    .init(
      label: "Move task up", command: "move up", preview: "Reorder current task upward",
      keybind: "Cmd+↑", submitImmediately: true),
    .init(
      label: "Move task down", command: "move down", preview: "Reorder current task downward",
      keybind: "Cmd+↓", submitImmediately: true),
    .init(
      label: "Enter subtasks", command: "enter children", preview: "Go to child level",
      keybind: "l / →", submitImmediately: true),
    .init(
      label: "Exit to parent", command: "exit parent", preview: "Go up one level",
      keybind: "h / ←", submitImmediately: true),
  ]

  static func filteredSuggestions(query: String, limit: Int = 8) -> [CheckvistCommandSuggestion] {
    let q = query.lowercased().trimmingCharacters(in: .whitespaces)
    let candidates = suggestions.filter { suggestion in
      q.isEmpty
        || suggestion.label.lowercased().contains(q)
        || suggestion.command.lowercased().contains(q)
        || suggestion.preview.lowercased().contains(q)
        || (suggestion.keybind?.lowercased().contains(q) ?? false)
    }
    return Array(candidates.prefix(limit))
  }

  static func parse(_ input: String) -> CheckvistCommand {
    let cmd = input.lowercased().trimmingCharacters(in: .whitespaces)
    if cmd == "done" { return .done }
    if cmd == "undone" { return .undone }
    if cmd == "invalidate" { return .invalidate }
    if cmd.hasPrefix("due ") {
      let raw = String(cmd.dropFirst(4)).trimmingCharacters(in: .whitespaces)
      return .due(raw)
    }
    if cmd == "clear due" { return .clearDue }
    if cmd == "edit" { return .edit }
    if cmd == "search" { return .search }
    if cmd == "add sibling" { return .addSibling }
    if cmd == "add child" { return .addChild }
    if cmd == "open link" { return .openLink }
    if cmd == "undo" { return .undo }
    if cmd == "toggle timer" { return .toggleTimer }
    if cmd == "pause timer" { return .pauseTimer }
    if cmd == "toggle hide future" { return .toggleHideFuture }
    if cmd == "delete" { return .delete }
    if cmd == "move up" { return .moveUp }
    if cmd == "move down" { return .moveDown }
    if cmd == "enter children" { return .enterChildren }
    if cmd == "exit parent" { return .exitParent }
    if cmd.hasPrefix("tag ") {
      return .tag(String(cmd.dropFirst(4)).trimmingCharacters(in: .whitespaces))
    }
    if cmd.hasPrefix("untag ") {
      return .untag(String(cmd.dropFirst(6)).trimmingCharacters(in: .whitespaces))
    }
    if cmd.hasPrefix("list ") {
      return .list(String(cmd.dropFirst(5)).trimmingCharacters(in: .whitespaces))
    }
    if cmd.hasPrefix("priority ") {
      let raw = String(cmd.dropFirst(9)).trimmingCharacters(in: .whitespaces)
      if raw == "back" || raw == "end" {
        return .priorityBack
      }
      if raw == "clear" {
        return .clearPriority
      }
      if let rank = Int(raw), (1...9).contains(rank) {
        return .priority(rank)
      }
    }
    if cmd == "clear priority" || cmd == "unpriority" {
      return .clearPriority
    }
    if cmd == "sync obsidian" || cmd == "send to obsidian" || cmd == "obsidian" {
      return .syncObsidian
    }
    if cmd == "open obsidian new window" || cmd == "obsidian new window"
      || cmd == "open in new window"
    {
      return .syncObsidianNewWindow
    }
    if cmd == "link obsidian folder" || cmd == "link folder" || cmd == "obsidian folder" {
      return .linkObsidianFolder
    }
    if cmd == "create obsidian folder" || cmd == "new obsidian folder"
      || cmd == "make obsidian folder"
    {
      return .createObsidianFolder
    }
    if cmd == "clear obsidian folder" || cmd == "unlink obsidian folder"
      || cmd == "clear folder link"
    {
      return .clearObsidianFolderLink
    }
    return .unknown(input)
  }

  static func resolveDueDate(_ input: String, now: Date = Date(), calendar: Calendar = .current)
    -> String
  {
    let cal = calendar
    let isoFormatter: DateFormatter = {
      let formatter = DateFormatter()
      formatter.calendar = cal
      formatter.dateFormat = "yyyy-MM-dd"
      return formatter
    }()

    switch input.lowercased() {
    case "today":
      return isoFormatter.string(from: now)
    case "tomorrow":
      guard let date = cal.date(byAdding: .day, value: 1, to: now) else { return input }
      return isoFormatter.string(from: date)
    case "next week":
      guard let date = cal.date(byAdding: .weekOfYear, value: 1, to: now) else { return input }
      return isoFormatter.string(from: date)
    case "next month":
      guard let date = cal.date(byAdding: .month, value: 1, to: now) else { return input }
      return isoFormatter.string(from: date)
    case "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday":
      let weekdays = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
        "thursday": 5, "friday": 6, "saturday": 7,
      ]
      guard let target = weekdays[input.lowercased()] else { return input }
      let current = cal.component(.weekday, from: now)
      var diff = target - current
      if diff <= 0 { diff += 7 }
      guard let date = cal.date(byAdding: .day, value: diff, to: now) else { return input }
      return isoFormatter.string(from: date)
    default:
      return input
    }
  }
}
