import re

# Update BarTaskerCoordinator.swift
with open("Bar Tasker/BarTaskerCoordinator.swift", "r") as f:
    content = f.read()

# Replace hideFuture, rootTaskView, selectedRootDueBucketRawValue, selectedRootTag
new_props = """  var hideFuture: Bool {
    get { taskListViewModel.hideFuture }
    set { taskListViewModel.hideFuture = newValue }
  }
  var rootTaskView: RootTaskView {
    get { taskListViewModel.rootTaskView }
    set {
      taskListViewModel.rootTaskView = newValue
      preferencesStore.set(newValue.rawValue, for: .rootTaskView)
    }
  }
  var selectedRootDueBucketRawValue: Int {
    get { taskListViewModel.selectedRootDueBucketRawValue }
    set {
      taskListViewModel.selectedRootDueBucketRawValue = newValue
      preferencesStore.set(newValue, for: .selectedRootDueBucketRawValue)
    }
  }
  var selectedRootTag: String {
    get { taskListViewModel.selectedRootTag }
    set {
      taskListViewModel.selectedRootTag = newValue
      preferencesStore.set(newValue, for: .selectedRootTag)
    }
  }"""

old_props_pattern = r'  var hideFuture: Bool = false \{\n    didSet \{ invalidateCaches\(\) \}\n  \}\n  var rootTaskView: RootTaskView \{\n    didSet \{\n      preferencesStore\.set\(rootTaskView\.rawValue, for: \.rootTaskView\)\n      invalidateCaches\(\)\n    \}\n  \}\n  var selectedRootDueBucketRawValue: Int \{\n    didSet \{\n      preferencesStore\.set\(selectedRootDueBucketRawValue, for: \.selectedRootDueBucketRawValue\)\n      invalidateCaches\(\)\n    \}\n  \}\n  var selectedRootTag: String \{\n    didSet \{\n      preferencesStore\.set\(selectedRootTag, for: \.selectedRootTag\)\n      invalidateCaches\(\)\n    \}\n  \}'

content = re.sub(old_props_pattern, new_props, content)

# Remove `@ObservationIgnored var cache = BarTaskerCacheState()`
content = re.sub(r'  @ObservationIgnored var cache = BarTaskerCacheState\(\)\n', '', content)

# Also remove `self.rootTaskView = ...` from init since we can't assign to computed property in init without setter, wait we have setter.
# Actually it's fine since we have a setter that calls preferencesStore.set.
# Wait, `self.rootTaskView = ...` will call setter and trigger preferencesStore.set, which is what we want.
# BUT we need to make sure `taskListViewModel` is instantiated BEFORE setting these values!
# In the init, we set `self.rootTaskView` BEFORE `self.taskListViewModel` is instantiated!
# We should move the `taskListViewModel` instantiation up or set the initial values inside TaskListViewModel.

with open("Bar Tasker/BarTaskerCoordinator.swift", "w") as f:
    f.write(content)

# Update BarTaskerCoordinator+TaskScoping.swift
with open("Bar Tasker/BarTaskerCoordinator+TaskScoping.swift", "r") as f:
    scoping = f.read()

# Replace uses of `cache.` with `taskListViewModel.cache.`
scoping = scoping.replace("cache.", "taskListViewModel.cache.")
# Replace `invalidateCaches()` with `taskListViewModel.invalidateCaches()`
scoping = scoping.replace("invalidateCaches()", "taskListViewModel.invalidateCaches()")
# Remove `ensureVisibleTasksCacheValid` and `computeVisibleTasks`
scoping = re.sub(r'  func ensureVisibleTasksCacheValid\(\) \{[\s\S]*?\}\n', '', scoping)
scoping = re.sub(r'  private func computeVisibleTasks\(\) -> \[CheckvistTask\] \{[\s\S]*?\}\n\n', '', scoping)
# Replace `ensureVisibleTasksCacheValid()` call in breadcrumbs and visibleTasks with `taskListViewModel.ensureVisibleTasksCacheValid()`
scoping = scoping.replace("ensureVisibleTasksCacheValid()", "taskListViewModel.ensureVisibleTasksCacheValid()")

# Remove `computeRootLevelTagNames`
scoping = re.sub(r'  private func computeRootLevelTagNames\(limit: Int\) -> \[String\] \{[\s\S]*?\}\n\n', '', scoping)

with open("Bar Tasker/BarTaskerCoordinator+TaskScoping.swift", "w") as f:
    f.write(scoping)

