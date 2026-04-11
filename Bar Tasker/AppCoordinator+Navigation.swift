import Foundation

extension AppCoordinator {
  // MARK: - Navigation

  @MainActor func nextTask() {
    guard
      let nextIndex = repository.navigationCoordinator.nextSiblingIndex(
        currentSiblingIndex: currentSiblingIndex,
        visibleCount: visibleTasks.count)
    else { return }
    currentSiblingIndex = nextIndex
  }

  @MainActor func previousTask() {
    guard
      let previousIndex = repository.navigationCoordinator.previousSiblingIndex(
        currentSiblingIndex: currentSiblingIndex,
        visibleCount: visibleTasks.count)
    else { return }
    currentSiblingIndex = previousIndex
  }

  /// Navigate into the current task's children
  @MainActor func enterChildren() {
    guard
      let selection = repository.navigationCoordinator.enterChildren(
        currentTask: currentTask,
        childCount: currentTaskChildren.count)
    else { return }
    rootScopeFocusLevel = selection.rootScopeFocusLevel
    currentParentId = selection.currentParentId
    currentSiblingIndex = selection.currentSiblingIndex
  }

  /// Navigate back up to the parent level
  @MainActor func exitToParent() {
    guard
      let selection = repository.navigationCoordinator.exitToParent(
        currentParentId: currentParentId,
        tasks: tasks)
    else { return }
    rootScopeFocusLevel = selection.rootScopeFocusLevel
    currentParentId = selection.currentParentId
    currentSiblingIndex = selection.currentSiblingIndex
  }

  @MainActor func navigateTo(task: CheckvistTask) {
    let selection = repository.navigationCoordinator.navigate(to: task, tasks: tasks)
    rootScopeFocusLevel = selection.rootScopeFocusLevel
    currentParentId = selection.currentParentId
    currentSiblingIndex = selection.currentSiblingIndex
  }

  @MainActor func clampSelectionToVisibleRange() {
    if rootTaskView == .kanban {
      kanban.clampKanbanSelection()
      return
    }
    let maxIndex = max(visibleTasks.count - 1, 0)
    if currentSiblingIndex > maxIndex {
      currentSiblingIndex = maxIndex
    }
  }
}
