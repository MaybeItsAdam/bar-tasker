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
  @ObservationIgnored var shortcutBindingProvider: ((ConfigurableShortcutAction) -> String)?

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

    return filtered.map { suggestion in
      let keybind = resolvedKeybindLabel(for: suggestion)
      return CommandSuggestion(
        label: suggestion.label,
        command: suggestion.command,
        preview: suggestion.preview,
        keybind: keybind,
        submitImmediately: suggestion.submitImmediately
      )
    }
  }

  private func resolvedKeybindLabel(for suggestion: CommandPaletteSuggestion) -> String? {
    guard
      let raw = suggestion.boundActionRawValue,
      let action = ConfigurableShortcutAction(rawValue: raw),
      let provider = shortcutBindingProvider
    else { return suggestion.keybind }
    let binding = provider(action).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !binding.isEmpty else { return suggestion.keybind }
    return Self.formatBinding(binding)
  }

  /// Formats a comma-separated raw binding string (e.g. "cmd+k,;,shift+;") into a
  /// compact display like "⌘K · ;" suitable for the palette row.
  static func formatBinding(_ raw: String) -> String {
    raw.split(separator: ",")
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .map(prettifyToken)
      .joined(separator: " · ")
  }

  private static func prettifyToken(_ token: String) -> String {
    let parts = token.lowercased().split(separator: "+")
    var modifiers = ""
    var key = ""
    for part in parts {
      switch part {
      case "cmd": modifiers += "⌘"
      case "shift": modifiers += "⇧"
      case "ctrl": modifiers += "⌃"
      case "option", "opt", "alt": modifiers += "⌥"
      default: key = String(part)
      }
    }
    let prettyKey: String
    switch key {
    case "left": prettyKey = "←"
    case "right": prettyKey = "→"
    case "up": prettyKey = "↑"
    case "down": prettyKey = "↓"
    case "enter", "return": prettyKey = "⏎"
    case "tab": prettyKey = "⇥"
    case "escape", "esc": prettyKey = "⎋"
    case "space": prettyKey = "␣"
    case "delete", "del": prettyKey = "⌫"
    default: prettyKey = key.count == 1 ? key.uppercased() : key.capitalized
    }
    return modifiers + prettyKey
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
