import Foundation
import OSLog

struct OfflineTaskStorePayload: Codable {
  let openTasks: [CheckvistTask]
  let archivedTasks: [CheckvistTask]
  let nextTaskId: Int

  static let empty = OfflineTaskStorePayload(openTasks: [], archivedTasks: [], nextTaskId: 1)
}

struct OfflineTaskStateSnapshot {
  let openTasks: [CheckvistTask]
  let archivedTasks: [CheckvistTask]
  let nextTaskId: Int
  let currentParentId: Int
  let currentSiblingIndex: Int
  let priorityTaskIds: [Int]
  let pendingObsidianSyncTaskIds: [Int]
  let timerByTaskId: [Int: TimeInterval]
  let timedTaskId: Int?
  let timerRunning: Bool
}

final class LocalTaskStore {
  private let defaults: UserDefaults
  private let payloadKey = "offlineTaskStorePayload"
  private let logger = Logger(subsystem: "uk.co.maybeitsadam.bar-tasker", category: "local-task-store")

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func load() -> OfflineTaskStorePayload {
    guard let data = defaults.data(forKey: payloadKey) else { return .empty }
    do {
      return try JSONDecoder().decode(OfflineTaskStorePayload.self, from: data)
    } catch {
      logger.error("Failed to decode offline task store: \(error.localizedDescription, privacy: .public)")
      return .empty
    }
  }

  func save(_ payload: OfflineTaskStorePayload) {
    do {
      let data = try JSONEncoder().encode(payload)
      defaults.set(data, forKey: payloadKey)
    } catch {
      logger.error("Failed to encode offline task store: \(error.localizedDescription, privacy: .public)")
    }
  }
}
