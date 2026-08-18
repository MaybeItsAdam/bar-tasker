import AppKit
import Foundation
import OSLog
import Observation
import PriorityCore

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
    subsystem: "uk.co.maybeitsadam.priority", category: "integrations")
  @ObservationIgnored private let preferencesStore: PreferencesStore

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

  /// MCP clients found on this machine, and the result of the last setup action.
  /// Populated by `refreshDetectedMCPClients()` when the MCP settings page opens.
  var detectedMCPClients: [MCPClientDescriptor] = []
  var mcpSetupStatusMessage: String = ""
  var mcpSetupStatusIsError: Bool = false

  @ObservationIgnored private let mcpClientInstaller = MCPClientInstaller()

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
    PendingSyncQueue.menuBarPrefix(count: pendingObsidianSyncTaskIds.count)
  }

  var hasResolvedMCPServerCommand: Bool {
    !mcpServerCommandPath.isEmpty
  }

  // MARK: - Init

  init(
    preferencesStore: PreferencesStore,
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
    let normalized = PendingSyncQueue.normalized(queue)
    pendingObsidianSyncTaskIds = normalized
    guard !listId.isEmpty else { return }
    pendingSyncQueueStore.save(normalized, for: listId)
  }

  func enqueuePendingObsidianSync(taskId: Int, listId: String) {
    savePendingObsidianSyncQueue(
      PendingSyncQueue.enqueue(taskId, into: pendingObsidianSyncTaskIds), listId: listId)
  }

  func dequeuePendingObsidianSync(taskId: Int, listId: String) {
    savePendingObsidianSyncQueue(
      PendingSyncQueue.dequeue(taskId, from: pendingObsidianSyncTaskIds), listId: listId)
  }

  func reconcilePendingObsidianSyncQueueWithOpenTasks(openTaskIds: Set<Int>, listId: String) {
    let filtered = PendingSyncQueue.reconciled(
      pendingObsidianSyncTaskIds, withOpenTaskIds: openTaskIds)
    // Only write when something actually went, so a routine fetch doesn't churn
    // the preferences store or the observation bus.
    guard filtered != pendingObsidianSyncTaskIds else { return }
    savePendingObsidianSyncQueue(filtered, listId: listId)
  }

  // MARK: - Google Calendar Event Links

  private func integrationTaskStorageKey(taskId: Int, listId: String) -> String {
    IntegrationLinkStore.storageKey(taskId: taskId, listId: listId)
  }

  func hasGoogleCalendarEventLink(taskId: Int, listId: String) -> Bool {
    IntegrationLinkStore.hasEventLink(
      taskId: taskId, listId: listId, in: googleCalendarEventLinksByTaskKey)
  }

  func googleCalendarEventLinkURL(taskId: Int, listId: String) -> URL? {
    IntegrationLinkStore.eventLinkURL(
      taskId: taskId, listId: listId, in: googleCalendarEventLinksByTaskKey)
  }

  func recordGoogleCalendarEventLink(
    taskId: Int,
    listId: String,
    eventURL: URL?
  ) {
    googleCalendarEventLinksByTaskKey = IntegrationLinkStore.recording(
      eventURL: eventURL, taskId: taskId, listId: listId,
      into: googleCalendarEventLinksByTaskKey)
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
        "MCP config copied with placeholder app path. Set PRIORITY_MCP_EXECUTABLE_PATH if your app is outside /Applications."
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

  // MARK: - MCP client setup

  /// True once Checkvist credentials exist. Without them the generated config
  /// carries `you@example.com` placeholders and every tool call fails on the
  /// client's side, which is a confusing way to discover a missing login.
  var hasMCPCredentials: Bool {
    guard let ds = dataSource else { return false }
    return !ds.activeCredentials.normalizedUsername.isEmpty
      && !ds.activeCredentials.normalizedRemoteKey.isEmpty
  }

  /// Refreshed explicitly rather than computed, so SwiftUI doesn't stat the
  /// filesystem on every body evaluation.
  func refreshDetectedMCPClients() {
    detectedMCPClients = mcpClientInstaller.detectedClients()
  }

  func mcpConfigPath(for client: MCPClientDescriptor) -> String {
    mcpClientInstaller.configURL(for: client).path
  }

  /// One button per client. Whichever route a client needs, this is the whole
  /// interaction: no locating config files, no merging JSON by hand.
  func setUpMCPClient(_ client: MCPClientDescriptor) {
    guard mcpIntegrationEnabled else {
      setMCPSetupStatus("Enable MCP integration first.", isError: true)
      return
    }
    guard let entry = makeMCPServerEntry(requiresTransportType: client.requiresTransportType) else {
      setMCPSetupStatus("Internal error: no data source.", isError: true)
      return
    }

    switch client.installStyle {
    case .mergeConfigFile:
      installMCPConfigFile(entry: entry, client: client)
    case .terminalCommand:
      copyToPasteboard(MCPClientConfigWriter.terminalCommand(entry: entry))
      setMCPSetupStatus(
        "Command copied. Paste it into Terminal. \(client.postInstallNote)", isError: false)
    case .pasteSnippet:
      copyToPasteboard(
        MCPClientConfigWriter.pasteSnippet(entry: entry, serversKey: client.serversKey))
      setMCPSetupStatus(
        "Snippet copied. Paste it inside the outer braces of \(client.configPath). "
          + client.postInstallNote,
        isError: false
      )
    }
  }

  private func installMCPConfigFile(entry: MCPServerEntry, client: MCPClientDescriptor) {
    do {
      switch try mcpClientInstaller.install(entry: entry, into: client) {
      case .cancelled:
        setMCPSetupStatus("Setup cancelled — \(client.displayName) wasn't changed.", isError: false)
      case .wrote(.added):
        setMCPSetupStatus("Added to \(client.displayName). \(client.postInstallNote)", isError: false)
      case .wrote(.updated):
        setMCPSetupStatus(
          "Updated the entry in \(client.displayName). \(client.postInstallNote)", isError: false)
      case .wrote(.unchanged):
        setMCPSetupStatus("\(client.displayName) is already set up.", isError: false)
      }
    } catch {
      logger.error("MCP setup for \(client.id, privacy: .public) failed: \(error)")
      setMCPSetupStatus(error.localizedDescription, isError: true)
    }
  }

  private func makeMCPServerEntry(requiresTransportType: Bool) -> MCPServerEntry? {
    guard let ds = dataSource else { return nil }
    refreshMCPServerCommandPath()
    let invocation = mcpIntegrationPlugin.serverInvocation()
    return MCPServerEntry(
      command: invocation.command,
      args: invocation.args,
      env: mcpIntegrationPlugin.serverEnvironment(
        credentials: ds.activeCredentials,
        listId: ds.listId
      ),
      transportType: requiresTransportType ? "stdio" : nil
    )
  }

  private func setMCPSetupStatus(_ message: String, isError: Bool) {
    mcpSetupStatusMessage = message
    mcpSetupStatusIsError = isError
  }

  private func copyToPasteboard(_ value: String) {
    NSPasteboard.general.clearContents()
    _ = NSPasteboard.general.setString(value, forType: .string)
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
