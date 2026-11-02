import SwiftUI

struct PrismApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppDelegate.model
    @AppStorage("showsMenuBarIcon") private var showsMenuBarIcon = true

    var body: some Scene {
        // A real window first: the menu bar icon is a shortcut, never the only way in.
        Window("Prism", id: "main") {
            PrismPanel(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Window("Performance", id: "performance") {
            PerformanceView(model: model)
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        MenuBarExtra(isInserted: $showsMenuBarIcon) {
            PrismPanel(model: model)
        } label: {
            // The app icon in line: light goes into the prism, and the three rays come out while it's splitting.
            Image(model.status == .live ? "MenuPrismLive" : "MenuPrism")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let model = PrismModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        if let i = arguments.firstIndex(of: "--tap-pid"), let pid = pid_t(arguments[i + 1]) { Self.model.debugTap(pid: pid) }
        if arguments.contains("--on") || UserDefaults.standard.bool(forKey: "on") { Self.model.turnOn() }
    }

    /// Closing the window keeps the music flowing; Prism quits only when asked.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
