import Foundation

struct RemoteKeyBootstrapState: Equatable {
  var remoteKey: String
  var hasAttemptedBootstrap: Bool
}

enum RemoteKeyBootstrapPolicy {
  static func bootstrap(
    state: RemoteKeyBootstrapState,
    usesKeychainStorage: Bool,
    loadFromKeychain: () -> String?
  ) -> RemoteKeyBootstrapState {
    guard usesKeychainStorage else { return state }
    let normalizedCurrent = state.remoteKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalizedCurrent.isEmpty, !state.hasAttemptedBootstrap else { return state }

    let loaded = loadFromKeychain()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return RemoteKeyBootstrapState(
      remoteKey: loaded.isEmpty ? state.remoteKey : loaded,
      hasAttemptedBootstrap: true
    )
  }
}
