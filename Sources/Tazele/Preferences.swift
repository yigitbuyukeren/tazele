import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

enum Pref {
    static let checkHours = "checkHours"        // 0 = yalnızca elle
    static let notify = "notifyOnNew"
    static let dockBadge = "dockBadge"
}

/// Arka plan kontrolü: `NSBackgroundActivityScheduler` sistemin pil/güç durumuna göre zamanlar.
@MainActor
final class BackgroundChecker {
    private var scheduler: NSBackgroundActivityScheduler?

    func reschedule() {
        scheduler?.invalidate()
        scheduler = nil
        let hours = UserDefaults.standard.integer(forKey: Pref.checkHours)
        guard hours > 0 else { return }
        let s = NSBackgroundActivityScheduler(identifier: "com.yigitbuyukeren.tazele.check")
        s.repeats = true
        s.interval = TimeInterval(hours) * 3600
        s.tolerance = s.interval * 0.2
        s.qualityOfService = .utility
        s.schedule { completion in
            Task { @MainActor in
                await sharedStore.performCheck(background: true)
                completion(.finished)
            }
        }
        scheduler = s
    }
}

enum Notifier {
    private static var available: Bool { Bundle.main.bundlePath.hasSuffix(".app") }

    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) { _, _ in }
    }

    static func notifyNew(count: Int) {
        guard available, UserDefaults.standard.bool(forKey: Pref.notify) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Tazele"
        content.body = String(localized: "\(count) yeni güncelleme var")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    static func updateBadge(count: Int) {
        NSApp.dockTile.badgeLabel = UserDefaults.standard.bool(forKey: Pref.dockBadge) && count > 0 ? "\(count)" : nil
    }
}

struct SettingsView: View {
    @AppStorage(Pref.checkHours) private var checkHours = 0
    @AppStorage(Pref.notify) private var notify = false
    @AppStorage(Pref.dockBadge) private var dockBadge = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Picker("Otomatik kontrol", selection: $checkHours) {
                Text("Yalnızca elle").tag(0)
                Text("Her saat").tag(1)
                Text("4 saatte bir").tag(4)
                Text("12 saatte bir").tag(12)
                Text("Günde bir").tag(24)
            }
            Toggle("Yeni güncelleme çıkınca bildirim gönder", isOn: $notify)
                .onChange(of: notify) { _, on in if on { Notifier.requestAuthorization() } }
            Toggle("Dock simgesinde sayıyı göster", isOn: $dockBadge)
                .onChange(of: dockBadge) { _, _ in Notifier.updateBadge(count: sharedStore.updatableItems.count) }
            Toggle("Oturum açılınca Tazele'yi başlat", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginError = nil
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                        loginError = String(localized: "Yalnızca .app olarak çalışırken ayarlanabilir.")
                    }
                }
            if let loginError { Text(loginError).font(.caption).foregroundStyle(.secondary) }
            Text("Arka planda yalnızca kontrol edilir; güncellemeler sen onaylayınca yüklenir.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
