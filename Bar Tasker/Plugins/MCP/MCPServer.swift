import Foundation

// swiftlint:disable file_length
private enum BarTaskerMCPConstants {
  static let jsonrpcVersion = "2.0"
  static let defaultProtocolVersion = "2024-11-05"
  static let serverName = "bar-tasker-mcp"
  static let serverVersion = "0.2.0"
  static let userAgent = "BarTaskerMCP/0.2"

  static let parseError = -32700
  static let invalidRequest = -32600
  static let methodNotFound = -32601
  static let invalidParams = -32602
  static let internalError = -32603
}

private struct BarTaskerMCPJsonRpcError: Error {
  let code: Int
  let message: String
  let data: Any?

  init(code: Int, message: String, data: Any? = nil) {
    self.code = code
    self.message = message
    self.data = data
  }
}

private struct MCPCheckvistError: Error {
  let message: String
  let status: Int?
  let body: Any?

  init(message: String, status: Int? = nil, body: Any? = nil) {
    self.message = message
    self.status = status
    self.body = body
  }
}

private struct BarTaskerMCPConfig {
  let username: String
  let remoteKey: String
  let defaultListId: String
  let baseURL: URL

  static func fromEnvironment() -> BarTaskerMCPConfig {
    let env = ProcessInfo.processInfo.environment
    let rawBaseURL = env["CHECKVIST_BASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let baseURL = URL(string: rawBaseURL ?? "") ?? URL(string: CheckvistEndpoints.baseURL)!

    return BarTaskerMCPConfig(
      username: env["CHECKVIST_USERNAME"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
      remoteKey: env["CHECKVIST_REMOTE_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
      defaultListId: env["CHECKVIST_LIST_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        ?? "",
      baseURL: baseURL
    )
  }
}

private final class BarTaskerMCPCheckvistClient {
  private let config: BarTaskerMCPConfig
  private let session: URLSession
  private var token: String?

  init(config: BarTaskerMCPConfig) {
    self.config = config
    let sessionConfig = URLSessionConfiguration.ephemeral
    sessionConfig.httpShouldSetCookies = false
    sessionConfig.httpCookieStorage = nil
    sessionConfig.urlCache = nil
    self.session = URLSession(configuration: sessionConfig)
  }

  func resolveListId(explicitListId: String?) throws -> String {
    let listId = explicitListId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let resolved = listId.isEmpty ? config.defaultListId : listId
    guard !resolved.isEmpty else {
      throw MCPCheckvistError(
        message: "Missing list ID. Set CHECKVIST_LIST_ID or pass list_id.")
    }
    return resolved
  }

  func listLists() async throws -> [[String: Any]] {
    let response = try await request(method: "GET", path: "/checklists.json", requireAuth: true)
    guard let lists = response as? [[String: Any]] else {
      throw MCPCheckvistError(
        message: "Unexpected response while listing checklists.",
        body: response
      )
    }
    return lists.filter { ($0["archived"] as? Bool) != true }
  }

  func fetchTasks(
    listId: String,
    includeClosed: Bool,
    withNotes: Bool
  ) async throws -> [[String: Any]] {
    let response = try await request(
      method: "GET",
      path: "/checklists/\(listId)/tasks.json",
      query: ["with_notes": withNotes ? "true" : "false"],
      requireAuth: true
    )
    guard let tasks = response as? [[String: Any]] else {
      throw MCPCheckvistError(
        message: "Unexpected response while fetching tasks.",
        body: response
      )
    }
    let openOnly = includeClosed ? tasks : tasks.filter { Self.asInt($0["status"]) == 0 }
    return depthFirstTasks(openOnly)
  }

  func createTask(
    listId: String,
    content: String,
    parentID: Int?,
    position: Int?,
    due: String?
  ) async throws -> [String: Any] {
    var taskPayload: [String: Any] = ["content": content]
    if let parentID {
      taskPayload["parent_id"] = parentID
    }
    if let position {
      taskPayload["position"] = position
    }
    if let due {
      taskPayload["due"] = due
    }

    let response = try await request(
      method: "POST",
      path: "/checklists/\(listId)/tasks.json",
      query: ["parse": "true"],
      body: ["task": taskPayload],
      requireAuth: true
    )
    if let dict = response as? [String: Any] {
      return dict
    }
    return ["ok": true, "response": response]
  }

  func updateTask(
    listId: String,
    taskId: Int,
    content: String?,
    due: String?
  ) async throws -> [String: Any] {
    var taskPayload: [String: Any] = [:]
    if let content {
      taskPayload["content"] = content
    }
    if let due {
      taskPayload["due"] = due
    }
    guard !taskPayload.isEmpty else {
      throw MCPCheckvistError(message: "No updates provided. Pass content and/or due.")
    }

    let response = try await request(
      method: "PUT",
      path: "/checklists/\(listId)/tasks/\(taskId).json",
      body: ["task": taskPayload],
      requireAuth: true
    )
    if let dict = response as? [String: Any] {
      return dict
    }
    return ["ok": true, "response": response]
  }

  func taskAction(
    listId: String,
    taskId: Int,
    action: CheckvistTaskAction
  ) async throws -> [String: Any] {
    let response = try await request(
      method: "POST",
      path: "/checklists/\(listId)/tasks/\(taskId)/\(action.rawValue).json",
      requireAuth: true
    )
    if let dict = response as? [String: Any] {
      return dict
    }
    return ["ok": true, "response": response]
  }

  func deleteTask(listId: String, taskId: Int) async throws -> [String: Any] {
    let response = try await request(
      method: "DELETE",
      path: "/checklists/\(listId)/tasks/\(taskId).json",
      requireAuth: true
    )
    if let dict = response as? [String: Any] {
      return dict
    }
    return ["ok": true, "response": response]
  }

  private func request(
    method: String,
    path: String,
    query: [String: String]? = nil,
    body: [String: Any]? = nil,
    requireAuth: Bool,
    retryUnauthorized: Bool = true
  ) async throws -> Any {
    let url = try makeURL(path: path, query: query)
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = method
    urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
    urlRequest.setValue(BarTaskerMCPConstants.userAgent, forHTTPHeaderField: "User-Agent")

    if let body {
      urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
      urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    if requireAuth {
      urlRequest.setValue(try await ensureToken(), forHTTPHeaderField: "X-Client-Token")
    }

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: urlRequest)
    } catch {
      throw MCPCheckvistError(message: "Network error: \(error.localizedDescription)")
    }

    guard let http = response as? HTTPURLResponse else {
      throw MCPCheckvistError(message: "Invalid HTTP response.")
    }

    let parsedBody = parseResponseBody(data)

    if http.statusCode == 401 && requireAuth && retryUnauthorized {
      token = nil
      return try await request(
        method: method,
        path: path,
        query: query,
        body: body,
        requireAuth: requireAuth,
        retryUnauthorized: false
      )
    }

    // Retry once on transient server errors (502/503/504) after a short delay.
    if [502, 503, 504].contains(http.statusCode) && retryUnauthorized {
      try? await Task.sleep(nanoseconds: 500_000_000)
      return try await request(
        method: method,
        path: path,
        query: query,
        body: body,
        requireAuth: requireAuth,
        retryUnauthorized: false  // prevents infinite retry chain
      )
    }

    guard (200...299).contains(http.statusCode) else {
      throw MCPCheckvistError(
        message: "Checkvist API request failed with status \(http.statusCode).",
        status: http.statusCode,
        body: parsedBody
      )
    }

    return parsedBody
  }

  private func ensureToken() async throws -> String {
    if let token, !token.isEmpty {
      return token
    }
    try await login()
    guard let token, !token.isEmpty else {
      throw MCPCheckvistError(message: "Authentication failed.")
    }
    return token
  }

  private func login() async throws {
    guard !config.username.isEmpty, !config.remoteKey.isEmpty else {
      throw MCPCheckvistError(
        message: "Missing credentials. Set CHECKVIST_USERNAME and CHECKVIST_REMOTE_KEY.")
    }

    let response = try await request(
      method: "POST",
      path: "/auth/login.json",
      body: ["username": config.username, "remote_key": config.remoteKey],
      requireAuth: false
    )

    if let dict = response as? [String: Any], let token = dict["token"] as? String {
      self.token = token.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n\t\r"))
      return
    }

    if let raw = response as? String {
      let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n\t\r"))
      if !token.isEmpty {
        self.token = token
        return
      }
    }

    throw MCPCheckvistError(
      message: "Authentication response did not include a token.",
      body: response
    )
  }

  private func makeURL(path: String, query: [String: String]?) throws -> URL {
    var components = URLComponents(
      url: config.baseURL.appendingPathComponent(
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
      resolvingAgainstBaseURL: false
    )
    if let query, !query.isEmpty {
      components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
    }
    guard let url = components?.url else {
      throw MCPCheckvistError(message: "Invalid request URL for path \(path).")
    }
    return url
  }

  private func parseResponseBody(_ data: Data) -> Any {
    guard !data.isEmpty else { return [:] }
    if let json = try? JSONSerialization.jsonObject(with: data, options: []) {
      return json
    }
    return String(data: data, encoding: .utf8) ?? ""
  }

  private func depthFirstTasks(_ tasks: [[String: Any]]) -> [[String: Any]] {
    var childrenByParent: [Int: [[String: Any]]] = [:]
    for task in tasks {
      let parentID = Self.asInt(task["parent_id"]) ?? 0
      childrenByParent[parentID, default: []].append(task)
    }
    for key in childrenByParent.keys {
      childrenByParent[key]?.sort {
        (Self.asInt($0["position"]) ?? 0) < (Self.asInt($1["position"]) ?? 0)
      }
    }

    var ordered: [[String: Any]] = []
    func walk(parentID: Int) {
      for task in childrenByParent[parentID] ?? [] {
        ordered.append(task)
        if let childID = Self.asInt(task["id"]) {
          walk(parentID: childID)
        }
      }
    }

    walk(parentID: 0)
    return ordered
  }

  private static func asInt(_ raw: Any?) -> Int? {
    if let value = raw as? Int {
      return value
    }
    if let value = raw as? String {
      return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    if let value = raw as? NSNumber {
      return value.intValue
    }
    return nil
  }
}

private final class BarTaskerMCPMessageReader {
  private let input = FileHandle.standardInput
  private var buffer = Data()

  func readMessage() throws -> Any? {
    while true {
      if let decoded = try decodeMessageFromBuffer() {
        return decoded
      }

      guard let chunk = try input.read(upToCount: 4096), !chunk.isEmpty else {
        if buffer.isEmpty {
          return nil
        }
        throw BarTaskerMCPJsonRpcError(
          code: BarTaskerMCPConstants.parseError,
          message: "Unexpected EOF while reading message.")
      }
      buffer.append(chunk)
    }
  }

  private func decodeMessageFromBuffer() throws -> Any? {
    let separator = Data([13, 10, 13, 10])
    let fallbackSeparator = Data([10, 10])
    guard
      let headerRange = buffer.range(of: separator)
        ?? buffer.range(of: fallbackSeparator)
    else {
      return nil
    }

    let headerData = buffer.subdata(in: 0..<headerRange.lowerBound)
    guard let headerString = String(data: headerData, encoding: .utf8) else {
      throw BarTaskerMCPJsonRpcError(
        code: BarTaskerMCPConstants.parseError,
        message: "Malformed MCP headers.")
    }

    var contentLength: Int?
    for rawLine in headerString.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
      guard !line.isEmpty else { continue }
      let components = line.split(separator: ":", maxSplits: 1).map(String.init)
      guard components.count == 2 else {
        throw BarTaskerMCPJsonRpcError(
          code: BarTaskerMCPConstants.parseError,
          message: "Malformed MCP header line.")
      }
      if components[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        == "content-length"
      {
        contentLength = Int(components[1].trimmingCharacters(in: .whitespacesAndNewlines))
      }
    }

    guard let contentLength, contentLength >= 0 else {
      throw BarTaskerMCPJsonRpcError(
        code: BarTaskerMCPConstants.parseError,
        message: "Missing or invalid Content-Length header.")
    }

    let bodyStart = headerRange.upperBound
    let bodyEnd = bodyStart + contentLength
    guard buffer.count >= bodyEnd else {
      return nil
    }

    let bodyData = buffer.subdata(in: bodyStart..<bodyEnd)
    buffer.removeSubrange(0..<bodyEnd)

    do {
      return try JSONSerialization.jsonObject(with: bodyData, options: [])
    } catch {
      throw BarTaskerMCPJsonRpcError(
        code: BarTaskerMCPConstants.parseError,
        message: "Invalid JSON payload.")
    }
  }
}

private final class BarTaskerMCPMessageWriter {
  private let output = FileHandle.standardOutput

  func writeResult(id: Any, result: Any) {
    writePayload([
      "jsonrpc": BarTaskerMCPConstants.jsonrpcVersion,
      "id": id,
      "result": result,
    ])
  }

  func writeError(id: Any, code: Int, message: String, data: Any? = nil) {
    var errorObject: [String: Any] = [
      "code": code,
      "message": message,
    ]
    if let data {
      errorObject["data"] = data
    }
    writePayload([
      "jsonrpc": BarTaskerMCPConstants.jsonrpcVersion,
      "id": id,
      "error": errorObject,
    ])
  }

  private func writePayload(_ payload: [String: Any]) {
    guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
    let header = "Content-Length: \(body.count)\r\n\r\n"
    guard let headerData = header.data(using: .utf8) else { return }

    do {
      try output.write(contentsOf: headerData)
      try output.write(contentsOf: body)
    } catch {
      FileHandle.standardError.write(
        Data("MCP write error: \(error.localizedDescription)\n".utf8))
    }
  }
}

// swiftlint:disable type_body_length
final class MCPServer {
  private let reader = BarTaskerMCPMessageReader()
  private let writer = BarTaskerMCPMessageWriter()
  private let client = BarTaskerMCPCheckvistClient(config: .fromEnvironment())
  private var protocolVersion = BarTaskerMCPConstants.defaultProtocolVersion
  private var initialized = false

  static func isLaunchMode(arguments: [String]) -> Bool {
    arguments.contains("--mcp-server")
  }

  func run() async {
    while true {
      let message: Any
      do {
        guard let decoded = try reader.readMessage() else { return }
        message = decoded
      } catch let rpcError as BarTaskerMCPJsonRpcError {
        writer.writeError(
          id: NSNull(),
          code: rpcError.code,
          message: rpcError.message,
          data: rpcError.data
        )
        continue
      } catch {
        writer.writeError(
          id: NSNull(),
          code: BarTaskerMCPConstants.internalError,
          message: error.localizedDescription
        )
        continue
      }

      let messageObject = message as? [String: Any]
      let messageID = messageObject?["id"]

      do {
        try await handle(message: message)
      } catch let rpcError as BarTaskerMCPJsonRpcError {
        if let messageID {
          writer.writeError(
            id: messageID,
            code: rpcError.code,
            message: rpcError.message,
            data: rpcError.data
          )
        }
      } catch {
        if let messageID {
          writer.writeError(
            id: messageID,
            code: BarTaskerMCPConstants.internalError,
            message: error.localizedDescription
          )
        }
      }
    }
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private func handle(message: Any) async throws {
    guard let request = message as? [String: Any] else {
      throw BarTaskerMCPJsonRpcError(
        code: BarTaskerMCPConstants.invalidRequest,
        message: "Request must be an object.")
    }

    let jsonRPC = request["jsonrpc"] as? String
    guard jsonRPC == BarTaskerMCPConstants.jsonrpcVersion else {
      throw BarTaskerMCPJsonRpcError(
        code: BarTaskerMCPConstants.invalidRequest,
        message: "Unsupported JSON-RPC version.")
    }

    guard let method = request["method"] as? String, !method.isEmpty else {
      throw BarTaskerMCPJsonRpcError(
        code: BarTaskerMCPConstants.invalidRequest,
        message: "Missing method.")
    }

    let params = request["params"]
    let messageID = request["id"]
    let isNotification = messageID == nil

    if method == "notifications/initialized" {
      initialized = true
      return
    }

    if method == "initialize" {
      if let params = params as? [String: Any],
        let requested = params["protocolVersion"] as? String,
        !requested.isEmpty
      {
        protocolVersion = requested
      } else {
        protocolVersion = BarTaskerMCPConstants.defaultProtocolVersion
      }

      if let messageID {
        writer.writeResult(
          id: messageID,
          result: [
            "protocolVersion": protocolVersion,
            "serverInfo": [
              "name": BarTaskerMCPConstants.serverName,
              "version": BarTaskerMCPConstants.serverVersion,
            ],
            "capabilities": [
              "tools": [:]
            ],
          ]
        )
      }
      return
    }

    if method == "ping" {
      if let messageID, !isNotification {
        writer.writeResult(id: messageID, result: [:])
      }
      return
    }

    if method == "tools/list" {
      if let messageID, !isNotification {
        writer.writeResult(id: messageID, result: ["tools": Self.toolDefinitions])
      }
      return
    }

    if method == "tools/call" {
      guard let params = params as? [String: Any] else {
        throw BarTaskerMCPJsonRpcError(
          code: BarTaskerMCPConstants.invalidParams,
          message: "tools/call params must be an object.")
      }
      guard let name = params["name"] as? String, !name.isEmpty else {
        throw BarTaskerMCPJsonRpcError(
          code: BarTaskerMCPConstants.invalidParams,
          message: "Missing tool name.")
      }

      let argumentsRaw = params["arguments"]
      let arguments: [String: Any]
      if argumentsRaw == nil {
        arguments = [:]
      } else if let parsed = argumentsRaw as? [String: Any] {
        arguments = parsed
      } else {
        throw BarTaskerMCPJsonRpcError(
          code: BarTaskerMCPConstants.invalidParams,
          message: "Tool arguments must be an object.")
      }

      let result = await callTool(name: name, arguments: arguments)
      if let messageID, !isNotification {
        writer.writeResult(id: messageID, result: result)
      }
      return
    }

    if method == "resources/list" {
      if let messageID, !isNotification {
        writer.writeResult(id: messageID, result: ["resources": []])
      }
      return
    }

    if method == "prompts/list" {
      if let messageID, !isNotification {
        writer.writeResult(id: messageID, result: ["prompts": []])
      }
      return
    }

    if method == "logging/setLevel" {
      if let messageID, !isNotification {
        writer.writeResult(id: messageID, result: [:])
      }
      return
    }

    throw BarTaskerMCPJsonRpcError(
      code: BarTaskerMCPConstants.methodNotFound,
      message: "Method not found: \(method)")
  }

  // swiftlint:disable:next function_body_length
  private func callTool(name: String, arguments: [String: Any]) async -> [String: Any] {
    do {
      switch name {
      case "checkvist_list_lists":
        let payload = try await client.listLists()
        return Self.textContentResult(title: "Checklists", payload: payload)
      case "checkvist_fetch_tasks":
        let listID = try client.resolveListId(explicitListId: Self.asString(arguments["list_id"]))
        let includeClosed = try Self.asBool(arguments["include_closed"], defaultValue: false)
        let withNotes = try Self.asBool(arguments["with_notes"], defaultValue: true)
        let payload = try await client.fetchTasks(
          listId: listID,
          includeClosed: includeClosed,
          withNotes: withNotes
        )
        return Self.textContentResult(
          title: "Tasks (list \(listID), include_closed=\(includeClosed))",
          payload: payload
        )
      case "checkvist_quick_add_task":
        let content = try Self.requiredString(arguments, key: "content")
        let location = Self.asString(arguments["location"]) ?? "default"
        guard location == "default" || location == "specific" else {
          throw MCPCheckvistError(message: "location must be 'default' or 'specific'.")
        }

        let listID = try client.resolveListId(explicitListId: Self.asString(arguments["list_id"]))
        let parentTaskID: Int?
        if location == "specific" {
          parentTaskID = try Self.requiredInt(arguments, key: "parent_task_id")
        } else {
          parentTaskID = nil
        }

        let position = try Self.asOptionalInt(arguments["position"]) ?? 1
        let due = Self.asOptionalString(arguments["due"])
        let payload = try await client.createTask(
          listId: listID,
          content: content,
          parentID: parentTaskID,
          position: position,
          due: due
        )
        return Self.textContentResult(title: "Task created", payload: payload)
      case "checkvist_update_task":
        let listID = try client.resolveListId(explicitListId: Self.asString(arguments["list_id"]))
        let taskID = try Self.requiredInt(arguments, key: "task_id")
        let content = Self.asOptionalString(arguments["content"])
        let due = Self.asOptionalString(arguments["due"])
        let payload = try await client.updateTask(
          listId: listID,
          taskId: taskID,
          content: content,
          due: due
        )
        return Self.textContentResult(title: "Task updated", payload: payload)
      case "checkvist_complete_task":
        let listID = try client.resolveListId(explicitListId: Self.asString(arguments["list_id"]))
        let taskID = try Self.requiredInt(arguments, key: "task_id")
        let payload = try await client.taskAction(listId: listID, taskId: taskID, action: .close)
        return Self.textContentResult(title: "Task completed", payload: payload)
      case "checkvist_reopen_task":
        let listID = try client.resolveListId(explicitListId: Self.asString(arguments["list_id"]))
        let taskID = try Self.requiredInt(arguments, key: "task_id")
        let payload = try await client.taskAction(listId: listID, taskId: taskID, action: .reopen)
        return Self.textContentResult(title: "Task reopened", payload: payload)
      case "checkvist_invalidate_task":
        let listID = try client.resolveListId(explicitListId: Self.asString(arguments["list_id"]))
        let taskID = try Self.requiredInt(arguments, key: "task_id")
        let payload = try await client.taskAction(
          listId: listID, taskId: taskID, action: .invalidate)
        return Self.textContentResult(title: "Task invalidated", payload: payload)
      case "checkvist_delete_task":
        let listID = try client.resolveListId(explicitListId: Self.asString(arguments["list_id"]))
        let taskID = try Self.requiredInt(arguments, key: "task_id")
        let payload = try await client.deleteTask(listId: listID, taskId: taskID)
        return Self.textContentResult(title: "Task deleted", payload: payload)
      default:
        throw BarTaskerMCPJsonRpcError(
          code: BarTaskerMCPConstants.invalidParams,
          message: "Unknown tool: \(name)")
      }
    } catch let error as BarTaskerMCPJsonRpcError {
      var payload: [String: Any] = ["code": error.code]
      if let data = error.data {
        payload["data"] = data
      }
      return Self.errorContentResult(
        title: "Error: \(error.message)",
        payload: payload
      )
    } catch let error as MCPCheckvistError {
      var payload: [String: Any] = [:]
      if let status = error.status {
        payload["status"] = status
      }
      if let body = error.body {
        payload["body"] = body
      }
      return Self.errorContentResult(
        title: "Error: \(error.message)",
        payload: payload
      )
    } catch {
      return Self.errorContentResult(
        title: "Error: \(error.localizedDescription)",
        payload: [:]
      )
    }
  }

  private static var toolDefinitions: [[String: Any]] {
    [
      [
        "name": "checkvist_list_lists",
        "description": "List available Checkvist checklists (non-archived).",
        "inputSchema": [
          "type": "object",
          "properties": [:],
          "additionalProperties": false,
        ],
      ],
      [
        "name": "checkvist_fetch_tasks",
        "description": "Fetch tasks for a list. Defaults to open tasks only.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "list_id": ["type": "string"],
            "include_closed": ["type": "boolean", "default": false],
            "with_notes": ["type": "boolean", "default": true],
          ],
          "additionalProperties": false,
        ],
      ],
      [
        "name": "checkvist_quick_add_task",
        "description": "Quick-add a task to list root or to a specific parent task ID.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "list_id": ["type": "string"],
            "content": ["type": "string", "minLength": 1],
            "location": ["type": "string", "enum": ["default", "specific"], "default": "default"],
            "parent_task_id": ["type": "integer"],
            "position": ["type": "integer", "default": 1],
            "due": ["type": "string"],
          ],
          "required": ["content"],
          "additionalProperties": false,
        ],
      ],
      [
        "name": "checkvist_update_task",
        "description": "Update task content and/or due field.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "list_id": ["type": "string"],
            "task_id": ["type": "integer"],
            "content": ["type": "string"],
            "due": ["type": "string"],
          ],
          "required": ["task_id"],
          "additionalProperties": false,
        ],
      ],
      [
        "name": "checkvist_complete_task",
        "description": "Mark a task as complete (close).",
        "inputSchema": [
          "type": "object",
          "properties": [
            "list_id": ["type": "string"],
            "task_id": ["type": "integer"],
          ],
          "required": ["task_id"],
          "additionalProperties": false,
        ],
      ],
      [
        "name": "checkvist_reopen_task",
        "description": "Reopen a task.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "list_id": ["type": "string"],
            "task_id": ["type": "integer"],
          ],
          "required": ["task_id"],
          "additionalProperties": false,
        ],
      ],
      [
        "name": "checkvist_invalidate_task",
        "description": "Invalidate a task.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "list_id": ["type": "string"],
            "task_id": ["type": "integer"],
          ],
          "required": ["task_id"],
          "additionalProperties": false,
        ],
      ],
      [
        "name": "checkvist_delete_task",
        "description": "Delete a task.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "list_id": ["type": "string"],
            "task_id": ["type": "integer"],
          ],
          "required": ["task_id"],
          "additionalProperties": false,
        ],
      ],
    ]
  }

  private static func textContentResult(title: String, payload: Any) -> [String: Any] {
    [
      "content": [
        [
          "type": "text",
          "text": "\(title)\n\n\(prettyJSONString(payload))",
        ]
      ]
    ]
  }

  private static func errorContentResult(title: String, payload: Any) -> [String: Any] {
    [
      "content": [
        [
          "type": "text",
          "text": "\(title)\n\n\(prettyJSONString(payload))",
        ]
      ],
      "isError": true,
    ]
  }

  private static func prettyJSONString(_ payload: Any) -> String {
    if let data = try? JSONSerialization.data(
      withJSONObject: payload,
      options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
    ),
      let text = String(data: data, encoding: .utf8)
    {
      return text
    }
    return String(describing: payload)
  }

  private static func asString(_ value: Any?) -> String? {
    guard let value else { return nil }
    if let stringValue = value as? String {
      return stringValue
    }
    if let intValue = value as? Int {
      return String(intValue)
    }
    if let doubleValue = value as? Double {
      return String(doubleValue)
    }
    return nil
  }

  private static func asOptionalString(_ value: Any?) -> String? {
    asString(value)
  }

  private static func asBool(_ value: Any?, defaultValue: Bool) throws -> Bool {
    guard let value else { return defaultValue }
    if let boolValue = value as? Bool {
      return boolValue
    }
    if let intValue = value as? Int {
      return intValue != 0
    }
    if let stringValue = value as? String {
      switch stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "true", "1", "yes", "y":
        return true
      case "false", "0", "no", "n":
        return false
      default:
        break
      }
    }
    throw MCPCheckvistError(message: "Expected boolean value.")
  }

  private static func asOptionalInt(_ value: Any?) throws -> Int? {
    guard let value else { return nil }
    if value is Bool {
      throw MCPCheckvistError(message: "Boolean value is not a valid integer.")
    }
    if let intValue = value as? Int {
      return intValue
    }
    if let stringValue = value as? String {
      let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty {
        return nil
      }
      guard let intValue = Int(trimmed) else {
        throw MCPCheckvistError(message: "Invalid integer value: \(stringValue)")
      }
      return intValue
    }
    if let number = value as? NSNumber {
      return number.intValue
    }
    throw MCPCheckvistError(message: "Expected integer value.")
  }

  private static let maxStringInputLength = 10_000

  private static func requiredString(_ arguments: [String: Any], key: String) throws -> String {
    guard let value = asString(arguments[key])?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else {
      throw MCPCheckvistError(message: "Missing required argument: \(key)")
    }
    guard value.count <= maxStringInputLength else {
      throw MCPCheckvistError(
        message: "Argument '\(key)' exceeds maximum length of \(maxStringInputLength) characters.")
    }
    return value
  }

  private static func requiredInt(_ arguments: [String: Any], key: String) throws -> Int {
    guard let value = try asOptionalInt(arguments[key]) else {
      throw MCPCheckvistError(message: "Missing required argument: \(key)")
    }
    return value
  }
}
// swiftlint:enable type_body_length
// swiftlint:enable file_length
