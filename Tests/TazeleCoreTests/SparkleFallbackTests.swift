import Foundation
import Testing
@testable import TazeleCore

@Suite struct SparkleFallbackTests {
    static let apiJSON = """
    [
      {"token":"chatgpt","name":["ChatGPT"],"version":"26.1027.30824","auto_updates":true,
       "depends_on":{"macos":{">=":["13"]}},
       "artifacts":[{"app":["ChatGPT.app"],"target":"/Applications/ChatGPT.app"},{"zap":[{"trash":["~/x"]}]}]},
      {"token":"thorium","version":"130.0,6723","artifacts":[{"app":["Thorium.app",{"target":"Thorium Browser.app"}]}]},
      {"token":"ghostty","version":"1.4.0","artifacts":[{"app":["Ghostty.app"]}],"depends_on":{}},
      {"token":"ghostty@tip","version":"18491,93967b7f","artifacts":[{"app":["Ghostty.app"]}]},
      {"token":"vincelwt-chatgpt","version":"0.0.5","artifacts":[{"app":["ChatGPT.app"]}]},
      {"token":"some-latest","version":"latest","artifacts":[{"app":["Latest.app"]}]},
      {"token":"dup-a","version":"9.0","artifacts":[{"app":["Twin.app"]}]},
      {"token":"dup-b","version":"9.1","artifacts":[{"app":["twin.app"]}]},
      {"token":"future-os","version":"5.0","artifacts":[{"app":["Future.app"]}],"depends_on":{"macos":{">=":["99"]}}},
      {"token":"pkg-only","version":"2.0","artifacts":[{"pkg":["Tool.pkg"]},"odd",["x"]]},
      {"name":["no token"],"version":"1.0"},
      {"token":"bad-types","version":5,"auto_updates":"yes","artifacts":{"app":"x"}}
    ]
    """

    static func app(_ name: String, _ version: String, folder: String? = nil, feed: URL? = nil, mas: Bool = false) -> SparkleApp {
        SparkleApp(name: name, path: "/Applications/\(folder ?? name).app", bundleID: "x.\(name)", shortVersion: version,
                   bundleVersion: "1", feedURL: feed, isMacAppStore: mas)
    }

    static let macOS27 = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)

    @Test func parsesOnlyNeededFieldsTolerantly() {
        let entries = SparkleFallback.parseCaskAPI(Data(Self.apiJSON.utf8))
        let byToken = Dictionary(uniqueKeysWithValues: entries.map { ($0.token, $0) })
        #expect(entries.count == 11)   // belirteci olmayan kayıt atlanır
        #expect(byToken["chatgpt"] == SparkleFallback.CaskEntry(
            token: "chatgpt", appNames: ["ChatGPT.app"], version: "26.1027.30824", autoUpdates: true, depends: ">= 13"))
        #expect(byToken["thorium"]?.appNames == ["Thorium Browser.app"])
        #expect(byToken["ghostty"]?.depends == nil && byToken["ghostty"]?.autoUpdates == false)
        #expect(byToken["pkg-only"]?.appNames == [])
        #expect(byToken["bad-types"]?.version == "" && byToken["bad-types"]?.appNames == [])
    }

    @Test func garbageGivesEmptyList() {
        #expect(SparkleFallback.parseCaskAPI(Data()).isEmpty)
        #expect(SparkleFallback.parseCaskAPI(Data("not json".utf8)).isEmpty)
        #expect(SparkleFallback.parseCaskAPI(Data(#"{"formulae":[]}"#.utf8)).isEmpty)
    }

    @Test func parsesInstalledInfoWithLeadingWarnings() {
        let text = """
        Warning: something went sideways
        {"formulae":[],"casks":[
          {"token":"iina","version":"1.5.0","installed":"1.4.4","auto_updates":true,"artifacts":[{"app":["IINA.app"]}]},
          {"token":"keka","version":"1.6.8","artifacts":[{"app":["Keka.app"]}]}
        ]}
        """
        let entries = SparkleFallback.parseCaskAPI(Data(text.utf8))
        #expect(entries.map(\.token) == ["iina", "keka"])
        let index = SparkleFallback.tokenIndex(entries)
        #expect(index == ["iina": "iina", "keka": "keka"])
        #expect(SparkleFallback.caskToken(for: Self.app("IINA", "1.4.4"), in: index) == "iina")
        #expect(SparkleFallback.caskToken(for: Self.app("Dia", "1.0"), in: index) == nil)
    }

    @Test func tokenIndexDropsAmbiguousNamesAndUsesFolderName() {
        let entries = SparkleFallback.parseCaskAPI(Data(Self.apiJSON.utf8))
        let index = SparkleFallback.tokenIndex(entries)
        #expect(index["twin"] == nil)
        #expect(index["thorium browser"] == "thorium")
        // Görünen ad farklı olsa da klasör adıyla bulunur.
        #expect(SparkleFallback.caskToken(for: Self.app("Thorium", "1", folder: "Thorium Browser"), in: index) == "thorium")
    }

    @Test func reportsOnlyUniqueStrictlyNewerMatches() {
        let entries = SparkleFallback.parseCaskAPI(Data(Self.apiJSON.utf8))
        let apps = [
            Self.app("ChatGPT", "26.1021.31345"),                       // daha yeni sürüm var (ikinci cask'e rağmen)
            Self.app("Ghostty", "1.4.0"),                               // güncel
            Self.app("Thorium", "131.0", folder: "thorium browser"),    // kurulu sürüm daha yeni
            Self.app("Latest", "1.0"),                                  // "latest" atlanır
            Self.app("Twin", "1.0"),                                    // iki cask eşleşir, atlanır
            Self.app("Future", "1.0"),                                  // macOS koşulu sağlanmıyor
            Self.app("Tool", "1.0"),                                    // .app yok
        ]
        let items = SparkleFallback.updates(apps: apps, entries: entries, system: Self.macOS27)
        #expect(items.count == 1)
        let item = items.first
        #expect(item?.source == .sparkle && item?.name == "ChatGPT")
        #expect(item?.installed == "26.1021.31345" && item?.latest == "26.1027.30824")
        #expect(item?.path == "/Applications/ChatGPT.app" && item?.caskToken == nil)
    }

    @Test func ambiguousMatchesNeedExactCanonicalToken() {
        let entries = SparkleFallback.parseCaskAPI(Data(Self.apiJSON.utf8))
        let ghostty = entries.filter { $0.appNames == ["Ghostty.app"] }
        #expect(ghostty.count == 2)
        #expect(SparkleFallback.uniqueMatch(ghostty, appKey: "ghostty")?.token == "ghostty")
        let twins = entries.filter { $0.token.hasPrefix("dup-") }
        #expect(SparkleFallback.uniqueMatch(twins, appKey: "twin") == nil)
        #expect(SparkleFallback.canonicalToken("Cloudflare WARP") == "cloudflare-warp")
    }

    @Test func caskVersionAfterCommaIsIgnored() {
        let entries = SparkleFallback.parseCaskAPI(Data(Self.apiJSON.utf8))
        let items = SparkleFallback.updates(apps: [Self.app("Thorium", "129.5", folder: "Thorium Browser")],
                                            entries: entries, system: Self.macOS27)
        #expect(items.first?.latest == "130.0")
        let same = SparkleFallback.updates(apps: [Self.app("Thorium", "130.0", folder: "Thorium Browser")],
                                           entries: entries, system: Self.macOS27)
        #expect(same.isEmpty)
    }

    @Test func requirementCheck() {
        #expect(SparkleFallback.requirementMet(">= 13", osVersion: "27.0.0"))
        #expect(!SparkleFallback.requirementMet(">= 99", osVersion: "27.0.0"))
        #expect(SparkleFallback.requirementMet("== 12", osVersion: "27.0.0"))
    }

    @Test func usesFreshCacheWithoutNetworkAndSkipsAppsWithFeeds() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tz-cask-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(Self.apiJSON.utf8).write(to: dir.appendingPathComponent("cask.json"))
        let apps = [
            Self.app("ChatGPT", "26.1021.31345"),
            Self.app("ChatGPT", "26.1021.31345", folder: "ChatGPT", feed: URL(string: "https://example.com/a.xml")),
            Self.app("ChatGPT", "26.1021.31345", mas: true),
        ]
        let items = await SparkleFallback.updatesFromCaskIndex(apps: apps, cacheDirectory: dir, now: Date())
        #expect(items.count == 1)
        #expect(items.first?.latest == "26.1027.30824")
    }

    @Test func noCandidatesMeansNoWork() async {
        let dir = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        let items = await SparkleFallback.updatesFromCaskIndex(apps: [Self.app("X", "1", feed: URL(string: "https://e.com"))],
                                                               cacheDirectory: dir)
        #expect(items.isEmpty)
    }
}
