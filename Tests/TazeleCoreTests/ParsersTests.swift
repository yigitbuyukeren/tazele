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
        #expect(cmds == [["brew", "upgrade", "--formula", "a"], ["brew", "upgrade", "--cask", "b"]])
    }
}
