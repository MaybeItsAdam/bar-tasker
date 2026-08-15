import Foundation

/// How Priority can add itself to a given MCP client.
///
/// Not every client can be configured the same way, and picking the wrong route
/// is worse than doing nothing — it either races the client's own writes or
/// destroys parts of a file the user hand-wrote.
enum MCPClientInstallStyle: Equatable {
  /// A plain JSON file that only ever holds MCP configuration. Priority can
  /// read it, merge one server entry in, and write it back.
  case mergeConfigFile

  /// The client rewrites its own config continuously — Claude Code touches
  /// `~/.claude.json` on nearly every run — so editing it underneath would race
  /// and lose one side of the write. Its CLI is the supported route.
  case terminalCommand

  /// The config is JSON-with-comments. Round-tripping it through
  /// `JSONSerialization` would silently drop every comment the user wrote, so
  /// hand over a snippet to paste instead of editing the file.
  case pasteSnippet
}

/// A known MCP client and everything needed to add Priority to it.
struct MCPClientDescriptor: Identifiable, Equatable {
  let id: String
  let displayName: String

  /// Config file path relative to the user's real home directory.
  let configPathComponents: [String]

  /// Top-level key holding the server map. Most clients use `mcpServers`;
  /// VS Code uses `servers` and Zed uses `context_servers`.
  let serversKey: String

  /// VS Code requires an explicit `"type": "stdio"` on each entry; the others
  /// infer stdio from the presence of `command`.
  let requiresTransportType: Bool

  let installStyle: MCPClientInstallStyle

  /// Home-relative paths whose existence means this client is worth offering.
  let homeRelativeMarkers: [String]

  /// App bundle names checked under `/Applications`.
  let applicationBundleNames: [String]

  /// What the user has to do after the config lands, shown once setup succeeds.
  let postInstallNote: String

  var configPath: String { configPathComponents.joined(separator: "/") }

  func configPath(inHomeDirectory home: String) -> String {
    ([home] + configPathComponents).joined(separator: "/")
  }

  /// The directory the config file lives in. Sandboxed builds ask for access to
  /// this rather than the file, so the config can be created when absent.
  func configDirectoryPath(inHomeDirectory home: String) -> String {
    ([home] + configPathComponents.dropLast()).joined(separator: "/")
  }

  var configFileName: String { configPathComponents.last ?? "" }
}

enum MCPClientCatalog {
  /// The server name Priority registers itself under in every client.
  static let serverName = "priority"

  static let claudeCode = MCPClientDescriptor(
    id: "claude-code",
    displayName: "Claude Code",
    configPathComponents: [".claude.json"],
    serversKey: "mcpServers",
    requiresTransportType: false,
    installStyle: .terminalCommand,
    homeRelativeMarkers: [".claude.json", ".claude"],
    applicationBundleNames: [],
    postInstallNote: "Run the command, then use /mcp in Claude Code to check the connection."
  )

  static let claudeDesktop = MCPClientDescriptor(
    id: "claude-desktop",
    displayName: "Claude Desktop",
    configPathComponents: ["Library", "Application Support", "Claude", "claude_desktop_config.json"],
    serversKey: "mcpServers",
    requiresTransportType: false,
    installStyle: .mergeConfigFile,
    homeRelativeMarkers: ["Library/Application Support/Claude"],
    applicationBundleNames: ["Claude.app"],
    postInstallNote: "Quit and reopen Claude Desktop to pick up the new server."
  )

  static let cursor = MCPClientDescriptor(
    id: "cursor",
    displayName: "Cursor",
    configPathComponents: [".cursor", "mcp.json"],
    serversKey: "mcpServers",
    requiresTransportType: false,
    installStyle: .mergeConfigFile,
    homeRelativeMarkers: [".cursor"],
    applicationBundleNames: ["Cursor.app"],
    postInstallNote: "Reload Cursor, then check Settings › MCP."
  )

  static let windsurf = MCPClientDescriptor(
    id: "windsurf",
    displayName: "Windsurf",
    configPathComponents: [".codeium", "windsurf", "mcp_config.json"],
    serversKey: "mcpServers",
    requiresTransportType: false,
    installStyle: .mergeConfigFile,
    homeRelativeMarkers: [".codeium/windsurf"],
    applicationBundleNames: ["Windsurf.app"],
    postInstallNote: "Reload Windsurf to pick up the new server."
  )

  static let visualStudioCode = MCPClientDescriptor(
    id: "vscode",
    displayName: "VS Code",
    configPathComponents: ["Library", "Application Support", "Code", "User", "mcp.json"],
    serversKey: "servers",
    requiresTransportType: true,
    installStyle: .mergeConfigFile,
    homeRelativeMarkers: ["Library/Application Support/Code/User"],
    applicationBundleNames: ["Visual Studio Code.app"],
    postInstallNote: "Reload the VS Code window to pick up the new server."
  )

  static let zed = MCPClientDescriptor(
    id: "zed",
    displayName: "Zed",
    configPathComponents: [".config", "zed", "settings.json"],
    serversKey: "context_servers",
    requiresTransportType: false,
    // Zed's settings.json ships with explanatory comments and most users add
    // their own. Rewriting it as plain JSON would delete all of them.
    installStyle: .pasteSnippet,
    homeRelativeMarkers: [".config/zed"],
    applicationBundleNames: ["Zed.app"],
    postInstallNote: "Paste into settings.json — Zed picks the server up on save."
  )

  static let all: [MCPClientDescriptor] = [
    claudeCode, claudeDesktop, cursor, windsurf, visualStudioCode, zed,
  ]

  /// Clients with a trace on this machine, in catalog order.
  ///
  /// Detection is deliberately loose — a marker directory is enough. Offering a
  /// client the user doesn't have costs them one ignored row; hiding one they do
  /// have sends them back to hand-editing JSON.
  static func detectedClients(
    homeDirectory: String,
    applicationsDirectory: String = "/Applications",
    fileExists: (String) -> Bool
  ) -> [MCPClientDescriptor] {
    all.filter { client in
      let homeHit = client.homeRelativeMarkers.contains { marker in
        fileExists(([homeDirectory] + marker.split(separator: "/").map(String.init))
          .joined(separator: "/"))
      }
      if homeHit { return true }
      return client.applicationBundleNames.contains { bundleName in
        fileExists("\(applicationsDirectory)/\(bundleName)")
      }
    }
  }
}
