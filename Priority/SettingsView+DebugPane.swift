#if DEBUG
  import SwiftUI

  /// Debug-only pane for `SettingsView`. Pulled out of the main file as part
  /// of the Phase-4 settings split; the contents are unchanged.
  extension SettingsView {
    var debugPane: some View {
      Section(header: Text("Debug")) {
        Text("Shortcut: Cmd+Shift+K toggles keychain mode for development.")
          .font(.caption)
          .foregroundColor(themeColor(.textSecondary))
        Button("Reset onboarding state") {
          checkvistManager.resetOnboardingForDebug()
        }
        .foregroundColor(themeColor(.danger))
      }
    }
  }
#endif
