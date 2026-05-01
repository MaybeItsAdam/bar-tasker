import XCTest

@testable import BarTaskerAppLogic

/// Documents which `TaskRepository` mutations fire `onCacheRelevantChange` and
/// — critically — which mutations *should* but currently do not. The known-failing
/// cases are wrapped with `XCTExpectFailure` so the suite stays green; flipping
/// them to passing is part of Phase 2 (unify cache invalidation).
@MainActor
final class TaskRepositoryCacheInvalidationTests: XCTestCase {
  private var defaults: UserDefaults!
  private var repo: TaskRepository!
  private var fired = 0

  override func setUp() async throws {
    try await super.setUp()
    defaults = makeIsolatedDefaults()
    let preferencesStore = PreferencesStore(defaults: defaults)
    let localTaskStore = LocalTaskStore(defaults: defaults)
    repo = TaskRepository(
      preferencesStore: preferencesStore,
      checkvistSyncPlugin: FakeCheckvistSyncPlugin(),
      localTaskStore: localTaskStore,
      initialRemoteKey: "",
      defaults: defaults
    )
    fired = 0
    repo.onCacheRelevantChange = { [weak self] in self?.fired += 1 }
  }

  // MARK: Hooks that fire today

  func testMutatingTasksFiresInvalidation() {
    repo.tasks = [makeTask(id: 1)]
    XCTAssertEqual(fired, 1)
  }

  func testMutatingPriorityTaskIdsByParentIdFiresInvalidation() {
    repo.priorityTaskIdsByParentId = [0: [1, 2]]
    XCTAssertEqual(fired, 1)
  }

  func testMutatingAbsolutePriorityTaskIdsFiresInvalidation() {
    repo.absolutePriorityTaskIds = [1, 2]
    XCTAssertEqual(fired, 1)
  }

  func testMutatingTaskEisenhowerLevelsFiresInvalidation() {
    repo.taskEisenhowerLevels = [1: EisenhowerLevel(urgency: 0.5, importance: 0.5)]
    XCTAssertEqual(fired, 1)
  }

  // MARK: Known gaps — Phase 2 should make these pass

  func testMutatingAvailableListsShouldFireInvalidation() {
    XCTExpectFailure(
      """
      `availableLists` has no didSet, so the cache invalidation hook never fires
      when the user fetches a new set of lists. UI that depends on this slice
      (SettingsView, connection state) can render stale data until something
      else triggers a rebuild. Phase 2 of the architecture plan should add
      a didSet that calls onCacheRelevantChange.
      """
    )
    repo.availableLists = [
      CheckvistList(id: 1, name: "Inbox", archived: false, readOnly: false)
    ]
    XCTAssertEqual(fired, 1)
  }

  func testMutatingIsNetworkReachableShouldFireInvalidation() {
    XCTExpectFailure(
      """
      `isNetworkReachable` has no didSet. Offline→online transitions don't trigger
      cache invalidation, so the UI relies on poll/explicit-sync calls to notice
      connectivity returning. Phase 2 should wire this through the same hook.
      """
    )
    repo.isNetworkReachable = false
    XCTAssertEqual(fired, 1)
  }
}
