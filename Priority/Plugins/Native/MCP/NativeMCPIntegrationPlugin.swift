import Foundation

private struct MCPClientServerConfig: Encodable {
  let command: String
  let args: [String]
  let env: [String: String]
}

private struct MCPClientConfigRoot: Encodable {
  let mcpServers: [String: MCPClientServerConfig]
}

@MainActor
final class NativeMCPIntegrationPlugin: MCPIntegrationPlugin {
  private struct ResolvedMCPCommand {
    let command: String
    let args: [String]
    let displayURL: URL?
  }

  let pluginIdentifier = "native.mcp.integration"
  let displayName = "Native MCP Integration"
  let pluginDescription = "Expose Priority as a local MCP server for AI assistants and tools."

  private let guideRelativePath = "docs/mcp-server.md"
  /// The MCP server is the `priority` CLI, shipped inside the bundle by
  /// `scripts/bundle_cli.sh`. Configurations point straight at it rather than
  /// at `Priority --mcp-server`, which now only exists to keep configurations
  /// written before that change working. See `MCPServerShim`.
  private let helperRelativePath = "Contents/Helpers/priority"
  private let defaultCommandPlaceholder =
    "/Applications/Priority.app/Contents/Helpers/priority"
  private let serverArguments = ["mcp"]

  func serverCommandURL() -> URL? {
    resolvedMCPCommand().displayURL
  }

  func guideURL() -> URL? {
    let fileManager = FileManager.default
    for candidate in guideCandidates() where fileManager.fileExists(atPath: candidate.path) {
      return candidate.standardizedFileURL
    }
    return nil
  }

  func serverInvocation() -> MCPServerInvocation {
    let resolved = resolvedMCPCommand()
    return MCPServerInvocation(command: resolved.command, args: resolved.args)
  }

  func serverEnvironment(
    credentials: CheckvistCredentials,
    listId: String
  ) -> [String: String] {
    serverEnvironment(credentials: credentials, listId: listId, redactSecrets: false)
  }

  private func serverEnvironment(
    credentials: CheckvistCredentials,
    listId: String,
    redactSecrets: Bool
  ) -> [String: String] {
    let usernameValue: String
    let remoteKeyValue: String
    if redactSecrets {
      usernameValue = "<set-checkvist-username>"
      remoteKeyValue = "<set-checkvist-remote-key>"
    } else {
      usernameValue =
        credentials.normalizedUsername.isEmpty
        ? "you@example.com" : credentials.normalizedUsername
      remoteKeyValue =
        credentials.normalizedRemoteKey.isEmpty
        ? "your-remote-key" : credentials.normalizedRemoteKey
    }

    let trimmedListId = listId.trimmingCharacters(in: .whitespacesAndNewlines)
    var env: [String: String] = [
      "CHECKVIST_USERNAME": usernameValue,
      "CHECKVIST_REMOTE_KEY": remoteKeyValue,
    ]
    if !trimmedListId.isEmpty {
      env["CHECKVIST_LIST_ID"] = trimmedListId
    }
    return env
  }

  func makeClientConfigurationJSON(
    credentials: CheckvistCredentials,
    listId: String,
    redactSecrets: Bool
  ) -> String {
    let command = resolvedMCPCommand()
    let env = serverEnvironment(
      credentials: credentials,
      listId: listId,
      redactSecrets: redactSecrets
    )

    let config = MCPClientConfigRoot(
      mcpServers: [
        "priority": MCPClientServerConfig(
          command: command.command,
          args: command.args,
          env: env
        )
      ]
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(config),
      let text = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return text
  }

  private func resolvedMCPCommand() -> ResolvedMCPCommand {
    let fileManager = FileManager.default
    let envOverride =
      ProcessInfo.processInfo.environment["PRIORITY_MCP_EXECUTABLE_PATH"]?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !envOverride.isEmpty {
      let overrideURL = URL(fileURLWithPath: envOverride).standardizedFileURL
      if fileManager.fileExists(atPath: overrideURL.path) {
        return ResolvedMCPCommand(
          command: overrideURL.path,
          args: serverArguments,
          displayURL: overrideURL
        )
      }
    }

    for candidate in commandCandidates() where fileManager.fileExists(atPath: candidate.path) {
      return ResolvedMCPCommand(
        command: candidate.path,
        args: serverArguments,
        displayURL: candidate.standardizedFileURL
      )
    }

    return ResolvedMCPCommand(
      command: defaultCommandPlaceholder,
      args: serverArguments,
      displayURL: nil
    )
  }

  private func commandCandidates() -> [URL] {
    let fileManager = FileManager.default
    var candidates: [URL] = []

    // The installed app first, so a configuration written from a development
    // build still names the path the user will actually have.
    candidates.append(
      URL(fileURLWithPath: "/Applications/Priority.app").appendingPathComponent(
        helperRelativePath))

    let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent()
    candidates.append(
      bundleParent.appendingPathComponent("Priority.app").appendingPathComponent(
        helperRelativePath))
    candidates.append(Bundle.main.bundleURL.appendingPathComponent(helperRelativePath))

    // A separately installed CLI, for a bundle built with
    // PRIORITY_SKIP_CLI_BUNDLE=1.
    let home = NSHomeDirectory()
    candidates.append(contentsOf: [
      "\(home)/.local/bin/priority",
      "\(home)/bin/priority",
      "/usr/local/bin/priority",
      "/opt/homebrew/bin/priority",
    ].map(URL.init(fileURLWithPath:)))

    var deduplicated: [URL] = []
    var seenPaths = Set<String>()
    for candidate in candidates {
      let standardized = candidate.standardizedFileURL
      guard fileManager.fileExists(atPath: standardized.path) else { continue }
      if seenPaths.insert(standardized.path).inserted {
        deduplicated.append(standardized)
      }
    }
    return deduplicated
  }

  private func guideCandidates() -> [URL] {
    candidateURLs(forRelativePath: guideRelativePath, envOverrideKey: "PRIORITY_MCP_GUIDE_PATH")
  }

  private func candidateURLs(forRelativePath relativePath: String, envOverrideKey: String) -> [URL]
  {
    var candidates: [URL] = []

    let envOverride =
      ProcessInfo.processInfo.environment[envOverrideKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !envOverride.isEmpty {
      candidates.append(URL(fileURLWithPath: envOverride))
    }

    let sourceBasedRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    candidates.append(sourceBasedRoot.appendingPathComponent(relativePath))

    let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    candidates.append(currentDirectory.appendingPathComponent(relativePath))

    if let resourceURL = Bundle.main.resourceURL {
      candidates.append(
        resourceURL.appendingPathComponent((relativePath as NSString).lastPathComponent))
    }

    let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent()
    candidates.append(bundleParent.appendingPathComponent(relativePath))
    candidates.append(bundleParent.deletingLastPathComponent().appendingPathComponent(relativePath))

    var deduplicated: [URL] = []
    var seenPaths = Set<String>()
    for candidate in candidates {
      let standardized = candidate.standardizedFileURL
      if seenPaths.insert(standardized.path).inserted {
        deduplicated.append(standardized)
      }
    }
    return deduplicated
  }
}
