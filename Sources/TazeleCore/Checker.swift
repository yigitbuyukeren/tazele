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
            // `mas update` root ister; yalnızca root'a ait, kullanıcının değiştiremeyeceği bir `mas` varsa
            // Tazele'den kurulabilir. Homebrew'ün kullanıcıya ait `mas`'ı ile App Store'un kendisi açılır.
            let trusted = PrivilegedCommand.trustedTool("mas", searchPath: searchPath) != nil
            return Parsers.mas(r.text).map { $0.withInstallable(trusted) }
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
        // Homebrew'ün kendi yönettiği uygulamalar brew grubunda gösterilir; burada tekrarlanmaz.
        let unmanaged = feedless.filter { app in
            !casks.contains { Sparkle.isSameApp(app.name, cask: $0) } && SparkleFallback.caskToken(for: app, in: caskIndex) == nil
        }
        async let cask = SparkleFallback.updatesFromCaskIndex(apps: unmanaged)
        // `.pkg` ile kurulmuş uygulamalar (WARP, Tailscale): satıcı beslemesi veya pkgutil + cask eşlemesi.
        async let pkg = PkgApps.updates(apps: unmanaged, runner: runner)
        var viaCasks: [OutdatedItem] = []
        for item in await cask + pkg where !viaCasks.contains(where: { $0.name == item.name }) { viaCasks.append(item) }
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

/// Bir güncelleme adımı. Çoğu adım bir komuttur; root isteyenler ve Sparkle kurulumu ayrı yürütülür.
public enum UpdateStep: Sendable {
    case command([String])
    /// Root gerektiren komut (örn. `mas update`, `softwareupdate -i`). `PrivilegedRunner` yürütür.
    case privileged([String])
    /// Sparkle uygulamasını Tazele'nin kendisi kurar (imza doğrulamalı). `SparkleInstaller` yürütür.
    case sparkle(OutdatedItem)

    /// Günlükte gösterilen satır.
    public var display: String {
        switch self {
        case .command(let c): c.joined(separator: " ")
        case .privileged(let c): "[yönetici] " + c.joined(separator: " ")
        case .sparkle(let item): "sparkle-install \(item.name)"
        }
    }

    /// İlerleme panelinde gösterilen kısa ad.
    public var shortTitle: String {
        switch self {
        case .command(let c), .privileged(let c):
            c.prefix(2).map { ($0 as NSString).lastPathComponent }.joined(separator: " ")
        case .sparkle(let item): item.name
        }
    }
}

/// Güncelleme planı: sıralı adımlar ve atlanan öğeler için günlük satırları.
public struct UpdatePlan: Sendable {
    public var steps: [UpdateStep] = []
    /// Neden atlandığını anlatan tek satırlık açıklamalar (geçersiz paket adı, güvenilmeyen `mas`).
    public var skipped: [String] = []
}

/// Araç çıktısından gelen paket adları komut satırına argüman olarak geçer. Tutucu bir dilbilgisine
/// uymayan ad (ör. "-" ile başlayan, seçenek gibi yorumlanabilecek) adım dışında bırakılır.
public enum PackageName {
    /// Harf/rakamla başlayan, `[A-Za-z0-9@._+-]` karakterlerinden oluşan parça.
    static func isBrewSegment(_ s: Substring) -> Bool {
        guard let first = s.unicodeScalars.first, isAlnum(first) else { return false }
        return s.unicodeScalars.allSatisfy { isAlnum($0) || "@._+-".unicodeScalars.contains($0) }
    }

    /// Homebrew formül/cask adı; tap'li biçim (`kullanıcı/tap/ad`) en fazla üç parça.
    public static func isBrew(_ s: String) -> Bool {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        return (1...3).contains(parts.count) && parts.allSatisfy(isBrewSegment)
    }

    /// npm: `^(@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*$`
    public static func isNpm(_ s: String) -> Bool {
        func part(_ p: Substring) -> Bool {
            guard let first = p.unicodeScalars.first, isLowerAlnum(first) else { return false }
            return p.unicodeScalars.allSatisfy { isLowerAlnum($0) || "._-".unicodeScalars.contains($0) }
        }
        if s.hasPrefix("@") {
            let parts = s.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            return parts.count == 2 && part(parts[0]) && part(parts[1])
        }
        return part(Substring(s))
    }

    /// RubyGems: harf/rakamla başlayan `[A-Za-z0-9._-]`.
    public static func isGem(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, isAlnum(first) else { return false }
        return s.unicodeScalars.allSatisfy { isAlnum($0) || "._-".unicodeScalars.contains($0) }
    }

    /// Python paket adı (PEP 508): harf/rakamla başlar ve biter, arada `[A-Za-z0-9._-]`.
    public static func isPython(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, let last = s.unicodeScalars.last, isAlnum(first), isAlnum(last) else { return false }
        return s.unicodeScalars.allSatisfy { isAlnum($0) || "._-".unicodeScalars.contains($0) }
    }

    private static func isAlnum(_ c: Unicode.Scalar) -> Bool {
        c.isASCII && (("a"..."z").contains(c) || ("A"..."Z").contains(c) || ("0"..."9").contains(c))
    }

    private static func isLowerAlnum(_ c: Unicode.Scalar) -> Bool {
        c.isASCII && (("a"..."z").contains(c) || ("0"..."9").contains(c))
    }
}

public enum Updater {
    /// Seçili öğeler için sıralı güncelleme adımları (kaynağa göre gruplanmış).
    public static func steps(for items: [OutdatedItem]) -> [UpdateStep] { plan(for: items).steps }

    /// Seçili öğeler için plan. `masPath`: root olarak çalıştırılabilecek güvenilir `mas` (yoksa App Store
    /// öğeleri atlanır ve kullanıcı App Store'a yönlendirilir).
    /// Ad argümanlarından önce, aracın desteklediği yerde `--` konur (brew, npm, gem: kaynak koduyla doğrulandı).
    public static func plan(for items: [OutdatedItem],
                            masPath: @autoclosure () -> String? = PrivilegedCommand.trustedTool("mas")) -> UpdatePlan {
        var plan = UpdatePlan()
        func skip(_ name: String) {
            plan.skipped.append(String(localized: "Geçersiz paket adı atlandı: \(name)", bundle: .main))
        }
        func names(_ k: SourceKind, _ isValid: (String) -> Bool) -> [String] {
            items.filter { $0.source == k }.map(\.name).filter { name in
                if isValid(name) { return true }
                skip(name)
                return false
            }
        }
        func add(_ c: [String]) { plan.steps.append(.command(c)) }
        let formulae = names(.homebrewFormula, PackageName.isBrew)
        if !formulae.isEmpty { add(["brew", "upgrade", "--formula", "--"] + formulae) }
        let casks = names(.homebrewCask, PackageName.isBrew)
        if !casks.isEmpty { add(["brew", "upgrade", "--cask", "--"] + casks) }
        let greedy = names(.selfUpdatingCask, PackageName.isBrew)
        if !greedy.isEmpty { add(["brew", "upgrade", "--cask", "--greedy", "--"] + greedy) }
        let appIDs = items.filter { $0.source == .appStore }.compactMap(\.appID)
        if !appIDs.isEmpty {
            // `mas update` root ister; seçilen kimlikler tek tek geçilir (sayısal oldukları `validate`'te denetlenir).
            if let mas = masPath() {
                plan.steps.append(.privileged([mas, "update"] + appIDs))
            } else {
                plan.skipped.append(String(localized: "App Store güncellemeleri atlandı: mas yönetici olarak güvenle çalıştırılamıyor; App Store'dan güncelle.", bundle: .main))
            }
        }
        let npm = names(.npm, PackageName.isNpm)
        if !npm.isEmpty { add(["npm", "update", "-g", "--"] + npm) }
        if items.contains(where: { $0.source == .rustup }) { add(["rustup", "update"]) }
        let gems = names(.gem, PackageName.isGem)
        if !gems.isEmpty { add(["gem", "update", "--"] + gems) }
        for item in items where item.source == .pythonTools {
            // pipx / uv için `--` doğrulanmadı; ad dilbilgisi "-" ile başlamayı zaten engeller.
            guard PackageName.isPython(item.name) else { skip(item.name); continue }
            add(item.manager == "uv" ? ["uv", "tool", "upgrade", item.name] : ["pipx", "upgrade", item.name])
        }
        if items.contains(where: { $0.source == .ohMyZsh }) {
            add(["sh", "-c", "ZSH=\"${ZSH:-$HOME/.oh-my-zsh}\" \"$ZSH/tools/upgrade.sh\""])
        }
        // Yeniden başlatma istemeyen macOS güncellemeleri (ör. Command Line Tools). Etiket `validate`'te denetlenir.
        for item in items where item.source == .system && item.installable {
            plan.steps.append(.privileged(["softwareupdate", "-i", item.manager ?? item.name]))
        }
        // Sparkle uygulamaları: cask'i varsa Homebrew ile, yoksa Tazele kendisi kurar.
        let sparkle = items.filter { $0.source == .sparkle }
        let tokens = sparkle.compactMap(\.caskToken).filter { token in
            if PackageName.isBrew(token) { return true }
            skip(token)
            return false
        }
        if !tokens.isEmpty { add(["brew", "upgrade", "--cask", "--greedy", "--"] + tokens) }
        for item in sparkle where item.caskToken == nil && SparkleInstaller.canInstall(item) { plan.steps.append(.sparkle(item)) }
        return plan
    }

    /// Yalnızca komut tabanlı adımlar (root isteyenlerin başına `sudo -A` eklenir). Testler ve günlük için.
    public static func commands(for items: [OutdatedItem],
                                masPath: @autoclosure () -> String? = PrivilegedCommand.trustedTool("mas")) -> [[String]] {
        plan(for: items, masPath: masPath()).steps.compactMap {
            switch $0 {
            case .command(let c): c
            case .privileged(let c): ["sudo", "-A"] + c
            case .sparkle: nil
            }
        }
    }
}
