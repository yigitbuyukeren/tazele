import Foundation

/// Terminali olmayan bir uygulamada `sudo` parola soramaz. Çözüm: `SUDO_ASKPASS`.
/// `sudo -A`, parolayı bu yardımcı betikten ister; betik yerel bir macOS parola penceresi gösterir.
/// Parola Tazele sürecinden geçmez: pencereyi `osascript` açar, yanıtı doğrudan `sudo`'ya verir.
public enum Privilege {
    static var script: String {
        func q(_ s: String) -> String { s.replacingOccurrences(of: "\"", with: "'") }
        let prompt = q(String(localized: "Tazele, App Store güncellemelerini yüklemek için yönetici parolanı istiyor.", bundle: .main))
        let cancel = q(String(localized: "İptal", bundle: .main)), ok = q(String(localized: "Tamam", bundle: .main))
        return """
        #!/bin/sh
        # Tazele: sudo için parola penceresi. İptal edilirse sıfırdan farklı kodla çıkar.
        /usr/bin/osascript <<'OSA' 2>/dev/null
        text returned of (display dialog "\(prompt)" default answer "" with hidden answer with title "Tazele" with icon caution buttons {"\(cancel)", "\(ok)"} default button "\(ok)" cancel button "\(cancel)")
        OSA
        """
    }

    /// Betiği Application Support altına yazar (yalnızca kullanıcı çalıştırabilir) ve yolunu döndürür.
    @discardableResult
    public static func installAskpass(in directory: URL? = nil) throws -> URL {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tazele", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("askpass.sh")
        let data = Data(script.utf8)
        if (try? Data(contentsOf: url)) != data { try data.write(to: url, options: .atomic) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    /// `sudo` varsayılan olarak PATH'i daraltır; bu yüzden aracı mutlak yolla çağırırız.
    public static func locate(_ tool: String, path: String = ShellEnvironment.make()["PATH"] ?? "") -> String? {
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
