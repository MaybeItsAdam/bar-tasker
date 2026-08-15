import Foundation

struct TimerNode: Equatable, Sendable {
  let id: Int
  let parentId: Int?
}

enum TimerStore {
  static func formatted(_ elapsed: TimeInterval) -> String {
    if elapsed < 60 {
      return "\(Int(elapsed))s"
    } else if elapsed < 3600 {
      let minutes = elapsed / 60
      return minutes < 10 ? String(format: "%.1fm", minutes) : "\(Int(minutes))m"
    } else {
      let hours = elapsed / 3600
      return hours < 10 ? String(format: "%.1fh", hours) : "\(Int(hours))h"
    }
  }

  static func childCountByTaskId(nodes: [TimerNode]) -> [Int: Int] {
    var counts: [Int: Int] = [:]
    for node in nodes {
      let parentId = node.parentId ?? 0
      guard parentId != 0 else { continue }
      counts[parentId, default: 0] += 1
    }
    return counts
  }

  static func rolledUpElapsedByTaskId(nodes: [TimerNode], ownElapsed: [Int: TimeInterval])
    -> [Int: TimeInterval]
  {
    var childrenByParent: [Int: [TimerNode]] = [:]
    for node in nodes {
      childrenByParent[node.parentId ?? 0, default: []].append(node)
    }

    var cache: [Int: TimeInterval] = [:]
    func total(for id: Int) -> TimeInterval {
      if let cached = cache[id] { return cached }
      var elapsed = ownElapsed[id] ?? 0
      for child in childrenByParent[id] ?? [] {
        elapsed += total(for: child.id)
      }
      cache[id] = elapsed
      return elapsed
    }

    for node in nodes {
      _ = total(for: node.id)
    }
    return cache
  }
}
