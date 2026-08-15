import Foundation

struct TaskNavigationSelection {
  let rootScopeFocusLevel: Int
  let currentParentId: Int
  let currentSiblingIndex: Int
}

struct TaskNavigationCoordinator {
  func nextSiblingIndex(currentSiblingIndex: Int, visibleCount: Int) -> Int? {
    guard visibleCount > 0 else { return nil }
    let clampedIndex = min(max(currentSiblingIndex, 0), visibleCount - 1)
    return (clampedIndex + 1) % visibleCount
  }

  func previousSiblingIndex(currentSiblingIndex: Int, visibleCount: Int) -> Int? {
    guard visibleCount > 0 else { return nil }
    let clampedIndex = min(max(currentSiblingIndex, 0), visibleCount - 1)
    return (clampedIndex - 1 + visibleCount) % visibleCount
  }

  func enterChildren(currentTask: CheckvistTask?, childCount: Int) -> TaskNavigationSelection? {
    guard let currentTask, childCount > 0 else { return nil }
    return TaskNavigationSelection(
      rootScopeFocusLevel: 0, currentParentId: currentTask.id, currentSiblingIndex: 0)
  }

  func exitToParent(currentParentId: Int, tasks: [CheckvistTask]) -> TaskNavigationSelection? {
    guard currentParentId != 0 else { return nil }

    guard let parent = tasks.first(where: { $0.id == currentParentId }) else {
      return TaskNavigationSelection(
        rootScopeFocusLevel: 0, currentParentId: 0, currentSiblingIndex: 0)
    }

    let grandparentId = parent.parentId ?? 0
    let siblings = tasks.filter { ($0.parentId ?? 0) == grandparentId }
    let siblingIndex = siblings.firstIndex(where: { $0.id == parent.id }) ?? 0
    return TaskNavigationSelection(
      rootScopeFocusLevel: 0,
      currentParentId: grandparentId,
      currentSiblingIndex: siblingIndex
    )
  }

  func navigate(to task: CheckvistTask, tasks: [CheckvistTask]) -> TaskNavigationSelection {
    let parentId = task.parentId ?? 0
    let siblings = tasks.filter { ($0.parentId ?? 0) == parentId }
    let siblingIndex = siblings.firstIndex(where: { $0.id == task.id }) ?? 0
    return TaskNavigationSelection(
      rootScopeFocusLevel: 0,
      currentParentId: parentId,
      currentSiblingIndex: siblingIndex
    )
  }
}
