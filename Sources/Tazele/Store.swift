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
    var unknownFeedApps: [String] = []

    /// Yoksayılan öğeler; uygulama yeniden açılınca da korunur.
    private(set) var ignoreList = IgnoreList()

    private let runner = CommandRunner()
    private var task: Task<Void, Never>?

    /// Yoksayılanlar dışındaki öğeler: listeler, sayılar ve seçim bunlardan hesaplanır.
    var activeItems: [OutdatedItem] { items.filter { !ignoreList.isIgnored($0) } }

    /// Son taramada görünen ama yoksayılan öğeler.
    var ignoredItems: [OutdatedItem] { items.filter { ignoreList.isIgnored($0) } }

    var selectedItems: [OutdatedItem] { activeItems.filter { selection.contains($0.id) && Self.isSelectable($0) } }

    /// Menü çubuğu ve Dock sayısı: macOS satırları ayrı gösterilir, sayılmaz.
    var updatableItems: [OutdatedItem] { activeItems.filter { $0.source != .system } }

    func items(in kind: SourceKind) -> [OutdatedItem] { activeItems.filter { $0.source == kind } }

    func selectableItems(in kind: SourceKind) -> [OutdatedItem] { items(in: kind).filter(Self.isSelectable) }

    /// Tazele'nin kendisinin kurabileceği öğeler işaretlenebilir.
    static func isSelectable(_ item: OutdatedItem) -> Bool {
        switch item.source {
        case .sparkle: item.caskToken != nil || SparkleInstaller.canInstall(item)
        case .system: item.installable
        default: true
        }
    }

    /// Taramadan sonra kendiliğinden işaretli gelenler; kendi güncelleyicisi olanlar ve macOS elle seçilir.
    static func isSelectedByDefault(_ item: OutdatedItem) -> Bool {
        isSelectable(item) && ![.system, .sparkle, .selfUpdatingCask].contains(item.source)
    }

    /// Beta / sürüm adayı macOS güncellemelerini ayırt eder (ör. "macOS 26.1 Beta", "RC 2", "26.1 RC").
    static func isPrerelease(_ item: OutdatedItem) -> Bool {
        let text = "\(item.name) \(item.latest)"
        if text.range(of: "beta", options: .caseInsensitive) != nil { return true }
        if text.range(of: "release candidate", options: .caseInsensitive) != nil { return true }
        let words = text.split { !$0.isLetter && !$0.isNumber }
        return words.contains { $0.hasPrefix("RC") && $0.dropFirst(2).allSatisfy(\.isNumber) }
    }

    func isAllSelected(_ kind: SourceKind) -> Bool {
        let group = selectableItems(in: kind)
        return !group.isEmpty && group.allSatisfy { selection.contains($0.id) }
    }

    func toggleGroup(_ kind: SourceKind) {
        let ids = Set(selectableItems(in: kind).map(\.id))
        if isAllSelected(kind) { selection.subtract(ids) } else { selection.formUnion(ids) }
    }

    func toggle(_ item: OutdatedItem) {
        guard Self.isSelectable(item) else { return }
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    /// Öğeyi listeden çıkarır; `versionOnly` ise daha yeni bir sürüm çıkınca geri gelir.
    func ignore(_ item: OutdatedItem, versionOnly: Bool = false) {
        ignoreList.ignore(item, versionOnly: versionOnly)
        selection.remove(item.id)
        Notifier.updateBadge(count: updatableItems.count)
    }

    func restore(id: String) {
        ignoreList.restore(id: id)
        if !isUpdating, let item = items.first(where: { $0.id == id }), Self.isSelectedByDefault(item) {
            selection.insert(id)
        }
        Notifier.updateBadge(count: updatableItems.count)
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
        // Daha yeni sürümü çıkmış "bu sürümü yoksay" kayıtları temizlenir; öğe listeye döner.
        ignoreList.pruneStale(current: report.items)
        selection = Set(activeItems.filter(Self.isSelectedByDefault).map(\.id))
        lastChecked = .now
        isChecking = false

        let current = Set(updatableItems.map(\.id))
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
        let plan = Updater.steps(for: chosen)
        steps = plan.count
        step = 0
        task = Task {
            for item in plan {
                if Task.isCancelled { break }
                step += 1
                currentCommand = item.shortTitle
                log.append("$ " + item.display)
                let sink: @Sendable (String) -> Void = { line in Task { @MainActor in self.log.append(line) } }
                do {
                    switch item {
                    case .command(let command):
                        let r = try await runner.run(command, onLine: sink)
                        if r.status != 0 { failedSteps += 1; log.append(String(localized: "Çıkış kodu: \(Int(r.status))")) }
                    case .privileged(let command):
                        let r = try await PrivilegedRunner.run(command, runner: runner, onLine: sink)
                        if r.status != 0 { failedSteps += 1; log.append(String(localized: "Çıkış kodu: \(Int(r.status))")) }
                    case .sparkle(let app):
                        try await SparkleInstaller.install(app, onLine: sink)
                    }
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
