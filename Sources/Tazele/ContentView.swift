import SwiftUI
import TazeleCore

struct ContentView: View {
    @Bindable var store: Store
    var inWindow = false
    @Environment(\.openWindow) private var openWindow
    @State private var overrides: [SourceKind: Bool] = [:]
    @State private var showLog = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var spring: Animation? { reduceMotion ? nil : Theme.spring }
    private var swap: AnyTransition { reduceMotion ? .opacity : .materialize }

    var body: some View {
        VStack(spacing: 12) {
            header
            Group {
                if store.isUpdating { progressCard.transition(swap) }
                else if (store.isChecking && store.items.isEmpty) || store.lastChecked == nil { scanningCard.transition(swap) }
                else if store.items.isEmpty && !store.errors.isEmpty { failedCard.transition(swap) }
                else if store.updatableItems.isEmpty && store.items.isEmpty { upToDateCard.transition(swap) }
                else {
                    VStack(spacing: 12) { summaryCard; sourceList }.transition(swap)
                }
            }
            if store.finished && !store.isUpdating { resultBanner.transition(swap) }
            if !store.errors.isEmpty { errorBanner }
            if !store.isUpdating, !store.log.isEmpty { logDisclosure }
            primaryAction
            if needsPasswordHint && !store.isUpdating {
                Label("App Store güncellemesi için yönetici parolası istenecek", systemImage: "lock.fill")
                    .font(.system(size: 10.5)).tracking(0.1).foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            footer
        }
        .padding(16)
        .frame(width: 400)
        .animation(spring, value: store.isUpdating)
        .animation(spring, value: store.isChecking)
        .animation(spring, value: store.finished)
        .modifier(WindowMaterial(enabled: inWindow))
    }

    // MARK: Başlık

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.brand)
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 38, height: 38)
            .shadow(color: Theme.brandBottom.opacity(0.4), radius: 6, y: 2)

            VStack(alignment: .leading, spacing: 1) {
                Text("Tazele").font(.system(size: 17, weight: .bold, design: .rounded)).tracking(-0.2)
                Text(subtitle).font(.system(size: 11.5)).tracking(0.1).foregroundStyle(.secondary)
            }
            Spacer()
            Button { store.check() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                    .rotationEffect(.degrees(store.isChecking && !reduceMotion ? 360 : 0))
                    .opacity(store.isChecking && reduceMotion ? 0.4 : 1)
                    .animation(store.isChecking && !reduceMotion ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default,
                               value: store.isChecking)
            }
            .buttonStyle(IconButtonStyle())
            .disabled(store.isChecking || store.isUpdating)
            .help("Yeniden tara")
        }
    }

    private var subtitle: String {
        if store.isUpdating { return String(localized: "Güncelleniyor…") }
        if store.isChecking || store.lastChecked == nil { return String(localized: "Taranıyor…") }
        if store.items.isEmpty && !store.errors.isEmpty { return String(localized: "Kontrol tamamlanamadı") }
        let n = store.updatableItems.count
        return n == 0 ? String(localized: "Her şey güncel") : String(localized: "\(n) güncelleme bekliyor")
    }

    // MARK: Durum kartları

    private var summaryCard: some View {
        Card(elevated: true) {
            HStack(alignment: .center, spacing: 14) {
                Text("\(store.updatableItems.count)")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .tracking(-1.2)
                    .foregroundStyle(Theme.brand)
                    .contentTransition(.numericText())
                VStack(alignment: .leading, spacing: 5) {
                    Text("güncelleme hazır").font(.system(size: 12.5, weight: .semibold)).tracking(0.1)
                    HStack(spacing: 10) {
                        ForEach(SourceKind.allCases.filter { $0 != .system && !store.items(in: $0).isEmpty }, id: \.self) { kind in
                            HStack(spacing: 4) {
                                Circle().fill(kind.tint).frame(width: 6, height: 6)
                                Text("\(kind.shortTitle) \(store.items(in: kind).count)")
                                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    private var scanningCard: some View {
        Card {
            VStack(spacing: 10) {
                ProgressView().controlSize(.regular)
                Text("Kurulu kaynaklar taranıyor").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 28)
        }
    }

    /// Kontrol başarısızsa "her şey güncel" demek yanıltıcı olur.
    private var failedCard: some View {
        Card {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 32)).foregroundStyle(.orange)
                Text("Kontrol tamamlanamadı").font(.system(size: 15, weight: .semibold, design: .rounded))
                Text("Aşağıdaki kaynaklar okunamadı; güncel olduğu anlamına gelmez.")
                    .font(.system(size: 11.5)).tracking(0.1).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 22).padding(.horizontal, 12)
        }
    }

    private var upToDateCard: some View {
        Card {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 34)).foregroundStyle(Theme.brand)
                Text("Her şey güncel").font(.system(size: 15, weight: .semibold, design: .rounded))
                Text("Taramada bekleyen güncelleme yok").font(.system(size: 11.5)).tracking(0.1).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 26)
        }
    }

    private var progressCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Adım \(store.step)/\(max(store.steps, 1))").font(.system(size: 12.5, weight: .semibold))
                    Text(store.currentCommand).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Durdur") { store.cancel() }.buttonStyle(.link).font(.system(size: 12))
                }
                ProgressView(value: Double(store.step), total: Double(max(store.steps, 1)))
                    .tint(Theme.brandTop)
                logBox(height: 170)
            }
            .padding(14)
        }
    }

    // MARK: Kaynak listesi

    private var sourceList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(SourceKind.allCases, id: \.self) { kind in
                    if !store.items(in: kind).isEmpty { section(kind) }
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.never)
        .frame(minHeight: 150, idealHeight: inWindow ? 420 : 300, maxHeight: inWindow ? 420 : 300)
    }

    private func isExpanded(_ kind: SourceKind) -> Bool {
        overrides[kind] ?? (store.items(in: kind).count <= 6)
    }

    private func section(_ kind: SourceKind) -> some View {
        let group = store.items(in: kind)
        let expanded = isExpanded(kind)
        return Card {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button { withAnimation(spring) { overrides[kind] = !expanded } } label: {
                        HStack(spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(kind.tint.gradient)
                                Image(systemName: kind.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                            }
                            .frame(width: 26, height: 26)
                            Text(kind.title).font(.system(size: 12.5, weight: .semibold))
                            Text("\(group.count)")
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 6).padding(.vertical, 1.5)
                                .background(.primary.opacity(0.08), in: Capsule())
                            Spacer()
                            if kind != .system {
                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.tertiary).rotationEffect(.degrees(expanded ? 90 : 0))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(RowButtonStyle())
                    if kind != .system && kind != .sparkle {
                        Button { store.toggleGroup(kind) } label: { CheckCircle(isOn: store.isAllSelected(kind)) }
                            .buttonStyle(.plain).help("Tümünü seç / bırak")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)

                if expanded || kind == .system {
                    Divider().opacity(0.5)
                    VStack(spacing: 0) { ForEach(group) { row($0) } }
                        .transition(.opacity)
                }
            }
        }
    }

    @ViewBuilder private func row(_ item: OutdatedItem) -> some View {
        if item.source == .sparkle {
            HStack(spacing: 10) {
                Text(item.name).font(.system(size: 12.5)).lineLimit(1)
                Spacer(minLength: 8)
                VersionPill(installed: item.installed, latest: item.latest)
                Button("Aç") { if let p = item.path { NSWorkspace.shared.open(URL(fileURLWithPath: p)) } }
                    .buttonStyle(.link).font(.system(size: 11.5))
                    .help("Uygulamayı aç; güncellemeyi kendi güncelleyicisinden yükle")
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        } else if item.source == .system {
            HStack {
                Text(item.name).font(.system(size: 12)).lineLimit(1)
                Spacer()
                Button {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!)
                } label: { Label("Ayarlar", systemImage: "arrow.up.forward.app").font(.system(size: 11.5)) }
                    .buttonStyle(.link)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        } else {
            Button { store.toggle(item) } label: {
                HStack(spacing: 10) {
                    CheckCircle(isOn: store.selection.contains(item.id))
                    Text(item.name).font(.system(size: 12.5)).lineLimit(1)
                    Spacer(minLength: 8)
                    VersionPill(installed: item.installed, latest: item.latest)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())
        }
    }

    // MARK: Hata, günlük, eylem

    private var resultBanner: some View {
        let ok = store.failedSteps == 0
        return Label {
            (ok ? Text("Güncellemeler tamamlandı") : Text("\(store.failedSteps) adım hata verdi, günlüğe bak"))
                .font(.system(size: 12, weight: .medium)).tracking(0.1)
        } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background((ok ? Color.green : Color.orange).opacity(0.13), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var errorBanner: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(store.errors.sorted(by: { $0.key < $1.key }), id: \.key) { name, message in
                Label {
                    Text("\(name): \(message)").font(.system(size: 11)).lineLimit(2)
                } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var logDisclosure: some View {
        DisclosureGroup(isExpanded: Binding(get: { showLog || store.failedSteps > 0 }, set: { showLog = $0 })) {
            logBox(height: 120).padding(.top, 6)
        } label: {
            Text("Son işlem günlüğü").font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }

    private func logBox(height: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(store.log.joined(separator: "\n"))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .id("end")
            }
            .onChange(of: store.log.count) { proxy.scrollTo("end", anchor: .bottom) }
        }
        .frame(height: height)
        .padding(8)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var primaryAction: some View {
        let n = store.selectedItems.count
        return Button { store.updateSelected() } label: {
            HStack(spacing: 7) {
                Image(systemName: "arrow.down.circle.fill")
                (n == 0 ? Text("Güncellenecek öğe seç") : Text("\(n) güncellemeyi yükle"))
            }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(n == 0 || store.isUpdating || store.isChecking)
        .opacity(store.isUpdating ? 0.5 : 1)
    }

    private var needsPasswordHint: Bool { store.selectedItems.contains { $0.source == .appStore } }

    // MARK: Alt çubuk

    private var footer: some View {
        HStack {
            if let date = store.lastChecked {
                Text("Son tarama \(date.formatted(date: .omitted, time: .shortened))")
            }
            Spacer()
            Menu {
                if !inWindow {
                    Button("Pencereyi aç") {
                        openWindow(id: "main")
                        NSApp.activate()
                    }
                    Divider()
                }
                if !store.unknownFeedApps.isEmpty {
                    Text("Adresi okunamayan: \(store.unknownFeedApps.joined(separator: ", "))")
                    Divider()
                }
                if !store.missingTools.isEmpty {
                    Text("Bulunamayan araçlar: \(store.missingTools.joined(separator: ", "))")
                    Divider()
                }
                SettingsLink { Text("Ayarlar…") }
                Divider()
                Button("GitHub'da aç") { NSWorkspace.shared.open(URL(string: "https://github.com/yigitbuyukeren/tazele")!) }
                Divider()
                Button("Tazele'den çık") { NSApplication.shared.terminate(nil) }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .font(.system(size: 11)).tracking(0.15).foregroundStyle(.tertiary)
    }
}

/// Pencerede arka plan sistem malzemesi olur (şeffaflığı azalt ayarına otomatik uyar).
private struct WindowMaterial: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.containerBackground(.regularMaterial, for: .window) } else { content }
    }
}
