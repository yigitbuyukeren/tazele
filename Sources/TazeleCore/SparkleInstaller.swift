import AppKit
import CryptoKit
import Foundation

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
        }
    }
}

/// Sparkle uygulamasını Sparkle'ın kendi güvenlik modeliyle kurar; üçüncü taraf ikili kullanmaz:
/// https indirme → arşiv baytlarında Ed25519 imzası (`SUPublicEDKey`) → arşivi açma →
/// paket kimliği, kod imzası, ekip kimliği ve sürüm denetimi → uygulamayı kibarca kapatma →
/// yedekli değiştirme (hata olursa geri yükleme) → yeniden açma. Root istemez, sudo kullanmaz.
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
    }

    /// Dosya sistemi denetimleri; testlerde yazılamaz konum taklit edilebilsin diye ayrı.
    struct FileProbe: Sendable {
        var exists: @Sendable (String) -> Bool
        var isSymlink: @Sendable (String) -> Bool
        var isWritable: @Sendable (String) -> Bool

        static let live = FileProbe(
            exists: { FileManager.default.fileExists(atPath: $0) },
            isSymlink: { (try? FileManager.default.attributesOfItem(atPath: $0)[.type] as? FileAttributeType) == .typeSymbolicLink },
            isWritable: { FileManager.default.isWritableFile(atPath: $0) })
    }

    /// Bu öğe Tazele'den kurulabilir mi? (EdDSA imzalı, https, desteklenen arşiv, yazılabilir konum.)
    public static func canInstall(_ item: OutdatedItem) -> Bool { rejection(for: item) == nil }

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
        guard probe.isWritable(app.deletingLastPathComponent().path), probe.isWritable(app.path) else { return .notWritable }
        return nil
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

    static func verifyEdSignature(ofFile url: URL, signature: String, publicKey key: String) -> Bool {
        // Büyük dosyalar belleğe kopyalanmadan eşlenir.
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return false }
        return verifyEdSignature(of: data, signature: signature, publicKey: key)
    }

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

        static let live = Environment(
            fetch: { download, dir in try await Downloader.fetch(download, into: dir) },
            isRunning: { id in await MainActor.run { !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty } },
            terminate: { id, timeout in await terminateLive(id, timeout: timeout) },
            relaunch: { url in await relaunchLive(url) },
            makeWorkDirectory: { app in
                try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
            })
    }

    public static func install(_ item: OutdatedItem, onLine: @Sendable (String) -> Void) async throws {
        try await install(item, onLine: onLine, environment: .live)
    }

    static func install(_ item: OutdatedItem, onLine: @Sendable (String) -> Void, environment env: Environment) async throws {
        do {
            try await perform(item, onLine: onLine, env: env)
        } catch is CancellationError {
            onLine(String(localized: "Kurulum iptal edildi", bundle: .main))
            throw SparkleInstallError.cancelled
        }
    }

    private static func perform(_ item: OutdatedItem, onLine: @Sendable (String) -> Void, env: Environment) async throws {
        let fm = FileManager.default
        guard rejection(for: item) == nil, let d = item.download, let sig = d.edSignature, let path = item.path,
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
        let appName = appURL.deletingPathExtension().lastPathComponent

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

        // b) EdDSA imzası
        try Task.checkCancellation()
        onLine(String(localized: "EdDSA imzası doğrulanıyor", bundle: .main))
        guard verifyEdSignature(ofFile: archive, signature: sig, publicKey: installedKey) else {
            try? fm.removeItem(at: archive)
            throw SparkleInstallError.signatureInvalid
        }
        onLine(String(localized: "İmza geçerli", bundle: .main))

        // c) Arşivi açma
        try Task.checkCancellation()
        onLine(String(localized: "Arşiv açılıyor", bundle: .main))
        let extractDir = work.appendingPathComponent("extracted", isDirectory: true)
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        let newApp = try await extract(archive, kind: kind, appName: appName, into: extractDir, work: work)
        try? fm.removeItem(at: archive)

        // d) Yeni paketin denetimi
        try Task.checkCancellation()
        onLine(String(localized: "Yeni sürüm denetleniyor (paket kimliği, kod imzası, ekip)", bundle: .main))
        guard let newInfo = bundleInfo(newApp), newInfo["CFBundleIdentifier"] as? String == d.bundleID
        else { throw SparkleInstallError.bundleMismatch }
        let newVersion = newInfo["CFBundleVersion"] as? String ?? ""
        guard isNewer(newVersion, than: installedVersion) else { throw SparkleInstallError.notNewer }
        let verify = try await Tool.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path], timeout: 300)
        guard verify.status == 0 else { throw SparkleInstallError.codeSignatureInvalid }
        let installedTeam = await team(of: appURL)
        if let installedTeam {
            guard await team(of: newApp) == installedTeam else { throw SparkleInstallError.teamMismatch }
        } else {
            // Kurulu uygulama ad-hoc / imzasızsa güven yalnızca EdDSA anahtarına dayanır: anahtar değişmemeli.
            let newKey = (newInfo["SUPublicEDKey"] as? String)?.filter { !$0.isWhitespace }
            guard newKey == installedKey else { throw SparkleInstallError.keyMismatch }
        }

        // e) Çalışıyorsa kibarca kapatma
        try Task.checkCancellation()
        let wasRunning = await env.isRunning(d.bundleID)
        if wasRunning {
            onLine(String(localized: "Kapatılıyor: \(appName)", bundle: .main))
            guard await env.terminate(d.bundleID, quitTimeout) else { throw SparkleInstallError.appStillRunning }
        }
        // Bu noktadan sonra iptal edilmez: değiştirme kısa ve geri alınabilir olmalı.

        // f) Yedekli değiştirme
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
                  placed["CFBundleVersion"] as? String == newVersion else { throw SparkleInstallError.swapFailed }
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

    static func bundleInfo(_ app: URL) -> [String: Any]? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
    }

    private static func team(of app: URL) async -> String? {
        guard let r = try? await Tool.run("/usr/bin/codesign", ["-dv", "--verbose=2", app.path], timeout: 120) else { return nil }
        return teamIdentifier(fromCodesignOutput: String(decoding: r.stderr + r.stdout, as: UTF8.self))
    }

    // MARK: - Arşivi açma

    private static func extract(_ archive: URL, kind: ArchiveKind, appName: String, into dir: URL, work: URL) async throws -> URL {
        switch kind {
        case .zip:
            let r = try await Tool.run("/usr/bin/ditto", ["-x", "-k", archive.path, dir.path], timeout: 900)
            guard r.status == 0 else { throw SparkleInstallError.extractFailed }
            return try findApp(named: appName, in: dir)
        case .tar:
            let r = try await Tool.run("/usr/bin/tar", ["-xf", archive.path, "-C", dir.path], timeout: 900)
            guard r.status == 0 else { throw SparkleInstallError.extractFailed }
            return try findApp(named: appName, in: dir)
        case .dmg:
            let mountRoot = work.appendingPathComponent("mnt", isDirectory: true)
            try FileManager.default.createDirectory(at: mountRoot, withIntermediateDirectories: true)
            var mounts: [String] = []
            do {
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
                let target = dir.appendingPathComponent(source.lastPathComponent)
                let copy = try await Tool.run("/usr/bin/ditto", [source.path, target.path], timeout: 900)
                guard copy.status == 0 else { throw SparkleInstallError.extractFailed }
                await detach(mounts, root: mountRoot)
                return target
            } catch {
                await detach(mounts, root: mountRoot)
                throw error
            }
        }
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
