import AppKit
import Combine
import Foundation
import OSLog
import ServiceManagement
import SwiftUI

extension KeyedDecodingContainer {
  fileprivate func decodeLossyString(forKey key: Key) -> String? {
    if let value = try? decodeIfPresent(String.self, forKey: key) {
      return value
    }
    if let value = try? decodeIfPresent(Int.self, forKey: key) {
      return String(value)
    }
    if let value = try? decodeIfPresent(Double.self, forKey: key) {
      return String(value)
    }
    if let value = try? decodeIfPresent(Bool.self, forKey: key) {
      return value ? "true" : "false"
    }
    return nil
  }

  fileprivate func decodeLossyInt(forKey key: Key) -> Int? {
    if let value = try? decodeIfPresent(Int.self, forKey: key) {
      return value
    }
    if let value = try? decodeIfPresent(String.self, forKey: key) {
      return Int(value)
    }
    if let value = try? decodeIfPresent(Double.self, forKey: key) {
      return Int(value)
    }
    return nil
  }
}

struct CheckvistNote: Codable, Identifiable {
  let id: Int?
  let content: String
  let createdAt: String?
  let updatedAt: String?

  enum CodingKeys: String, CodingKey {
    case id, content
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }

  private enum DecodingKeys: String, CodingKey {
    case id, content
    case text
    case note
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }

  init(id: Int?, content: String, createdAt: String?, updatedAt: String?) {
    self.id = id
    self.content = content
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  init(from decoder: Decoder) throws {
    if let singleValue = try? decoder.singleValueContainer() {
      if let stringValue = try? singleValue.decode(String.self) {
        self.init(id: nil, content: stringValue, createdAt: nil, updatedAt: nil)
        return
      }
    }

    let container = try decoder.container(keyedBy: DecodingKeys.self)
    let id = container.decodeLossyInt(forKey: .id)
    let content =
      container.decodeLossyString(forKey: .content)
      ?? container.decodeLossyString(forKey: .text)
      ?? container.decodeLossyString(forKey: .note)
      ?? ""
    let createdAt = container.decodeLossyString(forKey: .createdAt)
    let updatedAt = container.decodeLossyString(forKey: .updatedAt)
    self.init(id: id, content: content, createdAt: createdAt, updatedAt: updatedAt)
  }
}

struct CheckvistTask: Codable, Identifiable {
  let id: Int
  let content: String
  let status: Int
  let due: String?
  let position: Int?
  let parentId: Int?
  let level: Int?
  let notes: [CheckvistNote]?
  let updatedAt: String?

  enum CodingKeys: String, CodingKey {
    case id, content, status, due, position
    case parentId = "parent_id"
    case level, notes
    case updatedAt = "updated_at"
  }

  private enum DecodingKeys: String, CodingKey {
    case id, content, status, due, position
    case parentId = "parent_id"
    case level, notes
    case text
    case updatedAt = "updated_at"
  }

  init(
    id: Int,
    content: String,
    status: Int,
    due: String?,
    position: Int?,
    parentId: Int?,
    level: Int?,
    notes: [CheckvistNote]? = nil,
    updatedAt: String? = nil
  ) {
    self.id = id
    self.content = content
    self.status = status
    self.due = due
    self.position = position
    self.parentId = parentId
    self.level = level
    self.notes = notes
    self.updatedAt = updatedAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: DecodingKeys.self)

    guard let id = container.decodeLossyInt(forKey: .id) else {
      throw DecodingError.keyNotFound(
        DecodingKeys.id,
        .init(codingPath: decoder.codingPath, debugDescription: "Task id is missing")
      )
    }

    let content =
      container.decodeLossyString(forKey: .content)
      ?? container.decodeLossyString(forKey: .text)
      ?? ""
    let status = container.decodeLossyInt(forKey: .status) ?? 0
    let due = container.decodeLossyString(forKey: .due)
    let position = container.decodeLossyInt(forKey: .position)
    let parentId = container.decodeLossyInt(forKey: .parentId)
    let level = container.decodeLossyInt(forKey: .level)
    let updatedAt = container.decodeLossyString(forKey: .updatedAt)

    let notes: [CheckvistNote]?
    if let decodedNotes = try? container.decodeIfPresent([CheckvistNote].self, forKey: .notes) {
      notes = decodedNotes
    } else if let singleNote = try? container.decode(CheckvistNote.self, forKey: .notes) {
      notes = [singleNote]
    } else if let noteStrings = try? container.decodeIfPresent([String].self, forKey: .notes) {
      notes = noteStrings.map {
        CheckvistNote(id: nil, content: $0, createdAt: nil, updatedAt: nil)
      }
    } else if let noteString = try? container.decodeIfPresent(String.self, forKey: .notes) {
      notes = [CheckvistNote(id: nil, content: noteString, createdAt: nil, updatedAt: nil)]
    } else {
      notes = nil
    }

    self.init(
      id: id,
      content: content,
      status: status,
      due: due,
      position: position,
      parentId: parentId,
      level: level,
      notes: notes,
      updatedAt: updatedAt
    )
  }

  private static let dueDateFormatters: [DateFormatter] = {
    let locale = Locale(identifier: "en_US_POSIX")

    let dateOnly = DateFormatter()
    dateOnly.locale = locale
    dateOnly.dateFormat = "yyyy-MM-dd"

    let dateOnlyNoPadding = DateFormatter()
    dateOnlyNoPadding.locale = locale
    dateOnlyNoPadding.dateFormat = "yyyy-M-d"

    let dateTime = DateFormatter()
    dateTime.locale = locale
    dateTime.dateFormat = "yyyy-MM-dd HH:mm:ss Z"

    return [dateOnly, dateOnlyNoPadding, dateTime]
  }()

  private static let iso8601Parsers: [ISO8601DateFormatter] = {
    let internet = ISO8601DateFormatter()
    internet.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate]

    let internetFractional = ISO8601DateFormatter()
    internetFractional.formatOptions = [
      .withInternetDateTime, .withFractionalSeconds, .withDashSeparatorInDate,
    ]

    let fullDate = ISO8601DateFormatter()
    fullDate.formatOptions = [.withFullDate, .withDashSeparatorInDate]

    return [internet, internetFractional, fullDate]
  }()

  var dueDate: Date? {
    guard let dueRaw = due?.trimmingCharacters(in: .whitespacesAndNewlines), !dueRaw.isEmpty else {
      return nil
    }

    for parser in Self.iso8601Parsers {
      if let parsed = parser.date(from: dueRaw) {
        return parsed
      }
    }

    for formatter in Self.dueDateFormatters {
      if let parsed = formatter.date(from: dueRaw) {
        return parsed
      }
    }

    // Common fallback for strings like "yyyy-MM-ddTHH:mm:ssZ"
    if dueRaw.count >= 10 {
      let dayPrefix = String(dueRaw.prefix(10))
      for formatter in Self.dueDateFormatters {
        if let parsed = formatter.date(from: dayPrefix) {
          return parsed
        }
      }
    }

    return nil
  }

  var isOverdue: Bool {
    guard let d = dueDate else { return false }
    return d < Calendar.current.startOfDay(for: Date())
  }

  var isDueToday: Bool {
    guard let d = dueDate else { return false }
    return Calendar.current.isDateInToday(d)
  }

  var hasNotes: Bool {
    guard let notes else { return false }
    return notes.contains { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }
}

struct CheckvistList: Codable, Identifiable {
  let id: Int
  let name: String
  let archived: Bool?
  let readOnly: Bool?

  enum CodingKeys: String, CodingKey {
    case id, name, archived
    case readOnly = "read_only"
  }
}

@MainActor
class CheckvistManager: ObservableObject {
  private let logger = Logger(subsystem: "uk.co.maybeitsadam.bar-tasker", category: "manager")

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
    case checkvist
    case obsidian
    case googleCalendar
    case mcp

    var id: String { rawValue }
  }

  @Published var username: String
  @Published var remoteKey: String
  @Published var listId: String

  /// All tasks (flat, from API)
  @Published var tasks: [CheckvistTask] = []

  /// User's available lists from the API
  @Published var availableLists: [CheckvistList] = []

  /// The parent ID of the level currently being viewed (0 = root)
  @Published var currentParentId: Int = 0

  /// Index within the current level's sibling list
  @Published var currentSiblingIndex: Int = 0

  @Published var isLoading: Bool = false
  @Published var errorMessage: String? = nil

  // MARK: - Undo
  enum UndoableAction {
    case add(taskId: Int)
    case markDone(taskId: Int)
    case invalidate(taskId: Int)
    case update(taskId: Int, oldContent: String, oldDue: String?)
  }
  @Published var lastUndo: UndoableAction? = nil

  // MARK: - Filters & Quick Entry
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

  @Published var filterText: String = ""
  @Published var hideFuture: Bool = false
  @Published var showTaskBreadcrumbContext: Bool
  @Published var rootTaskView: RootTaskView
  @Published var selectedRootDueBucketRawValue: Int
  @Published var selectedRootTag: String
  /// 0 = task list, 1 = root tabs (All/Due/Tags), 2 = root filter row (due buckets/tags)
  @Published var rootScopeFocusLevel: Int = 0
  @Published var keyBuffer: String = ""
  @Published var quickEntryMode: QuickEntryMode = .search
  @Published var isQuickEntryFocused: Bool = false
  @Published var editCursorAtEnd: Bool = true  // true = append (a), false = insert (i)
  @Published var pendingDeleteConfirmation: Bool = false
  @Published var completingTaskId: Int? = nil
  @Published var commandSuggestionIndex: Int = 0
  @Published private(set) var priorityTaskIds: [Int]

  struct CommandSuggestion {
    let label: String
    let command: String
    let preview: String
    let keybind: String?
    let submitImmediately: Bool
  }

  static let commandSuggestions: [CommandSuggestion] = CheckvistCommandEngine.suggestions.map {
    .init(
      label: $0.label,
      command: $0.command,
      preview: $0.preview,
      keybind: $0.keybind,
      submitImmediately: $0.submitImmediately
    )
  }
  static let maxPriorityRank = 9
  private static let priorityQueuesDefaultsKey = "priorityTaskIdsByListId"
  private static let pendingObsidianSyncDefaultsKey = "pendingObsidianSyncTaskIdsByListId"
  private static let obsidianIntegrationEnabledDefaultsKey = "obsidianIntegrationEnabled"
  private static let googleCalendarIntegrationEnabledDefaultsKey =
    "googleCalendarIntegrationEnabled"
  private static let mcpIntegrationEnabledDefaultsKey = "mcpIntegrationEnabled"
  private static let quickAddHotkeyEnabledDefaultsKey = "quickAddHotkeyEnabled"
  private static let quickAddHotkeyKeyCodeDefaultsKey = "quickAddHotkeyKeyCode"
  private static let quickAddHotkeyModifiersDefaultsKey = "quickAddHotkeyModifiers"
  private static let quickAddLocationModeDefaultsKey = "quickAddLocationModeRawValue"
  private static let quickAddSpecificParentTaskIdDefaultsKey = "quickAddSpecificParentTaskId"
  private static let dismissedOnboardingDialogsDefaultsKey = "dismissedOnboardingDialogs"

  // MARK: - Timer
  @Published var timedTaskId: Int? = nil
  @Published private(set) var timerByTaskId: [Int: TimeInterval] = [:]
  @Published var timerRunning: Bool = false
  @Published var timerBarLeading: Bool
  @Published var timerMode: TimerMode
  private var timerTask: Task<Void, Never>? = nil

  /// Formatted elapsed time to 2 significant figures in the most readable unit.
  static func formattedTimer(_ elapsed: TimeInterval) -> String {
    CheckvistTimerStore.formatted(elapsed)
  }

  /// Timer string to show in the menu bar, nil when no timer is active.
  var timerBarString: String? {
    guard timerMode == .visible, let currentTask else { return nil }
    let elapsed = totalElapsed(forTaskId: currentTask.id)
    let currentTaskHasActiveTimer = timedTaskId == currentTask.id
    guard elapsed > 0 || currentTaskHasActiveTimer else { return nil }
    return CheckvistManager.formattedTimer(elapsed)
  }

  var timerIsEnabled: Bool { timerMode != .disabled }
  var timerIsVisible: Bool { timerMode == .visible }
  var hasPendingObsidianSync: Bool { !pendingObsidianSyncTaskIds.isEmpty }
  var pendingSyncMenuBarPrefix: String {
    guard hasPendingObsidianSync else { return "" }
    return pendingObsidianSyncTaskIds.count == 1
      ? "Pending Sync" : "Pending Sync (\(pendingObsidianSyncTaskIds.count))"
  }

  func filteredCommandSuggestions(query: String) -> [CommandSuggestion] {
    CheckvistCommandEngine.filteredSuggestions(query: query).map {
      .init(
        label: $0.label,
        command: $0.command,
        preview: $0.preview,
        keybind: $0.keybind,
        submitImmediately: $0.submitImmediately
      )
    }
  }

  @MainActor func selectNextCommandSuggestion(for query: String) {
    let total = filteredCommandSuggestions(query: query).count
    guard total > 0 else { return }
    commandSuggestionIndex = min(commandSuggestionIndex + 1, total - 1)
  }

  @MainActor func selectPreviousCommandSuggestion(for query: String) {
    let total = filteredCommandSuggestions(query: query).count
    guard total > 0 else { return }
    commandSuggestionIndex = max(commandSuggestionIndex - 1, 0)
  }

  // MARK: - Settings
  @Published var confirmBeforeDelete: Bool
  @Published var launchAtLogin: Bool
  @Published var ignoreKeychainInDebug: Bool
  @Published var obsidianIntegrationEnabled: Bool
  @Published var googleCalendarIntegrationEnabled: Bool
  @Published var mcpIntegrationEnabled: Bool
  @Published var globalHotkeyEnabled: Bool
  /// Carbon keyCode for the global hotkey (default 49 = Space)
  @Published var globalHotkeyKeyCode: Int
  /// Carbon modifier mask (default 0x0800 = optionKey i.e. ⌥)
  @Published var globalHotkeyModifiers: Int
  @Published var quickAddHotkeyEnabled: Bool
  /// Carbon keyCode for the quick add hotkey (default 11 = B)
  @Published var quickAddHotkeyKeyCode: Int
  /// Carbon modifier mask (default 0x0A00 = shift+option)
  @Published var quickAddHotkeyModifiers: Int
  @Published var quickAddLocationMode: QuickAddLocationMode
  @Published var quickAddSpecificParentTaskId: String

  /// Max width of the menu bar text
  @Published var maxTitleWidth: Double
  @Published var onboardingCompleted: Bool
  @Published var activeOnboardingDialog: OnboardingDialog?
  @Published private(set) var obsidianInboxPath: String
  @Published private(set) var mcpServerCommandPath: String
  @Published private(set) var pendingObsidianSyncTaskIds: [Int]
  @Published private(set) var isNetworkReachable: Bool = true

  private var dismissedOnboardingDialogs: Set<OnboardingDialog>

  var hasCredentials: Bool {
    !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !remoteKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var canAttemptLogin: Bool {
    let hasUsername = !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    guard hasUsername else { return false }
    if hasCredentials { return true }
    return usesKeychainStorage
  }

  var hasListSelection: Bool {
    !listId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var quickAddSpecificParentTaskIdValue: Int? {
    let raw = quickAddSpecificParentTaskId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty, let value = Int(raw), value > 0 else { return nil }
    return value
  }

  var hasResolvedMCPServerCommand: Bool {
    !mcpServerCommandPath.isEmpty
  }

  var mcpClientConfigurationPreview: String {
    mcpIntegrationPlugin.makeClientConfigurationJSON(
      credentials: activeCredentials,
      listId: listId,
      redactSecrets: true
    )
  }

  // Setup is non-blocking: the app can always run in offline-first mode.
  var needsInitialSetup: Bool { false }

  /// Tasks visible at the current level, sorted by position
  var currentLevelTasks: [CheckvistTask] {
    tasks.filter { ($0.parentId ?? 0) == currentParentId }
  }

  var currentTask: CheckvistTask? {
    let level = visibleTasks
    guard !level.isEmpty else { return nil }
    let clampedIndex = min(max(currentSiblingIndex, 0), level.count - 1)
    return level[clampedIndex]
  }

  var currentTaskText: String { currentTask?.content ?? "" }

  /// Breadcrumb chain from root down to (but not including) current task
  var breadcrumbs: [CheckvistTask] {
    var result: [CheckvistTask] = []
    var parentId = currentParentId
    while parentId != 0 {
      if let parent = tasks.first(where: { $0.id == parentId }) {
        result.insert(parent, at: 0)
        parentId = parent.parentId ?? 0
      } else {
        break
      }
    }
    return result
  }

  /// Children of the currently focused task
  var currentTaskChildren: [CheckvistTask] {
    guard let t = currentTask else { return [] }
    return tasks.filter { ($0.parentId ?? 0) == t.id }
  }

  /// Visible tasks: searches recursively through subtasks when filter active
  var visibleTasks: [CheckvistTask] {
    if isSearchFilterActive {
      // Recursive search: include any task under currentParentId that matches
      var matches = tasks.filter { task in
        task.content.localizedCaseInsensitiveContains(filterText)
          && isDescendant(task, of: currentParentId)
      }
      matches.sort(by: compareByPriorityThenPosition)
      return matches
    }
    let baseTasks: [CheckvistTask]
    if shouldShowRootScopeSection {
      if isRootLevel {
        switch rootTaskView {
        case .all:
          baseTasks = currentLevelTasks
        case .due, .tags, .priority:
          // In root Due/Tags/Priority views, mirror Checkvist-style cross-tree browsing.
          baseTasks = tasks
        }
      } else {
        // Once inside a task, always navigate the real child level.
        baseTasks = currentLevelTasks
      }
    } else {
      baseTasks = currentLevelTasks
    }

    var result = baseTasks
    if hideFuture {
      result = result.filter { task in
        guard let d = task.dueDate else { return false }
        guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) else {
          return false
        }
        return d <= Calendar.current.startOfDay(for: tomorrow)
      }
    }
    if shouldShowRootScopeSection {
      if isRootLevel {
        switch rootTaskView {
        case .all:
          result.sort(by: compareByPriorityThenPosition)
        case .due:
          if let selectedRootDueBucket {
            result = result.filter { rootDueBucket(for: $0) == selectedRootDueBucket }
          } else {
            result = result.filter { rootDueBucket(for: $0) != .noDueDate }
          }
          result.sort(by: compareByRootDueBucket)
        case .tags:
          if selectedRootTag.isEmpty {
            result = result.filter(hasAnyTag(_:))
          } else {
            result = result.filter { hasTag($0, tag: selectedRootTag) }
          }
          result.sort(by: compareByPriorityThenPosition)
        case .priority:
          result = result.filter { priorityRank(for: $0) != nil }
          result.sort(by: compareByPriorityThenPosition)
        }
      } else {
        // Allow full child browsing only when the current parent itself matches
        // the active root scope. Otherwise keep siblings constrained by scope.
        if let parentTask = tasks.first(where: { $0.id == currentParentId }),
          taskMatchesActiveRootScope(parentTask)
        {
          // Keep all real children.
        } else {
          result = result.filter(taskMatchesActiveRootScope(_:))
        }
        result.sort(by: compareByPriorityThenPosition)
      }
    } else {
      result.sort(by: compareByPriorityThenPosition)
    }
    return result
  }

  var isRootLevel: Bool { currentParentId == 0 }

  var shouldShowRootScopeSection: Bool { !needsInitialSetup && !isSearchFilterActive }
  var rootScopeShowsFilterControls: Bool {
    shouldShowRootScopeSection && isRootLevel && (rootTaskView == .due || rootTaskView == .tags)
  }

  var selectedRootDueBucket: RootDueBucket? {
    get { RootDueBucket(rawValue: selectedRootDueBucketRawValue) }
    set { selectedRootDueBucketRawValue = newValue?.rawValue ?? -1 }
  }

  func shouldShowBreadcrumbPath(for task: CheckvistTask) -> Bool {
    let pid = task.parentId ?? 0
    if isRootLevel && shouldShowRootScopeSection && rootTaskView != .all {
      return pid != 0
    }
    if isSearchFilterActive {
      return pid != currentParentId
    }
    if showTaskBreadcrumbContext {
      return pid != 0
    }
    return false
  }

  func rootDueSectionHeader(atVisibleIndex index: Int, visibleTasks: [CheckvistTask]) -> String? {
    guard shouldShowDueSectionHeaders, visibleTasks.indices.contains(index) else { return nil }
    let currentBucket = rootDueBucket(for: visibleTasks[index])
    if index == 0 { return currentBucket.title }
    let previousBucket = rootDueBucket(for: visibleTasks[index - 1])
    return previousBucket == currentBucket ? nil : currentBucket.title
  }

  func rootDueSectionCount(in visibleTasks: [CheckvistTask]) -> Int {
    guard shouldShowDueSectionHeaders, !visibleTasks.isEmpty else { return 0 }
    var total = 0
    var previousBucket: RootDueBucket?
    for task in visibleTasks {
      let bucket = rootDueBucket(for: task)
      if bucket != previousBucket {
        total += 1
        previousBucket = bucket
      }
    }
    return total
  }

  func rootLevelTagNames(limit: Int = 8) -> [String] {
    var counts: [String: Int] = [:]
    for task in tasks {
      let range = NSRange(task.content.startIndex..., in: task.content)
      let matches = Self.tagRegex.matches(in: task.content, range: range)
      for match in matches {
        guard let matchRange = Range(match.range, in: task.content) else { continue }
        let tag = String(task.content[matchRange]).lowercased()
        counts[tag, default: 0] += 1
      }
    }
    return
      counts
      .sorted { lhs, rhs in
        if lhs.value != rhs.value { return lhs.value > rhs.value }
        return lhs.key < rhs.key
      }
      .prefix(limit)
      .map(\.key)
  }

  func priorityRank(for task: CheckvistTask) -> Int? {
    guard let index = priorityTaskIds.firstIndex(of: task.id) else { return nil }
    return index + 1
  }

  private var isSearchFilterActive: Bool {
    !filterText.isEmpty && quickEntryMode == .search
  }

  var shouldShowDueSectionHeaders: Bool {
    isRootLevel && shouldShowRootScopeSection && rootTaskView == .due
      && selectedRootDueBucket == nil
  }

  private static let tagRegex = (try? NSRegularExpression(pattern: "[@#][a-zA-Z0-9_\\-]+"))!

  private func hasAnyTag(_ task: CheckvistTask) -> Bool {
    let range = NSRange(task.content.startIndex..., in: task.content)
    return Self.tagRegex.firstMatch(in: task.content, range: range) != nil
  }

  private func hasTag(_ task: CheckvistTask, tag: String) -> Bool {
    let normalized: String
    if tag.hasPrefix("#") || tag.hasPrefix("@") {
      normalized = tag.lowercased()
    } else {
      normalized = "#\(tag.lowercased())"
    }
    let range = NSRange(task.content.startIndex..., in: task.content)
    let matches = Self.tagRegex.matches(in: task.content, range: range)
    for match in matches {
      guard let matchRange = Range(match.range, in: task.content) else { continue }
      if String(task.content[matchRange]).lowercased() == normalized { return true }
    }
    return false
  }

  private func taskMatchesActiveRootScope(_ task: CheckvistTask) -> Bool {
    switch rootTaskView {
    case .all:
      return true
    case .due:
      if let selectedRootDueBucket {
        return rootDueBucket(for: task) == selectedRootDueBucket
      }
      return rootDueBucket(for: task) != .noDueDate
    case .tags:
      if selectedRootTag.isEmpty {
        return hasAnyTag(task)
      }
      return hasTag(task, tag: selectedRootTag)
    case .priority:
      return priorityRank(for: task) != nil
    }
  }

  private func compareByPositionThenContent(_ lhs: CheckvistTask, _ rhs: CheckvistTask) -> Bool {
    switch (lhs.position, rhs.position) {
    case (.some(let leftPosition), .some(let rightPosition)) where leftPosition != rightPosition:
      return leftPosition < rightPosition
    default:
      break
    }
    return lhs.content.localizedCaseInsensitiveCompare(rhs.content) == .orderedAscending
  }

  private func compareByPriorityThenPosition(_ lhs: CheckvistTask, _ rhs: CheckvistTask) -> Bool {
    let leftPriority = priorityRank(for: lhs)
    let rightPriority = priorityRank(for: rhs)

    if let leftPriority, let rightPriority, leftPriority != rightPriority {
      return leftPriority < rightPriority
    }
    if leftPriority != nil && rightPriority == nil {
      return true
    }
    if leftPriority == nil && rightPriority != nil {
      return false
    }

    return compareByPositionThenContent(lhs, rhs)
  }

  private func compareByRootDueBucket(_ lhs: CheckvistTask, _ rhs: CheckvistTask) -> Bool {
    let leftBucket = rootDueBucket(for: lhs)
    let rightBucket = rootDueBucket(for: rhs)
    if leftBucket != rightBucket {
      return leftBucket.rawValue < rightBucket.rawValue
    }

    switch (lhs.dueDate, rhs.dueDate) {
    case (.some(let leftDate), .some(let rightDate)) where leftDate != rightDate:
      return leftDate < rightDate
    default:
      break
    }

    switch (lhs.position, rhs.position) {
    case (.some(let leftPosition), .some(let rightPosition)) where leftPosition != rightPosition:
      return leftPosition < rightPosition
    default:
      break
    }

    return lhs.content.localizedCaseInsensitiveCompare(rhs.content) == .orderedAscending
  }

  func rootDueBucket(for task: CheckvistTask) -> RootDueBucket {
    let dueText = task.due?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    guard !dueText.isEmpty else { return .noDueDate }
    if dueText == "asap" { return .asap }
    guard let dueDate = task.dueDate else { return .future }

    let calendar = Calendar.current
    let now = Date()
    let todayStart = calendar.startOfDay(for: now)
    if dueDate < todayStart { return .overdue }
    if calendar.isDateInToday(dueDate) { return .today }
    if calendar.isDateInTomorrow(dueDate) { return .tomorrow }
    guard let sevenDaysOut = calendar.date(byAdding: .day, value: 8, to: todayStart) else {
      return .future
    }
    if dueDate < sevenDaysOut { return .nextSevenDays }
    return .future
  }

  func setRootTaskView(_ view: RootTaskView) {
    rootTaskView = view
    if currentParentId != 0 {
      currentParentId = 0
    }
    currentSiblingIndex = 0
    if view != .due {
      selectedRootDueBucket = nil
    }
    if view != .tags {
      selectedRootTag = ""
    }
    if !(view == .due || view == .tags), rootScopeFocusLevel > 1 {
      rootScopeFocusLevel = 1
    }
  }

  @MainActor func cycleRootTaskView(direction: Int) {
    let allViews = RootTaskView.allCases
    guard let currentIndex = allViews.firstIndex(of: rootTaskView) else { return }
    let nextIndex = max(0, min(allViews.count - 1, currentIndex + direction))
    guard nextIndex != currentIndex else { return }
    setRootTaskView(allViews[nextIndex])
  }

  @MainActor func cycleRootScopeFilter(direction: Int) {
    guard shouldShowRootScopeSection else { return }
    switch rootTaskView {
    case .all, .priority:
      return
    case .due:
      let options: [RootDueBucket?] = [nil] + RootDueBucket.allCases.filter { $0 != .noDueDate }
      guard let currentIndex = options.firstIndex(where: { $0 == selectedRootDueBucket }) else {
        selectedRootDueBucket = nil
        currentSiblingIndex = 0
        return
      }
      let nextIndex = max(0, min(options.count - 1, currentIndex + direction))
      selectedRootDueBucket = options[nextIndex]
      currentSiblingIndex = 0
    case .tags:
      let tags = rootLevelTagNames(limit: 30)
      let options = [""] + tags
      guard let currentIndex = options.firstIndex(of: selectedRootTag) else {
        selectedRootTag = ""
        currentSiblingIndex = 0
        return
      }
      let nextIndex = max(0, min(options.count - 1, currentIndex + direction))
      selectedRootTag = options[nextIndex]
      currentSiblingIndex = 0
    }
  }

  @MainActor func selectRootScopeFilter(at index: Int) {
    guard shouldShowRootScopeSection else { return }
    guard index >= 0 else { return }
    switch rootTaskView {
    case .all, .priority:
      return
    case .due:
      let options: [RootDueBucket?] = [nil] + RootDueBucket.allCases.filter { $0 != .noDueDate }
      guard options.indices.contains(index) else { return }
      selectedRootDueBucket = options[index]
      currentSiblingIndex = 0
      rootScopeFocusLevel = 2
    case .tags:
      let options = [""] + rootLevelTagNames(limit: 30)
      guard options.indices.contains(index) else { return }
      selectedRootTag = options[index]
      currentSiblingIndex = 0
      rootScopeFocusLevel = 2
    }
  }

  @MainActor func setPriorityForCurrentTask(_ rank: Int) {
    guard (1...Self.maxPriorityRank).contains(rank), let task = currentTask else { return }

    var updated = priorityTaskIds
    updated.removeAll { $0 == task.id }
    let insertIndex = min(max(rank - 1, 0), updated.count)
    updated.insert(task.id, at: insertIndex)
    if updated.count > Self.maxPriorityRank {
      updated = Array(updated.prefix(Self.maxPriorityRank))
    }
    savePriorityQueue(updated)
    errorMessage = nil

    if let newIndex = visibleTasks.firstIndex(where: { $0.id == task.id }) {
      currentSiblingIndex = newIndex
    }
  }

  @MainActor func sendCurrentTaskToPriorityBack() {
    guard let task = currentTask else { return }

    var updated = priorityTaskIds
    let wasPrioritized = updated.contains(task.id)
    updated.removeAll { $0 == task.id }

    if !wasPrioritized && updated.count >= Self.maxPriorityRank {
      errorMessage = "Priority slots full (1-9). Press 1-9 to replace one."
      return
    }

    updated.append(task.id)
    savePriorityQueue(updated)
    errorMessage = nil

    if let newIndex = visibleTasks.firstIndex(where: { $0.id == task.id }) {
      currentSiblingIndex = newIndex
    }
  }

  @MainActor func clearPriorityForCurrentTask() {
    guard let task = currentTask else { return }
    guard priorityTaskIds.contains(task.id) else { return }
    savePriorityQueue(priorityTaskIds.filter { $0 != task.id })
    errorMessage = nil

    if let newIndex = visibleTasks.firstIndex(where: { $0.id == task.id }) {
      currentSiblingIndex = newIndex
    } else {
      clampSelectionToVisibleRange()
    }
  }

  /// Returns true if task is a descendant of the given parentId (or IS at that level)
  func isDescendant(_ task: CheckvistTask, of rootId: Int) -> Bool {
    if rootId == 0 { return true }  // root contains everything
    var pid = task.parentId ?? 0
    while pid != 0 {
      if pid == rootId { return true }
      pid = tasks.first(where: { $0.id == pid })?.parentId ?? 0
    }
    return false
  }

  private var loadingOperationCount: Int = 0
  private var cancellables = Set<AnyCancellable>()
  private var pendingReorderRequests: [(taskId: Int, position: Int)] = []
  private var reorderSyncTask: Task<Void, Never>? = nil
  private var reorderResyncTask: Task<Void, Never>? = nil
  private var hasPendingSyncProcessingTask = false
  private var hasAttemptedRemoteKeyBootstrap = false
  private let credentialStore = CheckvistCredentialStore()
  private let checkvistSyncPlugin: any CheckvistSyncPlugin
  private let obsidianPlugin: any ObsidianIntegrationPlugin
  private let googleCalendarPlugin: any GoogleCalendarIntegrationPlugin
  private let mcpIntegrationPlugin: any MCPIntegrationPlugin
  private let navigationCoordinator = TaskNavigationCoordinator()
  private let reachabilityMonitor = NetworkReachabilityMonitor()
  private let priorityQueueStore = ListScopedTaskIDStore(
    defaultsKey: CheckvistManager.priorityQueuesDefaultsKey,
    maximumCount: CheckvistManager.maxPriorityRank
  )
  private let pendingSyncQueueStore = ListScopedTaskIDStore(
    defaultsKey: CheckvistManager.pendingObsidianSyncDefaultsKey
  )
  private var usesKeychainStorage: Bool {
    #if DEBUG
      !ignoreKeychainInDebug
    #else
      true
    #endif
  }

  private var activeCredentials: CheckvistCredentials {
    CheckvistCredentials(username: username, remoteKey: remoteKey)
  }

  init(pluginRegistry: FocusPluginRegistry) {
    let resolvedCheckvistSyncPlugin =
      pluginRegistry.activeCheckvistSyncPlugin ?? NativeCheckvistSyncPlugin()
    let resolvedObsidianPlugin =
      pluginRegistry.activeObsidianPlugin
      ?? NativeObsidianIntegrationPlugin()
    let resolvedGoogleCalendarPlugin =
      pluginRegistry.activeGoogleCalendarPlugin
      ?? NativeGoogleCalendarIntegrationPlugin()
    let resolvedMCPIntegrationPlugin =
      pluginRegistry.activeMCPIntegrationPlugin
      ?? NativeMCPIntegrationPlugin()
    self.checkvistSyncPlugin = resolvedCheckvistSyncPlugin
    self.obsidianPlugin = resolvedObsidianPlugin
    self.googleCalendarPlugin = resolvedGoogleCalendarPlugin
    self.mcpIntegrationPlugin = resolvedMCPIntegrationPlugin

    let storedUsername = UserDefaults.standard.string(forKey: "checkvistUsername") ?? ""
    let storedListId = UserDefaults.standard.string(forKey: "checkvistListId") ?? ""
    let storedObsidianInboxPath = resolvedObsidianPlugin.inboxPath
    self.username = storedUsername
    self.listId = storedListId
    self.pendingObsidianSyncTaskIds = pendingSyncQueueStore.load(for: storedListId)
    self.priorityTaskIds = priorityQueueStore.load(for: storedListId)
    self.obsidianInboxPath = storedObsidianInboxPath
    if let storedObsidianIntegrationEnabled =
      UserDefaults.standard.object(forKey: Self.obsidianIntegrationEnabledDefaultsKey) as? Bool
    {
      self.obsidianIntegrationEnabled = storedObsidianIntegrationEnabled
    } else {
      self.obsidianIntegrationEnabled = !storedObsidianInboxPath.isEmpty
    }
    self.googleCalendarIntegrationEnabled =
      UserDefaults.standard.object(forKey: Self.googleCalendarIntegrationEnabledDefaultsKey)
      as? Bool
      ?? false
    self.mcpIntegrationEnabled =
      UserDefaults.standard.object(forKey: Self.mcpIntegrationEnabledDefaultsKey)
      as? Bool
      ?? true
    self.mcpServerCommandPath = resolvedMCPIntegrationPlugin.serverCommandURL()?.path ?? ""
    self.confirmBeforeDelete =
      UserDefaults.standard.object(forKey: "confirmBeforeDelete") as? Bool ?? true
    self.showTaskBreadcrumbContext =
      UserDefaults.standard.object(forKey: "showTaskBreadcrumbContext") as? Bool ?? false
    self.rootTaskView =
      RootTaskView(rawValue: UserDefaults.standard.object(forKey: "rootTaskView") as? Int ?? 1)
      ?? .due
    self.selectedRootDueBucketRawValue =
      UserDefaults.standard.object(forKey: "selectedRootDueBucketRawValue") as? Int ?? -1
    self.selectedRootTag = UserDefaults.standard.string(forKey: "selectedRootTag") ?? ""
    self.launchAtLogin = UserDefaults.standard.object(forKey: "launchAtLogin") as? Bool ?? false
    #if DEBUG
      self.ignoreKeychainInDebug =
        UserDefaults.standard.object(
          forKey: CheckvistCredentialStore.ignoreKeychainInDebugDefaultsKey)
        as? Bool
        ?? true
    #else
      self.ignoreKeychainInDebug = true
    #endif
    self.globalHotkeyEnabled =
      UserDefaults.standard.object(forKey: "globalHotkeyEnabled") as? Bool ?? false
    self.globalHotkeyKeyCode =
      UserDefaults.standard.object(forKey: "globalHotkeyKeyCode") as? Int ?? 49  // Space
    self.globalHotkeyModifiers =
      UserDefaults.standard.object(forKey: "globalHotkeyModifiers") as? Int ?? 0x0800  // ⌥
    self.quickAddHotkeyEnabled =
      UserDefaults.standard.object(forKey: Self.quickAddHotkeyEnabledDefaultsKey) as? Bool ?? false
    self.quickAddHotkeyKeyCode =
      UserDefaults.standard.object(forKey: Self.quickAddHotkeyKeyCodeDefaultsKey) as? Int ?? 11  // B
    self.quickAddHotkeyModifiers =
      UserDefaults.standard.object(forKey: Self.quickAddHotkeyModifiersDefaultsKey) as? Int
      ?? 0x0A00  // ⇧⌥
    self.quickAddLocationMode =
      QuickAddLocationMode(
        rawValue: UserDefaults.standard.object(forKey: Self.quickAddLocationModeDefaultsKey)
          as? Int ?? 0
      ) ?? .defaultRoot
    self.quickAddSpecificParentTaskId =
      UserDefaults.standard.string(forKey: Self.quickAddSpecificParentTaskIdDefaultsKey) ?? ""
    self.maxTitleWidth = UserDefaults.standard.object(forKey: "maxTitleWidth") as? Double ?? 150.0
    if let storedOnboarding =
      UserDefaults.standard.object(forKey: CheckvistCredentialStore.onboardingCompletedDefaultsKey)
      as? Bool
    {
      self.onboardingCompleted = storedOnboarding
    } else {
      // Existing installs with saved account + list skip onboarding by default.
      self.onboardingCompleted = !storedUsername.isEmpty && !storedListId.isEmpty
    }
    self.timerBarLeading = UserDefaults.standard.object(forKey: "timerBarLeading") as? Bool ?? false
    self.timerMode =
      TimerMode(rawValue: UserDefaults.standard.object(forKey: "timerMode") as? Int ?? 0)
      ?? .visible
    self.timerByTaskId = Self.timerDictionaryFromDefaults()
    self.activeOnboardingDialog = nil
    let persistedDismissedDialogs =
      UserDefaults.standard.stringArray(forKey: Self.dismissedOnboardingDialogsDefaultsKey) ?? []
    self.dismissedOnboardingDialogs = Set(
      persistedDismissedDialogs.compactMap(OnboardingDialog.init(rawValue:))
    )

    let useKeychainStorageAtInit: Bool
    #if DEBUG
      let ignoreAtInit =
        UserDefaults.standard.object(
          forKey: CheckvistCredentialStore.ignoreKeychainInDebugDefaultsKey)
        as? Bool
        ?? true
      useKeychainStorageAtInit = !ignoreAtInit
    #else
      useKeychainStorageAtInit = true
    #endif

    self.remoteKey = credentialStore.startupRemoteKey(
      useKeychainStorageAtInit: useKeychainStorageAtInit)

    setupBindings()
    setupNetworkMonitor()
    Task { @MainActor [weak self] in
      self?.presentOnboardingDialogIfNeeded()
    }
  }

  convenience init() {
    self.init(pluginRegistry: .nativeFirst())
  }

  deinit {
    reachabilityMonitor.stop()
  }

  private func setupBindings() {
    $username
      .dropFirst()
      .sink { [weak self] value in
        UserDefaults.standard.set(value, forKey: "checkvistUsername")
        self?.checkvistSyncPlugin.clearAuthentication()
        self?.refreshOnboardingDialogState()
      }.store(in: &cancellables)
    $remoteKey
      .dropFirst()
      .removeDuplicates()
      .sink { [weak self] value in
        guard let self else { return }
        self.checkvistSyncPlugin.clearAuthentication()
        self.credentialStore.persistRemoteKey(value, useKeychainStorage: self.usesKeychainStorage)
        self.refreshOnboardingDialogState()
      }.store(in: &cancellables)
    $listId
      .dropFirst()
      .sink { [weak self] value in
        UserDefaults.standard.set(value, forKey: "checkvistListId")
        self?.loadPriorityQueue(for: value)
        self?.loadPendingObsidianSyncQueue(for: value)
        self?.refreshOnboardingDialogState()
      }.store(in: &cancellables)
    $confirmBeforeDelete.sink { UserDefaults.standard.set($0, forKey: "confirmBeforeDelete") }
      .store(in: &cancellables)
    $obsidianIntegrationEnabled
      .sink { [weak self] value in
        UserDefaults.standard.set(value, forKey: Self.obsidianIntegrationEnabledDefaultsKey)
        self?.refreshOnboardingDialogState()
      }
      .store(in: &cancellables)
    $googleCalendarIntegrationEnabled
      .sink { [weak self] value in
        UserDefaults.standard.set(value, forKey: Self.googleCalendarIntegrationEnabledDefaultsKey)
        self?.refreshOnboardingDialogState()
      }
      .store(in: &cancellables)
    $mcpIntegrationEnabled
      .sink { [weak self] in
        UserDefaults.standard.set($0, forKey: Self.mcpIntegrationEnabledDefaultsKey)
        self?.refreshOnboardingDialogState()
      }
      .store(in: &cancellables)
    $showTaskBreadcrumbContext.sink {
      UserDefaults.standard.set($0, forKey: "showTaskBreadcrumbContext")
    }
    .store(in: &cancellables)
    $rootTaskView.sink {
      UserDefaults.standard.set($0.rawValue, forKey: "rootTaskView")
    }
    .store(in: &cancellables)
    $selectedRootDueBucketRawValue.sink {
      UserDefaults.standard.set($0, forKey: "selectedRootDueBucketRawValue")
    }
    .store(in: &cancellables)
    $selectedRootTag.sink {
      UserDefaults.standard.set($0, forKey: "selectedRootTag")
    }
    .store(in: &cancellables)
    $launchAtLogin.sink { newValue in
      UserDefaults.standard.set(newValue, forKey: "launchAtLogin")
      if #available(macOS 13.0, *) {
        do {
          if newValue {
            try SMAppService.mainApp.register()
          } else {
            try SMAppService.mainApp.unregister()
          }
        } catch { print("Launch at login error: \(error)") }
      }
    }.store(in: &cancellables)
    #if DEBUG
      $ignoreKeychainInDebug
        .dropFirst()
        .sink { [weak self] newValue in
          guard let self else { return }
          UserDefaults.standard.set(
            newValue, forKey: CheckvistCredentialStore.ignoreKeychainInDebugDefaultsKey)
          self.handleCredentialStorageModeChanged()
        }.store(in: &cancellables)
    #endif
    $globalHotkeyEnabled.sink { UserDefaults.standard.set($0, forKey: "globalHotkeyEnabled") }
      .store(in: &cancellables)
    $globalHotkeyKeyCode.sink { UserDefaults.standard.set($0, forKey: "globalHotkeyKeyCode") }
      .store(in: &cancellables)
    $globalHotkeyModifiers.sink { UserDefaults.standard.set($0, forKey: "globalHotkeyModifiers") }
      .store(in: &cancellables)
    $quickAddHotkeyEnabled.sink {
      UserDefaults.standard.set($0, forKey: Self.quickAddHotkeyEnabledDefaultsKey)
    }
    .store(in: &cancellables)
    $quickAddHotkeyKeyCode.sink {
      UserDefaults.standard.set($0, forKey: Self.quickAddHotkeyKeyCodeDefaultsKey)
    }
    .store(in: &cancellables)
    $quickAddHotkeyModifiers.sink {
      UserDefaults.standard.set($0, forKey: Self.quickAddHotkeyModifiersDefaultsKey)
    }
    .store(in: &cancellables)
    $quickAddLocationMode.sink {
      UserDefaults.standard.set($0.rawValue, forKey: Self.quickAddLocationModeDefaultsKey)
    }
    .store(in: &cancellables)
    $quickAddSpecificParentTaskId.sink {
      UserDefaults.standard.set($0, forKey: Self.quickAddSpecificParentTaskIdDefaultsKey)
    }
    .store(in: &cancellables)
    $maxTitleWidth.sink { UserDefaults.standard.set($0, forKey: "maxTitleWidth") }.store(
      in: &cancellables)
    $onboardingCompleted
      .sink {
        UserDefaults.standard.set(
          $0, forKey: CheckvistCredentialStore.onboardingCompletedDefaultsKey)
      }
      .store(in: &cancellables)
    $timerBarLeading.sink { UserDefaults.standard.set($0, forKey: "timerBarLeading") }.store(
      in: &cancellables)
    $timerMode.sink { [weak self] mode in
      UserDefaults.standard.set(mode.rawValue, forKey: "timerMode")
      if mode == .disabled {
        Task { @MainActor in
          self?.stopTimer()
        }
      }
    }.store(in: &cancellables)
    $timerByTaskId.sink { timers in
      let encoded = Dictionary(uniqueKeysWithValues: timers.map { (String($0.key), $0.value) })
      UserDefaults.standard.set(encoded, forKey: "timerByTaskId")
    }.store(in: &cancellables)
  }

  private static func timerDictionaryFromDefaults() -> [Int: TimeInterval] {
    guard let raw = UserDefaults.standard.dictionary(forKey: "timerByTaskId") as? [String: Double]
    else { return [:] }
    var result: [Int: TimeInterval] = [:]
    for (k, v) in raw {
      if let id = Int(k) { result[id] = v }
    }
    return result
  }

  private static func normalizedTaskIdQueue(_ queue: [Int], maximumCount: Int? = nil) -> [Int] {
    var seen = Set<Int>()
    var normalized: [Int] = []
    for taskId in queue where taskId > 0 && !seen.contains(taskId) {
      seen.insert(taskId)
      normalized.append(taskId)
    }
    if let maximumCount, normalized.count > maximumCount {
      return Array(normalized.prefix(maximumCount))
    }
    return normalized
  }

  private func loadPriorityQueue(for listId: String) {
    priorityTaskIds = priorityQueueStore.load(for: listId)
  }

  private func loadPendingObsidianSyncQueue(for listId: String) {
    pendingObsidianSyncTaskIds = pendingSyncQueueStore.load(for: listId)
  }

  private func savePriorityQueue(_ queue: [Int]) {
    let normalized = Self.normalizedTaskIdQueue(queue, maximumCount: Self.maxPriorityRank)
    priorityTaskIds = normalized

    guard !listId.isEmpty else { return }
    priorityQueueStore.save(normalized, for: listId)
  }

  private func savePendingObsidianSyncQueue(_ queue: [Int]) {
    let normalized = Self.normalizedTaskIdQueue(queue)
    pendingObsidianSyncTaskIds = normalized

    guard !listId.isEmpty else { return }
    pendingSyncQueueStore.save(normalized, for: listId)
  }

  @MainActor private func enqueuePendingObsidianSync(taskId: Int) {
    var queue = pendingObsidianSyncTaskIds
    queue.removeAll { $0 == taskId }
    queue.append(taskId)
    savePendingObsidianSyncQueue(queue)
  }

  @MainActor private func dequeuePendingObsidianSync(taskId: Int) {
    savePendingObsidianSyncQueue(pendingObsidianSyncTaskIds.filter { $0 != taskId })
  }

  private func setupNetworkMonitor() {
    reachabilityMonitor.onStatusChange = { [weak self] reachable in
      guard let self else { return }
      Task { @MainActor in
        self.isNetworkReachable = reachable
        guard
          reachable,
          self.obsidianIntegrationEnabled,
          !self.pendingObsidianSyncTaskIds.isEmpty
        else { return }
        await self.processPendingObsidianSyncQueue()
      }
    }
    reachabilityMonitor.start()
  }

  @MainActor private func removeTasksFromPriorityQueue(_ taskIds: Set<Int>) {
    guard !taskIds.isEmpty else { return }
    let filtered = priorityTaskIds.filter { !taskIds.contains($0) }
    guard filtered != priorityTaskIds else { return }
    savePriorityQueue(filtered)
  }

  @MainActor private func reconcilePriorityQueueWithOpenTasks() {
    let openTaskIds = Set(tasks.map(\.id))
    let filtered = priorityTaskIds.filter { openTaskIds.contains($0) }
    if filtered != priorityTaskIds {
      savePriorityQueue(filtered)
    }
  }

  @MainActor private func reconcilePendingObsidianSyncQueueWithOpenTasks() {
    let openTaskIds = Set(tasks.map(\.id))
    let filtered = pendingObsidianSyncTaskIds.filter { openTaskIds.contains($0) }
    if filtered != pendingObsidianSyncTaskIds {
      savePendingObsidianSyncQueue(filtered)
    }
  }

  @MainActor
  private func beginLoading() {
    loadingOperationCount += 1
    isLoading = true
  }

  @MainActor
  private func endLoading() {
    loadingOperationCount = max(loadingOperationCount - 1, 0)
    isLoading = loadingOperationCount > 0
  }

  // MARK: - Keychain

  private func handleCredentialStorageModeChanged() {
    let current = remoteKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if usesKeychainStorage {
      if !current.isEmpty {
        credentialStore.persistRemoteKey(current, useKeychainStorage: true)
      } else {
        hasAttemptedRemoteKeyBootstrap = false
        loadRemoteKeyFromKeychainIfNeeded()
      }
    } else {
      credentialStore.persistRemoteKeyForDebugStorageMode(current)
    }
  }

  private func loadRemoteKeyFromKeychainIfNeeded() {
    let currentState = RemoteKeyBootstrapState(
      remoteKey: remoteKey,
      hasAttemptedBootstrap: hasAttemptedRemoteKeyBootstrap
    )
    let nextState = RemoteKeyBootstrapPolicy.bootstrap(
      state: currentState,
      usesKeychainStorage: usesKeychainStorage,
      loadFromKeychain: { credentialStore.loadRemoteKeyFromKeychain() }
    )
    remoteKey = nextState.remoteKey
    hasAttemptedRemoteKeyBootstrap = nextState.hasAttemptedBootstrap
  }

  @MainActor func toggleDebugKeychainStorageMode() {
    #if DEBUG
      ignoreKeychainInDebug.toggle()
      errorMessage =
        ignoreKeychainInDebug
        ? "Dev mode: keychain disabled (no password prompts)."
        : "Dev mode: keychain enabled."
    #endif
  }

  @MainActor func resetOnboardingForDebug() {
    #if DEBUG
      checkvistSyncPlugin.clearAuthentication()
      errorMessage = nil
      let resetState = OnboardingResetPolicy.reset(
        OnboardingResetState(
          remoteKey: remoteKey,
          onboardingCompleted: onboardingCompleted,
          username: username,
          listId: listId,
          availableListsCount: availableLists.count,
          tasksCount: tasks.count,
          currentParentId: currentParentId,
          currentSiblingIndex: currentSiblingIndex
        ))

      onboardingCompleted = resetState.onboardingCompleted
      username = resetState.username
      listId = resetState.listId
      availableLists = []
      tasks = []
      currentParentId = resetState.currentParentId
      currentSiblingIndex = resetState.currentSiblingIndex

      UserDefaults.standard.removeObject(forKey: "checkvistUsername")
      UserDefaults.standard.removeObject(forKey: "checkvistListId")
      UserDefaults.standard.removeObject(
        forKey: CheckvistCredentialStore.onboardingCompletedDefaultsKey)
      dismissedOnboardingDialogs = []
      activeOnboardingDialog = nil
      UserDefaults.standard.removeObject(forKey: Self.dismissedOnboardingDialogsDefaultsKey)
      presentOnboardingDialogIfNeeded()
    #endif
  }

  @MainActor func markOnboardingCompleted() {
    onboardingCompleted = true
  }

  @MainActor func markOnboardingRequired() {
    onboardingCompleted = false
  }

  // MARK: - Offline-first onboarding dialogs

  @MainActor func presentOnboardingDialogIfNeeded() {
    guard activeOnboardingDialog == nil else { return }
    for dialog in OnboardingDialog.allCases where shouldPresentOnboardingDialog(dialog) {
      activeOnboardingDialog = dialog
      return
    }
  }

  @MainActor func dismissActiveOnboardingDialog(permanently: Bool) {
    guard let dialog = activeOnboardingDialog else { return }
    if permanently {
      dismissedOnboardingDialogs.insert(dialog)
      persistDismissedOnboardingDialogs()
    }
    activeOnboardingDialog = nil
    presentOnboardingDialogIfNeeded()
  }

  private func shouldPresentOnboardingDialog(_ dialog: OnboardingDialog) -> Bool {
    guard !dismissedOnboardingDialogs.contains(dialog) else { return false }
    switch dialog {
    case .checkvist:
      return !canAttemptLogin || !hasListSelection
    case .obsidian:
      return !obsidianIntegrationEnabled || obsidianInboxPath.isEmpty
    case .googleCalendar:
      return !googleCalendarIntegrationEnabled
    case .mcp:
      return !mcpIntegrationEnabled
    }
  }

  private func persistDismissedOnboardingDialogs() {
    let rawValues = dismissedOnboardingDialogs.map(\.rawValue).sorted()
    UserDefaults.standard.set(rawValues, forKey: Self.dismissedOnboardingDialogsDefaultsKey)
  }

  @MainActor private func refreshOnboardingDialogState() {
    if let activeOnboardingDialog, !shouldPresentOnboardingDialog(activeOnboardingDialog) {
      self.activeOnboardingDialog = nil
    }
    presentOnboardingDialogIfNeeded()
  }

  // MARK: - Navigation

  @MainActor func nextTask() {
    guard
      let nextIndex = navigationCoordinator.nextSiblingIndex(
        currentSiblingIndex: currentSiblingIndex,
        visibleCount: visibleTasks.count)
    else { return }
    currentSiblingIndex = nextIndex
  }

  @MainActor func previousTask() {
    guard
      let previousIndex = navigationCoordinator.previousSiblingIndex(
        currentSiblingIndex: currentSiblingIndex,
        visibleCount: visibleTasks.count)
    else { return }
    currentSiblingIndex = previousIndex
  }

  /// Navigate into the current task's children
  @MainActor func enterChildren() {
    guard
      let selection = navigationCoordinator.enterChildren(
        currentTask: currentTask,
        childCount: currentTaskChildren.count)
    else { return }
    rootScopeFocusLevel = selection.rootScopeFocusLevel
    currentParentId = selection.currentParentId
    currentSiblingIndex = selection.currentSiblingIndex
  }

  /// Navigate back up to the parent level
  @MainActor func exitToParent() {
    guard
      let selection = navigationCoordinator.exitToParent(
        currentParentId: currentParentId,
        tasks: tasks)
    else { return }
    rootScopeFocusLevel = selection.rootScopeFocusLevel
    currentParentId = selection.currentParentId
    currentSiblingIndex = selection.currentSiblingIndex
  }

  @MainActor func navigateTo(task: CheckvistTask) {
    let selection = navigationCoordinator.navigate(to: task, tasks: tasks)
    rootScopeFocusLevel = selection.rootScopeFocusLevel
    currentParentId = selection.currentParentId
    currentSiblingIndex = selection.currentSiblingIndex
  }
  // MARK: - API

  @MainActor func login() async -> Bool {
    loadRemoteKeyFromKeychainIfNeeded()
    let credentials = activeCredentials
    guard !credentials.normalizedUsername.isEmpty, !credentials.normalizedRemoteKey.isEmpty else {
      errorMessage = "Username or Remote Key is missing."
      return false
    }

    beginLoading()
    defer { endLoading() }
    errorMessage = nil

    do {
      let success = try await checkvistSyncPlugin.login(credentials: credentials)
      guard success else {
        errorMessage = "Login failed. Check your credentials."
        return false
      }
      return true
    } catch {
      errorMessage = "Network error: \(error.localizedDescription)"
      return false
    }
  }

  @MainActor func fetchTopTask() async {
    guard !listId.isEmpty else { return }

    beginLoading()
    defer { endLoading() }
    errorMessage = nil

    do {
      let previousTasks = self.tasks
      let fetchedTasks = try await checkvistSyncPlugin.fetchOpenTasks(
        listId: listId,
        credentials: activeCredentials
      )

      self.tasks = fetchedTasks
      checkvistSyncPlugin.persistTaskCache(listId: listId, tasks: fetchedTasks)
      reconcilePriorityQueueWithOpenTasks()
      reconcilePendingObsidianSyncQueueWithOpenTasks()
      if currentSiblingIndex >= fetchedTasks.count { currentSiblingIndex = 0 }
      let latestOpenTaskIDs = Set(fetchedTasks.map(\.id))
      let previousTimerNodes = previousTasks.map {
        CheckvistTimerNode(id: $0.id, parentId: $0.parentId)
      }
      self.timerByTaskId = TimerElapsedReassignmentPolicy.remapElapsed(
        previousNodes: previousTimerNodes,
        latestOpenTaskIDs: latestOpenTaskIDs,
        elapsedByTaskID: self.timerByTaskId
      )
      if let activeTimerTaskID = timedTaskId, !latestOpenTaskIDs.contains(activeTimerTaskID) {
        stopTimer()
      }
      if !listId.isEmpty && canAttemptLogin {
        onboardingCompleted = true
      }

    } catch CheckvistSessionError.authenticationUnavailable {
      if errorMessage == nil {
        errorMessage = "Authentication required."
      }
    } catch {
      errorMessage = "Failed to fetch tasks: \(error.localizedDescription)"
    }
  }

  @MainActor func markCurrentTaskDone() async {
    guard let task = currentTask else { return }
    // Multi-step haptic pattern for stronger tactile feedback.
    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    try? await Task.sleep(nanoseconds: 60_000_000)
    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    // Spring the checkmark in.
    withAnimation(.spring(response: 0.28, dampingFraction: 0.45)) { completingTaskId = task.id }
    // Confirmation tap.
    try? await Task.sleep(nanoseconds: 120_000_000)
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    // Hold so strikethrough and pulse are visible.
    try? await Task.sleep(nanoseconds: 360_000_000)
    withAnimation { completingTaskId = nil }
    await taskAction(task, endpoint: "close")
  }

  /// POST to a Checkvist task action endpoint (close, reopen, invalidate)
  @MainActor private func taskAction(_ task: CheckvistTask, endpoint: String, isUndo: Bool = false)
    async
  {
    if !isUndo {
      if endpoint == "close" {
        lastUndo = .markDone(taskId: task.id)
      } else if endpoint == "invalidate" {
        lastUndo = .invalidate(taskId: task.id)
      }
    }

    guard let action = CheckvistTaskAction(rawValue: endpoint) else { return }
    let ancestorTaskIDsToKeepOpen =
      (!isUndo && endpoint == "close") ? ancestorTaskIDs(for: task, in: tasks) : []

    let optimisticSnapshot: OptimisticCompletionSnapshot? =
      (!isUndo && (endpoint == "close" || endpoint == "invalidate"))
      ? applyOptimisticCompletion(for: task.id) : nil

    do {
      let success = try await checkvistSyncPlugin.performTaskAction(
        listId: listId,
        taskId: task.id,
        action: action,
        credentials: activeCredentials
      )
      if success {
        await fetchTopTask()
        if !ancestorTaskIDsToKeepOpen.isEmpty {
          let reopenedAny = await reopenMissingAncestorTasksIfNeeded(ancestorTaskIDsToKeepOpen)
          if reopenedAny {
            await fetchTopTask()
          }
        }
      } else {
        if let optimisticSnapshot {
          restoreTasksSnapshot(optimisticSnapshot)
        }
        errorMessage = "Failed to \(endpoint) task."
      }
    } catch CheckvistSessionError.authenticationUnavailable {
      if let optimisticSnapshot {
        restoreTasksSnapshot(optimisticSnapshot)
      }
    } catch {
      if let optimisticSnapshot {
        restoreTasksSnapshot(optimisticSnapshot)
      }
      errorMessage = "Error: \(error.localizedDescription)"
    }
  }

  private func ancestorTaskIDs(for task: CheckvistTask, in taskList: [CheckvistTask]) -> [Int] {
    var taskByID: [Int: CheckvistTask] = [:]
    for listedTask in taskList {
      taskByID[listedTask.id] = listedTask
    }

    var ancestorIDs: [Int] = []
    var nextParentID = task.parentId ?? 0
    while nextParentID != 0 {
      ancestorIDs.append(nextParentID)
      guard let parent = taskByID[nextParentID] else { break }
      nextParentID = parent.parentId ?? 0
    }

    return ancestorIDs
  }

  @MainActor private func reopenMissingAncestorTasksIfNeeded(_ ancestorTaskIDs: [Int]) async -> Bool
  {
    let openTaskIDs = Set(tasks.map(\.id))
    let missingAncestorIDs = ancestorTaskIDs.filter { !openTaskIDs.contains($0) }
    guard !missingAncestorIDs.isEmpty else { return false }

    var reopenedAny = false
    for ancestorID in missingAncestorIDs {
      do {
        let success = try await checkvistSyncPlugin.performTaskAction(
          listId: listId,
          taskId: ancestorID,
          action: .reopen,
          credentials: activeCredentials
        )
        if success {
          reopenedAny = true
        }
      } catch CheckvistSessionError.authenticationUnavailable {
        if errorMessage == nil {
          errorMessage = "Authentication required."
        }
        break
      } catch {
        if errorMessage == nil {
          errorMessage = "Task completed, but a parent task could not be kept open."
        }
      }
    }

    return reopenedAny
  }

  @MainActor func fetchLists() async {
    do {
      let lists = try await checkvistSyncPlugin.fetchLists(credentials: activeCredentials)
      self.availableLists = lists
    } catch CheckvistSessionError.authenticationUnavailable {
      if errorMessage == nil {
        errorMessage = "Authentication required."
      }
    } catch {
      self.errorMessage = "Failed to fetch lists: \(error.localizedDescription)"
    }
  }

  @MainActor func selectList(_ list: CheckvistList) {
    listId = String(list.id)
  }

  @MainActor func updateTask(
    task: CheckvistTask, content: String? = nil, due: String? = nil, isUndo: Bool = false
  ) async {
    if !isUndo {
      lastUndo = .update(taskId: task.id, oldContent: task.content, oldDue: task.due)
    }

    do {
      let success = try await checkvistSyncPlugin.updateTask(
        listId: listId,
        taskId: task.id,
        content: content,
        due: due,
        credentials: activeCredentials
      )
      if success {
        await fetchTopTask()
      } else {
        errorMessage = "Failed to update task."
      }
    } catch CheckvistSessionError.authenticationUnavailable {
      if errorMessage == nil {
        errorMessage = "Authentication required."
      }
    } catch {
      errorMessage = "Error: \(error.localizedDescription)"
    }
  }

  @MainActor func addTask(content: String, insertAfterTask: CheckvistTask? = nil) async {
    guard !content.isEmpty, !listId.isEmpty else { return }

    let optimisticTask = insertOptimisticSiblingTask(content: content, afterTask: insertAfterTask)
    let optimisticTaskId = optimisticTask.id

    beginLoading()
    defer { endLoading() }
    errorMessage = nil

    // Find current position to insert right below
    var apiPosition = 0
    let target = insertAfterTask ?? currentTask
    if let current = target {
      if let targetPos = current.position {
        apiPosition = targetPos + 1
      } else {
        let siblings = tasks.filter { ($0.parentId ?? 0) == currentParentId }
        if let idx = siblings.firstIndex(where: { $0.id == current.id }) {
          apiPosition = idx + 2
        }
      }
    } else {
      apiPosition = 1
    }

    let parentIdForCreate = currentParentId == 0 ? nil : currentParentId
    let positionForCreate: Int? = apiPosition > 0 ? apiPosition : nil

    do {
      let newTask = try await checkvistSyncPlugin.createTask(
        listId: listId,
        content: content,
        parentId: parentIdForCreate,
        position: positionForCreate,
        credentials: activeCredentials
      )
      if let newTask {
        lastUndo = .add(taskId: newTask.id)
        await fetchTopTask()
      } else {
        removeOptimisticTask(id: optimisticTaskId)
        errorMessage = "Failed to add task."
      }
    } catch CheckvistSessionError.authenticationUnavailable {
      removeOptimisticTask(id: optimisticTaskId)
      if errorMessage == nil {
        errorMessage = "Authentication required."
      }
    } catch {
      removeOptimisticTask(id: optimisticTaskId)
      errorMessage = "Error adding task: \(error.localizedDescription)"
    }
  }

  @MainActor func addTaskAsChild(content: String, parentId: Int) async {
    guard !content.isEmpty, !listId.isEmpty else { return }
    let optimisticTask = insertOptimisticChildTask(content: content, parentId: parentId)
    let optimisticTaskId = optimisticTask.id

    beginLoading()
    defer { endLoading() }
    errorMessage = nil

    do {
      let newTask = try await checkvistSyncPlugin.createTask(
        listId: listId,
        content: content,
        parentId: parentId,
        position: 1,
        credentials: activeCredentials
      )
      if let newTask {
        lastUndo = .add(taskId: newTask.id)
        await fetchTopTask()
      } else {
        removeOptimisticTask(id: optimisticTaskId)
        errorMessage = "Failed to add task."
      }
    } catch CheckvistSessionError.authenticationUnavailable {
      removeOptimisticTask(id: optimisticTaskId)
      if errorMessage == nil {
        errorMessage = "Authentication required."
      }
    } catch {
      removeOptimisticTask(id: optimisticTaskId)
      errorMessage = "Error: \(error.localizedDescription)"
    }
  }

  @MainActor
  func beginQuickAddEntry(preferSpecificLocation: Bool? = nil) -> Bool {
    let useSpecificLocation =
      preferSpecificLocation ?? (quickAddLocationMode == .specificParentTask)
    if useSpecificLocation && quickAddSpecificParentTaskIdValue == nil {
      errorMessage = "Set a valid Quick Add parent task ID in Preferences first."
      return false
    }

    pendingDeleteConfirmation = false
    commandSuggestionIndex = 0
    quickEntryMode = useSpecificLocation ? .quickAddSpecific : .quickAddDefault
    filterText = ""
    isQuickEntryFocused = true
    return true
  }

  @MainActor
  func setQuickAddSpecificLocationToCurrentTask() {
    guard let currentTask else {
      errorMessage = "No task selected."
      return
    }
    quickAddSpecificParentTaskId = String(currentTask.id)
    quickAddLocationMode = .specificParentTask
    errorMessage = nil
  }

  @MainActor
  func submitQuickAddTask(content: String, useSpecificLocation: Bool) async {
    let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedContent.isEmpty else { return }
    guard !listId.isEmpty else {
      errorMessage = "List ID not set."
      return
    }

    let parentTaskId: Int?
    if useSpecificLocation {
      guard let specificTaskId = quickAddSpecificParentTaskIdValue else {
        errorMessage = "Set a valid Quick Add parent task ID in Preferences first."
        return
      }
      parentTaskId = specificTaskId
    } else {
      parentTaskId = nil
    }

    beginLoading()
    defer { endLoading() }
    errorMessage = nil

    do {
      let createdTask = try await checkvistSyncPlugin.createTask(
        listId: listId,
        content: normalizedContent,
        parentId: parentTaskId,
        position: 1,
        credentials: activeCredentials
      )
      guard let createdTask else {
        errorMessage = "Quick add failed."
        return
      }
      lastUndo = .add(taskId: createdTask.id)
      await fetchTopTask()
      quickEntryMode = .search
      filterText = ""
      isQuickEntryFocused = false
    } catch CheckvistSessionError.authenticationUnavailable {
      if errorMessage == nil {
        errorMessage = "Authentication required."
      }
    } catch {
      errorMessage = "Quick add failed: \(error.localizedDescription)"
    }
  }

  @MainActor private func insertOptimisticSiblingTask(content: String, afterTask: CheckvistTask?)
    -> CheckvistTask
  {
    let optimisticTask = CheckvistTask(
      id: nextOptimisticTaskId(),
      content: content,
      status: 0,
      due: nil,
      position: nil,
      parentId: currentParentId == 0 ? nil : currentParentId,
      level: nil
    )

    var insertIndex = tasks.endIndex
    if let target = afterTask, let rawIndex = tasks.firstIndex(where: { $0.id == target.id }) {
      var endIndex = rawIndex + 1
      while endIndex < tasks.count && isDescendant(tasks[endIndex], of: target.id) {
        endIndex += 1
      }
      insertIndex = endIndex
    }

    if insertIndex <= tasks.endIndex {
      tasks.insert(optimisticTask, at: insertIndex)
    } else {
      tasks.append(optimisticTask)
    }

    if let insertedIndex = currentLevelTasks.firstIndex(where: { $0.id == optimisticTask.id }) {
      currentSiblingIndex = insertedIndex
    }

    filterText = ""
    quickEntryMode = .search
    isQuickEntryFocused = false
    return optimisticTask
  }

  @MainActor private func insertOptimisticChildTask(content: String, parentId: Int) -> CheckvistTask
  {
    let optimisticTask = CheckvistTask(
      id: nextOptimisticTaskId(),
      content: content,
      status: 0,
      due: nil,
      position: nil,
      parentId: parentId,
      level: nil
    )

    if let parentRawIdx = tasks.firstIndex(where: { $0.id == parentId }) {
      tasks.insert(optimisticTask, at: parentRawIdx + 1)
    } else {
      tasks.append(optimisticTask)
    }

    filterText = ""
    quickEntryMode = .search
    isQuickEntryFocused = false
    return optimisticTask
  }

  @MainActor private func removeOptimisticTask(id: Int) {
    guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
    tasks.remove(at: index)
    clampSelectionToVisibleRange()
  }

  @MainActor private func clampSelectionToVisibleRange() {
    let maxIndex = max(visibleTasks.count - 1, 0)
    if currentSiblingIndex > maxIndex {
      currentSiblingIndex = maxIndex
    }
  }

  private struct OptimisticCompletionSnapshot {
    let tasks: [CheckvistTask]
    let priorityTaskIds: [Int]
  }

  @MainActor private func applyOptimisticCompletion(for taskId: Int)
    -> OptimisticCompletionSnapshot?
  {
    guard let removingRange = subtreeBlockRange(for: taskId, in: tasks) else { return nil }
    let removedTaskIds = Set(tasks[removingRange].map(\.id))
    let snapshot = OptimisticCompletionSnapshot(tasks: tasks, priorityTaskIds: priorityTaskIds)
    tasks.removeSubrange(removingRange)
    removeTasksFromPriorityQueue(removedTaskIds)
    clampSelectionToVisibleRange()
    return snapshot
  }

  @MainActor private func restoreTasksSnapshot(_ snapshot: OptimisticCompletionSnapshot) {
    tasks = snapshot.tasks
    savePriorityQueue(snapshot.priorityTaskIds)
    clampSelectionToVisibleRange()
  }

  private func nextOptimisticTaskId() -> Int {
    -Int.random(in: 1...1_000_000)
  }

  // MARK: - Delete

  @MainActor func deleteTask(_ task: CheckvistTask, isUndo: Bool = false) async {
    if !isUndo {
      lastUndo = nil  // Clear undo history since we don't support recovering hard-deleted tasks yet
    }

    beginLoading()
    defer { endLoading() }

    do {
      let success = try await checkvistSyncPlugin.deleteTask(
        listId: listId,
        taskId: task.id,
        credentials: activeCredentials
      )
      if success {
        await fetchTopTask()
      } else {
        errorMessage = "Failed to delete task."
      }
    } catch CheckvistSessionError.authenticationUnavailable {
      if errorMessage == nil {
        errorMessage = "Authentication required."
      }
    } catch {
      errorMessage = "Error: \(error.localizedDescription)"
    }
  }

  // MARK: - Invalidate

  @MainActor func reopenCurrentTask() async {
    guard let task = currentTask else { return }
    await taskAction(task, endpoint: "reopen")
  }

  @MainActor func invalidateCurrentTask() async {
    guard let task = currentTask else { return }
    await taskAction(task, endpoint: "invalidate")
  }

  // MARK: - Undo Execution

  @MainActor func undoLastAction() async {
    guard let action = lastUndo else { return }
    lastUndo = nil

    switch action {
    case .add(let taskId):
      let mockTask = CheckvistTask(
        id: taskId, content: "", status: 0, due: nil, position: nil, parentId: nil, level: nil)
      await deleteTask(mockTask, isUndo: true)
    case .markDone(let taskId), .invalidate(let taskId):
      let mockTask = CheckvistTask(
        id: taskId, content: "", status: 1, due: nil, position: nil, parentId: nil, level: nil)
      await taskAction(mockTask, endpoint: "reopen", isUndo: true)
    case .update(let taskId, let oldContent, let oldDue):
      let mockTask = CheckvistTask(
        id: taskId, content: "", status: 0, due: nil, position: nil, parentId: nil, level: nil)
      await updateTask(task: mockTask, content: oldContent, due: oldDue, isUndo: true)
    }
  }

  // MARK: - Open Link

  @MainActor func openTaskLink() {
    guard let task = currentTask else { return }
    // Extract first URL from task content
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    else { return }
    let range = NSRange(task.content.startIndex..., in: task.content)
    if let match = detector.firstMatch(in: task.content, range: range),
      let url = match.url
    {
      NSWorkspace.shared.open(url)
    }
  }

  // MARK: - Google Calendar

  @MainActor private func ensureGoogleCalendarIntegrationEnabled() -> Bool {
    guard googleCalendarIntegrationEnabled else {
      errorMessage = "Enable Google Calendar integration in Preferences first."
      return false
    }
    return true
  }

  @MainActor func openCurrentTaskInGoogleCalendar(taskId explicitTaskId: Int? = nil) {
    guard ensureGoogleCalendarIntegrationEnabled() else { return }

    let selectedTask: CheckvistTask?
    if let explicitTaskId {
      selectedTask = tasks.first(where: { $0.id == explicitTaskId })
    } else {
      selectedTask = currentTask
    }
    guard let selectedTask else {
      errorMessage = "No task selected."
      return
    }

    guard
      let googleCalendarURL = googleCalendarPlugin.makeCreateEventURL(
        task: selectedTask,
        listId: listId,
        now: Date()
      )
    else {
      errorMessage = "Could not create Google Calendar event URL."
      return
    }

    NSWorkspace.shared.open(googleCalendarURL)
    errorMessage = nil
  }

  // MARK: - MCP

  @MainActor private func ensureMCPIntegrationEnabled() -> Bool {
    guard mcpIntegrationEnabled else {
      errorMessage = "Enable MCP integration in Preferences first."
      return false
    }
    return true
  }

  @MainActor func refreshMCPServerCommandPath() {
    mcpServerCommandPath = mcpIntegrationPlugin.serverCommandURL()?.path ?? ""
  }

  @MainActor func copyMCPClientConfigurationToClipboard() {
    guard ensureMCPIntegrationEnabled() else { return }
    refreshMCPServerCommandPath()

    let config = mcpIntegrationPlugin.makeClientConfigurationJSON(
      credentials: activeCredentials,
      listId: listId,
      redactSecrets: false
    )
    NSPasteboard.general.clearContents()
    _ = NSPasteboard.general.setString(config, forType: .string)

    if mcpServerCommandPath.isEmpty {
      errorMessage =
        "MCP config copied with placeholder app path. Set BAR_TASKER_MCP_EXECUTABLE_PATH if your app is outside /Applications."
    } else {
      errorMessage = nil
    }
  }

  @MainActor func openMCPServerGuide() {
    guard ensureMCPIntegrationEnabled() else { return }
    guard let guideURL = mcpIntegrationPlugin.guideURL() else {
      errorMessage = "MCP guide not found. See docs/mcp-server.md in the repo."
      return
    }
    NSWorkspace.shared.open(guideURL)
    errorMessage = nil
  }

  // MARK: - Obsidian Sync

  @MainActor private func ensureObsidianIntegrationEnabled() -> Bool {
    guard obsidianIntegrationEnabled else {
      errorMessage = "Enable Obsidian integration in Preferences first."
      return false
    }
    return true
  }

  @discardableResult
  @MainActor func chooseObsidianInboxFolder() -> Bool {
    do {
      if let selectedPath = try obsidianPlugin.chooseInboxFolder() {
        obsidianInboxPath = selectedPath
        refreshOnboardingDialogState()
        errorMessage = nil
        return true
      }
      return false
    } catch {
      errorMessage = "Failed to save Obsidian folder access."
      return false
    }
  }

  @MainActor func clearObsidianInboxFolder() {
    obsidianPlugin.clearInboxFolder()
    obsidianInboxPath = ""
    refreshOnboardingDialogState()
  }

  @MainActor func linkCurrentTaskToObsidianFolder(taskId explicitTaskId: Int? = nil) {
    guard ensureObsidianIntegrationEnabled() else { return }
    guard
      let task = explicitTaskId.flatMap({ id in tasks.first(where: { $0.id == id }) })
        ?? currentTask
    else {
      errorMessage = "No task selected."
      return
    }

    do {
      if let linkedPath = try obsidianPlugin.chooseLinkedFolder(
        forTaskId: task.id,
        taskContent: task.content
      ) {
        _ = linkedPath
        errorMessage = nil
      }
    } catch {
      errorMessage = "Failed to link Obsidian folder."
    }
  }

  @MainActor func createAndLinkCurrentTaskObsidianFolder(taskId explicitTaskId: Int? = nil) {
    guard ensureObsidianIntegrationEnabled() else { return }
    guard
      let task = explicitTaskId.flatMap({ id in tasks.first(where: { $0.id == id }) })
        ?? currentTask
    else {
      errorMessage = "No task selected."
      return
    }

    do {
      if let createdPath = try obsidianPlugin.createAndLinkFolder(
        forTaskId: task.id,
        taskContent: task.content
      ) {
        _ = createdPath
        errorMessage = nil
      }
    } catch {
      errorMessage = "Failed to create and link Obsidian folder."
    }
  }

  @MainActor func clearCurrentTaskObsidianFolderLink(taskId explicitTaskId: Int? = nil) {
    guard let targetTaskId = explicitTaskId ?? currentTask?.id else {
      errorMessage = "No task selected."
      return
    }

    obsidianPlugin.clearLinkedFolder(forTaskId: targetTaskId)
    errorMessage = nil
  }

  @MainActor func hasObsidianFolderLink(taskId: Int) -> Bool {
    obsidianPlugin.hasLinkedFolder(forTaskId: taskId)
  }

  private func obsidianLinkedFolderAncestorTaskId(
    for task: CheckvistTask, taskList: [CheckvistTask]
  ) -> Int? {
    let taskById = Dictionary(uniqueKeysWithValues: taskList.map { ($0.id, $0) })
    var candidateTask: CheckvistTask? = task

    while let current = candidateTask {
      if obsidianPlugin.hasLinkedFolder(forTaskId: current.id) {
        return current.id
      }

      guard let parentId = current.parentId, parentId != 0 else { break }
      candidateTask = taskById[parentId]
    }

    return nil
  }

  @MainActor func syncCurrentTaskToObsidian(taskId explicitTaskId: Int? = nil) async {
    await syncCurrentTaskToObsidian(taskId: explicitTaskId, openMode: .standard)
  }

  @MainActor func openCurrentTaskInNewObsidianWindow(taskId explicitTaskId: Int? = nil) async {
    await syncCurrentTaskToObsidian(taskId: explicitTaskId, openMode: .newWindow)
  }

  @MainActor private func syncCurrentTaskToObsidian(
    taskId explicitTaskId: Int? = nil,
    openMode: ObsidianOpenMode
  ) async {
    guard ensureObsidianIntegrationEnabled() else { return }
    guard let targetTaskId = explicitTaskId ?? currentTask?.id else {
      errorMessage = "No task selected."
      return
    }
    guard !listId.isEmpty else {
      errorMessage = "List ID not set."
      return
    }

    if isNetworkReachable {
      let previousErrorMessage = errorMessage
      await fetchTopTask()
      if let task = tasks.first(where: { $0.id == targetTaskId }) {
        let linkedFolderTaskId = obsidianLinkedFolderAncestorTaskId(for: task, taskList: tasks)
        if linkedFolderTaskId == nil && obsidianInboxPath.isEmpty && !chooseObsidianInboxFolder() {
          return
        }
        do {
          _ = try obsidianPlugin.syncTask(
            task,
            listId: listId,
            linkedFolderTaskId: linkedFolderTaskId,
            openMode: openMode,
            syncDate: Date()
          )
          dequeuePendingObsidianSync(taskId: targetTaskId)
          errorMessage = nil
        } catch {
          enqueuePendingObsidianSync(taskId: targetTaskId)
          errorMessage =
            error.localizedDescription.isEmpty
            ? "Sync failed. Added to pending queue."
            : error.localizedDescription
        }
        return
      }

      if errorMessage == nil || errorMessage == previousErrorMessage {
        errorMessage = "Task not found after refresh."
        return
      }
    }

    guard let cachedPayload = checkvistSyncPlugin.loadTaskCache(for: listId) else {
      enqueuePendingObsidianSync(taskId: targetTaskId)
      errorMessage = "Offline and no cache available. Added to pending queue."
      return
    }
    guard let cachedTask = cachedPayload.tasks.first(where: { $0.id == targetTaskId }) else {
      enqueuePendingObsidianSync(taskId: targetTaskId)
      errorMessage = "Offline cache missing this task. Added to pending queue."
      return
    }

    let linkedFolderTaskId = obsidianLinkedFolderAncestorTaskId(
      for: cachedTask, taskList: cachedPayload.tasks)
    if linkedFolderTaskId == nil && obsidianInboxPath.isEmpty && !chooseObsidianInboxFolder() {
      return
    }

    do {
      _ = try obsidianPlugin.syncTask(
        cachedTask,
        listId: listId,
        linkedFolderTaskId: linkedFolderTaskId,
        openMode: openMode,
        syncDate: Date()
      )
      if checkvistSyncPlugin.isTaskCacheOutdated(cachedPayload) {
        enqueuePendingObsidianSync(taskId: targetTaskId)
      }
      errorMessage = nil
    } catch {
      enqueuePendingObsidianSync(taskId: targetTaskId)
      errorMessage = "Offline sync failed. Added to pending queue."
    }
  }

  @MainActor private func processPendingObsidianSyncQueue() async {
    guard obsidianIntegrationEnabled else { return }
    guard isNetworkReachable else { return }
    guard !pendingObsidianSyncTaskIds.isEmpty else { return }
    guard !hasPendingSyncProcessingTask else { return }
    hasPendingSyncProcessingTask = true
    defer { hasPendingSyncProcessingTask = false }

    let pendingTaskIds = pendingObsidianSyncTaskIds
    await fetchTopTask()
    guard isNetworkReachable else { return }

    for taskId in pendingTaskIds {
      guard let task = tasks.first(where: { $0.id == taskId }) else {
        dequeuePendingObsidianSync(taskId: taskId)
        continue
      }
      do {
        let linkedFolderTaskId = obsidianLinkedFolderAncestorTaskId(for: task, taskList: tasks)
        _ = try obsidianPlugin.syncTask(
          task,
          listId: listId,
          linkedFolderTaskId: linkedFolderTaskId,
          openMode: .standard,
          syncDate: Date()
        )
        dequeuePendingObsidianSync(taskId: taskId)
      } catch {
        // Keep queued; we'll retry on the next connectivity transition.
      }
    }
  }

  // MARK: - Reorder

  @MainActor func moveTask(_ task: CheckvistTask, direction: Int) async {
    guard direction == -1 || direction == 1 else { return }

    let siblings = tasks.filter { ($0.parentId ?? 0) == (task.parentId ?? 0) }
    guard let idx = siblings.firstIndex(where: { $0.id == task.id }) else { return }
    let newIdx = idx + direction
    guard siblings.indices.contains(newIdx) else { return }
    let neighbour = siblings[newIdx]
    let targetPosition = newIdx + 1
    let movingOriginalPosition = task.position

    // Optimistic UI update: move the task block immediately so the list responds instantly.
    if let movingRange = subtreeBlockRange(for: task.id, in: tasks),
      let neighbourRange = subtreeBlockRange(for: neighbour.id, in: tasks)
    {
      var updated = tasks
      let movingBlock = Array(updated[movingRange])
      updated.removeSubrange(movingRange)

      let insertIndex: Int
      if direction > 0 {
        // Neighbour was below; after removing our block, its end index shifts left.
        insertIndex = neighbourRange.upperBound - movingBlock.count
      } else {
        // Neighbour was above; its range is unaffected by the removal.
        insertIndex = neighbourRange.lowerBound
      }
      updated.insert(contentsOf: movingBlock, at: max(0, min(updated.count, insertIndex)))

      if let movedIdx = updated.firstIndex(where: { $0.id == task.id }) {
        updated[movedIdx] = taskWithPosition(updated[movedIdx], position: targetPosition)
      }
      if let neighbourIdx = updated.firstIndex(where: { $0.id == neighbour.id }) {
        updated[neighbourIdx] = taskWithPosition(
          updated[neighbourIdx], position: movingOriginalPosition)
      }

      tasks = updated
      // Keep selection anchored to the moved task in the currently visible list.
      if let visibleIdx = visibleTasks.firstIndex(where: { $0.id == task.id }) {
        currentSiblingIndex = visibleIdx
      } else {
        currentSiblingIndex = min(newIdx, max(0, visibleTasks.count - 1))
      }
    }

    enqueueReorderRequest(taskId: task.id, position: targetPosition)
  }

  private func taskWithPosition(_ task: CheckvistTask, position: Int?) -> CheckvistTask {
    CheckvistTask(
      id: task.id,
      content: task.content,
      status: task.status,
      due: task.due,
      position: position,
      parentId: task.parentId,
      level: task.level
    )
  }

  private func subtreeBlockRange(for taskId: Int, in flatTasks: [CheckvistTask]) -> Range<Int>? {
    guard let start = flatTasks.firstIndex(where: { $0.id == taskId }) else { return nil }

    var end = start + 1
    while end < flatTasks.count {
      let candidate = flatTasks[end]
      if isDescendant(candidate, of: taskId) {
        end += 1
      } else {
        break
      }
    }
    return start..<end
  }

  @MainActor private func enqueueReorderRequest(taskId: Int, position: Int) {
    pendingReorderRequests.removeAll { $0.taskId == taskId }
    pendingReorderRequests.append((taskId: taskId, position: position))
    startReorderSyncIfNeeded()
  }

  @MainActor private func startReorderSyncIfNeeded() {
    guard reorderSyncTask == nil else { return }

    reorderSyncTask = Task { [weak self] in
      guard let self else { return }
      var hadFailure = false

      while true {
        let nextRequest: (taskId: Int, position: Int)? = await MainActor.run {
          guard !self.pendingReorderRequests.isEmpty else { return nil }
          return self.pendingReorderRequests.removeFirst()
        }

        guard let nextRequest else { break }
        let success = await self.commitReorderRequest(
          taskId: nextRequest.taskId, position: nextRequest.position)
        if !success { hadFailure = true }
      }

      await MainActor.run {
        self.reorderSyncTask = nil
        if hadFailure { self.scheduleReorderResync() }
        if !self.pendingReorderRequests.isEmpty {
          self.startReorderSyncIfNeeded()
        }
      }
    }
  }

  private func commitReorderRequest(taskId: Int, position: Int) async -> Bool {
    do {
      let success = try await checkvistSyncPlugin.moveTask(
        listId: listId,
        taskId: taskId,
        position: position,
        credentials: activeCredentials
      )
      if !success {
        await MainActor.run {
          self.errorMessage = "Failed to move task."
        }
        return false
      }
      return true
    } catch CheckvistSessionError.authenticationUnavailable {
      return false
    } catch {
      await MainActor.run {
        self.errorMessage = "Error: \(error.localizedDescription)"
      }
      return false
    }
  }

  // MARK: - Timer Methods

  @MainActor func toggleTimerForCurrentTask() {
    guard timerIsEnabled else { return }
    guard let task = currentTask else { return }
    if timedTaskId == task.id {
      timerRunning ? pauseTimer() : resumeTimer()
    } else {
      pauseTimer()
      timedTaskId = task.id
      if timerByTaskId[task.id] == nil {
        timerByTaskId[task.id] = 0
      }
      resumeTimer()
    }
  }

  @MainActor func pauseTimer() {
    timerRunning = false
    timerTask?.cancel()
    timerTask = nil
  }

  @MainActor func resumeTimer() {
    guard timerIsEnabled, let activeTaskId = timedTaskId, !timerRunning else { return }
    timerRunning = true
    timerTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard !Task.isCancelled else { break }
        await MainActor.run {
          self?.timerByTaskId[activeTaskId, default: 0] += 1
        }
      }
    }
  }

  @MainActor func stopTimer() {
    pauseTimer()
    timedTaskId = nil
  }

  @MainActor func executeCommandInput(_ input: String) async {
    guard let task = currentTask else {
      errorMessage = "No task selected."
      return
    }

    let parsed = CheckvistCommandEngine.parse(input)
    logger.log("Executing command: \(input, privacy: .public)")

    switch parsed {
    case .done:
      await markCurrentTaskDone()
    case .undone:
      if lastUndo == nil {
        errorMessage = "Nothing to undo."
      } else {
        await undoLastAction()
      }
    case .invalidate:
      await invalidateCurrentTask()
    case .due(let raw):
      guard !raw.isEmpty else {
        errorMessage = "Missing due date/time. Try: due today 14:30"
        return
      }
      let resolved = Self.resolveDueDate(raw)
      await updateTask(task: task, due: resolved)
    case .clearDue:
      await updateTask(task: task, due: "")
    case .edit:
      quickEntryMode = .editTask
      editCursorAtEnd = true
      filterText = task.content
      isQuickEntryFocused = true
    case .search:
      quickEntryMode = .search
      filterText = ""
      isQuickEntryFocused = true
    case .addSibling:
      quickEntryMode = .addSibling
      isQuickEntryFocused = true
    case .addChild:
      quickEntryMode = .addChild
      isQuickEntryFocused = true
    case .openLink:
      openTaskLink()
    case .undo:
      await undoLastAction()
    case .toggleTimer:
      toggleTimerForCurrentTask()
    case .pauseTimer:
      if timerRunning { pauseTimer() } else { resumeTimer() }
    case .toggleHideFuture:
      hideFuture.toggle()
    case .delete:
      if confirmBeforeDelete {
        pendingDeleteConfirmation = true
      } else {
        await deleteTask(task)
      }
    case .moveUp:
      await moveTask(task, direction: -1)
    case .moveDown:
      await moveTask(task, direction: 1)
    case .enterChildren:
      enterChildren()
    case .exitParent:
      exitToParent()
    case .tag(let tagName):
      guard !tagName.isEmpty else {
        errorMessage = "Missing tag name. Try: tag urgent"
        return
      }
      let tagged =
        task.content.contains("#\(tagName)") ? task.content : "\(task.content) #\(tagName)"
      await updateTask(task: task, content: tagged)
    case .untag(let tagName):
      guard !tagName.isEmpty else {
        errorMessage = "Missing tag name. Try: untag urgent"
        return
      }
      let cleaned = task.content.replacingOccurrences(of: " #\(tagName)", with: "")
        .replacingOccurrences(of: "#\(tagName)", with: "")
        .trimmingCharacters(in: .whitespaces)
      await updateTask(task: task, content: cleaned)
    case .list(let query):
      guard !query.isEmpty else {
        errorMessage = "Missing list query. Try: list inbox"
        return
      }
      if availableLists.isEmpty {
        await fetchLists()
      }
      guard let found = availableLists.first(where: { $0.name.lowercased().contains(query) }) else {
        errorMessage = "No list matching \"\(query)\"."
        return
      }
      listId = "\(found.id)"
      currentParentId = 0
      currentSiblingIndex = 0
      filterText = ""
      await fetchTopTask()
    case .priority(let rank):
      setPriorityForCurrentTask(rank)
    case .priorityBack:
      sendCurrentTaskToPriorityBack()
    case .clearPriority:
      clearPriorityForCurrentTask()
    case .syncObsidian:
      await syncCurrentTaskToObsidian()
    case .syncObsidianNewWindow:
      await openCurrentTaskInNewObsidianWindow()
    case .linkObsidianFolder:
      linkCurrentTaskToObsidianFolder()
    case .createObsidianFolder:
      createAndLinkCurrentTaskObsidianFolder()
    case .clearObsidianFolderLink:
      clearCurrentTaskObsidianFolderLink()
    case .syncGoogleCalendar:
      openCurrentTaskInGoogleCalendar()
    case .unknown(let raw):
      errorMessage = "Unknown command: \(raw)"
      logger.error("Unknown command: \(raw, privacy: .public)")
    }
  }

  static func resolveDueDate(_ input: String) -> String {
    CheckvistCommandEngine.resolveDueDate(input)
  }

  func totalElapsed(forTaskId taskId: Int) -> TimeInterval {
    rolledUpElapsedByTaskId()[taskId] ?? 0
  }

  func totalElapsed(for task: CheckvistTask) -> TimeInterval {
    totalElapsed(forTaskId: task.id)
  }

  func childCountByTaskId() -> [Int: Int] {
    let nodes = tasks.map { CheckvistTimerNode(id: $0.id, parentId: $0.parentId) }
    return CheckvistTimerStore.childCountByTaskId(nodes: nodes)
  }

  func rolledUpElapsedByTaskId() -> [Int: TimeInterval] {
    let nodes = tasks.map { CheckvistTimerNode(id: $0.id, parentId: $0.parentId) }
    return CheckvistTimerStore.rolledUpElapsedByTaskId(nodes: nodes, ownElapsed: timerByTaskId)
  }

  @MainActor private func scheduleReorderResync() {
    reorderResyncTask?.cancel()
    reorderResyncTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 600_000_000)
      guard let self else { return }
      await self.fetchTopTask()
      await MainActor.run {
        self.reorderResyncTask = nil
      }
    }
  }

  // MARK: - Indent / Unindent

  @MainActor func indentTask(_ task: CheckvistTask) async {
    let siblings = tasks.filter { ($0.parentId ?? 0) == (task.parentId ?? 0) }
    guard let idx = siblings.firstIndex(where: { $0.id == task.id }), idx > 0 else { return }
    let newParent = siblings[idx - 1]

    do {
      let success = try await checkvistSyncPlugin.reparentTask(
        listId: listId,
        taskId: task.id,
        parentId: newParent.id,
        credentials: activeCredentials
      )
      if !success {
        errorMessage = "Failed to indent task."
        return
      }
    } catch CheckvistSessionError.authenticationUnavailable {
      if errorMessage == nil {
        errorMessage = "Authentication required."
      }
      return
    } catch {
      errorMessage = "Error indenting task: \(error.localizedDescription)"
      return
    }
    await fetchTopTask()
  }

  @MainActor func unindentTask(_ task: CheckvistTask) async {
    guard let parentId = task.parentId, parentId != 0 else { return }
    guard let parent = tasks.first(where: { $0.id == parentId }) else { return }
    let newParentId = parent.parentId ?? 0

    do {
      let success = try await checkvistSyncPlugin.reparentTask(
        listId: listId,
        taskId: task.id,
        parentId: newParentId == 0 ? nil : newParentId,
        credentials: activeCredentials
      )
      if !success {
        errorMessage = "Failed to unindent task."
        return
      }
    } catch CheckvistSessionError.authenticationUnavailable {
      if errorMessage == nil {
        errorMessage = "Authentication required."
      }
      return
    } catch {
      errorMessage = "Error unindenting task: \(error.localizedDescription)"
      return
    }
    await fetchTopTask()
  }
}
