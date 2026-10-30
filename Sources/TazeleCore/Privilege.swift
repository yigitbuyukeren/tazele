import Foundation

/// Terminali olmayan bir uygulamada `sudo` parola soramaz. Çözüm: `SUDO_ASKPASS`.
/// `sudo -A`, parolayı bu yardımcı betikten ister; betik yerel bir macOS parola penceresi gösterir.
/// Parola Tazele sürecinden geçmez: pencereyi `osascript` açar, yanıtı doğrudan `sudo`'ya verir.
/// Bu yol artık yalnızca yedektir; öncelikli yöntemler için `PrivilegedRunner`'a bakın.
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

// MARK: - Yetkilendirme yöntemi

/// Root gerektiren komutun nasıl yetkilendirileceği. Sıra, tercih sırasıdır.
public enum PrivilegeMechanism: String, CaseIterable, Sendable {
    /// Authorization Services: sistemin kendi izin penceresi (Touch ID destekli, Tazele adı ve simgesiyle).
    case authorizationServices
    /// `do shell script … with administrator privileges`: yine sistem penceresi; çıktı dosya üzerinden okunur.
    case osascript
    /// `sudo -A` + `SUDO_ASKPASS` parola penceresi (eski yol, son çare).
    case sudoAskpass

    /// Kullanıcının yöntemi elle seçebildiği ayar anahtarı (ör. `defaults write … privilegeMechanism sudoAskpass`).
    public static let defaultsKey = "privilegeMechanism"

    /// Ayarlarda kayıtlı tercih; tanınmayan değer yok sayılır.
    public static func preferred(in defaults: UserDefaults = .standard) -> PrivilegeMechanism? {
        defaults.string(forKey: defaultsKey).flatMap(PrivilegeMechanism.init(rawValue:))
    }

    /// Denenecek sıra: tercih edilen yöntem (varsa) ve varsayılan sırada ondan sonrakiler; yalnızca kullanılabilir olanlar.
    /// Böylece kullanıcı `sudoAskpass` seçtiyse sistem penceresi hiç denenmez.
    public static func chain(preferred: PrivilegeMechanism?,
                             isAvailable: (PrivilegeMechanism) -> Bool) -> [PrivilegeMechanism] {
        let start = preferred.flatMap { allCases.firstIndex(of: $0) } ?? 0
        return allCases[start...].filter(isAvailable)
    }

    /// Pencere açmadan, yalnızca dosya ve sembol varlığına bakarak bu sistemde kullanılabilir mi.
    public var isAvailableOnThisSystem: Bool {
        let fm = FileManager.default
        switch self {
        case .authorizationServices:
            return AuthorizationTool.function != nil
                && fm.isExecutableFile(atPath: "/usr/libexec/security_authtrampoline")
                && fm.isExecutableFile(atPath: RootScript.zsh)
        case .osascript:
            return fm.isExecutableFile(atPath: "/usr/bin/osascript") && fm.isExecutableFile(atPath: "/bin/sh")
        case .sudoAskpass:
            return fm.isExecutableFile(atPath: "/usr/bin/sudo")
        }
    }
}

/// Ayrıcalıklı çalıştırma hataları.
public enum PrivilegeError: Error, Equatable, LocalizedError {
    /// Komut izin listesinde değil ya da güvenli olmayan bir argüman içeriyor.
    case rejectedCommand(String)
    case toolNotFound(String)
    /// Kullanıcı izin penceresini kapattı.
    case canceled
    /// Parola / Touch ID kabul edilmedi.
    case denied
    /// Bu yöntem bu sistemde çalışmadı; zincirdeki bir sonraki yöntem denenir.
    case unavailable(PrivilegeMechanism, String)
    case noMechanism
    /// Root kabuğu çıkış kodunu bildirmeden kapandı.
    case incompleteOutput

    public var errorDescription: String? {
        switch self {
        case .rejectedCommand(let detail):
            String(localized: "Bu komut yönetici olarak çalıştırılamaz: \(detail)", bundle: .main)
        case .toolNotFound(let tool):
            String(localized: "Araç bulunamadı: \(tool)", bundle: .main)
        case .canceled:
            String(localized: "Yönetici izni iptal edildi.", bundle: .main)
        case .denied:
            String(localized: "Yönetici izni verilmedi.", bundle: .main)
        case .unavailable(_, let detail):
            String(localized: "Yönetici izni alınamadı: \(detail)", bundle: .main)
        case .noMechanism:
            String(localized: "Yönetici izni isteyecek kullanılabilir bir yöntem yok.", bundle: .main)
        case .incompleteOutput:
            String(localized: "Yönetici olarak çalışan komutun sonucu okunamadı.", bundle: .main)
        }
    }
}

// MARK: - Komut doğrulama ve tırnaklama

/// Root olarak yalnızca bilinen araçlar, sıkı biçimde denetlenmiş argümanlarla çalışır.
/// Uygulama kimlikleri ve etiketler araç çıktısından gelir; bu yüzden güvenilmez kabul edilir.
public enum PrivilegedCommand {
    /// Root olarak çalıştırılabilecek araçlar.
    static let allowedTools: Set<String> = ["mas", "softwareupdate"]
    /// Araç adı göreli verilirse önce yalnızca sistem dizinlerinde, sonra kullanıcı PATH'inde aranır.
    static let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    static let softwareUpdateFlags: Set<String> = ["--agree-to-license", "--verbose"]

    /// `^[A-Za-z0-9._ +()-]+$`
    public static func isSafeArgument(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { c in
            c.isASCII && (CharacterSet.alphanumerics.contains(c) || "._ +()-".unicodeScalars.contains(c))
        }
    }

    public static func isNumeric(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { $0.isASCII && ("0"..."9").contains(Character($0)) }
    }

    /// Komutu doğrular ve aracı mutlak yola çevirir. Geçersizse `PrivilegeError` fırlatır.
    public static func validate(_ command: [String], searchPath: @autoclosure () -> String = ShellEnvironment.make()["PATH"] ?? "")
        throws -> [String] {
        guard let first = command.first, !first.isEmpty else { throw PrivilegeError.rejectedCommand("") }
        let name = (first as NSString).lastPathComponent
        guard allowedTools.contains(name) else { throw PrivilegeError.rejectedCommand(name) }
        let args = Array(command.dropFirst())
        guard args.allSatisfy(isSafeArgument) else {
            throw PrivilegeError.rejectedCommand(args.first { !isSafeArgument($0) } ?? "")
        }
        switch name {
        case "mas":
            guard args.count >= 2, ["update", "upgrade"].contains(args[0]), args.dropFirst().allSatisfy(isNumeric)
            else { throw PrivilegeError.rejectedCommand(command.joined(separator: " ")) }
        case "softwareupdate":
            let rest = args.dropFirst()
            let labels = rest.filter { !softwareUpdateFlags.contains($0) }
            guard let sub = args.first, ["-i", "--install"].contains(sub), !labels.isEmpty,
                  labels.allSatisfy({ !$0.hasPrefix("-") })
            else { throw PrivilegeError.rejectedCommand(command.joined(separator: " ")) }
        default:
            throw PrivilegeError.rejectedCommand(name)
        }
        return [try resolve(first, name: name, searchPath: searchPath())] + args
    }

    static func resolve(_ tool: String, name: String, searchPath: String) throws -> String {
        if tool.hasPrefix("/") {
            let standardized = URL(fileURLWithPath: tool).standardizedFileURL.path
            guard standardized == tool, FileManager.default.isExecutableFile(atPath: tool)
            else { throw PrivilegeError.toolNotFound(tool) }
            return tool
        }
        guard !tool.contains("/"),
              let path = Privilege.locate(name, path: systemPath + ":" + searchPath)
        else { throw PrivilegeError.toolNotFound(tool) }
        return path
    }

    /// POSIX kabuğu için tek tırnaklı, kaçışlı argüman.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// AppleScript dize sabiti (ters bölü, tırnak ve satır sonu kaçışlı).
    public static func appleScriptLiteral(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"" + escaped + "\""
    }
}
