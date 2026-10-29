import AppKit
import SwiftUI
import TazeleCore

@MainActor let sharedStore = Store()

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `--window`: aynı arayüzü sıradan bir pencerede açar (hata ayıklama ve ekran görüntüsü için).
        guard CommandLine.arguments.contains("--window") else {
            NSApp.setActivationPolicy(.accessory)
            return
        }
        NSApp.setActivationPolicy(.regular)
        let host = NSHostingController(rootView: ContentView(store: sharedStore).task { sharedStore.check() })
        let win = NSWindow(contentViewController: host)
        win.title = "Tazele"
        win.setFrameOrigin(NSPoint(x: 80, y: 200))
        win.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window = win
    }
}

@main
struct TazeleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    
    var body: some Scene {
        MenuBarExtra {
            ContentView(store: sharedStore)
                .task { sharedStore.check() }
        } label: {
            Image(systemName: sharedStore.items.isEmpty ? "arrow.triangle.2.circlepath" : "arrow.triangle.2.circlepath.circle.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
