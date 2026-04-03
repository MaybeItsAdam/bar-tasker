import Foundation
import SwiftUI

extension BarTaskerManager {
  // MARK: - Timer Display

  /// Formatted elapsed time to 2 significant figures in the most readable unit.
  static func formattedTimer(_ elapsed: TimeInterval) -> String {
    BarTaskerTimerStore.formatted(elapsed)
  }

  /// Timer string to show in the menu bar, nil when no timer is active.
  var timerBarString: String? {
    guard timerMode == .visible, let currentTask else { return nil }
    let elapsed = totalElapsed(forTaskId: currentTask.id)
    let currentTaskHasActiveTimer = timedTaskId == currentTask.id
    guard elapsed > 0 || currentTaskHasActiveTimer else { return nil }
    return BarTaskerManager.formattedTimer(elapsed)
  }

  var timerIsEnabled: Bool { timerMode != .disabled }
  var timerIsVisible: Bool { timerMode == .visible }
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

  // MARK: - Shortcut Customization

  var configurableShortcutActions: [ConfigurableShortcutAction] {
    ConfigurableShortcutAction.allCases
  }

  func shortcutBinding(for action: ConfigurableShortcutAction) -> String {
    let override =
      customizableShortcutsByAction[action.rawValue]?.trimmingCharacters(
        in: .whitespacesAndNewlines)
      ?? ""
    return override.isEmpty ? action.defaultBinding : override
  }

  func setShortcutBinding(_ rawBinding: String, for action: ConfigurableShortcutAction) {
    let normalized = rawBinding.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedDefault =
      action.defaultBinding.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let normalizedInput = normalized.lowercased()

    if normalizedInput.isEmpty || normalizedInput == normalizedDefault {
      customizableShortcutsByAction.removeValue(forKey: action.rawValue)
      return
    }
    customizableShortcutsByAction[action.rawValue] = normalized
  }

  func resetConfigurableShortcutBindings() {
    customizableShortcutsByAction = [:]
  }

  func shortcutMatches(action: ConfigurableShortcutAction, keyToken: String) -> Bool {
    let normalizedToken = keyToken.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalizedToken.isEmpty else { return false }
    return Set(
      shortcutBinding(for: action).split(separator: ",").map {
        String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      }
    ).contains(normalizedToken)
  }

  func shortcutMatchesSequence(action: ConfigurableShortcutAction, sequence: String) -> Bool {
    let normalizedSequence = sequence.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalizedSequence.isEmpty else { return false }
    return Set(
      shortcutBinding(for: action).split(separator: ",").map {
        String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      }
    ).contains(normalizedSequence)
  }

  // MARK: - Theme

  var themeAccentColor: Color {
    let defaultAccent = BarTaskerThemeColorCodec.color(from: ThemeAccentPreset.blue.hex) ?? .blue
    switch themeAccentPreset {
    case .custom:
      if let resolved = BarTaskerThemeColorCodec.color(from: themeCustomAccentHex) {
        return resolved
      }
      return defaultAccent
    default:
      return BarTaskerThemeColorCodec.color(from: themeAccentPreset.hex) ?? defaultAccent
    }
  }

  func setCustomThemeAccentColor(_ color: Color) {
    guard let hex = BarTaskerThemeColorCodec.hex(from: color),
      let normalized = BarTaskerThemeColorCodec.normalizedHex(hex)
    else { return }
    themeCustomAccentHex = normalized
    themeAccentPreset = .custom
  }

  static func normalizedThemeColorTokenHexOverrides(_ raw: [String: String]) -> [String: String] {
    guard !raw.isEmpty else { return [:] }
    var normalized: [String: String] = [:]
    for token in BarTaskerThemeColorToken.allCases {
      guard let value = raw[token.rawValue] else { continue }
      guard let hex = BarTaskerThemeColorCodec.normalizedHex(value) else { continue }
      normalized[token.rawValue] = hex
    }
    return normalized
  }

  var configurableThemeColorTokens: [BarTaskerThemeColorToken] {
    BarTaskerThemeColorToken.allCases
  }

  func themeColor(for token: BarTaskerThemeColorToken) -> Color {
    if let storedHex = themeColorTokenHexOverrides[token.rawValue],
      let resolved = BarTaskerThemeColorCodec.color(from: storedHex)
    {
      return resolved
    }
    return defaultThemeColor(for: token)
  }

  func themeColorHex(for token: BarTaskerThemeColorToken) -> String {
    if let storedHex = themeColorTokenHexOverrides[token.rawValue],
      let normalized = BarTaskerThemeColorCodec.normalizedHex(storedHex)
    {
      return normalized
    }
    return BarTaskerThemeColorCodec.hex(from: defaultThemeColor(for: token)) ?? ""
  }

  func setThemeColor(_ token: BarTaskerThemeColorToken, color: Color) {
    guard let hex = BarTaskerThemeColorCodec.hex(from: color),
      let normalized = BarTaskerThemeColorCodec.normalizedHex(hex)
    else { return }
    themeColorTokenHexOverrides[token.rawValue] = normalized
  }

  func setThemeColorHex(_ token: BarTaskerThemeColorToken, hex: String) {
    let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      themeColorTokenHexOverrides.removeValue(forKey: token.rawValue)
      return
    }
    guard let normalized = BarTaskerThemeColorCodec.normalizedHex(trimmed) else { return }
    themeColorTokenHexOverrides[token.rawValue] = normalized
  }

  func resetThemeColorOverride(_ token: BarTaskerThemeColorToken) {
    themeColorTokenHexOverrides.removeValue(forKey: token.rawValue)
  }

  func resetAllThemeColorOverrides() {
    themeColorTokenHexOverrides = [:]
  }

  var hasThemeColorOverrides: Bool {
    !themeColorTokenHexOverrides.isEmpty
  }

  func exportThemeJSON(prettyPrinted: Bool = true) -> String {
    let document = BarTaskerThemeDocument(
      version: 1,
      appearance: themeAppearanceIdentifier(appTheme),
      accentPreset: themeAccentPreset.rawValue,
      customAccentHex: themeCustomAccentHex,
      colorOverrides: themeColorTokenHexOverrides
    )
    let encoder = JSONEncoder()
    if prettyPrinted {
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    } else {
      encoder.outputFormatting = [.sortedKeys]
    }
    guard let data = try? encoder.encode(document),
      let json = String(data: data, encoding: .utf8)
    else { return "" }
    return json
  }

  func importThemeJSON(_ raw: String) throws {
    guard let data = raw.data(using: .utf8) else {
      throw ThemeImportError.invalidJSON
    }
    let decoder = JSONDecoder()
    let document: BarTaskerThemeDocument
    do {
      document = try decoder.decode(BarTaskerThemeDocument.self, from: data)
    } catch {
      throw ThemeImportError.invalidJSON
    }

    guard let resolvedAppearance = themeAppearance(from: document.appearance) else {
      throw ThemeImportError.invalidAppearance
    }
    guard let resolvedPreset = ThemeAccentPreset(rawValue: document.accentPreset) else {
      throw ThemeImportError.invalidAccentPreset
    }
    guard let normalizedAccentHex = BarTaskerThemeColorCodec.normalizedHex(document.customAccentHex)
    else {
      throw ThemeImportError.invalidCustomAccentHex
    }

    appTheme = resolvedAppearance
    themeAccentPreset = resolvedPreset
    themeCustomAccentHex = normalizedAccentHex
    themeColorTokenHexOverrides = Self.normalizedThemeColorTokenHexOverrides(
      document.colorOverrides)
  }

  private func defaultThemeColor(for token: BarTaskerThemeColorToken) -> Color {
    switch token {
    case .panelBackground:
      return Color(NSColor.windowBackgroundColor)
    case .panelDivider:
      return Color(NSColor.separatorColor).opacity(0.85)
    case .panelSurface:
      return Color.secondary.opacity(0.08)
    case .panelSurfaceElevated:
      return Color.secondary.opacity(0.14)
    case .selectionBackground:
      return themeAccentColor.opacity(0.2)
    case .selectionForeground:
      return themeAccentColor
    case .focusRing:
      return themeAccentColor.opacity(0.9)
    case .textPrimary:
      return .primary
    case .textSecondary:
      return .secondary
    case .textMuted:
      return .secondary.opacity(0.8)
    case .link:
      return .blue
    case .success:
      return .green
    case .warning:
      return .orange
    case .danger:
      return .red
    }
  }

  private func themeAppearanceIdentifier(_ theme: AppTheme) -> String {
    switch theme {
    case .system: return "system"
    case .light: return "light"
    case .dark: return "dark"
    }
  }

  private func themeAppearance(from raw: String) -> AppTheme? {
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "system": return .system
    case "light": return .light
    case "dark": return .dark
    default: return nil
    }
  }

  func resetThemeCustomization() {
    themeAccentPreset = .blue
    themeCustomAccentHex = ThemeAccentPreset.blue.hex
    themeColorTokenHexOverrides = [:]
  }

  enum ThemeImportError: Error, LocalizedError {
    case invalidJSON
    case invalidAppearance
    case invalidAccentPreset
    case invalidCustomAccentHex

    var errorDescription: String? {
      switch self {
      case .invalidJSON:
        return "The provided theme JSON is invalid."
      case .invalidAppearance:
        return "Theme appearance must be one of: system, light, dark."
      case .invalidAccentPreset:
        return "Accent preset is invalid."
      case .invalidCustomAccentHex:
        return "Custom accent color must be a valid #RRGGBB hex value."
      }
    }
  }
}
