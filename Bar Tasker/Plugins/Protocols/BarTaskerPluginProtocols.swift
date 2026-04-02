import Foundation

protocol BarTaskerPlugin {
  var pluginIdentifier: String { get }
  var displayName: String { get }
}

struct CheckvistCredentials: Sendable {
  let username: String
  let remoteKey: String

  var normalizedUsername: String {
    username.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var normalizedRemoteKey: String {
    remoteKey.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

enum CheckvistTaskAction: String, Sendable {
  case close
  case reopen
  case invalidate
}

@MainActor
protocol CheckvistSyncPlugin: BarTaskerPlugin {
  func startupRemoteKey(useKeychainStorageAtInit: Bool) -> String
  func persistRemoteKey(_ value: String, useKeychainStorage: Bool)
  func persistRemoteKeyForDebugStorageMode(_ value: String)
  func loadRemoteKeyFromKeychain() -> String?
  func clearAuthentication()
  func login(credentials: CheckvistCredentials) async throws -> Bool
  func fetchOpenTasks(listId: String, credentials: CheckvistCredentials) async throws
    -> [CheckvistTask]
  func fetchLists(credentials: CheckvistCredentials) async throws -> [CheckvistList]
  func createList(name: String, credentials: CheckvistCredentials) async throws -> CheckvistList?
  func performTaskAction(
    listId: String,
    taskId: Int,
    action: CheckvistTaskAction,
    credentials: CheckvistCredentials
  ) async throws -> Bool
  func updateTask(
    listId: String,
    taskId: Int,
    content: String?,
    due: String?,
    credentials: CheckvistCredentials
  ) async throws -> Bool
  func createTask(
    listId: String,
    content: String,
    parentId: Int?,
    position: Int?,
    credentials: CheckvistCredentials
  ) async throws -> CheckvistTask?
  func deleteTask(listId: String, taskId: Int, credentials: CheckvistCredentials) async throws
    -> Bool
  func moveTask(
    listId: String,
    taskId: Int,
    position: Int,
    credentials: CheckvistCredentials
  ) async throws -> Bool
  func reparentTask(
    listId: String,
    taskId: Int,
    parentId: Int?,
    credentials: CheckvistCredentials
  ) async throws -> Bool
  func persistTaskCache(listId: String, tasks: [CheckvistTask])
  func loadTaskCache(for listId: String) -> CheckvistTaskCachePayload?
  func isTaskCacheOutdated(_ payload: CheckvistTaskCachePayload) -> Bool
}

@MainActor
extension CheckvistSyncPlugin {
  func startupRemoteKey(useKeychainStorageAtInit: Bool) -> String {
    ""
  }

  func persistRemoteKey(_ value: String, useKeychainStorage: Bool) {}

  func persistRemoteKeyForDebugStorageMode(_ value: String) {}

  func loadRemoteKeyFromKeychain() -> String? {
    nil
  }

  func createList(name: String, credentials: CheckvistCredentials) async throws -> CheckvistList? {
    nil
  }
}

@MainActor
protocol ObsidianIntegrationPlugin: BarTaskerPlugin {
  var inboxPath: String { get }
  func chooseInboxFolder() throws -> String?
  func clearInboxFolder()
  func chooseLinkedFolder(forTaskId taskId: Int, taskContent: String) throws -> String?
  func createAndLinkFolder(forTaskId taskId: Int, taskContent: String) throws -> String?
  func clearLinkedFolder(forTaskId taskId: Int)
  func hasLinkedFolder(forTaskId taskId: Int) -> Bool
  func syncTask(
    _ task: CheckvistTask,
    listId: String,
    linkedFolderTaskId: Int?,
    openMode: ObsidianOpenMode,
    syncDate: Date
  ) throws -> URL
}

@MainActor
protocol GoogleCalendarIntegrationPlugin: BarTaskerPlugin {
  func makeCreateEventURL(task: CheckvistTask, listId: String, now: Date) -> URL?
  func createEvent(task: CheckvistTask, listId: String, now: Date) async throws
    -> GoogleCalendarEventCreationOutcome
  var requiresAuthentication: Bool { get }
  var isAuthenticated: Bool { get }
  var authenticationStatusDescription: String { get }
  func beginAuthentication() async throws
  func disconnectAuthentication()
}

struct GoogleCalendarEventCreationOutcome: Sendable {
  let urlToOpen: URL?
  let usedGoogleCalendarAPI: Bool

  init(urlToOpen: URL?, usedGoogleCalendarAPI: Bool) {
    self.urlToOpen = urlToOpen
    self.usedGoogleCalendarAPI = usedGoogleCalendarAPI
  }
}

@MainActor
extension GoogleCalendarIntegrationPlugin {
  func createEvent(task: CheckvistTask, listId: String, now: Date) async throws
    -> GoogleCalendarEventCreationOutcome
  {
    GoogleCalendarEventCreationOutcome(
      urlToOpen: makeCreateEventURL(task: task, listId: listId, now: now),
      usedGoogleCalendarAPI: false
    )
  }

  var requiresAuthentication: Bool { false }
  var isAuthenticated: Bool { true }
  var authenticationStatusDescription: String {
    "Uses your browser session to create prefilled events."
  }

  func beginAuthentication() async throws {}
  func disconnectAuthentication() {}
}

@MainActor
protocol MCPIntegrationPlugin: BarTaskerPlugin {
  func serverCommandURL() -> URL?
  func guideURL() -> URL?
  func makeClientConfigurationJSON(
    credentials: CheckvistCredentials,
    listId: String,
    redactSecrets: Bool
  ) -> String
}
