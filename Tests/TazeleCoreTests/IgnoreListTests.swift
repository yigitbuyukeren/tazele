import Foundation
import Testing
@testable import TazeleCore

@Suite struct IgnoreListTests {
    /// Her test kendi geçici UserDefaults alanını kullanır.
    private func freshDefaults() -> (UserDefaults, String) {
        let suite = "tazele.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private func item(_ name: String, latest: String, source: SourceKind = .homebrewFormula) -> OutdatedItem {
        OutdatedItem(source: source, name: name, installed: "1.0", latest: latest)
    }

    @Test func ignoreAndRestorePersistAcrossInstances() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let git = item("git", latest: "2.50")

        var list = IgnoreList(defaults: defaults)
        #expect(!list.isIgnored(git))
        list.ignore(git)
        #expect(list.isIgnored(git))
        #expect(list.isIgnored(item("git", latest: "9.9")))

        var reloaded = IgnoreList(defaults: defaults)
        #expect(reloaded.ids == ["homebrewFormula:git"])
        #expect(reloaded.isIgnored(git))

        reloaded.restore(id: git.id)
        #expect(!reloaded.isIgnored(git))
        #expect(IgnoreList(defaults: defaults).isEmpty)
        #expect(defaults.data(forKey: IgnoreList.defaultKey) == nil)
    }

    @Test func versionOnlyIgnoreReturnsWhenNewerAppears() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var list = IgnoreList(defaults: defaults)
        list.ignore(item("node", latest: "24.1.0"), versionOnly: true)

        #expect(list.version(for: "homebrewFormula:node") == "24.1.0")
        #expect(list.isIgnored(item("node", latest: "24.1.0")))
        #expect(!list.isIgnored(item("node", latest: "24.2.0")))
        #expect(IgnoreList(defaults: defaults).isIgnored(item("node", latest: "24.1.0")))

        // Aynı sürüm hâlâ görünüyorsa kayıt kalır; yenisi gelince silinir.
        #expect(list.pruneStale(current: [item("node", latest: "24.1.0")]).isEmpty)
        #expect(list.pruneStale(current: [item("node", latest: "24.2.0")]) == ["homebrewFormula:node"])
        #expect(!list.contains(id: "homebrewFormula:node"))
        #expect(IgnoreList(defaults: defaults).isEmpty)
    }

    @Test func pruneKeepsPermanentAndAbsentEntries() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var list = IgnoreList(defaults: defaults)
        list.ignore(item("git", latest: "2.50"))
        list.ignore(item("wget", latest: "1.25"), versionOnly: true)

        // git'in yeni sürümü kalıcı kaydı etkilemez; taramada olmayan wget kaydı korunur.
        #expect(list.pruneStale(current: [item("git", latest: "2.51")]).isEmpty)
        #expect(list.ids == ["homebrewFormula:git", "homebrewFormula:wget"])
    }

    @Test func malformedStoredDataStartsEmpty() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("{not json".utf8), forKey: IgnoreList.defaultKey)
        #expect(IgnoreList(defaults: defaults).isEmpty)

        defaults.set("plain string", forKey: IgnoreList.defaultKey)
        var list = IgnoreList(defaults: defaults)
        #expect(list.isEmpty)
        list.ignore(id: "npm:typescript")
        #expect(IgnoreList(defaults: defaults).ids == ["npm:typescript"])
    }

    @Test func acceptsPlainIdArrayAndSkipsEmptyIds() throws {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(["npm:b", "", "npm:a"]), forKey: IgnoreList.defaultKey)
        let list = IgnoreList(defaults: defaults)
        #expect(list.ids == ["npm:a", "npm:b"])
        #expect(list.version(for: "npm:a") == nil)
    }

    @Test func idsAreStableAndSorted() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var list = IgnoreList(defaults: defaults)
        for name in ["zsh", "bat", "mise", "bat"] { list.ignore(item(name, latest: "1")) }
        #expect(list.ids == ["homebrewFormula:bat", "homebrewFormula:mise", "homebrewFormula:zsh"])
        #expect(IgnoreList(defaults: defaults).ids == list.ids)
        #expect(list.count == 3)
        let data1 = defaults.data(forKey: IgnoreList.defaultKey)
        list.ignore(item("bat", latest: "1"))
        #expect(defaults.data(forKey: IgnoreList.defaultKey) == data1)
    }

    @Test func separateKeysDoNotShareState() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var a = IgnoreList(defaults: defaults, key: "a")
        a.ignore(id: "gem:rails")
        #expect(IgnoreList(defaults: defaults, key: "b").isEmpty)
    }

    @Test func splitParsesSourceAndName() {
        let parsed = IgnoreList.split("pythonTools:ruff")
        #expect(parsed.source == .pythonTools && parsed.name == "ruff")
        let colon = IgnoreList.split("system:Command Line Tools: 16.4")
        #expect(colon.source == .system && colon.name == "Command Line Tools: 16.4")
        let unknown = IgnoreList.split("nothing")
        #expect(unknown.source == nil && unknown.name == "nothing")
    }
}
