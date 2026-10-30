import AppKit
import Foundation
import Observation
import TazeleCore

@MainActor @Observable
final class Store {
    var items: [OutdatedItem] = []
    var selection: Set<String> = []
    var errors: [String: String] = [:]
    var log: [String] = []
    var isChecking = false
    var isUpdating = false
    var lastChecked: Date?
    var step = 0
    var steps = 0
    var currentCommand = ""
    var finished = false
    var failedSteps = 0
    var missingTools: [String] = []

    private let runner = CommandRunner()
    private var task: Task<Void, Never>?

    var selectedItems: [OutdatedItem] { items.filter { selection.contains($0.id) && $0.source != .system && $0.source != .sparkle } }

    var updatableItems: [OutdatedItem] { items.filter { $0.source != .system } }
    var unknownFeedApps: [String] = []

    func items(in kind: SourceKind) -> [OutdatedItem] { items.filter { $0.source == kind } }

    func isAllSelected(_ kind: SourceKind) -> Bool {
        let group = items(in: kind)
        return !group.isEmpty && group.allSatisfy { selection.contains($0.id) }
    }

    func toggleGroup(_ kind: SourceKind) {
        let ids = Set(items(in: kind).map(\.id))
        if isAllSelected(kind) { selection.subtract(ids) } else { selection.formUnion(ids) }
    }

    func toggle(_ item: OutdatedItem) {
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    private var seenIDs: Set<String>?

    func check(clearResult: Bool = true) {
        guard !isChecking, !isUpdating else { return }
        if clearResult { finished = false }
        task = Task { await performCheck(background: false) }
    }

    /// Taramayı çalıştırır. Arka planda yeni çıkan güncellemeler için bildirim gönderir.
    func performCheck(background: Bool) async {
        guard !isChecking, !isUpdating else { return }
        isChecking = true
        errors = [:]
        let report = await Checker.checkAll(runner: runner)
        items = report.items
        errors = report.errors
        missingTools = report.missingTools
        unknownFeedApps = report.unknownFeedApps
        selection = Set(report.items.filter { ![.system, .sparkle, .selfUpdatingCask].contains($0.source) }.map(\.id))
        lastChecked = .now
        isChecking = false

        let current = Set(report.items.filter { $0.source != .system }.map(\.id))
        if let seen = seenIDs, background, report.errors.isEmpty {
            let fresh = current.subtracting(seen).count
            if fresh > 0 { Notifier.notifyNew(count: fresh) }
        }
        if report.errors.isEmpty { seenIDs = current }
        Notifier.updateBadge(count: updatableItems.count)
    }

    func updateSelected() {
        let chosen = selectedItems
        guard !chosen.isEmpty, !isUpdating, !isChecking else { return }
        isUpdating = true
        finished = false
        failedSteps = 0
        log = []
        let commands = Updater.commands(for: chosen)
        steps = commands.count
        step = 0
        task = Task {
            for command in commands {
                if Task.isCancelled { break }
                step += 1
                currentCommand = command.filter { $0 != "sudo" && $0 != "-A" }.prefix(2)
                    .map { ($0 as NSString).lastPathComponent }.joined(separator: " ")
                log.append("$ " + command.joined(separator: " "))
                do {
                    let r = try await runner.run(command) { line in
                        Task { @MainActor in self.log.append(line) }
                    }
                    if r.status != 0 { failedSteps += 1; log.append(String(localized: "Çıkış kodu: \(Int(r.status))")) }
                } catch {
                    failedSteps += 1
                    log.append(String(localized: "Hata: \(error.localizedDescription)"))
                }
            }
            isUpdating = false
            finished = true
            // Ses/titreşim/görsel aynı anda: başarı ve hata farklı karakterde.
            NSHapticFeedbackManager.defaultPerformer.perform(failedSteps == 0 ? .levelChange : .generic, performanceTime: .now)
            check(clearResult: false)
        }
    }

    func cancel() { task?.cancel() }
}
