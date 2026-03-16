import Foundation

enum AppTerminationDecision: Equatable {
  case terminateNow
  case cancel
}

enum AppTerminationPolicy {
  static func decision(explicitQuitRequested: Bool) -> AppTerminationDecision {
    explicitQuitRequested ? .terminateNow : .cancel
  }
}
