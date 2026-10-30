import Foundation

/// Besleme adresi Info.plist'ten okunamayan (çalışma anında ayarlanan) Sparkle uygulamaları ve
/// Homebrew cask ile kurulmuş Sparkle uygulamaları için yedek yollar.
public enum SparkleFallback {
    /// Homebrew'ün genel cask kaydından ihtiyaç duyulan alanlar.
    public struct CaskEntry: Sendable, Equatable {
        public let token: String
        /// Kurulumdan sonraki .app klasör adları (`target` ile yeniden adlandırma dikkate alınır).
        public let appNames: [String]
        public let version: String
        public let autoUpdates: Bool
        /// En düşük macOS koşulu, ör. ">= 13"; yoksa nil.
        public let depends: String?

        public init(token: String, appNames: [String], version: String, autoUpdates: Bool, depends: String?) {
            self.token = token
            self.appNames = appNames
            self.version = version
            self.autoUpdates = autoUpdates
            self.depends = depends
        }
    }

    public static let caskAPIURL = URL(string: "https://formulae.brew.sh/api/cask.json")!
    /// İndirilen cask listesi bu süre boyunca yeniden indirilmez.
    static let cacheLifetime: TimeInterval = 3600
    /// Ağ yoksa bundan eski olmayan önbellek yine de kullanılır.
    static let staleLimit: TimeInterval = 7 * 24 * 3600

    // MARK: - Kurulu cask'ler

    /// Kurulu cask'leri `brew info --json=v2 --installed --cask` ile okuyup uygulama yolu/adı/bundle id -> cask belirteci eşler.
    /// Anahtar: ".app" olmadan, küçük harfli uygulama adı. Aynı adı iki cask sahipleniyorsa ad belirsizdir, eşlenmez.
    public static func installedCaskTokens(runner: CommandRunner) async -> [String: String] {
        guard let r = try? await runner.run(["brew", "info", "--json=v2", "--installed", "--cask"], timeout: 120),
              !r.timedOut, r.status == 0 else { return [:] }
        return tokenIndex(parseCaskAPI(r.output))
    }

    /// Uygulama adı → cask belirteci; birden fazla cask aynı adı veriyorsa o ad dışarıda kalır.
    static func tokenIndex(_ entries: [CaskEntry]) -> [String: String] {
        var index: [String: String] = [:]
        var ambiguous = Set<String>()
        for entry in entries {
            for key in Set(entry.appNames.map(appKey)) where !key.isEmpty {
                if let existing = index[key], existing != entry.token { ambiguous.insert(key) }
                index[key] = entry.token
            }
        }
        ambiguous.forEach { index[$0] = nil }
        return index
    }

    public static func caskToken(for app: SparkleApp, in index: [String: String]) -> String? {
        if let token = index[appKey(app.name)] { return token }
        let folder = URL(fileURLWithPath: app.path).lastPathComponent
        return folder.isEmpty ? nil : index[appKey(folder)]
    }

    /// "Foo Bar.app" / "Foo Bar" → "foo bar"
    static func appKey(_ name: String) -> String {
        var s = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasSuffix(".app") { s = String(s.dropLast(4)) }
        return s.lowercased()
    }

    // MARK: - Genel cask kaydı

    /// Feed adresi olmayan uygulamalar için: Homebrew'ün genel cask API'si (https://formulae.brew.sh/api/cask.json) ile ad eşleştirip sürümü karşılaştırır.
    /// Yalnızca `feedURL == nil` olan ve App Store'dan gelmeyen uygulamalara bakılır. Ağ hatasında boş liste döner.
    public static func updatesFromCaskIndex(apps: [SparkleApp], cacheDirectory: URL? = nil, now: Date = .now) async -> [OutdatedItem] {
        let candidates = apps.filter { $0.feedURL == nil && !$0.isMacAppStore && !$0.shortVersion.isEmpty }
        guard !candidates.isEmpty else { return [] }
        let directory = cacheDirectory ?? defaultCacheDirectory
        guard let data = await caskAPIData(cacheDirectory: directory, now: now) else { return [] }
        return updates(apps: candidates, entries: parseCaskAPI(data))
    }

    /// Saf eşleştirme: cask'in .app adı uygulamanın klasör adına eşitse (büyük/küçük harf duyarsız) ve cask sürümü
    /// kesin olarak daha yeniyse bildirir. Eşleşme belirsizse uygulama atlanır (yanlış sürüm göstermemek için).
    static func updates(apps: [SparkleApp], entries: [CaskEntry],
                        system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> [OutdatedItem] {
        var byApp: [String: [CaskEntry]] = [:]
        for entry in entries where entry.version.lowercased() != "latest" && !entry.version.isEmpty {
            for key in Set(entry.appNames.map(appKey)) where !key.isEmpty { byApp[key, default: []].append(entry) }
        }
        let osVersion = "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
        return apps.compactMap { app -> OutdatedItem? in
            let folder = URL(fileURLWithPath: app.path).lastPathComponent
            let key = appKey(folder.isEmpty ? app.name : folder)
            guard let matches = byApp[key], let cask = uniqueMatch(matches, appKey: key) else { return nil }
            if let depends = cask.depends, !requirementMet(depends, osVersion: osVersion) { return nil }
            let latest = VersionCompare.normalize(cask.version)
            guard !latest.isEmpty, VersionCompare.compare(app.shortVersion, latest) == .orderedAscending else { return nil }
            return OutdatedItem(source: .sparkle, name: app.name, installed: app.shortVersion, latest: latest, path: app.path)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Tek eşleşme varsa odur. Birden fazlaysa (ör. `ghostty` + `ghostty@tip`, `chatgpt` + `vincelwt-chatgpt`)
    /// yalnızca belirteci Homebrew'ün ad kuralına birebir uyan tek cask kabul edilir; yoksa belirsizdir.
    static func uniqueMatch(_ matches: [CaskEntry], appKey: String) -> CaskEntry? {
        if matches.count == 1 { return matches[0] }
        let exact = matches.filter { $0.token == canonicalToken(appKey) }
        return exact.count == 1 ? exact[0] : nil
    }

    /// "Cloudflare WARP" → "cloudflare-warp" (Homebrew cask adlandırmasının sade hâli).
    static func canonicalToken(_ appName: String) -> String {
        appKey(appName).split(whereSeparator: \.isWhitespace).joined(separator: "-")
    }

    /// Yalnızca ">= X" koşulu denetlenir; anlaşılmayan koşul engel sayılmaz.
    static func requirementMet(_ depends: String, osVersion: String) -> Bool {
        let parts = depends.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == ">=" else { return true }
        let minimum = parts[1].split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        guard !minimum.isEmpty else { return true }
        return VersionCompare.compare(osVersion, minimum) != .orderedAscending
    }

    static var defaultCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tazele", isDirectory: true)
    }

    /// Önbellek bir saatten tazeyse onu, değilse indirileni döndürür; indirme başarısızsa yakın tarihli eski önbelleğe düşer.
    static func caskAPIData(cacheDirectory: URL, now: Date) async -> Data? {
        let file = cacheDirectory.appendingPathComponent("cask.json")
        let modified = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date
        let age = modified.map { now.timeIntervalSince($0) }
        if let age, age < cacheLifetime, let cached = try? Data(contentsOf: file) { return cached }

        if let fresh = await download(caskAPIURL) {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try? fresh.write(to: file, options: .atomic)
            return fresh
        }
        if let age, age < staleLimit { return try? Data(contentsOf: file) }
        return nil
    }

    /// Yalnızca https (her yönlendirme adımı dahil), en fazla 64 MB, sınırlı süre; aksi halde nil.
    static func download(_ url: URL, configuration: URLSessionConfiguration = .ephemeral) async -> Data? {
        guard let (data, _) = try? await BoundedFetch.data(from: url, maxBytes: BoundedFetch.caskIndexLimit,
                                                            requestTimeout: 20, resourceTimeout: 120,
                                                            configuration: configuration),
              !data.isEmpty else { return nil }
        return data
    }

    // MARK: - Ayrıştırma

    /// Cask listesini ayrıştırır: genel API'nin dizisi (`[{...}]`) ya da `brew info --json=v2` nesnesi (`{"casks":[...]}`).
    /// Eksik veya beklenmeyen alanlar hata değildir; belirteci olmayan kayıt atlanır. Bozuk veri → boş liste.
    public static func parseCaskAPI(_ data: Data) -> [CaskEntry] {
        let json = trimmedJSON(data)
        let decoder = JSONDecoder()
        if let list = try? decoder.decode([LenientCask].self, from: json) { return list.compactMap(\.entry) }
        if let root = try? decoder.decode(InstalledRoot.self, from: json) { return root.casks.compactMap(\.entry) }
        return []
    }

    /// brew, JSON'dan önce uyarı satırları basabilir (stderr de aynı boruya gelir); ilk `{`/`[` satırından başlatır.
    static func trimmedJSON(_ data: Data) -> Data {
        guard let first = data.first, first != UInt8(ascii: "{"), first != UInt8(ascii: "[") else { return data }
        var lineStart = data.startIndex
        for i in data.indices {
            if i == lineStart, data[i] == UInt8(ascii: "{") || data[i] == UInt8(ascii: "[") { return Data(data[i...]) }
            if data[i] == UInt8(ascii: "\n") { lineStart = data.index(after: i) }
        }
        return data
    }

    private struct InstalledRoot: Decodable {
        let casks: [LenientCask]
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            casks = (try? c.decode([LenientCask].self, forKey: AnyKey("casks"))) ?? []
        }
    }

    /// Hiçbir zaman hata atmayan kayıt çözücüsü; dosyadaki diğer onlarca alan okunmaz.
    private struct LenientCask: Decodable {
        let entry: CaskEntry?

        init(from decoder: Decoder) throws {
            guard let c = try? decoder.container(keyedBy: AnyKey.self),
                  let token = try? c.decode(String.self, forKey: AnyKey("token")), !token.isEmpty else {
                entry = nil
                return
            }
            let version = (try? c.decode(String.self, forKey: AnyKey("version"))) ?? ""
            let autoUpdates = (try? c.decode(Bool.self, forKey: AnyKey("auto_updates"))) ?? false
            let artifacts = (try? c.decode([LenientArtifact].self, forKey: AnyKey("artifacts"))) ?? []
            var seen = Set<String>()
            let names = artifacts.flatMap(\.appNames).filter { seen.insert($0.lowercased()).inserted }
            let depends = (try? c.decode(LenientDepends.self, forKey: AnyKey("depends_on")))?.macOS
            entry = CaskEntry(token: token, appNames: names, version: version, autoUpdates: autoUpdates, depends: depends)
        }
    }

    /// `{"app": ["Foo.app"]}` veya `{"app": ["Foo.app", {"target": "Bar.app"}], "target": "/Applications/Bar.app"}`.
    private struct LenientArtifact: Decodable {
        let appNames: [String]

        init(from decoder: Decoder) throws {
            guard let c = try? decoder.container(keyedBy: AnyKey.self),
                  let parts = try? c.decode([AppPart].self, forKey: AnyKey("app")) else {
                appNames = []
                return
            }
            // Yeniden adlandırma varsa diskteki ad hedeftir; kaynak adı eşleştirmede kullanılmaz.
            let renamed = parts.compactMap(\.target)
            if !renamed.isEmpty {
                appNames = renamed.map { URL(fileURLWithPath: $0).lastPathComponent }
            } else if let target = try? c.decode(String.self, forKey: AnyKey("target")), !target.isEmpty {
                appNames = [URL(fileURLWithPath: target).lastPathComponent]
            } else {
                appNames = parts.compactMap(\.name).map { URL(fileURLWithPath: $0).lastPathComponent }
            }
        }
    }

    private struct AppPart: Decodable {
        let name: String?
        let target: String?

        init(from decoder: Decoder) throws {
            if let s = try? decoder.singleValueContainer().decode(String.self) {
                name = s
                target = nil
            } else {
                name = nil
                target = (try? decoder.container(keyedBy: AnyKey.self))
                    .flatMap { try? $0.decode(String.self, forKey: AnyKey("target")) }
            }
        }
    }

    /// `"depends_on": {"macos": {">=": ["13"]}}` → ">= 13"
    private struct LenientDepends: Decodable {
        let macOS: String?

        init(from decoder: Decoder) throws {
            let condition = (try? decoder.container(keyedBy: AnyKey.self))
                .flatMap { try? $0.decode([String: [String]].self, forKey: AnyKey("macos")) }
            guard let (op, versions) = condition?.min(by: { $0.key < $1.key }), !versions.isEmpty else {
                macOS = nil
                return
            }
            macOS = "\(op) \(versions.joined(separator: ","))"
        }
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
