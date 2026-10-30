import AppKit
import CryptoKit
import Foundation
import Security

public enum SparkleInstallError: Error, LocalizedError, Equatable {
    case notSupported
    case insecureURL
    case downloadFailed(Int)
    case sizeMismatch
    case tooLarge
    case signatureInvalid
    case extractFailed
    case appNotFound
    case bundleMismatch
    case notNewer
    case codeSignatureInvalid
    case teamMismatch
    case keyMismatch
    case appStillRunning
    case swapFailed
    case volumeAccessDenied
    case cancelled
    /// Arşiv, imza doğrulamasından sonra (açılmadan önce) değişti.
    case archiveChanged
    /// Arşiv dışarıya yazan yol, dışarıyı gösteren bağ, özel dosya ya da aşırı boyut içeriyor.
    case unsafeArchive
    /// Kurulu uygulama taramadan / doğrulamadan sonra değişti (ör. kendi kendini güncelledi).
    case installedChanged

    public var errorDescription: String? {
        switch self {
        case .notSupported: String(localized: "Bu uygulama Tazele'den kurulamaz", bundle: .main)
        case .insecureURL: String(localized: "İndirme adresi güvenli değil (https değil)", bundle: .main)
        case .downloadFailed(let status): String(localized: "İndirme başarısız (HTTP \(status))", bundle: .main)
        case .sizeMismatch: String(localized: "İndirilen dosyanın boyutu beklenenle uyuşmuyor", bundle: .main)
        case .tooLarge: String(localized: "İndirilen dosya çok büyük", bundle: .main)
        case .signatureInvalid: String(localized: "EdDSA imzası doğrulanamadı; dosya silindi", bundle: .main)
        case .extractFailed: String(localized: "Arşiv açılamadı", bundle: .main)
        case .appNotFound: String(localized: "Arşivde beklenen uygulama bulunamadı", bundle: .main)
        case .bundleMismatch: String(localized: "Yeni sürümün paket kimliği kurulu uygulamayla uyuşmuyor", bundle: .main)
        case .notNewer: String(localized: "İndirilen sürüm kurulu sürümden yeni değil", bundle: .main)
        case .codeSignatureInvalid: String(localized: "Yeni sürümün kod imzası geçersiz", bundle: .main)
        case .teamMismatch: String(localized: "Yeni sürüm başka bir geliştirici ekibince imzalanmış", bundle: .main)
        case .keyMismatch: String(localized: "Yeni sürümün güncelleme anahtarı kurulu uygulamayla uyuşmuyor", bundle: .main)
        case .appStillRunning: String(localized: "Uygulama kapanmadı; kaydedilmemiş iş olabilir. Kapatıp yeniden dene.", bundle: .main)
        case .swapFailed: String(localized: "Uygulama değiştirilemedi; eski sürüm yerinde bırakıldı", bundle: .main)
        case .volumeAccessDenied:
            String(localized: "Disk görüntüsü okunamadı; Sistem Ayarları > Gizlilik ve Güvenlik > Dosyalar ve Klasörler'de Tazele'ye çıkarılabilir birimler izni ver", bundle: .main)
        case .cancelled: String(localized: "Kurulum iptal edildi", bundle: .main)
        case .archiveChanged: String(localized: "Arşiv imza doğrulamasından sonra değişti; kurulum durduruldu", bundle: .main)
        case .unsafeArchive: String(localized: "Arşiv güvenli değil (dışarıya yazan yol, bağ, özel dosya ya da aşırı boyut)", bundle: .main)
        case .installedChanged: String(localized: "Kurulu uygulama taramadan sonra değişti; yeniden tarayıp dene", bundle: .main)
        }
    }
}

/// Sparkle uygulamasını Sparkle'ın kendi güvenlik modeliyle kurar; üçüncü taraf ikili kullanmaz:
/// https indirme → arşiv baytlarında Ed25519 imzası (`SUPublicEDKey`) → arşivi açma →
/// paket kimliği, kod imzası, ekip kimliği ve sürüm denetimi → uygulamayı kibarca kapatma →
/// yedekli değiştirme (hata olursa geri yükleme) → yeniden açma.
///
/// Kullanıcının yazabildiği uygulamalar root istemeden değiştirilir. Kullanıcının yazamadığı (ör. .pkg ile
/// kurulmuş, root'a ait) uygulamalar yalnızca doğrudan /Applications içindeyse ve ekip kimliğiyle
/// imzalıysa kurulabilir: tüm doğrulama yine kullanıcı yetkisiyle yapılır, izin penceresi ancak her şey
/// geçtikten sonra açılır ve yalnızca son değiştirme adımı root olarak çalışır (bkz. RootSwap.swift).
public enum SparkleInstaller {
    /// İndirme üst sınırı (2 GB).
    static let maxDownloadBytes: Int64 = 2 * 1024 * 1024 * 1024
    /// Uygulamanın kapanması için beklenen en uzun süre.
    static let quitTimeout: Duration = .seconds(15)

    // MARK: - Kurulabilirlik

    /// Neden kurulamadığı (testler ve tanılama için).
    enum Rejection: Equatable, Sendable {
        case notSparkle, noDownload, insecureURL, noSignature, badKey, unsupportedArchive, badBundleID
        case noPath, protectedLocation, missing, symlink, macAppStore, notWritable
        /// Yazılamayan (yönetici izni gerekecek) uygulamanın ekip kimliği yok (ad-hoc / imzasız):
        /// root yolunda güven çıpası ekip kimliğidir, bu yüzden kurulmaz.
        case unsignedRootApp
    }

    /// Dosya sistemi denetimleri; testlerde yazılamaz konum taklit edilebilsin diye ayrı.
    struct FileProbe: Sendable {
        var exists: @Sendable (String) -> Bool
        var isSymlink: @Sendable (String) -> Bool
        var isWritable: @Sendable (String) -> Bool
        /// Kurulu uygulamanın ekip kimliği (imza bilgisinden, doğrulama yapmadan); yoksa nil.
        var teamIdentifier: @Sendable (String) -> String? = { SparkleInstaller.signingTeam(atPath: $0) }
        /// Sembolik bağları çözülmüş gerçek yol; yoksa nil.
        var realPath: @Sendable (String) -> String? = { RootSwap.realPath($0) }
        /// Yönetici izniyle kurulumun kabul edildiği tek klasör (testler sahte bir klasör verir).
        var applicationsDirectory = RootSwap.applicationsDirectory

        static let live = FileProbe(
            exists: { FileManager.default.fileExists(atPath: $0) },
            isSymlink: { (try? FileManager.default.attributesOfItem(atPath: $0)[.type] as? FileAttributeType) == .typeSymbolicLink },
            isWritable: { FileManager.default.isWritableFile(atPath: $0) })
    }

    /// Bu öğe Tazele'den kurulabilir mi? (EdDSA imzalı, https, desteklenen arşiv; yazılabilir konum ya da
    /// ekip kimliğiyle imzalı, doğrudan /Applications içindeki uygulama.)
    public static func canInstall(_ item: OutdatedItem) -> Bool { rejection(for: item) == nil }

    /// Kurulumu yönetici izni isteyecek mi? (Kurulabilir ve kullanıcı konumu yazamıyor.)
    public static func requiresAdministrator(_ item: OutdatedItem) -> Bool { requiresAdministrator(item, probe: .live) }

    static func requiresAdministrator(_ item: OutdatedItem, probe: FileProbe,
                                      ownBundleID: String? = Bundle.main.bundleIdentifier) -> Bool {
        guard rejection(for: item, probe: probe, ownBundleID: ownBundleID) == nil,
              let path = item.path, let app = appLocation(path) else { return false }
        return !isUserWritable(app, probe: probe)
    }

    static func isUserWritable(_ app: URL, probe: FileProbe) -> Bool {
        probe.isWritable(app.deletingLastPathComponent().path) && probe.isWritable(app.path)
    }

    static func rejection(for item: OutdatedItem, probe: FileProbe = .live,
                          ownBundleID: String? = Bundle.main.bundleIdentifier) -> Rejection? {
        guard item.source == .sparkle else { return .notSparkle }
        guard let d = item.download else { return .noDownload }
        guard isSecure(d.url) else { return .insecureURL }
        // Yalnızca EdDSA: eski DSA imzalı uygulamalar kendi güncelleyicileriyle açılır.
        guard let sig = d.edSignature, signatureData(sig) != nil else { return .noSignature }
        guard let key = d.publicEDKey, publicKey(key) != nil else { return .badKey }
        guard archiveKind(url: d.url, type: d.type, installationType: d.installationType) != nil else { return .unsupportedArchive }
        // Tazele kendini bu yolla güncellemez (kurulum sırasında kendini kapatırdı).
        guard !d.bundleID.isEmpty, d.bundleID != ownBundleID else { return .badBundleID }
        guard let path = item.path else { return .noPath }
        guard let app = appLocation(path) else { return .protectedLocation }
        guard probe.exists(app.path) else { return .missing }
        guard !probe.isSymlink(app.path) else { return .symlink }
        guard !probe.exists(app.appendingPathComponent("Contents/_MASReceipt").path) else { return .macAppStore }
        if isUserWritable(app, probe: probe) { return nil }
        return rootRejection(path: path, probe: probe)
    }

    /// Yazılamayan uygulama için yönetici yolu uygun mu? Yalnızca tam olarak "/Applications/<ad>.app"
    /// (iç içe değil, başka yerde değil, sembolik bağ değil) ve kurulu uygulamanın ekip kimliği varsa.
    static func rootRejection(path: String, probe: FileProbe) -> Rejection? {
        let apps = probe.applicationsDirectory
        guard !RootSwap.hasControlCharacters(path), RootSwap.isInstalledPathShape(path, applications: apps)
        else { return .notWritable }
        guard !probe.isSymlink(apps), probe.realPath(apps) == apps, probe.realPath(path) == path else { return .notWritable }
        guard let team = probe.teamIdentifier(path), RootSwap.isTeamID(team) else { return .unsignedRootApp }
        return nil
    }

    /// İmza bilgisindeki ekip kimliği (Security; kod doğrulanmaz, yalnızca okunur). Ad-hoc / imzasızsa nil.
    static func signingTeam(atPath path: String) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code
        else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    static func isSecure(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host(), !host.isEmpty else { return false }
        return true
    }

    /// Mutlak, `.app` ile biten ve sistem konumunda olmayan yol; aksi halde nil.
    static func appLocation(_ path: String) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.pathExtension.lowercased() == "app" else { return nil }
        let protected = ["/System/", "/Library/", "/usr/", "/bin/", "/sbin/"]
        for candidate in [url.path, url.resolvingSymlinksInPath().path] {
            if protected.contains(where: { candidate.hasPrefix($0) }) { return nil }
        }
        return url
    }

    // MARK: - Arşiv türü

    enum ArchiveKind: Equatable, Sendable { case zip, dmg, tar }

    /// Desteklenen arşiv türü; .pkg ve kurulum paketi türündeki ekler (installationType ≠ application) desteklenmez.
    static func archiveKind(url: URL, type: String?, installationType: String?) -> ArchiveKind? {
        if let t = installationType?.lowercased(), t != "application" { return nil }
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".pkg") || name.hasSuffix(".mpkg") { return nil }
        if name.hasSuffix(".zip") { return .zip }
        if name.hasSuffix(".dmg") { return .dmg }
        let tarSuffixes = [".tar", ".tgz", ".tbz", ".tbz2", ".txz"]
        if tarSuffixes.contains(where: { name.hasSuffix($0) }) || name.contains(".tar.") { return .tar }
        // Uzantısız adreslerde (ör. /download?id=1) MIME türüne bakılır.
        guard !name.contains(".") || url.pathExtension.isEmpty else { return nil }
        switch type?.lowercased() {
        case "application/zip", "application/x-zip-compressed": return .zip
        case "application/x-apple-diskimage": return .dmg
        case "application/x-tar": return .tar
        default: return nil
        }
    }

    // MARK: - EdDSA (Ed25519)

    static func base64(_ s: String) -> Data? {
        Data(base64Encoded: s.filter { !$0.isWhitespace })
    }

    static func publicKey(_ base64Key: String) -> Curve25519.Signing.PublicKey? {
        guard let raw = base64(base64Key), raw.count == 32 else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }

    static func signatureData(_ base64Signature: String) -> Data? {
        guard let raw = base64(base64Signature), raw.count == 64 else { return nil }
        return raw
    }

    /// Sparkle arşivin ham baytlarını imzalar; anahtar ve imza base64'tür.
    static func verifyEdSignature(of data: Data, signature: String, publicKey key: String) -> Bool {
        guard let k = publicKey(key), let sig = signatureData(signature) else { return false }
        return k.isValidSignature(sig, for: data)
    }

    /// Dosya için doğrulama `ArchiveGuard.verify` ile yapılır: imza ve SHA-256 aynı eşlenmiş baytlar üzerinde
    /// hesaplanır, böylece açılacak dosya doğrulanan baytlara bağlanabilir (bkz. ArchiveSafety.swift).

    // MARK: - Sürüm ve imza bilgisi

    /// Aday sürüm kurulu olandan kesinlikle yeni mi? (CFBundleVersion)
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        guard !candidate.isEmpty, !installed.isEmpty else { return false }
        return VersionCompare.compare(installed, candidate) == .orderedAscending
    }

    /// `codesign -dv` çıktısından ekip kimliği; ad-hoc / imzasız ise nil.
    static func teamIdentifier(fromCodesignOutput text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("TeamIdentifier=") {
            let value = line.dropFirst("TeamIdentifier=".count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty || value == "not set" ? nil : value
        }
        return nil
    }

    // MARK: - Kurulum

    /// Dış dünyaya dokunan adımlar; testler ağsız ve gerçek uygulamasız çalışsın diye değiştirilebilir.
    struct Environment: Sendable {
        /// Arşivi verilen boş klasöre indirir, dosyanın yolunu döndürür.
        var fetch: @Sendable (SparkleDownload, URL) async throws -> URL
        var isRunning: @Sendable (String) async -> Bool
        /// Kibarca kapatmayı ister; süre içinde kapandıysa true. Asla zorla öldürmez.
        var terminate: @Sendable (String, Duration) async -> Bool
        var relaunch: @Sendable (URL) async -> Bool
        /// Uygulamayla aynı birimde geçici çalışma klasörü (taşıma atomik olsun diye).
        var makeWorkDirectory: @Sendable (URL) throws -> URL
        /// Uygulamanın ekip kimliği (`codesign -dv`); ad-hoc / imzasızsa nil.
        var codeTeam: @Sendable (URL) async -> String? = { await SparkleInstaller.team(of: $0) }
        /// Yönetici yolu için: kod imzası Apple köklü ve verilen ekibe ait mi (izin penceresinden önce).
        var verifyTeamAnchor: @Sendable (URL, String) async -> Bool = { await SparkleInstaller.verifyAnchoredTeam($0, team: $1) }
        /// Yönetici yolu için: doğrulanan yeni paketin CDHash'i (root kopyası buna bağlanır).
        var codeHash: @Sendable (URL) async -> String? = { await SparkleInstaller.cdhash(of: $0) }
        /// Yönetici izniyle son değiştirme adımı (`PrivilegedRunner.runSwap`).
        var privilegedSwap: @Sendable (RootSwap.Request, @escaping @Sendable (String) -> Void) async throws -> CommandResult = {
            request, onLine in try await PrivilegedRunner.runSwap(request, runner: CommandRunner(), onLine: onLine)
        }

        static let live = Environment(
            fetch: { download, dir in try await Downloader.fetch(download, into: dir) },
            isRunning: { id in await MainActor.run { !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty } },
            terminate: { id, timeout in await terminateLive(id, timeout: timeout) },
            relaunch: { url in await relaunchLive(url) },
            makeWorkDirectory: { app in
                try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
            })
    }

    public static func install(_ item: OutdatedItem, onLine: @escaping @Sendable (String) -> Void) async throws {
        try await install(item, onLine: onLine, environment: .live)
    }

    static func install(_ item: OutdatedItem, onLine: @escaping @Sendable (String) -> Void, environment env: Environment,
                        probe: FileProbe = .live) async throws {
        do {
            try await perform(item, onLine: onLine, env: env, probe: probe)
        } catch is CancellationError {
            onLine(String(localized: "Kurulum iptal edildi", bundle: .main))
            throw SparkleInstallError.cancelled
        }
    }

    private static func perform(_ item: OutdatedItem, onLine: @escaping @Sendable (String) -> Void, env: Environment,
                                probe: FileProbe) async throws {
        let fm = FileManager.default
        guard rejection(for: item, probe: probe) == nil, let d = item.download, let sig = d.edSignature, let path = item.path,
              let appURL = appLocation(path),
              let kind = archiveKind(url: d.url, type: d.type, installationType: d.installationType)
        else { throw SparkleInstallError.notSupported }

        // Doğrulama anahtarı, öğedeki kopyaya değil şu an kurulu uygulamaya dayanır.
        guard let installedInfo = bundleInfo(appURL),
              installedInfo["CFBundleIdentifier"] as? String == d.bundleID else { throw SparkleInstallError.bundleMismatch }
        guard let installedKey = (installedInfo["SUPublicEDKey"] as? String)?.filter({ !$0.isWhitespace }),
              let itemKey = d.publicEDKey?.filter({ !$0.isWhitespace }), installedKey == itemKey
        else { throw SparkleInstallError.keyMismatch }
        let installedVersion = installedInfo["CFBundleVersion"] as? String ?? ""
        let installedShort = installedInfo["CFBundleShortVersionString"] as? String ?? ""
        // Taramada görülen sürüm hâlâ kurulu mu? (Uygulama bu arada kendini güncellediyse eski bilgiyle kurulmaz.)
        guard VersionCompare.compare(item.installed, installedShort) == .orderedSame else { throw SparkleInstallError.installedChanged }
        let appName = appURL.deletingPathExtension().lastPathComponent
        // Yönetici yolu mu? (Kurulabilirlik zaten denetlendi: yazılamıyorsa doğrudan /Applications'ta ve ekip imzalı.)
        let administrator = !isUserWritable(appURL, probe: probe)

        let work = try env.makeWorkDirectory(appURL)
        var keepWork = false
        defer { if !keepWork { try? fm.removeItem(at: work) } }

        // a) İndirme
        try Task.checkCancellation()
        onLine(String(localized: "İndiriliyor: \(appName)", bundle: .main))
        let downloadDir = work.appendingPathComponent("download", isDirectory: true)
        try fm.createDirectory(at: downloadDir, withIntermediateDirectories: true)
        let archive = try await env.fetch(d, downloadDir)
        let size = ((try? fm.attributesOfItem(atPath: archive.path)[.size]) as? NSNumber)?.int64Value ?? -1
        guard size > 0, size <= maxDownloadBytes else { try? fm.removeItem(at: archive); throw SparkleInstallError.tooLarge }
        if let expected = d.length, expected != size { try? fm.removeItem(at: archive); throw SparkleInstallError.sizeMismatch }
        // Çalışma klasörü yalnızca sahibine açık (0700), arşiv salt okunur (0400): doğrulamadan önce.
        try ArchiveGuard.restrict(workDirectory: work, archive: archive)

        // b) EdDSA imzası; aynı baytların SHA-256'sı ve dosya kimliği açmadan hemen önce yeniden denetlenir.
        try Task.checkCancellation()
        onLine(String(localized: "EdDSA imzası doğrulanıyor", bundle: .main))
        guard let fingerprint = ArchiveGuard.verify(file: archive, signature: sig, publicKey: installedKey) else {
            try? fm.removeItem(at: archive)
            throw SparkleInstallError.signatureInvalid
        }
        onLine(String(localized: "İmza geçerli", bundle: .main))

        // c) Arşivi açma
        try Task.checkCancellation()
        onLine(String(localized: "Arşiv açılıyor", bundle: .main))
        let extractDir = work.appendingPathComponent("extracted", isDirectory: true)
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        let newApp = try await extract(archive, kind: kind, fingerprint: fingerprint, appName: appName, into: extractDir, work: work)
        try? fm.removeItem(at: archive)

        // d) Yeni paketin denetimi
        try Task.checkCancellation()
        onLine(String(localized: "Yeni sürüm denetleniyor (paket kimliği, kod imzası, ekip)", bundle: .main))
        guard let newInfo = bundleInfo(newApp), newInfo["CFBundleIdentifier"] as? String == d.bundleID
        else { throw SparkleInstallError.bundleMismatch }
        let newVersion = newInfo["CFBundleVersion"] as? String ?? ""
        guard isNewer(newVersion, than: installedVersion) else { throw SparkleInstallError.notNewer }
        guard try await verifyCodeSignature(newApp) else { throw SparkleInstallError.codeSignatureInvalid }
        let installedTeam = await env.codeTeam(appURL)
        if let installedTeam {
            guard await env.codeTeam(newApp) == installedTeam else { throw SparkleInstallError.teamMismatch }
            if administrator {
                // Root yolunda güven çıpası ekip kimliğidir: kendinden imzalı sertifikayla taklit edilmesin diye
                // imza zinciri Apple köküne bağlanmalı. Kötü paket izin penceresi hiç açılmadan reddedilir.
                guard RootSwap.isTeamID(installedTeam), await env.verifyTeamAnchor(newApp, installedTeam)
                else { throw SparkleInstallError.codeSignatureInvalid }
            }
        } else if administrator {
            throw SparkleInstallError.notSupported
        } else {
            // Kurulu uygulama ad-hoc / imzasızsa güven yalnızca EdDSA anahtarına dayanır: anahtar değişmemeli.
            let newKey = (newInfo["SUPublicEDKey"] as? String)?.filter { !$0.isWhitespace }
            guard newKey == installedKey else { throw SparkleInstallError.keyMismatch }
        }
        // Doğrulanan paket CDHash ile kaydedilir: yönetici yolunda root kopyası, kullanıcı yolunda yerleştirilen
        // paket buna bağlanır (doğrulamadan sonra başka bir paket konursa kurulmaz).
        guard let verifiedHash = await env.codeHash(newApp), RootSwap.isCDHash(verifiedHash)
        else { throw SparkleInstallError.codeSignatureInvalid }

        // e) Çalışıyorsa kibarca kapatma
        try Task.checkCancellation()
        let wasRunning = await env.isRunning(d.bundleID)
        if wasRunning {
            onLine(String(localized: "Kapatılıyor: \(appName)", bundle: .main))
            guard await env.terminate(d.bundleID, quitTimeout) else { throw SparkleInstallError.appStillRunning }
        }
        // Bu noktadan sonra iptal edilmez: değiştirme kısa ve geri alınabilir olmalı.

        // Kurulu uygulama doğrulamanın başından beri değişmedi mi (kimlik ve iki sürüm değeri)?
        func requireInstalledUnchanged() async throws {
            guard isUnchanged(appURL, bundleID: d.bundleID, version: installedVersion, shortVersion: installedShort) else {
                if wasRunning { _ = await env.relaunch(appURL) }
                throw SparkleInstallError.installedChanged
            }
        }

        if administrator, let installedTeam {
            // Yönetici yolu: izin penceresi ancak şimdi, tüm doğrulamalardan sonra açılır. İptal, root betiği
            // kritik bölüme (yedek + yerleştirme) girene kadar işler; o bölüm yarıda kesilmez.
            // Kurulu yol, kurulabilirlik denetiminin tam olarak onayladığı ham yoldur (standartlaştırılmaz).
            // Gözlenen kurulu sürüm root betiğine de geçer: değiştirmeden hemen önce root olarak yeniden denetlenir.
            try await requireInstalledUnchanged()
            try await swapAsAdministrator(
                RootSwap.Request(installed: URL(fileURLWithPath: path), staged: newApp, workDirectory: work, bundleID: d.bundleID,
                                 version: newVersion, team: installedTeam, cdhash: verifiedHash,
                                 installedShortVersion: installedShort, installedVersion: installedVersion),
                appName: appName, wasRunning: wasRunning, onLine: onLine, env: env)
            let shown = newInfo["CFBundleShortVersionString"] as? String ?? newVersion
            onLine(String(localized: "\(appName) güncellendi: \(shown)", bundle: .main))
            return
        }

        // f) Yedekli değiştirme. Hemen önce: kurulu uygulama değişmedi ve hazırlanan paket hâlâ doğrulanan paket
        // (CDHash). Yerleştirildikten sonra kod imzası ve CDHash yerinde yeniden denetlenir; tutmazsa geri alınır.
        // Kalan risk: aynı kullanıcıyla çalışan bir süreç kullanıcının yazabildiği bu klasörlere her an
        // dokunabilir; bu denetimler yarışı daraltır ve kurulan nesneyi doğrulanan koda bağlar.
        try await requireInstalledUnchanged()
        guard await env.codeHash(newApp) == verifiedHash else {
            if wasRunning { _ = await env.relaunch(appURL) }
            throw SparkleInstallError.codeSignatureInvalid
        }
        onLine(String(localized: "Uygulama değiştiriliyor", bundle: .main))
        let backupDir = work.appendingPathComponent("backup", isDirectory: true)
        let backup = backupDir.appendingPathComponent(appURL.lastPathComponent)
        do {
            try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
            try fm.moveItem(at: appURL, to: backup)
        } catch {
            if wasRunning { _ = await env.relaunch(appURL) }
            throw SparkleInstallError.swapFailed
        }
        var swapped = false
        do {
            try fm.moveItem(at: newApp, to: appURL)
            swapped = true
            guard let placed = bundleInfo(appURL), placed["CFBundleIdentifier"] as? String == d.bundleID,
                  placed["CFBundleVersion"] as? String == newVersion,
                  try await verifyCodeSignature(appURL, cancellable: false), await env.codeHash(appURL) == verifiedHash
            else { throw SparkleInstallError.swapFailed }
        } catch {
            // Geri yükleme: yeni paketi kenara al, yedeği yerine koy.
            if swapped { try? fm.moveItem(at: appURL, to: work.appendingPathComponent("failed-\(appURL.lastPathComponent)")) }
            do {
                try fm.moveItem(at: backup, to: appURL)
                onLine(String(localized: "Eski sürüm geri yüklendi", bundle: .main))
            } catch {
                // Yedek tek kopyadır; silinmez.
                keepWork = true
                onLine(String(localized: "Eski sürüm şurada korunuyor: \(backup.path)", bundle: .main))
            }
            if wasRunning { _ = await env.relaunch(appURL) }
            throw SparkleInstallError.swapFailed
        }

        // g) Yeniden açma
        if wasRunning {
            onLine(String(localized: "Yeniden açılıyor: \(appName)", bundle: .main))
            if !(await env.relaunch(appURL)) { onLine(String(localized: "Uygulama yeniden açılamadı; elle açabilirsin", bundle: .main)) }
        }
        let shown = newInfo["CFBundleShortVersionString"] as? String ?? newVersion
        onLine(String(localized: "\(appName) güncellendi: \(shown)", bundle: .main))
    }

    /// Yönetici izniyle değiştirme ve sonucun yorumlanması. İzin penceresi ancak burada, tüm kullanıcı düzeyi
    /// doğrulamalar geçtikten sonra açılır. Başarısızlıkta eski sürüm root betiği tarafından yerinde bırakılır
    /// ya da geri yüklenir; uygulama kapatıldıysa yeniden açılır.
    private static func swapAsAdministrator(_ request: RootSwap.Request, appName: String, wasRunning: Bool,
                                            onLine: @escaping @Sendable (String) -> Void, env: Environment) async throws {
        let appURL = request.installed
        onLine(String(localized: "Yönetici izni isteniyor: \(appName)", bundle: .main))
        let translator = RootSwap.LineTranslator(onLine: onLine)
        let result: CommandResult
        do {
            result = try await env.privilegedSwap(request) { translator.feed($0) }
        } catch {
            // İzin verilmedi / iptal / yöntem yok / doğrulama reddi: root adımı başlamadı, uygulama yerinde.
            if wasRunning { _ = await env.relaunch(appURL) }
            throw error
        }
        let placed = bundleInfo(appURL)
        let placedOK = placed?["CFBundleIdentifier"] as? String == request.bundleID
            && placed?["CFBundleVersion"] as? String == request.version
        let outcome = RootSwap.Outcome(status: result.status)
        // İptal kritik bölümde geldiyse betik değiştirmeyi tamamlar; sonuç diskte doğrulanır.
        if translator.sawOK && placedOK && (outcome == .success || outcome == .cancelled) {
            if wasRunning {
                onLine(String(localized: "Yeniden açılıyor: \(appName)", bundle: .main))
                if !(await env.relaunch(appURL)) { onLine(String(localized: "Uygulama yeniden açılamadı; elle açabilirsin", bundle: .main)) }
            }
            return
        }
        if wasRunning { _ = await env.relaunch(appURL) }
        switch outcome {
        case .codeSignature, .codeHash: throw SparkleInstallError.codeSignatureInvalid
        case .team: throw SparkleInstallError.teamMismatch
        case .bundleID, .version: throw SparkleInstallError.bundleMismatch
        case .installedChanged: throw SparkleInstallError.installedChanged
        case .cancelled: throw SparkleInstallError.cancelled
        default:
            if bundleInfo(appURL) == nil {
                onLine(String(localized: "Uygulama yerinde bulunamadı; yönetici olarak değiştirme yarıda kalmış olabilir", bundle: .main))
            }
            throw SparkleInstallError.swapFailed
        }
    }

    /// `codesign --verify --deep --strict`.
    static func verifyCodeSignature(_ app: URL, cancellable: Bool = true) async throws -> Bool {
        try await Tool.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], timeout: 300,
                           cancellable: cancellable).status == 0
    }

    /// Kurulu uygulamanın kimliği ve iki sürüm değeri beklenenle aynı mı?
    static func isUnchanged(_ app: URL, bundleID: String, version: String, shortVersion: String) -> Bool {
        guard let info = bundleInfo(app) else { return false }
        return info["CFBundleIdentifier"] as? String == bundleID
            && (info["CFBundleVersion"] as? String ?? "") == version
            && (info["CFBundleShortVersionString"] as? String ?? "") == shortVersion
    }

    /// `codesign --verify --deep --strict` + Apple köklü, belirtilen ekibe ait imza gereksinimi.
    static func verifyAnchoredTeam(_ app: URL, team: String) async -> Bool {
        guard RootSwap.isTeamID(team) else { return false }
        let r = try? await Tool.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", RootSwap.requirement(team: team), app.path],
                                    timeout: 300)
        return r?.status == 0
    }

    static func cdhash(of app: URL) async -> String? {
        // İptal edilmez: değiştirmenin hemen öncesinde ve sonrasında da kullanılır (kısa sürer).
        guard let r = try? await Tool.run("/usr/bin/codesign", ["-dv", "--verbose=4", app.path], timeout: 120, cancellable: false)
        else { return nil }
        return RootSwap.cdhash(fromCodesignOutput: String(decoding: r.stderr + r.stdout, as: UTF8.self))
    }

    static func bundleInfo(_ app: URL) -> [String: Any]? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
    }

    static func team(of app: URL) async -> String? {
        guard let r = try? await Tool.run("/usr/bin/codesign", ["-dv", "--verbose=2", app.path], timeout: 120) else { return nil }
        return teamIdentifier(fromCodesignOutput: String(decoding: r.stderr + r.stdout, as: UTF8.self))
    }

    // MARK: - Arşivi açma

    /// Yalnızca doğrulanan dosyadan açar: her araç çağrısından hemen önce dosyanın kimliği ve SHA-256'sı
    /// doğrulanan parmak iziyle karşılaştırılır. Açılan ağaç `ArchiveGuard.checkTree` ile denetlenir.
    private static func extract(_ archive: URL, kind: ArchiveKind, fingerprint: ArchiveFingerprint, appName: String,
                                into dir: URL, work: URL) async throws -> URL {
        func requireVerifiedBytes() throws {
            guard ArchiveGuard.matches(fingerprint, file: archive) else { throw SparkleInstallError.archiveChanged }
        }
        switch kind {
        case .zip:
            try ArchiveGuard.checkZip(archive)
            try requireVerifiedBytes()
            // Başlıktaki boyut yalan söyleyebilir; bsdtar veri akışını diske yazmadan açar ve
            // gerçek boyut/sağlama toplamını denetler. `ditto` tek başına bu uyuşmazlığı kabul eder.
            try await verifyArchivePayload(archive)
            try requireVerifiedBytes()
            let r = try await Tool.run("/usr/bin/ditto", ["-x", "-k", archive.path, dir.path], timeout: 900)
            guard r.status == 0 else { throw SparkleInstallError.extractFailed }
            try ArchiveGuard.checkTree(dir)
            return try findApp(named: appName, in: dir)
        case .tar:
            // bsdtar varsayılan olarak ".." içeren ve bağın içinden geçen girdileri reddeder, baştaki "/" işaretini atar.
            try requireVerifiedBytes()
            try await verifyArchivePayload(archive)
            try requireVerifiedBytes()
            let r = try await Tool.run("/usr/bin/tar", ["-xf", archive.path, "-C", dir.path], timeout: 900)
            guard r.status == 0 else { throw SparkleInstallError.extractFailed }
            try ArchiveGuard.checkTree(dir)
            return try findApp(named: appName, in: dir)
        case .dmg:
            let mountRoot = work.appendingPathComponent("mnt", isDirectory: true)
            try FileManager.default.createDirectory(at: mountRoot, withIntermediateDirectories: true)
            var mounts: [String] = []
            do {
                try requireVerifiedBytes()
                let r = try await Tool.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-noverify",
                                                                "-mountrandom", mountRoot.path, "-plist", archive.path], timeout: 300)
                mounts = mountPoints(fromAttachPlist: r.stdout)
                guard r.status == 0, !mounts.isEmpty else { throw SparkleInstallError.extractFailed }
                var found: [URL] = []
                for m in mounts {
                    do { found += try findApps(named: appName, in: URL(fileURLWithPath: m)) } catch {
                        // macOS gizlilik izni ("Çıkarılabilir birimler") verilmemişse bağlanan birim okunamaz.
                        if (error as NSError).code == NSFileReadNoPermissionError { throw SparkleInstallError.volumeAccessDenied }
                        throw SparkleInstallError.extractFailed
                    }
                }
                guard found.count == 1, let source = found.first else { throw SparkleInstallError.appNotFound }
                // Salt okunur bağlanan uygulamayı kopyalamadan önce boyut ve bağları denetle.
                try ArchiveGuard.checkTree(source)
                let target = dir.appendingPathComponent(source.lastPathComponent)
                let copy = try await Tool.run("/usr/bin/ditto", [source.path, target.path], timeout: 900)
                guard copy.status == 0 else { throw SparkleInstallError.extractFailed }
                await detach(mounts, root: mountRoot)
                try ArchiveGuard.checkTree(dir)
                return target
            } catch {
                await detach(mounts, root: mountRoot)
                throw error
            }
        }
    }

    /// Arşiv içeriğini diske çıkarmadan açar ve toplam veri sınırını akışta uygular.
    /// bsdtar ayrıca ZIP verisinin boyut ve sağlama toplamını doğrular.
    static func verifyArchivePayload(_ archive: URL, maxBytes: Int64 = ArchiveGuard.maxExtractedBytes) async throws {
        guard maxBytes >= 0 else { throw SparkleInstallError.unsafeArchive }
        let job = ArchivePayloadCheck(archive: archive, limit: maxBytes)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            do { try await job.run() }
            catch { try Task.checkCancellation(); throw error }
            try Task.checkCancellation()
        } onCancel: { job.stop() }
    }

    /// `hdiutil attach -plist` çıktısındaki bağlama noktaları.
    static func mountPoints(fromAttachPlist data: Data) -> [String] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return [] }
        return entities.compactMap { $0["mount-point"] as? String }
    }

    /// Her durumda (iptal dahil) çağrılır; bağlama noktası çözümlenemediyse kök altındakiler denenir.
    private static func detach(_ mounts: [String], root: URL) async {
        let children = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).map { root.appendingPathComponent($0).path }
        for point in Set(mounts + children) {
            let r = try? await Tool.run("/usr/bin/hdiutil", ["detach", point, "-quiet"], timeout: 60, cancellable: false)
            if r?.status != 0, mounts.contains(point) {
                _ = try? await Tool.run("/usr/bin/hdiutil", ["detach", point, "-force", "-quiet"], timeout: 60, cancellable: false)
            }
        }
    }

    /// Kurulu uygulamayla aynı adlı tek `.app`; yoksa veya birden çoksa hata.
    static func findApp(named name: String, in dir: URL) throws -> URL {
        let found = try findApps(named: name, in: dir)
        guard found.count == 1, let app = found.first else { throw SparkleInstallError.appNotFound }
        return app
    }

    /// En fazla iki klasör derinliğinde arar; `.app` paketlerinin içine ve sembolik bağlara girmez.
    static func findApps(named name: String, in dir: URL, depth: Int = 2) throws -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let entries = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)
        var result: [URL] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: Set(keys))
            guard values?.isSymbolicLink != true, values?.isDirectory == true else { continue }
            if entry.pathExtension.lowercased() == "app" {
                if entry.deletingPathExtension().lastPathComponent.lowercased() == name.lowercased() { result.append(entry) }
            } else if depth > 1, !entry.lastPathComponent.hasPrefix("__MACOSX") {
                result += (try? findApps(named: name, in: entry, depth: depth - 1)) ?? []
            }
        }
        return result
    }

    // MARK: - Uygulamayı kapatma / açma

    private static func terminateLive(_ id: String, timeout: Duration) async -> Bool {
        await MainActor.run { NSRunningApplication.runningApplications(withBundleIdentifier: id).forEach { _ = $0.terminate() } }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await MainActor.run(body: { NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty }) { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return await MainActor.run { NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty }
    }

    private static func relaunchLive(_ url: URL) async -> Bool {
        let r = try? await Tool.run("/usr/bin/open", [url.path], timeout: 30, cancellable: false)
        return r?.status == 0
    }
}

// MARK: - İndirme

/// https dışı yönlendirmeyi, boyut aşımını ve hatalı yanıtı reddeden indirici.
enum Downloader {
    static func fetch(_ download: SparkleDownload, into dir: URL,
                      maxBytes: Int64 = SparkleInstaller.maxDownloadBytes) async throws -> URL {
        guard SparkleInstaller.isSecure(download.url) else { throw SparkleInstallError.insecureURL }
        let name = download.url.lastPathComponent.isEmpty ? "update" : download.url.lastPathComponent
        let destination = dir.appendingPathComponent(name.replacingOccurrences(of: "/", with: "_"))
        let delegate = DownloadDelegate(destination: destination, maxBytes: maxBytes, expected: download.length)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60
        config.httpAdditionalHeaders = ["User-Agent": "Tazele"]
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: download.url)
        request.setValue("Tazele", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                delegate.start(cont)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let maxBytes: Int64
    private let expected: Int64?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var failure: Error?
    private var saved: URL?

    init(destination: URL, maxBytes: Int64, expected: Int64?) {
        self.destination = destination
        self.maxBytes = maxBytes
        self.expected = expected
    }

    func start(_ cont: CheckedContinuation<URL, Error>) { lock.withLock { continuation = cont } }

    private func fail(_ error: Error) { lock.withLock { if failure == nil { failure = error } } }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        if SparkleInstaller.isSecure(request.url) { completionHandler(request); return }
        fail(SparkleInstallError.insecureURL)
        completionHandler(nil)
        task.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maxBytes || totalBytesExpectedToWrite > maxBytes {
            fail(SparkleInstallError.tooLarge); downloadTask.cancel()
        } else if let expected, totalBytesWritten > expected
                    || (totalBytesExpectedToWrite > 0 && totalBytesExpectedToWrite != expected) {
            fail(SparkleInstallError.sizeMismatch); downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Geçici dosya bu çağrıdan sonra silinir; hemen taşınmalı.
        let http = downloadTask.response as? HTTPURLResponse
        guard let http, http.statusCode == 200 else { fail(SparkleInstallError.downloadFailed(http?.statusCode ?? 0)); return }
        guard SparkleInstaller.isSecure(http.url) else { fail(SparkleInstallError.insecureURL); return }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            lock.withLock { saved = destination }
        } catch { fail(error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (cont, result): (CheckedContinuation<URL, Error>?, Result<URL, Error>) = lock.withLock {
            let c = continuation
            continuation = nil
            if let failure { return (c, .failure(failure)) }
            if let error {
                if (error as? URLError)?.code == .cancelled { return (c, .failure(CancellationError())) }
                return (c, .failure(error))
            }
            if let saved { return (c, .success(saved)) }
            return (c, .failure(SparkleInstallError.downloadFailed(0)))
        }
        cont?.resume(with: result)
    }
}

// MARK: - Süreç çalıştırma

/// bsdtar çıktısını diske yazmadan okur; sınır aşılınca ve iptalde süreci durdurur.
private final class ArchivePayloadCheck: @unchecked Sendable {
    private let process = Process()
    private let pipe = Pipe()
    private let limit: Int64
    private let lock = NSLock()
    private var stopped = false

    init(archive: URL, limit: Int64) {
        self.limit = limit
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        process.arguments = ["-xOf", archive.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
    }

    func stop() {
        lock.withLock { stopped = true }
        if process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    func run() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                do {
                    try process.run()
                    try pipe.fileHandleForWriting.close()
                    if lock.withLock({ stopped }) { stop() }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 900) { [weak self] in
                        guard let self, process.isRunning else { return }
                        stop()
                    }
                    var total: Int64 = 0
                    var exceeded = false
                    while true {
                        let data = try pipe.fileHandleForReading.read(upToCount: 64 * 1024) ?? Data()
                        if data.isEmpty { break }
                        if Int64(data.count) > limit - total { exceeded = true; stop(); break }
                        total += Int64(data.count)
                    }
                    try? pipe.fileHandleForReading.close()
                    process.waitUntilExit()
                    guard !exceeded, !lock.withLock({ stopped }), process.terminationStatus == 0 else {
                        throw SparkleInstallError.unsafeArchive
                    }
                    cont.resume()
                } catch {
                    stop()
                    try? pipe.fileHandleForReading.close()
                    try? pipe.fileHandleForWriting.close()
                    cont.resume(throwing: error)
                }
            }
        }
    }
}

/// Mutlak yollu bir aracı, kabuk ortamı olmadan çalıştırır. stdout ve stderr ayrı toplanır.
enum Tool {
    struct Result: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval,
                    cancellable: Bool = true) async throws -> Result {
        let job = Job(executable: executable, arguments: arguments)
        if cancellable { try Task.checkCancellation() }
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Result, Error>) in
                job.start(timeout: timeout, cont)
            }
        } onCancel: {
            if cancellable { job.terminate() }
        }
        // İptalle sonlandırılan sürecin yarım çıktısı kullanılmaz.
        if cancellable { try Task.checkCancellation() }
        return result
    }

    /// Çıktı boru yerine geçici dosyalara yazılır: `hdiutil attach` gibi araçların arka plan yardımcıları
    /// boruyu açık tutup okumayı sonsuza dek bekletebilir; dosyada bu sorun yoktur.
    private final class Job: @unchecked Sendable {
        private let process = Process()
        private let outURL: URL
        private let errURL: URL

        init(executable: String, arguments: [String]) {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("tazele-tool-\(UUID().uuidString)")
            outURL = base.appendingPathExtension("out")
            errURL = base.appendingPathExtension("err")
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
            for key in ["HOME", "TMPDIR", "USER"] { env[key] = ProcessInfo.processInfo.environment[key] }
            process.environment = env
            process.standardInput = FileHandle.nullDevice
        }

        func start(timeout: TimeInterval, _ cont: CheckedContinuation<Result, Error>) {
            let fm = FileManager.default
            guard fm.createFile(atPath: outURL.path, contents: nil), fm.createFile(atPath: errURL.path, contents: nil),
                  let out = try? FileHandle(forWritingTo: outURL), let err = try? FileHandle(forWritingTo: errURL) else {
                cont.resume(throwing: CocoaError(.fileWriteUnknown)); return
            }
            process.standardOutput = out
            process.standardError = err
            process.terminationHandler = { p in
                try? out.close(); try? err.close()
                let result = Result(status: p.terminationStatus,
                                    stdout: (try? Data(contentsOf: self.outURL)) ?? Data(),
                                    stderr: (try? Data(contentsOf: self.errURL)) ?? Data())
                try? FileManager.default.removeItem(at: self.outURL); try? FileManager.default.removeItem(at: self.errURL)
                cont.resume(returning: result)
            }
            do { try process.run() } catch {
                try? out.close(); try? err.close()
                try? fm.removeItem(at: outURL); try? fm.removeItem(at: errURL)
                cont.resume(throwing: error); return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { self.terminate() }
        }

        func terminate() { if process.isRunning { process.terminate() } }
    }
}
