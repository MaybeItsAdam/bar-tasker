import Foundation
import Observation

@MainActor
@Observable final class NavigationState {
  @ObservationIgnored private let cacheInvalidationBus: CacheInvalidationBus

  var currentParentId: Int = 0 {
    didSet { cacheInvalidationBus.invalidate() }
  }
  var currentSiblingIndex: Int = 0
  var rootScopeFocusLevel: Int = 0
  var isPopoverVisible: Bool = false

  init(cacheInvalidationBus: CacheInvalidationBus = CacheInvalidationBus()) {
    self.cacheInvalidationBus = cacheInvalidationBus
  }
}
