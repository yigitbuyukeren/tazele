import Foundation

public struct CheckReport: Sendable {
    public var items: [OutdatedItem] = []
    /// Kaynak adı → hata; bir kaynağın hatası diğerlerini engellemez.
    public var errors: [String: String] = [:]
}

public enum Checker {
    public static func checkAll(runner: CommandRunner) async -> CheckReport {
        var report = CheckReport()
        // brew ve mas Spotlight/kilit kullandığı için sıralı; bağımsız olanlar paralel çalışabilir ama MVP basit tutuldu.
        await collect("Homebrew", into: &report) {
            let r = try await runner.run(["brew", "outdated", "--json=v2"])
            guard r.status == 0 else { throw CheckError.failed(r.text) }
            return try Parsers.brew(r.output)
        }
        await collect("App Store", into: &report) {
            let r = try await runner.run(["mas", "outdated"])
            guard r.status == 0 else { throw CheckError.failed(r.text) }
            return Parsers.mas(r.text)
        }
        await collect("npm", into: &report) {
            let r = try await runner.run(["npm", "outdated", "-g", "--json"])
            // npm güncel olmayan paket varsa 1 döner.
            guard r.status == 0 || r.status == 1 else { throw CheckError.failed(r.text) }
            return try Parsers.npm(r.output)
        }
        await collect("macOS", into: &report) {
            let r = try await runner.run(["softwareupdate", "-l"])
            return Parsers.softwareUpdate(r.text)
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
    var message: String {
        if case .failed(let s) = self { return String(s.suffix(300)).trimmingCharacters(in: .whitespacesAndNewlines) }
        return ""
    }
}

public enum Updater {
    /// Seçili öğeler için çalıştırılacak komutlar (kaynağa göre gruplanmış).
    public static func commands(for items: [OutdatedItem]) -> [[String]] {
        func names(_ k: SourceKind) -> [String] { items.filter { $0.source == k }.map(\.name) }
        var cmds: [[String]] = []
        if !names(.homebrewFormula).isEmpty { cmds.append(["brew", "upgrade", "--formula"] + names(.homebrewFormula)) }
        if !names(.homebrewCask).isEmpty { cmds.append(["brew", "upgrade", "--cask"] + names(.homebrewCask)) }
        if !names(.appStore).isEmpty { cmds.append(["mas", "upgrade"]) }
        if !names(.npm).isEmpty { cmds.append(["npm", "update", "-g"] + names(.npm)) }
        return cmds
    }
}
