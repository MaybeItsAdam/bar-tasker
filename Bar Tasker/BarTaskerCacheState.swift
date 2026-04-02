import Foundation

/// Holds the pre-computed caches that drive visible-task filtering,
/// tag lookups, due-date bucketing, and timer roll-ups.
///
/// Owned by `BarTaskerManager`; rebuilt when the dirty flag is set.
struct BarTaskerCacheState {
  /// Dirty flag set by `objectWillChange`; cleared after recomputation.
  var dirty = true
  /// Prevents recursive cache rebuilds when visibility sorting reads cached helpers.
  var isRebuilding = false

  var visibleTasks: [CheckvistTask] = []
  var childCount: [Int: Int] = [:]
  var rolledUpElapsed: [Int: TimeInterval] = [:]
  var priorityRank: [Int: Int] = [:]
  var rootLevelTagNames: [String] = []
  var taskById: [Int: CheckvistTask] = [:]
  /// Pre-extracted lowercased tags per task ID, built once during cache rebuild.
  var tagsByTaskId: [Int: [String]] = [:]
  /// Pre-computed due bucket per task ID, avoiding repeated date math in filters/sorts.
  var rootDueBucket: [Int: BarTaskerManager.RootDueBucket] = [:]

  mutating func invalidate() {
    dirty = true
  }
}
