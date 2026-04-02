import SwiftUI

@MainActor
protocol PluginSettingsPageProviding: BarTaskerPlugin {
  var settingsIconSystemName: String { get }
  func makeSettingsView(manager: BarTaskerManager) -> AnyView
}
