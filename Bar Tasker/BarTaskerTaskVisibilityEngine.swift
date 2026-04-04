import Foundation

struct BarTaskerTaskVisibilityEngine {
  struct Context {
    let tasks: [CheckvistTask]
    let currentLevelTasks: [CheckvistTask]
    let currentParentId: Int
    let isSearchFilterActive: Bool
    let searchText: String
    let hideFuture: Bool
    let shouldShowRootScopeSection: Bool
    let isRootLevel: Bool
    let rootTaskView: BarTaskerManager.RootTaskView
    let selectedRootDueBucket: BarTaskerManager.RootDueBucket?
    let selectedRootTag: String
    let taskById: [Int: CheckvistTask]
    let isDescendant: (CheckvistTask, Int) -> Bool
    let taskMatchesActiveRootScope: (CheckvistTask) -> Bool
    let compareByPriorityThenPosition: (CheckvistTask, CheckvistTask) -> Bool
    let compareByRootDueBucket: (CheckvistTask, CheckvistTask) -> Bool
    let hasAnyTag: (CheckvistTask) -> Bool
    let hasTag: (CheckvistTask, String) -> Bool
    let rootDueBucket: (CheckvistTask) -> BarTaskerManager.RootDueBucket
  }

  static func computeVisibleTasks(in context: Context) -> [CheckvistTask] {
    if context.isSearchFilterActive {
      var matches = context.tasks.filter { task in
        task.content.localizedCaseInsensitiveContains(context.searchText)
          && context.isDescendant(task, context.currentParentId)
      }
      matches.sort(by: context.compareByPriorityThenPosition)
      return matches
    }

    let baseTasks: [CheckvistTask]
    if context.shouldShowRootScopeSection {
      if context.isRootLevel {
        switch context.rootTaskView {
        case .all:
          baseTasks = context.currentLevelTasks
        case .due, .tags, .priority, .kanban:
          baseTasks = context.tasks
        }
      } else {
        baseTasks = context.currentLevelTasks
      }
    } else {
      baseTasks = context.currentLevelTasks
    }

    var result = baseTasks
    if context.hideFuture {
      result = result.filter { task in
        guard let dueDate = task.dueDate else { return false }
        guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) else {
          return false
        }
        return dueDate <= Calendar.current.startOfDay(for: tomorrow)
      }
    }

    if context.shouldShowRootScopeSection {
      if context.isRootLevel {
        switch context.rootTaskView {
        case .all:
          result.sort(by: context.compareByPriorityThenPosition)
        case .due:
          if let selectedRootDueBucket = context.selectedRootDueBucket {
            result = result.filter { context.rootDueBucket($0) == selectedRootDueBucket }
          } else {
            result = result.filter { context.rootDueBucket($0) != .noDueDate }
          }
          result.sort(by: context.compareByRootDueBucket)
        case .tags:
          if context.selectedRootTag.isEmpty {
            result = result.filter(context.hasAnyTag)
          } else {
            result = result.filter { context.hasTag($0, context.selectedRootTag) }
          }
          result.sort(by: context.compareByPriorityThenPosition)
        case .priority:
          result = result.filter { context.taskMatchesActiveRootScope($0) }
          result.sort(by: context.compareByPriorityThenPosition)
        case .kanban:
          break
        }
      } else {
        if let parentTask = context.taskById[context.currentParentId],
          context.taskMatchesActiveRootScope(parentTask)
        {
          // Parent matches current scope: show all children.
        } else {
          result = result.filter(context.taskMatchesActiveRootScope)
        }
        result.sort(by: context.compareByPriorityThenPosition)
      }
    } else {
      result.sort(by: context.compareByPriorityThenPosition)
    }
    return result
  }
}
