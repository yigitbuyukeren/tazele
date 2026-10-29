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

    private let runner = CommandRunner()
    private var task: Task<Void, Never>?

    var selectedItems: [OutdatedItem] { items.filter { selection.contains($0.id) && $0.source != .system } }

    func check() {
        guard !isChecking, !isUpdating else { return }
        isChecking = true
        errors = [:]
        task = Task {
            let report = await Checker.checkAll(runner: runner)
            items = report.items
            errors = report.errors
            selection = Set(report.items.filter { $0.source != .system }.map(\.id))
            lastChecked = .now
            isChecking = false
        }
    }

    func updateSelected() {
        let chosen = selectedItems
        guard !chosen.isEmpty, !isUpdating, !isChecking else { return }
        isUpdating = true
        log = []
        task = Task {
            for command in Updater.commands(for: chosen) {
                if Task.isCancelled { break }
                log.append("$ " + command.joined(separator: " "))
                do {
                    let r = try await runner.run(command) { line in
                        Task { @MainActor in self.log.append(line) }
                    }
                    if r.status != 0 { log.append("Çıkış kodu: \(r.status)") }
                } catch {
                    log.append("Hata: \(error.localizedDescription)")
                }
            }
            isUpdating = false
            check()
        }
    }

    func cancel() { task?.cancel() }
}
