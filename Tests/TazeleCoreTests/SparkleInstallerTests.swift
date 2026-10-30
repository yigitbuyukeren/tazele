import CryptoKit
import Foundation
import Testing
@testable import TazeleCore

// MARK: - Yardımcılar

private var fm: FileManager { .default }

private func tempDir(_ tag: String) throws -> URL {
    let dir = fm.temporaryDirectory.appendingPathComponent("tz-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.resolvingSymlinksInPath()
}

@discardableResult
private func sh(_ exe: String, _ args: [String]) throws -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

/// Info.plist + gerçek bir Mach-O (/usr/bin/true kopyası) içeren, ad-hoc imzalı sahte uygulama.
@discardableResult
private func makeApp(in dir: URL, name: String = "Fake", id: String = "test.tazele.fake", version: String,
                     edKey: String?, sign: Bool = true) throws -> URL {
    let app = dir.appendingPathComponent("\(name).app")
    let macOS = app.appendingPathComponent("Contents/MacOS")
    try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
    try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent(name))
    var info: [String: Any] = ["CFBundleExecutable": name, "CFBundleIdentifier": id, "CFBundleVersion": version,
                               "CFBundleShortVersionString": "\(version).0", "CFBundlePackageType": "APPL", "CFBundleName": name]
    if let edKey { info["SUPublicEDKey"] = edKey }
    (info as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
    if sign { #expect(try sh("/usr/bin/codesign", ["--force", "--sign", "-", app.path]) == 0) }
    return app
}

private struct Keys {
    let priv = Curve25519.Signing.PrivateKey()
    var publicB64: String { priv.publicKey.rawRepresentation.base64EncodedString() }
    func sign(_ url: URL) throws -> String { try priv.signature(for: Data(contentsOf: url)).base64EncodedString() }
}

private func size(_ url: URL) -> Int64 { ((try? fm.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0 }

private func item(path: String, url: String = "https://example.invalid/Fake.zip", signature: String?, key: String?,
                  length: Int64? = nil, id: String = "test.tazele.fake", type: String? = nil, installationType: String? = nil) -> OutdatedItem {
    OutdatedItem(source: .sparkle, name: "Fake", installed: "1.0", latest: "2.0", path: path,
                 download: SparkleDownload(url: URL(string: url)!, edSignature: signature, length: length, publicEDKey: key,
                                           bundleID: id, type: type, installationType: installationType))
}

/// Kayıt tutan sahte uygulama denetimi.
private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var _relaunched: [URL] = []
    private var _work: URL?
    var relaunched: [URL] { lock.withLock { _relaunched } }
    var work: URL? { lock.withLock { _work } }
    func relaunch(_ u: URL) { lock.withLock { _relaunched.append(u) } }
    func setWork(_ u: URL) { lock.withLock { _work = u } }
}

/// Ağsız ortam: "indirme" yerel arşivi kopyalar.
private func offline(_ archive: URL, running: Bool = false, quits: Bool = true, calls: Calls) -> SparkleInstaller.Environment {
    SparkleInstaller.Environment(
        fetch: { _, dir in
            let dest = dir.appendingPathComponent(archive.lastPathComponent)
            try FileManager.default.copyItem(at: archive, to: dest)
            return dest
        },
        isRunning: { _ in running },
        terminate: { _, _ in quits },
        relaunch: { url in calls.relaunch(url); return true },
        makeWorkDirectory: { app in
            let w = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
            calls.setWork(w)
            return w
        })
}

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var _all: [String] = []
    var all: [String] { lock.withLock { _all } }
    func add(_ s: String) { lock.withLock { _all.append(s) } }
}

private func installedVersion(_ app: URL) -> String? {
    (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["CFBundleVersion"] as? String
}

/// Kurulu v1 + arşivlenmiş v2 kurgusu.
private struct Fixture {
    let root: URL, apps: URL, installed: URL, keys = Keys()
    init() throws {
        root = try tempDir("sparkle")
        apps = root.appendingPathComponent("Applications")
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        installed = try makeApp(in: apps, version: "1", edKey: keys.publicB64)
    }
    /// Yeni sürümü oluşturup arşivler; arşiv yolunu döndürür.
    func archive(kind: String = "zip", name: String = "Fake", id: String = "test.tazele.fake", version: String = "2",
                 edKey: String? = nil) throws -> URL {
        let src = root.appendingPathComponent("src-\(UUID().uuidString)")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        let app = try makeApp(in: src, name: name, id: id, version: version, edKey: edKey ?? keys.publicB64)
        let out = root.appendingPathComponent("Fake-\(UUID().uuidString.prefix(6)).\(kind)")
        switch kind {
        case "zip": #expect(try sh("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, out.path]) == 0)
        case "tar.gz": #expect(try sh("/usr/bin/tar", ["-czf", out.path, "-C", src.path, app.lastPathComponent]) == 0)
        case "dmg": #expect(try sh("/usr/bin/hdiutil", ["create", "-quiet", "-fs", "HFS+", "-srcfolder", src.path, "-volname", "Fake", out.path]) == 0)
        default: Issue.record("bilinmeyen tür")
        }
        return out
    }
    func cleanup() { try? fm.removeItem(at: root) }
}

// MARK: - Testler

@Suite struct SparkleInstallerTests {
    @Test func edSignatureVerification() throws {
        let keys = Keys(), other = Keys()
        let data = Data("Tazele arşiv baytları".utf8)
        let sig = try keys.priv.signature(for: data).base64EncodedString()
        #expect(SparkleInstaller.verifyEdSignature(of: data, signature: sig, publicKey: keys.publicB64))
        var tampered = data; tampered[0] ^= 0x01
        #expect(!SparkleInstaller.verifyEdSignature(of: tampered, signature: sig, publicKey: keys.publicB64))
        #expect(!SparkleInstaller.verifyEdSignature(of: data, signature: sig, publicKey: other.publicB64))
        #expect(!SparkleInstaller.verifyEdSignature(of: data, signature: "!!!not base64", publicKey: keys.publicB64))
        #expect(!SparkleInstaller.verifyEdSignature(of: data, signature: sig, publicKey: "%%%"))
        // Yanlış uzunluklar (DSA imzası / kısa anahtar) reddedilir.
        #expect(SparkleInstaller.signatureData(Data(repeating: 1, count: 46).base64EncodedString()) == nil)
        #expect(SparkleInstaller.publicKey(Data(repeating: 1, count: 31).base64EncodedString()) == nil)
        // Plist'te satır sonu olan anahtar da çözülür.
        #expect(SparkleInstaller.verifyEdSignature(of: data, signature: sig, publicKey: "\n " + keys.publicB64 + "\n"))
    }

    @Test(arguments: [
        ("https://x.io/A.zip", nil, nil, SparkleInstaller.ArchiveKind?.some(.zip)),
        ("https://x.io/A-1.2.dmg", nil, nil, .some(.dmg)),
        ("https://x.io/A.tar.gz", nil, nil, .some(.tar)),
        ("https://x.io/A.tar.xz", nil, nil, .some(.tar)),
        ("https://x.io/A.tgz", nil, nil, .some(.tar)),
        ("https://x.io/A.pkg", nil, nil, nil),
        ("https://x.io/A.mpkg", nil, nil, nil),
        ("https://x.io/A.zip", nil, "package", nil),
        ("https://x.io/A.zip", nil, "interactive-package", nil),
        ("https://x.io/A.zip", nil, "application", .some(.zip)),
        ("https://x.io/download", "application/zip", nil, .some(.zip)),
        ("https://x.io/download", "application/x-apple-diskimage", nil, .some(.dmg)),
        ("https://x.io/download", "application/octet-stream", nil, nil),
        ("https://x.io/A.exe", "application/zip", nil, nil),
    ] as [(String, String?, String?, SparkleInstaller.ArchiveKind?)])
    func archiveClassification(url: String, type: String?, installationType: String?, expected: SparkleInstaller.ArchiveKind?) {
        #expect(SparkleInstaller.archiveKind(url: URL(string: url)!, type: type, installationType: installationType) == expected)
    }

    @Test func installabilityDecisions() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let sig = Data(repeating: 7, count: 64).base64EncodedString()
        let key = f.keys.publicB64, path = f.installed.path
        func reason(_ i: OutdatedItem, writable: Bool = true) -> SparkleInstaller.Rejection? {
            var probe = SparkleInstaller.FileProbe.live
            if !writable { probe.isWritable = { _ in false } }
            return SparkleInstaller.rejection(for: i, probe: probe, ownBundleID: "app.tazele")
        }
        #expect(reason(item(path: path, signature: sig, key: key)) == nil)
        #expect(reason(item(path: path, url: "http://example.invalid/Fake.zip", signature: sig, key: key)) == .insecureURL)
        #expect(reason(item(path: path, signature: nil, key: key)) == .noSignature)       // yalnızca DSA
        #expect(reason(item(path: path, signature: sig, key: nil)) == .badKey)
        #expect(reason(item(path: path, signature: sig, key: "kısa")) == .badKey)
        #expect(reason(item(path: path, url: "https://example.invalid/Fake.pkg", signature: sig, key: key)) == .unsupportedArchive)
        #expect(reason(item(path: path, signature: sig, key: key, installationType: "package")) == .unsupportedArchive)
        #expect(reason(item(path: path, signature: sig, key: key, id: "app.tazele")) == .badBundleID)
        #expect(reason(item(path: "/System/Applications/Fake.app", signature: sig, key: key)) == .protectedLocation)
        #expect(reason(item(path: "/Library/Fake.app", signature: sig, key: key)) == .protectedLocation)
        #expect(reason(item(path: f.apps.appendingPathComponent("Yok.app").path, signature: sig, key: key)) == .missing)
        #expect(reason(item(path: path, signature: sig, key: key), writable: false) == .notWritable)
        #expect(reason(OutdatedItem(source: .sparkle, name: "Fake", installed: "1", latest: "2", path: path)) == .noDownload)
        // Mac App Store uygulamasına dokunulmaz.
        try Data().write(to: f.installed.appendingPathComponent("Contents/_MASReceipt"))
        #expect(reason(item(path: path, signature: sig, key: key)) == .macAppStore)
        // Yolu sembolik bağ olan uygulama değiştirilmez.
        let link = f.apps.appendingPathComponent("Link.app")
        try fm.createSymbolicLink(at: link, withDestinationURL: f.installed)
        #expect(reason(item(path: link.path, signature: sig, key: key)) == .symlink)
    }

    @Test func appcastEnclosureIsParsedAndDeltasIgnored() {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        <item><sparkle:version>200</sparkle:version><sparkle:shortVersionString>2.0</sparkle:shortVersionString>
          <sparkle:deltas>
            <enclosure url="https://x.io/delta.delta" sparkle:deltaFrom="100" length="10" sparkle:edSignature="DELTA"/>
          </sparkle:deltas>
          <enclosure url="https://x.io/App-2.0.zip" length="12345" type="application/octet-stream"
            sparkle:edSignature="SIG==" sparkle:installationType="application"/>
        </item>
        <item><enclosure url="https://x.io/App-1.0.zip" sparkle:version="100" sparkle:dsaSignature="DSA" length="0"/></item>
        </channel></rss>
        """
        let items = Sparkle.parseAppcast(Data(xml.utf8))
        #expect(items.count == 2)
        #expect(items[0].url == "https://x.io/App-2.0.zip")
        #expect(items[0].edSignature == "SIG==" && items[0].length == 12345)
        #expect(items[0].type == "application/octet-stream" && items[0].installationType == "application")
        #expect(items[1].edSignature == nil && items[1].length == nil)   // yalnızca DSA; 0 uzunluk yok sayılır

        let app = SparkleApp(name: "App", path: "/Applications/App.app", bundleID: "x.app", shortVersion: "1.0",
                             bundleVersion: "100", feedURL: nil, isMacAppStore: false, publicEDKey: "KEY")
        let out = Sparkle.outdated(app: app, items: items)
        #expect(out?.download?.url.absoluteString == "https://x.io/App-2.0.zip")
        #expect(out?.download?.edSignature == "SIG==" && out?.download?.publicEDKey == "KEY" && out?.download?.bundleID == "x.app")
        // Cask belirteci eklenince indirme bilgisi korunur.
        #expect(out?.withCaskToken("app").download == out?.download)
    }

    @Test func versionMustBeStrictlyNewer() {
        #expect(SparkleInstaller.isNewer("101", than: "100"))
        #expect(SparkleInstaller.isNewer("1.10", than: "1.9"))
        #expect(!SparkleInstaller.isNewer("100", than: "100"))
        #expect(!SparkleInstaller.isNewer("99", than: "100"))
        #expect(!SparkleInstaller.isNewer("", than: "100"))
        #expect(!SparkleInstaller.isNewer("2", than: ""))
    }

    @Test func teamIdentifierParsing() {
        #expect(SparkleInstaller.teamIdentifier(fromCodesignOutput: "Identifier=x\nTeamIdentifier=ABCDE12345\n") == "ABCDE12345")
        #expect(SparkleInstaller.teamIdentifier(fromCodesignOutput: "Signature=adhoc\nTeamIdentifier=not set\n") == nil)
        #expect(SparkleInstaller.teamIdentifier(fromCodesignOutput: "code object is not signed at all") == nil)
    }

    @Test func hdiutilPlistMountPoints() throws {
        let plist: [String: Any] = ["system-entities": [["dev-entry": "/dev/disk9"], ["dev-entry": "/dev/disk9s1", "mount-point": "/tmp/mnt/abc"]]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        #expect(SparkleInstaller.mountPoints(fromAttachPlist: data) == ["/tmp/mnt/abc"])
        #expect(SparkleInstaller.mountPoints(fromAttachPlist: Data("çöp".utf8)).isEmpty)
    }

    @Test func downloaderRejectsNonHTTPS() async throws {
        let dir = try tempDir("dl")
        defer { try? fm.removeItem(at: dir) }
        let d = SparkleDownload(url: URL(string: "http://example.invalid/a.zip")!, edSignature: nil, length: nil, publicEDKey: nil, bundleID: "x")
        await #expect(throws: SparkleInstallError.insecureURL) { _ = try await Downloader.fetch(d, into: dir) }
    }

    // MARK: Uçtan uca (ağsız, sahte uygulama, geçici "Applications")

    @Test(arguments: ["zip", "tar.gz", "dmg"])
    func endToEndInstallReplacesApp(kind: String) async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let archive = try f.archive(kind: kind)
        let calls = Calls(), lines = Lines()
        let i = item(path: f.installed.path, url: "https://example.invalid/Fake.\(kind)",
                     signature: try f.keys.sign(archive), key: f.keys.publicB64, length: size(archive))
        do {
            try await SparkleInstaller.install(i, onLine: { lines.add($0) }, environment: offline(archive, calls: calls))
        } catch SparkleInstallError.volumeAccessDenied where kind == "dmg" {
            // Test sürecinin "Çıkarılabilir birimler" gizlilik izni yoksa bağlanan birim okunamaz (EPERM).
            // Bu durumda da: uygulama değişmemeli, birim ayrılmış ve geçici dosyalar silinmiş olmalı.
            #expect(installedVersion(f.installed) == "1")
            #expect(calls.work.map { !fm.fileExists(atPath: $0.path) } == true)
            #expect(!(try sh("/bin/sh", ["-c", "mount | grep -q 'NSIRD_'"]) == 0))
            return
        }
        #expect(installedVersion(f.installed) == "2")
        #expect(try sh("/usr/bin/codesign", ["--verify", "--deep", "--strict", f.installed.path]) == 0)
        #expect(calls.relaunched.isEmpty)
        #expect(calls.work.map { !fm.fileExists(atPath: $0.path) } == true)   // geçici dosyalar silindi
        #expect(lines.all.count >= 5)
        // dmg ise bağlı kalan birim olmamalı.
        #expect(!(try sh("/bin/sh", ["-c", "mount | grep -q '\(calls.work?.path ?? "/nonexistent")'"]) == 0))
    }

    @Test func tamperedArchiveIsRejectedAndAppUntouched() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let archive = try f.archive()
        let sig = try f.keys.sign(archive)
        let h = try FileHandle(forWritingTo: archive); try h.seekToEnd(); try h.write(contentsOf: Data([0])); try h.close()
        let calls = Calls()
        await #expect(throws: SparkleInstallError.signatureInvalid) {
            try await SparkleInstaller.install(item(path: f.installed.path, signature: sig, key: f.keys.publicB64),
                                               onLine: { _ in }, environment: offline(archive, calls: calls))
        }
        #expect(installedVersion(f.installed) == "1")
        #expect(calls.work.map { !fm.fileExists(atPath: $0.path) } == true)
    }

    @Test func wrongLengthIsRejected() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let archive = try f.archive()
        await #expect(throws: SparkleInstallError.sizeMismatch) {
            try await SparkleInstaller.install(item(path: f.installed.path, signature: try f.keys.sign(archive), key: f.keys.publicB64,
                                                    length: size(archive) + 1),
                                               onLine: { _ in }, environment: offline(archive, calls: Calls()))
        }
        #expect(installedVersion(f.installed) == "1")
    }

    @Test func bundleChecksRejectBadCandidates() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let other = Keys()
        let cases: [(URL, SparkleInstallError)] = [
            (try f.archive(version: "1"), .notNewer),
            (try f.archive(id: "evil.other"), .bundleMismatch),
            (try f.archive(name: "Baska"), .appNotFound),
            (try f.archive(edKey: other.publicB64), .keyMismatch),   // ad-hoc kurulu uygulamada anahtar değişemez
        ]
        for (archive, expected) in cases {
            await #expect(throws: expected) {
                try await SparkleInstaller.install(item(path: f.installed.path, signature: try f.keys.sign(archive), key: f.keys.publicB64),
                                                   onLine: { _ in }, environment: offline(archive, calls: Calls()))
            }
            #expect(installedVersion(f.installed) == "1")
        }
    }

    @Test func unsignedCandidateFailsCodeSignatureCheck() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let src = f.root.appendingPathComponent("unsigned")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        let app = try makeApp(in: src, version: "2", edKey: f.keys.publicB64, sign: false)
        // İmzasız paket (yalnızca içindeki ikili Apple imzalı) codesign --strict denetiminden geçmemeli.
        let archive = f.root.appendingPathComponent("unsigned.zip")
        #expect(try sh("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, archive.path]) == 0)
        await #expect(throws: SparkleInstallError.codeSignatureInvalid) {
            try await SparkleInstaller.install(item(path: f.installed.path, signature: try f.keys.sign(archive), key: f.keys.publicB64),
                                               onLine: { _ in }, environment: offline(archive, calls: Calls()))
        }
        #expect(installedVersion(f.installed) == "1")
    }

    @Test func runningAppThatWontQuitAbortsWithoutChanges() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let archive = try f.archive()
        let calls = Calls()
        await #expect(throws: SparkleInstallError.appStillRunning) {
            try await SparkleInstaller.install(item(path: f.installed.path, signature: try f.keys.sign(archive), key: f.keys.publicB64),
                                               onLine: { _ in }, environment: offline(archive, running: true, quits: false, calls: calls))
        }
        #expect(installedVersion(f.installed) == "1")
        #expect(calls.relaunched.isEmpty)
    }

    @Test func runningAppIsRelaunchedAfterUpdate() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let archive = try f.archive()
        let calls = Calls()
        try await SparkleInstaller.install(item(path: f.installed.path, signature: try f.keys.sign(archive), key: f.keys.publicB64),
                                           onLine: { _ in }, environment: offline(archive, running: true, calls: calls))
        #expect(installedVersion(f.installed) == "2")
        #expect(calls.relaunched == [f.installed.standardizedFileURL])
    }

    @Test func installedKeyMustMatchItemKey() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let attacker = Keys()
        let archive = try f.archive(edKey: attacker.publicB64)
        // Öğedeki anahtar kurulu uygulamanınkinden farklıysa (bayat/sahte bilgi) kurulmaz.
        await #expect(throws: SparkleInstallError.keyMismatch) {
            try await SparkleInstaller.install(item(path: f.installed.path, signature: try attacker.sign(archive), key: attacker.publicB64),
                                               onLine: { _ in }, environment: offline(archive, calls: Calls()))
        }
        #expect(installedVersion(f.installed) == "1")
    }

    @Test func cancellationCleansUp() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let archive = try f.archive()
        let calls = Calls()
        var env = offline(archive, calls: calls)
        env.fetch = { _, _ in try await Task.sleep(for: .seconds(30)); throw CancellationError() }
        let i = item(path: f.installed.path, signature: try f.keys.sign(archive), key: f.keys.publicB64)
        let task = Task { try await SparkleInstaller.install(i, onLine: { _ in }, environment: env) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: SparkleInstallError.cancelled) { try await task.value }
        #expect(installedVersion(f.installed) == "1")
        #expect(calls.work.map { !fm.fileExists(atPath: $0.path) } == true)
    }
}
