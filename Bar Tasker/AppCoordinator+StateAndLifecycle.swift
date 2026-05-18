import Foundation

extension AppCoordinator {
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

  // MARK: - Keychain

  func handleCredentialStorageModeChanged() {
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
