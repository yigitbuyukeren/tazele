import SwiftUI
import TazeleCore

struct ContentView: View {
    @Bindable var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if store.items.isEmpty && !store.isChecking {
                Text(store.errors.isEmpty ? "Her şey güncel." : "Bazı kaynaklar okunamadı.")
                    .foregroundStyle(.secondary)
            } else {
                list
            }
            if !store.errors.isEmpty { errorList }
            if !store.log.isEmpty { logView }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 420)
    }

    private var header: some View {
        HStack {
            Text("Tazele").font(.headline)
            Spacer()
            if store.isChecking || store.isUpdating { ProgressView().controlSize(.small) }
            Button("Yeniden tara") { store.check() }.disabled(store.isChecking || store.isUpdating)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(SourceKind.allCases, id: \.self) { kind in
                    let group = store.items.filter { $0.source == kind }
                    if !group.isEmpty {
                        Text(kind.title).font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                        ForEach(group) { row($0) }
                    }
                }
            }
        }
        .frame(minHeight: 180, idealHeight: 260, maxHeight: 260)
    }

    @ViewBuilder private func row(_ item: OutdatedItem) -> some View {
        if item.source == .system {
            HStack {
                Text(item.name).lineLimit(1)
                Spacer()
                Button("Sistem Ayarları") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!)
                }.buttonStyle(.link)
            }
        } else {
            Toggle(isOn: Binding(
                get: { store.selection.contains(item.id) },
                set: { if $0 { store.selection.insert(item.id) } else { store.selection.remove(item.id) } }
            )) {
                HStack {
                    Text(item.name).lineLimit(1)
                    Spacer()
                    Text("\(item.installed) → \(item.latest)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
        }
    }

    private var errorList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(store.errors.sorted(by: { $0.key < $1.key }), id: \.key) { name, message in
                Text("\(name): \(message)").font(.caption).foregroundStyle(.red).lineLimit(2)
            }
        }
    }

    private var logView: some View {
        ScrollView {
            Text(store.log.joined(separator: "\n"))
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(height: 110)
        .padding(6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private var footer: some View {
        HStack {
            Button("Seçilenleri güncelle (\(store.selectedItems.count))") { store.updateSelected() }
                .disabled(store.selectedItems.isEmpty || store.isUpdating || store.isChecking)
            if store.isUpdating { Button("Durdur") { store.cancel() } }
            Spacer()
            Button("Çık") { NSApplication.shared.terminate(nil) }
        }
    }
}
