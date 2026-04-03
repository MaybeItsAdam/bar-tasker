import Combine
import Foundation
import ServiceManagement

extension BarTaskerManager {
  private var shouldSuppressLaunchAtLoginAvailabilityError: Bool {
    #if DEBUG
      let env = ProcessInfo.processInfo.environment
      return env["XCODE_VERSION_ACTUAL"] != nil || env["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil
    #else
      return false
    #endif
  }

  // swiftlint:disable function_body_length
  func setupBindings() {
    // Invalidate computed-property caches only when properties that affect visible
    // task computation change — not on every @Published update (e.g. UI-only flags
    // like completingTaskId, isQuickEntryFocused, errorMessage).
    Publishers.MergeMany(
      $tasks.map { _ in () }.eraseToAnyPublisher(),
      $currentParentId.map { _ in () }.eraseToAnyPublisher(),
      $searchText.map { _ in () }.eraseToAnyPublisher(),
      $hideFuture.map { _ in () }.eraseToAnyPublisher(),
      $rootTaskView.map { _ in () }.eraseToAnyPublisher(),
      $selectedRootDueBucketRawValue.map { _ in () }.eraseToAnyPublisher(),
      $selectedRootTag.map { _ in () }.eraseToAnyPublisher(),
      $quickEntryMode.map { _ in () }.eraseToAnyPublisher(),
      $priorityTaskIds.map { _ in () }.eraseToAnyPublisher(),
      $timerByTaskId.map { _ in () }.eraseToAnyPublisher(),
      $kanbanColumns.map { _ in () }.eraseToAnyPublisher(),
      $kanbanFocusedColumnIndex.map { _ in () }.eraseToAnyPublisher()
    )
    .sink { [weak self] _ in
      self?.invalidateCaches()
    }
    .store(in: &cancellables)

    userPluginManager.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)

    $username
      .dropFirst()
      .sink { [weak self] value in
        self?.preferencesStore.set(value, for: .checkvistUsername)
        self?.checkvistSyncPlugin.clearAuthentication()
        self?.refreshOnboardingDialogState()
      }.store(in: &cancellables)
    $remoteKey
      .dropFirst()
      .removeDuplicates()
      .sink { [weak self] value in
        guard let self else { return }
        self.checkvistSyncPlugin.clearAuthentication()
        self.checkvistSyncPlugin.persistRemoteKey(
          value, useKeychainStorage: self.usesKeychainStorage)
        self.refreshOnboardingDialogState()
      }.store(in: &cancellables)
    $listId
      .dropFirst()
      .sink { [weak self] value in
        self?.preferencesStore.set(value, for: .checkvistListId)
        self?.loadPriorityQueue(for: value)
        self?.loadPendingObsidianSyncQueue(for: value)
        self?.refreshOnboardingDialogState()
      }.store(in: &cancellables)
    $confirmBeforeDelete.sink { [weak self] in
      self?.preferencesStore.set($0, for: .confirmBeforeDelete)
    }
    .store(in: &cancellables)
    $obsidianIntegrationEnabled
      .sink { [weak self] value in
        self?.preferencesStore.set(value, for: .obsidianIntegrationEnabled)
        self?.refreshOnboardingDialogState()
      }
      .store(in: &cancellables)
    $googleCalendarIntegrationEnabled
      .sink { [weak self] value in
        self?.preferencesStore.set(value, for: .googleCalendarIntegrationEnabled)
        self?.refreshOnboardingDialogState()
      }
      .store(in: &cancellables)
    $mcpIntegrationEnabled
      .sink { [weak self] in
        self?.preferencesStore.set($0, for: .mcpIntegrationEnabled)
        self?.refreshOnboardingDialogState()
      }
      .store(in: &cancellables)
    $appTheme.sink { [weak self] in
      self?.preferencesStore.set($0.rawValue, for: .appThemeRawValue)
    }
    .store(in: &cancellables)
    $themeAccentPreset.sink { [weak self] in
      self?.preferencesStore.set($0.rawValue, for: .themeAccentPresetRawValue)
    }
    .store(in: &cancellables)
    $themeCustomAccentHex
      .dropFirst()
      .sink { [weak self] value in
        guard let self else { return }
        let normalized =
          BarTaskerThemeColorCodec.normalizedHex(value) ?? ThemeAccentPreset.blue.hex
        if normalized != value {
          self.themeCustomAccentHex = normalized
          return
        }
        self.preferencesStore.set(normalized, for: .themeCustomAccentHex)
      }
      .store(in: &cancellables)
    $themeColorTokenHexOverrides
      .dropFirst()
      .sink { [weak self] value in
        guard let self else { return }
        let normalized = Self.normalizedThemeColorTokenHexOverrides(value)
        if normalized != value {
          self.themeColorTokenHexOverrides = normalized
          return
        }
        self.preferencesStore.set(normalized, for: .themeColorTokenHexOverrides)
      }
      .store(in: &cancellables)
    $showTaskBreadcrumbContext.sink { [weak self] in
      self?.preferencesStore.set($0, for: .showTaskBreadcrumbContext)
    }
    .store(in: &cancellables)
    $rootTaskView.sink { [weak self] in
      self?.preferencesStore.set($0.rawValue, for: .rootTaskView)
    }
    .store(in: &cancellables)
    $kanbanColumns
      .dropFirst()
      .sink { [weak self] columns in
        self?.saveKanbanColumns(columns)
      }
      .store(in: &cancellables)
    $selectedRootDueBucketRawValue.sink { [weak self] in
      self?.preferencesStore.set($0, for: .selectedRootDueBucketRawValue)
    }
    .store(in: &cancellables)
    $selectedRootTag.sink { [weak self] in
      self?.preferencesStore.set($0, for: .selectedRootTag)
    }
    .store(in: &cancellables)
    $launchAtLogin.sink { [weak self] newValue in
      guard let self else { return }
      if self.isApplyingLaunchAtLoginChange { return }
      self.preferencesStore.set(newValue, for: .launchAtLogin)
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
              self.errorMessage =
                "Launch at login is unavailable for this app build. Install in /Applications and try again."
            }
          } else {
            self.errorMessage = "Launch at login failed: \(error.localizedDescription)"
          }
          if newValue {
            self.isApplyingLaunchAtLoginChange = true
            self.launchAtLogin = false
            self.preferencesStore.set(false, for: .launchAtLogin)
            self.isApplyingLaunchAtLoginChange = false
          }
        }
      }
    }.store(in: &cancellables)
    #if DEBUG
      $ignoreKeychainInDebug
        .dropFirst()
        .sink { [weak self] newValue in
          guard let self else { return }
          self.preferencesStore.set(
            newValue, for: .ignoreKeychainInDebug)
          self.handleCredentialStorageModeChanged()
        }.store(in: &cancellables)
    #endif
    $globalHotkeyEnabled.sink { [weak self] in
      self?.preferencesStore.set($0, for: .globalHotkeyEnabled)
    }
    .store(in: &cancellables)
    $globalHotkeyKeyCode.sink { [weak self] in
      self?.preferencesStore.set($0, for: .globalHotkeyKeyCode)
    }
    .store(in: &cancellables)
    $globalHotkeyModifiers.sink { [weak self] in
      self?.preferencesStore.set($0, for: .globalHotkeyModifiers)
    }
    .store(in: &cancellables)
    $quickAddHotkeyEnabled.sink { [weak self] in
      self?.preferencesStore.set($0, for: .quickAddHotkeyEnabled)
    }
    .store(in: &cancellables)
    $quickAddHotkeyKeyCode.sink { [weak self] in
      self?.preferencesStore.set($0, for: .quickAddHotkeyKeyCode)
    }
    .store(in: &cancellables)
    $quickAddHotkeyModifiers.sink { [weak self] in
      self?.preferencesStore.set($0, for: .quickAddHotkeyModifiers)
    }
    .store(in: &cancellables)
    $quickAddLocationMode.sink { [weak self] in
      self?.preferencesStore.set($0.rawValue, for: .quickAddLocationModeRawValue)
    }
    .store(in: &cancellables)
    $quickAddSpecificParentTaskId.sink { [weak self] in
      self?.preferencesStore.set($0, for: .quickAddSpecificParentTaskId)
    }
    .store(in: &cancellables)
    $customizableShortcutsByAction.sink { [weak self] value in
      self?.preferencesStore.set(value, for: .customizableShortcutsByAction)
    }
    .store(in: &cancellables)
    $maxTitleWidth.sink { [weak self] in
      self?.preferencesStore.set($0, for: .maxTitleWidth)
    }.store(
      in: &cancellables)
    $onboardingCompleted
      .sink { [weak self] in
        self?.preferencesStore.set(
          $0, for: .onboardingCompleted)
      }
      .store(in: &cancellables)
    $timerBarLeading.sink { [weak self] in
      self?.preferencesStore.set($0, for: .timerBarLeading)
    }.store(
      in: &cancellables)
    $timerMode.sink { [weak self] mode in
      self?.preferencesStore.set(mode.rawValue, for: .timerMode)
      if mode == .disabled {
        Task { @MainActor in
          self?.stopTimer()
        }
      }
    }.store(in: &cancellables)
    $timerByTaskId.sink { timers in
      let encoded = Dictionary(uniqueKeysWithValues: timers.map { (String($0.key), $0.value) })
      self.preferencesStore.set(encoded, for: .timerByTaskId)
    }.store(in: &cancellables)
  }
  // swiftlint:enable function_body_length

  static func timerDictionaryFromDefaults(
    preferencesStore: BarTaskerPreferencesStore
  ) -> [Int: TimeInterval] {
    let raw = preferencesStore.timerDictionary()
    guard !raw.isEmpty else { return [:] }
    var result: [Int: TimeInterval] = [:]
    for (key, value) in raw {
      if let id = Int(key) { result[id] = value }
    }
    return result
  }

  private static func normalizedTaskIdQueue(_ queue: [Int], maximumCount: Int? = nil) -> [Int] {
    var seen = Set<Int>()
    var normalized: [Int] = []
    for taskId in queue where taskId > 0 && !seen.contains(taskId) {
      seen.insert(taskId)
      normalized.append(taskId)
    }
    if let maximumCount, normalized.count > maximumCount {
      return Array(normalized.prefix(maximumCount))
    }
    return normalized
  }

  private func loadPriorityQueue(for listId: String) {
    priorityTaskIds = priorityQueueStore.load(for: listId)
  }

  private func loadPendingObsidianSyncQueue(for listId: String) {
    pendingObsidianSyncTaskIds = pendingSyncQueueStore.load(for: listId)
  }

  func savePriorityQueue(_ queue: [Int]) {
    let normalized = Self.normalizedTaskIdQueue(queue, maximumCount: Self.maxPriorityRank)
    priorityTaskIds = normalized

    guard !listId.isEmpty else { return }
    priorityQueueStore.save(normalized, for: listId)
  }

  func savePendingObsidianSyncQueue(_ queue: [Int]) {
    let normalized = Self.normalizedTaskIdQueue(queue)
    pendingObsidianSyncTaskIds = normalized

    guard !listId.isEmpty else { return }
    pendingSyncQueueStore.save(normalized, for: listId)
  }

  @MainActor func enqueuePendingObsidianSync(taskId: Int) {
    var queue = pendingObsidianSyncTaskIds
    queue.removeAll { $0 == taskId }
    queue.append(taskId)
    savePendingObsidianSyncQueue(queue)
  }

  @MainActor func dequeuePendingObsidianSync(taskId: Int) {
    savePendingObsidianSyncQueue(pendingObsidianSyncTaskIds.filter { $0 != taskId })
  }

  func setupNetworkMonitor() {
    reachabilityMonitor.onStatusChange = { [weak self] reachable in
      guard let self else { return }
      Task { @MainActor in
        self.isNetworkReachable = reachable
        guard
          reachable,
          self.obsidianIntegrationEnabled,
          !self.pendingObsidianSyncTaskIds.isEmpty
        else { return }
        await self.processPendingObsidianSyncQueue()
      }
    }
    reachabilityMonitor.start()
  }

  @MainActor func removeTasksFromPriorityQueue(_ taskIds: Set<Int>) {
    guard !taskIds.isEmpty else { return }
    let filtered = priorityTaskIds.filter { !taskIds.contains($0) }
    guard filtered != priorityTaskIds else { return }
    savePriorityQueue(filtered)
  }

  @MainActor func reconcilePriorityQueueWithOpenTasks() {
    let openTaskIds = Set(tasks.map(\.id))
    let filtered = priorityTaskIds.filter { openTaskIds.contains($0) }
    if filtered != priorityTaskIds {
      savePriorityQueue(filtered)
    }
  }

  @MainActor func reconcilePendingObsidianSyncQueueWithOpenTasks() {
    let openTaskIds = Set(tasks.map(\.id))
    let filtered = pendingObsidianSyncTaskIds.filter { openTaskIds.contains($0) }
    if filtered != pendingObsidianSyncTaskIds {
      savePendingObsidianSyncQueue(filtered)
    }
  }

  @MainActor
  func beginLoading() {
    loadingOperationCount += 1
    isLoading = true
  }

  @MainActor
  func endLoading() {
    loadingOperationCount = max(loadingOperationCount - 1, 0)
    isLoading = loadingOperationCount > 0
  }

  @MainActor
  func withLoadingState<T>(_ operation: () async throws -> T) async rethrows -> T {
    beginLoading()
    defer { endLoading() }
    return try await operation()
  }

  @MainActor
  func setAuthenticationRequiredErrorIfNeeded() {
    if errorMessage == nil {
      errorMessage = "Authentication required."
    }
  }

  @MainActor
  func runBooleanMutation(
    failureMessage: String,
    errorMessageBuilder: @escaping (Error) -> String = { "Error: \($0.localizedDescription)" },
    action: () async throws -> Bool,
    onSuccess: @MainActor () async -> Void
  ) async {
    do {
      let success = try await action()
      if success {
        await onSuccess()
      } else {
        errorMessage = failureMessage
      }
    } catch CheckvistSessionError.authenticationUnavailable {
      setAuthenticationRequiredErrorIfNeeded()
    } catch {
      self.errorMessage = errorMessageBuilder(error)
    }
  }

  // MARK: - Keychain

  private func handleCredentialStorageModeChanged() {
    let current = remoteKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if usesKeychainStorage {
      if !current.isEmpty {
        checkvistSyncPlugin.persistRemoteKey(current, useKeychainStorage: true)
      } else {
        hasAttemptedRemoteKeyBootstrap = false
        loadRemoteKeyFromKeychainIfNeeded()
      }
    } else {
      checkvistSyncPlugin.persistRemoteKeyForDebugStorageMode(current)
    }
  }

  func loadRemoteKeyFromKeychainIfNeeded() {
    let currentState = RemoteKeyBootstrapState(
      remoteKey: remoteKey,
      hasAttemptedBootstrap: hasAttemptedRemoteKeyBootstrap
    )
    let nextState = RemoteKeyBootstrapPolicy.bootstrap(
      state: currentState,
      usesKeychainStorage: usesKeychainStorage,
      loadFromKeychain: { checkvistSyncPlugin.loadRemoteKeyFromKeychain() }
    )
    remoteKey = nextState.remoteKey
    hasAttemptedRemoteKeyBootstrap = nextState.hasAttemptedBootstrap
  }

  @MainActor func toggleDebugKeychainStorageMode() {
    #if DEBUG
      ignoreKeychainInDebug.toggle()
      errorMessage =
        ignoreKeychainInDebug
        ? "Dev mode: keychain disabled (no password prompts)."
        : "Dev mode: keychain enabled."
    #endif
  }

  @MainActor func resetOnboardingForDebug() {
    #if DEBUG
      checkvistSyncPlugin.clearAuthentication()
      errorMessage = nil
      let resetState = OnboardingResetPolicy.reset(
        OnboardingResetState(
          remoteKey: remoteKey,
          onboardingCompleted: onboardingCompleted,
          username: username,
          listId: listId,
          availableListsCount: availableLists.count,
          tasksCount: tasks.count,
          currentParentId: currentParentId,
          currentSiblingIndex: currentSiblingIndex
        ))

      onboardingCompleted = resetState.onboardingCompleted
      username = resetState.username
      listId = resetState.listId
      availableLists = []
      tasks = []
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
      return false
    case .obsidian:
      return obsidianIntegrationEnabled && obsidianInboxPath.isEmpty
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
