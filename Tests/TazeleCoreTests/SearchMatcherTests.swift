import Testing
@testable import TazeleCore

@Suite struct SearchMatcherTests {
    @Test(arguments: [
        ("iina", "IINA", true), ("OBS", "obs", true), ("android-platform-tools", "platform", true),
        ("Ghostty", "xyzzy", false), ("ChatGPT", "", true), ("ChatGPT", "   ", true),
        ("Işık", "isik", true), ("ışık", "ISIK", true), ("İstanbul", "istanbul", true),
        ("Şablon", "sablon", true), ("Çay", "cay", true), ("Dia", "  dia ", true),
    ])
    func matching(name: String, query: String, expected: Bool) {
        #expect(SearchMatcher.matches(name, query: query) == expected)
    }
}
