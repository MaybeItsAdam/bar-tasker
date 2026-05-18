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
/// The service holds a `weak` reference to `AppCoordinator` because the
/// view-switch logic reaches into `currentTask`, `visibleTasks`, and other
/// derived properties that today still live on the coordinator. That coupling
/// is expected to dissolve as later steps in Phase 3 push more state ownership
/// down; the weak ref is the same composition pattern as `LifecycleController`
/// and `UndoService`.
@MainActor
final class TaskNavigationService {
  private weak var coordinator: AppCoordinator?
  private let logic = TaskNavigationCoordinator()

  init(coordinator: AppCoordinator) {
    self.coordinator = coordinator
  }

  // MARK: - Movement

  func nextTask() {
    guard let coordinator else { return }
    guard
      let nextIndex = logic.nextSiblingIndex(
        currentSiblingIndex: coordinator.currentSiblingIndex,
        visibleCount: coordinator.visibleTasks.count)
    else { return }
    coordinator.currentSiblingIndex = nextIndex
  }

  func previousTask() {
    guard let coordinator else { return }
    guard
      let previousIndex = logic.previousSiblingIndex(
        currentSiblingIndex: coordinator.currentSiblingIndex,
        visibleCount: coordinator.visibleTasks.count)
    else { return }
    coordinator.currentSiblingIndex = previousIndex
  }

  func enterChildren() {
    guard let coordinator else { return }
    guard
      let selection = logic.enterChildren(
        currentTask: coordinator.currentTask,
        childCount: coordinator.currentTaskChildren.count)
    else { return }
    coordinator.rootScopeFocusLevel = selection.rootScopeFocusLevel
    coordinator.currentParentId = selection.currentParentId
    coordinator.currentSiblingIndex = selection.currentSiblingIndex
  }

  func exitToParent() {
    guard let coordinator else { return }
    guard
      let selection = logic.exitToParent(
        currentParentId: coordinator.currentParentId,
        tasks: coordinator.tasks)
    else { return }
    coordinator.rootScopeFocusLevel = selection.rootScopeFocusLevel
    coordinator.currentParentId = selection.currentParentId
    coordinator.currentSiblingIndex = selection.currentSiblingIndex
  }

  func navigate(to task: CheckvistTask) {
    guard let coordinator else { return }
    let selection = logic.navigate(to: task, tasks: coordinator.tasks)
    coordinator.rootScopeFocusLevel = selection.rootScopeFocusLevel
    coordinator.currentParentId = selection.currentParentId
    coordinator.currentSiblingIndex = selection.currentSiblingIndex
  }

  func clampSelectionToVisibleRange() {
    guard let coordinator else { return }
    coordinator.focusSessionManager.clampForTasks(coordinator.tasks)
    if coordinator.rootTaskView == .kanban {
      coordinator.kanban.clampKanbanSelection()
      return
    }
    let maxIndex = max(coordinator.visibleTasks.count - 1, 0)
    if coordinator.currentSiblingIndex > maxIndex {
      coordinator.currentSiblingIndex = maxIndex
    }
  }

  // MARK: - Root-task view switching

  func setRootTaskView(_ view: RootTaskView) {
    guard let coordinator else { return }

    // Capture tree position BEFORE changing rootTaskView — `currentTask`
    // dispatches on `rootTaskView` and would otherwise return the kanban
    // selection, not the task the user had highlighted in the source view.
    let capturedParentId = coordinator.currentParentId
    let capturedTask = coordinator.currentTask
    coordinator.rootTaskView = view

    // Preserve drill-in across view switches. Previously we reset
    // currentParentId to 0 which lost the user's subtask scope whenever they
    // flipped tabs. Try to keep the same task selected by re-finding it in
    // the new view.
    if let task = capturedTask,
      let newIndex = coordinator.visibleTasks.firstIndex(where: { $0.id == task.id })
    {
      coordinator.currentSiblingIndex = newIndex
    } else {
      coordinator.currentSiblingIndex = 0
    }
    if view != .due {
      coordinator.selectedRootDueBucket = nil
    }
    if view != .tags {
      coordinator.selectedRootTag = ""
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
      coordinator.rootScopeFocusLevel > 1
    {
      coordinator.rootScopeFocusLevel = 1
    }
  }

  func cycleRootTaskView(direction: Int) {
    guard let coordinator else { return }
    let allViews = coordinator.orderedRootTaskViews
    guard let currentIndex = allViews.firstIndex(of: coordinator.rootTaskView) else { return }
    let nextIndex = max(0, min(allViews.count - 1, currentIndex + direction))
    guard nextIndex != currentIndex else { return }
    setRootTaskView(allViews[nextIndex])
  }

  func cycleRootScopeFilter(direction: Int) {
    guard let coordinator else { return }
    guard coordinator.shouldShowRootScopeSection else { return }
    switch coordinator.rootTaskView {
    case .all, .priority, .eisenhower, .kanban:
      return
    case .due:
      let options: [RootDueBucket?] = [nil] + RootDueBucket.allCases.filter { $0 != .noDueDate }
      guard
        let currentIndex = options.firstIndex(where: { $0 == coordinator.selectedRootDueBucket })
      else {
        coordinator.selectedRootDueBucket = nil
        coordinator.currentSiblingIndex = 0
        return
      }
      let nextIndex = max(0, min(options.count - 1, currentIndex + direction))
      coordinator.selectedRootDueBucket = options[nextIndex]
      coordinator.currentSiblingIndex = 0
    case .tags:
      let tags = coordinator.rootLevelTagNames(limit: 30)
      let options = [""] + tags
      guard let currentIndex = options.firstIndex(of: coordinator.selectedRootTag) else {
        coordinator.selectedRootTag = ""
        coordinator.currentSiblingIndex = 0
        return
      }
      let nextIndex = max(0, min(options.count - 1, currentIndex + direction))
      coordinator.selectedRootTag = options[nextIndex]
      coordinator.currentSiblingIndex = 0
    }
  }

  func selectRootScopeFilter(at index: Int) {
    guard let coordinator else { return }
    guard coordinator.shouldShowRootScopeSection, index >= 0 else { return }
    switch coordinator.rootTaskView {
    case .all, .priority, .eisenhower, .kanban:
      return
    case .due:
      let options: [RootDueBucket?] = [nil] + RootDueBucket.allCases.filter { $0 != .noDueDate }
      guard options.indices.contains(index) else { return }
      coordinator.selectedRootDueBucket = options[index]
      coordinator.currentSiblingIndex = 0
      coordinator.rootScopeFocusLevel = 2
    case .tags:
      let options = [""] + coordinator.rootLevelTagNames(limit: 30)
      guard options.indices.contains(index) else { return }
      coordinator.selectedRootTag = options[index]
      coordinator.currentSiblingIndex = 0
      coordinator.rootScopeFocusLevel = 2
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
        coordinator.currentSiblingIndex = 0
        break
      }
    }
  }
}
