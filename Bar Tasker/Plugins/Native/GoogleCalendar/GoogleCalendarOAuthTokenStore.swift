import Foundation
import Security

struct GoogleCalendarOAuthTokenPayload: Codable, Sendable {
  let accessToken: String
  let refreshToken: String
  let expiryDate: Date
  let grantedScopes: String
  let clientID: String
}

final class GoogleCalendarOAuthTokenStore {
  private static let service = "uk.co.maybeitsadam.bar-tasker"
  private static let account = "googleCalendarOAuthTokenPayload"

  func load() -> GoogleCalendarOAuthTokenPayload? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: Self.account,
      kSecReturnData as String: true,
    ]
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return nil }
    return try? JSONDecoder().decode(GoogleCalendarOAuthTokenPayload.self, from: data)
  }

  func save(_ payload: GoogleCalendarOAuthTokenPayload) {
    guard let data = try? JSONEncoder().encode(payload) else { return }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: Self.account,
    ]

    if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
      let attrs: [String: Any] = [kSecValueData as String: data]
      SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
    } else {
      var add = query
      add[kSecValueData as String] = data
      add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      SecItemAdd(add as CFDictionary, nil)
    }
  }

  func clear() {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: Self.account,
    ]
    SecItemDelete(query as CFDictionary)
  }
}
