import SwiftUI

@MainActor
protocol PluginSettingsPageProviding: Plugin {
  var settingsIconSystemName: String { get }
  func makeSettingsView(manager: AppCoordinator) -> AnyView
  /// Short label SettingsView shows next to the plugin's name in the sidebar
  /// list (e.g. "Enabled", "Disabled", "Built-in plugin"). Each plugin owns
  /// the shape of this string so `SettingsView` doesn't have to switch on
  /// identifiers — see `docs/plugins.md`.
  func sidebarStatusLabel(manager: AppCoordinator) -> String
}

extension PluginSettingsPageProviding {
  /// Default: plugins that don't override the label just describe themselves
  /// as "Built-in plugin". The four native plugins override to show
  /// Enabled/Disabled against their own toggle state.
  func sidebarStatusLabel(manager: AppCoordinator) -> String { "Built-in plugin" }
}
