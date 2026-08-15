import Foundation

enum OnboardingDialog: String, CaseIterable, Identifiable {
  case pluginSelection
  case checkvist
  case obsidian
  case googleCalendar
  case mcp

  var id: String { rawValue }
}
