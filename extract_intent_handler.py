import re
import os

with open("Bar Tasker/BarTaskerCoordinator+TaskMutations.swift", "r") as f:
    content = f.read()

# Instead of keeping it as an extension, let's create a new class TaskIntentHandler.
# Wait, it's easier to first write the Swift code and replace the file.
