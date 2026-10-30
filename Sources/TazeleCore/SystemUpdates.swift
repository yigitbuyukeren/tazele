import Foundation

/// `softwareupdate -l` çıktısındaki macOS güncellemeleri.
/// Yeniden başlatma / kapatma istemeyenler (ör. Command Line Tools) Tazele'den kurulabilir;
/// diğerleri için arayüz Sistem Ayarları'nı açar.
public enum SystemUpdates {
    /// Ayrıntı satırında tanınan alanlar. Başlık virgül içerebileceği için ayrıştırma bu anahtarlara göre yapılır.
    static let knownKeys = ["Title", "Version", "Size", "Recommended", "Action", "Deferred"]

    /// Her `* Label:` satırı yeni bir kayıt başlatır; ardından gelen `Title: ..., Version: ...` satırları o kayda eklenir.
    /// Diğer satırlar (başlık, "No new software available." ya da yerelleştirilmiş açıklamalar) yok sayılır.
    public static func parse(_ text: String) -> [OutdatedItem] {
        var entries: [(label: String, fields: [String: String])] = []
        let labelPattern = /^\s*\*\s*Label:\s*(.*?)\s*$/
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if let m = try? labelPattern.firstMatch(in: line) {
                entries.append((String(m.1), [:]))
                continue
            }
            guard !entries.isEmpty else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard knownKeys.contains(where: { trimmed.hasPrefix("\($0):") }) else { continue }
            entries[entries.count - 1].fields.merge(fields(in: trimmed)) { old, _ in old }
        }
        return entries.compactMap { entry in
            let title = entry.fields["Title"].flatMap { $0.isEmpty ? nil : $0 } ?? entry.label
            guard !title.isEmpty, !entry.label.isEmpty else { return nil }
            return OutdatedItem(source: .system, name: title, installed: "", latest: entry.fields["Version"] ?? "",
                                manager: entry.label, installable: entry.fields["Action"] == nil)
        }
    }

    /// "Title: A, B, Version: 1, Size: 2KiB, Recommended: YES, Action: restart," → anahtar/değer.
    /// Bir anahtar yalnızca satır başında veya virgülden sonra geliyorsa sınır sayılır.
    static func fields(in line: String) -> [String: String] {
        let keys = knownKeys.joined(separator: "|")
        guard let pattern = try? Regex<(Substring, Substring)>("(?:^|,)\\s*(\(keys)):\\s*") else { return [:] }
        let matches = line.matches(of: pattern)
        var result: [String: String] = [:]
        for (i, m) in matches.enumerated() {
            let end = i + 1 < matches.count ? matches[i + 1].range.lowerBound : line.endIndex
            var value = line[m.range.upperBound..<end].trimmingCharacters(in: .whitespaces)
            while value.hasSuffix(",") { value = String(value.dropLast()).trimmingCharacters(in: .whitespaces) }
            let key = String(m.1)
            if result[key] == nil { result[key] = value }
        }
        return result
    }

    /// Beta / Release Candidate / RC sürümleri; arayüz kurmadan önce uyarır.
    public static func isBeta(_ title: String) -> Bool {
        let lower = title.lowercased()
        if lower.contains("beta") || lower.contains("release candidate") { return true }
        return title.contains(/(?i)\bRC\d*\b/)
    }
}
