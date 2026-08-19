import PriorityCore
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
      // Only visible once the main window puts the app in `.regular` — an
      // accessory app has no menu bar to hang these off. They exist so a
      // windowed user has a discoverable route to everything the keyboard
      // already does, and so the window can be reopened after it is closed.
      CommandGroup(after: .windowList) {
        Button("Priority") {
          AppDelegate.shared.showMainWindow()
        }
        .keyboardShortcut("0", modifiers: .command)
      }
      CommandMenu("View") {
        // Same order the tab strip uses, so the menu and the strip cannot
        // disagree about what the tabs are or which order they are in.
        ForEach(AppDelegate.shared.checkvistManager.orderedRootTaskViews, id: \.rawValue) { scope in
          Button(scope.title) {
            AppDelegate.shared.checkvistManager.taskNavigationService.setRootTaskView(scope)
          }
        }
        Divider()
        Button("Refresh") {
          Task { await AppDelegate.shared.checkvistManager.syncService.fetchTopTask() }
        }
        .keyboardShortcut("r", modifiers: .command)
        Button("Diagnostics") {
          AppDelegate.shared.showMainWindow()
          AppDelegate.shared.checkvistManager.popoverChrome.showsDiagnostics = true
        }
      }
    }
  }
}
