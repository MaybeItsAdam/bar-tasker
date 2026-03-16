import Combine
import Foundation
import OSLog
import ServiceManagement
import SwiftUI

struct CheckvistTask: Codable, Identifiable {
  let id: Int
  let content: String
  let status: Int
  let due: String?
  let position: Int?
  let parentId: Int?
  let level: Int?

  enum CodingKeys: String, CodingKey {
    case id, content, status, due, position
    case parentId = "parent_id"
    case level
  }

  private static let dueDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f
  }()

  var dueDate: Date? {
    guard let due else { return nil }
    return Self.dueDateFormatter.date(from: due)
  }

  var isOverdue: Bool {
    guard let d = dueDate else { return false }
    return d < Calendar.current.startOfDay(for: Date())
  }

  var isDueToday: Bool {
    guard let d = dueDate else { return false }
    return Calendar.current.isDateInToday(d)
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

class CheckvistManager: ObservableObject {
  private let logger = Logger(subsystem: "uk.co.maybeitsadam.checkvist-focus", category: "manager")

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
  enum QuickEntryMode { case search, addSibling, addChild, editTask, command }
  enum TimerMode: Int, CaseIterable {
    case visible
    case hidden
    case disabled
  }

  @Published var filterText: String = ""
  @Published var hideFuture: Bool = false
  @Published var keyBuffer: String = ""
  @Published var quickEntryMode: QuickEntryMode = .search
  @Published var isQuickEntryFocused: Bool = false
  @Published var editCursorAtEnd: Bool = true  // true = append (a), false = insert (i)
  @Published var pendingDeleteConfirmation: Bool = false
  @Published var completingTaskId: Int? = nil
  @Published var commandSuggestionIndex: Int = 0

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
  @Published var globalHotkeyEnabled: Bool
  /// Carbon keyCode for the global hotkey (default 49 = Space)
  @Published var globalHotkeyKeyCode: Int
  /// Carbon modifier mask (default 0x0800 = optionKey i.e. ⌥)
  @Published var globalHotkeyModifiers: Int

  /// Max width of the menu bar text
  @Published var maxTitleWidth: Double
  @Published var onboardingCompleted: Bool

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

  var needsInitialSetup: Bool {
    !onboardingCompleted || !canAttemptLogin || !hasListSelection
  }

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
    if !filterText.isEmpty && quickEntryMode == .search {
      // Recursive search: include any task under currentParentId that matches
      return tasks.filter { task in
        task.content.localizedCaseInsensitiveContains(filterText)
          && isDescendant(task, of: currentParentId)
      }
    }
    var result = currentLevelTasks
    if hideFuture {
      result = result.filter { task in
        guard let d = task.dueDate else { return false }
        guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) else {
          return false
        }
        return d <= Calendar.current.startOfDay(for: tomorrow)
      }
    }
    return result
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

  private var token: String? = nil
  private var cancellables = Set<AnyCancellable>()
  private var pendingReorderRequests: [(taskId: Int, position: Int)] = []
  private var reorderSyncTask: Task<Void, Never>? = nil
  private var reorderResyncTask: Task<Void, Never>? = nil
  private var hasAttemptedRemoteKeyBootstrap = false
  private let credentialStore = CheckvistCredentialStore()
  private let apiClient = CheckvistAPIClient()
  private var usesKeychainStorage: Bool {
    #if DEBUG
      !ignoreKeychainInDebug
    #else
      true
    #endif
  }

  init() {
    let storedUsername = UserDefaults.standard.string(forKey: "checkvistUsername") ?? ""
    let storedListId = UserDefaults.standard.string(forKey: "checkvistListId") ?? ""
    self.username = storedUsername
    self.listId = storedListId
    self.confirmBeforeDelete =
      UserDefaults.standard.object(forKey: "confirmBeforeDelete") as? Bool ?? true
    self.launchAtLogin = UserDefaults.standard.object(forKey: "launchAtLogin") as? Bool ?? false
    #if DEBUG
      self.ignoreKeychainInDebug =
        UserDefaults.standard.object(
          forKey: CheckvistCredentialStore.ignoreKeychainInDebugDefaultsKey)
        as? Bool
        ?? false
    #else
      self.ignoreKeychainInDebug = true
    #endif
    self.globalHotkeyEnabled =
      UserDefaults.standard.object(forKey: "globalHotkeyEnabled") as? Bool ?? false
    self.globalHotkeyKeyCode =
      UserDefaults.standard.object(forKey: "globalHotkeyKeyCode") as? Int ?? 49  // Space
    self.globalHotkeyModifiers =
      UserDefaults.standard.object(forKey: "globalHotkeyModifiers") as? Int ?? 0x0800  // ⌥
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

    let useKeychainStorageAtInit: Bool
    #if DEBUG
      let ignoreAtInit =
        UserDefaults.standard.object(
          forKey: CheckvistCredentialStore.ignoreKeychainInDebugDefaultsKey)
        as? Bool
        ?? false
      useKeychainStorageAtInit = !ignoreAtInit
    #else
      useKeychainStorageAtInit = true
    #endif

    self.remoteKey = credentialStore.startupRemoteKey(
      useKeychainStorageAtInit: useKeychainStorageAtInit)

    setupBindings()
  }

  private func setupBindings() {
    $username
      .dropFirst()
      .sink { [weak self] value in
        UserDefaults.standard.set(value, forKey: "checkvistUsername")
        self?.token = nil
      }.store(in: &cancellables)
    $remoteKey
      .dropFirst()
      .removeDuplicates()
      .sink { [weak self] value in
        guard let self else { return }
        self.token = nil
        self.credentialStore.persistRemoteKey(value, useKeychainStorage: self.usesKeychainStorage)
      }.store(in: &cancellables)
    $listId
      .dropFirst()
      .sink { [weak self] value in
        UserDefaults.standard.set(value, forKey: "checkvistListId")
        self?.token = nil
      }.store(in: &cancellables)
    $confirmBeforeDelete.sink { UserDefaults.standard.set($0, forKey: "confirmBeforeDelete") }
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

  @MainActor func resetOnboardingForDebug() {
    #if DEBUG
      token = nil
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
    #endif
  }

  @MainActor func markOnboardingCompleted() {
    onboardingCompleted = true
  }

  @MainActor func markOnboardingRequired() {
    onboardingCompleted = false
  }

  // MARK: - Navigation

  @MainActor func nextTask() {
    let count = visibleTasks.count
    guard count > 0 else { return }
    let clampedIndex = min(max(currentSiblingIndex, 0), count - 1)
    currentSiblingIndex = (clampedIndex + 1) % count
  }

  @MainActor func previousTask() {
    let count = visibleTasks.count
    guard count > 0 else { return }
    let clampedIndex = min(max(currentSiblingIndex, 0), count - 1)
    currentSiblingIndex = (clampedIndex - 1 + count) % count
  }

  /// Navigate into the current task's children
  @MainActor func enterChildren() {
    guard let task = currentTask, !currentTaskChildren.isEmpty else { return }
    currentParentId = task.id
    currentSiblingIndex = 0
  }

  /// Navigate back up to the parent level
  @MainActor func exitToParent() {
    guard currentParentId != 0 else { return }
    // Find the parent task and make it the selected sibling
    if let parent = tasks.first(where: { $0.id == currentParentId }) {
      let grandparentId = parent.parentId ?? 0
      let siblings = tasks.filter { ($0.parentId ?? 0) == grandparentId }
      currentParentId = grandparentId
      currentSiblingIndex = siblings.firstIndex(where: { $0.id == parent.id }) ?? 0
    } else {
      currentParentId = 0
      currentSiblingIndex = 0
    }
  }

  @MainActor func navigateTo(task: CheckvistTask) {
    let parentId = task.parentId ?? 0
    let siblings = tasks.filter { ($0.parentId ?? 0) == parentId }
    currentParentId = parentId
    currentSiblingIndex = siblings.firstIndex(where: { $0.id == task.id }) ?? 0
  }
  // MARK: - API

  @MainActor func login() async -> Bool {
    loadRemoteKeyFromKeychainIfNeeded()
    let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedRemoteKey = remoteKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedUsername.isEmpty, !normalizedRemoteKey.isEmpty else {
      errorMessage = "Username or Remote Key is missing."
      return false
    }

    isLoading = true
    errorMessage = nil

    guard let url = URL(string: "https://checkvist.com/auth/login.json") else {
      errorMessage = "Invalid login URL."
      isLoading = false
      return false
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("CheckvistFocus/1.0 (Macintosh; Mac OS X)", forHTTPHeaderField: "User-Agent")

    let body: [String: String] = [
      "username": normalizedUsername, "remote_key": normalizedRemoteKey,
    ]

    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      let (data, response) = try await apiClient.data(for: request)

      guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
        errorMessage = "Login failed. Check your credentials."
        isLoading = false
        return false
      }

      if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let tokenString = json["token"] as? String
      {
        self.token = tokenString
      } else if let tokenString = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
      {
        self.token = tokenString
      } else {
        errorMessage = "Failed to parse token."
        isLoading = false
        return false
      }

      isLoading = false
      return true
    } catch {
      errorMessage = "Network error: \(error.localizedDescription)"
      isLoading = false
      return false
    }
  }

  @MainActor func fetchTopTask() async {
    guard !listId.isEmpty else { return }

    if token == nil {
      // Ensure persisted credentials are available after app/laptop restarts.
      loadRemoteKeyFromKeychainIfNeeded()
      if remoteKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        errorMessage = "Authentication required."
        return
      }
      let success = await login()
      if !success { return }
    }

    guard let validToken = token else { return }

    isLoading = true
    errorMessage = nil

    guard let url = URL(string: "https://checkvist.com/checklists/\(listId)/tasks.json") else {
      errorMessage = "Invalid list URL."
      isLoading = false
      return
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
    request.setValue("CheckvistFocus/1.0 (Macintosh; Mac OS X)", forHTTPHeaderField: "User-Agent")

    do {
      let (data, response) = try await apiClient.data(for: request)

      if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
        self.token = nil
        self.isLoading = false
        return
      }

      let decoder = JSONDecoder()
      let allTasks = try decoder.decode([CheckvistTask].self, from: data)

      // Only open tasks, walk depth-first respecting Checkvist's tree order
      let open = allTasks.filter { $0.status == 0 }

      // Build a depth-first order: sort each level by position, recurse children
      // The API returns a flat list occasionally mixed up by creation time, so we must reconstruct the tree locally
      func depthFirst(parentId: Int, all: [CheckvistTask]) -> [CheckvistTask] {
        let children =
          all
          .filter { ($0.parentId ?? 0) == parentId }
          .sorted { ($0.position ?? 0) < ($1.position ?? 0) }
        return children.flatMap { [$0] + depthFirst(parentId: $0.id, all: all) }
      }
      let sortedForest = depthFirst(parentId: 0, all: open)

      self.tasks = sortedForest
      if currentSiblingIndex >= sortedForest.count { currentSiblingIndex = 0 }
      let validTaskIds = Set(sortedForest.map(\.id))
      self.timerByTaskId = self.timerByTaskId.filter { validTaskIds.contains($0.key) }
      if !listId.isEmpty && canAttemptLogin {
        onboardingCompleted = true
      }

    } catch {
      errorMessage = "Failed to fetch tasks: \(error.localizedDescription)"
    }

    isLoading = false
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

    if token == nil {
      let ok = await login()
      if !ok { return }
    }
    guard let validToken = token else { return }
    guard
      let url = URL(
        string: "https://checkvist.com/checklists/\(listId)/tasks/\(task.id)/\(endpoint).json")
    else { return }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
    request.setValue("CheckvistFocus/1.0 (Macintosh; Mac OS X)", forHTTPHeaderField: "User-Agent")

    let optimisticSnapshot: [CheckvistTask]? =
      (!isUndo && (endpoint == "close" || endpoint == "invalidate"))
      ? applyOptimisticCompletion(for: task.id) : nil

    do {
      let (_, response) = try await apiClient.data(for: request)
      if let r = response as? HTTPURLResponse, (200...299).contains(r.statusCode) {
        await fetchTopTask()
      } else {
        if let optimisticSnapshot {
          restoreTasksSnapshot(optimisticSnapshot)
        }
        errorMessage = "Failed to \(endpoint) task."
      }
    } catch {
      if let optimisticSnapshot {
        restoreTasksSnapshot(optimisticSnapshot)
      }
      errorMessage = "Error: \(error.localizedDescription)"
    }
  }
  @MainActor func fetchLists() async {
    if token == nil {
      let ok = await login()
      if !ok { return }
    }
    guard let validToken = token,
      let url = URL(string: "https://checkvist.com/checklists.json")
    else { return }

    var request = URLRequest(url: url)
    request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    do {
      let (data, response) = try await apiClient.data(for: request)
      if let httpResponse = response as? HTTPURLResponse,
        (200...299).contains(httpResponse.statusCode)
      {
        let lists = try JSONDecoder().decode([CheckvistList].self, from: data)
        self.availableLists = lists.filter { !($0.archived ?? false) }
      } else {
        self.errorMessage = "Failed to fetch lists."
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

    if token == nil {
      let ok = await login()
      if !ok { return }
    }
    guard let validToken = token else { return }
    guard let url = URL(string: "https://checkvist.com/checklists/\(listId)/tasks/\(task.id).json")
    else { return }

    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("CheckvistFocus/1.0 (Macintosh; Mac OS X)", forHTTPHeaderField: "User-Agent")

    var taskDict: [String: Any] = [:]
    if let c = content { taskDict["content"] = c }
    if let d = due { taskDict["due"] = d }

    request.httpBody = try? JSONSerialization.data(withJSONObject: ["task": taskDict])

    do {
      let (_, response) = try await apiClient.data(for: request)
      if let httpResponse = response as? HTTPURLResponse,
        (200...299).contains(httpResponse.statusCode)
      {
        await fetchTopTask()
      } else {
        errorMessage = "Failed to update task."
      }
    } catch {
      errorMessage = "Error: \(error.localizedDescription)"
    }
  }

  @MainActor func addTask(content: String, insertAfterTask: CheckvistTask? = nil) async {
    guard !content.isEmpty, !listId.isEmpty else { return }

    let optimisticTask = insertOptimisticSiblingTask(content: content, afterTask: insertAfterTask)
    let optimisticTaskId = optimisticTask.id

    if token == nil {
      let success = await login()
      if !success {
        removeOptimisticTask(id: optimisticTaskId)
        return
      }
    }

    guard let validToken = token else { return }

    isLoading = true
    errorMessage = nil

    guard let url = URL(string: "https://checkvist.com/checklists/\(listId)/tasks.json?parse=true")
    else {
      isLoading = false
      return
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("CheckvistFocus/1.0 (Macintosh; Mac OS X)", forHTTPHeaderField: "User-Agent")

    var taskPayload: [String: Any] = ["content": content]
    if currentParentId != 0 {
      taskPayload["parent_id"] = currentParentId
    }

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

    if apiPosition > 0 { taskPayload["position"] = apiPosition }

    request.httpBody = try? JSONSerialization.data(withJSONObject: ["task": taskPayload])

    do {
      let (data, response) = try await apiClient.data(for: request)
      if let httpResponse = response as? HTTPURLResponse,
        (200...299).contains(httpResponse.statusCode)
      {
        if let newTask = try? JSONDecoder().decode(CheckvistTask.self, from: data) {
          lastUndo = .add(taskId: newTask.id)
        }
        await fetchTopTask()
      } else {
        removeOptimisticTask(id: optimisticTaskId)
        errorMessage = "Failed to add task."
        isLoading = false
      }
    } catch {
      removeOptimisticTask(id: optimisticTaskId)
      errorMessage = "Error adding task: \(error.localizedDescription)"
      isLoading = false
    }
  }

  @MainActor func addTaskAsChild(content: String, parentId: Int) async {
    guard !content.isEmpty, !listId.isEmpty else { return }
    let optimisticTask = insertOptimisticChildTask(content: content, parentId: parentId)
    let optimisticTaskId = optimisticTask.id

    if token == nil {
      let ok = await login()
      if !ok {
        removeOptimisticTask(id: optimisticTaskId)
        return
      }
    }
    guard let validToken = token,
      let url = URL(string: "https://checkvist.com/checklists/\(listId)/tasks.json?parse=true")
    else {
      removeOptimisticTask(id: optimisticTaskId)
      return
    }
    isLoading = true
    errorMessage = nil
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("CheckvistFocus/1.0", forHTTPHeaderField: "User-Agent")
    request.httpBody = try? JSONSerialization.data(withJSONObject: [
      "task": ["content": content, "parent_id": parentId, "position": 1]
    ])

    do {
      let (data, response) = try await apiClient.data(for: request)
      if let r = response as? HTTPURLResponse, (200...299).contains(r.statusCode) {
        if let newTask = try? JSONDecoder().decode(CheckvistTask.self, from: data) {
          lastUndo = .add(taskId: newTask.id)
        }
        await fetchTopTask()
      } else {
        removeOptimisticTask(id: optimisticTaskId)
        errorMessage = "Failed to add task."
        isLoading = false
      }
    } catch {
      removeOptimisticTask(id: optimisticTaskId)
      errorMessage = "Error: \(error.localizedDescription)"
      isLoading = false
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

  @MainActor private func applyOptimisticCompletion(for taskId: Int) -> [CheckvistTask]? {
    guard let removingRange = subtreeBlockRange(for: taskId, in: tasks) else { return nil }
    let snapshot = tasks
    tasks.removeSubrange(removingRange)
    clampSelectionToVisibleRange()
    return snapshot
  }

  @MainActor private func restoreTasksSnapshot(_ snapshot: [CheckvistTask]) {
    tasks = snapshot
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

    if token == nil {
      let ok = await login()
      if !ok { return }
    }
    guard let validToken = token else { return }
    guard let url = URL(string: "https://checkvist.com/checklists/\(listId)/tasks/\(task.id).json")
    else { return }

    isLoading = true
    var request = URLRequest(url: url)
    request.httpMethod = "DELETE"
    request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
    request.setValue("CheckvistFocus/1.0", forHTTPHeaderField: "User-Agent")

    do {
      let (_, response) = try await apiClient.data(for: request)
      if let r = response as? HTTPURLResponse, (200...299).contains(r.statusCode) {
        await fetchTopTask()
      } else {
        errorMessage = "Failed to delete task."
        isLoading = false
      }
    } catch {
      errorMessage = "Error: \(error.localizedDescription)"
      isLoading = false
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
    if token == nil {
      let ok = await login()
      if !ok { return false }
    }
    guard let validToken = token,
      let url = URL(string: "https://checkvist.com/checklists/\(listId)/tasks/\(taskId).json")
    else { return false }

    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("CheckvistFocus/1.0", forHTTPHeaderField: "User-Agent")
    request.httpBody = try? JSONSerialization.data(withJSONObject: [
      "task": ["position": position]
    ])

    do {
      let (_, response) = try await apiClient.data(for: request)
      if let httpResponse = response as? HTTPURLResponse,
        !(200...299).contains(httpResponse.statusCode)
      {
        await MainActor.run {
          self.errorMessage = "Failed to move task."
        }
        return false
      }
      return true
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
        errorMessage = "Missing due date. Try: due today"
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
    if token == nil {
      let ok = await login()
      if !ok { return }
    }
    guard let validToken = token else { return }
    let siblings = tasks.filter { ($0.parentId ?? 0) == (task.parentId ?? 0) }
    guard let idx = siblings.firstIndex(where: { $0.id == task.id }), idx > 0 else { return }
    let newParent = siblings[idx - 1]

    guard let url = URL(string: "https://checkvist.com/checklists/\(listId)/tasks/\(task.id).json")
    else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("CheckvistFocus/1.0", forHTTPHeaderField: "User-Agent")
    request.httpBody = try? JSONSerialization.data(withJSONObject: [
      "task": ["parent_id": newParent.id]
    ])
    do {
      let (_, response) = try await apiClient.data(for: request)
      if let httpResponse = response as? HTTPURLResponse,
        !(200...299).contains(httpResponse.statusCode)
      {
        errorMessage = "Failed to indent task."
        return
      }
    } catch {
      errorMessage = "Error indenting task: \(error.localizedDescription)"
      return
    }
    await fetchTopTask()
  }

  @MainActor func unindentTask(_ task: CheckvistTask) async {
    if token == nil {
      let ok = await login()
      if !ok { return }
    }
    guard let validToken = token, let parentId = task.parentId, parentId != 0 else { return }
    guard let parent = tasks.first(where: { $0.id == parentId }) else { return }
    let newParentId = parent.parentId ?? 0

    guard let url = URL(string: "https://checkvist.com/checklists/\(listId)/tasks/\(task.id).json")
    else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("CheckvistFocus/1.0", forHTTPHeaderField: "User-Agent")
    let body: [String: Any] =
      newParentId == 0 ? ["task": ["parent_id": NSNull()]] : ["task": ["parent_id": newParentId]]
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    do {
      let (_, response) = try await apiClient.data(for: request)
      if let httpResponse = response as? HTTPURLResponse,
        !(200...299).contains(httpResponse.statusCode)
      {
        errorMessage = "Failed to unindent task."
        return
      }
    } catch {
      errorMessage = "Error unindenting task: \(error.localizedDescription)"
      return
    }
    await fetchTopTask()
  }
}
