import Foundation

public enum AppTerminationDecision: Equatable {
  case terminateNow
  case cancel
}

public enum AppTerminationPolicy {
  /// Whether a termination request should be honoured.
  ///
  /// A menu bar agent has no window to close and no app menu to quit from, so
  /// the only legitimate quit is the one from its own status item menu —
  /// everything else is the system asking on behalf of something the user did
  /// not mean, and gets cancelled.
  ///
  /// That stops being true the moment the app has a Dock icon. ⌘Q from the app
  /// menu calls `NSApp.terminate` directly without routing through the status
  /// item, so under `.regular` a quit that isn't explicitly flagged is still a
  /// real quit, and cancelling it looks like the shortcut is broken.
  public static func decision(
    explicitQuitRequested: Bool,
    isRegularActivationPolicy: Bool
  ) -> AppTerminationDecision {
    (explicitQuitRequested || isRegularActivationPolicy) ? .terminateNow : .cancel
  }
}
