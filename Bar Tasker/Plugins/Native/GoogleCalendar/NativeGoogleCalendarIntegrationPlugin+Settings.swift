import SwiftUI

@MainActor
extension NativeGoogleCalendarIntegrationPlugin: PluginSettingsPageProviding {
  var settingsIconSystemName: String { "calendar" }

  func makeSettingsView(manager: BarTaskerManager) -> AnyView {
    AnyView(
      GoogleCalendarIntegrationPluginSettingsView(
        manager: manager,
        plugin: self
      )
    )
  }
}

private struct GoogleCalendarIntegrationPluginSettingsView: View {
  @ObservedObject var manager: BarTaskerManager
  @ObservedObject var plugin: NativeGoogleCalendarIntegrationPlugin
  @State private var pluginActionError: String?

  var body: some View {
    Section(header: Text("Google Calendar Plugin")) {
      Toggle(
        "Enable Google Calendar integration",
        isOn: $manager.integrations.googleCalendarIntegrationEnabled
      )

      if manager.integrations.googleCalendarIntegrationEnabled {
        VStack(alignment: .leading, spacing: 10) {
          Text("OAuth Client ID (Desktop app)")
          TextField(
            "",
            text: $plugin.oauthClientID,
            prompt: Text("1234567890-abc123.apps.googleusercontent.com")
          )
          .textFieldStyle(.roundedBorder)
          .labelsHidden()
          .autocorrectionDisabled()

          Text("Calendar ID")
          TextField("", text: $plugin.targetCalendarID, prompt: Text("primary"))
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .autocorrectionDisabled()

          Toggle("Open created event in browser", isOn: $plugin.openCreatedEventInBrowser)

          HStack(spacing: 8) {
            Button(plugin.isAuthenticated ? "Re-authenticate" : "Sign in with Google") {
              Task { await performSignIn() }
            }
            .disabled(plugin.isAuthenticating || !plugin.hasOAuthClientConfiguration)

            Button("Sign out") {
              plugin.disconnectAuthentication()
              pluginActionError = nil
            }
            .disabled(plugin.isAuthenticating || !plugin.isAuthenticated)

            Button("Create event from selected task") {
              manager.openCurrentTaskInGoogleCalendar()
            }
            .disabled(
              plugin.isAuthenticating || !plugin.hasOAuthClientConfiguration
                || !plugin.isAuthenticated
            )

            Spacer()
            if plugin.isAuthenticating {
              ProgressView()
                .scaleEffect(0.8)
            }
          }

          Text(plugin.authenticationStatusDescription)
            .font(.caption)
            .foregroundColor(plugin.isAuthenticated ? .green : .secondary)

          if let pluginActionError, !pluginActionError.isEmpty {
            Text(pluginActionError)
              .font(.caption)
              .foregroundColor(.red)
          }

          Text(
            "This integration creates Google Calendar events from tasks. OAuth setup and sign-in are required."
          )
          .font(.caption2)
          .foregroundColor(.secondary)
        }
        .padding(.top, 4)
      } else {
        Text("Google Calendar integration is disabled.")
          .foregroundColor(.secondary)
          .font(.caption)
      }
    }
  }

  @MainActor
  private func performSignIn() async {
    pluginActionError = nil
    do {
      try await plugin.beginAuthentication()
    } catch {
      if let localizedError = error as? LocalizedError,
        let message = localizedError.errorDescription
      {
        pluginActionError = message
      } else {
        pluginActionError = error.localizedDescription
      }
    }
  }
}
