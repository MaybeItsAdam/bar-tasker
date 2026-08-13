import AppKit
import Foundation
import OSLog

/// Writes Bar Tasker's MCP entry into the config files of clients that keep one.
///
/// Release builds are sandboxed (`Bar Tasker.release.entitlements`), so nothing
/// outside the container is readable until the user hands it over through an
/// open panel. The granted directory is bookmarked, so that happens once per
/// client rather than once per install.
@MainActor
final class MCPClientInstaller {
  enum InstallResult: Equatable {
    case wrote(MCPConfigWriteOutcome)
    case cancelled
  }

  enum InstallError: LocalizedError {
    case configDirectoryMissing(client: String, directory: String)

    var errorDescription: String? {
      switch self {
      case .configDirectoryMissing(let client, let directory):
        return "\(client)'s config folder isn't there (\(directory)). Open \(client) once, then retry."
      }
    }
  }

  private let logger = Logger(
    subsystem: "uk.co.maybeitsadam.bar-tasker", category: "MCPClientInstaller")
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  // MARK: - Environment

  /// The user's actual home directory.
  ///
  /// `FileManager.homeDirectoryForCurrentUser` returns the *container* under the
  /// sandbox, which is never where an MCP client keeps its config.
  static var realHomeDirectory: URL {
    if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
      return URL(fileURLWithPath: String(cString: directory))
    }
    return FileManager.default.homeDirectoryForCurrentUser
  }

  private static var isSandboxed: Bool {
    ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
  }

  func detectedClients() -> [MCPClientDescriptor] {
    MCPClientCatalog.detectedClients(
      homeDirectory: Self.realHomeDirectory.path,
      fileExists: { FileManager.default.fileExists(atPath: $0) }
    )
  }

  func configURL(for client: MCPClientDescriptor) -> URL {
    URL(fileURLWithPath: client.configPath(inHomeDirectory: Self.realHomeDirectory.path))
  }

  // MARK: - Install

  func install(entry: MCPServerEntry, into client: MCPClientDescriptor) throws -> InstallResult {
    let configURL = configURL(for: client)
    let directoryURL = configURL.deletingLastPathComponent()

    if let bookmarked = resolvedBookmarkURL(for: client) {
      return .wrote(
        try withSecurityScope(bookmarked) {
          try mergeAndWrite(entry: entry, client: client, configURL: configURL)
        })
    }

    guard Self.isSandboxed else {
      return .wrote(try mergeAndWrite(entry: entry, client: client, configURL: configURL))
    }

    guard FileManager.default.fileExists(atPath: directoryURL.path) else {
      throw InstallError.configDirectoryMissing(
        client: client.displayName, directory: directoryURL.path)
    }
    guard let granted = try requestAccess(to: directoryURL, client: client) else {
      return .cancelled
    }
    return .wrote(
      try withSecurityScope(granted) {
        try mergeAndWrite(entry: entry, client: client, configURL: configURL)
      })
  }

  private func mergeAndWrite(
    entry: MCPServerEntry,
    client: MCPClientDescriptor,
    configURL: URL
  ) throws -> MCPConfigWriteOutcome {
    let existing = try existingContents(at: configURL)
    let merged = try MCPClientConfigWriter.merged(
      entry: entry,
      into: existing,
      serversKey: client.serversKey,
      clientName: client.displayName,
      configPath: configURL.path
    )

    // Don't touch the file when nothing would change — a no-op write still
    // bumps the modification date and can nudge clients into a reload.
    guard merged.outcome != .unchanged else { return .unchanged }

    try merged.contents.write(to: configURL, atomically: true, encoding: .utf8)
    logger.info(
      "Wrote MCP entry for \(client.id, privacy: .public): \(String(describing: merged.outcome), privacy: .public)"
    )
    return merged.outcome
  }

  private func existingContents(at url: URL) throws -> String? {
    do {
      return try String(contentsOf: url, encoding: .utf8)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return nil
    }
  }

  // MARK: - Sandbox access

  private func requestAccess(to directoryURL: URL, client: MCPClientDescriptor) throws -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = false
    panel.allowsMultipleSelection = false
    // Several clients hide their config under a dotted folder.
    panel.showsHiddenFiles = true
    panel.directoryURL = directoryURL
    panel.prompt = "Grant Access"
    panel.message =
      "Bar Tasker needs permission to edit \(client.displayName)'s MCP configuration. "
      + "The folder is already selected — click Grant Access."

    guard panel.runModal() == .OK, let selected = panel.url else { return nil }

    let bookmark = try selected.bookmarkData(
      options: [.withSecurityScope],
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
    defaults.set(bookmark, forKey: bookmarkKey(for: client))
    return selected
  }

  private func bookmarkKey(for client: MCPClientDescriptor) -> String {
    "mcpClientConfigDirectoryBookmark.\(client.id)"
  }

  private func resolvedBookmarkURL(for client: MCPClientDescriptor) -> URL? {
    guard let data = defaults.data(forKey: bookmarkKey(for: client)) else { return nil }
    var isStale = false
    guard
      let url = try? URL(
        resolvingBookmarkData: data,
        options: [.withSecurityScope],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
    else {
      defaults.removeObject(forKey: bookmarkKey(for: client))
      return nil
    }
    if isStale,
      let refreshed = try? url.bookmarkData(
        options: [.withSecurityScope],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
    {
      defaults.set(refreshed, forKey: bookmarkKey(for: client))
    }
    return url
  }

  /// Every read and write under a bookmark-resolved directory has to happen
  /// inside one of these. Mirrors `ObsidianSyncService.withSecurityScope`.
  private func withSecurityScope<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
    let accessed = url.startAccessingSecurityScopedResource()
    defer {
      if accessed { url.stopAccessingSecurityScopedResource() }
    }
    return try body()
  }
}
