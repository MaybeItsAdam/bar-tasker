import Foundation
import ServiceManagement

/// Owns the wiring that has to happen exactly once during `AppCoordinator`
/// construction: cache-invalidation bus subscription, the
/// repository/manager-callback fan-out, and the network-reachability monitor's
/// lifecycle. Splitting this out shrinks `AppCoordinator` itself and keeps
/// "what fires when" readable in one place.
///
/// The controller intentionally holds a `weak` reference to `AppCoordinator`:
/// the coordinator owns the controller, every callback originates from a
/// child manager that the coordinator also owns, so a strong reference here
/// would form a cycle. `start()` is called from `AppCoordinator.init`; `stop()`
/// from its `deinit`.
@MainActor
final class LifecycleController {
  private weak var coordinator: AppCoordinator?
  private let reachabilityMonitor: NetworkReachabilityMonitor

  init(coordinator: AppCoordinator, reachabilityMonitor: NetworkReachabilityMonitor) {
    self.coordinator = coordinator
    self.reachabilityMonitor = reachabilityMonitor
  }

  func start() {
    setupChildCallbacks()
    setupNetworkMonitor()
  }

  // MARK: - Child callbacks

  private func setupChildCallbacks() {
    guard let coordinator else { return }

    // All cache invalidation flows through `cacheInvalidationBus`: producers'
    // `didSet`s call `bus.invalidate()`, and the single subscription below
    // routes that into `TaskListViewModel.invalidateCaches()`.
    coordinator.cacheInvalidationBus.subscribe { [weak coordinator] in
      coordinator?.taskListViewModel.invalidateCaches()
    }

    let repository = coordinator.repository

    // Repository callbacks (non-cache concerns only).
    repository.onUsernameChanged = { [weak coordinator] in
      guard let coordinator else { return }
      coordinator.repository.checkvistSyncPlugin.clearAuthentication()
      coordinator.refreshOnboardingDialogState()
    }
    repository.onRemoteKeyChanged = { [weak coordinator] newKey in
      guard let coordinator else { return }
      coordinator.repository.checkvistSyncPlugin.clearAuthentication()
      coordinator.repository.checkvistSyncPlugin.persistRemoteKey(
        newKey, useKeychainStorage: coordinator.usesKeychainStorage)
      coordinator.refreshOnboardingDialogState()
    }
    repository.onListIdChanged = { [weak coordinator] listId in
      guard let coordinator else { return }
      coordinator.integrations.loadPendingObsidianSyncQueue(for: listId)
      coordinator.refreshOnboardingDialogState()
    }
    repository.onCheckvistIntegrationEnabledChanged = { [weak coordinator] in
      coordinator?.refreshOnboardingDialogState()
    }

    // Other manager callbacks (non-cache concerns only).
    coordinator.quickEntry.integrationFlagsProvider = { [weak coordinator] in
      guard let coordinator else { return (false, false, false) }
      return (
        coordinator.integrations.obsidianIntegrationEnabled,
        coordinator.integrations.googleCalendarIntegrationEnabled,
        coordinator.integrations.mcpIntegrationEnabled
      )
    }
    coordinator.quickEntry.shortcutBindingProvider = { [weak coordinator] action in
      coordinator?.preferences.shortcutBinding(for: action) ?? action.defaultBinding
    }
    coordinator.startDates.dateResolver = { [weak coordinator] input in
      coordinator?.resolveDueDateWithConfig(input) ?? input
    }
    coordinator.integrations.onError = { [weak coordinator] err in
      coordinator?.repository.errorMessage = err
    }

    coordinator.preferences.onLaunchAtLoginChanged = { [weak self] newValue in
      self?.applyLaunchAtLoginChange(newValue)
    }

    #if DEBUG
      coordinator.preferences.onIgnoreKeychainInDebugChanged = { [weak coordinator] in
        coordinator?.handleCredentialStorageModeChanged()
      }
    #endif
  }

  // MARK: - Network

  private func setupNetworkMonitor() {
    reachabilityMonitor.onStatusChange = { [weak coordinator] reachable in
      guard let coordinator else { return }
      Task { @MainActor in
        coordinator.repository.isNetworkReachable = reachable
        guard reachable else { return }
        await coordinator.syncService.flushPendingTaskMutations()
        guard coordinator.integrations.obsidianIntegrationEnabled,
          !coordinator.integrations.pendingObsidianSyncTaskIds.isEmpty
        else { return }
        await coordinator.integrations.processPendingObsidianSyncQueue()
      }
    }
    reachabilityMonitor.start()
  }

  // MARK: - Launch at login

  private var shouldSuppressLaunchAtLoginAvailabilityError: Bool {
    #if DEBUG
      let env = ProcessInfo.processInfo.environment
      return env["XCODE_VERSION_ACTUAL"] != nil || env["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil
    #else
      return false
    #endif
  }

  private func applyLaunchAtLoginChange(_ newValue: Bool) {
    guard let coordinator else { return }
    if coordinator.isApplyingLaunchAtLoginChange { return }
    guard #available(macOS 13.0, *) else { return }
    do {
      if newValue {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      let nsError = error as NSError
      if nsError.domain == SMAppServiceErrorDomain && nsError.code == 1 {
        if !shouldSuppressLaunchAtLoginAvailabilityError {
          coordinator.repository.errorMessage =
            "Launch at login is unavailable for this app build. Install in /Applications and try again."
        }
      } else {
        coordinator.repository.errorMessage =
          "Launch at login failed: \(error.localizedDescription)"
      }
      if newValue {
        coordinator.isApplyingLaunchAtLoginChange = true
        coordinator.preferences.launchAtLogin = false
        coordinator.isApplyingLaunchAtLoginChange = false
      }
    }
  }
}
