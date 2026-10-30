import Foundation

/// Arama kutusunun eşleştirme kuralı: büyük/küçük harf ve aksan duyarsız; Türkçe ı/İ de i sayılır.
public enum SearchMatcher {
    public static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "ı", with: "i")
    }

    /// Boş sorgu her şeyi eşleştirir.
    public static func matches(_ name: String, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty || fold(name).contains(fold(q))
    }
}
