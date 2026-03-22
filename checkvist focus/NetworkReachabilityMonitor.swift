import Foundation
import Network

final class NetworkReachabilityMonitor {
  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "uk.co.maybeitsadam.checkvist-focus.network")

  var onStatusChange: ((Bool) -> Void)?

  func start() {
    monitor.pathUpdateHandler = { [weak self] path in
      self?.onStatusChange?(path.status == .satisfied)
    }
    monitor.start(queue: queue)
  }

  func stop() {
    monitor.cancel()
  }
}
