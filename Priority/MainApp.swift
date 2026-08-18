import SwiftUI

/// The real entry point, so `--mcp-server` is handled before AppKit starts.
///
/// `MCPServerShim.run()` replaces the process image with the bundled `priority`
/// CLI, so nothing here gets as far as opening a window-server connection for a
/// process that only ever speaks JSON-RPC on stdio.
@main
enum PriorityEntryPoint {
  static func main() {
    if MCPServerShim.isLaunchMode(arguments: CommandLine.arguments) {
      MCPServerShim.run()
    }
    MainApp.main()
  }
}

struct MainApp: App {
  // AppDelegate owns the single AppCoordinator instance
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  var body: some Scene {
    Settings {
      EmptyView()
    }
    .commands {
      CommandGroup(replacing: .appSettings) {
        Button("Preferences...") {
          AppDelegate.shared.menuSettings()
        }
        .keyboardShortcut(",", modifiers: .command)
      }
    }
  }
}
