import SwiftUI

@MainActor
extension NativeMCPIntegrationPlugin: PluginSettingsPageProviding {
  var settingsIconSystemName: String { "link" }

  func makeSettingsView(manager: BarTaskerCoordinator) -> AnyView {
    AnyView(MCPIntegrationPluginSettingsView(manager: manager))
  }
}

private struct MCPIntegrationPluginSettingsView: View {
  var manager: BarTaskerCoordinator

  var body: some View {
    @Bindable var manager = manager
    Section(header: Text("MCP Plugin")) {
      Toggle("Enable MCP integration", isOn: $manager.integrations.mcpIntegrationEnabled)

      if manager.integrations.mcpIntegrationEnabled {
        VStack(alignment: .leading, spacing: 8) {
          Text("MCP Server")
          if manager.hasResolvedMCPServerCommand {
            Text(manager.integrations.mcpServerCommandPath)
              .font(.caption)
              .textSelection(.enabled)
          } else {
            Text("App command path not detected. Set BAR_TASKER_MCP_EXECUTABLE_PATH if needed.")
              .foregroundColor(.secondary)
              .font(.caption)
          }

          HStack {
            Button("Refresh Path") {
              manager.integrations.refreshMCPServerCommandPath()
            }
            Button("Copy Client Config") {
              manager.integrations.copyMCPClientConfigurationToClipboard()
            }
            Button("Open Guide") {
              manager.integrations.openMCPServerGuide()
            }
            Spacer()
          }

          ScrollView {
            Text(manager.mcpClientConfigurationPreview)
              .font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(minHeight: 120, maxHeight: 180)

          Text("Preview is redacted. Copied config includes your saved credentials.")
            .foregroundColor(.secondary)
            .font(.caption)
        }
        .padding(.top, 4)
      } else {
        Text("MCP integration is disabled.")
          .foregroundColor(.secondary)
          .font(.caption)
      }
    }
  }
}
