import re

with open("Bar Tasker/BarTaskerCoordinator.swift", "r") as f:
    content = f.read()

# Extract the block
pattern = r'(    self\.rootTaskView =\n      RootTaskView\(rawValue: preferencesStore\.int\(\.rootTaskView, default: 1\)\) \?\? \.due\n    self\.selectedRootDueBucketRawValue = preferencesStore\.int\(\n      \.selectedRootDueBucketRawValue, default: -1\)\n    self\.selectedRootTag = preferencesStore\.string\(\.selectedRootTag\)\n)'

match = re.search(pattern, content)
if match:
    block = match.group(1)
    # Remove from original location
    content = content.replace(block, "")
    
    # Insert at end of init
    insert_point = "    setupBindings()\n"
    content = content.replace(insert_point, block + "    setupBindings()\n")
    
    with open("Bar Tasker/BarTaskerCoordinator.swift", "w") as f:
        f.write(content)
else:
    print("Match not found!")
