import AppKit
import Foundation
import SwiftUI

/// `AppCoordinator`'s production conformance to the seams that
/// `TaskMutationService` and `SyncService` talk through.
///
/// This is deliberately the *only* app-only half of the split: everything here
/// is either a forward into a manager the coordinator already owns, or a piece
/// of genuinely UI-bound behaviour (haptics, the completion animation, the
/// kanban column maths, the recurrence rule store) that has no business in
/// `BarTaskerAppLogic`. The services themselves are now testable without it.

// MARK: - Shared

extension AppCoordinator: TaskServiceHost {
  var visibleTasks: [CheckvistTask] { taskListViewModel.visibleTasks }

  var currentSiblingIndex: Int {
    get { navigationState.currentSiblingIndex }
    set { navigationState.currentSiblingIndex = newValue }
  }

  func subtreeBlockRange(for taskId: Int, in tasks: [CheckvistTask]) -> Range<Int>? {
    taskListViewModel.subtreeBlockRange(for: taskId, in: tasks)
  }

  func reconcilePendingObsidianSyncQueue(openTaskIds: Set<Int>, listId: String) {
    integrations.reconcilePendingObsidianSyncQueueWithOpenTasks(
      openTaskIds: openTaskIds, listId: listId)
  }
}

// MARK: - TaskMutationHost

extension AppCoordinator: TaskMutationHost {
  var currentTask: CheckvistTask? { taskListViewModel.currentTask }

  var currentLevelTasks: [CheckvistTask] { taskListViewModel.currentLevelTasks }

  func isDescendant(_ task: CheckvistTask, of ancestorId: Int) -> Bool {
    taskListViewModel.isDescendant(task, of: ancestorId)
  }

  func clampSelectionToVisibleRange() {
    taskNavigationService.clampSelectionToVisibleRange()
  }

  var lastUndoableAction: UndoableAction? {
    get { undoService.lastAction }
    set { undoService.lastAction = newValue }
  }

  func fetchTopTask() async {
    await syncService.fetchTopTask()
  }

  var timerElapsedByTaskId: [Int: TimeInterval] {
    get { timer.timerByTaskId }
    set { timer.timerByTaskId = newValue }
  }

  var pendingObsidianSyncTaskIds: [Int] { integrations.pendingObsidianSyncTaskIds }

  func savePendingObsidianSyncQueue(_ taskIds: [Int], listId: String) {
    integrations.savePendingObsidianSyncQueue(taskIds, listId: listId)
  }

  func presentOnboardingDialogIfNeeded() {
    onboardingService.presentOnboardingDialogIfNeeded()
  }

  // MARK: Quick Add

  var quickAddPrefersSpecificLocation: Bool {
    preferences.quickAddLocationMode == .specificParentTask
  }

  var quickAddSpecificParentTaskId: Int? {
    preferences.quickAddSpecificParentTaskIdValue
  }

  func setQuickAddSpecificParentTask(id: Int) {
    preferences.quickAddSpecificParentTaskId = String(id)
    preferences.quickAddLocationMode = .specificParentTask
  }

  func beginQuickAddEntry(useSpecificLocation: Bool) {
    quickEntry.pendingDeleteConfirmation = false
    quickEntry.commandSuggestionIndex = 0
    quickEntry.quickEntryMode = useSpecificLocation ? .quickAddSpecific : .quickAddDefault
    quickEntry.quickEntryText = ""
    quickEntry.isQuickEntryFocused = true
  }

  func finishQuickAddEntry() {
    quickEntry.quickEntryMode = .search
    quickEntry.quickEntryText = ""
    quickEntry.isQuickEntryFocused = false
  }

  // MARK: Recurrence

  func nextOccurrence(for completedTask: CheckvistTask)
    -> (dueDateString: String, savedRule: String)?
  {
    recurrence.computeNextOccurrence(
      for: completedTask,
      parseDueDateString: RecurrenceManager.parseDueDateString
    )
  }

  func hasRecurrenceRule(forTaskId taskId: Int) -> Bool {
    guard let raw = recurrence.recurrenceRulesByTaskId[taskId] else { return false }
    return !raw.isEmpty
  }

  func transferRecurrenceRule(fromTaskId: Int, toTaskId: Int, rule: String) {
    recurrence.transferRule(from: fromTaskId, to: toTaskId, rule: rule)
  }

  func clearRecurrenceRule(forTaskId taskId: Int) {
    recurrence.recurrenceRulesByTaskId.removeValue(forKey: taskId)
  }

  // MARK: Completion feedback

  /// Multi-step haptic pattern for stronger tactile feedback, run alongside the
  /// strikethrough animation. Each sleep must propagate `CancellationError` so
  /// navigating away or switching tasks stops the sequence before the close
  /// fires — hence the `false` return, which tells the caller to abandon the
  /// mutation rather than send it late.
  func runTaskCompletionFeedback(taskId: Int) async -> Bool {
    do {
      NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
      try await Task.sleep(nanoseconds: 30_000_000)
      NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
      withAnimation(.spring(response: 0.28, dampingFraction: 0.45)) {
        quickEntry.completingTaskId = taskId
      }
      // Confirmation tap, around when the strikethrough finishes drawing.
      try await Task.sleep(nanoseconds: 100_000_000)
      NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
      // Brief hold so the strikethrough is perceptible without dragging out
      // removal.
      try await Task.sleep(nanoseconds: 80_000_000)
    } catch {
      withAnimation { quickEntry.completingTaskId = nil }
      return false
    }
    withAnimation { quickEntry.completingTaskId = nil }
    return true
  }
}

// MARK: - SyncHost

extension AppCoordinator: SyncHost {
  var taskMoveMode: TaskMoveMode {
    switch taskListViewModel.rootTaskView {
    case .priority: return .priorityQueue
    case .kanban: return .kanbanColumn
    case .due: return .dueDate
    case .all, .tags, .eisenhower: return .siblingPosition
    }
  }

  var currentParentId: Int {
    get { navigationState.currentParentId }
    set { navigationState.currentParentId = newValue }
  }

  var kanbanFilterParentId: Int? {
    get { kanban.kanbanFilterParentId }
    set { kanban.kanbanFilterParentId = newValue }
  }

  /// Purely visual reorder: writes only to the per-column manual-order overlay
  /// for whichever column currently hosts the task, never to its date,
  /// priority, or position.
  func moveTaskWithinKanbanColumn(taskId: Int, direction: Int) {
    let columns = kanban.kanbanColumns
    let hostingColumn = columns.first { column in
      kanban.tasksForKanbanColumn(column, allColumns: columns)
        .contains { $0.id == taskId }
    }
    guard let column = hostingColumn else { return }
    kanban.nudgeTaskInColumn(taskId: taskId, in: column, direction: direction)
  }

  func clampKanbanSelection() {
    kanban.clampKanbanSelection()
  }

  func clearKanbanSelection() {
    kanban.kanbanSelectedTaskId = nil
  }

  func clampFocusSessionForTasks(_ tasks: [CheckvistTask]) {
    focusSessionManager.clampForTasks(tasks)
  }

  func reconcileTimersAfterFetch(previousTasks: [CheckvistTask], openTasks: [CheckvistTask]) {
    let latestOpenTaskIDs = Set(openTasks.map(\.id))
    let previousTimerNodes = previousTasks.map {
      TimerNode(id: $0.id, parentId: $0.parentId)
    }
    timer.timerByTaskId = TimerElapsedReassignmentPolicy.remapElapsed(
      previousNodes: previousTimerNodes,
      latestOpenTaskIDs: latestOpenTaskIDs,
      elapsedByTaskID: timer.timerByTaskId
    )
    timer.stopTimerIfTaskRemoved(openTaskIds: latestOpenTaskIDs)
  }

  func markOnboardingCompleted() {
    onboardingService.onboardingCompleted = true
  }
}
