import Foundation
import ServiceManagement

extension AppCoordinator {
  private var shouldSuppressLaunchAtLoginAvailabilityError: Bool {
    #if DEBUG
      let env = ProcessInfo.processInfo.environment
      return env["XCODE_VERSION_ACTUAL"] != nil || env["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil
    #else
      return false
    #endif
  }

  /// All persistence and cache-invalidation that was previously Combine-based is now
  /// handled by `didSet` observers on each property. This method is retained only for
  /// any remaining cross-cutting bindings that cannot be expressed as `didSet`.
  func setupBindings() {
    // All property persistence is now handled by didSet observers.
    // Cache invalidation from own properties is handled by didSet.
    // Cache invalidation from child managers is handled by setupChildCallbacks().
  }

  /// Wires up child manager callbacks for cache invalidation and coordinator-level side effects.
  func setupChildCallbacks() {
    // Repository callbacks
    repository.onCacheRelevantChange = { [weak self] in self?.invalidateCaches() }
    repository.onUsernameChanged = { [weak self] in
      guard let self else { return }
      self.repository.checkvistSyncPlugin.clearAuthentication()
      self.refreshOnboardingDialogState()
    }
    repository.onRemoteKeyChanged = { [weak self] newKey in
      guard let self else { return }
      self.repository.checkvistSyncPlugin.clearAuthentication()
      self.repository.checkvistSyncPlugin.persistRemoteKey(
        newKey, useKeychainStorage: self.usesKeychainStorage)
      self.refreshOnboardingDialogState()
    }
    repository.onListIdChanged = { [weak self] listId in
      guard let self else { return }
      self.integrations.loadPendingObsidianSyncQueue(for: listId)
      self.refreshOnboardingDialogState()
    }
    repository.onCheckvistIntegrationEnabledChanged = { [weak self] in
      guard let self else { return }
      self.invalidateCaches()
      self.refreshOnboardingDialogState()
    }

    // Other manager callbacks
    quickEntry.onCacheRelevantChange = { [weak self] in self?.invalidateCaches() }
    quickEntry.integrationFlagsProvider = { [weak self] in
      guard let self else { return (false, false, false) }
      return (
        integrations.obsidianIntegrationEnabled,
        integrations.googleCalendarIntegrationEnabled,
        integrations.mcpIntegrationEnabled
      )
    }
    quickEntry.shortcutBindingProvider = { [weak self] action in
      self?.preferences.shortcutBinding(for: action) ?? action.defaultBinding
    }
    timer.onCacheRelevantChange = { [weak self] in self?.invalidateCaches() }
    kanban.onCacheRelevantChange = { [weak self] in self?.invalidateCaches() }
    focusSessionManager.onCacheRelevantChange = { [weak self] in self?.invalidateCaches() }
    startDates.onCacheRelevantChange = { [weak self] in self?.invalidateCaches() }
    startDates.dateResolver = { [weak self] input in
      self?.resolveDueDateWithConfig(input) ?? input
    }
    integrations.onError = { [weak self] err in self?.errorMessage = err }

    preferences.onLaunchAtLoginChanged = { [weak self] newValue in
      guard let self else { return }
      if self.isApplyingLaunchAtLoginChange { return }
      if #available(macOS 13.0, *) {
        do {
          if newValue {
            try SMAppService.mainApp.register()
          } else {
            try SMAppService.mainApp.unregister()
          }
        } catch {
          let nsError = error as NSError
          if nsError.domain == SMAppServiceErrorDomain && nsError.code == 1 {
            if !self.shouldSuppressLaunchAtLoginAvailabilityError {
              self.repository.errorMessage =
                "Launch at login is unavailable for this app build. Install in /Applications and try again."
            }
          } else {
            self.repository.errorMessage = "Launch at login failed: \(error.localizedDescription)"
          }
          if newValue {
            self.isApplyingLaunchAtLoginChange = true
            self.preferences.launchAtLogin = false
            self.isApplyingLaunchAtLoginChange = false
          }
        }
      }
    }

    #if DEBUG
      preferences.onIgnoreKeychainInDebugChanged = { [weak self] in
        self?.handleCredentialStorageModeChanged()
      }
    #endif
  }

  // MARK: - Priority Queue (forwarding to repository)

  func savePriorityQueue(_ queues: [Int: [Int]]) {
    repository.savePriorityQueue(queues)
  }

  @MainActor func removeTasksFromPriorityQueue(_ taskIds: Set<Int>) {
    repository.removeTasksFromPriorityQueue(taskIds)
  }

  @MainActor func reconcilePriorityQueueWithOpenTasks() {
    repository.reconcilePriorityQueueWithOpenTasks()
  }

  @MainActor func reconcilePendingObsidianSyncQueueWithOpenTasks() {
    integrations.reconcilePendingObsidianSyncQueueWithOpenTasks(
      openTaskIds: Set(repository.tasks.map(\.id)),
      listId: repository.listId
    )
  }

  // MARK: - Loading (forwarding to repository)

  @MainActor func beginLoading() {
    repository.beginLoading()
  }

  @MainActor func endLoading() {
    repository.endLoading()
  }

  @MainActor
  func withLoadingState<T>(_ operation: () async throws -> T) async rethrows -> T {
    try await repository.withLoadingState(operation)
  }

  @MainActor
  func setAuthenticationRequiredErrorIfNeeded() {
    repository.setAuthenticationRequiredErrorIfNeeded()
  }

  @MainActor
  func runBooleanMutation(
    failureMessage: String,
    errorMessageBuilder: @escaping (Error) -> String = { "Error: \($0.localizedDescription)" },
    action: () async throws -> Bool,
    onSuccess: @MainActor () async -> Void
  ) async {
    await repository.runBooleanMutation(
      failureMessage: failureMessage,
      errorMessageBuilder: errorMessageBuilder,
      action: action,
      onSuccess: onSuccess
    )
  }

  // MARK: - Network

  func setupNetworkMonitor() {
    reachabilityMonitor.onStatusChange = { [weak self] reachable in
      guard let self else { return }
      Task { @MainActor in
        self.repository.isNetworkReachable = reachable
        guard reachable else { return }
        await self.flushPendingTaskMutations()
        guard self.integrations.obsidianIntegrationEnabled,
          !self.integrations.pendingObsidianSyncTaskIds.isEmpty
        else {
          return
        }
        await self.integrations.processPendingObsidianSyncQueue()
      }
    }
    reachabilityMonitor.start()
  }

  // MARK: - Keychain

  private func handleCredentialStorageModeChanged() {
    let current = repository.remoteKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if usesKeychainStorage {
      if !current.isEmpty {
        repository.checkvistSyncPlugin.persistRemoteKey(current, useKeychainStorage: true)
      } else {
        repository.hasAttemptedRemoteKeyBootstrap = false
        loadRemoteKeyFromKeychainIfNeeded()
      }
    } else {
      repository.checkvistSyncPlugin.persistRemoteKeyForDebugStorageMode(current)
    }
  }

  /// Explicitly load the remote key from the system keychain. Call only in response to a user action.
  @MainActor func loadCredentialsFromKeychain() {
    repository.hasAttemptedRemoteKeyBootstrap = false
    loadRemoteKeyFromKeychainIfNeeded()
  }

  func loadRemoteKeyFromKeychainIfNeeded() {
    let currentState = RemoteKeyBootstrapState(
      remoteKey: repository.remoteKey,
      hasAttemptedBootstrap: repository.hasAttemptedRemoteKeyBootstrap
    )
    let nextState = RemoteKeyBootstrapPolicy.bootstrap(
      state: currentState,
      usesKeychainStorage: usesKeychainStorage,
      loadFromKeychain: { repository.checkvistSyncPlugin.loadRemoteKeyFromKeychain() }
    )
    repository.remoteKey = nextState.remoteKey
    repository.hasAttemptedRemoteKeyBootstrap = nextState.hasAttemptedBootstrap
  }

  @MainActor func toggleDebugKeychainStorageMode() {
    #if DEBUG
      preferences.ignoreKeychainInDebug.toggle()
      repository.errorMessage =
        preferences.ignoreKeychainInDebug
        ? "Dev mode: keychain disabled (no password prompts)."
        : "Dev mode: keychain enabled."
    #endif
  }

  @MainActor func resetOnboardingForDebug() {
    #if DEBUG
      repository.checkvistSyncPlugin.clearAuthentication()
      repository.errorMessage = nil
      let resetState = OnboardingResetPolicy.reset(
        OnboardingResetState(
          remoteKey: repository.remoteKey,
          onboardingCompleted: onboardingCompleted,
          username: repository.username,
          listId: repository.listId,
          availableListsCount: repository.availableLists.count,
          tasksCount: repository.tasks.count,
          currentParentId: currentParentId,
          currentSiblingIndex: currentSiblingIndex
        ))

      onboardingCompleted = resetState.onboardingCompleted
      repository.username = resetState.username
      repository.listId = resetState.listId
      repository.availableLists = []
      repository.tasks = []
      currentParentId = resetState.currentParentId
      currentSiblingIndex = resetState.currentSiblingIndex

      preferencesStore.remove(.checkvistUsername)
      preferencesStore.remove(.checkvistListId)
      preferencesStore.remove(.onboardingCompleted)
      preferencesStore.remove(.pluginSelectionOnboardingCompleted)
      dismissedOnboardingDialogs = []
      activeOnboardingDialog = nil
      preferencesStore.remove(.dismissedOnboardingDialogs)
      presentOnboardingDialogIfNeeded()
    #endif
  }

  @MainActor func markOnboardingCompleted() {
    onboardingCompleted = true
  }

  @MainActor func markOnboardingRequired() {
    onboardingCompleted = false
  }

  @MainActor func completePluginSelectionOnboarding() {
    preferencesStore.set(true, for: .pluginSelectionOnboardingCompleted)
    if activeOnboardingDialog == .pluginSelection {
      activeOnboardingDialog = nil
    }
    presentOnboardingDialogIfNeeded()
  }

  // MARK: - Offline-first onboarding dialogs

  @MainActor func presentOnboardingDialogIfNeeded() {
    guard activeOnboardingDialog == nil else { return }
    for dialog in OnboardingDialog.allCases where shouldPresentOnboardingDialog(dialog) {
      activeOnboardingDialog = dialog
      return
    }
  }

  @MainActor func dismissActiveOnboardingDialog(permanently: Bool) {
    guard let dialog = activeOnboardingDialog else { return }
    if permanently {
      dismissedOnboardingDialogs.insert(dialog)
      persistDismissedOnboardingDialogs()
    }
    activeOnboardingDialog = nil
    presentOnboardingDialogIfNeeded()
  }

  private func shouldPresentOnboardingDialog(_ dialog: OnboardingDialog) -> Bool {
    guard !dismissedOnboardingDialogs.contains(dialog) else { return false }
    switch dialog {
    case .pluginSelection:
      return !preferencesStore.bool(.pluginSelectionOnboardingCompleted, default: false)
    case .checkvist:
      return checkvistIntegrationEnabled && !hasCredentials
    case .obsidian:
      return integrations.obsidianIntegrationEnabled && integrations.obsidianInboxPath.isEmpty
    case .googleCalendar:
      return false
    case .mcp:
      return false
    }
  }

  private func persistDismissedOnboardingDialogs() {
    let rawValues = dismissedOnboardingDialogs.map(\.rawValue).sorted()
    preferencesStore.set(rawValues, for: .dismissedOnboardingDialogs)
  }

  @MainActor func refreshOnboardingDialogState() {
    if let activeOnboardingDialog, !shouldPresentOnboardingDialog(activeOnboardingDialog) {
      self.activeOnboardingDialog = nil
    }
    presentOnboardingDialogIfNeeded()
  }
}
