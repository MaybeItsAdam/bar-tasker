import Foundation

// MARK: - Date Parsing Config

/// User-customisable named-time shortcuts used by the natural language date parser.
struct BarTaskerDateParsingConfig: Equatable {
  var morningHour: Int = 9
  var afternoonHour: Int = 14
  var eveningHour: Int = 18
  var eodHour: Int = 17
}

struct BarTaskerCommandSuggestion: Equatable, Sendable {
  let label: String
  let command: String
  let preview: String
  let keybind: String?
  let submitImmediately: Bool
}

enum BarTaskerCommand: Equatable, Sendable {
  case done
  case undone
  case invalidate
  case due(String)
  case clearDue
  case setStart(String)
  case clearStart
  case setRecurrence(String)
  case clearRecurrence
  case edit
  case search
  case openPreferences
  case reloadCheckvistLists
  case uploadOfflineTasks
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
  case chooseObsidianInbox
  case clearObsidianInbox
  case linkObsidianFolder
  case createObsidianFolder
  case clearObsidianFolderLink
  case syncGoogleCalendar
  case refreshMCPPath
  case copyMCPClientConfig
  case openMCPGuide
  case unknown(String)
}

// swiftlint:disable type_body_length
enum BarTaskerCommandEngine {
  static let suggestions: [BarTaskerCommandSuggestion] = [
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
      label: "Due today at time", command: "due today ",
      preview: "Set due date with time (for example 14:30 or 9am)", keybind: "dt",
      submitImmediately: false),
    .init(
      label: "Clear due date", command: "clear due", preview: "Remove due date", keybind: "dd",
      submitImmediately: true),
    .init(
      label: "Start today", command: "start today", preview: "Set start date to today",
      keybind: "ds", submitImmediately: true),
    .init(
      label: "Start tomorrow", command: "start tomorrow", preview: "Set start date to tomorrow",
      keybind: "ds", submitImmediately: true),
    .init(
      label: "Start next week", command: "start next week",
      preview: "Set start date to next week", keybind: "ds", submitImmediately: true),
    .init(
      label: "Start at time", command: "start today ",
      preview: "Set start date with time (e.g. 9am, 14:30, next mon 9am)",
      keybind: "ds", submitImmediately: false),
    .init(
      label: "Clear start date", command: "clear start", preview: "Remove start date",
      keybind: "ds", submitImmediately: true),
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
      label: "Repeat daily", command: "repeat daily",
      preview: "Schedule this task to recur every day", keybind: "dr",
      submitImmediately: true),
    .init(
      label: "Repeat weekdays", command: "repeat weekdays",
      preview: "Schedule this task to recur every weekday (Mon–Fri)", keybind: "dr",
      submitImmediately: true),
    .init(
      label: "Repeat weekly", command: "repeat weekly",
      preview: "Schedule this task to recur every week on the same day", keybind: "dr",
      submitImmediately: true),
    .init(
      label: "Repeat every N days/weeks", command: "repeat every ",
      preview: "e.g. repeat every 3 days, repeat every 2 weeks", keybind: "dr",
      submitImmediately: false),
    .init(
      label: "Repeat every weekday", command: "repeat every monday",
      preview: "Recur on a specific weekday (e.g. every monday)", keybind: "dr",
      submitImmediately: false),
    .init(
      label: "Clear repeat", command: "clear repeat",
      preview: "Remove recurring rule from task", keybind: "dr",
      submitImmediately: true),
    .init(
      label: "Reload Checkvist lists", command: "reload checkvist lists",
      preview: "Refresh available Checkvist workspaces", keybind: nil,
      submitImmediately: true),
    .init(
      label: "Upload offline tasks", command: "upload offline tasks",
      preview: "Copy the offline workspace into the active or first loaded Checkvist list",
      keybind: nil, submitImmediately: true),
    .init(
      label: "Open in Obsidian", command: "sync obsidian",
      preview: "Write selected task and notes, then open it in Obsidian", keybind: "o",
      submitImmediately: true),
    .init(
      label: "Open in Obsidian (New Window)", command: "open obsidian new window",
      preview: "Write selected task and open it in a new Obsidian window", keybind: "O",
      submitImmediately: true),
    .init(
      label: "Choose Obsidian inbox folder", command: "choose obsidian inbox",
      preview: "Pick the default Obsidian inbox used for task sync", keybind: nil,
      submitImmediately: true),
    .init(
      label: "Clear Obsidian inbox folder", command: "clear obsidian inbox",
      preview: "Remove the default Obsidian inbox folder", keybind: nil,
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
      label: "Create Google Calendar event", command: "sync google calendar",
      preview: "Create a Google Calendar event from the selected task", keybind: "gc",
      submitImmediately: true),
    .init(
      label: "Refresh MCP path", command: "refresh mcp path",
      preview: "Re-detect the built-in MCP server command path", keybind: nil,
      submitImmediately: true),
    .init(
      label: "Copy MCP client config", command: "copy mcp config",
      preview: "Copy the MCP client configuration to the clipboard", keybind: nil,
      submitImmediately: true),
    .init(
      label: "Open MCP guide", command: "open mcp guide",
      preview: "Open the local MCP setup guide", keybind: nil,
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
      label: "Open preferences", command: "preferences",
      preview: "Open Bar Tasker preferences",
      keybind: "Cmd+,", submitImmediately: true),
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

  static func filteredSuggestions(query: String, limit: Int? = nil) -> [BarTaskerCommandSuggestion]
  {
    let queryText = query.lowercased().trimmingCharacters(in: .whitespaces)
    let candidates = suggestions.filter { suggestion in
      queryText.isEmpty
        || suggestion.label.lowercased().contains(queryText)
        || suggestion.command.lowercased().contains(queryText)
        || suggestion.preview.lowercased().contains(queryText)
        || (suggestion.keybind?.lowercased().contains(queryText) ?? false)
    }
    guard let limit else { return candidates }
    return Array(candidates.prefix(limit))
  }

  // swiftlint:disable:next cyclomatic_complexity
  static func parse(_ input: String) -> BarTaskerCommand {
    let cmd = input.lowercased().trimmingCharacters(in: .whitespaces)
    if cmd == "done" { return .done }
    if cmd == "undone" { return .undone }
    if cmd == "invalidate" { return .invalidate }
    if cmd.hasPrefix("due ") {
      let raw = String(cmd.dropFirst(4)).trimmingCharacters(in: .whitespaces)
      return .due(raw)
    }
    if cmd == "clear due" { return .clearDue }
    if cmd.hasPrefix("start ") {
      let raw = String(cmd.dropFirst(6)).trimmingCharacters(in: .whitespaces)
      return .setStart(raw)
    }
    if cmd == "clear start" || cmd == "remove start" || cmd == "unstart" { return .clearStart }
    if cmd.hasPrefix("repeat ") {
      let raw = String(cmd.dropFirst(7)).trimmingCharacters(in: .whitespaces)
      return .setRecurrence(raw)
    }
    if cmd == "clear repeat" || cmd == "remove repeat" || cmd == "no repeat" || cmd == "unrepeat" {
      return .clearRecurrence
    }
    if cmd == "edit" { return .edit }
    if cmd == "search" { return .search }
    if cmd == "preferences" || cmd == "prefs" || cmd == "settings" {
      return .openPreferences
    }
    if cmd == "reload checkvist lists" || cmd == "reload lists" || cmd == "refresh lists" {
      return .reloadCheckvistLists
    }
    if cmd == "upload offline tasks" || cmd == "upload offline" {
      return .uploadOfflineTasks
    }
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
    if cmd == "choose obsidian inbox" || cmd == "choose inbox folder"
      || cmd == "obsidian inbox"
    {
      return .chooseObsidianInbox
    }
    if cmd == "clear obsidian inbox" || cmd == "clear inbox folder" {
      return .clearObsidianInbox
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
    if cmd == "sync google calendar" || cmd == "google calendar" || cmd == "gcal"
      || cmd == "open google calendar" || cmd == "calendar"
    {
      return .syncGoogleCalendar
    }
    if cmd == "refresh mcp path" || cmd == "mcp refresh path" {
      return .refreshMCPPath
    }
    if cmd == "copy mcp config" || cmd == "mcp config" || cmd == "mcp copy config" {
      return .copyMCPClientConfig
    }
    if cmd == "open mcp guide" || cmd == "mcp guide" {
      return .openMCPGuide
    }
    return .unknown(input)
  }

  static func resolveDueDate(
    _ input: String,
    now: Date = Date(),
    calendar: Calendar = .current,
    config: BarTaskerDateParsingConfig = .init()
  ) -> String {
    let rawInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rawInput.isEmpty else { return input }

    let cal = calendar
    let dateOnlyFormatter: DateFormatter = {
      let formatter = DateFormatter()
      formatter.calendar = cal
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = cal.timeZone
      formatter.dateFormat = "yyyy-MM-dd"
      return formatter
    }()
    let dateTimeFormatter: DateFormatter = {
      let formatter = DateFormatter()
      formatter.calendar = cal
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = cal.timeZone
      formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
      return formatter
    }()

    let normalized = rawInput.lowercased()

    // Try "time keyword" order first (e.g. "4pm fri", "9am tomorrow").
    if let swapped = resolveTimeFirstExpression(normalized, now: now, calendar: cal, config: config) {
      return dateTimeFormatter.string(from: swapped)
    }

    if let relative = resolveRelativeDateExpression(normalized, now: now, calendar: cal) {
      if let timeText = relative.timeText {
        guard
          let timeComponents = parseTimeComponents(from: timeText, config: config),
          let dateTime = combine(date: relative.baseDate, with: timeComponents, calendar: cal)
        else {
          return rawInput
        }
        return dateTimeFormatter.string(from: dateTime)
      }
      return dateOnlyFormatter.string(from: relative.baseDate)
    }

    if let relativeOffsetDate = resolveRelativeOffsetExpression(normalized, now: now, calendar: cal)
    {
      return dateTimeFormatter.string(from: relativeOffsetDate)
    }

    if let absolute = resolveAbsoluteDateExpression(normalized, calendar: cal) {
      if let timeText = absolute.timeText {
        guard
          let timeComponents = parseTimeComponents(from: timeText, config: config),
          let dateTime = combine(date: absolute.baseDate, with: timeComponents, calendar: cal)
        else {
          return rawInput
        }
        return dateTimeFormatter.string(from: dateTime)
      }
      return dateOnlyFormatter.string(from: absolute.baseDate)
    }

    if let timeComponents = parseTimeComponents(from: normalized, config: config),
      let dateTime = combine(date: now, with: timeComponents, calendar: cal)
    {
      return dateTimeFormatter.string(from: dateTime)
    }

    return rawInput
  }

  /// Full and abbreviated weekday name → Calendar weekday component (Sun=1 … Sat=7)
  private static let weekdayNumbers: [String: Int] = [
    "sunday": 1, "sun": 1,
    "monday": 2, "mon": 2,
    "tuesday": 3, "tue": 3, "tues": 3,
    "wednesday": 4, "wed": 4,
    "thursday": 5, "thu": 5, "thur": 5, "thurs": 5,
    "friday": 6, "fri": 6,
    "saturday": 7, "sat": 7,
  ]

  private static func resolveRelativeDateExpression(
    _ normalized: String,
    now: Date,
    calendar: Calendar
  ) -> (baseDate: Date, timeText: String?)? {
    if let timeText = timeSuffix(for: normalized, keyword: "today") {
      return (now, timeText.isEmpty ? nil : timeText)
    }
    if let timeText = timeSuffix(for: normalized, keyword: "tomorrow"),
      let date = calendar.date(byAdding: .day, value: 1, to: now)
    {
      return (date, timeText.isEmpty ? nil : timeText)
    }
    if let timeText = timeSuffix(for: normalized, keyword: "next week"),
      let date = calendar.date(byAdding: .weekOfYear, value: 1, to: now)
    {
      return (date, timeText.isEmpty ? nil : timeText)
    }
    if let timeText = timeSuffix(for: normalized, keyword: "next month"),
      let date = calendar.date(byAdding: .month, value: 1, to: now)
    {
      return (date, timeText.isEmpty ? nil : timeText)
    }

    // "next <weekday>" — always picks the coming occurrence even if today matches
    for (name, weekdayValue) in weekdayNumbers {
      guard let timeText = timeSuffix(for: normalized, keyword: "next \(name)") else { continue }
      let currentWeekday = calendar.component(.weekday, from: now)
      var diff = weekdayValue - currentWeekday
      if diff <= 0 { diff += 7 }
      guard let date = calendar.date(byAdding: .day, value: diff, to: now) else { continue }
      return (date, timeText.isEmpty ? nil : timeText)
    }

    // "this <weekday>" — nearest occurrence within the current calendar week
    for (name, weekdayValue) in weekdayNumbers {
      guard let timeText = timeSuffix(for: normalized, keyword: "this \(name)") else { continue }
      let currentWeekday = calendar.component(.weekday, from: now)
      var diff = weekdayValue - currentWeekday
      // "this" means within the current week — if the day has passed, keep 0 offset (today)
      if diff < 0 { diff = 0 }
      guard let date = calendar.date(byAdding: .day, value: diff, to: now) else { continue }
      return (date, timeText.isEmpty ? nil : timeText)
    }

    // Plain weekday name — next occurrence (allows today if diff would be 0, skip to next week)
    for (name, weekdayValue) in weekdayNumbers {
      guard let timeText = timeSuffix(for: normalized, keyword: name) else { continue }
      let currentWeekday = calendar.component(.weekday, from: now)
      var diff = weekdayValue - currentWeekday
      if diff <= 0 { diff += 7 }
      guard let date = calendar.date(byAdding: .day, value: diff, to: now) else { continue }
      return (date, timeText.isEmpty ? nil : timeText)
    }

    return nil
  }

  /// Handles "time keyword" order: "4pm fri", "9am tomorrow", "morning next monday"
  private static func resolveTimeFirstExpression(
    _ normalized: String,
    now: Date,
    calendar: Calendar,
    config: BarTaskerDateParsingConfig
  ) -> Date? {
    let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
    guard let match = timeFirstRegex.firstMatch(in: normalized, options: [], range: range),
      let timePart = Range(match.range(at: 1), in: normalized),
      let datePart = Range(match.range(at: 2), in: normalized)
    else { return nil }

    let timeText = String(normalized[timePart])
    let dateKeyword = String(normalized[datePart])

    guard let relative = resolveRelativeDateExpression(dateKeyword, now: now, calendar: calendar)
    else { return nil }

    guard relative.timeText == nil else { return nil }

    guard let timeComponents = parseTimeComponents(from: timeText, config: config) else { return nil }
    return combine(date: relative.baseDate, with: timeComponents, calendar: calendar)
  }

  private static let relativeOffsetRegex = makeRegex(
    #"^in\s+(a|an|\d+)\s*(m|min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days|w|wk|wks|week|weeks)$"#
  )
  private static let twelveHourRegex = makeRegex(
    #"^(1[0-2]|0?[1-9])(?::([0-5]\d))?\s*([ap]m)$"#)
  private static let twentyFourHourRegex = makeRegex(
    #"^([01]?\d|2[0-3])(?::([0-5]\d))?$"#)
  // Matches "4pm fri", "3:30pm next monday", "9am tomorrow" — time BEFORE the date keyword
  private static let timeFirstRegex = makeRegex(
    #"^((?:1[0-2]|0?[1-9])(?::[0-5]\d)?\s*[ap]m|(?:[01]?\d|2[0-3]):[0-5]\d|noon|midnight|morning|afternoon|evening|eod)\s+(.+)$"#
  )

  private static func makeRegex(_ pattern: String) -> NSRegularExpression {
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      fatalError("Invalid regex pattern: \(pattern)")
    }
    return regex
  }

  private static func resolveRelativeOffsetExpression(
    _ normalized: String,
    now: Date,
    calendar: Calendar
  ) -> Date? {
    let regex = relativeOffsetRegex
    let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
    guard let match = regex.firstMatch(in: normalized, options: [], range: range) else {
      return nil
    }
    guard
      let amountRange = Range(match.range(at: 1), in: normalized),
      let unitRange = Range(match.range(at: 2), in: normalized)
    else { return nil }

    let amountStr = String(normalized[amountRange])
    let amount: Int
    if amountStr == "a" || amountStr == "an" {
      amount = 1
    } else if let n = Int(amountStr), n > 0 {
      amount = n
    } else {
      return nil
    }

    let unit = String(normalized[unitRange])
    let component: Calendar.Component
    switch unit {
    case "m", "min", "mins", "minute", "minutes":
      component = .minute
    case "h", "hr", "hrs", "hour", "hours":
      component = .hour
    case "d", "day", "days":
      component = .day
    case "w", "wk", "wks", "week", "weeks":
      component = .weekOfYear
    default:
      return nil
    }

    return calendar.date(byAdding: component, value: amount, to: now)
  }

  private static func resolveAbsoluteDateExpression(_ normalized: String, calendar: Calendar)
    -> (baseDate: Date, timeText: String?)?
  {
    let datePart: String
    let timePart: String?
    if let separatorIndex = normalized.firstIndex(where: { $0 == " " || $0 == "t" }) {
      datePart = String(normalized[..<separatorIndex])
      let remainder = normalized[normalized.index(after: separatorIndex)...]
      let trimmedRemainder = String(remainder).trimmingCharacters(in: .whitespaces)
      timePart = trimmedRemainder.isEmpty ? nil : trimmedRemainder
    } else {
      datePart = normalized
      timePart = nil
    }

    let components = datePart.split(separator: "-", omittingEmptySubsequences: false)
    guard components.count == 3, components[0].count == 4 else { return nil }
    guard
      let year = Int(components[0]),
      let month = Int(components[1]),
      let day = Int(components[2])
    else {
      return nil
    }

    var dateComponents = DateComponents()
    dateComponents.calendar = calendar
    dateComponents.timeZone = calendar.timeZone
    dateComponents.year = year
    dateComponents.month = month
    dateComponents.day = day
    guard let date = calendar.date(from: dateComponents) else { return nil }
    return (date, timePart)
  }

  private static func timeSuffix(for normalized: String, keyword: String) -> String? {
    guard normalized == keyword || normalized.hasPrefix(keyword + " ") else { return nil }
    return String(normalized.dropFirst(keyword.count)).trimmingCharacters(in: .whitespaces)
  }

  private static func parseTimeComponents(
    from rawTime: String,
    config: BarTaskerDateParsingConfig = .init()
  ) -> DateComponents? {
    var normalized = rawTime.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized.hasPrefix("at ") {
      normalized = String(normalized.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !normalized.isEmpty else { return nil }

    if normalized == "noon" {
      return DateComponents(hour: 12, minute: 0, second: 0)
    }
    if normalized == "midnight" {
      return DateComponents(hour: 0, minute: 0, second: 0)
    }
    if normalized == "morning" {
      return DateComponents(hour: config.morningHour, minute: 0, second: 0)
    }
    if normalized == "afternoon" {
      return DateComponents(hour: config.afternoonHour, minute: 0, second: 0)
    }
    if normalized == "evening" {
      return DateComponents(hour: config.eveningHour, minute: 0, second: 0)
    }
    if normalized == "eod" || normalized == "end of day" || normalized == "cob" {
      return DateComponents(hour: config.eodHour, minute: 0, second: 0)
    }

    if let captures = captureGroups(regex: twelveHourRegex, in: normalized), captures.count >= 3 {
      guard var hour = Int(captures[0]) else { return nil }
      let minute = Int(captures[1]) ?? 0
      let meridiem = captures[2]
      if meridiem == "pm" && hour != 12 { hour += 12 }
      if meridiem == "am" && hour == 12 { hour = 0 }
      return DateComponents(hour: hour, minute: minute, second: 0)
    }

    if let captures = captureGroups(regex: twentyFourHourRegex, in: normalized),
      captures.count >= 2
    {
      guard let hour = Int(captures[0]) else { return nil }
      let minute = Int(captures[1]) ?? 0
      return DateComponents(hour: hour, minute: minute, second: 0)
    }

    return nil
  }

  private static func captureGroups(regex: NSRegularExpression, in text: String) -> [String]? {
    let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: fullRange) else { return nil }

    var groups: [String] = []
    for captureIndex in 1..<match.numberOfRanges {
      let captureRange = match.range(at: captureIndex)
      guard captureRange.location != NSNotFound, let range = Range(captureRange, in: text) else {
        groups.append("")
        continue
      }
      groups.append(String(text[range]))
    }
    return groups
  }

  private static func combine(date: Date, with time: DateComponents, calendar: Calendar) -> Date? {
    var components = calendar.dateComponents([.year, .month, .day], from: date)
    components.calendar = calendar
    components.timeZone = calendar.timeZone
    components.hour = time.hour
    components.minute = time.minute
    components.second = time.second ?? 0
    return calendar.date(from: components)
  }
}
// swiftlint:enable type_body_length
