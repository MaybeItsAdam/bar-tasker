import Foundation

public enum AppTerminationDecision: Equatable {
  case terminateNow
  case cancel
}

public enum AppTerminationPolicy {
  public static func decision(explicitQuitRequested: Bool) -> AppTerminationDecision {
    explicitQuitRequested ? .terminateNow : .cancel
  }
}
