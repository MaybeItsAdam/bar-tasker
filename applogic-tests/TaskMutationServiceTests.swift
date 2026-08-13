import XCTest

@testable import BarTaskerAppLogic

/// Coverage for the optimistic-mutation layer: what lands in `tasks`
/// immediately, what gets rolled back when the server says no, and what gets
/// queued instead when the network is gone.
@MainActor
final class TaskMutationServiceTests: XCTestCase {
  private var defaults: UserDefaults!
  private var preferencesStore: PreferencesStore!
  private var localTaskStore: LocalTaskStore!
  private var plugin: FakeCheckvistSyncPlugin!
  private var repository: TaskRepository!
  private var host: StubTaskServiceHost!
  private var service: TaskMutationService!

  override func setUp() async throws {
    try await super.setUp()
    defaults = makeIsolatedDefaultsSuite()
    preferencesStore = PreferencesStore(defaults: defaults)
    localTaskStore = LocalTaskStore(defaults: defaults)
    plugin = FakeCheckvistSyncPlugin()

    // Credentials + list + integration on, so `activeSyncPlugin` resolves to
    // the fake Checkvist plugin rather than the offline store.
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
    service = TaskMutationService(host: host, repository: repository)
  }

  // MARK: - Rollback after a suspension

  /// The rollback has to re-find the task by id. A captured index goes stale
  /// across the `await`, because other main-actor work (a refetch, a sibling
  /// completion) can reshape `tasks` while the update is in flight — and the
  /// old code then wrote the original task over whatever now sat at that index.
  func testUpdateRollbackRestoresTheRightTaskAfterTheListShiftedUnderIt() async {
    repository.tasks = [
      makeTask(id: 1, content: "alpha"),
      makeTask(id: 2, content: "bravo"),
      makeTask(id: 3, content: "charlie"),
    ]
    let target = repository.tasks[1]

    // Simulate a refetch landing mid-flight: the row ahead of the target goes
    // away, so the target's index shifts from 1 to 0.
    plugin.beforeUpdateTaskReturns = { [weak self] in
      self?.repository.tasks.removeAll { $0.id == 1 }
    }
    plugin.updateTaskError = CheckvistSessionError.requestFailed

    await service.updateTask(task: target, content: "edited")

    XCTAssertEqual(repository.tasks.map(\.id), [2, 3])
    XCTAssertEqual(repository.tasks[0].content, "bravo", "target should be rolled back")
    XCTAssertEqual(repository.tasks[1].content, "charlie", "bystander must be untouched")
  }

  func testUpdateAppliesOptimisticallyAndKeepsItOnSuccess() async {
    repository.tasks = [makeTask(id: 1, content: "alpha")]

    await service.updateTask(task: repository.tasks[0], content: "edited")

    XCTAssertEqual(repository.tasks[0].content, "edited")
    XCTAssertEqual(host.fetchTopTaskCallCount, 1)
    XCTAssertNil(repository.errorMessage)
  }

  func testUpdateWhileOfflineKeepsTheEditAndQueuesItForReplay() async {
    repository.tasks = [makeTask(id: 1, content: "alpha")]
    repository.isNetworkReachable = false
    plugin.updateTaskError = CheckvistSessionError.requestFailed

    await service.updateTask(task: repository.tasks[0], due: "2026-09-01")

    XCTAssertEqual(repository.tasks[0].due, "2026-09-01", "optimistic edit must survive")
    XCTAssertEqual(repository.pendingTaskMutations[1]?.due, "2026-09-01")
    XCTAssertEqual(repository.errorMessage, "Offline — will sync when connected.")
  }

  // MARK: - Add

  func testAddOnlineFailureRemovesTheOptimisticTask() async {
    repository.tasks = [makeTask(id: 1, content: "alpha")]
    plugin.createTaskError = CheckvistSessionError.requestFailed

    await service.addTask(content: "new thing")

    XCTAssertEqual(repository.tasks.map(\.id), [1])
    XCTAssertTrue(repository.pendingTaskCreates.isEmpty)
    XCTAssertEqual(repository.errorMessage?.hasPrefix("Error adding task:"), true)
  }

  func testAddWhileOfflineKeepsTheOptimisticTaskAndQueuesTheCreate() async throws {
    repository.tasks = [makeTask(id: 1, content: "alpha")]
    repository.isNetworkReachable = false
    plugin.createTaskError = CheckvistSessionError.requestFailed

    await service.addTask(content: "new thing")

    XCTAssertEqual(repository.tasks.count, 2)
    let optimistic = try XCTUnwrap(repository.tasks.first { $0.id != 1 })
    XCTAssertEqual(optimistic.content, "new thing")
    XCTAssertLessThan(optimistic.id, 0, "placeholder ids are negative")
    XCTAssertEqual(repository.pendingTaskCreates.count, 1)
    XCTAssertEqual(repository.pendingTaskCreates.first?.tempId, optimistic.id)
  }

  func testAddWithoutAListPromptsSetupInsteadOfCallingTheServer() async {
    repository.listId = ""

    await service.addTask(content: "new thing")

    XCTAssertEqual(host.onboardingDialogPresentCount, 1)
    XCTAssertTrue(plugin.createTaskCalls.isEmpty)
  }

  // MARK: - Mark done

  func testMarkDoneRemovesTheWholeSubtreeOptimisticallyAndClosesTheTask() async {
    repository.tasks = [
      makeTask(id: 1, content: "parent"),
      makeTask(id: 2, content: "child", parentId: 1),
      makeTask(id: 3, content: "unrelated"),
    ]
    host.currentTask = repository.tasks[0]

    await service.markCurrentTaskDone()

    XCTAssertEqual(repository.tasks.map(\.id), [3], "parent and child both leave the list")
    XCTAssertEqual(plugin.performTaskActionCalls.count, 1)
    XCTAssertEqual(plugin.performTaskActionCalls.first?.taskId, 1)
    XCTAssertEqual(plugin.performTaskActionCalls.first?.action, .close)
  }

  /// The haptic/animation sequence is the host's job, and it can be cancelled
  /// by the user navigating away. A cancelled sequence must abort the close
  /// rather than let it fire late against a task the user has moved off.
  func testMarkDoneIsAbandonedWhenTheCompletionFeedbackIsCancelled() async {
    repository.tasks = [makeTask(id: 1, content: "parent")]
    host.currentTask = repository.tasks[0]
    host.completionFeedbackSucceeds = false

    await service.markCurrentTaskDone()

    XCTAssertEqual(host.completionFeedbackTaskIds, [1])
    XCTAssertTrue(plugin.performTaskActionCalls.isEmpty)
    XCTAssertEqual(repository.tasks.map(\.id), [1], "the task stays put")
  }

  func testTaskActionRestoresTheSubtreeWhenTheServerRejectsTheClose() async {
    repository.tasks = [
      makeTask(id: 1, content: "parent"),
      makeTask(id: 2, content: "child", parentId: 1),
    ]
    plugin.performTaskActionResult = false

    await service.taskAction(repository.tasks[0], endpoint: "close")

    XCTAssertEqual(repository.tasks.map(\.id), [1, 2])
    XCTAssertEqual(repository.errorMessage, "Failed to close task.")
  }

  func testCloseWhileOfflineQueuesTheActionAndAnAncestorReopen() async {
    repository.tasks = [
      makeTask(id: 1, content: "parent"),
      makeTask(id: 2, content: "child", parentId: 1),
    ]
    repository.isNetworkReachable = false
    plugin.performTaskActionError = CheckvistSessionError.requestFailed

    await service.taskAction(repository.tasks[1], endpoint: "close")

    XCTAssertEqual(
      repository.pendingTaskActions.map(\.taskId), [2, 1],
      "the close, then the ancestor reopen that defeats Checkvist's cascade")
    XCTAssertEqual(repository.pendingTaskActions.map(\.action), [.close, .reopen])
  }

  // MARK: - Delete

  func testDeletingAStillQueuedOfflineCreateCancelsItInsteadOfCallingTheServer() async {
    let tempId = -7
    repository.tasks = [makeTask(id: tempId, content: "offline task")]
    repository.enqueuePendingCreate(
      PendingTaskCreate(tempId: tempId, content: "offline task", parentId: nil, position: 1))

    await service.deleteTask(repository.tasks[0])

    XCTAssertTrue(repository.pendingTaskCreates.isEmpty)
    XCTAssertTrue(repository.tasks.isEmpty)
    XCTAssertTrue(plugin.deleteTaskCalls.isEmpty, "never round-trip a create+delete")
  }

  func testDeleteRemovesTheSubtreeImmediatelyAndCallsTheServer() async {
    repository.tasks = [
      makeTask(id: 1, content: "parent"),
      makeTask(id: 2, content: "child", parentId: 1),
      makeTask(id: 3, content: "unrelated"),
    ]

    await service.deleteTask(repository.tasks[0])
    await settle()

    XCTAssertEqual(repository.tasks.map(\.id), [3])
    XCTAssertEqual(plugin.deleteTaskCalls, [1])
    XCTAssertEqual(host.obsidianReconcileCalls.count, 1)
  }

  func testDeleteRestoresTheSubtreeWhenTheServerRejectsIt() async {
    repository.tasks = [
      makeTask(id: 1, content: "parent"),
      makeTask(id: 2, content: "child", parentId: 1),
    ]
    plugin.deleteTaskResult = false

    await service.deleteTask(repository.tasks[0])
    await settle()

    XCTAssertEqual(repository.tasks.map(\.id), [1, 2])
    XCTAssertEqual(repository.errorMessage, "Failed to delete task.")
  }

  // MARK: - Recurrence

  /// Two open siblings share a title; only one of them is the occurrence we
  /// just created. Matching on content alone moved the recurrence rule onto
  /// whichever came first, so the series silently jumped to the wrong task.
  func testNextOccurrenceTransfersTheRuleToTheNewTaskNotASameTitledSibling() async throws {
    repository.tasks = [
      makeTask(id: 1, content: "water plants"),
      makeTask(id: 2, content: "water plants"),
    ]
    let completed = repository.tasks[0]
    host.recurrenceRules = [1: "every day"]
    host.nextOccurrenceDueDateString = "2026-08-14"

    await service.createNextOccurrence(for: completed)

    let newTask = try XCTUnwrap(
      repository.tasks.first { $0.id != 1 && $0.id != 2 },
      "a next occurrence should have been inserted")
    XCTAssertEqual(host.recurrenceRules[newTask.id], "every day")
    XCTAssertNil(host.recurrenceRules[1], "the completed task gives up its rule")
    XCTAssertNil(host.recurrenceRules[2], "the same-titled sibling must not inherit it")
  }

  func testNoRecurrenceRuleMeansNoNextOccurrenceAndNoErrorNoise() async {
    repository.tasks = [makeTask(id: 1, content: "one-off")]

    await service.createNextOccurrence(for: repository.tasks[0])

    XCTAssertEqual(repository.tasks.map(\.id), [1])
    XCTAssertNil(repository.errorMessage)
  }

  func testUncomputableNextOccurrenceReportsTheFailureForARecurringTask() async {
    repository.tasks = [makeTask(id: 1, content: "recurring")]
    host.recurrenceRules = [1: "gibberish"]
    host.nextOccurrenceDueDateString = nil

    await service.createNextOccurrence(for: repository.tasks[0])

    XCTAssertEqual(
      repository.errorMessage, "Could not calculate next occurrence for recurring task.")
  }

  // MARK: - Quick Add

  func testQuickAddRefusesSpecificModeUntilAParentTaskIsConfigured() {
    host.quickAddSpecificParentTaskId = nil

    XCTAssertFalse(service.beginQuickAddEntry(preferSpecificLocation: true))
    XCTAssertTrue(host.beginQuickAddCalls.isEmpty, "focus must be left alone")
    XCTAssertEqual(
      repository.errorMessage, "Set a valid Quick Add parent task ID in Preferences first.")
  }

  func testQuickAddFollowsTheConfiguredLocationModeWhenNotOverridden() {
    host.quickAddPrefersSpecificLocation = true
    host.quickAddSpecificParentTaskId = 99

    XCTAssertTrue(service.beginQuickAddEntry())
    XCTAssertEqual(host.beginQuickAddCalls, [true])
  }

  func testQuickAddSubmitCreatesUnderTheSpecificParentAndClosesTheEntryBar() async {
    host.quickAddSpecificParentTaskId = 99

    await service.submitQuickAddTask(content: "  inbox item  ", useSpecificLocation: true)

    XCTAssertEqual(plugin.createTaskCalls.count, 1)
    XCTAssertEqual(plugin.createTaskCalls.first?.content, "inbox item")
    XCTAssertEqual(plugin.createTaskCalls.first?.parentId, 99)
    XCTAssertEqual(host.finishQuickAddCallCount, 1)
  }

  /// Offline quick add has no refetch to surface the new task, so it has to
  /// insert the placeholder itself — otherwise the task the user just typed
  /// vanishes until the next reconnect.
  func testQuickAddWhileOfflineInsertsAPlaceholderAndQueuesTheCreate() async {
    repository.isNetworkReachable = false
    plugin.createTaskError = CheckvistSessionError.requestFailed

    await service.submitQuickAddTask(content: "inbox item", useSpecificLocation: false)

    XCTAssertEqual(repository.tasks.count, 1)
    XCTAssertEqual(repository.tasks.first?.content, "inbox item")
    XCTAssertEqual(repository.pendingTaskCreates.count, 1)
    XCTAssertEqual(host.finishQuickAddCallCount, 1)
  }

  // MARK: - Helpers

  /// Lets the unstructured `Task` that `deleteTask` spawns run to completion.
  private func settle() async {
    for _ in 0..<10 {
      await Task.yield()
    }
  }
}
