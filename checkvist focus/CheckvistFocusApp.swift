import SwiftUI

@main
struct CheckvistFocusApp: App {
    // AppDelegate owns the single CheckvistManager instance
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(appDelegate.checkvistManager)
        }
    }
}
