import re
import os

with open("Bar Tasker/BarTaskerCoordinator+TaskMutations.swift", "r") as f:
    mutations = f.read()

# Replace `extension BarTaskerCoordinator` with `class TaskIntentHandler`
# Add init and properties
# ...

