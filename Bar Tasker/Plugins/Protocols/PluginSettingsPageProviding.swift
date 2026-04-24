import SwiftUI

@MainActor
protocol PluginSettingsPageProviding: Plugin {
  var settingsIconSystemName: String { get }
  func makeSettingsView(manager: AppCoordinator) -> AnyView
}
