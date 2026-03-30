import Foundation

struct AuthRetryState: Equatable {
  var hasRetriedAfterUnauthorized: Bool
}

enum AuthRetryDecision: Equatable {
  case retryAuthentication
  case giveUp
}

enum AuthRetryPolicy {
  static func decisionForUnauthorized(state: AuthRetryState) -> (
    decision: AuthRetryDecision, nextState: AuthRetryState
  ) {
    guard !state.hasRetriedAfterUnauthorized else {
      return (.giveUp, state)
    }
    var next = state
    next.hasRetriedAfterUnauthorized = true
    return (.retryAuthentication, next)
  }
}
