import Foundation

// Plugin protocols and stub models needed by `BarTaskerAppLogic` (TaskRepository,
// OfflineTaskSyncPlugin, LocalTaskStore). Must stay in sync with:
//   • Bar Tasker/Plugins/Protocols/PluginProtocols.swift
//   • plugin-tests-support/PluginModelStubs.swift
//
// SPM forbids the same file appearing in two targets, so we keep an AppLogic-local
// copy here. The Xcode app target compiles the originals; this file is excluded
// from the Xcode target via the project.pbxproj membership.

protocol Plugin {
  var pluginIdentifier: String { get }
  var displayName: String { get }
  var pluginDescription: String { get }
}

extension Plugin {
  var pluginDescription: String { "" }
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

struct CheckvistNote: Codable, Equatable, Identifiable {
  let id: Int?
  let content: String
}

struct CheckvistTask: Codable, Equatable, Identifiable {
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
    case id
    case content
    case status
    case due
    case position
    case parentId = "parent_id"
    case level
    case notes
    case updatedAt = "updated_at"
  }

  init(
    id: Int,
    content: String,
    status: Int,
    due: String?,
    position: Int? = nil,
    parentId: Int? = nil,
    level: Int? = nil,
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
}

struct CheckvistList: Codable, Equatable, Identifiable {
  let id: Int
  let name: String
  let archived: Bool?
  let readOnly: Bool?

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case archived
    case readOnly = "read_only"
  }
}

struct CheckvistTaskCachePayload: Codable, Equatable {
  let listId: String
  let fetchedAt: Date
  let tasks: [CheckvistTask]
}

enum CheckvistSessionError: Error {
  case authenticationUnavailable
  case requestFailed
}

@MainActor
protocol CheckvistSyncPlugin: Plugin {
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
  func startupRemoteKey(useKeychainStorageAtInit: Bool) -> String { "" }
  func persistRemoteKey(_ value: String, useKeychainStorage: Bool) {}
  func persistRemoteKeyForDebugStorageMode(_ value: String) {}
  func loadRemoteKeyFromKeychain() -> String? { nil }
  func createList(name: String, credentials: CheckvistCredentials) async throws -> CheckvistList? {
    nil
  }
}
