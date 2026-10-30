import Foundation
import Testing
@testable import TazeleCore

@Suite struct ExtraSourcesTests {
    @Test func rustupParsesUpdatesOnly() {
        let text = """
        stable-aarch64-apple-darwin - Update available : 1.80.0 (abc123 2024-07-25) -> 1.81.0 (def456 2024-09-04)
        nightly-aarch64-apple-darwin - Up to date : 1.82.0-nightly (aaa 2024-09-01)
        rustup - Update available : 1.27.0 -> 1.27.1
        """
        let items = ExtraSources.parseRustupCheck(text)
        #expect(items.count == 2)
        #expect(items[0].source == .rustup && items[0].name == "stable-aarch64-apple-darwin")
        #expect(items[0].installed == "1.80.0" && items[0].latest == "1.81.0")
        #expect(items[1].name == "rustup" && items[1].installed == "1.27.0" && items[1].latest == "1.27.1")
    }

    @Test(arguments: [
        "", "\n\n", "garbage line",
        "stable-aarch64-apple-darwin - Up to date : 1.81.0 (def 2024-09-04)",
    ])
    func rustupNoUpdates(_ text: String) {
        #expect(ExtraSources.parseRustupCheck(text).isEmpty)
    }

    @Test func gemParsesLines() {
        let items = ExtraSources.parseGemOutdated("""
        rake (13.0.6 < 13.2.1)
        json (2.6.1, 2.5.0 < 2.7.2)
        not a gem line
        """)
        #expect(items.count == 2)
        #expect(items[0].source == .gem && items[0].name == "rake")
        #expect(items[0].installed == "13.0.6" && items[0].latest == "13.2.1")
        #expect(items[1].installed == "2.6.1" && items[1].latest == "2.7.2")
        #expect(ExtraSources.parseGemOutdated("").isEmpty)
    }

    @Test func pipxParsesVenvs() {
        let json = """
        {"pipx_spec_version":"0.1","venvs":{
          "black":{"metadata":{"main_package":{"package":"black","package_version":"24.4.0"}}},
          "broken":{"metadata":{}}}}
        """
        let r = ExtraSources.parsePipxList(Data(json.utf8))
        #expect(r.count == 1)
        #expect(r[0].name == "black" && r[0].version == "24.4.0")
    }

    @Test func pipxEmptyAndInvalid() {
        #expect(ExtraSources.parsePipxList(Data(#"{"pipx_spec_version":"0.1","venvs":{}}"#.utf8)).isEmpty)
        #expect(ExtraSources.parsePipxList(Data()).isEmpty)
        #expect(ExtraSources.parsePipxList(Data("nope".utf8)).isEmpty)
    }

    @Test func uvParsesToolsAndIgnoresExecutables() {
        let text = """
        nano-pdf v0.2.1
        - nano-pdf
        ruff v0.6.9
        - ruff
        """
        let r = ExtraSources.parseUVToolList(text)
        #expect(r.count == 2)
        #expect(r[0].name == "nano-pdf" && r[0].version == "0.2.1")
        #expect(r[1].name == "ruff" && r[1].version == "0.6.9")
        #expect(ExtraSources.parseUVToolList("").isEmpty)
        #expect(ExtraSources.parseUVToolList("No tools installed").isEmpty)
    }

    @Test func checkWithNothingInstalled() async {
        let report = await ExtraSources.check(runner: CommandRunner(), searchPath: "/nonexistent")
        #expect(report.items.isEmpty)
        #expect(report.errors.isEmpty)
        #expect(Set(report.missingTools).isSuperset(of: ["rustup", "gem", "pipx", "uv"]))
    }
}
