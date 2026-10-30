import Foundation
import Testing
@testable import TazeleCore

@Suite struct ParsersTests {
    @Test func brewParsesFormulaeAndCasks() throws {
        let json = """
        {"formulae":[{"name":"ada-url","installed_versions":["4.0.0"],"current_version":"4.0.0_1","pinned":false}],
         "casks":[{"name":"android-platform-tools","installed_versions":["37.0.0"],"current_version":"37.0.1"}]}
        """
        let items = try Parsers.brew(Data(json.utf8))
        #expect(items.count == 2)
        #expect(items[0].source == .homebrewFormula && items[0].latest == "4.0.0_1")
        #expect(items[1].source == .homebrewCask && items[1].installed == "37.0.0")
    }

    @Test func masParsesLines() {
        let items = Parsers.mas("497799835 Xcode (15.0 -> 15.1)\ngarbage\n")
        #expect(items.count == 1)
        #expect(items[0].name == "Xcode" && items[0].installed == "15.0" && items[0].latest == "15.1")
        #expect(items[0].appID == "497799835")
    }

    @Test func npmEmptyOutputMeansUpToDate() throws {
        #expect(try Parsers.npm(Data()).isEmpty)
    }

    @Test func npmParsesObject() throws {
        let json = #"{"@playwright/mcp":{"current":"0.0.82","wanted":"0.0.83","latest":"0.0.83"}}"#
        let items = try Parsers.npm(Data(json.utf8))
        #expect(items.first?.name == "@playwright/mcp" && items.first?.latest == "0.0.83")
    }

    @Test func softwareUpdateParsesLabels() {
        let text = "* Label: Command Line Tools for Xcode 27.0-27.0\n\tTitle: x\n"
        #expect(Parsers.softwareUpdate(text).first?.name == "Command Line Tools for Xcode 27.0-27.0")
    }

    @Test func updaterGroupsBySource() {
        let items = [
            OutdatedItem(source: .homebrewFormula, name: "a", installed: "1", latest: "2"),
            OutdatedItem(source: .homebrewCask, name: "b", installed: "1", latest: "2"),
            OutdatedItem(source: .system, name: "macOS", installed: "", latest: ""),
        ]
        let cmds = Updater.commands(for: items)
        #expect(cmds == [["brew", "upgrade", "--formula", "--", "a"], ["brew", "upgrade", "--cask", "--", "b"]])
    }

    @Test func appStoreUpdatesUseSudoWithAppIDs() {
        let items = [
            OutdatedItem(source: .appStore, name: "Xcode", installed: "1", latest: "2", appID: "111"),
            OutdatedItem(source: .appStore, name: "Pages", installed: "1", latest: "2", appID: "222"),
        ]
        #expect(Updater.commands(for: items).isEmpty)
    }

    @Test func askpassIsWrittenPrivateAndExecutable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tazele-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try Privilege.installAskpass(in: dir)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        #expect(try String(contentsOf: url, encoding: .utf8).hasPrefix("#!/bin/sh"))
    }

    @Test func askpassRepairsTamperingWithoutFollowingLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tazele-askpass-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("support")
        let url = try Privilege.installAskpass(in: dir)
        try Data("tampered".utf8).write(to: url)
        let repaired = try Privilege.installAskpass(in: dir)
        #expect(try Data(contentsOf: repaired) == Data(Privilege.script.utf8))
        let target = root.appendingPathComponent("target")
        let original = Data("untouched".utf8)
        try original.write(to: target)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        _ = try Privilege.installAskpass(in: dir)
        #expect(try Data(contentsOf: target) == original)
        #expect(Privilege.isIntactAskpass(at: url, expected: Data(Privilege.script.utf8)))
    }

    @Test func askpassRejectsLinkedSupportDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tazele-askpass-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let actual = root.appendingPathComponent("actual")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)
        #expect(throws: (any Error).self) { try Privilege.installAskpass(in: link) }
        #expect(!FileManager.default.fileExists(atPath: actual.appendingPathComponent("askpass.sh").path))
    }

    @Test func locateFindsToolsByAbsolutePath() {
        #expect(Privilege.locate("sh", path: "/nonexistent:/bin") == "/bin/sh")
        #expect(Privilege.locate("no-such-tool-xyz", path: "/bin") == nil)
    }

    @Test func missingToolsAreSkippedNotReportedAsErrors() async {
        let r = await Checker.checkAll(runner: CommandRunner(), searchPath: "/nonexistent")
        #expect(Set(["brew", "mas", "npm"]).isSubset(of: Set(r.missingTools)))
        #expect(r.errors.isEmpty)
        #expect(r.items.allSatisfy { $0.source == .system || $0.source == .sparkle })
    }

    @Test func versionCompareHandlesNumbersAndPrereleases() {
        #expect(VersionCompare.compare("1.54.2", "1.55.1") == .orderedAscending)
        #expect(VersionCompare.compare("1.10", "1.9") == .orderedDescending)
        #expect(VersionCompare.compare("1.0", "1.0.0") == .orderedSame)
        #expect(VersionCompare.compare("1.0b2", "1.0") == .orderedAscending)
        #expect(VersionCompare.compare("32.2.2", "33.0.0") == .orderedAscending)
    }

    @Test func appcastPicksNewestStableCompatibleItem() {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        <item><title>2.0 beta</title><sparkle:channel>beta</sparkle:channel>
          <enclosure url="x" sparkle:version="200" sparkle:shortVersionString="2.0b"/></item>
        <item><sparkle:version>150</sparkle:version><sparkle:shortVersionString>1.5</sparkle:shortVersionString>
          <sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion></item>
        <item><enclosure url="x" sparkle:version="120" sparkle:shortVersionString="1.2"/></item>
        <item><enclosure url="x" sparkle:version="110" sparkle:shortVersionString="1.1"/></item>
        </channel></rss>
        """
        let items = Sparkle.parseAppcast(Data(xml.utf8))
        #expect(items.count == 4)
        #expect(Sparkle.newest(in: items)?.shortVersion == "1.2")
    }

    @Test func sparkleOutdatedComparesBundleVersions() {
        let app = SparkleApp(name: "Dia", path: "/Applications/Dia.app", bundleID: "x", shortVersion: "1.54.2",
                             bundleVersion: "89247", feedURL: nil, isMacAppStore: false)
        let newer = [AppcastItem(version: "89833", shortVersion: "1.55.1 (89833)")]
        #expect(Sparkle.outdated(app: app, items: newer)?.latest == "1.55.1")
        let same = [AppcastItem(version: "89247", shortVersion: "1.54.2")]
        #expect(Sparkle.outdated(app: app, items: same) == nil)
        #expect(Sparkle.outdated(app: app, items: []) == nil)
    }

    @Test func sameAppMatchingAvoidsCaskDuplicates() {
        #expect(Sparkle.isSameApp("IINA", cask: "iina"))
        #expect(Sparkle.isSameApp("Keka", cask: "keka"))
        #expect(!Sparkle.isSameApp("Dia", cask: "iina"))
    }

    @Test func stableNamedChannelIsAcceptedButBetaIsNot() {
        let items = [
            AppcastItem(version: "300", shortVersion: "3.0rc", channel: "beta"),
            AppcastItem(version: "200", shortVersion: "2.0", channel: "stable"),
        ]
        #expect(Sparkle.newest(in: items)?.shortVersion == "2.0")
    }

    @Test func hardwareRequirementsSkipOtherArchitectures() {
        let items = [AppcastItem(version: "2", shortVersion: "2.0", hardware: "arm64"), AppcastItem(version: "1", shortVersion: "1.0")]
        #expect(Sparkle.newest(in: items, arch: "x86_64")?.shortVersion == "1.0")
        #expect(Sparkle.newest(in: items, arch: "arm64")?.shortVersion == "2.0")
    }

    @Test(arguments: [
        ("v1.2", "1.2"), ("1.2 (r1234)", "1.2"), ("1.2-HEAD-abc", "1.2"), ("2.0.osx", "2.0"),
        ("1.2,345", "1.2"), ("  3.4.5 ", "3.4.5"), ("1.55.1 (89833)", "1.55.1"),
    ])
    func versionNormalizerTable(raw: String, expected: String) {
        #expect(VersionCompare.normalize(raw) == expected)
        #expect(VersionCompare.compare(raw, expected) == .orderedSame)
    }

    @Test func runnerTimesOutAndKillsProcess() async throws {
        let start = Date()
        let r = try await CommandRunner().run(["sleep", "30"], timeout: 1)
        #expect(r.timedOut)
        #expect(Date().timeIntervalSince(start) < 8)
    }

    @Test func loginPathIsMergedWithoutDuplicates() {
        let parts = (ShellEnvironment.make()["PATH"] ?? "").split(separator: ":")
        #expect(Set(parts).count == parts.count)
        #expect(parts.contains("/usr/bin"))
    }

    @Test func installedVersionReadsRealAppBundle() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tz-apps-\(UUID().uuidString)")
        let contents = dir.appendingPathComponent("Ghostty.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        (["CFBundleShortVersionString": "1.4.0", "CFBundleIdentifier": "x.y"] as NSDictionary)
            .write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
        #expect(Sparkle.installedVersion(matchingCask: "ghostty", directories: [dir.path]) == "1.4.0")
        #expect(Sparkle.installedVersion(matchingCask: "iina", directories: [dir.path]) == nil)
    }
}

@Suite struct RestartInstallPlanTests {
    @Test func restartingSystemUpdateGetsRestartFlag() throws {
        let item = OutdatedItem(source: .system, name: "macOS 27.2", installed: "", latest: "27.2",
                                manager: "macOS 27.2 Release Candidate-26B123", installable: false)
        let plan = Updater.restartInstallPlan(for: item)
        #expect(plan.skipped.isEmpty)
        guard case .privileged(let command)? = plan.steps.first else { Issue.record("adım yok"); return }
        #expect(command == ["softwareupdate", "-i", "macOS 27.2 Release Candidate-26B123", "--restart"])
    }

    @Test func nonSystemOrOptionLikeLabelIsRejected() {
        let brew = OutdatedItem(source: .homebrewFormula, name: "x", installed: "1", latest: "2", manager: "x")
        let option = OutdatedItem(source: .system, name: "x", installed: "", latest: "2", manager: "--evil")
        let installable = OutdatedItem(source: .system, name: "CLT", installed: "", latest: "2", manager: "CLT", installable: true)
        for item in [brew, option, installable] {
            let plan = Updater.restartInstallPlan(for: item)
            #expect(plan.steps.isEmpty)
            #expect(plan.skipped.count == 1)
        }
    }
}
