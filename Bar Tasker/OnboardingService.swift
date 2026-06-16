import Foundation
import Observation

@MainActor
@Observable class OnboardingService {
  @ObservationIgnored private let preferencesStore: PreferencesStore
  @ObservationIgnored private let repository: TaskRepository
  @ObservationIgnored private let integrations: IntegrationCoordinator

  var onboardingCompleted: Bool {
    didSet {
      preferencesStore.set(onboardingCompleted, for: .onboardingCompleted)
    }
  }
  
  var activeOnboardingDialog: OnboardingDialog?
  var dismissedOnboardingDialogs: Set<OnboardingDialog>

  init(
    preferencesStore: PreferencesStore,
    repository: TaskRepository,
    integrations: IntegrationCoordinator
  ) {
    self.preferencesStore = preferencesStore
    self.repository = repository
    self.integrations = integrations

    let storedUsername = preferencesStore.string(.checkvistUsername)
    let storedListId = preferencesStore.string(.checkvistListId)
    let storedOnboardingCompletedFlag = preferencesStore.optionalBool(.onboardingCompleted)

    if let storedOnboarding = storedOnboardingCompletedFlag {
      self.onboardingCompleted = storedOnboarding
    } else {
      self.onboardingCompleted = !storedUsername.isEmpty && !storedListId.isEmpty
    }

    let persistedDismissedDialogs = preferencesStore.stringArray(.dismissedOnboardingDialogs)
    self.dismissedOnboardingDialogs = Set(
      persistedDismissedDialogs.compactMap(OnboardingDialog.init(rawValue:))
    )
    self.activeOnboardingDialog = nil
  }

  func markOnboardingCompleted() {
    onboardingCompleted = true
  }

  func markOnboardingRequired() {
    onboardingCompleted = false
  }

  func completePluginSelectionOnboarding() {
    preferencesStore.set(true, for: .pluginSelectionOnboardingCompleted)
    if activeOnboardingDialog == .pluginSelection {
      activeOnboardingDialog = nil
    }
    presentOnboardingDialogIfNeeded()
  }

  func presentOnboardingDialogIfNeeded() {
    guard activeOnboardingDialog == nil else { return }
    for dialog in OnboardingDialog.allCases where shouldPresentOnboardingDialog(dialog) {
      activeOnboardingDialog = dialog
      return
    }
  }

  func dismissActiveOnboardingDialog(permanently: Bool) {
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
      return repository.checkvistIntegrationEnabled && !repository.hasCredentials
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

  func refreshOnboardingDialogState() {
    if let activeOnboardingDialog, !shouldPresentOnboardingDialog(activeOnboardingDialog) {
      self.activeOnboardingDialog = nil
    }
    presentOnboardingDialogIfNeeded()
  }
}
