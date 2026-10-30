import Foundation
import Testing
@testable import TazeleCore

@Suite struct SystemUpdatesTests {
    static let sample = """
    Software Update Tool

    Finding available software
    Software Update found the following new or updated software:
    * Label: Command Line Tools for Xcode 27.0-27.0
    \tTitle: Command Line Tools for Xcode 27.0, Version: 27.0, Size: 519460KiB, Recommended: YES,
    * Label: macOS 27.2 Release Candidate-26B123
    \tTitle: macOS 27.2 Release Candidate, Version: 27.2, Size: 6067768KiB, Recommended: YES, Action: restart,
    """

    @Test func parsesRealSample() {
        let items = SystemUpdates.parse(Self.sample)
        #expect(items.count == 2)
        let clt = items[0]
        #expect(clt.source == .system)
        #expect(clt.name == "Command Line Tools for Xcode 27.0")
        #expect(clt.installed == "" && clt.latest == "27.0")
        #expect(clt.manager == "Command Line Tools for Xcode 27.0-27.0")
        #expect(clt.installable)
        let os = items[1]
        #expect(os.name == "macOS 27.2 Release Candidate" && os.latest == "27.2")
        #expect(os.manager == "macOS 27.2 Release Candidate-26B123")
        #expect(!os.installable)
    }

    @Test func emptyAndNothingAvailableGiveNoItems() {
        #expect(SystemUpdates.parse("").isEmpty)
        #expect(SystemUpdates.parse("Software Update Tool\n\nFinding available software\nNo new software available.\n").isEmpty)
    }

    @Test func localizedPrefixLinesAreIgnored() {
        let text = """
        Yazılım Güncelleme Aracı

        Kullanılabilir yazılımlar aranıyor
        Yazılım Güncelleme aşağıdaki yeni veya güncellenmiş yazılımları buldu:
        * Label: Safari18.1-18.1
        \tTitle: Safari, Version: 18.1, Size: 150000KiB, Recommended: YES,
        """
        let items = SystemUpdates.parse(text)
        #expect(items.count == 1)
        #expect(items.first?.name == "Safari" && items.first?.latest == "18.1" && items.first?.installable == true)
    }

    @Test func titleWithCommasIsKeptWhole() {
        let text = "* Label: Pro Display, XDR-1.0\n\tTitle: Pro Display XDR Firmware, Update 2, Version: 1.0, Size: 10KiB, Recommended: NO,\n"
        let item = SystemUpdates.parse(text).first
        #expect(item?.name == "Pro Display XDR Firmware, Update 2")
        #expect(item?.latest == "1.0")
        #expect(item?.manager == "Pro Display, XDR-1.0")
    }

    @Test func missingFieldsFallBackToLabel() {
        let text = "* Label: Mystery Update-1\n* Label: Other-2\n\tVersion: 2.0, Action: shut down,\n"
        let items = SystemUpdates.parse(text)
        #expect(items.count == 2)
        #expect(items[0].name == "Mystery Update-1" && items[0].latest == "" && items[0].installable)
        #expect(items[1].name == "Other-2" && items[1].latest == "2.0" && !items[1].installable)
    }

    @Test func unknownTrailingKeyDoesNotLeakIntoValues() {
        let text = "* Label: X-1\n\tTitle: X, Version: 1.2, Size: 5KiB, Recommended: YES, Deferred: NO,\n"
        let item = SystemUpdates.parse(text).first
        #expect(item?.latest == "1.2" && item?.installable == true)
    }

    @Test(arguments: [
        ("macOS 27.2 Release Candidate", true), ("macOS Tahoe 27.1 beta 3", true), ("macOS 27.2 RC", true),
        ("macOS 27.2 RC2", true), ("Command Line Tools for Xcode 27.0", false), ("Source Code Pro", false),
        ("macOS Tahoe 27.1", false),
    ])
    func betaDetection(title: String, expected: Bool) {
        #expect(SystemUpdates.isBeta(title) == expected)
    }
}
