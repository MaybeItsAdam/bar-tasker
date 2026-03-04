import SwiftUI
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {
    var checkvistManager = CheckvistManager()

    private var statusItem: NSStatusItem!
    private var popover: NSPopover?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Note: LSUIElement in Info.plist handles the accessory policy.
        // Do NOT call NSApp.setActivationPolicy(.accessory) here — it triggers
        // a teardown cycle that wipes the status item immediately after creation.

        // Setup status item — variable length showing icon + short task text
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "Focus")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeft
            button.title = " …"
            button.action = #selector(statusBarButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
        }

        // Keep title + tooltip in sync with the current task
        checkvistManager.$tasks
            .combineLatest(checkvistManager.$currentTaskIndex)
            .receive(on: RunLoop.main)
            .sink { [weak self] tasks, index in
                guard !tasks.isEmpty, tasks.indices.contains(index) else {
                    self?.statusItem?.button?.title = " …"
                    self?.statusItem?.button?.toolTip = "No tasks loaded"
                    return
                }
                let full = tasks[index].content
                let short = full.count > 20 ? String(full.prefix(20)) + "…" : full
                self?.statusItem?.button?.title = " " + short
                self?.statusItem?.button?.toolTip = full
            }
            .store(in: &cancellables)

        // Fetch tasks — deferred slightly so the run loop can settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Task { await self.checkvistManager.fetchTopTask() }
        }
    }

    // Lazily create the popover only when first needed
    private func makePopoverIfNeeded() -> NSPopover {
        if let existing = popover { return existing }
        let p = NSPopover()
        p.contentSize = NSSize(width: 320, height: 380)
        p.behavior = .applicationDefined
        p.contentViewController = NSHostingController(
            rootView: PopoverView().environmentObject(checkvistManager)
        )
        popover = p
        return p
    }

    @objc func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            Task { await checkvistManager.fetchTopTask() }
        } else {
            togglePopover()
        }
    }

    func togglePopover() {
        let p = makePopoverIfNeeded()
        if p.isShown {
            p.performClose(nil)
        } else if let button = statusItem.button {
            p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // CRITICAL for menu bar apps: prevent macOS from quitting when the Settings window closes
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
