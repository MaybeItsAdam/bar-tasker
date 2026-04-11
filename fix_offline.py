import re

with open("Bar Tasker/BarTaskerCoordinator+TaskMutations.swift", "r") as f:
    content = f.read()

# Replace repository.checkvistSyncPlugin with repository.activeSyncPlugin
content = content.replace("repository.checkvistSyncPlugin", "repository.activeSyncPlugin")

# 1. taskAction
# We need to remove the whole `if isUsingOfflineStore { ... return \n    }` block.
content = re.sub(r'    if isUsingOfflineStore \{\n.*?(?=\n    if !isUndo \{)', '', content, flags=re.DOTALL)

# 2. updateTask
content = re.sub(r'    if isUsingOfflineStore \{\n.*?(?=\n    if !isUndo \{)', '', content, flags=re.DOTALL)

# 3. addTask
content = re.sub(r'    if isUsingOfflineStore \{\n.*?(?=\n    guard !listId\.isEmpty else \{)', '', content, flags=re.DOTALL)

# 4. addSubtask
content = re.sub(r'    if isUsingOfflineStore \{\n.*?(?=\n    guard !listId\.isEmpty else \{)', '', content, flags=re.DOTALL)

# 5. deleteTask
content = re.sub(r'    if isUsingOfflineStore \{\n.*?(?=\n    let optimisticSnapshot: OptimisticCompletionSnapshot\?)', '', content, flags=re.DOTALL)

with open("Bar Tasker/BarTaskerCoordinator+TaskMutations.swift", "w") as f:
    f.write(content)

with open("Bar Tasker/BarTaskerCoordinator+ReorderingAndTiming.swift", "r") as f:
    content2 = f.read()

content2 = content2.replace("repository.checkvistSyncPlugin", "repository.activeSyncPlugin")
content2 = re.sub(r'    let snapshot = isUsingOfflineStore \? offlineStateSnapshot\(\) : nil\n', '', content2, flags=re.DOTALL)
content2 = re.sub(r'    if isUsingOfflineStore \{\n.*?return\n    \}\n\n', '', content2, flags=re.DOTALL)

with open("Bar Tasker/BarTaskerCoordinator+ReorderingAndTiming.swift", "w") as f:
    f.write(content2)

with open("Bar Tasker/BarTaskerCoordinator+QuickAdd.swift", "r") as f:
    content3 = f.read()
content3 = content3.replace("repository.checkvistSyncPlugin", "repository.activeSyncPlugin")
content3 = re.sub(r'    if isUsingOfflineStore \{\n.*?return\n      \}\n    \} else \{\n', '    if true {\n', content3, flags=re.DOTALL)

with open("Bar Tasker/BarTaskerCoordinator+QuickAdd.swift", "w") as f:
    f.write(content3)
