import CryptoKit
import Foundation
import Testing
@testable import TazeleCore

// Yönetici izniyle kurulum testleri. Hiçbiri izin penceresi açmaz, hiçbir şeyi root olarak çalıştırmaz ve
// gerçek /Applications klasörüne dokunmaz. Root betiğinin gövdesi, root gerektirmeyen test başlığıyla
// (yalnızca DEBUG derlemesinde var olan `RootSwap.Script.testVariant()`) geçici klasörlerde çalıştırılır.

// MARK: - Yardımcılar

private var fm: FileManager { .default }
private let team = "ABCDE12345"

/// Gerçek yol (/var → /private/var); root betiği realpath ile karşılaştırır.
private func realTemp(_ tag: String) throws -> URL {
    let dir = fm.temporaryDirectory.appendingPathComponent("tz-root-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return URL(fileURLWithPath: try #require(RootSwap.realPath(dir.path)), isDirectory: true)
}

@discardableResult
private func run(_ exe: String, _ args: [String]) throws -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

private func output(_ exe: String, _ args: [String]) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// Ad-hoc imzalı sahte uygulama; test başlığı ekip kimliğini Info.plist'teki `TazeleTestTeam`'den okur.
/// İçinde paket içi göreli bir sembolik bağ da vardır (gerçek uygulamalardaki gibi).
@discardableResult
private func makeApp(in dir: URL, name: String = "Fake", id: String = "test.tazele.fake", version: String,
                     team: String? = team, edKey: String? = nil, sign: Bool = true) throws -> URL {
    let app = dir.appendingPathComponent("\(name).app")
    let macOS = app.appendingPathComponent("Contents/MacOS")
    let resources = app.appendingPathComponent("Contents/Resources")
    try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
    try fm.createDirectory(at: resources, withIntermediateDirectories: true)
    try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent(name))
    try Data("veri".utf8).write(to: resources.appendingPathComponent("data.txt"))
    try fm.createSymbolicLink(atPath: resources.appendingPathComponent("link.txt").path, withDestinationPath: "data.txt")
    var info: [String: Any] = ["CFBundleExecutable": name, "CFBundleIdentifier": id, "CFBundleVersion": version,
                               "CFBundleShortVersionString": "\(version).0", "CFBundlePackageType": "APPL", "CFBundleName": name]
    if let team { info["TazeleTestTeam"] = team }
    if let edKey { info["SUPublicEDKey"] = edKey }
    (info as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
    if sign { #expect(try run("/usr/bin/codesign", ["--force", "--sign", "-", app.path]) == 0) }
    return app
}

private func version(_ app: URL) -> String? {
    (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["CFBundleVersion"] as? String
}

private func entries(_ dir: URL) -> [String] { (try? fm.contentsOfDirectory(atPath: dir.path)) ?? ["?"] }

private func mode(_ path: String) -> Int {
    var st = stat()
    return lstat(path, &st) == 0 ? Int(st.st_mode & 0o7777) : -1
}

/// Geçici "Applications" + root betiğinin `mktemp` tabanı + hazırlanan yeni sürüm.
private struct Bed {
    let root: URL, apps: URL, base: URL, work: URL
    let installed: URL
    init(installedTeam: String? = team) throws {
        root = try realTemp("bed")
        apps = root.appendingPathComponent("Applications", isDirectory: true)
        base = root.appendingPathComponent("base", isDirectory: true)
        work = root.appendingPathComponent("work", isDirectory: true)
        for d in [apps, base, work] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        installed = try makeApp(in: apps, version: "1", team: installedTeam)
    }
    func stage(id: String = "test.tazele.fake", version: String = "2", team: String? = team, sign: Bool = true) throws -> URL {
        let dir = work.appendingPathComponent("extracted-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return try makeApp(in: dir, id: id, version: version, team: team, sign: sign)
    }
    func cleanup() {
        _ = try? run("/bin/chmod", ["-R", "u+w", root.path])
        try? fm.removeItem(at: root)
    }
}

private struct ScriptResult { let status: Int32; let output: String }

/// Test sürümü betiği verilen kabukla, ROOT OLMADAN çalıştırır.
private func runScript(shell: String, bed: Bed, args: [String], hook: String? = nil) throws -> ScriptResult {
    let flags = shell == RootSwap.shell ? ["-f", "-p", "-c"] : ["-c"]
    let p = Process()
    p.executableURL = URL(fileURLWithPath: shell)
    p.arguments = flags + [RootSwap.Script.testVariant(), "tazele-swap"] + args + ["1.0", "1"]
    var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TAZELE_TEST_APPS": bed.apps.path, "TAZELE_TEST_BASE": bed.base.path]
    if let hook { env["TAZELE_TEST_HOOK"] = hook }
    p.environment = env
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return ScriptResult(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
}

private let shells = [RootSwap.shell, "/bin/sh"]

/// Biçimce geçerli ama hiçbir pakete ait olmayan CDHash.
private let fakeHash = String(repeating: "a", count: 40)

/// Paketin CDHash'i (`codesign -dv --verbose=4`); imzasızsa biçimce geçerli sahte değer.
private func cdh(_ app: URL) -> String {
    RootSwap.cdhash(fromCodesignOutput: (try? output("/usr/bin/codesign", ["-dv", "--verbose=4", app.path])) ?? "") ?? fakeHash
}

// MARK: - Testler

@Suite struct RootInstallTests {

    // MARK: Yol ve argüman doğrulama (Swift, izin penceresinden önce)

    @Test(arguments: [
        ("/Applications/Tailscale.app", true),
        ("/Applications/Foo Bar (2).app", true),
        ("/Applications/A+B-c_d.1.app", true),
        ("/Applications/../etc.app", false),
        ("/Applications/..app", false),
        ("/Applications/.app", false),
        ("/Applications/.Hidden.app", false),
        ("/Applications/-rf.app", false),
        ("/Applications/Sub/X.app", false),
        ("/Applications/X.app/", false),
        ("/Applications//X.app", false),
        ("/applications/X.app", false),
        ("/Users/me/Applications/X.app", false),
        ("/System/Applications/X.app", false),
        ("Applications/X.app", false),
        ("/Applications/X", false),
        ("/Applications/X.app.zip", false),
        ("/Applications/X\n.app", false),
        ("/Applications/X\r.app", false),
        ("/Applications/X;id.app", false),
        ("/Applications/X$(id).app", false),
        ("/Applications/X'q.app", false),
        ("/Applications/Çay.app", false),
        ("/Applications/a..b.app", false),
    ])
    func installedPathShape(path: String, ok: Bool) {
        #expect(RootSwap.isInstalledPathShape(path) == ok)
    }

    @Test func valueValidation() {
        for ok in ["ABCDE12345", "W5364U7YZB"] { #expect(RootSwap.isTeamID(ok)) }
        for bad in ["", "abcde12345", "ABCDE1234", "ABCDE123456", "ABCDE 1234", "ABCDE1234\n", "ABCDE1234Ç"] { #expect(!RootSwap.isTeamID(bad)) }
        for ok in ["io.tailscale.ipn.macsys", "com.x-y.z_1"] { #expect(RootSwap.isBundleID(ok)) }
        for bad in ["", "-x", ".x", "a b", "a;b", "a/b", "a\nb"] { #expect(!RootSwap.isBundleID(bad)) }
        for ok in ["101.96.5", "1234", "2.0b1", "1.0+build-2"] { #expect(RootSwap.isVersion(ok)) }
        for bad in ["", "-1", "1 2", "1;rm", "1\n2", "1/2"] { #expect(!RootSwap.isVersion(bad)) }
        #expect(RootSwap.hasControlCharacters("a\u{7F}b") && RootSwap.hasControlCharacters("a\tb") && !RootSwap.hasControlCharacters("a b"))
    }

    @Test func stagedPathValidation() throws {
        let bed = try Bed()
        defer { bed.cleanup() }
        let staged = try bed.stage()
        #expect(RootSwap.validateStaged(staged.path, workDirectory: bed.work))
        // Sembolik bağlı çalışma klasörü yolu da (/var → /private/var gibi) kabul edilir.
        let alias = bed.root.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: bed.work)
        #expect(RootSwap.validateStaged(staged.path, workDirectory: alias))

        // Reddedilenler.
        let link = bed.work.appendingPathComponent("Link.app")
        try fm.createSymbolicLink(at: link, withDestinationURL: staged)
        #expect(!RootSwap.validateStaged(link.path, workDirectory: bed.work))                       // sembolik bağ
        let outside = try makeApp(in: bed.root, name: "Outside", version: "2")
        #expect(!RootSwap.validateStaged(outside.path, workDirectory: bed.work))                    // çalışma klasörü dışında
        #expect(!RootSwap.validateStaged(bed.installed.path, workDirectory: bed.work))              // Applications
        let traversal = bed.work.path + "/extracted/../../Applications/Fake.app"
        #expect(!RootSwap.validateStaged(traversal, workDirectory: bed.work))                       // ".."
        #expect(!RootSwap.validateStaged(bed.work.path + "//x/Fake.app", workDirectory: bed.work))  // boş bileşen
        let file = bed.work.appendingPathComponent("File.app")
        try Data().write(to: file)
        #expect(!RootSwap.validateStaged(file.path, workDirectory: bed.work))                       // klasör değil
        let notApp = bed.work.appendingPathComponent("Fake")
        try fm.createDirectory(at: notApp, withIntermediateDirectories: true)
        #expect(!RootSwap.validateStaged(notApp.path, workDirectory: bed.work))                     // .app değil
        let newline = bed.work.appendingPathComponent("Fa\nke.app")
        try fm.createDirectory(at: newline, withIntermediateDirectories: true)
        #expect(!RootSwap.validateStaged(newline.path, workDirectory: bed.work))                    // kontrol karakteri
        #expect(!RootSwap.validateStaged("extracted/Fake.app", workDirectory: bed.work))            // göreli
        #expect(!RootSwap.validateStaged(staged.path, workDirectory: URL(fileURLWithPath: "/")))   // kök çalışma klasörü
    }

    @Test func commandRejectsBeforeAnyPrompt() async throws {
        let bed = try Bed()
        defer { bed.cleanup() }
        let staged = try bed.stage()
        func request(installed: URL? = nil, staged s: URL? = nil, id: String = "test.tazele.fake",
                     version: String = "2", team t: String = team) -> RootSwap.Request {
            RootSwap.Request(installed: installed ?? URL(fileURLWithPath: "/Applications/Fake.app"), staged: s ?? staged,
                             workDirectory: bed.work, bundleID: id, version: version, team: t, cdhash: fakeHash, installedShortVersion: "1", installedVersion: "1")
        }
        // Geçici klasördeki "kurulu" uygulama /Applications değildir: biçimden reddedilir (dosya sistemine bakılmaz).
        let bad: [RootSwap.Request] = [
            request(installed: bed.installed),
            request(installed: URL(fileURLWithPath: "/Applications/Sub/Fake.app")),
            request(installed: URL(fileURLWithPath: "/Applications/../Fake.app")),
            request(installed: URL(fileURLWithPath: "/Applications/Fa\nke.app")),
        ]
        for r in bad {
            #expect(throws: PrivilegeError.self) { try RootSwap.command(for: r) }
            // Herkese açık giriş noktası da pencere açmadan reddeder.
            await #expect(throws: PrivilegeError.self) { try await PrivilegedRunner.runSwap(r, runner: CommandRunner()) }
        }
        // Hazırlanan yolda ".." gerçek yola çevrilmeden önce reddedilir.
        let sneaky = URL(fileURLWithPath: staged.deletingLastPathComponent().path + "/../" + staged.deletingLastPathComponent().lastPathComponent + "/Fake.app")
        #expect(throws: PrivilegeError.self) { try RootSwap.command(for: request(staged: sneaky)) }
    }

    @Test func argumentsArePositionalAndUnquoted() {
        let args = RootSwap.arguments(script: RootSwap.Script.production, installed: "/Applications/A B.app",
                                      staged: "/w/x'y/A B.app", bundleID: "a.b", version: "1", team: team, cdhash: fakeHash, installedShortVersion: "1", installedVersion: "1")
        #expect(args == ["/bin/zsh", "-f", "-p", "-c", RootSwap.Script.production, "tazele-swap",
                         "/Applications/A B.app", "/w/x'y/A B.app", "a.b", "1", team, fakeHash, "1", "1"])
        #expect(RootSwap.requirement(team: team) == "=anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\"")
    }

    // MARK: Betik metni

    @Test func productionScriptContainsEveryCheckAndNoTestSeam() {
        let s = RootSwap.Script.production
        for needle in [
            "tz_apps=/Applications", "tz_base=/private/var/tmp", "tz_uid=0", "tz_owner=root:wheel",
            "[ \"$(/usr/bin/id -u)\" = \"$tz_uid\" ] || tz_fail notroot 11",
            "/usr/bin/codesign --verify --deep --strict -R \"=anchor apple generic and certificate leaf[subject.OU] = \\\"$2\\\"\"",
            "/usr/bin/codesign -dv --verbose=2",
            "/usr/bin/mktemp -d \"$tz_base/tazele-swap.XXXXXXXX\"",
            "[ -O \"$tz_work\" ]",
            "/usr/bin/ditto --noacl \"$tz_staged\" \"$tz_new\"",
            "/usr/sbin/chown -R \"$tz_owner\" \"$tz_new\"",
            "/bin/chmod -R go-w,ug-s \"$tz_new\"",
            "[ ! -L \"$tz_inst\" ]", "/bin/realpath \"$tz_inst\"", "/bin/realpath \"$tz_staged\"",
            "*/../*", "_MASReceipt", "tz_is_team \"$tz_t_old\" && [ \"$tz_t_old\" = \"$tz_team\" ]",
            "[ \"$tz_t_new\" = \"$tz_team\" ]", "CFBundleIdentifier", "CFBundleVersion)\" = \"$tz_ver\"",
            "trap '' TERM INT HUP", "/bin/mv \"$tz_inst\" \"$tz_backup\"", "/bin/mv \"$tz_backup\" \"$tz_inst\"",
            "tz_hook() { :; }", "__TAZELE_SWAP__", "[ \"$(tz_cdhash \"$tz_new\")\" = \"$tz_cd\" ] || tz_fail cdhash 17",
            "tz_dev \"$tz_work\"", "tz_swap &", "trap '' TERM INT HUP PIPE", "[ \"$(tz_ino \"$tz_inst\")\" = \"$tz_ino_new\" ]",
        ] {
            #expect(s.contains(needle), "eksik: \(needle)")
        }
        // Doğrulama, değiştirmeden önce gelir.
        let verify = s.range(of: "tz_bg tz_verify")!.lowerBound, swap = s.range(of: "/bin/mv \"$tz_inst\" \"$tz_backup\"")!.lowerBound
        #expect(verify < swap)
        // Test kapısı, yeniden ayrıştırma ya da ortamdan okunan değer yok.
        for forbidden in ["TAZELE_TEST", "TazeleTestTeam", "eval", "source ", "${TAZELE", "sudo", "osascript"] {
            #expect(!s.contains(forbidden), "olmamalı: \(forbidden)")
        }
        // Gövde, test sürümüyle aynıdır; yalnızca başlık farklıdır.
        #expect(RootSwap.Script.testVariant().hasSuffix(RootSwap.Script.body))
        #expect(s == RootSwap.Script.productionHeader + RootSwap.Script.body)
    }

    /// Üretim betiği root değilse hiçbir şeye dokunmadan çıkar (gerçek /Applications argümanlarıyla bile).
    @Test(arguments: shells)
    func productionScriptRefusesWithoutRoot(shell: String) throws {
        try #require(getuid() != 0, "testler root olarak çalıştırılmamalı")
        let flags = shell == RootSwap.shell ? ["-f", "-p", "-c"] : ["-c"]
        let out = try output(shell, flags + [RootSwap.Script.production, "tazele-swap",
                                             "/Applications/TazeleYok.app", "/nonexistent/TazeleYok.app", "a.b", "2", team, fakeHash, "1.0", "1"])
        #expect(out.contains("__TAZELE_SWAP__ fail notroot"))
        #expect(!out.contains("step copy"))
        #expect(try run(shell, flags + [RootSwap.Script.production, "tazele-swap",
                                        "/Applications/TazeleYok.app", "/nonexistent/TazeleYok.app", "a.b", "2", team, fakeHash, "1.0", "1"]) == 11)
    }

    /// Aynısı authorizationServices yolunun zsh sarmalayıcısıyla (yetkisiz, soket üzerinden).
    @Test func productionCommandSurvivesZshWrapper() async throws {
        try #require(getuid() != 0)
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let command = RootSwap.arguments(script: RootSwap.Script.production, installed: "/Applications/X.app",
                                         staged: "/nonexistent/$(id)/X.app", bundleID: "a.b", version: "2", team: team, cdhash: fakeHash, installedShortVersion: "1", installedVersion: "1")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: RootScript.zsh)
        process.arguments = RootScript.zshArguments(nonce: "RS", command: command)
        let child = FileHandle(fileDescriptor: fds[1], closeOnDealloc: false)
        process.standardInput = child
        process.standardOutput = child
        process.standardError = FileHandle.nullDevice
        try process.run()
        close(fds[1])
        let channel = PrivilegedChannel(fd: fds[0])
        let lines = Lines()
        let parser = PrivilegedOutputParser(nonce: "RS", onLine: { lines.add($0) })
        await PrivilegedChannel.collect(channel, into: parser)
        channel.close()
        process.waitUntilExit()
        #expect(parser.exitStatus == 11)
        #expect(lines.all == ["__TAZELE_SWAP__ fail notroot"])
    }

    // MARK: Betiğin gerçek çalıştırılması (root olmadan, geçici klasörlerde)

    @Test(arguments: shells)
    func scriptSwapsAndHardensCopy(shell: String) throws {
        let bed = try Bed()
        defer { bed.cleanup() }
        let staged = try bed.stage()
        // Kullanıcının hazırlanan kopyaya eklediği tehlikeli izinler kopyada kalmamalı.
        let exe = staged.appendingPathComponent("Contents/MacOS/Fake").path
        #expect(chmod(exe, 0o4777) == 0)
        let data = staged.appendingPathComponent("Contents/Resources/data.txt").path
        #expect(chmod(data, 0o666) == 0)
        #expect(try run("/bin/chmod", ["+a", "everyone allow write", data]) == 0)

        let r = try runScript(shell: shell, bed: bed, args: [bed.installed.path, staged.path, "test.tazele.fake", "2", team, cdh(staged)])
        #expect(r.status == 0, "\(r.output)")
        #expect(r.output.contains("__TAZELE_SWAP__ ok"))
        #expect(version(bed.installed) == "2")
        #expect(try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", bed.installed.path]) == 0)
        let placedExe = bed.installed.appendingPathComponent("Contents/MacOS/Fake").path
        let placedData = bed.installed.appendingPathComponent("Contents/Resources/data.txt").path
        #expect(mode(placedExe) & 0o6022 == 0)       // setuid/setgid ve grup/diğer yazma yok
        #expect(mode(placedData) & 0o022 == 0)
        #expect(mode(bed.installed.path) == 0o755)
        #expect(!(try output("/bin/ls", ["-le", placedData])).contains("allow"))   // ACL yok
        #expect(RootSwap.isSymlink(bed.installed.appendingPathComponent("Contents/Resources/link.txt").path))
        #expect(entries(bed.base).isEmpty)           // root klasörü (yedek dahil) silindi
        #expect(version(staged) == "2")              // hazırlanan paket kopyalandı, taşınmadı
    }

    @Test(arguments: shells)
    func scriptVerificationFailuresLeaveAppUntouched(shell: String) throws {
        // (açıklama, kurulu ekip, hazırlama, argümanlar → beklenen çıkış kodu)
        struct Case { let name: String; let installedTeam: String?; let stage: (Bed) throws -> URL; let args: (Bed, URL) -> [String]; let status: Int32 }
        let std: (Bed, URL) -> [String] = { b, s in [b.installed.path, s.path, "test.tazele.fake", "2", team, cdh(s)] }
        let cases: [Case] = [
            Case(name: "ekip uyuşmuyor", installedTeam: team, stage: { try $0.stage(team: "ZZZZZ99999") }, args: std, status: 14),
            Case(name: "beklenen ekip kurulu olanla aynı değil", installedTeam: team, stage: { try $0.stage() },
                 args: { b, s in [b.installed.path, s.path, "test.tazele.fake", "2", "CCCCCCCCCC", cdh(s)] }, status: 14),
            Case(name: "kurulu uygulamada ekip yok", installedTeam: nil, stage: { try $0.stage() }, args: std, status: 14),
            Case(name: "paket kimliği uyuşmuyor", installedTeam: team, stage: { try $0.stage(id: "evil.other") }, args: std, status: 15),
            Case(name: "beklenen paket kimliği farklı", installedTeam: team, stage: { try $0.stage() },
                 args: { b, s in [b.installed.path, s.path, "evil.other", "2", team, cdh(s)] }, status: 15),
            Case(name: "sürüm beklenen değil (eskiye dönme)", installedTeam: team, stage: { try $0.stage(version: "1") }, args: std, status: 16),
            Case(name: "CDHash doğrulanan paketle aynı değil (doğrulamadan sonra değiştirilmiş)", installedTeam: team,
                 stage: { try $0.stage() }, args: { b, s in [b.installed.path, s.path, "test.tazele.fake", "2", team, fakeHash] }, status: 17),
            Case(name: "imzasız", installedTeam: team, stage: { try $0.stage(sign: false) }, args: std, status: 13),
            Case(name: "imzadan sonra değiştirilmiş", installedTeam: team, stage: { bed in
                let s = try bed.stage()
                try Data("kurcalandı".utf8).write(to: s.appendingPathComponent("Contents/Resources/data.txt"))
                return s
            }, args: std, status: 13),
        ]
        for c in cases {
            let bed = try Bed(installedTeam: c.installedTeam)
            defer { bed.cleanup() }
            let staged = try c.stage(bed)
            let r = try runScript(shell: shell, bed: bed, args: c.args(bed, staged))
            #expect(r.status == c.status, "\(c.name): \(r.output)")
            #expect(version(bed.installed) == "1", "\(c.name)")
            #expect(!r.output.contains("__TAZELE_SWAP__ ok"), "\(c.name)")
            #expect(!r.output.contains("step swap"), "\(c.name)")
            #expect(entries(bed.base).isEmpty, "\(c.name)")
        }
    }

    @Test(arguments: shells)
    func scriptRejectsChangedInstalledVersion(shell: String) throws {
        let bed = try Bed()
        defer { bed.cleanup() }
        let staged = try bed.stage()
        let plist = bed.installed.appendingPathComponent("Contents/Info.plist")
        let info = try #require(NSMutableDictionary(contentsOf: plist))
        info["CFBundleVersion"] = "3"
        #expect(info.write(to: plist, atomically: true))
        let result = try runScript(shell: shell, bed: bed, args: [bed.installed.path, staged.path, "test.tazele.fake", "2", team, cdh(staged)])
        #expect(result.status == 18)
        #expect(version(bed.installed) == "3")
    }

    @Test(arguments: shells)
    func scriptRejectsBadArguments(shell: String) throws {
        let bed = try Bed()
        defer { bed.cleanup() }
        let staged = try bed.stage()
        // Sembolik bağ olan kurulu yol (gerçek uygulama başka yerde).
        let elsewhere = bed.root.appendingPathComponent("elsewhere")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let real = try makeApp(in: elsewhere, name: "Linked", version: "1")
        let linked = bed.apps.appendingPathComponent("Linked.app")
        try fm.createSymbolicLink(at: linked, withDestinationURL: real)
        // İç içe uygulama.
        let sub = bed.apps.appendingPathComponent("Sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        let nested = try makeApp(in: sub, version: "1")
        // Sembolik bağ olan hazırlanan paket.
        let stagedLink = bed.work.appendingPathComponent("StagedLink.app")
        try fm.createSymbolicLink(at: stagedLink, withDestinationURL: staged)
        let i = bed.installed.path, s = staged.path, h = cdh(staged)
        let table: [[String]] = [
            [linked.path, s, "test.tazele.fake", "2", team, h],
            [nested.path, s, "test.tazele.fake", "2", team, h],
            [real.path, s, "test.tazele.fake", "2", team, h],
            [bed.apps.path + "/../Applications/Fake.app", s, "test.tazele.fake", "2", team, h],
            [bed.apps.path + "/Fa\nke.app", s, "test.tazele.fake", "2", team, h],
            [i, stagedLink.path, "test.tazele.fake", "2", team, h],
            [i, staged.deletingLastPathComponent().path, "test.tazele.fake", "2", team, h],
            [i, i, "test.tazele.fake", "2", team, h],
            [i, s.replacingOccurrences(of: "/work/", with: "/work/./"), "test.tazele.fake", "2", team, h],
            [i, "relative/Fake.app", "test.tazele.fake", "2", team, h],
            [i, s, "test.tazele.fake", "2", "abc", h],
            [i, s, "-x", "2", team, h],
            [i, s, "test.tazele.fake", "2;id", team, h],
            [i, s, "test.tazele.fake", "2", team],
            [i, s, "test.tazele.fake", "2", team, h, "fazla"],
            [i, s, "test.tazele.fake", "2", team, h.uppercased()],
            [i, s, "test.tazele.fake", "2", team, String(h.prefix(39))],
            [i, s, "test.tazele.fake", "2", team, h + ";id"],
        ]
        for args in table {
            let r = try runScript(shell: shell, bed: bed, args: args)
            #expect(r.status == 10, "\(args): \(r.output)")
            #expect(!r.output.contains("step copy"), "\(args)")
        }
        #expect(version(bed.installed) == "1" && version(real) == "1" && version(nested) == "1")
        #expect(RootSwap.isSymlink(linked.path))
        #expect(entries(bed.base).isEmpty)
    }

    @Test(arguments: shells)
    func scriptRestoresBackupWhenPlacementFails(shell: String) throws {
        let bed = try Bed()
        defer { bed.cleanup() }
        let staged = try bed.stage()
        let r = try runScript(shell: shell, bed: bed, args: [bed.installed.path, staged.path, "test.tazele.fake", "2", team, cdh(staged)],
                              hook: "remove-new")
        #expect(r.status == 20, "\(r.output)")
        #expect(r.output.contains("__TAZELE_SWAP__ restored"))
        #expect(version(bed.installed) == "1")
        #expect(try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", bed.installed.path]) == 0)
        #expect(entries(bed.base).isEmpty)
    }

    @Test(arguments: shells)
    func scriptKeepsBackupWhenRestoreIsImpossible(shell: String) throws {
        let bed = try Bed()
        defer { bed.cleanup() }
        let staged = try bed.stage()
        // Yedek alındıktan sonra hedefte bir dosya belirir (yarış): ne yeni paket ne yedek oraya taşınır.
        let r = try runScript(shell: shell, bed: bed, args: [bed.installed.path, staged.path, "test.tazele.fake", "2", team, cdh(staged)],
                              hook: "block-target")
        #expect(r.status == 21, "\(r.output)")
        let line = try #require(r.output.split(separator: "\n").first { $0.hasPrefix("__TAZELE_SWAP__ kept ") })
        let backup = URL(fileURLWithPath: String(line.dropFirst("__TAZELE_SWAP__ kept ".count)))
        #expect(backup.path.hasPrefix(bed.base.path + "/"))
        #expect(version(backup) == "1")                       // yedek silinmedi
        #expect(!RootSwap.isDirectory(bed.installed.path))    // hedefteki engel dosyasına dokunulmadı
    }

    /// Kritik bölümde gelen TERM yok sayılır: değiştirme yarıda kalmaz.
    @Test(arguments: shells)
    func scriptIgnoresTermDuringCriticalSection(shell: String) throws {
        let bed = try Bed()
        defer { bed.cleanup() }
        let staged = try bed.stage()
        let r = try runScript(shell: shell, bed: bed, args: [bed.installed.path, staged.path, "test.tazele.fake", "2", team, cdh(staged)],
                              hook: "term-self")
        #expect(r.status == 0, "\(r.output)")
        #expect(version(bed.installed) == "2")
        #expect(entries(bed.base).isEmpty)
    }

    /// Sarmalayıcının 2 sn sonraki KILL'i yalnızca ana kabuğa gider: alt kabuktaki değiştirme yine tamamlanır.
    @Test(arguments: shells)
    func scriptSwapSurvivesKillOfParentShell(shell: String) async throws {
        let bed = try Bed()
        defer { bed.cleanup() }
        let staged = try bed.stage()
        let r = try runScript(shell: shell, bed: bed, args: [bed.installed.path, staged.path, "test.tazele.fake", "2", team, cdh(staged)],
                              hook: "kill-parent")
        #expect(r.status == 9 || r.status == 137, "\(r.status) \(r.output)")   // ana kabuk öldürüldü
        // Çıktı borusu alt kabuk bitince kapanır; yine de kısa bir süre beklenir.
        let start = Date()
        while version(bed.installed) != "2" || !entries(bed.base).isEmpty, Date().timeIntervalSince(start) < 10 {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(version(bed.installed) == "2")
        #expect(entries(bed.base).isEmpty)
    }

    /// Doğrulama sırasında TERM (Tazele'de iptal): uzun süren alt süreç durdurulur, root klasörü silinir,
    /// kurulu uygulamaya dokunulmaz, çıkış kodu 143.
    @Test(arguments: shells)
    func scriptCancelsCleanlyBeforeCriticalSection(shell: String) async throws {
        let bed = try Bed()
        defer { bed.cleanup() }
        let staged = try bed.stage()
        let flags = shell == RootSwap.shell ? ["-f", "-p", "-c"] : ["-c"]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = flags + [RootSwap.Script.testVariant(), "tazele-swap", bed.installed.path, staged.path, "test.tazele.fake", "2", team, cdh(staged), "1.0", "1"]
        p.environment = ["PATH": "/usr/bin:/bin", "TAZELE_TEST_APPS": bed.apps.path, "TAZELE_TEST_BASE": bed.base.path,
                         "TAZELE_TEST_HOOK": "slow-verify"]
        let out = bed.root.appendingPathComponent("out.log")
        try Data().write(to: out)
        let handle = try FileHandle(forWritingTo: out)
        p.standardOutput = handle
        p.standardError = handle
        try p.run()
        let start = Date()
        while !(String(decoding: (try? Data(contentsOf: out)) ?? Data(), as: UTF8.self)).contains("step verify"),
              Date().timeIntervalSince(start) < 20 {
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(entries(bed.base).count == 1)   // root kopyası var
        p.terminate()
        p.waitUntilExit()
        try handle.close()
        #expect(Date().timeIntervalSince(start) < 15)
        #expect(p.terminationStatus == 143)
        #expect(String(decoding: try Data(contentsOf: out), as: UTF8.self).contains("__TAZELE_SWAP__ fail cancelled"))
        #expect(entries(bed.base).isEmpty)
        #expect(version(bed.installed) == "1")
    }

    // MARK: Kurulabilirlik (yazılamayan uygulamalar)

    @Test func eligibilityForNonWritableApps() {
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let sig = Data(repeating: 7, count: 64).base64EncodedString()
        func item(_ path: String, id: String = "io.example.app") -> OutdatedItem {
            OutdatedItem(source: .sparkle, name: "X", installed: "1", latest: "2", path: path,
                         download: SparkleDownload(url: URL(string: "https://example.invalid/X.zip")!, edSignature: sig, length: nil,
                                                   publicEDKey: key, bundleID: id))
        }
        func probe(writable: Bool = false, team: String? = team, symlinks: Set<String> = [], mas: Bool = false) -> SparkleInstaller.FileProbe {
            var p = SparkleInstaller.FileProbe(
                exists: { $0.hasSuffix("_MASReceipt") ? mas : true },
                isSymlink: { symlinks.contains($0) },
                isWritable: { _ in writable })
            p.teamIdentifier = { _ in team }
            p.realPath = { $0 }   // gerçek /Applications'a bakılmaz
            return p
        }
        func reason(_ i: OutdatedItem, _ p: SparkleInstaller.FileProbe) -> SparkleInstaller.Rejection? {
            SparkleInstaller.rejection(for: i, probe: p, ownBundleID: "app.tazele")
        }
        let path = "/Applications/Tailscale.app"
        #expect(reason(item(path), probe()) == nil)
        #expect(SparkleInstaller.requiresAdministrator(item(path), probe: probe(), ownBundleID: "app.tazele"))
        // Yazılabilirse yönetici gerekmez (eski yol aynen).
        #expect(reason(item(path), probe(writable: true)) == nil)
        #expect(!SparkleInstaller.requiresAdministrator(item(path), probe: probe(writable: true), ownBundleID: "app.tazele"))
        #expect(reason(item("/Users/me/Apps/X.app"), probe(writable: true, team: nil)) == nil)
        // Ekip kimliği yok (ad-hoc / imzasız) ya da biçimsiz.
        #expect(reason(item(path), probe(team: nil)) == .unsignedRootApp)
        #expect(reason(item(path), probe(team: "not set")) == .unsignedRootApp)
        #expect(!SparkleInstaller.requiresAdministrator(item(path), probe: probe(team: nil), ownBundleID: "app.tazele"))
        // Yalnızca doğrudan /Applications.
        #expect(reason(item("/Applications/Sub/X.app"), probe()) == .notWritable)
        #expect(reason(item("/Users/me/Applications/X.app"), probe()) == .notWritable)
        #expect(reason(item("/opt/X.app"), probe()) == .notWritable)
        #expect(reason(item("/Applications/../Applications/X.app"), probe()) == .notWritable)
        #expect(reason(item("/Applications/.X.app"), probe()) == .notWritable)
        // Sembolik bağ: uygulama ya da /Applications.
        #expect(reason(item(path), probe(symlinks: [path])) == .symlink)
        #expect(reason(item(path), probe(symlinks: ["/Applications"])) == .notWritable)
        var resolving = probe()
        resolving.realPath = { $0 == path ? "/Volumes/Other/Tailscale.app" : $0 }
        #expect(reason(item(path), resolving) == .notWritable)
        // App Store ve Tazele'nin kendisi hâlâ reddedilir.
        #expect(reason(item(path), probe(mas: true)) == .macAppStore)
        #expect(reason(item(path, id: "app.tazele"), probe()) == .badBundleID)
    }

    @Test func liveSigningTeamReader() throws {
        let dir = try realTemp("team")
        defer { try? fm.removeItem(at: dir) }
        let adhoc = try makeApp(in: dir, version: "1")
        #expect(SparkleInstaller.signingTeam(atPath: adhoc.path) == nil)        // ad-hoc: ekip yok
        let unsigned = try makeApp(in: dir, name: "Unsigned", version: "1", sign: false)
        #expect(SparkleInstaller.signingTeam(atPath: unsigned.path) == nil)
        #expect(SparkleInstaller.signingTeam(atPath: dir.appendingPathComponent("Yok.app").path) == nil)
    }

    // MARK: Uçtan uca (yönetici yolu; root adımı test betiğiyle, root olmadan)

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var swaps = 0, relaunches = 0
        func swap() { lock.withLock { swaps += 1 } }
        func relaunch() { lock.withLock { relaunches += 1 } }
        var swapCount: Int { lock.withLock { swaps } }
        var relaunchCount: Int { lock.withLock { relaunches } }
    }

    private struct EndToEnd {
        let bed: Bed
        let keys = Curve25519.Signing.PrivateKey()
        var publicB64: String { keys.publicKey.rawRepresentation.base64EncodedString() }
        let installed: URL
        init() throws {
            bed = try Bed()
            // Kurulu sürüm Sparkle anahtarıyla yeniden oluşturulur.
            try fm.removeItem(at: bed.installed)
            installed = try makeApp(in: bed.apps, version: "1", edKey: keys.publicKey.rawRepresentation.base64EncodedString())
        }
        func archive(team t: String = team) throws -> URL {
            let src = bed.root.appendingPathComponent("src-\(UUID().uuidString.prefix(6))")
            try fm.createDirectory(at: src, withIntermediateDirectories: true)
            let app = try makeApp(in: src, version: "2", team: t, edKey: publicB64)
            let out = bed.root.appendingPathComponent("Fake-\(UUID().uuidString.prefix(6)).zip")
            #expect(try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, out.path]) == 0)
            return out
        }
        func item(_ archive: URL, signature: String? = nil) throws -> OutdatedItem {
            let sig = try signature ?? keys.signature(for: Data(contentsOf: archive)).base64EncodedString()
            return OutdatedItem(source: .sparkle, name: "Fake", installed: "1", latest: "2", path: installed.path,
                                download: SparkleDownload(url: URL(string: "https://example.invalid/Fake.zip")!, edSignature: sig,
                                                          length: nil, publicEDKey: publicB64, bundleID: "test.tazele.fake"))
        }
        var probe: SparkleInstaller.FileProbe {
            var p = SparkleInstaller.FileProbe.live
            p.isWritable = { _ in false }
            p.applicationsDirectory = bed.apps.path
            p.teamIdentifier = { path in
                (NSDictionary(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["TazeleTestTeam"] as? String
            }
            return p
        }
        func environment(_ archive: URL, counter: Counter, running: Bool = false, anchorOK: Bool = true,
                         swap: (@Sendable (RootSwap.Request, @escaping @Sendable (String) -> Void) async throws -> CommandResult)? = nil)
            -> SparkleInstaller.Environment {
            let bed = self.bed
            var env = SparkleInstaller.Environment(
                fetch: { _, dir in
                    let dest = dir.appendingPathComponent(archive.lastPathComponent)
                    try FileManager.default.copyItem(at: archive, to: dest)
                    return dest
                },
                isRunning: { _ in running },
                terminate: { _, _ in true },
                relaunch: { _ in counter.relaunch(); return true },
                makeWorkDirectory: { app in
                    try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
                })
            env.codeTeam = { app in
                (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["TazeleTestTeam"] as? String
            }
            env.verifyTeamAnchor = { _, _ in anchorOK }
            env.privilegedSwap = swap ?? { request, onLine in
                counter.swap()
                let staged = RootSwap.canonicalParent(of: request.staged)
                let r = try runScript(shell: RootSwap.shell, bed: bed,
                                      args: [request.installed.path, staged, request.bundleID, request.version, request.team, request.cdhash])
                r.output.split(separator: "\n").forEach { onLine(String($0)) }
                if r.status != 0 { onLine("durum \(r.status): \(request.installed.path) \(staged) \(r.output)") }
                return CommandResult(status: r.status, output: Data(r.output.utf8), timedOut: false)
            }
            return env
        }
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        func add(_ s: String) { lock.withLock { list.append(s) } }
        var all: [String] { lock.withLock { list } }
    }

    @Test func endToEndAdministratorInstall() async throws {
        let e = try EndToEnd()
        defer { e.bed.cleanup() }
        let archive = try e.archive()
        let counter = Counter(), lines = Lines()
        do {
            try await SparkleInstaller.install(try e.item(archive), onLine: { lines.add($0) },
                                               environment: e.environment(archive, counter: counter, running: true), probe: e.probe)
        } catch {
            Issue.record("\(error): \(lines.all)")
        }
        #expect(version(e.installed) == "2")
        #expect(counter.swapCount == 1 && counter.relaunchCount == 1)
        #expect(!lines.all.contains { $0.hasPrefix("__TAZELE_SWAP__") })   // işaret satırları günlüğe çevrildi
        #expect(entries(e.bed.base).isEmpty)
    }

    @Test func badDownloadNeverReachesThePrompt() async throws {
        let e = try EndToEnd()
        defer { e.bed.cleanup() }
        let counter = Counter()
        // Kurcalanmış arşiv.
        let archive = try e.archive()
        let sig = try e.keys.signature(for: Data(contentsOf: archive)).base64EncodedString()
        let h = try FileHandle(forWritingTo: archive); try h.seekToEnd(); try h.write(contentsOf: Data([0])); try h.close()
        await #expect(throws: SparkleInstallError.signatureInvalid) {
            try await SparkleInstaller.install(try e.item(archive, signature: sig), onLine: { _ in },
                                               environment: e.environment(archive, counter: counter), probe: e.probe)
        }
        // Başka ekip.
        let other = try e.archive(team: "ZZZZZ99999")
        await #expect(throws: SparkleInstallError.teamMismatch) {
            try await SparkleInstaller.install(try e.item(other), onLine: { _ in },
                                               environment: e.environment(other, counter: counter), probe: e.probe)
        }
        // Apple köküne bağlanmayan imza (ör. kendinden imzalı sertifikayla taklit edilen ekip).
        let good = try e.archive()
        await #expect(throws: SparkleInstallError.codeSignatureInvalid) {
            try await SparkleInstaller.install(try e.item(good), onLine: { _ in },
                                               environment: e.environment(good, counter: counter, anchorOK: false), probe: e.probe)
        }
        #expect(counter.swapCount == 0)
        #expect(version(e.installed) == "1")
    }

    @Test func deniedPromptRelaunchesAndKeepsOldApp() async throws {
        let e = try EndToEnd()
        defer { e.bed.cleanup() }
        let archive = try e.archive()
        let counter = Counter()
        let env = e.environment(archive, counter: counter, running: true, swap: { _, _ in
            counter.swap(); throw PrivilegeError.canceled
        })
        await #expect(throws: PrivilegeError.canceled) {
            try await SparkleInstaller.install(try e.item(archive), onLine: { _ in }, environment: env, probe: e.probe)
        }
        #expect(counter.swapCount == 1 && counter.relaunchCount == 1)
        #expect(version(e.installed) == "1")
    }

    @Test func rootSideFailuresMapToErrors() async throws {
        let cases: [(Int32, SparkleInstallError)] = [(13, .codeSignatureInvalid), (14, .teamMismatch), (15, .bundleMismatch),
                                                     (16, .bundleMismatch), (17, .codeSignatureInvalid), (20, .swapFailed), (21, .swapFailed), (10, .swapFailed),
                                                     (143, .cancelled)]
        for (status, expected) in cases {
            let e = try EndToEnd()
            defer { e.bed.cleanup() }
            let archive = try e.archive()
            let counter = Counter()
            let env = e.environment(archive, counter: counter, running: true, swap: { _, onLine in
                counter.swap(); onLine("__TAZELE_SWAP__ fail x")
                return CommandResult(status: status, output: Data(), timedOut: false)
            })
            await #expect(throws: expected) {
                try await SparkleInstaller.install(try e.item(archive), onLine: { _ in }, environment: env, probe: e.probe)
            }
            #expect(counter.relaunchCount == 1, "\(status)")
            #expect(version(e.installed) == "1")
        }
    }

    @Test func outcomeCodes() {
        #expect(RootSwap.Outcome(status: 0) == .success)
        #expect(RootSwap.Outcome(status: 11) == .notRoot)
        #expect(RootSwap.Outcome(status: 21) == .backupKept)
        #expect(RootSwap.Outcome(status: 137) == .unknown(137))
        let lines = Lines()
        let t = RootSwap.LineTranslator(onLine: { lines.add($0) })
        for l in ["__TAZELE_SWAP__ step copy", "codesign: bir hata", "__TAZELE_SWAP__ fail team", "x __TAZELE_SWAP__ ok"] { t.feed(l) }
        #expect(!t.sawOK)
        t.feed("__TAZELE_SWAP__ ok")
        #expect(t.sawOK)
        #expect(lines.all.count == 3 && lines.all.contains("codesign: bir hata") && lines.all.contains("x __TAZELE_SWAP__ ok"))
    }
}
