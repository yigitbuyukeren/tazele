import Foundation
import Testing
@testable import TazeleCore

@Suite struct PkgAppsTests {
    /// formulae.brew.sh/api/cask.json kayıtlarından kısaltılmış örnekler (2026-10-30).
    static let caskJSON = """
    [
      {"token":"cloudflare-warp","version":"2026.8.2115.0","auto_updates":true,"homepage":"https://cloudflarewarp.com/",
       "depends_on":{"macos":{">=":["14"]}},
       "artifacts":[{"uninstall":[{"launchctl":["com.cloudflare.1dot1dot1dot1.macos.warp.daemon"],
                                   "quit":"com.cloudflare.1dot1dot1dot1.macos","pkgutil":"com.cloudflare.1dot1dot1dot1.macos",
                                   "delete":["/usr/local/bin/warp-cli"]}]},
                    {"pkg":["Cloudflare_WARP_2026.8.2115.0.pkg"]},{"zap":[{"trash":["~/x"]}]}]},
      {"token":"cloudflare-warp@beta","version":"2026.9.1555.1","auto_updates":true,
       "depends_on":{"macos":{">=":["15"]}},
       "artifacts":[{"uninstall":[{"quit":"com.cloudflare.1dot1dot1dot1.macos","pkgutil":"com.cloudflare.1dot1dot1dot1.macos"}]},
                    {"pkg":["Cloudflare_WARP_2026.9.1555.1.pkg"]}]},
      {"token":"tailscale-app","version":"1.104.4","auto_updates":true,"homepage":"https://tailscale.com/",
       "depends_on":{"macos":{">=":["13"]}},
       "artifacts":[{"uninstall":[{"quit":"io.tailscale.ipn.macsys","login_item":"Tailscale","pkgutil":"com.tailscale.ipn.macsys"}]},
                    {"pkg":["Tailscale-1.104.4-macos.pkg"]}]},
      {"token":"acrobat-reader","version":"25.001.20000","artifacts":[{"pkg":["x.pkg"]},
       {"uninstall":[{"pkgutil":["com.adobe.acrobat.DC.reader.*","com.adobe.armdc.app.pkg"],"quit":["com.adobe.Reader"]}]}]},
      {"token":"broad-vendor","version":"9.9","artifacts":[{"uninstall":[{"pkgutil":"com.microsoft.*"}]}]},
      {"token":"regexy","version":"9.9","artifacts":[{"uninstall":[{"pkgutil":"org.netbeans.ide.*|glassfish.*"}]}]},
      {"token":"quoted","version":"3.0","artifacts":[{"uninstall":[{"pkgutil":"'org.distroav.distroav'"}]}]},
      {"token":"twin-a","version":"5.0","artifacts":[{"uninstall":[{"pkgutil":"com.twin.pkg","quit":"com.twin.app"}]}]},
      {"token":"twin-b","version":"5.1","artifacts":[{"uninstall":[{"pkgutil":"com.twin.pkg","quit":"com.other"}]}]},
      {"token":"twin-c","version":"5.2","artifacts":[{"uninstall":[{"pkgutil":"com.twin2.pkg"}]}]},
      {"token":"twin-d","version":"5.3","artifacts":[{"uninstall":[{"pkgutil":"com.twin2.pkg"}]}]},
      {"token":"named","version":"2.0,100","artifacts":[{"app":["Named.app",{"target":"Named Pro.app"}]}]},
      {"token":"rolling","version":"latest","artifacts":[{"uninstall":[{"pkgutil":"com.rolling.pkg"}]}]},
      {"token":"future","version":"7.0","depends_on":{"macos":{">=":["99"]}},"artifacts":[{"uninstall":[{"pkgutil":"com.future.pkg"}]}]},
      {"token":"odd","version":5,"artifacts":[{"uninstall":"x"},"y",[1],{"uninstall":[{"pkgutil":[1,"com.odd.pkg"]}]}]},
      {"name":["no token"]}
    ]
    """

    static func app(_ name: String, _ version: String, bundleID: String = "", folder: String? = nil,
                    feed: URL? = nil, mas: Bool = false, build: String = "") -> SparkleApp {
        SparkleApp(name: name, path: "/Applications/\(folder ?? name).app", bundleID: bundleID, shortVersion: version,
                   bundleVersion: build, feedURL: feed, isMacAppStore: mas)
    }

    static let casks = PkgApps.parseCasks(Data(caskJSON.utf8))
    static let macOS27 = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
    static let warp = app("Cloudflare WARP", "2026.6.822.0", bundleID: "com.cloudflare.1dot1dot1dot1.macos", build: "20269006.822")
    static let tailscale = app("Tailscale", "1.96.5", bundleID: "io.tailscale.ipn.macsys", build: "101.96.5")

    // MARK: - Ayrıştırma

    @Test func parsesCasksTolerantly() {
        let byToken = Dictionary(uniqueKeysWithValues: Self.casks.map { ($0.token, $0) })
        #expect(Self.casks.count == 15)   // belirteci olmayan kayıt atlanır
        #expect(byToken["cloudflare-warp"] == PkgCask(
            token: "cloudflare-warp", version: "2026.8.2115.0", pkgutilIDs: ["com.cloudflare.1dot1dot1dot1.macos"],
            appNames: [], bundleIDs: ["com.cloudflare.1dot1dot1dot1.macos"], autoUpdates: true, dependsMacOS: ">= 14",
            homepage: "https://cloudflarewarp.com/"))
        #expect(byToken["acrobat-reader"]?.pkgutilIDs == ["com.adobe.acrobat.DC.reader.*", "com.adobe.armdc.app.pkg"])
        #expect(byToken["acrobat-reader"]?.bundleIDs == ["com.adobe.Reader"])
        #expect(byToken["named"]?.appNames == ["Named Pro.app"])
        #expect(byToken["odd"]?.version == "" && byToken["odd"]?.pkgutilIDs == ["com.odd.pkg"])
    }

    @Test func parsesInstalledInfoShapeAndGarbage() {
        let text = "Warning: x\n{\"casks\":[{\"token\":\"t\",\"version\":\"1\",\"artifacts\":[{\"uninstall\":[{\"pkgutil\":\"a.b.c\"}]}]}]}"
        #expect(PkgApps.parseCasks(Data(text.utf8)).map(\.pkgutilIDs) == [["a.b.c"]])
        #expect(PkgApps.parseCasks(Data()).isEmpty)
        #expect(PkgApps.parseCasks(Data("nope".utf8)).isEmpty)
    }

    @Test func parsesPkgutilOutput() {
        let info = """
        volume: /
        path: /Applications/Foo.app

        pkgid: com.foo.app.pkg
        pkg-version: 1.2.3
        install-time: 1700000000
        uid: 0

        pkgid: com.foo.helper
        pkgid: com.foo.app.pkg
        """
        #expect(PkgApps.parsePkgutilFileInfo(info) == ["com.foo.app.pkg", "com.foo.helper"])
        // Makbuzu dosya dizininde olmayan uygulama (WARP ve Tailscale'de görülen hâl).
        #expect(PkgApps.parsePkgutilFileInfo("volume: /\npath: /Applications/Tailscale.app\n").isEmpty)
        #expect(PkgApps.parsePkgList("com.apple.pkg.X\n\ncom.tailscale.ipn.macsys\nNo receipt for x\n")
                == ["com.apple.pkg.X", "com.tailscale.ipn.macsys"])
    }

    @Test func receiptLocationGivesAppPaths() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>install-location</key><string>Applications/Tailscale.app</string>
        <key>pkg-version</key><string>1.96.5</string>
        <key>pkgid</key><string>com.tailscale.ipn.macsys</string>
        <key>volume</key><string>/</string>
        </dict></plist>
        """
        let info = try #require(PkgApps.parsePkgInfo(Data(plist.utf8)))
        #expect(info.volume == "/" && info.location == "Applications/Tailscale.app")
        #expect(PkgApps.appPaths(volume: info.volume, location: info.location, dirs: []) == ["/Applications/Tailscale.app"])
        // WARP: kurulum yeri "Applications", `.app` üst düzey klasörlerden okunur.
        let dirs = ["Cloudflare WARP.app", "Cloudflare WARP.app/Contents", "Helper.app/Contents", "Library"]
        #expect(PkgApps.appPaths(volume: "/", location: "Applications", dirs: dirs) == ["/Applications/Cloudflare WARP.app"])
        #expect(PkgApps.appPaths(volume: "/", location: "", dirs: ["Tool.app"]) == ["/Tool.app"])
        #expect(PkgApps.parsePkgInfo(Data("x".utf8)) == nil)
    }

    // MARK: - Eşleştirme

    @Test func matchesByReceiptAndPrefersCanonicalToken() {
        // WARP: iki cask aynı makbuzu sahiplenir; uygulama adının cask adı biçimi `cloudflare-warp` seçilir.
        #expect(PkgApps.match(app: Self.warp, pkgIDs: ["com.cloudflare.1dot1dot1dot1.macos"], casks: Self.casks)?.token
                == "cloudflare-warp")
        // Tailscale: `.app` adı ile cask adı farklı (tailscale-app), makbuz tek eşleşme verir.
        #expect(PkgApps.match(app: Self.tailscale, pkgIDs: ["com.tailscale.ipn.macsys"], casks: Self.casks)?.token
                == "tailscale-app")
        // Makbuz yoksa ad tahmini yapılmaz.
        #expect(PkgApps.match(app: Self.tailscale, pkgIDs: [], casks: Self.casks) == nil)
    }

    @Test func ambiguousReceiptUsesBundleHintOrSkips() {
        let a = Self.app("Twin", "1.0", bundleID: "com.twin.app")
        #expect(PkgApps.match(app: a, pkgIDs: ["com.twin.pkg"], casks: Self.casks)?.token == "twin-a")
        let b = Self.app("Twin", "1.0", bundleID: "com.unknown")
        #expect(PkgApps.match(app: b, pkgIDs: ["com.twin.pkg"], casks: Self.casks) == nil)
        let c = Self.app("Twin Two", "1.0", bundleID: "com.twin2.app")
        #expect(PkgApps.match(app: c, pkgIDs: ["com.twin2.pkg"], casks: Self.casks) == nil)
    }

    @Test func fallsBackToAppNameOnlyExactly() {
        #expect(PkgApps.match(app: Self.app("Named Pro", "1.0"), pkgIDs: [], casks: Self.casks)?.token == "named")
        #expect(PkgApps.match(app: Self.app("Named", "1.0"), pkgIDs: [], casks: Self.casks) == nil)
        // Klasör adı görünen addan farklı olabilir.
        #expect(PkgApps.match(app: Self.app("Named", "1.0", folder: "Named Pro"), pkgIDs: [], casks: Self.casks)?.token == "named")
        // Makbuz bir şeyle eşleşmezse ada geçilir.
        #expect(PkgApps.match(app: Self.app("Named Pro", "1.0"), pkgIDs: ["com.nothing"], casks: Self.casks)?.token == "named")
    }

    @Test func pkgutilPatterns() {
        #expect(PkgApps.pkgID("com.cloudflare.1dot1dot1dot1.macos", matches: "com.cloudflare.1dot1dot1dot1.macos"))
        #expect(PkgApps.pkgID("com.Tailscale.ipn.macsys", matches: "com.tailscale.ipn.macsys"))
        #expect(!PkgApps.pkgID("com.tailscale.ipn.macsys.extra", matches: "com.tailscale.ipn.macsys"))
        #expect(PkgApps.pkgID("com.adobe.acrobat.DC.reader.app.pkg.MUI", matches: "com.adobe.acrobat.DC.reader.*"))
        #expect(!PkgApps.pkgID("com.adobe.acrobat.DC.viewer", matches: "com.adobe.acrobat.DC.reader.*"))
        #expect(PkgApps.pkgID("org.r-project.R.fw.pkg", matches: "org.r-project*"))
        #expect(PkgApps.pkgID("com.microsoft.dotnet.sdk.10.0.arm64", matches: "com.microsoft.dotnet.*10.0*arm64"))
        // Üretici genelindeki ve düzenli ifade biçimli desenler güvenli değil.
        #expect(!PkgApps.pkgID("com.microsoft.package.Microsoft_Word.app", matches: "com.microsoft.*"))
        #expect(!PkgApps.pkgID("org.netbeans.ide.base", matches: "org.netbeans.ide.*|glassfish.*"))
        #expect(!PkgApps.pkgID("anything", matches: "*"))
        #expect(PkgApps.pkgID("org.distroav.distroav", matches: "'org.distroav.distroav'"))
        #expect(PkgApps.match(app: Self.app("Word", "1"), pkgIDs: ["com.microsoft.package.Word"], casks: Self.casks) == nil)
    }

    // MARK: - Sürüm karşılaştırma

    @Test func reportsOnlyStrictlyNewerCompatibleVersions() {
        let apps = [
            Self.warp, Self.tailscale,
            Self.app("Current", "1.104.4", bundleID: "x.current", folder: "Current"),
            Self.app("Rolling", "1.0"),
            Self.app("Future", "1.0"),
            Self.app("Named Pro", "2.1"),   // kurulu sürüm daha yeni
        ]
        let ids = [
            Self.warp.path: ["com.cloudflare.1dot1dot1dot1.macos"],
            Self.tailscale.path: ["com.tailscale.ipn.macsys"],
            "/Applications/Current.app": ["com.tailscale.ipn.macsys"],
            "/Applications/Rolling.app": ["com.rolling.pkg"],
            "/Applications/Future.app": ["com.future.pkg"],
        ]
        let items = PkgApps.updates(apps: apps, pkgIDs: ids, casks: Self.casks, system: Self.macOS27)
        #expect(items.map(\.name) == ["Cloudflare WARP", "Tailscale"])
        #expect(items[0] == OutdatedItem(source: .sparkle, name: "Cloudflare WARP", installed: "2026.6.822.0",
                                         latest: "2026.8.2115.0", path: "/Applications/Cloudflare WARP.app"))
        #expect(items[1].latest == "1.104.4" && items[1].installed == "1.96.5" && items[1].caskToken == nil)
        // macOS 13'te WARP cask'i (>= 14) önerilmez.
        let old = OperatingSystemVersion(majorVersion: 13, minorVersion: 6, patchVersion: 0)
        #expect(PkgApps.updates(apps: [Self.warp], pkgIDs: ids, casks: Self.casks, system: old).isEmpty)
        // Virgülden sonrası (derleme numarası) karşılaştırmaya girmez.
        #expect(PkgApps.updates(apps: [Self.app("Named Pro", "1.9")], pkgIDs: [:], casks: Self.casks, system: Self.macOS27)
                    .first?.latest == "2.0")
    }

    // MARK: - Üretici kaynağı

    /// downloads.cloudflareclient.com/v1/update/sparkle/macos/ga yanıtından kısaltılmış (2026-10-30).
    static let warpAppcast = """
    <?xml version="1.0" encoding="utf-8"?><rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
    <title>Cloudflare WARP macOS Release</title>
    <item><title>Version 2026.8.2115.0</title><sparkle:version>20269008.2115</sparkle:version>
    <sparkle:shortVersionString>2026.8.2115.0</sparkle:shortVersionString>
    <enclosure sparkle:version="20269008.2115" url="https://downloads.cloudflareclient.com/v1/download/macos/version/2026.8.2115.0/Cloudflare_WARP_2026.8.2115.0.pkg" type="application/octet-stream"></enclosure></item>
    <item><title>Version 2026.8.2110.0</title><sparkle:version>20269008.2110</sparkle:version>
    <sparkle:shortVersionString>2026.8.2110.0</sparkle:shortVersionString></item>
    </channel></rss>
    """

    /// pkgs.tailscale.com/stable/appcast.xml yanıtı (2026-10-30).
    static let tailscaleAppcast = """
    <?xml version="1.0" standalone="yes"?>
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><title>Tailscale</title>
    <item><title>1.104.4</title><sparkle:version>101.104.4</sparkle:version>
    <sparkle:shortVersionString>1.104.4</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>13.5</sparkle:minimumSystemVersion>
    <enclosure url="Tailscale-1.104.4-macos.zip" type="application/octet-stream"/></item>
    </channel></rss>
    """

    @Test func vendorTableAndSampleAppcasts() throws {
        let warpItems = Sparkle.parseAppcast(Data(Self.warpAppcast.utf8))
        let tsItems = Sparkle.parseAppcast(Data(Self.tailscaleAppcast.utf8))
        #expect(Sparkle.outdated(app: Self.warp, items: warpItems)?.latest == "2026.8.2115.0")
        #expect(Sparkle.outdated(app: Self.tailscale, items: tsItems)?.latest == "1.104.4")
        #expect(PkgApps.vendorSources[Self.warp.bundleID] != nil)
        #expect(PkgApps.vendorSources[Self.tailscale.bundleID] != nil)
        // App Store sürümü (io.tailscale.ipn.macos) zaten App Store'dan denetlenir; tabloda yok.
        #expect(PkgApps.vendorSources["io.tailscale.ipn.macos"] == nil)
    }

    @Test func vendorFirstThenCasksWhenVendorUnreadable() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tz-pkg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Ad eşleşmesiyle bulunabilecek bir uygulama da cask listesine konur; ağ kullanılmaz (önbellek taze).
        try Data(Self.caskJSON.utf8).write(to: dir.appendingPathComponent("cask.json"))
        let warpFeed = Data(Self.warpAppcast.utf8)
        let apps = [
            Self.warp,                                   // üretici kaynağı okunur
            Self.tailscale,                              // üretici kaynağı okunamaz; sonuç bu Mac'teki makbuzlara bağlı, denetlenmez
            Self.app("Named Pro", "1.0", bundleID: "x.named"),
            Self.app("Named Pro", "1.0", bundleID: "x.named", feed: URL(string: "https://e.com/a.xml")),
            Self.app("Named Pro", "1.0", bundleID: "x.named", mas: true),
        ]
        let items = await PkgApps.updates(apps: apps, cacheDirectory: dir, runner: CommandRunner(), now: Date(),
                                          fetchAppcast: { url in
            url.host() == "downloads.cloudflareclient.com" ? Sparkle.parseAppcast(warpFeed) : []
        })
        let byName = Dictionary(items.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(byName["Cloudflare WARP"]?.latest == "2026.8.2115.0")
        #expect(byName["Named Pro"]?.latest == "2.0")
        #expect(items.filter { $0.name == "Named Pro" }.count == 1)
    }

    @Test func vendorUpToDateIsNotOverriddenByCask() async {
        let current = Self.app("Cloudflare WARP", "2026.8.2115.0", bundleID: "com.cloudflare.1dot1dot1dot1.macos",
                               build: "20269008.2115")
        let feed = Data(Self.warpAppcast.utf8)
        let items = await PkgApps.updates(apps: [current], cacheDirectory: URL(fileURLWithPath: "/nonexistent-\(UUID())"),
                                          runner: CommandRunner(), now: Date(), fetchAppcast: { _ in Sparkle.parseAppcast(feed) })
        #expect(items.isEmpty)
    }

    @Test func noCandidatesMeansNoWork() async {
        let items = await PkgApps.updates(apps: [Self.app("X", "1", feed: URL(string: "https://e.com"))],
                                          runner: CommandRunner())
        #expect(items.isEmpty)
    }
}
