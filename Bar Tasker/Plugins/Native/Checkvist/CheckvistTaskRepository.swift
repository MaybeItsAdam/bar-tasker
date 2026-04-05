import Foundation
import OSLog

struct CheckvistTaskCachePayload: Codable, Sendable {
  let listId: String
  let fetchedAt: Date
  let tasks: [CheckvistTask]
}

struct CheckvistTaskRepository {
  private let logger = Logger(
    subsystem: "uk.co.maybeitsadam.bar-tasker", category: "task-repository")
  private static let userAgent = "BarTasker/1.0 (Macintosh; Mac OS X)"
  private static let cacheFreshnessInterval: TimeInterval = 15 * 60

  func fetchTasks(
    listId: String,
    performAuthenticatedRequest:
      @escaping @MainActor (
        (String) throws -> URLRequest
      ) async throws -> (Data, HTTPURLResponse)
  ) async throws -> [CheckvistTask] {
    guard let baseURL = CheckvistEndpoints.tasks(listId: listId),
      var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
    else {
      throw CheckvistTaskRepositoryError.invalidListURL
    }
    components.queryItems = [URLQueryItem(name: "with_notes", value: "true")]
    guard let url = components.url else {
      throw CheckvistTaskRepositoryError.invalidListURL
    }

    let (data, httpResponse) = try await performAuthenticatedRequest { validToken in
      var request = URLRequest(url: url)
      request.httpMethod = "GET"
      request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
      request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
      return request
    }

    guard (200...299).contains(httpResponse.statusCode) else {
      throw CheckvistTaskRepositoryError.fetchFailed(statusCode: httpResponse.statusCode)
    }

    let allTasks = try JSONDecoder().decode([CheckvistTask].self, from: data)
    let openTasks = allTasks.filter { $0.status == 0 }
    return Self.depthFirstTasks(from: openTasks)
  }

  func persistTaskCache(_ payload: CheckvistTaskCachePayload) {
    guard let cacheURL = taskCacheURL(for: payload.listId) else { return }

    do {
      let data = try JSONEncoder().encode(payload)
      try data.write(to: cacheURL, options: [.atomic])
    } catch {
      logger.error("Failed to persist task cache: \(error.localizedDescription, privacy: .public)")
    }
  }

  func loadTaskCache(for listId: String) -> CheckvistTaskCachePayload? {
    guard let cacheURL = taskCacheURL(for: listId) else { return nil }

    do {
      let data = try Data(contentsOf: cacheURL)
      return try JSONDecoder().decode(CheckvistTaskCachePayload.self, from: data)
    } catch {
      return nil
    }
  }

  func isCacheOutdated(_ payload: CheckvistTaskCachePayload) -> Bool {
    Date().timeIntervalSince(payload.fetchedAt) > Self.cacheFreshnessInterval
  }

  private func taskCacheURL(for listId: String) -> URL? {
    guard !listId.isEmpty else { return nil }

    let fileManager = FileManager.default
    guard
      let appSupportDirectory = fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    else { return nil }

    let containerDirectory = appSupportDirectory.appendingPathComponent(
      "Bar Tasker", isDirectory: true)

    do {
      try fileManager.createDirectory(at: containerDirectory, withIntermediateDirectories: true)
    } catch {
      return nil
    }

    return containerDirectory.appendingPathComponent("tasks-cache-\(listId).json")
  }

  private static func depthFirstTasks(from allTasks: [CheckvistTask]) -> [CheckvistTask] {
    func depthFirst(parentId: Int) -> [CheckvistTask] {
      let children =
        allTasks
        .filter { ($0.parentId ?? 0) == parentId }
        .sorted { ($0.position ?? 0) < ($1.position ?? 0) }
      return children.flatMap { [$0] + depthFirst(parentId: $0.id) }
    }

    return depthFirst(parentId: 0)
  }
}

enum CheckvistTaskRepositoryError: LocalizedError {
  case invalidListURL
  case fetchFailed(statusCode: Int)

  var errorDescription: String? {
    switch self {
    case .invalidListURL:
      return "Invalid list URL."
    case .fetchFailed:
      return "Failed to fetch tasks."
    }
  }
}
