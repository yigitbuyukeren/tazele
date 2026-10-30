import Foundation

/// Terminali olmayan bir uygulamada `sudo` parola soramaz. Çözüm: `SUDO_ASKPASS`.
/// `sudo -A`, parolayı bu yardımcı betikten ister; betik yerel bir macOS parola penceresi gösterir.
/// Parola Tazele sürecinden geçmez: pencereyi `osascript` açar, yanıtı doğrudan `sudo`'ya verir.
/// Bu yol artık yalnızca son çaredir; öncelikli yöntem sistemin kendi izin penceresidir (bkz. `PrivilegedRunner`).
///
/// Bilinen sınır: betik kullanıcının yazabildiği Application Support klasöründedir. Bu yüzden her
/// kullanımdan hemen önce (her `ShellEnvironment.make()` çağrısında) yeniden denetlenir: sembolik bağ
/// değil, sahibi kullanıcı, kipi 0700, tek bağlantılı ve içeriği beklenen betikle bayt bayt aynı olmalı;
/// değilse silinip yeniden yazılır. Yine de aynı kullanıcıyla çalışan bir süreç, denetim ile `sudo`'nun
/// betiği çalıştırması arasında onu değiştirebilir ya da herhangi bir parola penceresini zaten taklit
/// edebilir (kullanıcı düzeyindeki her uygulamanın sınırı). Sistem izin penceresi bu yüzden tercih edilir.
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

    /// Betiği Application Support altına yazar (yalnızca kullanıcı çalıştırabilir), bütünlüğünü denetler ve
    /// yolunu döndürür. Klasör güvenilir değilse (sembolik bağ, başkasına ait) hata fırlatır; o zaman
    /// `SUDO_ASKPASS` hiç ayarlanmaz.
    @discardableResult
    public static func installAskpass(in directory: URL? = nil) throws -> URL {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tazele", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var st = stat()
        guard lstat(base.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid() else {
            throw CocoaError(.fileWriteNoPermission)
        }
        // Grup/diğer yazma izni varsa kaldırılır (başka bir kullanıcı betiği değiştiremesin).
        if st.st_mode & 0o022 != 0, chmod(base.path, st.st_mode & 0o755) != 0 { throw CocoaError(.fileWriteNoPermission) }

        let url = base.appendingPathComponent("askpass.sh")
        let expected = Data(script.utf8)
        if !isIntactAskpass(at: url, expected: expected) {
            // `removeItem` sembolik bağın kendisini siler, hedefine dokunmaz.
            if (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil || isSymlink(url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try writeExclusive(expected, to: url, mode: 0o700)
        }
        guard isIntactAskpass(at: url, expected: expected) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    /// Betik bozulmamış mı: sembolik bağ değil, düzenli dosya, sahibi kullanıcı, kipi tam 0700, tek bağlantı,
    /// içerik beklenenle aynı. Dosya `O_NOFOLLOW` ile açılır; denetim ve okuma aynı tanımlayıcı üzerindedir.
    static func isIntactAskpass(at url: URL, expected: Data) -> Bool {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(),
              st.st_mode & 0o7777 == 0o700, st.st_nlink == 1, st.st_size == off_t(expected.count) else { return false }
        let data = FileHandle(fileDescriptor: fd, closeOnDealloc: false).readDataToEndOfFile()
        return data == expected
    }

    /// Yeni dosya oluşturur (`O_CREAT | O_EXCL | O_NOFOLLOW`): var olan bir dosyanın ya da bağın üzerine yazmaz.
    static func writeExclusive(_ data: Data, to url: URL, mode: mode_t) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        let written = data.withUnsafeBytes { raw -> Int in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 { if errno == EINTR { continue }; return -1 }
                offset += n
            }
            return offset
        }
        guard written == data.count, fchmod(fd, mode) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    static func isSymlink(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFLNK
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
///
/// Eskiden `osascript` (`do shell script … with administrator privileges`) de vardı: root, çıktıyı
/// kullanıcının yazabildiği bir klasördeki dosyaya yazıyordu; aynı kullanıcıyla çalışan bir süreç o dosyayı
/// denetim ile açılış arasında bir sembolik bağla değiştirip root'a istediği dosyaya yazdırabiliyordu.
/// Bu yüzden kaldırıldı. Ayarlarda hâlâ "osascript" yazılıysa tanınmaz ve varsayılan sıra kullanılır.
public enum PrivilegeMechanism: String, CaseIterable, Sendable {
    /// Authorization Services: sistemin kendi izin penceresi (Touch ID destekli, Tazele adı ve simgesiyle).
    case authorizationServices
    /// `sudo -A` + `SUDO_ASKPASS` parola penceresi (eski yol, son çare).
    case sudoAskpass

    /// Kullanıcının yöntemi elle seçebildiği ayar anahtarı (ör. `defaults write … privilegeMechanism sudoAskpass`).
    public static let defaultsKey = "privilegeMechanism"

    /// Ayarlarda kayıtlı tercih; tanınmayan değer (kaldırılan "osascript" dahil) yok sayılır.
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
    /// Araç bulundu ama root olarak çalıştırılacak kadar güvenilir bir konumda değil (ör. kullanıcıya ait Homebrew).
    case untrustedTool(String)
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
        case .untrustedTool(let tool):
            String(localized: "Araç yönetici olarak çalıştırılmadı; kullanıcının değiştirebildiği bir konumda: \(tool)", bundle: .main)
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

// MARK: - Root olarak çalıştırılabilecek aracın güvenilirliği

/// Bir aracın root olarak çalıştırılmaya uygun olup olmadığını dosya sistemi sahipliğiyle denetler.
///
/// Kural: sembolik bağlar çözüldükten sonraki gerçek dosya düzenli, çalıştırılabilir, sahibi root ve
/// grup/diğer yazamaz olmalı; kökten (/) dosyaya kadar her üst klasör de root'a ait, grup/diğer yazamaz
/// ve ACL'siz olmalı. Böylece kullanıcı (ya da onun adına çalışan bir süreç) denetimden sonra dosyayı
/// değiştiremez; çalıştırılan yol, denetlenen gerçek yoldur (sembolik bağ değil).
///
/// Homebrew'ün kurduğu `mas` (/opt/homebrew, kullanıcıya ait) bu yüzden güvenilir sayılmaz. Kod imzası
/// denetimi (ör. `codesign --verify -R …`) bilinçli olarak alternatif yapılmadı: kullanıcının yazabildiği
/// bir dosya imza denetiminden SONRA, root onu çalıştırmadan önce değiştirilebilir; imza denetimi
/// çalıştırılan baytlara bağlanamaz. Sahiplik kuralı ise bu pencereyi kapatır.
public struct ExecutableTrust: Sendable {
    /// `lstat` sonucunun gereken kısmı.
    public struct Node: Sendable, Equatable {
        public let uid: uid_t
        public let mode: mode_t
        public let hasACL: Bool
        public init(uid: uid_t, mode: mode_t, hasACL: Bool = false) {
            self.uid = uid
            self.mode = mode
            self.hasACL = hasACL
        }
    }

    /// Bağı izlemeden dosya bilgisi; yoksa nil. Testlerde sahte sahiplik verilir.
    var inspect: @Sendable (String) -> Node?
    /// Sembolik bağları çözülmüş gerçek yol; yoksa nil.
    var realPath: @Sendable (String) -> String?

    public static let live = ExecutableTrust(
        inspect: { path in
            var st = stat()
            guard lstat(path, &st) == 0 else { return nil }
            return Node(uid: st.st_uid, mode: st.st_mode, hasACL: ExecutableTrust.hasExtendedACL(path))
        },
        realPath: { RootSwap.realPath($0) })

    /// Güvenilirse çalıştırılacak gerçek (bağları çözülmüş) yolu, değilse nil döndürür.
    public func trustedPath(_ path: String) -> String? {
        guard path.hasPrefix("/"), let real = realPath(path), real.hasPrefix("/"),
              let file = inspect(real), file.mode & S_IFMT == S_IFREG, file.mode & 0o111 != 0,
              Self.isRootOnly(file) else { return nil }
        var dir = (real as NSString).deletingLastPathComponent
        while true {
            guard let node = inspect(dir), node.mode & S_IFMT == S_IFDIR, Self.isRootOnly(node) else { return nil }
            if dir == "/" || dir.isEmpty { break }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return real
    }

    /// Sahibi root, grup/diğer yazamaz, ek erişim listesi yok.
    static func isRootOnly(_ node: Node) -> Bool {
        node.uid == 0 && node.mode & 0o022 == 0 && !node.hasACL
    }

    /// ACL sorgusu başarısızsa güvenli kabul etme. macOS, ACL bulunmadığında ENOENT döndürür;
    /// aynı hata kaybolan yol için de kullanılabildiğinden yolun hâlâ var olduğunu ayrıca denetle.
    static func hasExtendedACL(_ path: String) -> Bool {
        errno = 0
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else {
            guard errno == ENOENT else { return true }
            var st = stat()
            return lstat(path, &st) != 0
        }
        acl_free(UnsafeMutableRawPointer(acl))
        // Boş bir ACL de güvenilmeyen durum kabul edilir.
        return true
    }

}

// MARK: - Komut doğrulama

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

    /// PATH'te (önce sistem dizinleri) bulunan ilk GÜVENİLİR aday; gerçek yolu döndürür. Güvenilir kopya
    /// yoksa nil (kullanıcıya ait kopyalar atlanır).
    public static func trustedTool(_ name: String, searchPath: String = ShellEnvironment.make()["PATH"] ?? "",
                                   trust: ExecutableTrust = .live) -> String? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        for dir in (systemPath + ":" + searchPath).split(separator: ":") where dir.hasPrefix("/") {
            let candidate = "\(dir)/\(name)"
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            if let real = trust.trustedPath(candidate) { return real }
        }
        return nil
    }

    /// Komutu doğrular ve aracı güvenilir, mutlak gerçek yola çevirir. Geçersizse `PrivilegeError` fırlatır.
    public static func validate(_ command: [String], searchPath: @autoclosure () -> String = ShellEnvironment.make()["PATH"] ?? "",
                                trust: ExecutableTrust = .live) throws -> [String] {
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
        return [try resolve(first, name: name, searchPath: searchPath(), trust: trust)] + args
    }

    static func resolve(_ tool: String, name: String, searchPath: String, trust: ExecutableTrust) throws -> String {
        if tool.hasPrefix("/") {
            let standardized = URL(fileURLWithPath: tool).standardizedFileURL.path
            guard standardized == tool, FileManager.default.isExecutableFile(atPath: tool)
            else { throw PrivilegeError.toolNotFound(tool) }
            guard let trusted = trust.trustedPath(tool) else { throw PrivilegeError.untrustedTool(tool) }
            return trusted
        }
        guard !tool.contains("/") else { throw PrivilegeError.toolNotFound(tool) }
        if let trusted = trustedTool(name, searchPath: searchPath, trust: trust) { return trusted }
        if let found = Privilege.locate(name, path: systemPath + ":" + searchPath) { throw PrivilegeError.untrustedTool(found) }
        throw PrivilegeError.toolNotFound(tool)
    }
}
