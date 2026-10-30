import Foundation

/// Kullanıcının listeden çıkardığı öğeler. Kimlikler `OutdatedItem.id` biçimindedir ("kaynak:ad")
/// ve UserDefaults'ta JSON olarak saklanır. Bir kayıt ya tümüyle yoksayılır ya da yalnızca belirli
/// bir sürüm için; ikinci durumda farklı (daha yeni) bir sürüm çıkınca öğe listeye geri döner.
public struct IgnoreList {
    public struct Entry: Codable, Hashable, Sendable {
        public let id: String
        /// nil ise öğe her sürümde yoksayılır.
        public let version: String?

        public init(id: String, version: String? = nil) {
            self.id = id
            self.version = version
        }
    }

    public static let defaultKey = "ignoredItems"

    private let defaults: UserDefaults
    private let key: String
    private var storage: [String: Entry]

    /// Kayıtlı veri bozuksa liste boş başlar; bozuk veri ilk değişikliğe kadar olduğu gibi kalır.
    public init(defaults: UserDefaults = .standard, key: String = IgnoreList.defaultKey) {
        self.defaults = defaults
        self.key = key
        self.storage = [:]
        for entry in Self.decode(defaults.data(forKey: key)) where !entry.id.isEmpty {
            storage[entry.id] = entry
        }
    }

    /// Sıralı kimlikler; aynı içerik her zaman aynı sırayı verir.
    public var ids: [String] { storage.keys.sorted() }
    public var entries: [Entry] { ids.compactMap { storage[$0] } }
    public var isEmpty: Bool { storage.isEmpty }
    public var count: Int { storage.count }

    /// Kayıt yalnızca bir sürüm içinse o sürüm; tümüyle yoksayılmışsa veya kayıt yoksa nil.
    public func version(for id: String) -> String? { storage[id]?.version }
    public func contains(id: String) -> Bool { storage[id] != nil }

    public func isIgnored(id: String, latest: String) -> Bool {
        guard let entry = storage[id] else { return false }
        guard let version = entry.version else { return true }
        return version == latest
    }

    public func isIgnored(_ item: OutdatedItem) -> Bool { isIgnored(id: item.id, latest: item.latest) }

    public mutating func ignore(id: String, version: String? = nil) {
        guard !id.isEmpty else { return }
        storage[id] = Entry(id: id, version: version.flatMap { $0.isEmpty ? nil : $0 })
        save()
    }

    /// `versionOnly` ise yalnızca öğenin şu anki en yeni sürümü yoksayılır.
    public mutating func ignore(_ item: OutdatedItem, versionOnly: Bool = false) {
        ignore(id: item.id, version: versionOnly ? item.latest : nil)
    }

    public mutating func restore(id: String) {
        guard storage.removeValue(forKey: id) != nil else { return }
        save()
    }

    /// Taramada farklı bir sürümle yeniden görünen sürüme özel kayıtları siler; silinen kimlikleri döndürür.
    /// Taramada hiç görünmeyen kayıtlara dokunmaz (kaynak okunamamış olabilir).
    @discardableResult
    public mutating func pruneStale(current items: [OutdatedItem]) -> [String] {
        let latest = Dictionary(items.map { ($0.id, $0.latest) }, uniquingKeysWith: { first, _ in first })
        let stale = storage.values.filter { entry in
            guard let version = entry.version, let now = latest[entry.id] else { return false }
            return now != version
        }.map(\.id).sorted()
        guard !stale.isEmpty else { return [] }
        for id in stale { storage.removeValue(forKey: id) }
        save()
        return stale
    }

    /// "kaynak:ad" kimliğini ilk ':' karakterinden böler; adın kendisi ':' içerebilir.
    public static func split(_ id: String) -> (source: SourceKind?, name: String) {
        guard let colon = id.firstIndex(of: ":") else { return (nil, id) }
        return (SourceKind(rawValue: String(id[..<colon])), String(id[id.index(after: colon)...]))
    }

    private func save() {
        let list = entries
        if list.isEmpty { defaults.removeObject(forKey: key); return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(list) { defaults.set(data, forKey: key) }
    }

    private static func decode(_ data: Data?) -> [Entry] {
        guard let data else { return [] }
        if let list = try? JSONDecoder().decode([Entry].self, from: data) { return list }
        // Basit kimlik dizisi de kabul edilir.
        if let plain = try? JSONDecoder().decode([String].self, from: data) { return plain.map { Entry(id: $0) } }
        return []
    }
}
