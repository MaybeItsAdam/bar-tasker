import Foundation
import Observation

@MainActor
@Observable final class NavigationState {
  var currentParentId: Int = 0
  var currentSiblingIndex: Int = 0
  var rootScopeFocusLevel: Int = 0
  var isPopoverVisible: Bool = false
}
