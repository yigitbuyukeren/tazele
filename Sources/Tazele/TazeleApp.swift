import AppKit
import SwiftUI
import TazeleCore

@MainActor let sharedStore = Store()

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let background = BackgroundChecker()
    func applicationDidFinishLaunching(_ notification: Notification) {
        // @AppStorage varsayılanları yalnızca ayarlar penceresinde geçerlidir; UserDefaults.bool kayıtsız anahtar için false verir.
        UserDefaults.standard.register(defaults: [Pref.dockBadge: true, Pref.notify: false, Pref.checkHours: 0])
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        background.reschedule()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.background.reschedule()
        }
    }

    // Pencere kapansa da menü çubuğu öğesi çalışmaya devam eder.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct TazeleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Tazele", id: "main") {
            ContentView(store: sharedStore, inWindow: true)
                .task { if sharedStore.lastChecked == nil { sharedStore.check() } }
        }
        // Pencere boyutlanabilir; alt sınırı içeriğin en küçük çerçevesinden gelir.
        .windowResizability(.contentMinSize)
        .defaultSize(width: 480, height: 680)
        .defaultPosition(.center)

        MenuBarExtra {
            ContentView(store: sharedStore, inWindow: false)
                .task { if sharedStore.lastChecked == nil { sharedStore.check() } }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.2.circlepath")
                let n = sharedStore.updatableItems.count
                if n > 0 { Text("\(n)").monospacedDigit() }
            }
        }
        .menuBarExtraStyle(.window)

        Settings { SettingsView() }
    }
}
