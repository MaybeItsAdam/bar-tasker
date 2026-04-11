import re

with open("Bar Tasker/BarTaskerCoordinator+TaskSync.swift", "r") as f:
    content = f.read()

# Replace `checkvistSyncPlugin` with `activeSyncPlugin`
content = content.replace("repository.checkvistSyncPlugin", "repository.activeSyncPlugin")

# Replace `fetchTopTask`
# It starts at `  @MainActor func fetchTopTask() async {`
# And we want to remove the `isUsingOfflineStore` block and the guard listId.isEmpty.
old_fetch_start = r"""  @MainActor func fetchTopTask\(\) async \{
    if isUsingOfflineStore \{
      errorMessage = nil
      let payload = repository\.localTaskStore\.load\(\)
      tasks = normalizeOfflineTasks\(payload\.openTasks\)
      repository\.offlineArchivedTasksById = Dictionary\(
        uniqueKeysWithValues: payload\.archivedTasks\.map \{ \(\$0\.id, \$0\) \}\)
      let maxKnownTaskId = max\(
        tasks\.map\(\\\.id\)\.max\(\) \?\? 0,
        payload\.archivedTasks\.map\(\\\.id\)\.max\(\) \?\? 0
      \)
      repository\.nextOfflineTaskIdValue = max\(payload\.nextTaskId, maxKnownTaskId \+ 1, 1\)
      reconcilePriorityQueueWithOpenTasks\(\)
      reconcilePendingObsidianSyncQueueWithOpenTasks\(\)
      clampSelectionToVisibleRange\(\)
      timer\.stopTimerIfTaskRemoved\(openTaskIds: Set\(tasks\.map\(\\\.id\)\)\)
      return
    \}

    guard \!listId\.isEmpty else \{ return \}"""

new_fetch_start = """  @MainActor func fetchTopTask() async {
    if !isUsingOfflineStore && listId.isEmpty { return }"""

content = re.sub(old_fetch_start, new_fetch_start, content)

# also fix line 208 error: `normalizeOfflineTasks` in `hasTasksToSyncToObsidian`
# The line is `let offlineTasks = normalizeOfflineTasks(repository.localTaskStore.load().openTasks)`
# Wait, let's see what that function is doing.
