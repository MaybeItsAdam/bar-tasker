import Foundation

extension BarTaskerManager {
  // Timer display methods are now on TimerManager
  var hasPendingObsidianSync: Bool { !pendingObsidianSyncTaskIds.isEmpty }
  var pendingSyncMenuBarPrefix: String {
    guard hasPendingObsidianSync else { return "" }
    return pendingObsidianSyncTaskIds.count == 1
      ? "Pending Sync" : "Pending Sync (\(pendingObsidianSyncTaskIds.count))"
  }

  // MARK: - Command Palette

  func filteredCommandSuggestions(query: String) -> [CommandSuggestion] {
    let filtered = BarTaskerCommandEngine.filteredSuggestions(query: query).filter { suggestion in
      switch suggestion.command {
      case "sync obsidian", "open obsidian new window", "choose obsidian inbox",
        "clear obsidian inbox", "link obsidian folder", "create obsidian folder",
        "clear obsidian folder":
        return obsidianIntegrationEnabled
      case "sync google calendar":
        return googleCalendarIntegrationEnabled
      case "refresh mcp path", "copy mcp config", "open mcp guide":
        return mcpIntegrationEnabled
      default:
        return true
      }
    }

    return filtered.map {
      .init(
        label: $0.label,
        command: $0.command,
        preview: $0.preview,
        keybind: $0.keybind,
        submitImmediately: $0.submitImmediately
      )
    }
  }

  @MainActor func selectNextCommandSuggestion(for query: String) {
    let total = filteredCommandSuggestions(query: query).count
    guard total > 0 else { return }
    commandSuggestionIndex = min(commandSuggestionIndex + 1, total - 1)
  }

  @MainActor func selectPreviousCommandSuggestion(for query: String) {
    let total = filteredCommandSuggestions(query: query).count
    guard total > 0 else { return }
    commandSuggestionIndex = max(commandSuggestionIndex - 1, 0)
  }
}
