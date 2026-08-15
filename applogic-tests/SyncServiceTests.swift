import XCTest

@testable import PriorityAppLogic

/// Coverage for the network-facing service: the offline replay queue, the
/// refetch fan-out, and list switching.
@MainActor
final class SyncServiceTests: XCTestCase {
  private var defaults: UserDefaults!
  private var preferencesStore: PreferencesStore!
  private var localTaskStore: LocalTaskStore!
  private var plugin: FakeCheckvistSyncPlugin!
  private var repository: TaskRepository!
  private var host: StubTaskServiceHost!
  private var service: SyncService!

  override func setUp() async throws {
    try await super.setUp()
    defaults = makeIsolatedDefaultsSuite()
    preferencesStore = PreferencesStore(defaults: defaults)
    localTaskStore = LocalTaskStore(defaults: defaults)
    plugin = FakeCheckvistSyncPlugin()

    preferencesStore.set("tester", for: .checkvistUsername)
    preferencesStore.set("42", for: .checkvistListId)
    preferencesStore.set(true, for: .checkvistIntegrationEnabled)

    repository = TaskRepository(
      preferencesStore: preferencesStore,
      checkvistSyncPlugin: plugin,
      localTaskStore: localTaskStore,
      initialRemoteKey: "key",
      defaults: defaults
    )
    XCTAssertTrue(repository.canSyncRemotely, "tests assume the online routing branch")

    host = StubTaskServiceHost()
    host.repository = repository
    service = SyncService(host: host, repository: repository)
  }

  // MARK: - Offline replay

  func testReplayMapsAQueuedCreateOntoItsRealIdBeforeReplayingDependentWork() async {
    plugin.nextCreatedTaskId = 500
    repository.tasks = [makeTask(id: -1, content: "offline task")]
    repository.enqueuePendingCreate(
      PendingTaskCreate(tempId: -1, content: "offline task", parentId: nil, position: 1))
    repository.enqueuePendingDelete(-1)

    await service.flushPendingTaskMutations()

    XCTAssertEqual(plugin.deleteTaskCalls, [500], "the delete targets the real server id")
    XCTAssertFalse(repository.hasPendingOfflineWork)
    XCTAssertEqual(plugin.fetchOpenTasksCalls, ["42"], "a clean flush ends in a refetch")
  }

  /// A create that fails is retried on the next flush. Work queued behind it
  /// therefore has to be preserved against the *temp* id — dropping it made the
  /// create succeed later with nothing to delete or close it, so a task the
  /// user had already dealt with offline came back permanently.
  func testWorkBehindAFailedCreateIsPreservedAgainstTheTempId() async {
    plugin.createTaskError = CheckvistSessionError.requestFailed
    repository.enqueuePendingCreate(
      PendingTaskCreate(tempId: -1, content: "offline task", parentId: nil, position: 1))
    repository.enqueuePendingDelete(-1)
    repository.enqueuePendingAction(PendingTaskAction(taskId: -1, action: .close))
    repository.enqueuePendingMutation(taskId: -1, content: "edited", due: nil)

    await service.flushPendingTaskMutations()

    XCTAssertEqual(repository.pendingTaskCreates.map(\.tempId), [-1])
    XCTAssertEqual(repository.pendingTaskDeletes, [-1])
    XCTAssertEqual(repository.pendingTaskActions.map(\.taskId), [-1])
    XCTAssertEqual(repository.pendingTaskMutations[-1]?.content, "edited")
    XCTAssertTrue(plugin.deleteTaskCalls.isEmpty)
    XCTAssertTrue(plugin.fetchOpenTasksCalls.isEmpty, "a failed flush must not refetch")
  }

  /// Distinct from the case above: the create is gone for good (it isn't in
  /// the queue and never produced a real id), so the dependent work is moot.
  func testWorkBehindAVanishedCreateIsDropped() async {
    repository.enqueuePendingDelete(-99)

    await service.flushPendingTaskMutations()

    XCTAssertTrue(repository.pendingTaskDeletes.isEmpty)
    XCTAssertTrue(plugin.deleteTaskCalls.isEmpty)
  }

  func testAChildCreateWaitsForItsParentCreateToSucceed() async {
    plugin.createTaskError = CheckvistSessionError.requestFailed
    repository.enqueuePendingCreate(
      PendingTaskCreate(tempId: -1, content: "parent", parentId: nil, position: 1))
    repository.enqueuePendingCreate(
      PendingTaskCreate(tempId: -2, content: "child", parentId: -1, position: 1))

    await service.flushPendingTaskMutations()

    XCTAssertEqual(
      repository.pendingTaskCreates.map(\.tempId).sorted(), [-2, -1].sorted(),
      "both creates survive for the next flush")
    XCTAssertEqual(
      plugin.createTaskCalls.count, 1,
      "the child is never attempted without a real parent id")
  }

  func testReplayIsANoOpWhenNothingIsQueued() async {
    await service.flushPendingTaskMutations()

    XCTAssertTrue(plugin.createTaskCalls.isEmpty)
    XCTAssertTrue(plugin.fetchOpenTasksCalls.isEmpty)
  }

  // MARK: - Fetch

  func testFetchReplacesTasksAndFansOutTheReconciliations() async {
    plugin.openTasksByListId["42"] = [makeTask(id: 1, content: "alpha")]
    host.currentSiblingIndex = 9

    await service.fetchTopTask()

    XCTAssertEqual(repository.tasks.map(\.id), [1])
    XCTAssertEqual(host.currentSiblingIndex, 0, "an out-of-range cursor is reset")
    XCTAssertEqual(host.focusClampCallCount, 1)
    XCTAssertEqual(host.timerReconcileCallCount, 1)
    XCTAssertEqual(host.obsidianReconcileCalls.count, 1)
    XCTAssertEqual(host.onboardingCompletedCallCount, 1)
  }

  func testFetchInKanbanModeClampsTheKanbanSelectionInsteadOfTheListCursor() async {
    plugin.openTasksByListId["42"] = [makeTask(id: 1, content: "alpha")]
    host.taskMoveMode = .kanbanColumn
    host.currentSiblingIndex = 9

    await service.fetchTopTask()

    XCTAssertEqual(host.clampKanbanSelectionCallCount, 1)
    XCTAssertEqual(host.currentSiblingIndex, 9, "the list cursor is not the kanban cursor")
  }

  func testFetchClearsAKanbanFilterWhoseParentTaskIsGone() async {
    plugin.openTasksByListId["42"] = [makeTask(id: 1, content: "alpha")]
    host.taskMoveMode = .kanbanColumn
    host.kanbanFilterParentId = 77
    host.currentParentId = 77

    await service.fetchTopTask()

    XCTAssertNil(host.kanbanFilterParentId)
    XCTAssertEqual(host.currentParentId, 0, "scope falls back to the root")
  }

  // MARK: - List management

  func testSwitchingListsResetsScopeAndDropsStaleOfflineWork() async {
    repository.enqueuePendingDelete(5)
    host.currentParentId = 12
    host.currentSiblingIndex = 3
    host.kanbanFilterParentId = 12

    await service.switchCheckvistList(to: " 77 ")

    XCTAssertEqual(repository.listId, "77")
    XCTAssertEqual(host.currentParentId, 0)
    XCTAssertEqual(host.currentSiblingIndex, 0)
    XCTAssertNil(host.kanbanFilterParentId)
    XCTAssertEqual(host.clearKanbanSelectionCallCount, 1)
    XCTAssertFalse(
      repository.hasPendingOfflineWork, "queued work belongs to the list it was queued against")
  }

  func testSwitchingToTheCurrentListDoesNothing() async {
    await service.switchCheckvistList(to: "42")

    XCTAssertTrue(plugin.fetchOpenTasksCalls.isEmpty)
    XCTAssertEqual(host.clearKanbanSelectionCallCount, 0)
  }

  // MARK: - Reorder routing

  func testMoveInKanbanModeIsHandedToTheHostRatherThanTouchingPositions() async {
    repository.tasks = [makeTask(id: 1, position: 1), makeTask(id: 2, position: 2)]
    host.taskMoveMode = .kanbanColumn

    await service.moveTask(repository.tasks[0], direction: 1)

    XCTAssertEqual(host.kanbanNudges.map(\.taskId), [1])
    XCTAssertEqual(host.kanbanNudges.map(\.direction), [1])
    XCTAssertEqual(repository.tasks.map(\.position), [1, 2], "positions are untouched")
    XCTAssertTrue(plugin.moveTaskCalls.isEmpty)
  }

  func testSiblingMoveSwapsPositionsAndQueuesTheServerReorder() async {
    repository.tasks = [makeTask(id: 1, position: 1), makeTask(id: 2, position: 2)]

    await service.moveTask(repository.tasks[0], direction: 1)

    XCTAssertEqual(repository.tasks.map(\.id), [2, 1])
    XCTAssertEqual(repository.tasks.first { $0.id == 1 }?.position, 2)
    XCTAssertEqual(repository.tasks.first { $0.id == 2 }?.position, 1)
  }

  func testMoveIgnoresDirectionsOtherThanOneStep() async {
    repository.tasks = [makeTask(id: 1, position: 1), makeTask(id: 2, position: 2)]

    await service.moveTask(repository.tasks[0], direction: 3)

    XCTAssertEqual(repository.tasks.map(\.id), [1, 2])
  }

  func testDueViewMoveCopiesTheNeighbourDueDateThroughTheOptimisticEditPath() async {
    repository.tasks = [
      makeTask(id: 1, position: 1, due: "2026-08-13"),
      makeTask(id: 2, position: 2, due: "2026-08-20"),
    ]
    host.taskMoveMode = .dueDate

    await service.moveTask(repository.tasks[0], direction: 1)

    XCTAssertEqual(host.optimisticMoveCalls.map(\.taskId), [1])
    XCTAssertEqual(host.optimisticMoveCalls.first?.due, "2026-08-20")
  }
}
