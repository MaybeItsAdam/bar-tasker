import Foundation
import XCTest

@testable import BarTaskerAppLogic

/// Returns a `UserDefaults` instance backed by a fresh suite. Each test that
/// hits defaults should use one of these so suite contents from prior tests
/// can't leak into the suite under test. Caller is responsible for calling
/// `removePersistentDomain` on teardown if it wants the bytes wiped.
func makeIsolatedDefaults(file: StaticString = #file, line: UInt = #line) -> UserDefaults {
  let suiteName = "applogic-tests-\(UUID().uuidString)"
  guard let defaults = UserDefaults(suiteName: suiteName) else {
    XCTFail("Could not create isolated UserDefaults suite", file: file, line: line)
    return .standard
  }
  return defaults
}

/// Convenience constructor matching the offline plugin's expectations.
func makeTask(
  id: Int,
  content: String = "",
  parentId: Int? = nil,
  status: Int = 0,
  position: Int? = nil,
  due: String? = nil
) -> CheckvistTask {
  CheckvistTask(
    id: id,
    content: content,
    status: status,
    due: due,
    position: position,
    parentId: parentId,
    level: nil,
    notes: nil,
    updatedAt: nil
  )
}

/// In-memory `CheckvistSyncPlugin` used to drive `TaskRepository` tests through
/// the "online" branch without touching the network. Records calls and lets the
/// test programme responses.
@MainActor
final class FakeCheckvistSyncPlugin: CheckvistSyncPlugin {
  let pluginIdentifier = "test.fake.checkvist"
  let displayName = "Fake Checkvist"
  let pluginDescription = "Test double"

  // Responses
  var loginResult: Bool = true
  var loginError: Error?
  var lists: [CheckvistList] = []
  var openTasksByListId: [String: [CheckvistTask]] = [:]
  var nextCreatedTaskId: Int = 1_000

  // Recorded calls
  private(set) var loginCallCount = 0
  private(set) var fetchOpenTasksCalls: [String] = []
  private(set) var fetchListsCallCount = 0
  private(set) var createTaskCalls:
    [(listId: String, content: String, parentId: Int?, position: Int?)] = []
  private(set) var moveTaskCalls: [(listId: String, taskId: Int, position: Int)] = []
  private(set) var performTaskActionCalls:
    [(listId: String, taskId: Int, action: CheckvistTaskAction)] = []
  private(set) var didClearAuthentication = false

  func login(credentials: CheckvistCredentials) async throws -> Bool {
    loginCallCount += 1
    if let loginError { throw loginError }
    return loginResult
  }

  func fetchOpenTasks(listId: String, credentials: CheckvistCredentials) async throws
    -> [CheckvistTask]
  {
    fetchOpenTasksCalls.append(listId)
    return openTasksByListId[listId] ?? []
  }

  func fetchLists(credentials: CheckvistCredentials) async throws -> [CheckvistList] {
    fetchListsCallCount += 1
    return lists
  }

  func clearAuthentication() {
    didClearAuthentication = true
  }

  func performTaskAction(
    listId: String,
    taskId: Int,
    action: CheckvistTaskAction,
    credentials: CheckvistCredentials
  ) async throws -> Bool {
    performTaskActionCalls.append((listId, taskId, action))
    return true
  }

  func updateTask(
    listId: String,
    taskId: Int,
    content: String?,
    due: String?,
    credentials: CheckvistCredentials
  ) async throws -> Bool {
    true
  }

  func createTask(
    listId: String,
    content: String,
    parentId: Int?,
    position: Int?,
    credentials: CheckvistCredentials
  ) async throws -> CheckvistTask? {
    createTaskCalls.append((listId, content, parentId, position))
    let id = nextCreatedTaskId
    nextCreatedTaskId += 1
    return makeTask(id: id, content: content, parentId: parentId, position: position)
  }

  func deleteTask(listId: String, taskId: Int, credentials: CheckvistCredentials) async throws
    -> Bool
  {
    true
  }

  func moveTask(
    listId: String,
    taskId: Int,
    position: Int,
    credentials: CheckvistCredentials
  ) async throws -> Bool {
    moveTaskCalls.append((listId, taskId, position))
    return true
  }

  func reparentTask(
    listId: String,
    taskId: Int,
    parentId: Int?,
    credentials: CheckvistCredentials
  ) async throws -> Bool {
    true
  }

  func persistTaskCache(listId: String, tasks: [CheckvistTask]) {}
  func loadTaskCache(for listId: String) -> CheckvistTaskCachePayload? { nil }
  func isTaskCacheOutdated(_ payload: CheckvistTaskCachePayload) -> Bool { true }
}
