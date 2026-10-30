import Foundation

/// Homebrew genel cask kaydından `.pkg` ile kurulan uygulamaları eşleştirmek için gereken alanlar.
public struct PkgCask: Sendable, Equatable {
    public let token: String
    public let version: String
    /// `uninstall` içindeki `pkgutil` kimlikleri (Homebrew bunları desen olarak da kabul eder, ör. `com.foo.*`).
    public let pkgutilIDs: [String]
    /// Kurulumdan sonraki `.app` adları (`target` ile yeniden adlandırma dikkate alınır).
    public let appNames: [String]
    /// `uninstall.quit` içindeki bundle kimlikleri; yalnızca birden fazla eşleşme arasında seçim için ipucu.
    public let bundleIDs: [String]
    public let autoUpdates: Bool
    /// En düşük macOS koşulu, ör. ">= 14"; yoksa nil.
    public let dependsMacOS: String?
    public let homepage: String?

    public init(token: String, version: String, pkgutilIDs: [String] = [], appNames: [String] = [], bundleIDs: [String] = [],
                autoUpdates: Bool = false, dependsMacOS: String? = nil, homepage: String? = nil) {
        self.token = token
        self.version = version
        self.pkgutilIDs = pkgutilIDs
        self.appNames = appNames
        self.bundleIDs = bundleIDs
        self.autoUpdates = autoUpdates
        self.dependsMacOS = dependsMacOS
        self.homepage = homepage
    }
}

/// Üreticinin kendi resmî sürüm kaynağı (yalnızca doğrulanmış uç noktalar).
public enum VendorSource: Sendable, Equatable {
    /// Üreticinin Sparkle appcast'i; uygulama besleme adresini çalışma anında ayarladığı için Info.plist'te yok.
    case sparkleAppcast(URL)
}

/// Besleme adresi okunamayan, çoğunlukla `.pkg` ile kurulmuş uygulamalar (ör. Cloudflare WARP, Tailscale) için güncelleme denetimi.
/// Önce üreticinin resmî kaynağına, o yoksa ya da okunamazsa Homebrew'ün genel cask listesine bakılır.
public enum PkgApps {
    /// Bundle id → üreticinin resmî sürüm kaynağı. Yalnızca düz GET ile okunabildiği doğrulanmış adresler eklenir.
    public static let vendorSources: [String: VendorSource] = [
        // Homebrew'ün `cloudflare-warp` cask'inin livecheck'te kullandığı resmî kararlı (GA) kanal.
        "com.cloudflare.1dot1dot1dot1.macos":
            .sparkleAppcast(URL(string: "https://downloads.cloudflareclient.com/v1/update/sparkle/macos/ga")!),
        // Tailscale'in App Store dışı (standalone) sürümünün kendi ikili dosyasında geçen kararlı kanal.
        "io.tailscale.ipn.macsys":
            .sparkleAppcast(URL(string: "https://pkgs.tailscale.com/stable/appcast.xml")!),
    ]

    /// Feed adresi olmayan, `.pkg` ile kurulmuş olabilecek uygulamalar için Homebrew cask listesiyle (pkgutil kimliği, bundle id, `.app` adı) eşleştirip güncelleme arar.
    public static func updates(apps: [SparkleApp], cacheDirectory: URL? = nil, runner: CommandRunner) async -> [OutdatedItem] {
        await updates(apps: apps, cacheDirectory: cacheDirectory, runner: runner, now: .now,
                      fetchAppcast: { await Sparkle.fetch($0) })
    }

    static func updates(apps: [SparkleApp], cacheDirectory: URL?, runner: CommandRunner, now: Date,
                        fetchAppcast: @escaping @Sendable (URL) async -> [AppcastItem]) async -> [OutdatedItem] {
        let candidates = apps.filter { $0.feedURL == nil && !$0.isMacAppStore && !$0.shortVersion.isEmpty }
        guard !candidates.isEmpty else { return [] }

        // 1) Üreticinin resmî kaynağı. Kaynak okunamazsa (boş liste) cask listesine düşülür.
        var viaVendor: [OutdatedItem] = []
        var remaining: [SparkleApp] = []
        for app in candidates {
            guard case .sparkleAppcast(let url)? = vendorSources[app.bundleID] else { remaining.append(app); continue }
            let items = await fetchAppcast(url)
            if items.isEmpty { remaining.append(app); continue }
            if let item = Sparkle.outdated(app: app, items: items) { viaVendor.append(item) }
        }

        // 2) Homebrew cask listesi: kurulum makbuzundaki paket kimlikleri ve `.app` adı.
        var viaCasks: [OutdatedItem] = []
        if !remaining.isEmpty, let data = await SparkleFallback.caskAPIData(
            cacheDirectory: cacheDirectory ?? SparkleFallback.defaultCacheDirectory, now: now) {
            let casks = parseCasks(data)
            let receipts = await installedPackageIDs(runner: runner)
            let byPath = await receiptAppPaths(receipts: receipts, casks: casks, runner: runner)
            var pkgIDs: [String: [String]] = [:]
            for app in remaining { pkgIDs[app.path] = await packageIDs(for: app, byPath: byPath, runner: runner) }
            viaCasks = updates(apps: remaining, pkgIDs: pkgIDs, casks: casks)
        }
        return (viaVendor + viaCasks).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Saf karşılaştırma: eşleşen cask'in sürümü kurulu sürümden kesin olarak yeniyse bildirir.
    /// `latest` sürümlü ve bu macOS'u desteklemeyen cask'ler atlanır.
    static func updates(apps: [SparkleApp], pkgIDs: [String: [String]], casks: [PkgCask],
                        system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> [OutdatedItem] {
        let osVersion = "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
        return apps.compactMap { app -> OutdatedItem? in
            guard let cask = match(app: app, pkgIDs: pkgIDs[app.path] ?? [], casks: casks) else { return nil }
            guard cask.version.lowercased() != "latest" else { return nil }
            if let depends = cask.dependsMacOS, !SparkleFallback.requirementMet(depends, osVersion: osVersion) { return nil }
            let latest = VersionCompare.normalize(cask.version)
            guard !latest.isEmpty, VersionCompare.compare(app.shortVersion, latest) == .orderedAscending else { return nil }
            return OutdatedItem(source: .sparkle, name: app.name, installed: app.shortVersion, latest: latest,
                                path: app.path, caskToken: nil)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Eşleştirme

    /// Uygulamayı tek bir cask'e bağlar: önce kurulum makbuzunun paket kimliği cask'in `uninstall.pkgutil` listesinde
    /// geçiyorsa, o yoksa cask'in `.app` adı uygulamanın klasör adına eşitse. Birden fazla aday kalırsa yalnızca
    /// belirteci Homebrew'ün ad kuralına birebir uyan, o da yoksa `uninstall.quit` içinde uygulamanın bundle id'sini
    /// taşıyan tek cask seçilir; aksi hâlde nil (yanlış eşleşme, kaçırmaktan kötüdür). Benzer ad tahmini yapılmaz.
    public static func match(app: SparkleApp, pkgIDs: [String], casks: [PkgCask]) -> PkgCask? {
        let ids = Set(pkgIDs.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        if !ids.isEmpty {
            let byReceipt = casks.filter { cask in
                cask.pkgutilIDs.contains { pattern in ids.contains { pkgID($0, matches: pattern) } }
            }
            // Makbuzla aday bulunduysa ad eşleşmesine geçilmez: belirsizlik, ad ile çözülmeye çalışılmaz.
            if !byReceipt.isEmpty { return unique(byReceipt, for: app) }
        }
        let folder = URL(fileURLWithPath: app.path).lastPathComponent
        let key = SparkleFallback.appKey(folder.isEmpty ? app.name : folder)
        guard !key.isEmpty else { return nil }
        let byName = casks.filter { cask in cask.appNames.contains { SparkleFallback.appKey($0) == key } }
        return byName.isEmpty ? nil : unique(byName, for: app)
    }

    static func unique(_ matches: [PkgCask], for app: SparkleApp) -> PkgCask? {
        if matches.count == 1 { return matches[0] }
        let folder = URL(fileURLWithPath: app.path).lastPathComponent
        let names = Set([app.name, folder].map(SparkleFallback.canonicalToken).filter { !$0.isEmpty })
        let exact = matches.filter { names.contains($0.token) }
        if exact.count == 1 { return exact[0] }
        guard !app.bundleID.isEmpty else { return nil }
        let byBundle = matches.filter { $0.bundleIDs.contains(app.bundleID) }
        return byBundle.count == 1 ? byBundle[0] : nil
    }

    /// Paket kimliği desene uyar mı? Düz kimlik birebir (büyük/küçük harf duyarsız) karşılaştırılır.
    /// `*` içeren desenlerde `*` herhangi bir dizi demektir; ilk `*`'tan önceki kısım en az iki bileşenli olmalı
    /// ve noktayla bitmemeli (ör. `org.r-project*`, `com.adobe.acrobat.DC.*`); `com.microsoft.*` gibi üretici
    /// genelindeki desenler ve diğer düzenli ifade biçimleri (`(`, `|`, boşluk...) güvenli değil, atlanır.
    static func pkgID(_ id: String, matches rawPattern: String) -> Bool {
        var pattern = rawPattern.trimmingCharacters(in: .whitespaces)
        if pattern.count >= 2, let q = pattern.first, q == "'" || q == "\"", pattern.last == q {
            pattern = String(pattern.dropFirst().dropLast())
        }
        guard !pattern.isEmpty, !id.isEmpty else { return false }
        let id = id.lowercased(), lowered = pattern.lowercased()
        guard lowered.contains("*") else { return id == lowered }
        guard !lowered.contains(where: { "()|[]{}^$+?\\ ".contains($0) }) else { return false }
        let prefix = lowered.prefix { $0 != "*" }
        let components = prefix.split(separator: ".", omittingEmptySubsequences: true)
        guard components.count >= 3 || (components.count == 2 && !prefix.hasSuffix(".")) else { return false }
        return globMatch(Array(id), Array(lowered))
    }

    /// Yalnızca `*` destekleyen basit eşleştirme (tüm dizgi).
    private static func globMatch(_ s: [Character], _ p: [Character]) -> Bool {
        var i = 0, j = 0, star = -1, mark = 0
        while i < s.count {
            if j < p.count, p[j] != "*", p[j] == s[i] { i += 1; j += 1 }
            else if j < p.count, p[j] == "*" { star = j; mark = i; j += 1 }
            else if star >= 0 { j = star + 1; mark += 1; i = mark }
            else { return false }
        }
        while j < p.count, p[j] == "*" { j += 1 }
        return j == p.count
    }

    // MARK: - Kurulum makbuzları (pkgutil, salt okunur)

    /// `pkgutil --file-info <yol>` çıktısındaki paket kimlikleri (`pkgid:` satırları), sırası korunarak tekilleştirilir.
    public static func parsePkgutilFileInfo(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let s = line.trimmingCharacters(in: .whitespaces)
            for key in ["pkgid:", "package-id:"] where s.hasPrefix(key) {
                let id = s.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
                return id.isEmpty ? nil : id
            }
            return nil
        }
        .filter { seen.insert($0).inserted }
    }

    /// `pkgutil --pkgs` çıktısı: her satırda bir paket kimliği.
    static func parsePkgList(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains(" ") })
    }

    static func installedPackageIDs(runner: CommandRunner) async -> Set<String> {
        guard let r = try? await runner.run(["/usr/sbin/pkgutil", "--pkgs"], timeout: 30),
              !r.timedOut, r.status == 0 else { return [] }
        return parsePkgList(r.text)
    }

    /// Makbuz → kurduğu `.app` yolları. Yalnızca bir cask'in `uninstall.pkgutil` listesinde geçen makbuzlara bakılır
    /// (genelde birkaç tane). `pkgutil --file-info` uygulama kendini güncelledikten sonra çoğu zaman sonuç vermez
    /// (WARP ve Tailscale'de böyle); makbuzun kurulum yeri ve üst düzey klasörleri ise kalır.
    static func receiptAppPaths(receipts: Set<String>, casks: [PkgCask], runner: CommandRunner) async -> [String: [String]] {
        let patterns = Set(casks.flatMap(\.pkgutilIDs))
        let exact = Set(patterns.filter { !$0.contains("*") }.map { $0.lowercased() })
        let globs = patterns.filter { $0.contains("*") }
        let relevant = receipts.filter { id in exact.contains(id.lowercased()) || globs.contains { pkgID(id, matches: $0) } }
        var byPath: [String: [String]] = [:]
        for id in relevant.sorted() {
            guard let r = try? await runner.run(["/usr/sbin/pkgutil", "--pkg-info-plist", id], timeout: 15),
                  !r.timedOut, r.status == 0, let info = parsePkgInfo(r.output) else { continue }
            var dirs: [String] = []
            if !info.location.lowercased().hasSuffix(".app"),
               let f = try? await runner.run(["/usr/sbin/pkgutil", "--only-dirs", "--files", id], timeout: 30),
               !f.timedOut, f.status == 0 {
                dirs = f.text.split(whereSeparator: \.isNewline).map(String.init)
            }
            for path in appPaths(volume: info.volume, location: info.location, dirs: dirs) {
                byPath[path, default: []].append(id)
            }
        }
        return byPath
    }

    /// `pkgutil --pkg-info-plist` çıktısından birim ve kurulum yeri.
    static func parsePkgInfo(_ data: Data) -> (volume: String, location: String)? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return ((plist["volume"] as? String) ?? "/", (plist["install-location"] as? String) ?? "")
    }

    /// Makbuzun kurduğu `.app` yolları: kurulum yeri bir `.app` ise kendisi, değilse kurulum yerindeki üst düzey
    /// `.app` klasörleri (`--only-dirs --files` çıktısında `/` içermeyen satırlar).
    static func appPaths(volume: String, location: String, dirs: [String]) -> [String] {
        func join(_ parts: [String]) -> String {
            "/" + parts.flatMap { $0.split(separator: "/") }.joined(separator: "/")
        }
        if location.lowercased().hasSuffix(".app") { return [join([volume, location])] }
        return dirs.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.contains("/") && $0.lowercased().hasSuffix(".app") }
            .map { join([volume, location, $0]) }
    }

    /// Uygulamanın kurulum makbuzları: `pkgutil --file-info` (dosya dizini kayıtlıysa) ve makbuz yollarından bulunanlar.
    static func packageIDs(for app: SparkleApp, byPath: [String: [String]], runner: CommandRunner) async -> [String] {
        var ids: [String] = []
        if let r = try? await runner.run(["/usr/sbin/pkgutil", "--file-info", app.path], timeout: 15),
           !r.timedOut, r.status == 0 {
            ids = parsePkgutilFileInfo(r.text)
        }
        let path = URL(fileURLWithPath: app.path).standardizedFileURL.path
        for id in byPath[path] ?? [] where !ids.contains(id) { ids.append(id) }
        return ids
    }

    // MARK: - Cask listesi ayrıştırma

    /// Genel cask API'si (`[{...}]`) ya da `brew info --json=v2` (`{"casks":[...]}`). Hiç hata atmaz; bozuk veri → boş liste.
    static func parseCasks(_ data: Data) -> [PkgCask] {
        let json = SparkleFallback.trimmedJSON(data)
        let decoder = JSONDecoder()
        if let list = try? decoder.decode([LenientCask].self, from: json) { return list.compactMap(\.cask) }
        if let root = try? decoder.decode(Root.self, from: json) { return root.casks.compactMap(\.cask) }
        return []
    }

    private struct Root: Decodable {
        let casks: [LenientCask]
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            casks = (try? c.decode([LenientCask].self, forKey: Key("casks"))) ?? []
        }
    }

    private struct LenientCask: Decodable {
        let cask: PkgCask?

        init(from decoder: Decoder) throws {
            guard let c = try? decoder.container(keyedBy: Key.self),
                  let token = try? c.decode(String.self, forKey: Key("token")), !token.isEmpty else {
                cask = nil
                return
            }
            let version = (try? c.decode(String.self, forKey: Key("version"))) ?? ""
            let artifacts = (try? c.decode([Artifact].self, forKey: Key("artifacts"))) ?? []
            func unique(_ list: [String]) -> [String] {
                var seen = Set<String>()
                return list.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            }
            let depends = (try? c.decode(Depends.self, forKey: Key("depends_on")))?.macOS
            cask = PkgCask(token: token, version: version,
                           pkgutilIDs: unique(artifacts.flatMap(\.pkgutil)),
                           appNames: unique(artifacts.flatMap(\.appNames)),
                           bundleIDs: unique(artifacts.flatMap(\.quit)),
                           autoUpdates: (try? c.decode(Bool.self, forKey: Key("auto_updates"))) ?? false,
                           dependsMacOS: depends,
                           homepage: try? c.decode(String.self, forKey: Key("homepage")))
        }
    }

    /// Tek bir artifact: `{"app": [...]}`, `{"uninstall": [{"pkgutil": ..., "quit": ...}]}` ya da ilgisiz bir şey.
    private struct Artifact: Decodable {
        var appNames: [String] = []
        var pkgutil: [String] = []
        var quit: [String] = []

        init(from decoder: Decoder) throws {
            guard let c = try? decoder.container(keyedBy: Key.self) else { return }
            if let parts = try? c.decode([AppPart].self, forKey: Key("app")) {
                // Yeniden adlandırma varsa diskteki ad hedeftir.
                let renamed = parts.compactMap(\.target)
                if !renamed.isEmpty {
                    appNames = renamed.map { URL(fileURLWithPath: $0).lastPathComponent }
                } else if let target = try? c.decode(String.self, forKey: Key("target")), !target.isEmpty {
                    appNames = [URL(fileURLWithPath: target).lastPathComponent]
                } else {
                    appNames = parts.compactMap(\.name).map { URL(fileURLWithPath: $0).lastPathComponent }
                }
            }
            let directives = (try? c.decode([Directive].self, forKey: Key("uninstall"))) ?? []
            pkgutil = directives.flatMap(\.pkgutil)
            quit = directives.flatMap(\.quit)
        }
    }

    /// `uninstall` içindeki bir yönerge; `pkgutil` ve `quit` tek dizgi ya da dizgi listesi olabilir.
    private struct Directive: Decodable {
        let pkgutil: [String]
        let quit: [String]

        init(from decoder: Decoder) throws {
            let c = try? decoder.container(keyedBy: Key.self)
            func strings(_ key: String) -> [String] {
                guard let c else { return [] }
                if let s = try? c.decode(String.self, forKey: Key(key)) { return [s] }
                return (try? c.decode([Lenient].self, forKey: Key(key)))?.compactMap(\.string) ?? []
            }
            pkgutil = strings("pkgutil")
            quit = strings("quit")
        }
    }

    private struct Lenient: Decodable {
        let string: String?
        init(from decoder: Decoder) throws { string = try? decoder.singleValueContainer().decode(String.self) }
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
                target = (try? decoder.container(keyedBy: Key.self)).flatMap { try? $0.decode(String.self, forKey: Key("target")) }
            }
        }
    }

    /// `"depends_on": {"macos": {">=": ["14"]}}` → ">= 14"
    private struct Depends: Decodable {
        let macOS: String?
        init(from decoder: Decoder) throws {
            let condition = (try? decoder.container(keyedBy: Key.self))
                .flatMap { try? $0.decode([String: [String]].self, forKey: Key("macos")) }
            guard let (op, versions) = condition?.min(by: { $0.key < $1.key }), !versions.isEmpty else {
                macOS = nil
                return
            }
            macOS = "\(op) \(versions.joined(separator: ","))"
        }
    }

    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
