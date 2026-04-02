import Foundation
import XCTest

@testable import BarTaskerPlugins

@MainActor
final class UserPluginManagerCompatibilityTests: XCTestCase {
  func testReloadRejectsUnsupportedPluginAPIVersion() throws {
    let pluginsRoot = try makeTemporaryPluginsRoot()
    defer { try? FileManager.default.removeItem(at: pluginsRoot) }

    _ = try makePluginFolder(
      in: pluginsRoot,
      folderName: "unsupported-api-plugin",
      manifestJSON: """
        {
          "id": "compat.unsupported.api",
          "name": "Unsupported API Plugin",
          "pluginApiVersion": 2
        }
        """
    )

    let manager = UserPluginManager(
      builtInPluginIdentifiers: [],
      currentAppVersion: "1.2.0",
      pluginsDirectoryURL: pluginsRoot
    )
    manager.reloadInstalledPlugins()

    XCTAssertTrue(manager.installedPlugins.isEmpty)
    XCTAssertEqual(manager.validationIssues.count, 1)
    XCTAssertEqual(manager.validationIssues.first?.pluginFolderName, "unsupported-api-plugin")
    XCTAssertTrue(
      manager.validationIssues.first?.message.localizedCaseInsensitiveContains("not supported")
        ?? false
    )
  }

  func testReloadRejectsInvalidMinimumAppVersion() throws {
    let pluginsRoot = try makeTemporaryPluginsRoot()
    defer { try? FileManager.default.removeItem(at: pluginsRoot) }

    _ = try makePluginFolder(
      in: pluginsRoot,
      folderName: "invalid-min-version-plugin",
      manifestJSON: """
        {
          "id": "compat.invalid.min",
          "name": "Invalid Min Version Plugin",
          "pluginApiVersion": 1,
          "minAppVersion": "abc"
        }
        """
    )

    let manager = UserPluginManager(
      builtInPluginIdentifiers: [],
      currentAppVersion: "1.2.0",
      pluginsDirectoryURL: pluginsRoot
    )
    manager.reloadInstalledPlugins()

    XCTAssertTrue(manager.installedPlugins.isEmpty)
    XCTAssertEqual(manager.validationIssues.count, 1)
    XCTAssertTrue(
      manager.validationIssues.first?.message.localizedCaseInsensitiveContains(
        "minimum app version")
        ?? false
    )
  }

  func testReloadRejectsPluginWhenAppVersionTooOld() throws {
    let pluginsRoot = try makeTemporaryPluginsRoot()
    defer { try? FileManager.default.removeItem(at: pluginsRoot) }

    _ = try makePluginFolder(
      in: pluginsRoot,
      folderName: "min-version-too-high-plugin",
      manifestJSON: """
        {
          "id": "compat.requires.newer.app",
          "name": "Requires Newer App",
          "pluginApiVersion": 1,
          "minAppVersion": "2.0.0"
        }
        """
    )

    let manager = UserPluginManager(
      builtInPluginIdentifiers: [],
      currentAppVersion: "1.5.0",
      pluginsDirectoryURL: pluginsRoot
    )
    manager.reloadInstalledPlugins()

    XCTAssertTrue(manager.installedPlugins.isEmpty)
    XCTAssertEqual(manager.validationIssues.count, 1)
    XCTAssertTrue(
      manager.validationIssues.first?.message.localizedCaseInsensitiveContains(
        "requires app version")
        ?? false
    )
  }

  func testReloadRejectsPluginWhenCurrentAppVersionUnavailable() throws {
    let pluginsRoot = try makeTemporaryPluginsRoot()
    defer { try? FileManager.default.removeItem(at: pluginsRoot) }

    _ = try makePluginFolder(
      in: pluginsRoot,
      folderName: "needs-version-plugin",
      manifestJSON: """
        {
          "id": "compat.app.version.required",
          "name": "Needs App Version",
          "pluginApiVersion": 1,
          "minAppVersion": "1.0.0"
        }
        """
    )

    let manager = UserPluginManager(
      builtInPluginIdentifiers: [],
      currentAppVersion: "",
      pluginsDirectoryURL: pluginsRoot
    )
    manager.reloadInstalledPlugins()

    XCTAssertTrue(manager.installedPlugins.isEmpty)
    XCTAssertEqual(manager.validationIssues.count, 1)
    XCTAssertTrue(
      manager.validationIssues.first?.message.localizedCaseInsensitiveContains(
        "version is unavailable")
        ?? false
    )
  }

  func testInstallRejectsUnsupportedPluginAPIVersion() throws {
    let pluginsRoot = try makeTemporaryPluginsRoot()
    defer { try? FileManager.default.removeItem(at: pluginsRoot) }

    let sourceRoot = try makeTemporaryPluginsRoot()
    defer { try? FileManager.default.removeItem(at: sourceRoot) }
    let sourcePluginFolder = try makePluginFolder(
      in: sourceRoot,
      folderName: "source-plugin",
      manifestJSON: """
        {
          "id": "compat.install.unsupported",
          "name": "Install Unsupported API",
          "pluginApiVersion": 9
        }
        """
    )

    let manager = UserPluginManager(
      builtInPluginIdentifiers: [],
      currentAppVersion: "1.2.0",
      pluginsDirectoryURL: pluginsRoot
    )

    XCTAssertThrowsError(try manager.installPlugin(from: sourcePluginFolder)) { error in
      guard let installError = error as? UserPluginManager.PluginInstallError else {
        return XCTFail("Expected PluginInstallError, got \(error)")
      }
      switch installError {
      case .unsupportedPluginAPIVersion(let version):
        XCTAssertEqual(version, 9)
      default:
        XCTFail("Expected unsupportedPluginAPIVersion, got \(installError)")
      }
    }
  }

  private func makeTemporaryPluginsRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bar-tasker-plugin-compat-tests-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @discardableResult
  private func makePluginFolder(in root: URL, folderName: String, manifestJSON: String) throws
    -> URL
  {
    let pluginFolder = root.appendingPathComponent(folderName, isDirectory: true)
    try FileManager.default.createDirectory(at: pluginFolder, withIntermediateDirectories: true)
    let manifestURL = pluginFolder.appendingPathComponent("plugin.json")
    guard let manifestData = manifestJSON.data(using: .utf8) else {
      throw NSError(domain: "UserPluginManagerCompatibilityTests", code: 1)
    }
    try manifestData.write(to: manifestURL)
    return pluginFolder
  }
}
