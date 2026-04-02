import Foundation

final class BarTaskerPreferencesStore {
  enum Key: String {
    case checkvistUsername
    case checkvistListId
    case confirmBeforeDelete
    case showTaskBreadcrumbContext
    case rootTaskView
    case selectedRootDueBucketRawValue
    case selectedRootTag
    case launchAtLogin
    case globalHotkeyEnabled
    case globalHotkeyKeyCode
    case globalHotkeyModifiers
    case maxTitleWidth
    case timerBarLeading
    case timerMode
    case timerByTaskId
    case onboardingCompleted
    case pluginSelectionOnboardingCompleted
    case ignoreKeychainInDebug
    case obsidianIntegrationEnabled
    case googleCalendarIntegrationEnabled
    case mcpIntegrationEnabled
    case quickAddHotkeyEnabled
    case quickAddHotkeyKeyCode
    case quickAddHotkeyModifiers
    case quickAddLocationModeRawValue
    case quickAddSpecificParentTaskId
    case appThemeRawValue
    case themeAccentPresetRawValue
    case themeCustomAccentHex
    case themeColorTokenHexOverrides
    case customizableShortcutsByAction
    case dismissedOnboardingDialogs
  }

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func string(_ key: Key, default defaultValue: String = "") -> String {
    defaults.string(forKey: key.rawValue) ?? defaultValue
  }

  func set(_ value: String, for key: Key) {
    defaults.set(value, forKey: key.rawValue)
  }

  func bool(_ key: Key, default defaultValue: Bool) -> Bool {
    defaults.object(forKey: key.rawValue) as? Bool ?? defaultValue
  }

  func optionalBool(_ key: Key) -> Bool? {
    defaults.object(forKey: key.rawValue) as? Bool
  }

  func set(_ value: Bool, for key: Key) {
    defaults.set(value, forKey: key.rawValue)
  }

  func int(_ key: Key, default defaultValue: Int) -> Int {
    defaults.object(forKey: key.rawValue) as? Int ?? defaultValue
  }

  func set(_ value: Int, for key: Key) {
    defaults.set(value, forKey: key.rawValue)
  }

  func double(_ key: Key, default defaultValue: Double) -> Double {
    defaults.object(forKey: key.rawValue) as? Double ?? defaultValue
  }

  func set(_ value: Double, for key: Key) {
    defaults.set(value, forKey: key.rawValue)
  }

  func stringArray(_ key: Key) -> [String] {
    defaults.stringArray(forKey: key.rawValue) ?? []
  }

  func set(_ value: [String], for key: Key) {
    defaults.set(value, forKey: key.rawValue)
  }

  func stringDictionary(_ key: Key) -> [String: String] {
    defaults.dictionary(forKey: key.rawValue) as? [String: String] ?? [:]
  }

  func set(_ value: [String: String], for key: Key) {
    defaults.set(value, forKey: key.rawValue)
  }

  func timerDictionary() -> [String: Double] {
    defaults.dictionary(forKey: Key.timerByTaskId.rawValue) as? [String: Double] ?? [:]
  }

  func set(_ value: [String: Double], for key: Key) {
    defaults.set(value, forKey: key.rawValue)
  }

  func remove(_ key: Key) {
    defaults.removeObject(forKey: key.rawValue)
  }
}
