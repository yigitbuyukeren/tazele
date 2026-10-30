import Foundation

public enum Parsers {
    public static func brew(_ data: Data) throws -> [OutdatedItem] {
        struct Root: Decodable {
            struct Entry: Decodable {
                let name: String
                let installed_versions: [String]
                let current_version: String
            }
            let formulae: [Entry]
            let casks: [Entry]
        }
        let root = try JSONDecoder().decode(Root.self, from: data)
        func map(_ entries: [Root.Entry], _ kind: SourceKind) -> [OutdatedItem] {
            entries.map {
                OutdatedItem(source: kind, name: $0.name,
                             installed: $0.installed_versions.last ?? "?", latest: $0.current_version)
            }
        }
        return map(root.formulae, .homebrewFormula) + map(root.casks, .homebrewCask)
    }

    /// `mas outdated` satırları: `497799835 Xcode (15.0 -> 15.1)`.
    public static func mas(_ text: String) -> [OutdatedItem] {
        text.split(separator: "\n").compactMap { line in
            let pattern = /^\s*(\d+)\s+(.+?)\s+\((.+?)\s*->\s*(.+?)\)\s*$/
            guard let m = try? pattern.firstMatch(in: String(line)) else { return nil }
            return OutdatedItem(source: .appStore, name: String(m.2), installed: String(m.3), latest: String(m.4),
                                appID: String(m.1))
        }
    }

    /// `npm outdated -g --json`; çıktı boşsa güncel paket yoktur.
    public static func npm(_ data: Data) throws -> [OutdatedItem] {
        guard !data.isEmpty else { return [] }
        struct Entry: Decodable { let current: String?; let latest: String? }
        let dict = try JSONDecoder().decode([String: Entry].self, from: data)
        return dict.keys.sorted().map {
            OutdatedItem(source: .npm, name: $0, installed: dict[$0]?.current ?? "?", latest: dict[$0]?.latest ?? "?")
        }
    }

    /// `softwareupdate -l` etiket satırları (yalnızca listelenir).
    public static func softwareUpdate(_ text: String) -> [OutdatedItem] {
        text.split(separator: "\n").compactMap { line in
            let pattern = /^\*\s*Label:\s*(.+?)\s*$/
            guard let m = try? pattern.firstMatch(in: String(line)) else { return nil }
            return OutdatedItem(source: .system, name: String(m.1), installed: "", latest: "")
        }
    }
}
