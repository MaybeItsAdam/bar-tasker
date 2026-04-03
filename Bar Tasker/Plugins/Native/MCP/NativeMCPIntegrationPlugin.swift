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
  let pluginDescription = "Expose Bar Tasker as a local MCP server for AI assistants and tools."

  private let guideRelativePath = "docs/mcp-server.md"
  private let scriptRelativePath = "scripts/bar_tasker_mcp_server.py"
  private let defaultCommandPlaceholder = "/Applications/Bar Tasker.app/Contents/MacOS/Bar Tasker"

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

  func makeClientConfigurationJSON(
    credentials: CheckvistCredentials,
    listId: String,
    redactSecrets: Bool
  ) -> String {
    let command = resolvedMCPCommand()
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

    let config = MCPClientConfigRoot(
      mcpServers: [
        "bar-tasker": MCPClientServerConfig(
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
      ProcessInfo.processInfo.environment["BAR_TASKER_MCP_EXECUTABLE_PATH"]?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !envOverride.isEmpty {
      let overrideURL = URL(fileURLWithPath: envOverride).standardizedFileURL
      if fileManager.fileExists(atPath: overrideURL.path) {
        return ResolvedMCPCommand(
          command: overrideURL.path,
          args: ["--mcp-server"],
          displayURL: overrideURL
        )
      }
    }

    let scriptURL = scriptCandidates().first(where: { fileManager.fileExists(atPath: $0.path) })
    if shouldPreferScriptFallback(), let scriptURL {
      return ResolvedMCPCommand(
        command: "/usr/bin/env",
        args: ["python3", scriptURL.path],
        displayURL: scriptURL.standardizedFileURL
      )
    }

    for candidate in commandCandidates() where fileManager.fileExists(atPath: candidate.path) {
      return ResolvedMCPCommand(
        command: candidate.path,
        args: ["--mcp-server"],
        displayURL: candidate.standardizedFileURL
      )
    }

    if let scriptURL {
      return ResolvedMCPCommand(
        command: "/usr/bin/env",
        args: ["python3", scriptURL.path],
        displayURL: scriptURL.standardizedFileURL
      )
    }

    return ResolvedMCPCommand(
      command: defaultCommandPlaceholder,
      args: ["--mcp-server"],
      displayURL: nil
    )
  }

  private func shouldPreferScriptFallback() -> Bool {
    let env = ProcessInfo.processInfo.environment
    if env["BAR_TASKER_MCP_PREFER_APP"] == "1" {
      return false
    }
    if env["BAR_TASKER_MCP_PREFER_SCRIPT"] == "1" {
      return true
    }
    #if DEBUG
      return true
    #else
      return false
    #endif
  }

  private func commandCandidates() -> [URL] {
    let fileManager = FileManager.default
    var candidates: [URL] = []

    let installedAppCommand = URL(
      fileURLWithPath: "/Applications/Bar Tasker.app/Contents/MacOS/Bar Tasker")
    candidates.append(installedAppCommand)

    let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent()
    candidates.append(
      bundleParent.appendingPathComponent("Bar Tasker.app/Contents/MacOS/Bar Tasker"))

    if let executableURL = Bundle.main.executableURL {
      candidates.append(executableURL.standardizedFileURL)
    }

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

  private func scriptCandidates() -> [URL] {
    candidateURLs(forRelativePath: scriptRelativePath, envOverrideKey: "BAR_TASKER_MCP_SCRIPT_PATH")
  }

  private func guideCandidates() -> [URL] {
    candidateURLs(forRelativePath: guideRelativePath, envOverrideKey: "BAR_TASKER_MCP_GUIDE_PATH")
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
