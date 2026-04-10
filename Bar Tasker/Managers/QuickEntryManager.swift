import Combine
import Foundation

@MainActor
class QuickEntryManager: ObservableObject {
  @Published var searchText: String = ""
  @Published var quickEntryText: String = ""
  @Published var quickEntryMode: BarTaskerManager.QuickEntryMode = .search
  @Published var isQuickEntryFocused: Bool = false
  @Published var editCursorAtEnd: Bool = true  // true = append (a), false = insert (i)
  @Published var pendingDeleteConfirmation: Bool = false
  @Published var completingTaskId: Int? = nil
  @Published var commandSuggestionIndex: Int = 0
  @Published var keyBuffer: String = ""

  static let commandSuggestions: [BarTaskerManager.CommandSuggestion] =
    BarTaskerCommandEngine.suggestions.map {
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
  ) -> [BarTaskerManager.CommandSuggestion] {
    let filtered = BarTaskerCommandEngine.filteredSuggestions(query: query).filter { suggestion in
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

  // MARK: - Search state

  var isSearchFilterActive: Bool { !searchText.isEmpty && quickEntryMode == .search }
}
