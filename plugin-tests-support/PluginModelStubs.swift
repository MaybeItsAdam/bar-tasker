import Foundation

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

  var dueDate: Date? {
    guard let dueRaw = due?.trimmingCharacters(in: .whitespacesAndNewlines), !dueRaw.isEmpty else {
      return nil
    }

    for parser in iso8601Parsers() {
      if let parsed = parser.date(from: dueRaw) {
        return parsed
      }
    }

    for formatter in dueDateFormatters() {
      if let parsed = formatter.date(from: dueRaw) {
        return parsed
      }
    }

    if dueRaw.count >= 10 {
      let dayPrefix = String(dueRaw.prefix(10))
      for formatter in dueDateFormatters() {
        if let parsed = formatter.date(from: dayPrefix) {
          return parsed
        }
      }
    }

    return nil
  }

  private func dueDateFormatters() -> [DateFormatter] {
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
  }

  private func iso8601Parsers() -> [ISO8601DateFormatter] {
    let internet = ISO8601DateFormatter()
    internet.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate]

    let internetFractional = ISO8601DateFormatter()
    internetFractional.formatOptions = [
      .withInternetDateTime, .withFractionalSeconds, .withDashSeparatorInDate,
    ]

    let fullDate = ISO8601DateFormatter()
    fullDate.formatOptions = [.withFullDate, .withDashSeparatorInDate]

    return [internet, internetFractional, fullDate]
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

enum ObsidianOpenMode: Equatable {
  case standard
  case newWindow
}

@MainActor
final class ObsidianSyncService {
  var inboxPath = ""
  var chooseInboxFolderResult: String?
  var chooseLinkedFolderResult: String?
  var createAndLinkFolderResult: String?
  var syncResultURL = URL(fileURLWithPath: "/tmp/obsidian-task.md")
  var syncedNoteTaskIDs: Set<Int> = []
  private var linkedFolderByTask: [Int: String] = [:]

  private(set) var lastSyncCall:
    (
      task: CheckvistTask,
      listId: String,
      linkedFolderTaskId: Int?,
      openMode: ObsidianOpenMode,
      syncDate: Date
    )?

  func chooseInboxFolder() throws -> String? {
    chooseInboxFolderResult
  }

  func clearInboxFolder() {
    inboxPath = ""
  }

  func chooseLinkedFolder(forTaskId taskId: Int, taskContent: String) throws -> String? {
    if let chosen = chooseLinkedFolderResult {
      linkedFolderByTask[taskId] = chosen
    }
    return chooseLinkedFolderResult
  }

  func createAndLinkFolder(forTaskId taskId: Int, taskContent: String) throws -> String? {
    if let created = createAndLinkFolderResult {
      linkedFolderByTask[taskId] = created
    }
    return createAndLinkFolderResult
  }

  func clearLinkedFolder(forTaskId taskId: Int) {
    linkedFolderByTask.removeValue(forKey: taskId)
  }

  func hasLinkedFolder(forTaskId taskId: Int) -> Bool {
    linkedFolderByTask[taskId] != nil
  }

  func hasSyncedNote(task: CheckvistTask, linkedFolderTaskId: Int?) -> Bool {
    syncedNoteTaskIDs.contains(task.id)
  }

  func syncTask(
    _ task: CheckvistTask,
    listId: String,
    linkedFolderTaskId: Int?,
    openMode: ObsidianOpenMode,
    syncDate: Date
  ) throws -> URL {
    lastSyncCall = (task, listId, linkedFolderTaskId, openMode, syncDate)
    return syncResultURL
  }
}

enum CheckvistSessionError: Error {
  case authenticationUnavailable
  case requestFailed
}

@MainActor
final class CheckvistSession {
  var issuedToken = "test-token"
  var nextResponseData = Data()
  var nextResponseStatusCode = 200
  var loginResult = true
  var loginError: Error?
  var requestError: Error?

  private(set) var didClearToken = false
  private(set) var loginCallCount = 0
  private(set) var lastLoginUsername: String?
  private(set) var lastLoginRemoteKey: String?
  private(set) var performRequestCallCount = 0
  private(set) var lastRequestUsername: String?
  private(set) var lastRequestRemoteKey: String?
  private(set) var recordedRequests: [URLRequest] = []

  func clearToken() {
    didClearToken = true
  }

  func login(username: String, remoteKey: String) async throws -> Bool {
    loginCallCount += 1
    lastLoginUsername = username
    lastLoginRemoteKey = remoteKey
    if let loginError {
      throw loginError
    }
    return loginResult
  }

  func performAuthenticatedRequest(
    username: String,
    remoteKey: String,
    _ buildRequest: (String) throws -> URLRequest
  ) async throws -> (Data, HTTPURLResponse) {
    performRequestCallCount += 1
    lastRequestUsername = username
    lastRequestRemoteKey = remoteKey

    if let requestError {
      throw requestError
    }

    let request = try buildRequest(issuedToken)
    recordedRequests.append(request)
    let response = HTTPURLResponse(
      url: request.url ?? URL(string: "https://example.com")!,
      statusCode: nextResponseStatusCode,
      httpVersion: nil,
      headerFields: nil
    )!
    return (nextResponseData, response)
  }
}

@MainActor
final class CheckvistTaskRepository {
  var nextFetchedTasks: [CheckvistTask] = []
  var fetchError: Error?
  var isCacheOutdatedResult = false

  private(set) var fetchTasksCallCount = 0
  private(set) var persistedPayload: CheckvistTaskCachePayload?
  var cachedPayloadByListId: [String: CheckvistTaskCachePayload] = [:]

  func fetchTasks(
    listId: String,
    performAuthenticatedRequest:
      @escaping ((String) throws -> URLRequest) async throws -> (Data, HTTPURLResponse)
  ) async throws -> [CheckvistTask] {
    fetchTasksCallCount += 1
    if let fetchError {
      throw fetchError
    }
    return nextFetchedTasks
  }

  func persistTaskCache(_ payload: CheckvistTaskCachePayload) {
    persistedPayload = payload
    cachedPayloadByListId[payload.listId] = payload
  }

  func loadTaskCache(for listId: String) -> CheckvistTaskCachePayload? {
    cachedPayloadByListId[listId]
  }

  func isCacheOutdated(_ payload: CheckvistTaskCachePayload) -> Bool {
    isCacheOutdatedResult
  }
}

final class GoogleOAuthLoopbackReceiver {
  func start() async throws -> URL {
    URL(string: "http://127.0.0.1:8787/google-oauth-callback")!
  }

  func waitForCallback(timeout: TimeInterval) async throws -> URL {
    URL(string: "http://127.0.0.1:8787/google-oauth-callback?code=test&state=test")!
  }

  func stop() {}
}
