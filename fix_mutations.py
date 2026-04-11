import sys

def remove_offline_blocks(content):
    while True:
        idx = content.find("if isUsingOfflineStore {")
        if idx == -1:
            break
        
        # We need to find the matching closing brace
        brace_count = 0
        in_string = False
        escape = False
        end_idx = -1
        
        # Start searching from the opening brace
        start_search = content.find("{", idx)
        for i in range(start_search, len(content)):
            char = content[i]
            if escape:
                escape = False
                continue
            if char == '\\':
                escape = True
                continue
            if char == '"':
                in_string = not in_string
                continue
                
            if not in_string:
                if char == '{':
                    brace_count += 1
                elif char == '}':
                    brace_count -= 1
                    if brace_count == 0:
                        end_idx = i
                        break
        
        if end_idx != -1:
            # Also remove preceding whitespace
            start_remove = idx
            while start_remove > 0 and content[start_remove-1] in [' ', '\t']:
                start_remove -= 1
            
            # Remove from start_remove to end_idx + 1
            content = content[:start_remove] + content[end_idx+1:]
            
            # Remove any trailing newlines if it leaves empty lines
            if content.startswith('\n', start_remove):
                content = content[:start_remove] + content[start_remove+1:]
        else:
            break
            
    return content

files_to_fix = [
    "Bar Tasker/BarTaskerCoordinator+TaskMutations.swift",
    "Bar Tasker/BarTaskerCoordinator+ReorderingAndTiming.swift",
    "Bar Tasker/BarTaskerCoordinator+QuickAdd.swift"
]

for path in files_to_fix:
    with open(path, "r") as f:
        content = f.read()
    
    content = content.replace("repository.checkvistSyncPlugin", "repository.activeSyncPlugin")
    content = remove_offline_blocks(content)
    
    # Also remove: `let snapshot = isUsingOfflineStore ? offlineStateSnapshot() : nil`
    content = content.replace("let snapshot = isUsingOfflineStore ? offlineStateSnapshot() : nil\n", "")
    
    with open(path, "w") as f:
        f.write(content)
