import Foundation

/// The coordinator-shaped surface that `TaskMutationService` and `SyncService`
/// need, expressed without AppKit, SwiftUI, or any app-only model type.
///
/// Both services used to hold a `weak var coordinator: AppCoordinator?` and
/// reach through it into `taskListViewModel`, `quickEntry`, `kanban`, `timer`,
/// `integrations`, and friends. That made them impossible to compile — let
/// alone test — outside the Xcode app target, so the two files carrying the
/// optimistic-mutation and offline-replay logic had no unit coverage at all.
///
/// These protocols are the seam. Everything that genuinely needs the UI layer
/// (haptics, the completion animation, kanban column maths, the recurrence
/// rule store) is expressed as a *behaviour* the host performs rather than as a
/// manager object the service pokes at, so the services can move into
/// `BarTaskerAppLogic` and run against a test double. `AppCoordinator` provides
/// the production conformance in `AppCoordinator+ServiceHosts.swift`.
///
/// Neither service holds the host strongly: `AppCoordinator` owns the services,
/// so a strong back-reference would be a retain cycle.

// MARK: - Shared

/// How `SyncService.moveTask` should reorder, derived from the active root
/// view. Mirrors the app-only `RootTaskView` cases that behave differently:
/// `.all`, `.tags`, and `.eisenhower` all collapse to `.siblingPosition`.
enum TaskMoveMode: Equatable, Sendable {
  case priorityQueue
  case kanbanColumn
  case dueDate
  case siblingPosition
}

/// The parts of the host both services use. Kept separate from the two
/// service-specific protocols so a test double can conform once.
@MainActor
protocol TaskServiceHost: AnyObject {
  /// The task list as currently filtered and ordered for display.
  var visibleTasks: [CheckvistTask] { get }
  /// Index of the selected task within `visibleTasks`.
  var currentSiblingIndex: Int { get set }
  /// The contiguous span of `tasks` covering `taskId` and all its descendants,
  /// or `nil` when the task isn't present.
  func subtreeBlockRange(for taskId: Int, in tasks: [CheckvistTask]) -> Range<Int>?
  /// Drops queued Obsidian syncs whose task is no longer open.
  func reconcilePendingObsidianSyncQueue(openTaskIds: Set<Int>, listId: String)
}

// MARK: - TaskMutationService

@MainActor
protocol TaskMutationHost: TaskServiceHost {
  // Selection and tree shape.
  var currentTask: CheckvistTask? { get }
  var currentParentId: Int { get }
  var currentLevelTasks: [CheckvistTask] { get }
  func isDescendant(_ task: CheckvistTask, of ancestorId: Int) -> Bool
  func clampSelectionToVisibleRange()

  /// The single-step undo slot. Mutations claim it as they go.
  var lastUndoableAction: UndoableAction? { get set }

  /// Re-reads the list from the active sync plugin. Lives on the host because
  /// it belongs to `SyncService`, which is a sibling rather than a dependency.
  func fetchTopTask() async

  // Per-task accumulated timer values, snapshotted and restored alongside the
  // task list so a rolled-back deletion doesn't lose recorded time.
  var timerElapsedByTaskId: [Int: TimeInterval] { get set }

  // Obsidian sync queue, snapshotted for the same reason.
  var pendingObsidianSyncTaskIds: [Int] { get }
  func savePendingObsidianSyncQueue(_ taskIds: [Int], listId: String)

  /// Nudges the user toward list setup when a mutation fails for want of one.
  func presentOnboardingDialogIfNeeded()

  // Quick Add. The service decides *whether* entry can start; the host owns the
  // focus/mode/text fields that make it happen.
  var quickAddPrefersSpecificLocation: Bool { get }
  var quickAddSpecificParentTaskId: Int? { get }
  func setQuickAddSpecificParentTask(id: Int)
  func beginQuickAddEntry(useSpecificLocation: Bool)
  func finishQuickAddEntry()

  // Recurrence. Rules are keyed by task id and stored by the host, so the
  // service never has to know the `RecurrenceRule` type.
  func nextOccurrence(for completedTask: CheckvistTask)
    -> (dueDateString: String, savedRule: String)?
  func hasRecurrenceRule(forTaskId taskId: Int) -> Bool
  func transferRecurrenceRule(fromTaskId: Int, toTaskId: Int, rule: String)
  func clearRecurrenceRule(forTaskId taskId: Int)

  /// Runs the haptic + strikethrough sequence for a task the user just closed.
  /// Returns `false` when the sequence was cancelled (the user navigated away
  /// mid-animation), in which case the close must not be sent.
  func runTaskCompletionFeedback(taskId: Int) async -> Bool
}

// MARK: - SyncService

@MainActor
protocol SyncHost: TaskServiceHost {
  /// Which reorder strategy the active root view implies.
  var taskMoveMode: TaskMoveMode { get }
  /// Root scope cursor. `SyncService` resets it when the list changes or the
  /// kanban filter parent disappears.
  var currentParentId: Int { get set }

  // Kanban. Column membership and ordering are app-only concerns, so the host
  // takes the whole operation rather than exposing `KanbanColumn`.
  var kanbanFilterParentId: Int? { get set }
  func moveTaskWithinKanbanColumn(taskId: Int, direction: Int)
  func clampKanbanSelection()
  func clearKanbanSelection()

  func clampFocusSessionForTasks(_ tasks: [CheckvistTask])

  /// Carries accumulated timer values across a refetch (reassigning a closed
  /// task's time to its surviving parent) and stops the timer if its task is
  /// gone. Lives on the host because the reassignment policy is in
  /// `BarTaskerCore`, which `BarTaskerAppLogic` doesn't link.
  func reconcileTimersAfterFetch(previousTasks: [CheckvistTask], openTasks: [CheckvistTask])

  /// Marks first-run onboarding satisfied once a real list has loaded.
  func markOnboardingCompleted()

  /// Applies a content/due edit optimistically and syncs it in the background.
  func applyOptimisticMoveAndSync(task: CheckvistTask, content: String?, due: String?)
}
