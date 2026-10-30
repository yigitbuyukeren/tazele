import Foundation

public struct ExtraSourcesReport: Sendable {
    public var items: [OutdatedItem] = []
    /// Kaynak adı → kısa hata.
    public var errors: [String: String] = [:]
    /// Kurulu olmayan araçlar (hata sayılmaz).
    public var missingTools: [String] = []

    public init() {}
}

/// rustup, gem, pipx/uv araçları ve Oh My Zsh için yalnızca okuma amaçlı güncelleme denetimi.
public enum ExtraSources {
    public static func check(runner: CommandRunner,
                             searchPath: String = ShellEnvironment.make()["PATH"] ?? "") async -> ExtraSourcesReport {
        var report = ExtraSourcesReport()
        await checkRustup(runner, searchPath, &report)
        await checkGem(runner, searchPath, &report)
        await checkPythonTools(runner, searchPath, &report)
        await checkOhMyZsh(runner, searchPath, &report)
        return report
    }

    // MARK: - Kaynaklar

    /// Çalıştırır; zaman aşımı ve sıfırdan farklı çıkışı hataya çevirir.
    private static func runChecked(_ runner: CommandRunner, _ cmd: [String], timeout: TimeInterval) async throws -> CommandResult {
        let r = try await runner.run(cmd, timeout: timeout)
        if r.timedOut { throw ExtraError(message: String(localized: "Zaman aşımı", bundle: .main)) }
        guard r.status == 0 else {
            throw ExtraError(message: String(r.text.suffix(300)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return r
    }

    private static func record(_ name: String, _ error: Error, _ report: inout ExtraSourcesReport) {
        report.errors[name] = (error as? ExtraError)?.message ?? error.localizedDescription
    }

    private static func checkRustup(_ runner: CommandRunner, _ path: String, _ report: inout ExtraSourcesReport) async {
        guard let tool = Privilege.locate("rustup", path: path) else { report.missingTools.append("rustup"); return }
        do {
            let r = try await runChecked(runner, [tool, "check"], timeout: 60)
            report.items += parseRustupCheck(r.text)
        } catch { record("rustup", error, &report) }
    }

    private static func checkGem(_ runner: CommandRunner, _ path: String, _ report: inout ExtraSourcesReport) async {
        guard let tool = Privilege.locate("gem", path: path) else { report.missingTools.append("gem"); return }
        // Sistem Ruby'si sudo ister ve dokunulmamalıdır.
        guard tool != "/usr/bin/gem" else { return }
        do {
            let r = try await runChecked(runner, [tool, "outdated"], timeout: 60)
            report.items += parseGemOutdated(r.text)
        } catch { record("gem", error, &report) }
    }

    private static func checkPythonTools(_ runner: CommandRunner, _ path: String, _ report: inout ExtraSourcesReport) async {
        var installed: [(name: String, version: String, manager: String)] = []
        if let pipx = Privilege.locate("pipx", path: path) {
            do {
                let r = try await runChecked(runner, [pipx, "list", "--json"], timeout: 30)
                installed += parsePipxList(r.output).map { ($0.name, $0.version, "pipx") }
            } catch { record("pipx", error, &report) }
        } else { report.missingTools.append("pipx") }
        if let uv = Privilege.locate("uv", path: path) {
            do {
                let r = try await runChecked(runner, [uv, "tool", "list"], timeout: 30)
                installed += parseUVToolList(r.text).map { ($0.name, $0.version, "uv") }
            } catch { record("uv", error, &report) }
        } else { report.missingTools.append("uv") }
        guard !installed.isEmpty else { return }

        let latest = await pypiLatest(Array(Set(installed.map(\.name))))
        for tool in installed {
            guard let newest = latest[tool.name],
                  VersionCompare.compare(tool.version, newest) == .orderedAscending else { continue }
            report.items.append(OutdatedItem(source: .pythonTools, name: tool.name, installed: tool.version,
                                             latest: newest, manager: tool.manager))
        }
    }

    private static func checkOhMyZsh(_ runner: CommandRunner, _ path: String, _ report: inout ExtraSourcesReport) async {
        let env = ProcessInfo.processInfo.environment["ZSH"]
        let dir = (env?.isEmpty == false) ? env! : NSHomeDirectory() + "/.oh-my-zsh"
        guard FileManager.default.fileExists(atPath: dir + "/.git") else { return }
        guard let git = Privilege.locate("git", path: path) else { report.missingTools.append("git"); return }
        do {
            _ = try await runChecked(runner, [git, "-C", dir, "fetch", "--quiet", "origin"], timeout: 30)
            var upstream: String?
            for ref in ["@{u}", "origin/master", "origin/main"] {
                let r = try await runner.run([git, "-C", dir, "rev-list", "--count", "HEAD..\(ref)"], timeout: 15)
                if r.status == 0, let n = Int(r.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    if n > 0 { upstream = ref }
                    break
                }
            }
            guard let ref = upstream else { return }
            let head = try await runChecked(runner, [git, "-C", dir, "rev-parse", "--short", "HEAD"], timeout: 15)
            let up = try await runChecked(runner, [git, "-C", dir, "rev-parse", "--short", ref], timeout: 15)
            report.items.append(OutdatedItem(
                source: .ohMyZsh, name: "Oh My Zsh",
                installed: head.text.trimmingCharacters(in: .whitespacesAndNewlines),
                latest: up.text.trimmingCharacters(in: .whitespacesAndNewlines)))
        } catch { record("Oh My Zsh", error, &report) }
    }

    // MARK: - PyPI

    private static func pypiLatest(_ names: [String]) async -> [String: String] {
        await withTaskGroup(of: (String, String?).self) { group in
            for name in names {
                group.addTask { (name, await fetchPyPIVersion(name)) }
            }
            var out: [String: String] = [:]
            for await (name, version) in group { if let version { out[name] = version } }
            return out
        }
    }

    private static func fetchPyPIVersion(_ name: String) async -> String? {
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://pypi.org/pypi/\(encoded)/json") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Tazele", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = obj["info"] as? [String: Any],
              let version = info["version"] as? String, !version.isEmpty else { return nil }
        return version
    }

    // MARK: - Ayrıştırıcılar

    /// "1.80.0 (abc 2024-07-25)" → "1.80.0"
    private static func firstToken(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? s
    }

    public static func parseRustupCheck(_ text: String) -> [OutdatedItem] {
        var items: [OutdatedItem] = []
        let clean = text.replacing(/\u{1B}\[[0-9;]*[A-Za-z]/, with: "")
        for raw in clean.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let m = line.firstMatch(of: /^(\S+) - Update available : (.+?) -> (.+)$/) else { continue }
            items.append(OutdatedItem(source: .rustup, name: String(m.1),
                                      installed: firstToken(String(m.2)), latest: firstToken(String(m.3))))
        }
        return items
    }

    public static func parseGemOutdated(_ text: String) -> [OutdatedItem] {
        var items: [OutdatedItem] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let m = line.firstMatch(of: /^(\S+) \(([^<)]+?) < ([^)]+?)\)/) else { continue }
            // Birden çok sürüm kuruluysa ("1.0, 0.9 < 2.0") ilkini al.
            let installed = String(m.2).split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? String(m.2)
            items.append(OutdatedItem(source: .gem, name: String(m.1), installed: installed, latest: String(m.3)))
        }
        return items
    }

    public static func parsePipxList(_ data: Data) -> [(name: String, version: String)] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let venvs = obj["venvs"] as? [String: Any] else { return [] }
        var result: [(name: String, version: String)] = []
        for key in venvs.keys.sorted() {
            guard let venv = venvs[key] as? [String: Any],
                  let meta = venv["metadata"] as? [String: Any],
                  let main = meta["main_package"] as? [String: Any],
                  let version = main["package_version"] as? String, !version.isEmpty else { continue }
            let name = (main["package"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? key
            result.append((name, version))
        }
        return result
    }

    public static func parseUVToolList(_ text: String) -> [(name: String, version: String)] {
        var result: [(name: String, version: String)] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            // Girintili "- executable" satırlarını atla.
            guard let first = raw.first, !first.isWhitespace, first != "-" else { continue }
            let parts = raw.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, parts[1].hasPrefix("v"), parts[1].dropFirst().first?.isNumber == true else { continue }
            result.append((String(parts[0]), String(parts[1].dropFirst())))
        }
        return result
    }
}

private struct ExtraError: Error { let message: String }
