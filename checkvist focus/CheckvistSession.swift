import Foundation

@MainActor
final class CheckvistSession {
  private let apiClient: CheckvistAPIClient
  private let userAgent = "CheckvistFocus/1.0 (Macintosh; Mac OS X)"
  private var token: String?
  private var isLoginInProgress = false
  private var loginWaiters: [CheckedContinuation<Bool, Never>] = []

  init(apiClient: CheckvistAPIClient = CheckvistAPIClient()) {
    self.apiClient = apiClient
  }

  func clearToken() {
    token = nil
  }

  func login(username: String, remoteKey: String) async throws -> Bool {
    if isLoginInProgress {
      return await withCheckedContinuation { continuation in
        loginWaiters.append(continuation)
      }
    }

    isLoginInProgress = true
    let result = await executeLoginRequest(username: username, remoteKey: remoteKey)
    isLoginInProgress = false

    let waiters = loginWaiters
    loginWaiters = []
    for waiter in waiters {
      waiter.resume(returning: result)
    }

    return result
  }

  func performAuthenticatedRequest(
    username: String,
    remoteKey: String,
    _ buildRequest: (String) throws -> URLRequest
  ) async throws -> (Data, HTTPURLResponse) {
    var retryState = AuthRetryState(hasRetriedAfterUnauthorized: false)

    while true {
      if token == nil {
        let ok = try await login(username: username, remoteKey: remoteKey)
        if !ok {
          throw CheckvistSessionError.authenticationUnavailable
        }
      }

      guard let validToken = token else {
        throw CheckvistSessionError.authenticationUnavailable
      }

      let request = try buildRequest(validToken)
      let (data, response) = try await apiClient.data(for: request)
      guard let httpResponse = response as? HTTPURLResponse else {
        throw CheckvistSessionError.invalidResponse
      }

      if httpResponse.statusCode == 401 {
        token = nil
        let retry = AuthRetryPolicy.decisionForUnauthorized(state: retryState)
        retryState = retry.nextState
        if retry.decision == .retryAuthentication {
          continue
        }
      }

      return (data, httpResponse)
    }
  }

  private func executeLoginRequest(username: String, remoteKey: String) async -> Bool {
    let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedRemoteKey = remoteKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedUsername.isEmpty, !normalizedRemoteKey.isEmpty else {
      return false
    }

    guard let url = URL(string: "https://checkvist.com/auth/login.json") else {
      return false
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

    let body: [String: String] = [
      "username": normalizedUsername,
      "remote_key": normalizedRemoteKey,
    ]

    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      let (data, response) = try await apiClient.data(for: request)

      guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
        return false
      }

      if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let tokenString = json["token"] as? String
      {
        token = tokenString
        return true
      }

      if let tokenString = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
      {
        token = tokenString
        return true
      }

      return false
    } catch {
      return false
    }
  }
}

enum CheckvistSessionError: Error {
  case authenticationUnavailable
  case invalidResponse
}
