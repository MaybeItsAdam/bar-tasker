import Foundation

enum AutoRefreshThrottlePolicy {
  static func shouldRefresh(
    needsInitialSetup: Bool,
    now: Date,
    lastRefreshAt: Date,
    minimumInterval: TimeInterval = 8
  ) -> Bool {
    guard !needsInitialSetup else { return false }
    return now.timeIntervalSince(lastRefreshAt) > minimumInterval
  }
}
