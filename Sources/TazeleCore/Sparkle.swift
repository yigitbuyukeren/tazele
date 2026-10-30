import Foundation

/// Sparkle ile kendini güncelleyen uygulamaların tespiti: `SUFeedURL` + appcast.
/// Tazele bu uygulamaları kendisi kurmaz; yalnızca yeni sürüm var mı diye bakar.
public struct SparkleApp: Sendable, Equatable {
    public let name: String
    public let path: String
    public let bundleID: String
    public let shortVersion: String
    public let bundleVersion: String
    public let feedURL: URL?
    public let isMacAppStore: Bool
}

public struct AppcastItem: Sendable, Equatable {
    public var version: String?          // sparkle:version (CFBundleVersion)
    public var shortVersion: String?     // sparkle:shortVersionString
    public var minimumSystem: String?
    public var channel: String?
    public var hardware: String?         // sparkle:hardwareRequirements (ör. "arm64")
}

public enum Sparkle {
    public static let defaultDirectories = ["/Applications", "\(NSHomeDirectory())/Applications"]

    public static func scan(directories: [String] = defaultDirectories) -> [SparkleApp] {
        var apps: [SparkleApp] = []
        for dir in directories {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            for entry in entries where entry.hasSuffix(".app") {
                let path = "\(dir)/\(entry)"
                guard let info = NSDictionary(contentsOfFile: "\(path)/Contents/Info.plist") as? [String: Any] else { continue }
                let hasFramework = FileManager.default.fileExists(atPath: "\(path)/Contents/Frameworks/Sparkle.framework")
                let bundleID = info["CFBundleIdentifier"] as? String ?? ""
                // 1) Info.plist, 2) kullanıcı tercihleri (Sparkle eski `setFeedURL:` ile buraya yazar).
                let feed = ((info["SUFeedURL"] as? String)
                    ?? (bundleID.isEmpty ? nil : CFPreferencesCopyAppValue("SUFeedURL" as CFString, bundleID as CFString) as? String))
                    .flatMap(URL.init(string:))
                guard feed != nil || hasFramework else { continue }
                apps.append(SparkleApp(
                    name: String(entry.dropLast(4)), path: path, bundleID: bundleID,
                    shortVersion: info["CFBundleShortVersionString"] as? String ?? "",
                    bundleVersion: info["CFBundleVersion"] as? String ?? "",
                    feedURL: feed,
                    isMacAppStore: FileManager.default.fileExists(atPath: "\(path)/Contents/_MASReceipt")))
            }
        }
        return apps
    }

    public static func parseAppcast(_ data: Data) -> [AppcastItem] {
        let delegate = AppcastDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    /// Kullanıcıya önerilebilecek kararlı kanal adları; bunun dışındaki (beta, rc, nightly, ...) atlanır.
    static let stableChannels: Set<String> = ["stable", "release", "public", "production", "default", "latest", "general", "ga"]

    #if arch(arm64)
    public static let currentArch = "arm64"
    #else
    public static let currentArch = "x86_64"
    #endif

    /// Kararlı kanaldaki, bu macOS'a ve bu işlemciye uyan en yeni sürüm.
    public static func newest(in items: [AppcastItem], system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
                              arch: String = currentArch) -> AppcastItem? {
        let compatible = items.filter { item in
            if let channel = item.channel, !stableChannels.contains(channel.lowercased()) { return false }
            if let hw = item.hardware, !hw.lowercased().split(whereSeparator: { ", ".contains($0) }).contains(where: { $0 == Substring(arch) }) { return false }
            guard let min = item.minimumSystem else { return true }
            return VersionCompare.compare(min, "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)") != .orderedDescending
        }
        return compatible.max { a, b in
            VersionCompare.compare(a.version ?? a.shortVersion ?? "0", b.version ?? b.shortVersion ?? "0") == .orderedAscending
        }
    }

    /// Yeni bir sürüm varsa onu döndürür. Besleme okunamazsa nil (hata değil).
    public static func outdated(app: SparkleApp, items: [AppcastItem]) -> OutdatedItem? {
        guard let latest = newest(in: items) else { return nil }
        let isNewer: Bool
        if let v = latest.version, !app.bundleVersion.isEmpty {
            isNewer = VersionCompare.compare(app.bundleVersion, v) == .orderedAscending
        } else if let s = latest.shortVersion {
            isNewer = VersionCompare.compare(app.shortVersion, s) == .orderedAscending
        } else { return nil }
        guard isNewer else { return nil }
        return OutdatedItem(source: .sparkle, name: app.name, installed: app.shortVersion,
                            latest: latest.shortVersion.map(cleanVersion) ?? latest.version ?? "?", path: app.path)
    }

    /// Cask adına uyan, diskte kurulu uygulamanın gerçek sürümü (cask kaydı eski kalabilir).
    public static func installedVersion(matchingCask cask: String, directories: [String] = defaultDirectories) -> String? {
        for dir in directories {
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where entry.hasSuffix(".app") {
                guard isSameApp(String(entry.dropLast(4)), cask: cask),
                      let info = NSDictionary(contentsOfFile: "\(dir)/\(entry)/Contents/Info.plist") as? [String: Any],
                      let v = info["CFBundleShortVersionString"] as? String else { continue }
                return v
            }
        }
        return nil
    }

    /// Aynı uygulamayı hem Sparkle hem Homebrew cask olarak saymamak için ad eşleştirme.
    public static func isSameApp(_ appName: String, cask: String) -> Bool {
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let a = norm(appName), c = norm(cask)
        return !a.isEmpty && !c.isEmpty && (a == c || a.hasPrefix(c) || c.hasPrefix(a))
    }

    /// "1.55.1 (89833)" → "1.55.1"
    static func cleanVersion(_ s: String) -> String {
        s.split(separator: " ").first.map(String.init) ?? s
    }

    public static func fetch(_ url: URL) async -> [AppcastItem] {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Tazele", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return parseAppcast(data)
    }
}

/// Sparkle'ın karşılaştırıcısına yakın: sayı ve harf parçalarına böler; "1.0b" < "1.0".
public enum VersionCompare {
    /// "v1.2", "1.2 (r1234)", "1.2-HEAD", "2.0.osx", "1.2,345" (cask) → "1.2" biçimine yaklaştırır.
    public static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comma = s.firstIndex(of: ",") { s = String(s[..<comma]) }
        s = s.replacing(/\s*\(.*?\)/, with: "")
        s = s.replacing(/-HEAD.*$/, with: "")
        s = s.replacing(/\.osx$/, with: "")
        if let first = s.first, (first == "v" || first == "V"), s.dropFirst().first?.isNumber == true { s.removeFirst() }
        return s
    }

    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = tokens(normalize(a)), y = tokens(normalize(b))
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : nil, q = i < y.count ? y[i] : nil
            switch (p, q) {
            case let (p?, q?):
                if let m = Int(p), let n = Int(q) { if m != n { return m < n ? .orderedAscending : .orderedDescending } }
                else if Int(p) != nil { return .orderedDescending }
                else if Int(q) != nil { return .orderedAscending }
                else if p != q { return p < q ? .orderedAscending : .orderedDescending }
            case let (p?, nil): if let m = Int(p) { if m != 0 { return .orderedDescending } } else { return .orderedAscending }
            case let (nil, q?): if let n = Int(q) { if n != 0 { return .orderedAscending } } else { return .orderedDescending }
            default: break
            }
        }
        return .orderedSame
    }

    private static func tokens(_ s: String) -> [String] {
        s.matches(of: /\d+|[A-Za-z]+/).map { String($0.0) }
    }
}

private final class AppcastDelegate: NSObject, XMLParserDelegate {
    var items: [AppcastItem] = []
    private var current: AppcastItem?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        text = ""
        switch name {
        case "item": current = AppcastItem()
        case "enclosure":
            if current?.version == nil { current?.version = attributes["sparkle:version"] }
            if current?.shortVersion == nil { current?.shortVersion = attributes["sparkle:shortVersionString"] }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "sparkle:version": if !value.isEmpty { current?.version = value }
        case "sparkle:shortVersionString": if !value.isEmpty { current?.shortVersion = value }
        case "sparkle:minimumSystemVersion": if !value.isEmpty { current?.minimumSystem = value }
        case "sparkle:channel": if !value.isEmpty { current?.channel = value }
        case "sparkle:hardwareRequirements": if !value.isEmpty { current?.hardware = value }
        case "item": if let c = current { items.append(c) }; current = nil
        default: break
        }
    }
}
