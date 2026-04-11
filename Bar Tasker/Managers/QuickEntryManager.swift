import Foundation
import Observation

@MainActor
@Observable class QuickEntryManager {
  var searchText: String = "" {
    didSet { onCacheRelevantChange?() }
  }
  var quickEntryText: String = ""
  var quickEntryMode: QuickEntryMode = .search {
    didSet { onCacheRelevantChange?() }
  }
  var isQuickEntryFocused: Bool = false
  var editCursorAtEnd: Bool = true  // true = append (a), false = insert (i)
  var pendingDeleteConfirmation: Bool = false
  var completingTaskId: Int? = nil
  var commandSuggestionIndex: Int = 0
  var keyBuffer: String = ""

  @ObservationIgnored var onCacheRelevantChange: (() -> Void)?
  @ObservationIgnored var integrationFlagsProvider: (() -> (obsidian: Bool, googleCalendar: Bool, mcp: Bool))?

  static let commandSuggestions: [CommandSuggestion] =
    CommandEngine.suggestions.map {
      .init(
        label: $0.label,
        command: $0.command,
        preview: $0.preview,
        keybind: $0.keybind,
        submitImmediately: $0.submitImmediately
      )
    }

  // MARK: - Command Palette

  func filteredCommandSuggestions(
    query: String,
    obsidianEnabled: Bool,
    googleCalendarEnabled: Bool,
    mcpEnabled: Bool
  ) -> [CommandSuggestion] {
    let filtered = CommandEngine.filteredSuggestions(query: query).filter { suggestion in
      switch suggestion.command {
      case "sync obsidian", "open obsidian new window", "choose obsidian inbox",
        "clear obsidian inbox", "link obsidian folder", "create obsidian folder",
        "clear obsidian folder":
        return obsidianEnabled
      case "sync google calendar":
        return googleCalendarEnabled
      case "refresh mcp path", "copy mcp config", "open mcp guide":
        return mcpEnabled
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

  func selectNextCommandSuggestion(
    for query: String,
    obsidianEnabled: Bool,
    googleCalendarEnabled: Bool,
    mcpEnabled: Bool
  ) {
    let total = filteredCommandSuggestions(
      query: query,
      obsidianEnabled: obsidianEnabled,
      googleCalendarEnabled: googleCalendarEnabled,
      mcpEnabled: mcpEnabled
    ).count
    guard total > 0 else { return }
    commandSuggestionIndex = min(commandSuggestionIndex + 1, total - 1)
  }

  func selectPreviousCommandSuggestion(
    for query: String,
    obsidianEnabled: Bool,
    googleCalendarEnabled: Bool,
    mcpEnabled: Bool
  ) {
    let total = filteredCommandSuggestions(
      query: query,
      obsidianEnabled: obsidianEnabled,
      googleCalendarEnabled: googleCalendarEnabled,
      mcpEnabled: mcpEnabled
    ).count
    guard total > 0 else { return }
    commandSuggestionIndex = max(commandSuggestionIndex - 1, 0)
  }

  // MARK: - Command palette (no-argument overloads using integrationFlagsProvider)

  private func currentIntegrationFlags() -> (obsidian: Bool, googleCalendar: Bool, mcp: Bool) {
    integrationFlagsProvider?() ?? (obsidian: false, googleCalendar: false, mcp: false)
  }

  func filteredCommandSuggestions(query: String) -> [CommandSuggestion] {
    let flags = currentIntegrationFlags()
    return filteredCommandSuggestions(
      query: query,
      obsidianEnabled: flags.obsidian,
      googleCalendarEnabled: flags.googleCalendar,
      mcpEnabled: flags.mcp
    )
  }

  func selectNextCommandSuggestion(for query: String) {
    let flags = currentIntegrationFlags()
    selectNextCommandSuggestion(
      for: query,
      obsidianEnabled: flags.obsidian,
      googleCalendarEnabled: flags.googleCalendar,
      mcpEnabled: flags.mcp
    )
  }

  func selectPreviousCommandSuggestion(for query: String) {
    let flags = currentIntegrationFlags()
    selectPreviousCommandSuggestion(
      for: query,
      obsidianEnabled: flags.obsidian,
      googleCalendarEnabled: flags.googleCalendar,
      mcpEnabled: flags.mcp
    )
  }

  // MARK: - Search state

  var isSearchFilterActive: Bool { !searchText.isEmpty && quickEntryMode == .search }
}
