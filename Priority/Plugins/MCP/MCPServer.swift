import Foundation

// swiftlint:disable file_length
private enum PriorityMCPConstants {
  static let jsonrpcVersion = "2.0"
  static let defaultProtocolVersion = "2024-11-05"
  static let serverName = "priority-mcp"
  static let serverVersion = "0.3.0"
  static let userAgent = "PriorityMCP/0.3"

  static let parseError = -32700
  static let invalidRequest = -32600
  static let methodNotFound = -32601
  static let invalidParams = -32602
  static let internalError = -32603
}

private struct PriorityMCPJsonRpcError: Error {
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

private struct PriorityMCPConfig {
  let username: String
  let remoteKey: String
  let defaultListId: String
  let baseURL: URL

  static func fromEnvironment() -> PriorityMCPConfig {
    let env = ProcessInfo.processInfo.environment
    let rawBaseURL = env["CHECKVIST_BASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let baseURL = URL(string: rawBaseURL ?? "") ?? URL(string: CheckvistEndpoints.baseURL)!

    return PriorityMCPConfig(
      username: env["CHECKVIST_USERNAME"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
      remoteKey: env["CHECKVIST_REMOTE_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
      defaultListId: env["CHECKVIST_LIST_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        ?? "",
      baseURL: baseURL
    )
  }
}

private final class PriorityMCPCheckvistClient {
  private let config: PriorityMCPConfig
  private let session: URLSession
  private var token: String?

  init(config: PriorityMCPConfig) {
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

  /// Reorder within the current parent. Checkvist treats `position` as 1-based
  /// among siblings, matching `NativeCheckvistSyncPlugin.moveTask`.
  func moveTask(listId: String, taskId: Int, position: Int) async throws -> [String: Any] {
    let response = try await request(
      method: "PUT",
      path: "/checklists/\(listId)/tasks/\(taskId).json",
      body: ["task": ["position": position]],
      requireAuth: true
    )
    if let dict = response as? [String: Any] {
      return dict
    }
    return ["ok": true, "response": response]
  }

  /// `parentId == nil` promotes the task to the list root. `NSNull` rather than
  /// omitting the key, because omitting it means "leave the parent alone" —
  /// same distinction `NativeCheckvistSyncPlugin.reparentTask` relies on.
  func reparentTask(listId: String, taskId: Int, parentId: Int?) async throws -> [String: Any] {
    let payload: [String: Any] = ["parent_id": parentId ?? NSNull()]
    let response = try await request(
      method: "PUT",
      path: "/checklists/\(listId)/tasks/\(taskId).json",
      body: ["task": payload],
      requireAuth: true
    )
    if let dict = response as? [String: Any] {
      return dict
    }
    return ["ok": true, "response": response]
  }

  func createList(name: String) async throws -> [String: Any] {
    let response = try await request(
      method: "POST",
      path: "/checklists.json",
      body: ["checklist": ["name": name]],
      requireAuth: true
    )
    if let dict = response as? [String: Any] {
      return dict
    }
    return ["ok": true, "response": response]
  }

  /// Notes are Checkvist "comments" — a separate resource from the task, which
  /// is why `task_update` can't write them and this exists instead.
  func addNote(listId: String, taskId: Int, comment: String) async throws -> [String: Any] {
    let response = try await request(
      method: "POST",
      path: "/checklists/\(listId)/tasks/\(taskId)/comments.json",
      body: ["comment": ["comment": comment]],
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
    urlRequest.setValue(PriorityMCPConstants.userAgent, forHTTPHeaderField: "User-Agent")

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

/// Reads the state Priority keeps on this machine rather than in Checkvist.
///
/// Priorities, recurrence rules, start dates, focus history and dailies have no
/// Checkvist representation at all, so an assistant limited to the API can't see
/// any of them — it can list your tasks but not tell you what you did today.
///
/// No IPC is involved: `--mcp-server` is the same binary and bundle identifier
/// as the app, so `UserDefaults.standard` resolves to the same preferences
/// domain and the day-log files sit at the same Application Support path.
///
/// Deliberately **read-only**. The running app holds this state in memory and
/// writes it back on its own schedule, so a write from this process would be
/// silently overwritten the next time the app touched the same key. Mutating
/// local state needs to go through the app, which is a different design problem
/// than this server solves.
private struct PriorityMCPLocalState {
  private let defaults: UserDefaults
  private let storeDirectory: URL

  /// `PRIORITY_MCP_STORE_DIR` / `PRIORITY_MCP_PREFS_PATH` redirect both
  /// sources at fixture data. That exists for `scripts/mcp_parity_check.py`,
  /// which drives this server and the Python one over the same fixture and
  /// diffs them — the only way to catch the two aggregators drifting apart,
  /// since neither implementation can import the other.
  init() {
    let env = ProcessInfo.processInfo.environment

    if let prefsPath = env["PRIORITY_MCP_PREFS_PATH"], !prefsPath.isEmpty,
      let contents = NSDictionary(contentsOfFile: prefsPath) as? [String: Any]
    {
      let fixtureDefaults = UserDefaults(suiteName: "priority-mcp-fixture") ?? .standard
      fixtureDefaults.removePersistentDomain(forName: "priority-mcp-fixture")
      for (key, value) in contents {
        fixtureDefaults.set(value, forKey: key)
      }
      self.defaults = fixtureDefaults
    } else {
      self.defaults = .standard
    }

    if let storeDir = env["PRIORITY_MCP_STORE_DIR"], !storeDir.isEmpty {
      self.storeDirectory = URL(fileURLWithPath: storeDir, isDirectory: true)
    } else {
      self.storeDirectory = DailyLogService.defaultStoreDirectoryURL()
    }
  }

  var boundary: DayBoundary {
    guard defaults.object(forKey: "dailyLogRolloverHour") != nil else {
      return DayBoundary()
    }
    return DayBoundary(rolloverHour: min(23, max(0, defaults.integer(forKey: "dailyLogRolloverHour"))))
  }

  private var events: [DayLogEvent] {
    DayLogFileStore(directoryURL: storeDirectory).loadAll()
  }

  private var dailies: DailyCollection {
    DailyDefinitionsStore(directoryURL: storeDirectory).load()
  }

  /// One entry per logical day, newest first.
  func daySummaries(endingOn date: Date, count: Int) -> [[String: Any]] {
    let boundary = self.boundary
    let events = self.events
    let dailies = self.dailies
    return boundary.days(endingOn: date, count: count).reversed().map { day in
      let summary = DayLogAggregator.summary(events: events, boundary: boundary, on: day)
      let dueDailies = dailies.due(on: boundary.logicalDay(for: day))
      let tickedIds = summary.completedDailyIds
      return [
        "day": summary.key,
        "completed_count": summary.completedCount,
        "planned_count": summary.plannedCount,
        "unfinished_count": summary.unfinishedCount,
        "focus_seconds": summary.focusSeconds,
        "completed": summary.completed.map {
          ["task_id": $0.taskId, "title": $0.title, "at": Self.iso8601.string(from: $0.at)]
        },
        "unfinished_task_ids": summary.unfinishedTaskIds,
        "deferred_task_ids": summary.deferredTaskIds,
        "invalidated_task_ids": summary.invalidatedTaskIds,
        "dailies": dueDailies.map {
          [
            "id": $0.id,
            "title": $0.title,
            "done": tickedIds.contains($0.id),
          ]
        },
      ]
    }
  }

  /// Every active daily plus whether it's ticked on the requested day.
  func dailiesSnapshot(on date: Date) -> [String: Any] {
    let boundary = self.boundary
    let dailies = self.dailies
    let day = boundary.logicalDay(for: date)
    let ticked = DayLogAggregator.completedDailyIds(
      events: events, boundary: boundary, on: date)
    let dueToday = Set(dailies.due(on: day).map(\.id))
    return [
      "day": boundary.dayKey(for: date),
      "dailies": dailies.active.map {
        [
          "id": $0.id,
          "title": $0.title,
          "schedule": $0.scheduleLabel,
          "due_today": dueToday.contains($0.id),
          "done": ticked.contains($0.id),
        ]
      },
    ]
  }

  /// Priority-only per-task fields, keyed by task id, for one list.
  func taskMetadata(listId: String) -> [String: Any] {
    let scopedQueues = ListScopedPriorityStore(
      defaultsKey: "priorityTaskIdsByParentIdByListId", defaults: defaults
    ).load(for: listId)
    let absoluteQueue = ListScopedTaskIDStore(
      defaultsKey: "absolutePriorityTaskIdsByListId", defaults: defaults
    ).load(for: listId)

    // Rank is the position in the queue, not a stored number — index 0 is rank 1
    // within that parent scope, exactly as `TaskRepository` reads it.
    var scopedRanks: [String: [String: Int]] = [:]
    for (parentId, queue) in scopedQueues {
      var ranks: [String: Int] = [:]
      for (index, taskId) in queue.enumerated() {
        ranks[String(taskId)] = index + 1
      }
      scopedRanks[String(parentId)] = ranks
    }
    var absoluteRanks: [String: Int] = [:]
    for (index, taskId) in absoluteQueue.enumerated() {
      absoluteRanks[String(taskId)] = index + 1
    }

    return [
      "list_id": listId,
      "scoped_priority_rank_by_parent_id": scopedRanks,
      "absolute_priority_rank": absoluteRanks,
      "recurrence_rule_by_task_id": defaults.dictionary(forKey: "recurrenceRulesByTaskId")
        as? [String: String] ?? [:],
      "start_date_by_task_id": defaults.dictionary(forKey: "taskStartDatesByTaskId")
        as? [String: String] ?? [:],
    ]
  }

  // MARK: - Writes
  //
  // Only dailies are writable, and only through the locked read/modify/write in
  // the stores. Priorities, recurrence and start dates stay read-only: they live
  // in `UserDefaults`, which the running app holds in memory and rewrites on its
  // own schedule, so there is no equivalent of the file lock to make an external
  // write survive.

  func addDaily(title: String, activeWeekdays: Set<Int>?) throws -> [String: Any] {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw MCPCheckvistError(message: "title must not be empty.")
    }
    let daily = Daily(
      title: trimmed,
      activeWeekdays: activeWeekdays.map { $0.isEmpty ? Daily.allWeekdays : $0 }
        ?? Daily.allWeekdays
    )
    let saved = try DailyDefinitionsStore(directoryURL: storeDirectory).mutate { $0.add(daily) }
    guard let stored = saved.daily(withId: daily.id) else {
      throw MCPCheckvistError(message: "The daily was not saved.")
    }
    return Self.dailyPayload(stored)
  }

  func updateDaily(
    id: String,
    title: String?,
    activeWeekdays: Set<Int>?,
    archived: Bool?
  ) throws -> [String: Any] {
    let store = DailyDefinitionsStore(directoryURL: storeDirectory)
    guard store.load().daily(withId: id) != nil else {
      throw MCPCheckvistError(message: "No daily with id \(id).")
    }
    let saved = try store.mutate { collection in
      collection.update(id: id) { daily in
        if let title {
          let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
          if !trimmed.isEmpty { daily.title = trimmed }
        }
        if let activeWeekdays, !activeWeekdays.isEmpty {
          daily.activeWeekdays = activeWeekdays
        }
        if let archived {
          // Archive rather than delete, so history referencing this id still
          // renders with a title instead of as an orphan.
          daily.archivedAt = archived ? (daily.archivedAt ?? Date()) : nil
        }
      }
    }
    guard let stored = saved.daily(withId: id) else {
      throw MCPCheckvistError(message: "No daily with id \(id).")
    }
    return Self.dailyPayload(stored)
  }

  /// Ticks or un-ticks a daily by appending to the log, exactly as
  /// `DailyLogService.setDaily` does — the tick is a fact about a day, not a
  /// field on the daily.
  func setDaily(id: String, done: Bool, now: Date = Date()) throws -> [String: Any] {
    let store = DailyDefinitionsStore(directoryURL: storeDirectory)
    guard let daily = store.load().daily(withId: id) else {
      throw MCPCheckvistError(message: "No daily with id \(id).")
    }

    let boundary = self.boundary
    let logStore = DayLogFileStore(directoryURL: storeDirectory)
    let alreadyDone = DayLogAggregator.completedDailyIds(
      events: logStore.loadAll(), boundary: boundary, on: now
    ).contains(id)

    guard alreadyDone != done else {
      return [
        "id": id, "title": daily.title, "done": alreadyDone,
        "day": boundary.dayKey(for: now), "changed": false,
      ]
    }

    try logStore.append(
      done
        ? .dailyCompleted(dailyId: id, title: daily.title, at: now)
        : .dailyUncompleted(dailyId: id, title: daily.title, at: now)
    )
    return [
      "id": id, "title": daily.title, "done": done,
      "day": boundary.dayKey(for: now), "changed": true,
    ]
  }

  private static func dailyPayload(_ daily: Daily) -> [String: Any] {
    [
      "id": daily.id,
      "title": daily.title,
      "schedule": daily.scheduleLabel,
      "active_weekdays": daily.activeWeekdays.sorted(),
      "archived": daily.isArchived,
    ]
  }

  private static let iso8601: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()
}

private final class PriorityMCPMessageReader {
  private let input = FileHandle.standardInput
  private var decoder = MCPFrameDecoder()

  /// Framing the peer last used, so replies go back in the same shape.
  var framing: MCPMessageFraming { decoder.detectedFraming }

  func readMessage() throws -> Any? {
    while true {
      if let body = try decoder.nextMessageBody() {
        guard let decoded = try? JSONSerialization.jsonObject(with: body, options: []) else {
          throw PriorityMCPJsonRpcError(
            code: PriorityMCPConstants.parseError,
            message: "Invalid JSON payload.")
        }
        return decoded
      }

      // EOF ends the session. Reporting a leftover partial message here instead
      // would loop forever: the buffer never drains, so the caller writes the
      // same error and reads again with the same result.
      guard let chunk = try input.read(upToCount: 4096), !chunk.isEmpty else {
        return nil
      }
      decoder.append(chunk)
    }
  }
}

private final class PriorityMCPMessageWriter {
  private let output = FileHandle.standardOutput

  /// Newline-delimited is the MCP stdio transport, and also the right default
  /// before any request has arrived.
  var framing: MCPMessageFraming = .newlineDelimited

  func writeResult(id: Any, result: Any) {
    writePayload([
      "jsonrpc": PriorityMCPConstants.jsonrpcVersion,
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
      "jsonrpc": PriorityMCPConstants.jsonrpcVersion,
      "id": id,
      "error": errorObject,
    ])
  }

  private func writePayload(_ payload: [String: Any]) {
    // No `.prettyPrinted`: newline framing requires the body to be a single
    // line, and the MCP spec forbids embedded newlines outright.
    guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

    do {
      try output.write(contentsOf: MCPFrameEncoder.encode(body: body, framing: framing))
    } catch {
      FileHandle.standardError.write(
        Data("MCP write error: \(error.localizedDescription)\n".utf8))
    }
  }
}

final class MCPServer {
  private let reader = PriorityMCPMessageReader()
  private let writer = PriorityMCPMessageWriter()
  private let client = PriorityMCPCheckvistClient(config: .fromEnvironment())
  private let localState = PriorityMCPLocalState()
  private var protocolVersion = PriorityMCPConstants.defaultProtocolVersion
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
        writer.framing = reader.framing
      } catch let rpcError as PriorityMCPJsonRpcError {
        writer.framing = reader.framing
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
          code: PriorityMCPConstants.internalError,
          message: error.localizedDescription
        )
        continue
      }

      let messageObject = message as? [String: Any]
      let messageID = messageObject?["id"]

      do {
        try await handle(message: message)
      } catch let rpcError as PriorityMCPJsonRpcError {
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
            code: PriorityMCPConstants.internalError,
            message: error.localizedDescription
          )
        }
      }
    }
  }

  private func handle(message: Any) async throws {
    guard let request = message as? [String: Any] else {
      throw PriorityMCPJsonRpcError(
        code: PriorityMCPConstants.invalidRequest,
        message: "Request must be an object.")
    }

    let jsonRPC = request["jsonrpc"] as? String
    guard jsonRPC == PriorityMCPConstants.jsonrpcVersion else {
      throw PriorityMCPJsonRpcError(
        code: PriorityMCPConstants.invalidRequest,
        message: "Unsupported JSON-RPC version.")
    }

    guard let method = request["method"] as? String, !method.isEmpty else {
      throw PriorityMCPJsonRpcError(
        code: PriorityMCPConstants.invalidRequest,
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
        protocolVersion = PriorityMCPConstants.defaultProtocolVersion
      }

      if let messageID {
        writer.writeResult(
          id: messageID,
          result: [
            "protocolVersion": protocolVersion,
            "serverInfo": [
              "name": PriorityMCPConstants.serverName,
              "version": PriorityMCPConstants.serverVersion,
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
        throw PriorityMCPJsonRpcError(
          code: PriorityMCPConstants.invalidParams,
          message: "tools/call params must be an object.")
      }
      guard let name = params["name"] as? String, !name.isEmpty else {
        throw PriorityMCPJsonRpcError(
          code: PriorityMCPConstants.invalidParams,
          message: "Missing tool name.")
      }

      let argumentsRaw = params["arguments"]
      let arguments: [String: Any]
      if argumentsRaw == nil {
        arguments = [:]
      } else if let parsed = argumentsRaw as? [String: Any] {
        arguments = parsed
      } else {
        throw PriorityMCPJsonRpcError(
          code: PriorityMCPConstants.invalidParams,
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

    throw PriorityMCPJsonRpcError(
      code: PriorityMCPConstants.methodNotFound,
      message: "Method not found: \(method)")
  }

  private func callTool(name: String, arguments: [String: Any]) async -> [String: Any] {
    do {
      switch name {
      case "task_lists":
        let payload = try await client.listLists()
        return Self.textContentResult(title: "Checklists", payload: payload)
      case "task_fetch":
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
      case "task_add":
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
      case "task_update":
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
      case "task_complete":
        let listID = try client.resolveListId(explicitListId: Self.asString(arguments["list_id"]))
        let taskID = try Self.requiredInt(arguments, key: "task_id")
        let payload = try await client.taskAction(listId: listID, taskId: taskID, action: .close)
        return Self.textContentResult(title: "Task completed", payload: payload)
      case "task_reopen":
        let listID = try client.resolveListId(explicitListId: Self.asString(arguments["list_id"]))
        let taskID = try Self.requiredInt(arguments, key: "task_id")
        let payload = try await client.taskAction(listId: listID, taskId: taskID, action: .reopen)
        return Self.textContentResult(title: "Task reopened", payload: payload)
      case "task_invalidate":
        let listID = try client.resolveListId(explicitListId: Self.asString(arguments["list_id"]))
        let taskID = try Self.requiredInt(arguments, key: "task_id")
        let payload = try await client.taskAction(
          listId: listID, taskId: taskID, action: .invalidate)
        return Self.textContentResult(title: "Task invalidated", payload: payload)
      case "task_delete":
        let listID = try client.resolveListId(explicitListId: Self.asString(arguments["list_id"]))
        let taskID = try Self.requiredInt(arguments, key: "task_id")
        let payload = try await client.deleteTask(listId: listID, taskId: taskID)
        return Self.textContentResult(title: "Task deleted", payload: payload)
      case "task_move":
        let listID = try client.resolveListId(explicitListId: Self.asString(arguments["list_id"]))
        let taskID = try Self.requiredInt(arguments, key: "task_id")
        let position = try Self.requiredInt(arguments, key: "position")
        guard position >= 1 else {
          throw MCPCheckvistError(message: "position must be 1 or greater.")
        }
        let payload = try await client.moveTask(
          listId: listID, taskId: taskID, position: position)
        return Self.textContentResult(title: "Task moved", payload: payload)
      case "task_reparent":
        let listID = try client.resolveListId(explicitListId: Self.asString(arguments["list_id"]))
        let taskID = try Self.requiredInt(arguments, key: "task_id")
        // Absent means "move to root". Passing 0 means the same, so a client
        // that can't express null still has a way to say it.
        let rawParent = try Self.asOptionalInt(arguments["parent_task_id"])
        let parentID = (rawParent == 0) ? nil : rawParent
        if let parentID, parentID == taskID {
          throw MCPCheckvistError(message: "A task cannot be its own parent.")
        }
        let payload = try await client.reparentTask(
          listId: listID, taskId: taskID, parentId: parentID)
        return Self.textContentResult(title: "Task reparented", payload: payload)
      case "task_note_add":
        let listID = try client.resolveListId(explicitListId: Self.asString(arguments["list_id"]))
        let taskID = try Self.requiredInt(arguments, key: "task_id")
        let comment = try Self.requiredString(arguments, key: "note")
        let payload = try await client.addNote(
          listId: listID, taskId: taskID, comment: comment)
        return Self.textContentResult(title: "Note added", payload: payload)
      case "list_create":
        let name = try Self.requiredString(arguments, key: "name")
        let payload = try await client.createList(name: name)
        return Self.textContentResult(title: "List created", payload: payload)
      case "task_search":
        let listID = try client.resolveListId(explicitListId: Self.asString(arguments["list_id"]))
        let includeClosed = try Self.asBool(arguments["include_closed"], defaultValue: false)
        let tasks = try await client.fetchTasks(
          listId: listID, includeClosed: includeClosed, withNotes: false)
        let matches = Self.filterTasks(
          tasks,
          query: Self.asOptionalString(arguments["query"]),
          tag: Self.asOptionalString(arguments["tag"]),
          dueBefore: Self.asOptionalString(arguments["due_before"])
        )
        let limit = try Self.asOptionalInt(arguments["limit"]) ?? 50
        let truncated = matches.count > limit
        return Self.textContentResult(
          title: "Search (list \(listID), \(matches.count) match(es)"
            + (truncated ? ", showing \(limit)" : "") + ")",
          payload: Array(matches.prefix(max(0, limit)))
        )
      case "daily_log_fetch":
        let days = try Self.asOptionalInt(arguments["days"]) ?? 1
        guard days >= 1, days <= 90 else {
          throw MCPCheckvistError(message: "days must be between 1 and 90.")
        }
        let payload = localState.daySummaries(endingOn: Date(), count: days)
        return Self.textContentResult(title: "Daily log (\(days) day(s))", payload: payload)
      case "dailies_list":
        let payload = localState.dailiesSnapshot(on: Date())
        return Self.textContentResult(title: "Dailies", payload: payload)
      case "task_metadata":
        let listID = try client.resolveListId(explicitListId: Self.asString(arguments["list_id"]))
        let payload = localState.taskMetadata(listId: listID)
        return Self.textContentResult(
          title: "Priority metadata (list \(listID))", payload: payload)
      case "daily_add":
        let title = try Self.requiredString(arguments, key: "title")
        let weekdays = try Self.asOptionalWeekdays(arguments["active_weekdays"])
        let payload = try localState.addDaily(title: title, activeWeekdays: weekdays)
        return Self.textContentResult(title: "Daily added", payload: payload)
      case "daily_update":
        let id = try Self.requiredString(arguments, key: "daily_id")
        let title = Self.asOptionalString(arguments["title"])
        let weekdays = try Self.asOptionalWeekdays(arguments["active_weekdays"])
        let archived = arguments["archived"] == nil
          ? nil : try Self.asBool(arguments["archived"], defaultValue: false)
        guard title != nil || weekdays != nil || archived != nil else {
          throw MCPCheckvistError(
            message: "No updates provided. Pass title, active_weekdays and/or archived.")
        }
        let payload = try localState.updateDaily(
          id: id, title: title, activeWeekdays: weekdays, archived: archived)
        return Self.textContentResult(title: "Daily updated", payload: payload)
      case "daily_tick":
        let id = try Self.requiredString(arguments, key: "daily_id")
        let done = try Self.asBool(arguments["done"], defaultValue: true)
        let payload = try localState.setDaily(id: id, done: done)
        return Self.textContentResult(
          title: (payload["changed"] as? Bool == true)
            ? (done ? "Daily ticked" : "Daily un-ticked")
            : "Daily already in that state",
          payload: payload
        )
      default:
        throw PriorityMCPJsonRpcError(
          code: PriorityMCPConstants.invalidParams,
          message: "Unknown tool: \(name)")
      }
    } catch let error as PriorityMCPJsonRpcError {
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

  /// Filtering runs here rather than in the client so a search over a large
  /// list costs one tool result instead of the whole list plus the model's own
  /// scan of it. All three filters are ANDed; omitting one drops it.
  private static func filterTasks(
    _ tasks: [[String: Any]],
    query: String?,
    tag: String?,
    dueBefore: String?
  ) -> [[String: Any]] {
    var matches = tasks

    if let query = query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
      matches = matches.filter {
        (($0["content"] as? String) ?? "").range(of: query, options: .caseInsensitive) != nil
      }
    }

    if let tag = tag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty {
      // Checkvist returns tags both as an array and inline in the content as
      // `#tag`, and which one is populated depends on the endpoint — match
      // either rather than silently missing half the tagged tasks.
      let normalized = tag.hasPrefix("#") ? String(tag.dropFirst()) : tag
      matches = matches.filter { task in
        if let tags = task["tags"] as? [String],
          tags.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame })
        {
          return true
        }
        if let tags = task["tags"] as? [String: Any],
          tags.keys.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame })
        {
          return true
        }
        let content = (task["content"] as? String) ?? ""
        return content.range(of: "#\(normalized)", options: .caseInsensitive) != nil
      }
    }

    if let dueBefore = dueBefore?.trimmingCharacters(in: .whitespacesAndNewlines),
      !dueBefore.isEmpty
    {
      // Checkvist serialises `due` as `YYYY-MM-DD`, which compares correctly as
      // a string. Tasks with no due date are never "due before" anything.
      matches = matches.filter {
        guard let due = $0["due"] as? String, !due.isEmpty else { return false }
        return due < dueBefore
      }
    }

    return matches
  }

  private static var toolDefinitions: [[String: Any]] {
    [
      [
        "name": "task_lists",
        "description": "List available task lists (non-archived).",
        "inputSchema": [
          "type": "object",
          "properties": [:],
          "additionalProperties": false,
        ],
      ],
      [
        "name": "task_fetch",
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
        "name": "task_add",
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
        "name": "task_update",
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
        "name": "task_complete",
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
        "name": "task_reopen",
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
        "name": "task_invalidate",
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
        "name": "task_delete",
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
      [
        "name": "task_move",
        "description": "Reorder a task among its siblings. Position is 1-based.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "list_id": ["type": "string"],
            "task_id": ["type": "integer"],
            "position": ["type": "integer", "minimum": 1],
          ],
          "required": ["task_id", "position"],
          "additionalProperties": false,
        ],
      ],
      [
        "name": "task_reparent",
        "description":
          "Move a task under a different parent. Omit parent_task_id (or pass 0) to move it to the list root.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "list_id": ["type": "string"],
            "task_id": ["type": "integer"],
            "parent_task_id": ["type": "integer"],
          ],
          "required": ["task_id"],
          "additionalProperties": false,
        ],
      ],
      [
        "name": "task_note_add",
        "description":
          "Append a note (Checkvist comment) to a task. Notes are read back via task_fetch with with_notes.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "list_id": ["type": "string"],
            "task_id": ["type": "integer"],
            "note": ["type": "string", "minLength": 1],
          ],
          "required": ["task_id", "note"],
          "additionalProperties": false,
        ],
      ],
      [
        "name": "list_create",
        "description": "Create a new checklist.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "name": ["type": "string", "minLength": 1]
          ],
          "required": ["name"],
          "additionalProperties": false,
        ],
      ],
      [
        "name": "task_search",
        "description":
          "Search tasks in a list by content substring, tag, and/or due date. Cheaper than fetching the whole list.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "list_id": ["type": "string"],
            "query": ["type": "string"],
            "tag": ["type": "string"],
            "due_before": ["type": "string", "description": "YYYY-MM-DD, exclusive."],
            "include_closed": ["type": "boolean", "default": false],
            "limit": ["type": "integer", "default": 50, "minimum": 1],
          ],
          "additionalProperties": false,
        ],
      ],
      [
        "name": "daily_log_fetch",
        "description":
          "What actually happened on recent days: completions, focus time, unfinished and deferred tasks, and daily ticks. Local to Priority; read-only.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "days": [
              "type": "integer", "default": 1, "minimum": 1, "maximum": 90,
              "description": "How many logical days back to include, ending today.",
            ]
          ],
          "additionalProperties": false,
        ],
      ],
      [
        "name": "dailies_list",
        "description":
          "The configured dailies (habits) with today's schedule and tick state. Local to Priority; read-only.",
        "inputSchema": [
          "type": "object",
          "properties": [:],
          "additionalProperties": false,
        ],
      ],
      [
        "name": "task_metadata",
        "description":
          "Priority-only per-task state that Checkvist does not store: priority ranks, recurrence rules, and start dates. Read-only.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "list_id": ["type": "string"]
          ],
          "additionalProperties": false,
        ],
      ],
      [
        "name": "daily_add",
        "description":
          "Create a daily (a habit that resets each day, not a task). Local to Priority.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "title": ["type": "string", "minLength": 1],
            "active_weekdays": [
              "type": "array",
              "items": ["type": "integer", "minimum": 1, "maximum": 7],
              "description": "1 = Sunday. Omit for every day.",
            ],
          ],
          "required": ["title"],
          "additionalProperties": false,
        ],
      ],
      [
        "name": "daily_update",
        "description":
          "Rename a daily, change which weekdays it's expected on, or archive/unarchive it. Archiving keeps history readable rather than deleting.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "daily_id": ["type": "string"],
            "title": ["type": "string"],
            "active_weekdays": [
              "type": "array",
              "items": ["type": "integer", "minimum": 1, "maximum": 7],
              "description": "1 = Sunday.",
            ],
            "archived": ["type": "boolean"],
          ],
          "required": ["daily_id"],
          "additionalProperties": false,
        ],
      ],
      [
        "name": "daily_tick",
        "description":
          "Tick or un-tick a daily for today. Recorded against the current logical day, honouring the configured rollover hour.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "daily_id": ["type": "string"],
            "done": ["type": "boolean", "default": true],
          ],
          "required": ["daily_id"],
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

  /// Whether a decoded JSON value was literally `true`/`false`.
  ///
  /// `value is Bool` cannot answer this. `JSONSerialization` decodes numbers to
  /// `NSNumber`, and Swift's dynamic cast from `NSNumber` to `Bool` succeeds for
  /// 0 and 1 — so the obvious check rejected `position: 1` and
  /// `parent_task_id: 0` as "boolean", which are the two most common values
  /// those arguments take. Only `__NSCFBoolean` carries `CFBooleanGetTypeID`.
  private static func isJSONBoolean(_ value: Any) -> Bool {
    guard let number = value as? NSNumber else { return value is Bool }
    return CFGetTypeID(number) == CFBooleanGetTypeID()
  }

  private static func asOptionalInt(_ value: Any?) throws -> Int? {
    guard let value else { return nil }
    if isJSONBoolean(value) {
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

  /// `Calendar` weekday numbering, 1 = Sunday, matching `Daily.activeWeekdays`.
  private static func asOptionalWeekdays(_ value: Any?) throws -> Set<Int>? {
    guard let value, !(value is NSNull) else { return nil }
    guard let raw = value as? [Any] else {
      throw MCPCheckvistError(message: "active_weekdays must be an array of integers 1-7.")
    }
    var weekdays = Set<Int>()
    for element in raw {
      guard let day = try asOptionalInt(element), (1...7).contains(day) else {
        throw MCPCheckvistError(
          message: "active_weekdays entries must be integers 1-7 (1 = Sunday).")
      }
      weekdays.insert(day)
    }
    guard !weekdays.isEmpty else {
      throw MCPCheckvistError(message: "active_weekdays must not be empty.")
    }
    return weekdays
  }

  private static func requiredInt(_ arguments: [String: Any], key: String) throws -> Int {
    guard let value = try asOptionalInt(arguments[key]) else {
      throw MCPCheckvistError(message: "Missing required argument: \(key)")
    }
    return value
  }
}
// swiftlint:enable file_length
