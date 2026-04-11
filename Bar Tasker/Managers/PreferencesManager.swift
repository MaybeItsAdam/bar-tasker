import AppKit
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable final class PreferencesManager {
  @ObservationIgnored private let preferencesStore: BarTaskerPreferencesStore

  @ObservationIgnored var onLaunchAtLoginChanged: ((Bool) -> Void)?
  @ObservationIgnored var onIgnoreKeychainInDebugChanged: (() -> Void)?

  var confirmBeforeDelete: Bool {
    didSet { preferencesStore.set(confirmBeforeDelete, for: .confirmBeforeDelete) }
  }
  var launchAtLogin: Bool {
    didSet {
      preferencesStore.set(launchAtLogin, for: .launchAtLogin)
      onLaunchAtLoginChanged?(launchAtLogin)
    }
  }
  var ignoreKeychainInDebug: Bool {
    didSet {
      #if DEBUG
        preferencesStore.set(ignoreKeychainInDebug, for: .ignoreKeychainInDebug)
        onIgnoreKeychainInDebugChanged?()
      #endif
    }
  }
  var appTheme: AppTheme {
    didSet { preferencesStore.set(appTheme.rawValue, for: .appThemeRawValue) }
  }
  var themeAccentPreset: ThemeAccentPreset {
    didSet { preferencesStore.set(themeAccentPreset.rawValue, for: .themeAccentPresetRawValue) }
  }
  var themeCustomAccentHex: String {
    didSet {
      let normalized =
        BarTaskerThemeColorCodec.normalizedHex(themeCustomAccentHex) ?? ThemeAccentPreset.blue.hex
      if normalized != themeCustomAccentHex {
        themeCustomAccentHex = normalized
        return
      }
      preferencesStore.set(normalized, for: .themeCustomAccentHex)
    }
  }
  var themeColorTokenHexOverrides: [String: String] {
    didSet {
      let normalized = Self.normalizedThemeColorTokenHexOverrides(themeColorTokenHexOverrides)
      if normalized != themeColorTokenHexOverrides {
        themeColorTokenHexOverrides = normalized
        return
      }
      preferencesStore.set(normalized, for: .themeColorTokenHexOverrides)
    }
  }
  var globalHotkeyEnabled: Bool {
    didSet { preferencesStore.set(globalHotkeyEnabled, for: .globalHotkeyEnabled) }
  }
  /// Carbon keyCode for the global hotkey (default 49 = Space)
  var globalHotkeyKeyCode: Int {
    didSet { preferencesStore.set(globalHotkeyKeyCode, for: .globalHotkeyKeyCode) }
  }
  /// Carbon modifier mask (default 0x0800 = optionKey i.e. ⌥)
  var globalHotkeyModifiers: Int {
    didSet { preferencesStore.set(globalHotkeyModifiers, for: .globalHotkeyModifiers) }
  }
  var quickAddHotkeyEnabled: Bool {
    didSet { preferencesStore.set(quickAddHotkeyEnabled, for: .quickAddHotkeyEnabled) }
  }
  /// Carbon keyCode for the quick add hotkey (default 11 = B)
  var quickAddHotkeyKeyCode: Int {
    didSet { preferencesStore.set(quickAddHotkeyKeyCode, for: .quickAddHotkeyKeyCode) }
  }
  /// Carbon modifier mask (default 0x0A00 = shift+option)
  var quickAddHotkeyModifiers: Int {
    didSet { preferencesStore.set(quickAddHotkeyModifiers, for: .quickAddHotkeyModifiers) }
  }
  var quickAddLocationMode: QuickAddLocationMode {
    didSet { preferencesStore.set(quickAddLocationMode.rawValue, for: .quickAddLocationModeRawValue) }
  }
  var quickAddSpecificParentTaskId: String {
    didSet { preferencesStore.set(quickAddSpecificParentTaskId, for: .quickAddSpecificParentTaskId) }
  }
  var customizableShortcutsByAction: [String: String] {
    didSet { preferencesStore.set(customizableShortcutsByAction, for: .customizableShortcutsByAction) }
  }
  var maxTitleWidth: Double {
    didSet { preferencesStore.set(maxTitleWidth, for: .maxTitleWidth) }
  }
  var showTaskBreadcrumbContext: Bool {
    didSet { preferencesStore.set(showTaskBreadcrumbContext, for: .showTaskBreadcrumbContext) }
  }
  var namedTimeMorningHour: Int {
    didSet { preferencesStore.set(namedTimeMorningHour, for: .namedTimeMorningHour) }
  }
  var namedTimeAfternoonHour: Int {
    didSet { preferencesStore.set(namedTimeAfternoonHour, for: .namedTimeAfternoonHour) }
  }
  var namedTimeEveningHour: Int {
    didSet { preferencesStore.set(namedTimeEveningHour, for: .namedTimeEveningHour) }
  }
  var namedTimeEodHour: Int {
    didSet { preferencesStore.set(namedTimeEodHour, for: .namedTimeEodHour) }
  }

  init(preferencesStore: BarTaskerPreferencesStore) {
    self.preferencesStore = preferencesStore
    self.confirmBeforeDelete = preferencesStore.bool(.confirmBeforeDelete, default: true)
    self.launchAtLogin = preferencesStore.bool(.launchAtLogin, default: false)
    #if DEBUG
      self.ignoreKeychainInDebug = preferencesStore.bool(.ignoreKeychainInDebug, default: true)
    #else
      self.ignoreKeychainInDebug = true
    #endif
    self.appTheme = AppTheme(rawValue: preferencesStore.int(.appThemeRawValue, default: 0)) ?? .system
    self.themeAccentPreset =
      ThemeAccentPreset(
        rawValue: preferencesStore.string(
          .themeAccentPresetRawValue,
          default: ThemeAccentPreset.blue.rawValue
        )
      ) ?? .blue
    self.themeCustomAccentHex =
      BarTaskerThemeColorCodec.normalizedHex(
        preferencesStore.string(.themeCustomAccentHex, default: ThemeAccentPreset.blue.hex)
      ) ?? ThemeAccentPreset.blue.hex
    self.themeColorTokenHexOverrides = Self.normalizedThemeColorTokenHexOverrides(
      preferencesStore.stringDictionary(.themeColorTokenHexOverrides)
    )
    self.globalHotkeyEnabled = preferencesStore.bool(.globalHotkeyEnabled, default: false)
    self.globalHotkeyKeyCode = preferencesStore.int(
      .globalHotkeyKeyCode,
      default: BarTaskerCoordinator.CarbonKey.space
    )
    self.globalHotkeyModifiers = preferencesStore.int(
      .globalHotkeyModifiers,
      default: BarTaskerCoordinator.CarbonModifier.option
    )
    self.quickAddHotkeyEnabled = preferencesStore.bool(.quickAddHotkeyEnabled, default: false)
    self.quickAddHotkeyKeyCode = preferencesStore.int(
      .quickAddHotkeyKeyCode,
      default: BarTaskerCoordinator.CarbonKey.b
    )
    self.quickAddHotkeyModifiers = preferencesStore.int(
      .quickAddHotkeyModifiers,
      default: BarTaskerCoordinator.CarbonModifier.shiftOption
    )
    self.quickAddLocationMode =
      QuickAddLocationMode(
        rawValue: preferencesStore.int(.quickAddLocationModeRawValue, default: 0)
      ) ?? .defaultRoot
    self.quickAddSpecificParentTaskId = preferencesStore.string(.quickAddSpecificParentTaskId)
    self.customizableShortcutsByAction = preferencesStore.stringDictionary(.customizableShortcutsByAction)
    self.maxTitleWidth = preferencesStore.double(.maxTitleWidth, default: 150.0)
    self.showTaskBreadcrumbContext = preferencesStore.bool(.showTaskBreadcrumbContext, default: false)
    self.namedTimeMorningHour = preferencesStore.int(.namedTimeMorningHour, default: 9)
    self.namedTimeAfternoonHour = preferencesStore.int(.namedTimeAfternoonHour, default: 14)
    self.namedTimeEveningHour = preferencesStore.int(.namedTimeEveningHour, default: 18)
    self.namedTimeEodHour = preferencesStore.int(.namedTimeEodHour, default: 17)
  }

  var configurableShortcutActions: [ConfigurableShortcutAction] {
    ConfigurableShortcutAction.allCases
  }

  func shortcutBinding(for action: ConfigurableShortcutAction) -> String {
    let override =
      customizableShortcutsByAction[action.rawValue]?.trimmingCharacters(
        in: .whitespacesAndNewlines
      )
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
      document.colorOverrides
    )
  }

  func resetThemeCustomization() {
    themeAccentPreset = .blue
    themeCustomAccentHex = ThemeAccentPreset.blue.hex
    themeColorTokenHexOverrides = [:]
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
}
