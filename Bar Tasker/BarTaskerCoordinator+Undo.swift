import Foundation

extension BarTaskerCoordinator {
  // MARK: - Undo Execution

  @MainActor func undoLastAction() async {
    guard let action = lastUndo else { return }
    lastUndo = nil

    switch action {
    case .restoreOfflineState(let snapshot):
      restoreOfflineState(snapshot)
    case .add(let taskId):
      let mockTask = CheckvistTask(
        id: taskId, content: "", status: 0, due: nil, position: nil, parentId: nil, level: nil)
      await deleteTask(mockTask, isUndo: true)
    case .markDone(let taskId), .invalidate(let taskId):
      let mockTask = CheckvistTask(
        id: taskId, content: "", status: 1, due: nil, position: nil, parentId: nil, level: nil)
      await taskAction(mockTask, endpoint: "reopen", isUndo: true)
    case .update(let taskId, let oldContent, let oldDue):
      let mockTask = CheckvistTask(
        id: taskId, content: "", status: 0, due: nil, position: nil, parentId: nil, level: nil)
      await updateTask(task: mockTask, content: oldContent, due: oldDue, isUndo: true)
    }
  }
}
