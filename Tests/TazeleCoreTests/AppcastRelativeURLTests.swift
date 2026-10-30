import Foundation
import Testing
@testable import TazeleCore

@Suite struct AppcastRelativeURLTests {
    let xml = """
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
    <item><sparkle:version>101.104.4</sparkle:version><sparkle:shortVersionString>1.104.4</sparkle:shortVersionString>
    <enclosure url="Tailscale-1.104.4-macos.zip" length="31823652" sparkle:edSignature="abc"/></item>
    <item><sparkle:version>2</sparkle:version>
    <enclosure url="https://cdn.example.com/x.zip" length="1" sparkle:edSignature="abc"/></item>
    </channel></rss>
    """

    @Test func relativeEnclosureIsResolvedAgainstAppcastURL() {
        let base = URL(string: "https://pkgs.tailscale.com/stable/appcast.xml")!
        let items = Sparkle.parseAppcast(Data(xml.utf8), baseURL: base)
        #expect(items[0].url == "https://pkgs.tailscale.com/stable/Tailscale-1.104.4-macos.zip")
        #expect(items[1].url == "https://cdn.example.com/x.zip")
    }

    @Test func withoutBaseURLRelativeStaysAsIs() {
        #expect(Sparkle.parseAppcast(Data(xml.utf8))[0].url == "Tailscale-1.104.4-macos.zip")
    }

    @Test func httpRelativeBaseStaysRejectedBySecurityCheck() {
        let base = URL(string: "http://example.com/appcast.xml")!
        let url = Sparkle.parseAppcast(Data(xml.utf8), baseURL: base)[0].url
        #expect(url == "http://example.com/Tailscale-1.104.4-macos.zip")
    }
}
