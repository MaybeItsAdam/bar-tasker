import Foundation

/// Owns the imperative side of navigation: moving the cursor between siblings,
/// drilling in/out of subtrees, and switching root-task views (All / Due /
/// Tags / Priority / Kanban / Eisenhower) with the surrounding state-restoration
/// logic that those view switches require.
///
/// Pairs with the pure-logic `TaskNavigationCoordinator` struct (which lives
/// in `BarTaskerAppLogic` so it can be unit-tested): the struct returns
/// `TaskNavigationSelection` outcomes for movement intents, and this service
/// applies those outcomes to the live `NavigationState` / managers.
///
/// Owns its raw navigation dependencies directly: cursor state
/// (`NavigationState`) and the task list (`TaskRepository`). It still keeps a
/// `weak` reference to `AppCoordinator` for the *derived* properties that today
/// only the coordinator computes (`currentTask`, `visibleTasks`,
/// `currentTaskChildren`, `rootLevelTagNames`, `shouldShowRootScopeSection`).
/// As those derivations move down onto `TaskListViewModel`, the coordinator
/// reference shrinks toward nothing. The weak ref is the same composition
/// pattern as `LifecycleController` and `UndoService`.
@MainActor
final class TaskNavigationService {
  private weak var coordinator: AppCoordinator?
  private let repository: TaskRepository
  private let navigationState: NavigationState
  private let logic = TaskNavigationCoordinator()

  init(
    coordinator: AppCoordinator,
    repository: TaskRepository,
    navigationState: NavigationState
  ) {
    self.coordinator = coordinator
    self.repository = repository
    self.navigationState = navigationState
  }

  // MARK: - Movement

  func nextTask() {
    guard let coordinator else { return }
    guard
      let nextIndex = logic.nextSiblingIndex(
        currentSiblingIndex: navigationState.currentSiblingIndex,
        visibleCount: coordinator.visibleTasks.count)
    else { return }
    navigationState.currentSiblingIndex = nextIndex
  }

  func previousTask() {
    guard let coordinator else { return }
    guard
      let previousIndex = logic.previousSiblingIndex(
        currentSiblingIndex: navigationState.currentSiblingIndex,
        visibleCount: coordinator.visibleTasks.count)
    else { return }
    navigationState.currentSiblingIndex = previousIndex
  }

  func enterChildren() {
    guard let coordinator else { return }
    guard
      let selection = logic.enterChildren(
        currentTask: coordinator.currentTask,
        childCount: coordinator.currentTaskChildren.count)
    else { return }
    navigationState.rootScopeFocusLevel = selection.rootScopeFocusLevel
    navigationState.currentParentId = selection.currentParentId
    navigationState.currentSiblingIndex = selection.currentSiblingIndex
  }

  func exitToParent() {
    guard
      let selection = logic.exitToParent(
        currentParentId: navigationState.currentParentId,
        tasks: repository.tasks)
    else { return }
    navigationState.rootScopeFocusLevel = selection.rootScopeFocusLevel
    navigationState.currentParentId = selection.currentParentId
    navigationState.currentSiblingIndex = selection.currentSiblingIndex
  }

  func navigate(to task: CheckvistTask) {
    let selection = logic.navigate(to: task, tasks: repository.tasks)
    navigationState.rootScopeFocusLevel = selection.rootScopeFocusLevel
    navigationState.currentParentId = selection.currentParentId
    navigationState.currentSiblingIndex = selection.currentSiblingIndex
  }

  func clampSelectionToVisibleRange() {
    guard let coordinator else { return }
    coordinator.focusSessionManager.clampForTasks(repository.tasks)
    if coordinator.taskListViewModel.rootTaskView == .kanban {
      coordinator.kanban.clampKanbanSelection()
      return
    }
    let maxIndex = max(coordinator.visibleTasks.count - 1, 0)
    if navigationState.currentSiblingIndex > maxIndex {
      navigationState.currentSiblingIndex = maxIndex
    }
  }

  // MARK: - Root-task view switching

  func setRootTaskView(_ view: RootTaskView) {
    guard let coordinator else { return }

    // Capture tree position BEFORE changing rootTaskView — `currentTask`
    // dispatches on `rootTaskView` and would otherwise return the kanban
    // selection, not the task the user had highlighted in the source view.
    let capturedParentId = navigationState.currentParentId
    let capturedTask = coordinator.currentTask
    coordinator.taskListViewModel.rootTaskView = view

    // Preserve drill-in across view switches. Previously we reset
    // currentParentId to 0 which lost the user's subtask scope whenever they
    // flipped tabs. Try to keep the same task selected by re-finding it in
    // the new view.
    if let task = capturedTask,
      let newIndex = coordinator.visibleTasks.firstIndex(where: { $0.id == task.id })
    {
      navigationState.currentSiblingIndex = newIndex
    } else {
      navigationState.currentSiblingIndex = 0
    }
    if view != .due {
      coordinator.taskListViewModel.selectedRootDueBucket = nil
    }
    if view != .tags {
      coordinator.taskListViewModel.selectedRootTag = ""
    }
    if view != .kanban {
      coordinator.kanban.kanbanFilterSubtasks = false
      coordinator.kanban.kanbanFilterParentId = nil
    } else {
      restoreKanbanSelection(
        capturedParentId: capturedParentId,
        capturedTask: capturedTask,
        on: coordinator
      )
    }
    if !(view == .due || view == .tags || view == .kanban),
      navigationState.rootScopeFocusLevel > 1
    {
      navigationState.rootScopeFocusLevel = 1
    }
  }

  func cycleRootTaskView(direction: Int) {
    guard let coordinator else { return }
    let allViews = coordinator.orderedRootTaskViews
    guard let currentIndex = allViews.firstIndex(of: coordinator.taskListViewModel.rootTaskView) else { return }
    let nextIndex = max(0, min(allViews.count - 1, currentIndex + direction))
    guard nextIndex != currentIndex else { return }
    setRootTaskView(allViews[nextIndex])
  }

  func cycleRootScopeFilter(direction: Int) {
    guard let coordinator else { return }
    guard coordinator.shouldShowRootScopeSection else { return }
    switch coordinator.taskListViewModel.rootTaskView {
    case .all, .priority, .eisenhower, .kanban:
      return
    case .due:
      let options: [RootDueBucket?] = [nil] + RootDueBucket.allCases.filter { $0 != .noDueDate }
      guard
        let currentIndex = options.firstIndex(where: { $0 == coordinator.taskListViewModel.selectedRootDueBucket })
      else {
        coordinator.taskListViewModel.selectedRootDueBucket = nil
        navigationState.currentSiblingIndex = 0
        return
      }
      let nextIndex = max(0, min(options.count - 1, currentIndex + direction))
      coordinator.taskListViewModel.selectedRootDueBucket = options[nextIndex]
      navigationState.currentSiblingIndex = 0
    case .tags:
      let tags = coordinator.rootLevelTagNames(limit: 30)
      let options = [""] + tags
      guard let currentIndex = options.firstIndex(of: coordinator.taskListViewModel.selectedRootTag) else {
        coordinator.taskListViewModel.selectedRootTag = ""
        navigationState.currentSiblingIndex = 0
        return
      }
      let nextIndex = max(0, min(options.count - 1, currentIndex + direction))
      coordinator.taskListViewModel.selectedRootTag = options[nextIndex]
      navigationState.currentSiblingIndex = 0
    }
  }

  func selectRootScopeFilter(at index: Int) {
    guard let coordinator else { return }
    guard coordinator.shouldShowRootScopeSection, index >= 0 else { return }
    switch coordinator.taskListViewModel.rootTaskView {
    case .all, .priority, .eisenhower, .kanban:
      return
    case .due:
      let options: [RootDueBucket?] = [nil] + RootDueBucket.allCases.filter { $0 != .noDueDate }
      guard options.indices.contains(index) else { return }
      coordinator.taskListViewModel.selectedRootDueBucket = options[index]
      navigationState.currentSiblingIndex = 0
      navigationState.rootScopeFocusLevel = 2
    case .tags:
      let options = [""] + coordinator.rootLevelTagNames(limit: 30)
      guard options.indices.contains(index) else { return }
      coordinator.taskListViewModel.selectedRootTag = options[index]
      navigationState.currentSiblingIndex = 0
      navigationState.rootScopeFocusLevel = 2
    }
  }

  // MARK: - Helpers

  /// Propagates the user's tree position into the kanban filter when entering
  /// the kanban view, then validates / repairs the kanban selection. Extracted
  /// from `setRootTaskView` to keep that method's branching readable.
  private func restoreKanbanSelection(
    capturedParentId: Int,
    capturedTask: CheckvistTask?,
    on coordinator: AppCoordinator
  ) {
    let kanban = coordinator.kanban
    let inheritedParentId: Int? = capturedParentId == 0 ? nil : capturedParentId
    kanban.kanbanFilterParentId = inheritedParentId
    kanban.kanbanFilterSubtasks = false
    if let task = capturedTask {
      kanban.kanbanSelectedTaskId = task.id
    }

    // Validate the selection against ALL columns, not just the focused one,
    // because the task may have moved while we were in another view.
    let cols = kanban.kanbanColumns
    var selectionValidInColumn: Int?
    if let selectedId = kanban.kanbanSelectedTaskId {
      for (idx, col) in cols.enumerated() {
        let colTasks = kanban.tasksForKanbanColumn(col, allColumns: cols)
        if colTasks.contains(where: { $0.id == selectedId }) {
          selectionValidInColumn = idx
          break
        }
      }
    }
    if let validIdx = selectionValidInColumn {
      kanban.kanbanFocusedColumnIndex = validIdx
      return
    }

    // Selection is stale — find the first non-empty column and select its
    // first task.
    kanban.kanbanSelectedTaskId = nil
    for (idx, col) in cols.enumerated() {
      let colTasks = kanban.tasksForKanbanColumn(col, allColumns: cols)
      if let firstTask = colTasks.first {
        kanban.kanbanFocusedColumnIndex = idx
        kanban.kanbanSelectedTaskId = firstTask.id
        navigationState.currentSiblingIndex = 0
        break
      }
    }
  }
}
