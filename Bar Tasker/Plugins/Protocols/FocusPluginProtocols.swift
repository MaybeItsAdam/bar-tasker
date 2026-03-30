import Foundation

protocol FocusPlugin {
  var pluginIdentifier: String { get }
  var displayName: String { get }
}

struct CheckvistCredentials {
  let username: String
  let remoteKey: String

  var normalizedUsername: String {
    username.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var normalizedRemoteKey: String {
    remoteKey.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

enum CheckvistTaskAction: String {
  case close
  case reopen
  case invalidate
}

@MainActor
protocol CheckvistSyncPlugin: FocusPlugin {
  func clearAuthentication()
  func login(credentials: CheckvistCredentials) async throws -> Bool
  func fetchOpenTasks(listId: String, credentials: CheckvistCredentials) async throws
    -> [CheckvistTask]
  func fetchLists(credentials: CheckvistCredentials) async throws -> [CheckvistList]
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
protocol ObsidianIntegrationPlugin: FocusPlugin {
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
protocol GoogleCalendarIntegrationPlugin: FocusPlugin {
  func makeCreateEventURL(task: CheckvistTask, listId: String, now: Date) -> URL?
}

@MainActor
protocol MCPIntegrationPlugin: FocusPlugin {
  func serverCommandURL() -> URL?
  func guideURL() -> URL?
  func makeClientConfigurationJSON(
    credentials: CheckvistCredentials,
    listId: String,
    redactSecrets: Bool
  ) -> String
}
