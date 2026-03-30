import Foundation

struct OnboardingResetState: Equatable {
  var remoteKey: String
  var onboardingCompleted: Bool
  var username: String
  var listId: String
  var availableListsCount: Int
  var tasksCount: Int
  var currentParentId: Int
  var currentSiblingIndex: Int
}

enum OnboardingResetPolicy {
  static func reset(_ state: OnboardingResetState) -> OnboardingResetState {
    OnboardingResetState(
      remoteKey: state.remoteKey,
      onboardingCompleted: false,
      username: "",
      listId: "",
      availableListsCount: 0,
      tasksCount: 0,
      currentParentId: 0,
      currentSiblingIndex: 0
    )
  }
}
