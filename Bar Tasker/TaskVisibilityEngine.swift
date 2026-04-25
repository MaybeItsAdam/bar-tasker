import Foundation

struct TaskVisibilityEngine {
  struct Context {
    let tasks: [CheckvistTask]
    let currentLevelTasks: [CheckvistTask]
    let currentParentId: Int
    let isSearchFilterActive: Bool
    let searchText: String
    let hideFuture: Bool
    let shouldShowRootScopeSection: Bool
    let isRootLevel: Bool
    let rootTaskView: RootTaskView
    let selectedRootDueBucket: RootDueBucket?
    let selectedRootTag: String
    let taskById: [Int: CheckvistTask]
    let isDescendant: (CheckvistTask, Int) -> Bool
    let taskMatchesActiveRootScope: (CheckvistTask) -> Bool
    let isAbsolutePrioritized: (CheckvistTask) -> Bool
    let compareByPriorityThenPosition: (CheckvistTask, CheckvistTask) -> Bool
    let compareByRootDueBucket: (CheckvistTask, CheckvistTask) -> Bool
    let hasAnyTag: (CheckvistTask) -> Bool
    let hasTag: (CheckvistTask, String) -> Bool
    let rootDueBucket: (CheckvistTask) -> RootDueBucket
  }

  struct Result {
    let tasks: [CheckvistTask]
    /// Index at which non-matching "remainder" tasks begin. nil when the view
    /// does not split matching / remainder.
    let remainderStartIndex: Int?
  }

  static func computeVisibleTasks(in context: Context) -> [CheckvistTask] {
    compute(in: context).tasks
  }

  static func compute(in context: Context) -> Result {
    if context.isSearchFilterActive {
      var matches = context.tasks.filter { task in
        task.content.localizedCaseInsensitiveContains(context.searchText)
          && context.isDescendant(task, context.currentParentId)
      }
      matches.sort(by: context.compareByPriorityThenPosition)
      return Result(tasks: matches, remainderStartIndex: nil)
    }

    let baseTasks: [CheckvistTask]
    if context.shouldShowRootScopeSection {
      if context.isRootLevel {
        switch context.rootTaskView {
        case .all, .due, .tags:
          // Keep root "All / Due / Tags" scoped to current-level siblings so
          // hierarchy + breadcrumb navigation stay stable while those tabs
          // reorder matches ahead of remainder.
          baseTasks = context.currentLevelTasks
        case .priority:
          // Priority view should surface prioritised subtasks from anywhere in
          // the list, even when browsing root.
          baseTasks = context.tasks
        case .kanban, .eisenhower:
          // Kanban has its own per-column task lists via tasksForKanbanColumn;
          // visibleTasks is unused in kanban mode, so return empty to prevent
          // any stale-index interaction with currentSiblingIndex.
          return Result(tasks: [], remainderStartIndex: nil)
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
          let matchesFilter: (CheckvistTask) -> Bool = { task in
            if let selectedRootDueBucket = context.selectedRootDueBucket {
              return context.rootDueBucket(task) == selectedRootDueBucket
            }
            return context.rootDueBucket(task) != .noDueDate
          }
          var matching = result.filter(matchesFilter)
          matching.sort(by: context.compareByRootDueBucket)
          return Result(tasks: matching, remainderStartIndex: nil)
        case .tags:
          let matchesFilter: (CheckvistTask) -> Bool = { task in
            if context.selectedRootTag.isEmpty { return context.hasAnyTag(task) }
            return context.hasTag(task, context.selectedRootTag)
          }
          var matching = result.filter(matchesFilter)
          matching.sort(by: context.compareByPriorityThenPosition)
          return Result(tasks: matching, remainderStartIndex: nil)
        case .priority:
          var matching = result.filter { context.taskMatchesActiveRootScope($0) }
          // When an ancestor is also prioritised, only show the ancestor at root.
          // Users can drill in to see prioritised descendants in that subtree.
          let prioritizedIds = Set(matching.map(\.id))
          matching = matching.filter { task in
            let taskIsAbsolute = context.isAbsolutePrioritized(task)
            var parentId = task.parentId ?? 0
            while parentId != 0 {
              if prioritizedIds.contains(parentId) {
                // Absolute priority can break out of a scoped-priority ancestor.
                if taskIsAbsolute,
                  let ancestor = context.taskById[parentId],
                  !context.isAbsolutePrioritized(ancestor)
                {
                  parentId = context.taskById[parentId]?.parentId ?? 0
                  continue
                }
                return false
              }
              parentId = context.taskById[parentId]?.parentId ?? 0
            }
            return true
          }
          matching.sort(by: context.compareByPriorityThenPosition)
          return Result(tasks: matching, remainderStartIndex: nil)
        case .kanban, .eisenhower:
          break  // unreachable — kanban returns [] above
        }
      } else {
        // Sub-level in a filtered root tab.
        switch context.rootTaskView {
        case .all, .kanban, .eisenhower:
          result.sort(by: context.compareByPriorityThenPosition)
        case .tags:
          var matching = result.filter(context.taskMatchesActiveRootScope)
          matching.sort(by: context.compareByPriorityThenPosition)
          return Result(tasks: matching, remainderStartIndex: nil)
        case .due, .priority:
          var matching = result.filter(context.taskMatchesActiveRootScope)
          matching.sort(by: context.compareByPriorityThenPosition)
          return Result(tasks: matching, remainderStartIndex: nil)
        }
      }
    } else {
      result.sort(by: context.compareByPriorityThenPosition)
    }
    return Result(tasks: result, remainderStartIndex: nil)
  }
}
