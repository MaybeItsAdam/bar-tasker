import AppKit
import Foundation
import Observation
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
@Observable class IntegrationCoordinator {
  @ObservationIgnored private let logger = Logger(
    subsystem: "uk.co.maybeitsadam.bar-tasker", category: "integrations")
  @ObservationIgnored private let preferencesStore: BarTaskerPreferencesStore

  @ObservationIgnored weak var dataSource: IntegrationDataSource?

  /// Called when integration-enabled flags change so the coordinator can refresh onboarding.
  @ObservationIgnored var onIntegrationStateChanged: (() -> Void)?
  /// Called with an error message (or nil to clear) when integration actions produce errors.
  @ObservationIgnored var onError: ((String?) -> Void)?

  // MARK: - Integration enable flags

  var obsidianIntegrationEnabled: Bool {
    didSet {
      preferencesStore.set(obsidianIntegrationEnabled, for: .obsidianIntegrationEnabled)
      onIntegrationStateChanged?()
    }
  }
  var googleCalendarIntegrationEnabled: Bool {
    didSet {
      preferencesStore.set(googleCalendarIntegrationEnabled, for: .googleCalendarIntegrationEnabled)
      onIntegrationStateChanged?()
    }
  }
  var mcpIntegrationEnabled: Bool {
    didSet {
      preferencesStore.set(mcpIntegrationEnabled, for: .mcpIntegrationEnabled)
      onIntegrationStateChanged?()
    }
  }

  // MARK: - Integration state

  var obsidianInboxPath: String
  var mcpServerCommandPath: String
  var pendingObsidianSyncTaskIds: [Int]
  var googleCalendarEventLinksByTaskKey: [String: String]

  // MARK: - Plugin references

  let obsidianPlugin: any ObsidianIntegrationPlugin
  let googleCalendarPlugin: any GoogleCalendarIntegrationPlugin
  let mcpIntegrationPlugin: any MCPIntegrationPlugin

  // MARK: - Internal state

  @ObservationIgnored var hasPendingSyncProcessingTask = false

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

  func openTaskInGoogleCalendar(taskId explicitTaskId: Int? = nil) {
    guard googleCalendarIntegrationEnabled else {
      onError?("Enable Google Calendar integration in Preferences first.")
      return
    }
    guard let ds = dataSource else { onError?("Internal error: no data source."); return }

    let selectedTask: CheckvistTask?
    if let explicitTaskId {
      selectedTask = ds.tasks.first(where: { $0.id == explicitTaskId })
    } else {
      selectedTask = ds.currentTask
    }
    guard let selectedTask else {
      onError?("No task selected.")
      return
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
        self.onError?(nil)
      } catch {
        self.onError?(error.localizedDescription)
      }
    }
  }

  /// Async version that returns error message (used internally).
  private func openTaskInGoogleCalendarAsync(taskId explicitTaskId: Int? = nil) async -> String? {
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

  func openSavedGoogleCalendarEventLink(taskId explicitTaskId: Int? = nil) {
    guard googleCalendarIntegrationEnabled else {
      onError?("Enable Google Calendar integration in Preferences first.")
      return
    }
    guard let ds = dataSource else { onError?("Internal error: no data source."); return }
    let targetTaskId = explicitTaskId ?? ds.currentTask?.id
    guard let targetTaskId else {
      onError?("No task selected.")
      return
    }
    guard let url = googleCalendarEventLinkURL(taskId: targetTaskId, listId: ds.listId),
      url.scheme?.lowercased() == "https"
    else {
      onError?("No saved browser link for this Google Calendar event.")
      return
    }
    NSWorkspace.shared.open(url)
    onError?(nil)
  }

  // MARK: - MCP

  func refreshMCPServerCommandPath() {
    mcpServerCommandPath = mcpIntegrationPlugin.serverCommandURL()?.path ?? ""
  }

  func copyMCPClientConfigurationToClipboard() {
    guard mcpIntegrationEnabled else {
      onError?("Enable MCP integration in Preferences first.")
      return
    }
    guard let ds = dataSource else { onError?("Internal error: no data source."); return }

    refreshMCPServerCommandPath()

    let config = mcpIntegrationPlugin.makeClientConfigurationJSON(
      credentials: ds.activeCredentials,
      listId: ds.listId,
      redactSecrets: false
    )
    NSPasteboard.general.clearContents()
    _ = NSPasteboard.general.setString(config, forType: .string)

    if mcpServerCommandPath.isEmpty {
      onError?(
        "MCP config copied with placeholder app path. Set BAR_TASKER_MCP_EXECUTABLE_PATH if your app is outside /Applications."
      )
    } else {
      onError?(nil)
    }
  }

  func openMCPServerGuide() {
    guard mcpIntegrationEnabled else {
      onError?("Enable MCP integration in Preferences first.")
      return
    }
    guard let guideURL = mcpIntegrationPlugin.guideURL() else {
      onError?("MCP guide not found. See docs/mcp-server.md in the repo.")
      return
    }
    NSWorkspace.shared.open(guideURL)
    onError?(nil)
  }

  func mcpClientConfigurationPreview(credentials: CheckvistCredentials, listId: String) -> String {
    mcpIntegrationPlugin.makeClientConfigurationJSON(
      credentials: credentials,
      listId: listId,
      redactSecrets: true
    )
  }

  // MARK: - Obsidian

  @discardableResult
  func chooseObsidianInboxFolder() -> Bool {
    do {
      if let selectedPath = try obsidianPlugin.chooseInboxFolder() {
        obsidianInboxPath = selectedPath
        onIntegrationStateChanged?()
        onError?(nil)
        return true
      }
      return false
    } catch {
      onError?("Failed to save Obsidian folder access.")
      return false
    }
  }

  func clearObsidianInboxFolder() {
    obsidianPlugin.clearInboxFolder()
    obsidianInboxPath = ""
    onIntegrationStateChanged?()
  }

  func linkTaskToObsidianFolder(taskId explicitTaskId: Int? = nil) {
    guard obsidianIntegrationEnabled else {
      onError?("Enable Obsidian integration in Preferences first.")
      return
    }
    guard let ds = dataSource else { onError?("Internal error: no data source."); return }
    guard
      let task = explicitTaskId.flatMap({ id in ds.tasks.first(where: { $0.id == id }) })
        ?? ds.currentTask
    else {
      onError?("No task selected.")
      return
    }

    do {
      _ = try obsidianPlugin.chooseLinkedFolder(forTaskId: task.id, taskContent: task.content)
      onError?(nil)
    } catch {
      onError?("Failed to link Obsidian folder.")
    }
  }

  func createAndLinkTaskObsidianFolder(taskId explicitTaskId: Int? = nil) {
    guard obsidianIntegrationEnabled else {
      onError?("Enable Obsidian integration in Preferences first.")
      return
    }
    guard let ds = dataSource else { onError?("Internal error: no data source."); return }
    guard
      let task = explicitTaskId.flatMap({ id in ds.tasks.first(where: { $0.id == id }) })
        ?? ds.currentTask
    else {
      onError?("No task selected.")
      return
    }

    do {
      _ = try obsidianPlugin.createAndLinkFolder(forTaskId: task.id, taskContent: task.content)
      onError?(nil)
    } catch {
      onError?("Failed to create and link Obsidian folder.")
    }
  }

  func clearTaskObsidianFolderLink(taskId explicitTaskId: Int? = nil) {
    guard let ds = dataSource else { onError?("Internal error: no data source."); return }
    guard let targetTaskId = explicitTaskId ?? ds.currentTask?.id else {
      onError?("No task selected.")
      return
    }
    obsidianPlugin.clearLinkedFolder(forTaskId: targetTaskId)
    onError?(nil)
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

  func syncTaskToObsidian(taskId explicitTaskId: Int? = nil, openMode: ObsidianOpenMode) async {
    guard obsidianIntegrationEnabled else {
      onError?("Enable Obsidian integration in Preferences first.")
      return
    }
    guard let ds = dataSource else { onError?("Internal error: no data source."); return }
    guard let targetTaskId = explicitTaskId ?? ds.currentTask?.id else {
      onError?("No task selected.")
      return
    }
    guard let task = ds.tasks.first(where: { $0.id == targetTaskId }) ?? ds.currentTask else {
      onError?("Task not found.")
      return
    }

    let listId = ds.listId
    let linkedFolderTaskId = obsidianLinkedFolderAncestorTaskId(for: task, taskList: ds.tasks)
    if linkedFolderTaskId == nil && obsidianInboxPath.isEmpty {
      let success = chooseObsidianInboxFolder()
      if !success { return }
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
      onError?(nil)
    } catch {
      enqueuePendingObsidianSync(taskId: targetTaskId, listId: listId)
      onError?(
        error.localizedDescription.isEmpty
          ? "Obsidian sync failed. Added to pending queue."
          : error.localizedDescription
      )
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
