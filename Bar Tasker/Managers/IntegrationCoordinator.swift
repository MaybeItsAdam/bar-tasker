import AppKit
import Combine
import Foundation
import OSLog

/// Provides read-only access to task/list data that IntegrationCoordinator needs.
@MainActor
protocol IntegrationDataSource: AnyObject {
  var tasks: [CheckvistTask] { get }
  var listId: String { get }
  var currentTask: CheckvistTask? { get }
  var activeCredentials: CheckvistCredentials { get }
}

@MainActor
class IntegrationCoordinator: ObservableObject {
  private let logger = Logger(
    subsystem: "uk.co.maybeitsadam.bar-tasker", category: "integrations")
  private let preferencesStore: BarTaskerPreferencesStore
  private var cancellables = Set<AnyCancellable>()

  weak var dataSource: IntegrationDataSource?

  /// Called when integration-enabled flags change so the coordinator can refresh onboarding.
  var onIntegrationStateChanged: (() -> Void)?

  // MARK: - Integration enable flags

  @Published var obsidianIntegrationEnabled: Bool
  @Published var googleCalendarIntegrationEnabled: Bool
  @Published var mcpIntegrationEnabled: Bool

  // MARK: - Integration state

  @Published var obsidianInboxPath: String
  @Published var mcpServerCommandPath: String
  @Published var pendingObsidianSyncTaskIds: [Int]
  @Published var googleCalendarEventLinksByTaskKey: [String: String]

  // MARK: - Plugin references

  let obsidianPlugin: any ObsidianIntegrationPlugin
  let googleCalendarPlugin: any GoogleCalendarIntegrationPlugin
  let mcpIntegrationPlugin: any MCPIntegrationPlugin

  // MARK: - Internal state

  var hasPendingSyncProcessingTask = false

  private static let pendingObsidianSyncDefaultsKey = "pendingObsidianSyncTaskIdsByListId"
  let pendingSyncQueueStore = ListScopedTaskIDStore(
    defaultsKey: IntegrationCoordinator.pendingObsidianSyncDefaultsKey
  )

  // MARK: - Computed

  var hasPendingObsidianSync: Bool { !pendingObsidianSyncTaskIds.isEmpty }

  var pendingSyncMenuBarPrefix: String {
    guard hasPendingObsidianSync else { return "" }
    return pendingObsidianSyncTaskIds.count == 1
      ? "Pending Sync" : "Pending Sync (\(pendingObsidianSyncTaskIds.count))"
  }

  var hasResolvedMCPServerCommand: Bool {
    !mcpServerCommandPath.isEmpty
  }

  // MARK: - Init

  init(
    preferencesStore: BarTaskerPreferencesStore,
    obsidianPlugin: any ObsidianIntegrationPlugin,
    googleCalendarPlugin: any GoogleCalendarIntegrationPlugin,
    mcpIntegrationPlugin: any MCPIntegrationPlugin,
    initialListId: String
  ) {
    self.preferencesStore = preferencesStore
    self.obsidianPlugin = obsidianPlugin
    self.googleCalendarPlugin = googleCalendarPlugin
    self.mcpIntegrationPlugin = mcpIntegrationPlugin

    let storedObsidianEnabled = preferencesStore.optionalBool(.obsidianIntegrationEnabled)
    let storedGoogleEnabled = preferencesStore.optionalBool(.googleCalendarIntegrationEnabled)
    let storedMCPEnabled = preferencesStore.optionalBool(.mcpIntegrationEnabled)

    self.obsidianIntegrationEnabled =
      storedObsidianEnabled
      ?? preferencesStore.bool(.obsidianIntegrationEnabled, default: false)
    self.googleCalendarIntegrationEnabled =
      storedGoogleEnabled
      ?? preferencesStore.bool(.googleCalendarIntegrationEnabled, default: false)
    self.mcpIntegrationEnabled =
      storedMCPEnabled
      ?? preferencesStore.bool(.mcpIntegrationEnabled, default: false)
    self.obsidianInboxPath = obsidianPlugin.inboxPath
    self.mcpServerCommandPath = mcpIntegrationPlugin.serverCommandURL()?.path ?? ""
    self.googleCalendarEventLinksByTaskKey = preferencesStore.stringDictionary(
      .googleCalendarEventLinksByTaskKey)
    self.pendingObsidianSyncTaskIds = ListScopedTaskIDStore(
      defaultsKey: IntegrationCoordinator.pendingObsidianSyncDefaultsKey
    ).load(for: initialListId)

    setupBindings()
  }

  private func setupBindings() {
    $obsidianIntegrationEnabled
      .sink { [weak self] value in
        self?.preferencesStore.set(value, for: .obsidianIntegrationEnabled)
        self?.onIntegrationStateChanged?()
      }
      .store(in: &cancellables)
    $googleCalendarIntegrationEnabled
      .sink { [weak self] value in
        self?.preferencesStore.set(value, for: .googleCalendarIntegrationEnabled)
        self?.onIntegrationStateChanged?()
      }
      .store(in: &cancellables)
    $mcpIntegrationEnabled
      .sink { [weak self] in
        self?.preferencesStore.set($0, for: .mcpIntegrationEnabled)
        self?.onIntegrationStateChanged?()
      }
      .store(in: &cancellables)
  }

  // MARK: - Pending Obsidian Sync Queue

  func loadPendingObsidianSyncQueue(for listId: String) {
    pendingObsidianSyncTaskIds = pendingSyncQueueStore.load(for: listId)
  }

  func savePendingObsidianSyncQueue(_ queue: [Int], listId: String) {
    let normalized = Self.normalizedTaskIdQueue(queue)
    pendingObsidianSyncTaskIds = normalized
    guard !listId.isEmpty else { return }
    pendingSyncQueueStore.save(normalized, for: listId)
  }

  func enqueuePendingObsidianSync(taskId: Int, listId: String) {
    var queue = pendingObsidianSyncTaskIds
    queue.removeAll { $0 == taskId }
    queue.append(taskId)
    savePendingObsidianSyncQueue(queue, listId: listId)
  }

  func dequeuePendingObsidianSync(taskId: Int, listId: String) {
    savePendingObsidianSyncQueue(
      pendingObsidianSyncTaskIds.filter { $0 != taskId }, listId: listId)
  }

  func reconcilePendingObsidianSyncQueueWithOpenTasks(openTaskIds: Set<Int>, listId: String) {
    let filtered = pendingObsidianSyncTaskIds.filter { openTaskIds.contains($0) }
    if filtered != pendingObsidianSyncTaskIds {
      savePendingObsidianSyncQueue(filtered, listId: listId)
    }
  }

  private static func normalizedTaskIdQueue(_ queue: [Int]) -> [Int] {
    var seen = Set<Int>()
    var normalized: [Int] = []
    for taskId in queue where taskId > 0 && !seen.contains(taskId) {
      seen.insert(taskId)
      normalized.append(taskId)
    }
    return normalized
  }

  // MARK: - Google Calendar Event Links

  private func integrationTaskStorageKey(taskId: Int, listId: String) -> String {
    let normalizedListId = listId.trimmingCharacters(in: .whitespacesAndNewlines)
    let scope = normalizedListId.isEmpty ? "offline" : normalizedListId
    return "\(scope):\(taskId)"
  }

  func hasGoogleCalendarEventLink(taskId: Int, listId: String) -> Bool {
    let key = integrationTaskStorageKey(taskId: taskId, listId: listId)
    return googleCalendarEventLinksByTaskKey[key] != nil
  }

  func googleCalendarEventLinkURL(taskId: Int, listId: String) -> URL? {
    let key = integrationTaskStorageKey(taskId: taskId, listId: listId)
    guard let rawValue = googleCalendarEventLinksByTaskKey[key], rawValue != "created" else {
      return nil
    }
    return URL(string: rawValue)
  }

  func recordGoogleCalendarEventLink(
    taskId: Int,
    listId: String,
    eventURL: URL?
  ) {
    let key = integrationTaskStorageKey(taskId: taskId, listId: listId)
    googleCalendarEventLinksByTaskKey[key] = eventURL?.absoluteString ?? "created"
    preferencesStore.set(googleCalendarEventLinksByTaskKey, for: .googleCalendarEventLinksByTaskKey)
  }

  // MARK: - Open Link

  func openTaskLink(task: CheckvistTask) {
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    else { return }
    let range = NSRange(task.content.startIndex..., in: task.content)
    if let match = detector.firstMatch(in: task.content, range: range),
      let url = match.url,
      let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    {
      NSWorkspace.shared.open(url)
    }
  }

  // MARK: - Google Calendar

  /// Returns an error message on failure, nil on success.
  func openTaskInGoogleCalendar(taskId explicitTaskId: Int? = nil) -> String? {
    guard googleCalendarIntegrationEnabled else {
      return "Enable Google Calendar integration in Preferences first."
    }
    guard let ds = dataSource else { return "Internal error: no data source." }

    let selectedTask: CheckvistTask?
    if let explicitTaskId {
      selectedTask = ds.tasks.first(where: { $0.id == explicitTaskId })
    } else {
      selectedTask = ds.currentTask
    }
    guard let selectedTask else {
      return "No task selected."
    }

    let listId = ds.listId

    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let outcome = try await self.googleCalendarPlugin.createEvent(
          task: selectedTask,
          listId: listId,
          now: Date()
        )
        self.recordGoogleCalendarEventLink(
          taskId: selectedTask.id,
          listId: listId,
          eventURL: outcome.urlToOpen
        )
        if let url = outcome.urlToOpen, url.scheme?.lowercased() == "https" {
          NSWorkspace.shared.open(url)
        }
        // Post error/success via the data source's errorMessage — handled by coordinator
      } catch {
        // Error handling delegated to coordinator
      }
    }

    return nil  // async — errors posted separately
  }

  /// Async version that returns error message.
  func openTaskInGoogleCalendarAsync(taskId explicitTaskId: Int? = nil) async -> String? {
    guard googleCalendarIntegrationEnabled else {
      return "Enable Google Calendar integration in Preferences first."
    }
    guard let ds = dataSource else { return "Internal error: no data source." }

    let selectedTask: CheckvistTask?
    if let explicitTaskId {
      selectedTask = ds.tasks.first(where: { $0.id == explicitTaskId })
    } else {
      selectedTask = ds.currentTask
    }
    guard let selectedTask else {
      return "No task selected."
    }

    let listId = ds.listId

    do {
      let outcome = try await googleCalendarPlugin.createEvent(
        task: selectedTask,
        listId: listId,
        now: Date()
      )
      recordGoogleCalendarEventLink(
        taskId: selectedTask.id,
        listId: listId,
        eventURL: outcome.urlToOpen
      )
      if let url = outcome.urlToOpen, url.scheme?.lowercased() == "https" {
        NSWorkspace.shared.open(url)
      }
      if !outcome.usedGoogleCalendarAPI && outcome.urlToOpen == nil {
        return "Could not create Google Calendar event."
      } else if outcome.usedGoogleCalendarAPI && outcome.urlToOpen == nil {
        return "Google Calendar event created."
      }
      return nil
    } catch {
      if let localizedError = error as? LocalizedError,
        let message = localizedError.errorDescription
      {
        return message
      }
      return "Google Calendar action failed: \(error.localizedDescription)"
    }
  }

  /// Returns an error message on failure, nil on success.
  func openSavedGoogleCalendarEventLink(taskId explicitTaskId: Int? = nil) -> String? {
    guard googleCalendarIntegrationEnabled else {
      return "Enable Google Calendar integration in Preferences first."
    }
    guard let ds = dataSource else { return "Internal error: no data source." }
    let targetTaskId = explicitTaskId ?? ds.currentTask?.id
    guard let targetTaskId else {
      return "No task selected."
    }
    guard let url = googleCalendarEventLinkURL(taskId: targetTaskId, listId: ds.listId),
      url.scheme?.lowercased() == "https"
    else {
      return "No saved browser link for this Google Calendar event."
    }
    NSWorkspace.shared.open(url)
    return nil
  }

  // MARK: - MCP

  func refreshMCPServerCommandPath() {
    mcpServerCommandPath = mcpIntegrationPlugin.serverCommandURL()?.path ?? ""
  }

  /// Returns an error message on failure, nil on success.
  func copyMCPClientConfigurationToClipboard() -> String? {
    guard mcpIntegrationEnabled else {
      return "Enable MCP integration in Preferences first."
    }
    guard let ds = dataSource else { return "Internal error: no data source." }

    refreshMCPServerCommandPath()

    let config = mcpIntegrationPlugin.makeClientConfigurationJSON(
      credentials: ds.activeCredentials,
      listId: ds.listId,
      redactSecrets: false
    )
    NSPasteboard.general.clearContents()
    _ = NSPasteboard.general.setString(config, forType: .string)

    if mcpServerCommandPath.isEmpty {
      return
        "MCP config copied with placeholder app path. Set BAR_TASKER_MCP_EXECUTABLE_PATH if your app is outside /Applications."
    }
    return nil
  }

  /// Returns an error message on failure, nil on success.
  func openMCPServerGuide() -> String? {
    guard mcpIntegrationEnabled else {
      return "Enable MCP integration in Preferences first."
    }
    guard let guideURL = mcpIntegrationPlugin.guideURL() else {
      return "MCP guide not found. See docs/mcp-server.md in the repo."
    }
    NSWorkspace.shared.open(guideURL)
    return nil
  }

  func mcpClientConfigurationPreview(credentials: CheckvistCredentials, listId: String) -> String {
    mcpIntegrationPlugin.makeClientConfigurationJSON(
      credentials: credentials,
      listId: listId,
      redactSecrets: true
    )
  }

  // MARK: - Obsidian

  /// Returns true if a folder was chosen, false otherwise. Sets error message via return value.
  @discardableResult
  func chooseObsidianInboxFolder() -> (success: Bool, error: String?) {
    do {
      if let selectedPath = try obsidianPlugin.chooseInboxFolder() {
        obsidianInboxPath = selectedPath
        onIntegrationStateChanged?()
        return (true, nil)
      }
      return (false, nil)
    } catch {
      return (false, "Failed to save Obsidian folder access.")
    }
  }

  func clearObsidianInboxFolder() {
    obsidianPlugin.clearInboxFolder()
    obsidianInboxPath = ""
    onIntegrationStateChanged?()
  }

  /// Returns an error message on failure, nil on success.
  func linkTaskToObsidianFolder(
    taskId explicitTaskId: Int? = nil
  ) -> String? {
    guard obsidianIntegrationEnabled else {
      return "Enable Obsidian integration in Preferences first."
    }
    guard let ds = dataSource else { return "Internal error: no data source." }
    guard
      let task = explicitTaskId.flatMap({ id in ds.tasks.first(where: { $0.id == id }) })
        ?? ds.currentTask
    else {
      return "No task selected."
    }

    do {
      if let linkedPath = try obsidianPlugin.chooseLinkedFolder(
        forTaskId: task.id,
        taskContent: task.content
      ) {
        _ = linkedPath
        return nil
      }
      return nil
    } catch {
      return "Failed to link Obsidian folder."
    }
  }

  /// Returns an error message on failure, nil on success.
  func createAndLinkTaskObsidianFolder(
    taskId explicitTaskId: Int? = nil
  ) -> String? {
    guard obsidianIntegrationEnabled else {
      return "Enable Obsidian integration in Preferences first."
    }
    guard let ds = dataSource else { return "Internal error: no data source." }
    guard
      let task = explicitTaskId.flatMap({ id in ds.tasks.first(where: { $0.id == id }) })
        ?? ds.currentTask
    else {
      return "No task selected."
    }

    do {
      if let createdPath = try obsidianPlugin.createAndLinkFolder(
        forTaskId: task.id,
        taskContent: task.content
      ) {
        _ = createdPath
        return nil
      }
      return nil
    } catch {
      return "Failed to create and link Obsidian folder."
    }
  }

  /// Returns an error message on failure, nil on success.
  func clearTaskObsidianFolderLink(taskId explicitTaskId: Int? = nil) -> String? {
    guard let ds = dataSource else { return "Internal error: no data source." }
    guard let targetTaskId = explicitTaskId ?? ds.currentTask?.id else {
      return "No task selected."
    }
    obsidianPlugin.clearLinkedFolder(forTaskId: targetTaskId)
    return nil
  }

  func hasObsidianFolderLink(taskId: Int) -> Bool {
    obsidianPlugin.hasLinkedFolder(forTaskId: taskId)
  }

  func hasObsidianSyncedNote(task: CheckvistTask, tasks: [CheckvistTask]) -> Bool {
    let linkedFolderTaskId = obsidianLinkedFolderAncestorTaskId(for: task, taskList: tasks)
    return obsidianPlugin.hasSyncedNote(task: task, linkedFolderTaskId: linkedFolderTaskId)
  }

  func obsidianLinkedFolderAncestorTaskId(
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

  /// Returns an error message on failure, nil on success.
  func syncTaskToObsidian(
    taskId explicitTaskId: Int? = nil,
    openMode: ObsidianOpenMode
  ) async -> String? {
    guard obsidianIntegrationEnabled else {
      return "Enable Obsidian integration in Preferences first."
    }
    guard let ds = dataSource else { return "Internal error: no data source." }
    guard let targetTaskId = explicitTaskId ?? ds.currentTask?.id else {
      return "No task selected."
    }
    guard let task = ds.tasks.first(where: { $0.id == targetTaskId }) ?? ds.currentTask else {
      return "Task not found."
    }

    let listId = ds.listId
    let linkedFolderTaskId = obsidianLinkedFolderAncestorTaskId(
      for: task, taskList: ds.tasks)
    if linkedFolderTaskId == nil && obsidianInboxPath.isEmpty {
      let result = chooseObsidianInboxFolder()
      if !result.success {
        return result.error
      }
    }

    do {
      _ = try obsidianPlugin.syncTask(
        task,
        listId: listId,
        linkedFolderTaskId: linkedFolderTaskId,
        openMode: openMode,
        syncDate: Date()
      )
      dequeuePendingObsidianSync(taskId: targetTaskId, listId: listId)
      return nil
    } catch {
      enqueuePendingObsidianSync(taskId: targetTaskId, listId: listId)
      return
        error.localizedDescription.isEmpty
        ? "Obsidian sync failed. Added to pending queue."
        : error.localizedDescription
    }
  }

  func processPendingObsidianSyncQueue() async {
    guard obsidianIntegrationEnabled else { return }
    guard !pendingObsidianSyncTaskIds.isEmpty else { return }
    guard !hasPendingSyncProcessingTask else { return }
    guard let ds = dataSource else { return }
    hasPendingSyncProcessingTask = true
    defer { hasPendingSyncProcessingTask = false }

    let pendingTaskIds = pendingObsidianSyncTaskIds
    let listId = ds.listId

    for taskId in pendingTaskIds {
      guard let task = ds.tasks.first(where: { $0.id == taskId }) else {
        dequeuePendingObsidianSync(taskId: taskId, listId: listId)
        continue
      }
      do {
        let linkedFolderTaskId = obsidianLinkedFolderAncestorTaskId(
          for: task, taskList: ds.tasks)
        _ = try obsidianPlugin.syncTask(
          task,
          listId: listId,
          linkedFolderTaskId: linkedFolderTaskId,
          openMode: .standard,
          syncDate: Date()
        )
        dequeuePendingObsidianSync(taskId: taskId, listId: listId)
      } catch {
        // Keep queued; we'll retry on the next connectivity transition.
      }
    }
  }
}
