import sys

with open("Bar Tasker/BarTaskerCoordinator+TaskSync.swift", "r") as f:
    content = f.read()

content = content.replace("repository.checkvistSyncPlugin", "repository.activeSyncPlugin")

# Replace fetchTopTask start
start_str = "  @MainActor func fetchTopTask() async {"
end_str = "    errorMessage = nil\n\n    do {"

start_index = content.find(start_str)
end_index = content.find(end_str, start_index) + len(end_str)

new_start = """  @MainActor func fetchTopTask() async {
    if !isUsingOfflineStore && listId.isEmpty { return }

    errorMessage = nil

    do {"""

if start_index != -1 and end_index != -1:
    content = content[:start_index] + new_start + content[end_index:]

content = content.replace(
    "let offlineTasks = normalizeOfflineTasks(repository.localTaskStore.load().openTasks)",
    "let offlineTasks = try? await repository.offlineSyncPlugin.fetchOpenTasks(listId: \"\", credentials: activeCredentials) ?? []"
)
# Ensure the new offlineTasks is not an optional binding if we coalesce ?? []
content = content.replace(
    "let offlineTasks = try? await repository.offlineSyncPlugin.fetchOpenTasks(listId: \"\", credentials: activeCredentials) ?? []",
    "let offlineTasks = (try? await repository.offlineSyncPlugin.fetchOpenTasks(listId: \"\", credentials: activeCredentials)) ?? []"
)

with open("Bar Tasker/BarTaskerCoordinator+TaskSync.swift", "w") as f:
    f.write(content)
