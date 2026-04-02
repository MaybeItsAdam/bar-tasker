import Foundation
import XCTest

@testable import BarTaskerPlugins

@MainActor
final class NativeMCPIntegrationPluginTests: XCTestCase {
  func testMakeClientConfigurationJSONIncludesProvidedCredentials() throws {
    let plugin = NativeMCPIntegrationPlugin()
    let credentials = CheckvistCredentials(username: " user@example.com ", remoteKey: " rkey ")

    let json = plugin.makeClientConfigurationJSON(
      credentials: credentials,
      listId: " 123 ",
      redactSecrets: false
    )
    let root = try decodeJSON(json)

    let env = try XCTUnwrap(root["env"] as? [String: Any])
    XCTAssertEqual(env["CHECKVIST_USERNAME"] as? String, "user@example.com")
    XCTAssertEqual(env["CHECKVIST_REMOTE_KEY"] as? String, "rkey")
    XCTAssertEqual(env["CHECKVIST_LIST_ID"] as? String, "123")
  }

  func testMakeClientConfigurationJSONRedactsSecrets() throws {
    let plugin = NativeMCPIntegrationPlugin()
    let credentials = CheckvistCredentials(username: "real@example.com", remoteKey: "secret")

    let json = plugin.makeClientConfigurationJSON(
      credentials: credentials,
      listId: "",
      redactSecrets: true
    )
    let root = try decodeJSON(json)

    let env = try XCTUnwrap(root["env"] as? [String: Any])
    XCTAssertEqual(env["CHECKVIST_USERNAME"] as? String, "<set-checkvist-username>")
    XCTAssertEqual(env["CHECKVIST_REMOTE_KEY"] as? String, "<set-checkvist-remote-key>")
    XCTAssertNil(env["CHECKVIST_LIST_ID"])
  }

  private func decodeJSON(_ json: String) throws -> [String: Any] {
    let data = try XCTUnwrap(json.data(using: .utf8))
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let servers = try XCTUnwrap(object?["mcpServers"] as? [String: Any])
    return try XCTUnwrap(servers["bar-tasker"] as? [String: Any])
  }
}
