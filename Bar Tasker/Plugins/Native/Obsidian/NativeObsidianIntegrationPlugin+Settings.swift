import SwiftUI

@MainActor
extension NativeObsidianIntegrationPlugin: PluginSettingsPageProviding {
  var settingsIconSystemName: String { "book.closed" }

  func makeSettingsView(manager: BarTaskerManager) -> AnyView {
    AnyView(ObsidianIntegrationPluginSettingsView(manager: manager))
  }
}

private struct ObsidianIntegrationPluginSettingsView: View {
  @ObservedObject var manager: BarTaskerManager

  var body: some View {
    Section(header: Text("Obsidian Plugin")) {
      Toggle("Enable Obsidian integration", isOn: $manager.integrations.obsidianIntegrationEnabled)

      if manager.integrations.obsidianIntegrationEnabled {
        VStack(alignment: .leading, spacing: 8) {
          Text("Obsidian Inbox")
          if manager.integrations.obsidianInboxPath.isEmpty {
            Text("No folder selected")
              .foregroundColor(.secondary)
              .font(.caption)
          } else {
            Text(manager.integrations.obsidianInboxPath)
              .font(.caption)
              .textSelection(.enabled)
          }

          HStack {
            Button("Choose Folder") {
              manager.chooseObsidianInboxFolder()
            }
            if !manager.integrations.obsidianInboxPath.isEmpty {
              Button("Clear") {
                manager.clearObsidianInboxFolder()
              }
            }
            Spacer()
            if manager.hasPendingObsidianSync {
              Text(manager.pendingSyncMenuBarPrefix)
                .font(.caption)
                .foregroundColor(.orange)
            }
          }
        }
        .padding(.top, 4)
      } else {
        Text("Obsidian integration is disabled.")
          .foregroundColor(.secondary)
          .font(.caption)
      }
    }
  }
}
