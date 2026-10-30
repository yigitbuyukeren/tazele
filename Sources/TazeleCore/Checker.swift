import Foundation

public struct CheckReport: Sendable {
    public var items: [OutdatedItem] = []
    /// Kaynak adı → hata; bir kaynağın hatası diğerlerini engellemez.
    public var errors: [String: String] = [:]
    /// Bu Mac'te kurulu olmayan araçlar; hata sayılmaz, sessizce atlanır.
    public var missingTools: [String] = []
    /// Sparkle içerir ama besleme adresi bilinmeyen uygulamalar (çalışma anında ayarlanıyor); kontrol edilemedi.
    public var unknownFeedApps: [String] = []
}

public enum Checker {
    public static func checkAll(runner: CommandRunner, searchPath: String = ShellEnvironment.make()["PATH"] ?? "") async -> CheckReport {
        var report = CheckReport()
        // brew ve mas Spotlight/kilit kullandığı için sıralı; bağımsız olanlar paralel çalışabilir ama MVP basit tutuldu.
        let installed = Set(["brew", "mas", "npm"].filter { Privilege.locate($0, path: searchPath) != nil })
        report.missingTools = ["brew", "mas", "npm"].filter { !installed.contains($0) }
        if installed.contains("brew") { await collect("Homebrew", into: &report) {
            let r = try await runner.run(["brew", "outdated", "--json=v2"], timeout: 180)
            guard !r.timedOut else { throw CheckError.timedOut }
            guard r.status == 0 else { throw CheckError.failed(r.text) }
            return try Parsers.brew(r.output)
        } }
        // `auto_updates` olan cask'ler normalde gizlenir. `--greedy` farkı ayrı grupta gösterilir;
        // cask kaydı eski kalmış ama uygulama kendini güncellemişse (ör. Ghostty) elenir.
        if installed.contains("brew"), report.errors["Homebrew"] == nil {
            if let r = try? await runner.run(["brew", "outdated", "--cask", "--greedy", "--json=v2"], timeout: 180),
               !r.timedOut, r.status == 0, let all = try? Parsers.brew(r.output) {
                let normal = Set(report.items.filter { $0.source == .homebrewCask }.map(\.name))
                let extra = all.filter { $0.source == .homebrewCask && !normal.contains($0.name) && $0.latest != "latest" }
                report.items += extra.compactMap { item -> OutdatedItem? in
                    if let actual = Sparkle.installedVersion(matchingCask: item.name),
                       VersionCompare.compare(actual, item.latest) != .orderedAscending { return nil }
                    return OutdatedItem(source: .selfUpdatingCask, name: item.name, installed: item.installed, latest: item.latest)
                }
            }
        }
        if installed.contains("mas") { await collect("App Store", into: &report) {
            let r = try await runner.run(["mas", "outdated"], timeout: 90)
            guard !r.timedOut else { throw CheckError.timedOut }
            guard r.status == 0 else { throw CheckError.failed(r.text) }
            return Parsers.mas(r.text)
        } }
        if installed.contains("npm") { await collect("npm", into: &report) {
            let r = try await runner.run(["npm", "outdated", "-g", "--json"], timeout: 90)
            guard !r.timedOut else { throw CheckError.timedOut }
            // npm güncel olmayan paket varsa 1 döner.
            guard r.status == 0 || r.status == 1 else { throw CheckError.failed(r.text) }
            return try Parsers.npm(r.output)
        } }
        let apps = Sparkle.scan().filter { !$0.isMacAppStore }
        let feedless = apps.filter { $0.feedURL == nil }
        report.unknownFeedApps = feedless.map(\.name)
        let caskIndex = installed.contains("brew") ? await SparkleFallback.installedCaskTokens(runner: runner) : [:]
        let casks = report.items.filter { $0.source == .homebrewCask || $0.source == .selfUpdatingCask }.map(\.name)
        let candidates = apps.filter { app in app.feedURL != nil && !casks.contains { Sparkle.isSameApp(app.name, cask: $0) } }
        let found = await withTaskGroup(of: OutdatedItem?.self) { group -> [OutdatedItem] in
            for app in candidates {
                group.addTask {
                    guard let item = Sparkle.outdated(app: app, items: await Sparkle.fetch(app.feedURL!)) else { return nil }
                    return item.withCaskToken(SparkleFallback.caskToken(for: app, in: caskIndex))
                }
            }
            var result: [OutdatedItem] = []
            for await item in group { if let item { result.append(item) } }
            return result
        }
        // Besleme adresi okunamayan uygulamalar: Homebrew'ün cask listesiyle sürüm karşılaştırması.
        let viaCasks = await SparkleFallback.updatesFromCaskIndex(
            apps: feedless.filter { app in !casks.contains { Sparkle.isSameApp(app.name, cask: $0) } })
        // Cask listesiyle denetlenebilenler artık "okunamayan" sayılmaz.
        report.unknownFeedApps = feedless.map(\.name).filter { name in !viaCasks.contains { $0.name == name } }
        report.items += (found + viaCasks).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        // Ek kaynaklar: rustup, RubyGems, pipx/uv, Oh My Zsh.
        let extra = await ExtraSources.check(runner: runner, searchPath: searchPath)
        report.items += extra.items
        report.errors.merge(extra.errors) { a, _ in a }
        for tool in extra.missingTools where !report.missingTools.contains(tool) { report.missingTools.append(tool) }
        await collect("macOS", into: &report) {
            let r = try await runner.run(["softwareupdate", "-l"], timeout: 120)
            guard !r.timedOut else { throw CheckError.timedOut }
            return SystemUpdates.parse(r.text)
        }
        return report
    }

    private static func collect(_ name: String, into report: inout CheckReport,
                                _ work: () async throws -> [OutdatedItem]) async {
        do { report.items += try await work() } catch {
            report.errors[name] = (error as? CheckError)?.message ?? error.localizedDescription
        }
    }
}

public enum CheckError: Error {
    case failed(String)
    case timedOut
    var message: String {
        switch self {
        case .failed(let s): String(s.suffix(300)).trimmingCharacters(in: .whitespacesAndNewlines)
        case .timedOut: String(localized: "Zaman aşımı", bundle: .main)
        }
    }
}

public enum Updater {
    /// Seçili öğeler için çalıştırılacak komutlar (kaynağa göre gruplanmış).
    public static func commands(for items: [OutdatedItem]) -> [[String]] {
        func names(_ k: SourceKind) -> [String] { items.filter { $0.source == k }.map(\.name) }
        var cmds: [[String]] = []
        if !names(.homebrewFormula).isEmpty { cmds.append(["brew", "upgrade", "--formula"] + names(.homebrewFormula)) }
        if !names(.homebrewCask).isEmpty { cmds.append(["brew", "upgrade", "--cask"] + names(.homebrewCask)) }
        if !names(.selfUpdatingCask).isEmpty { cmds.append(["brew", "upgrade", "--cask", "--greedy"] + names(.selfUpdatingCask)) }
        let appIDs = items.filter { $0.source == .appStore }.compactMap(\.appID)
        if !appIDs.isEmpty {
            // `mas update` root ister; seçilen kimlikler tek tek geçilir.
            cmds.append(["sudo", "-A", Privilege.locate("mas") ?? "mas", "update"] + appIDs)
        }
        if !names(.npm).isEmpty { cmds.append(["npm", "update", "-g"] + names(.npm)) }
        if !names(.rustup).isEmpty { cmds.append(["rustup", "update"]) }
        if !names(.gem).isEmpty { cmds.append(["gem", "update"] + names(.gem)) }
        for item in items where item.source == .pythonTools {
            cmds.append(item.manager == "uv" ? ["uv", "tool", "upgrade", item.name] : ["pipx", "upgrade", item.name])
        }
        if !names(.ohMyZsh).isEmpty {
            cmds.append(["sh", "-c", "ZSH=\"${ZSH:-$HOME/.oh-my-zsh}\" \"$ZSH/tools/upgrade.sh\""])
        }
        // Yeniden başlatma istemeyen macOS güncellemeleri (ör. Command Line Tools).
        for item in items where item.source == .system && item.installable {
            cmds.append(["sudo", "-A", "softwareupdate", "-i", item.manager ?? item.name])
        }
        // Homebrew cask'i olan Sparkle uygulamaları cask üzerinden güncellenir.
        let sparkleCasks = items.filter { $0.source == .sparkle }.compactMap(\.caskToken)
        if !sparkleCasks.isEmpty { cmds.append(["brew", "upgrade", "--cask", "--greedy"] + sparkleCasks) }
        return cmds
    }
}
