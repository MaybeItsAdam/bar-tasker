import Foundation
import OSLog
import Security

final class CheckvistCredentialStore {
  static let keychainService = "uk.co.maybeitsadam.bar-tasker"
  static let legacyKeychainService = "uk.co.maybeitsadam.checkvist-focus"
  static let remoteKeyDefaultsKey = "checkvistRemoteKey"
  static let ignoreKeychainInDebugDefaultsKey = "ignoreKeychainInDebug"
  static let onboardingCompletedDefaultsKey = "onboardingCompleted"

  private let defaults: UserDefaults
  private let logger = Logger(subsystem: "uk.co.maybeitsadam.bar-tasker", category: "keychain")

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func startupRemoteKey(useKeychainStorageAtInit: Bool) -> String {
    if useKeychainStorageAtInit {
      migrateLegacyRemoteKeyIntoKeychainIfNeeded()
      // Never read keychain during app bootstrap; defer until explicit login/action.
      return ""
    }
    let stored = defaults.string(forKey: Self.remoteKeyDefaultsKey)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !stored.isEmpty { return stored }
    // One-time migration off keychain: if a prior install stashed the key in
    // the keychain, copy it into UserDefaults and delete the keychain copy so
    // future launches never trigger a keychain access prompt.
    guard let migrated = keychainValue(forKey: Self.remoteKeyDefaultsKey)?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !migrated.isEmpty
    else { return "" }
    defaults.set(migrated, forKey: Self.remoteKeyDefaultsKey)
    deleteKeychainValue(forKey: Self.remoteKeyDefaultsKey)
    return migrated
  }

  func persistRemoteKey(_ value: String, useKeychainStorage: Bool) {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if useKeychainStorage {
      if normalized.isEmpty {
        deleteKeychainValue(forKey: Self.remoteKeyDefaultsKey)
      } else {
        setKeychainValue(normalized, forKey: Self.remoteKeyDefaultsKey)
      }
    } else if normalized.isEmpty {
      defaults.removeObject(forKey: Self.remoteKeyDefaultsKey)
    } else {
      defaults.set(normalized, forKey: Self.remoteKeyDefaultsKey)
    }
  }

  func persistRemoteKeyForDebugStorageMode(_ value: String) {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.isEmpty {
      defaults.removeObject(forKey: Self.remoteKeyDefaultsKey)
    } else {
      defaults.set(normalized, forKey: Self.remoteKeyDefaultsKey)
    }
  }

  func loadRemoteKeyFromKeychain() -> String? {
    keychainValue(forKey: Self.remoteKeyDefaultsKey)
  }

  private func migrateLegacyRemoteKeyIntoKeychainIfNeeded() {
    if let legacyKey = defaults.string(forKey: Self.remoteKeyDefaultsKey), !legacyKey.isEmpty {
      setKeychainValue(legacyKey, forKey: Self.remoteKeyDefaultsKey)
      defaults.removeObject(forKey: Self.remoteKeyDefaultsKey)
    }
  }

  private func keychainValue(forKey key: String) -> String? {
    let scopedQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.keychainService,
      kSecAttrAccount as String: key,
      kSecReturnData as String: true,
    ]
    var result: AnyObject?
    if SecItemCopyMatching(scopedQuery as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    {
      return String(data: data, encoding: .utf8)
    }

    // Compatibility: migrate legacy entries scoped to the old app service name.
    let legacyServiceQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.legacyKeychainService,
      kSecAttrAccount as String: key,
      kSecReturnData as String: true,
    ]
    var legacyServiceResult: AnyObject?
    if SecItemCopyMatching(legacyServiceQuery as CFDictionary, &legacyServiceResult)
      == errSecSuccess,
      let legacyData = legacyServiceResult as? Data,
      let legacyValue = String(data: legacyData, encoding: .utf8)
    {
      setKeychainValue(legacyValue, forKey: key)
      SecItemDelete(legacyServiceQuery as CFDictionary)
      return legacyValue
    }

    // Compatibility: migrate legacy entries that were saved without kSecAttrService.
    let legacyQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccount as String: key,
      kSecReturnData as String: true,
    ]
    var legacyResult: AnyObject?
    guard SecItemCopyMatching(legacyQuery as CFDictionary, &legacyResult) == errSecSuccess,
      let legacyData = legacyResult as? Data,
      let legacyValue = String(data: legacyData, encoding: .utf8)
    else { return nil }
    setKeychainValue(legacyValue, forKey: key)
    SecItemDelete(legacyQuery as CFDictionary)
    return legacyValue
  }

  private func setKeychainValue(_ value: String, forKey key: String) {
    let data = Data(value.utf8)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.keychainService,
      kSecAttrAccount as String: key,
    ]
    if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
      let status = SecItemUpdate(
        query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
      if status != errSecSuccess {
        logger.error("SecItemUpdate failed for key \(key, privacy: .public): \(status)")
      }
    } else {
      var add = query
      add[kSecValueData as String] = data
      add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let status = SecItemAdd(add as CFDictionary, nil)
      if status != errSecSuccess {
        logger.error("SecItemAdd failed for key \(key, privacy: .public): \(status)")
      }
    }
  }

  private func deleteKeychainValue(forKey key: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.keychainService,
      kSecAttrAccount as String: key,
    ]
    let status = SecItemDelete(query as CFDictionary)
    if status != errSecSuccess && status != errSecItemNotFound {
      logger.error("SecItemDelete failed for key \(key, privacy: .public): \(status)")
    }
  }
}
