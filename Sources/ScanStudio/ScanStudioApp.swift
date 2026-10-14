import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Necessario quando l'eseguibile viene lanciato fuori da un bundle .app
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ScanStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("ScanStudio", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1100, minHeight: 680)
        }
        .defaultSize(width: 1320, height: 840)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
