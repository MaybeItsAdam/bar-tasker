import Foundation

extension BarTaskerManager {
  var hasPendingObsidianSync: Bool { integrations.hasPendingObsidianSync }
  var pendingSyncMenuBarPrefix: String { integrations.pendingSyncMenuBarPrefix }

  // MARK: - Command Palette (delegates to QuickEntryManager)

  func filteredCommandSuggestions(query: String) -> [CommandSuggestion] {
    quickEntry.filteredCommandSuggestions(
      query: query,
      obsidianEnabled: integrations.obsidianIntegrationEnabled,
      googleCalendarEnabled: integrations.googleCalendarIntegrationEnabled,
      mcpEnabled: integrations.mcpIntegrationEnabled
    )
  }

  @MainActor func selectNextCommandSuggestion(for query: String) {
    quickEntry.selectNextCommandSuggestion(
      for: query,
      obsidianEnabled: integrations.obsidianIntegrationEnabled,
      googleCalendarEnabled: integrations.googleCalendarIntegrationEnabled,
      mcpEnabled: integrations.mcpIntegrationEnabled
    )
  }

  @MainActor func selectPreviousCommandSuggestion(for query: String) {
    quickEntry.selectPreviousCommandSuggestion(
      for: query,
      obsidianEnabled: integrations.obsidianIntegrationEnabled,
      googleCalendarEnabled: integrations.googleCalendarIntegrationEnabled,
      mcpEnabled: integrations.mcpIntegrationEnabled
    )
  }
}
