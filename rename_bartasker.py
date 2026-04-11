import os
import re

directory = "Bar Tasker"
pbxproj = "Bar Tasker.xcodeproj/project.pbxproj"

name_map = {
    "BarTaskerCoordinator": "AppCoordinator",
    "BarTaskerCacheState": "CacheState",
    "BarTaskerCommandExecutor": "CommandExecutor",
    "BarTaskerApp": "MainApp",
    "BarTaskerPreferencesStore": "PreferencesStore",
    "BarTaskerRecurrenceRule": "RecurrenceRule",
    "BarTaskerReorderQueue": "ReorderQueue",
    "BarTaskerTaskVisibilityEngine": "TaskVisibilityEngine",
    "BarTaskerTheme": "AppTheme",
    "BarTaskerTypography": "Typography",
    "BarTaskerMCPServer": "MCPServer",
    "BarTaskerPluginRegistry": "PluginRegistry",
    "BarTaskerPluginProtocols": "PluginProtocols",
    "BarTaskerPlugin": "Plugin",
    "BarTaskerMCPCheckvistError": "MCPCheckvistError",
    "BarTaskerTimerStore": "TimerStore",
    "BarTaskerTimerNode": "TimerNode",
    "BarTaskerCommandEngine": "CommandEngine",
    "BarTaskerCommand": "Command"
}

# 1. Update file contents
for root, dirs, files in os.walk(directory):
    for file in files:
        if file.endswith(".swift") or file.endswith(".plist") or file.endswith(".entitlements"):
            filepath = os.path.join(root, file)
            with open(filepath, 'r') as f:
                content = f.read()
            
            new_content = content
            for old_name, new_name in name_map.items():
                new_content = new_content.replace(old_name, new_name)
            
            if content != new_content:
                with open(filepath, 'w') as f:
                    f.write(new_content)

# 2. Rename files
for root, dirs, files in os.walk(directory):
    for file in files:
        new_file = file
        for old_name, new_name in name_map.items():
            if old_name in new_file:
                new_file = new_file.replace(old_name, new_name)
        
        if new_file != file:
            old_path = os.path.join(root, file)
            new_path = os.path.join(root, new_file)
            os.rename(old_path, new_path)

# 3. Update project.pbxproj
with open(pbxproj, 'r') as f:
    content = f.read()

new_content = content
for old_name, new_name in name_map.items():
    new_content = new_content.replace(old_name, new_name)

if content != new_content:
    with open(pbxproj, 'w') as f:
        f.write(new_content)

print("Renaming complete.")
