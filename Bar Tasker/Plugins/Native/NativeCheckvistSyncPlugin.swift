import Foundation

@MainActor
final class NativeCheckvistSyncPlugin: CheckvistSyncPlugin {
  let pluginIdentifier = "native.checkvist.sync"
  let displayName = "Native Checkvist Sync"

  private static let userAgent = "BarTasker/1.0 (Macintosh; Mac OS X)"
  private let session: CheckvistSession
  private let taskRepository: CheckvistTaskRepository

  init(session: CheckvistSession, taskRepository: CheckvistTaskRepository) {
    self.session = session
    self.taskRepository = taskRepository
  }

  convenience init() {
    self.init(session: CheckvistSession(), taskRepository: CheckvistTaskRepository())
  }

  func clearAuthentication() {
    session.clearToken()
  }

  func login(credentials: CheckvistCredentials) async throws -> Bool {
    guard
      !credentials.normalizedUsername.isEmpty,
      !credentials.normalizedRemoteKey.isEmpty
    else {
      return false
    }
    return try await session.login(
      username: credentials.normalizedUsername,
      remoteKey: credentials.normalizedRemoteKey
    )
  }

  func fetchOpenTasks(listId: String, credentials: CheckvistCredentials) async throws
    -> [CheckvistTask]
  {
    try await taskRepository.fetchTasks(
      listId: listId,
      performAuthenticatedRequest: { [weak self] buildRequest in
        guard let self else {
          throw CheckvistSessionError.authenticationUnavailable
        }
        return try await self.performAuthenticatedRequest(
          credentials: credentials,
          buildRequest
        )
      }
    )
  }

  func fetchLists(credentials: CheckvistCredentials) async throws -> [CheckvistList] {
    guard let url = URL(string: "https://checkvist.com/checklists.json") else {
      return []
    }

    let (data, response) = try await performAuthenticatedRequest(credentials: credentials) {
      validToken in
      var request = URLRequest(url: url)
      request.httpMethod = "GET"
      request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
      return request
    }

    guard (200...299).contains(response.statusCode) else {
      return []
    }

    let lists = try JSONDecoder().decode([CheckvistList].self, from: data)
    return lists.filter { !($0.archived ?? false) }
  }

  func performTaskAction(
    listId: String,
    taskId: Int,
    action: CheckvistTaskAction,
    credentials: CheckvistCredentials
  ) async throws -> Bool {
    guard
      let url = URL(
        string: "https://checkvist.com/checklists/\(listId)/tasks/\(taskId)/\(action.rawValue).json"
      )
    else {
      return false
    }

    let (_, response) = try await performAuthenticatedRequest(credentials: credentials) {
      validToken in
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
      request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
      return request
    }

    return (200...299).contains(response.statusCode)
  }

  func updateTask(
    listId: String,
    taskId: Int,
    content: String?,
    due: String?,
    credentials: CheckvistCredentials
  ) async throws -> Bool {
    var taskDict: [String: Any] = [:]
    if let content {
      taskDict["content"] = content
    }
    if let due {
      taskDict["due"] = due
    }
    guard !taskDict.isEmpty else { return true }
    return try await putTask(
      listId: listId,
      taskId: taskId,
      bodyTaskPayload: taskDict,
      credentials: credentials
    )
  }

  func createTask(
    listId: String,
    content: String,
    parentId: Int?,
    position: Int?,
    credentials: CheckvistCredentials
  ) async throws -> CheckvistTask? {
    guard
      let url = URL(string: "https://checkvist.com/checklists/\(listId)/tasks.json?parse=true")
    else {
      return nil
    }

    var taskPayload: [String: Any] = ["content": content]
    if let parentId {
      taskPayload["parent_id"] = parentId
    }
    if let position {
      taskPayload["position"] = position
    }

    let (data, response) = try await performAuthenticatedRequest(credentials: credentials) {
      validToken in
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
      request.httpBody = try? JSONSerialization.data(withJSONObject: ["task": taskPayload])
      return request
    }

    guard (200...299).contains(response.statusCode) else {
      return nil
    }

    return try? JSONDecoder().decode(CheckvistTask.self, from: data)
  }

  func deleteTask(listId: String, taskId: Int, credentials: CheckvistCredentials) async throws
    -> Bool
  {
    guard let url = URL(string: "https://checkvist.com/checklists/\(listId)/tasks/\(taskId).json")
    else {
      return false
    }

    let (_, response) = try await performAuthenticatedRequest(credentials: credentials) {
      validToken in
      var request = URLRequest(url: url)
      request.httpMethod = "DELETE"
      request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
      request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
      return request
    }

    return (200...299).contains(response.statusCode)
  }

  func moveTask(
    listId: String,
    taskId: Int,
    position: Int,
    credentials: CheckvistCredentials
  ) async throws -> Bool {
    try await putTask(
      listId: listId,
      taskId: taskId,
      bodyTaskPayload: ["position": position],
      credentials: credentials
    )
  }

  func reparentTask(
    listId: String,
    taskId: Int,
    parentId: Int?,
    credentials: CheckvistCredentials
  ) async throws -> Bool {
    let payload: [String: Any] = ["parent_id": parentId ?? NSNull()]
    return try await putTask(
      listId: listId,
      taskId: taskId,
      bodyTaskPayload: payload,
      credentials: credentials
    )
  }

  func persistTaskCache(listId: String, tasks: [CheckvistTask]) {
    taskRepository.persistTaskCache(
      CheckvistTaskCachePayload(listId: listId, fetchedAt: Date(), tasks: tasks)
    )
  }

  func loadTaskCache(for listId: String) -> CheckvistTaskCachePayload? {
    taskRepository.loadTaskCache(for: listId)
  }

  func isTaskCacheOutdated(_ payload: CheckvistTaskCachePayload) -> Bool {
    taskRepository.isCacheOutdated(payload)
  }

  private func putTask(
    listId: String,
    taskId: Int,
    bodyTaskPayload: [String: Any],
    credentials: CheckvistCredentials
  ) async throws -> Bool {
    guard let url = URL(string: "https://checkvist.com/checklists/\(listId)/tasks/\(taskId).json")
    else {
      return false
    }

    let (_, response) = try await performAuthenticatedRequest(credentials: credentials) {
      validToken in
      var request = URLRequest(url: url)
      request.httpMethod = "PUT"
      request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
      request.httpBody = try? JSONSerialization.data(withJSONObject: ["task": bodyTaskPayload])
      return request
    }

    return (200...299).contains(response.statusCode)
  }

  private func performAuthenticatedRequest(
    credentials: CheckvistCredentials,
    _ buildRequest: (String) throws -> URLRequest
  ) async throws -> (Data, HTTPURLResponse) {
    try await session.performAuthenticatedRequest(
      username: credentials.normalizedUsername,
      remoteKey: credentials.normalizedRemoteKey,
      buildRequest
    )
  }
}
