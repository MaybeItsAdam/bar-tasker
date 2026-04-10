import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class PreferencesManager: ObservableObject {
  typealias AppTheme = BarTaskerManager.AppTheme
  typealias ThemeAccentPreset = BarTaskerManager.ThemeAccentPreset
  typealias QuickAddLocationMode = BarTaskerManager.QuickAddLocationMode
  typealias ConfigurableShortcutAction = BarTaskerManager.ConfigurableShortcutAction

  private let preferencesStore: BarTaskerPreferencesStore
  private var cancellables = Set<AnyCancellable>()

  @Published var confirmBeforeDelete: Bool
  @Published var launchAtLogin: Bool
  @Published var ignoreKeychainInDebug: Bool
  @Published var appTheme: AppTheme
  @Published var themeAccentPreset: ThemeAccentPreset
  @Published var themeCustomAccentHex: String
  @Published var themeColorTokenHexOverrides: [String: String]
  @Published var globalHotkeyEnabled: Bool
  /// Carbon keyCode for the global hotkey (default 49 = Space)
  @Published var globalHotkeyKeyCode: Int
  /// Carbon modifier mask (default 0x0800 = optionKey i.e. ⌥)
  @Published var globalHotkeyModifiers: Int
  @Published var quickAddHotkeyEnabled: Bool
  /// Carbon keyCode for the quick add hotkey (default 11 = B)
  @Published var quickAddHotkeyKeyCode: Int
  /// Carbon modifier mask (default 0x0A00 = shift+option)
  @Published var quickAddHotkeyModifiers: Int
  @Published var quickAddLocationMode: QuickAddLocationMode
  @Published var quickAddSpecificParentTaskId: String
  @Published var customizableShortcutsByAction: [String: String]
  @Published var maxTitleWidth: Double
  @Published var showTaskBreadcrumbContext: Bool
  @Published var namedTimeMorningHour: Int
  @Published var namedTimeAfternoonHour: Int
  @Published var namedTimeEveningHour: Int
  @Published var namedTimeEodHour: Int

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
      default: BarTaskerManager.CarbonKey.space
    )
    self.globalHotkeyModifiers = preferencesStore.int(
      .globalHotkeyModifiers,
      default: BarTaskerManager.CarbonModifier.option
    )
    self.quickAddHotkeyEnabled = preferencesStore.bool(.quickAddHotkeyEnabled, default: false)
    self.quickAddHotkeyKeyCode = preferencesStore.int(
      .quickAddHotkeyKeyCode,
      default: BarTaskerManager.CarbonKey.b
    )
    self.quickAddHotkeyModifiers = preferencesStore.int(
      .quickAddHotkeyModifiers,
      default: BarTaskerManager.CarbonModifier.shiftOption
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
    setupBindings()
  }

  private func setupBindings() {
    $confirmBeforeDelete.sink { [weak self] in
      self?.preferencesStore.set($0, for: .confirmBeforeDelete)
    }
    .store(in: &cancellables)

    $launchAtLogin.sink { [weak self] in
      self?.preferencesStore.set($0, for: .launchAtLogin)
    }
    .store(in: &cancellables)

    #if DEBUG
      $ignoreKeychainInDebug
        .dropFirst()
        .sink { [weak self] in
          self?.preferencesStore.set($0, for: .ignoreKeychainInDebug)
        }
        .store(in: &cancellables)
    #endif

    $appTheme.sink { [weak self] in
      self?.preferencesStore.set($0.rawValue, for: .appThemeRawValue)
    }
    .store(in: &cancellables)

    $themeAccentPreset.sink { [weak self] in
      self?.preferencesStore.set($0.rawValue, for: .themeAccentPresetRawValue)
    }
    .store(in: &cancellables)

    $themeCustomAccentHex
      .dropFirst()
      .sink { [weak self] value in
        guard let self else { return }
        let normalized =
          BarTaskerThemeColorCodec.normalizedHex(value) ?? ThemeAccentPreset.blue.hex
        if normalized != value {
          self.themeCustomAccentHex = normalized
          return
        }
        self.preferencesStore.set(normalized, for: .themeCustomAccentHex)
      }
      .store(in: &cancellables)

    $themeColorTokenHexOverrides
      .dropFirst()
      .sink { [weak self] value in
        guard let self else { return }
        let normalized = Self.normalizedThemeColorTokenHexOverrides(value)
        if normalized != value {
          self.themeColorTokenHexOverrides = normalized
          return
        }
        self.preferencesStore.set(normalized, for: .themeColorTokenHexOverrides)
      }
      .store(in: &cancellables)

    $showTaskBreadcrumbContext.sink { [weak self] in
      self?.preferencesStore.set($0, for: .showTaskBreadcrumbContext)
    }
    .store(in: &cancellables)

    $globalHotkeyEnabled.sink { [weak self] in
      self?.preferencesStore.set($0, for: .globalHotkeyEnabled)
    }
    .store(in: &cancellables)

    $globalHotkeyKeyCode.sink { [weak self] in
      self?.preferencesStore.set($0, for: .globalHotkeyKeyCode)
    }
    .store(in: &cancellables)

    $globalHotkeyModifiers.sink { [weak self] in
      self?.preferencesStore.set($0, for: .globalHotkeyModifiers)
    }
    .store(in: &cancellables)

    $quickAddHotkeyEnabled.sink { [weak self] in
      self?.preferencesStore.set($0, for: .quickAddHotkeyEnabled)
    }
    .store(in: &cancellables)

    $quickAddHotkeyKeyCode.sink { [weak self] in
      self?.preferencesStore.set($0, for: .quickAddHotkeyKeyCode)
    }
    .store(in: &cancellables)

    $quickAddHotkeyModifiers.sink { [weak self] in
      self?.preferencesStore.set($0, for: .quickAddHotkeyModifiers)
    }
    .store(in: &cancellables)

    $quickAddLocationMode.sink { [weak self] in
      self?.preferencesStore.set($0.rawValue, for: .quickAddLocationModeRawValue)
    }
    .store(in: &cancellables)

    $quickAddSpecificParentTaskId.sink { [weak self] in
      self?.preferencesStore.set($0, for: .quickAddSpecificParentTaskId)
    }
    .store(in: &cancellables)

    $customizableShortcutsByAction.sink { [weak self] value in
      self?.preferencesStore.set(value, for: .customizableShortcutsByAction)
    }
    .store(in: &cancellables)

    $maxTitleWidth.sink { [weak self] in
      self?.preferencesStore.set($0, for: .maxTitleWidth)
    }
    .store(in: &cancellables)

    $namedTimeMorningHour.sink { [weak self] in
      self?.preferencesStore.set($0, for: .namedTimeMorningHour)
    }
    .store(in: &cancellables)

    $namedTimeAfternoonHour.sink { [weak self] in
      self?.preferencesStore.set($0, for: .namedTimeAfternoonHour)
    }
    .store(in: &cancellables)

    $namedTimeEveningHour.sink { [weak self] in
      self?.preferencesStore.set($0, for: .namedTimeEveningHour)
    }
    .store(in: &cancellables)

    $namedTimeEodHour.sink { [weak self] in
      self?.preferencesStore.set($0, for: .namedTimeEodHour)
    }
    .store(in: &cancellables)
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
