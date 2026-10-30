import CryptoKit
import Foundation

// İndirilen arşivin doğrulanan baytlara bağlanması ve açılmanın sınırlandırılması.
//
// 1) Bağlama: Ed25519 imzası ve SHA-256 aynı eşlenmiş (mmap) baytlar üzerinde hesaplanır; dosyanın
//    aygıt/inode/boyut/değişiklik zamanı da kaydedilir. Arşiv açılmadan HEMEN önce dosya `O_NOFOLLOW` ile
//    yeniden açılır, aynı kimlik bilgileri ve aynı SHA-256 istenir. Çalışma klasörü 0700, arşiv 0400 yapılır.
//    Kalan risk (belgelenmiş): aynı kullanıcıyla çalışan bir süreç bu dosyaların kipini geri değiştirip
//    son denetim ile `ditto`/`tar`/`hdiutil`'in dosyayı okuması arasındaki çok kısa pencerede içeriği
//    değiştirebilir. Aynı kullanıcıya karşı tam koruma kullanıcı düzeyinde mümkün değildir; açılan içerik
//    yine paket kimliği, kod imzası, ekip ve (yönetici yolunda) Apple kökü + CDHash denetiminden geçer.
//
// 2) Sınırlama: ZIP arşivinin merkezi dizini açmadan önce okunur: mutlak yol, ".." bileşeni, bir sembolik
//    bağın "içine" yazan girdi, aygıt/FIFO/soket, setuid/setgid ve toplam açılmış boyut sınırı (4 GB).
//    Her arşiv türünde açıldıktan sonra ağaç `lstat` ile (bağlar izlenmeden) gezilir: dışarıyı gösteren
//    (mutlak ya da kökten çıkan) sembolik bağ, özel dosya, setuid/setgid, ağaç dışına giden sabit bağ ve
//    toplam boyut sınırı reddedilir. `tar` (bsdtar) zaten ".." içeren ve bağın içinden geçen girdileri
//    reddeder, baştaki "/" işaretini atar; `ditto` da bu girdileri hedef klasörün içinde tutar
//    (macOS 27'de denendi). ZIP ve tar içeriği açılmadan önce bsdtar akışıyla sınırlandırılır;
//    DMG'de salt okunur bağlanan uygulama kopyalanmadan önce boyut ve bağlantılar bakımından denetlenir.
//    Son kontrol ile çıkarma arasında aynı kullanıcı kaynaklı yarış riski devam eder.

/// Doğrulanan arşiv dosyasının kimliği ve içeriğinin özeti.
struct ArchiveFingerprint: Equatable, Sendable {
    let sha256: Data
    let device: Int64
    let inode: UInt64
    let size: Int64
    let mtimeSeconds: Int
    let mtimeNanoseconds: Int

    init(sha256: Data, stat st: stat) {
        self.sha256 = sha256
        device = Int64(st.st_dev)
        inode = UInt64(st.st_ino)
        size = Int64(st.st_size)
        mtimeSeconds = st.st_mtimespec.tv_sec
        mtimeNanoseconds = st.st_mtimespec.tv_nsec
    }

    /// Dosya kimliği (özet hariç) aynı mı?
    func sameFile(_ st: stat) -> Bool {
        device == Int64(st.st_dev) && inode == UInt64(st.st_ino) && size == Int64(st.st_size)
            && mtimeSeconds == st.st_mtimespec.tv_sec && mtimeNanoseconds == st.st_mtimespec.tv_nsec
    }
}

enum ArchiveGuard {
    /// Açılmış içerik için üst sınır (4 GB).
    static let maxExtractedBytes: Int64 = 4 * 1024 * 1024 * 1024

    // MARK: - Bağlama

    /// Dosyayı bağı izlemeden açar; düzenli dosya değilse nil.
    private static func openRegular(_ url: URL) -> (Int32, stat)? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size > 0 else { close(fd); return nil }
        return (fd, st)
    }

    /// Ed25519 imzasını doğrular; geçerliyse aynı baytların SHA-256'sı ve dosya kimliğiyle parmak izini döndürür.
    static func verify(file url: URL, signature: String, publicKey key: String) -> ArchiveFingerprint? {
        guard let k = SparkleInstaller.publicKey(key), let sig = SparkleInstaller.signatureData(signature),
              let (fd, before) = openRegular(url) else { return nil }
        defer { close(fd) }
        let length = Int(before.st_size)
        guard let mapped = mmap(nil, length, PROT_READ, MAP_PRIVATE, fd, 0),
              mapped != UnsafeMutableRawPointer(bitPattern: -1) else { return nil }
        defer { munmap(mapped, length) }
        let bytes = Data(bytesNoCopy: mapped, count: length, deallocator: .none)
        guard k.isValidSignature(sig, for: bytes) else { return nil }
        let digest = Data(SHA256.hash(data: bytes))
        var after = stat()
        guard fstat(fd, &after) == 0 else { return nil }
        let fingerprint = ArchiveFingerprint(sha256: digest, stat: before)
        // Doğrulama sürerken dosya değiştiyse (boyut / zaman) sonuç geçersizdir.
        return fingerprint.sameFile(after) ? fingerprint : nil
    }

    /// Dosya hâlâ doğrulanan dosya mı: aynı aygıt/inode/boyut/zaman ve aynı SHA-256.
    static func matches(_ fingerprint: ArchiveFingerprint, file url: URL) -> Bool {
        guard let (fd, before) = openRegular(url) else { return false }
        defer { close(fd) }
        guard fingerprint.sameFile(before) else { return false }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var total: Int64 = 0
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 { if errno == EINTR { continue }; return false }
            if n == 0 { break }
            total += Int64(n)
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, fingerprint.sameFile(after), total == fingerprint.size else { return false }
        return Data(hasher.finalize()) == fingerprint.sha256
    }

    /// Çalışma klasörünü 0700, arşivi 0400 yapar (yalnızca sahibi; bağ izlenmez).
    static func restrict(workDirectory: URL, archive: URL) throws {
        for dir in [workDirectory, archive.deletingLastPathComponent()] {
            let fd = open(dir.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw SparkleInstallError.extractFailed }
            var st = stat()
            let valid = fstat(fd, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR && st.st_uid == getuid()
                && fchmod(fd, 0o700) == 0
            close(fd)
            guard valid else { throw SparkleInstallError.extractFailed }
        }
        let fd = open(archive.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SparkleInstallError.extractFailed }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(), st.st_nlink == 1,
              fchmod(fd, 0o400) == 0 else { throw SparkleInstallError.extractFailed }
    }

    // MARK: - Yol denetimi

    /// Arşiv içi yol güvenli mi: boş değil, mutlak değil, ".." bileşeni yok, NUL yok. Ters bölü de ayırıcı sayılır.
    static func isSafeEntryPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("\\"), !path.contains("\0") else { return false }
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        return !parts.contains("..")
    }

    // MARK: - ZIP merkezi dizini

    struct ZipEntry: Equatable {
        let path: String
        /// Unix kipi (ZIP "made by" Unix ise), değilse nil.
        let mode: UInt32?
        let uncompressedSize: UInt64
    }

    /// ZIP'in merkezi dizinini okur (ZIP64 dahil). Biçim bozuksa `unsafeArchive` fırlatır.
    static func zipEntries(_ url: URL) throws -> [ZipEntry] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw SparkleInstallError.unsafeArchive }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), fileSize >= 22 else { throw SparkleInstallError.unsafeArchive }
        func read(_ offset: UInt64, _ count: Int) throws -> Data {
            guard count >= 0, offset <= fileSize, UInt64(count) <= fileSize - offset else { throw SparkleInstallError.unsafeArchive }
            if count == 0 { return Data() }
            guard
                  (try? handle.seek(toOffset: offset)) != nil,
                  let d = try? handle.read(upToCount: count), d.count == count else { throw SparkleInstallError.unsafeArchive }
            return d
        }
        // Merkezi dizin sonu (EOCD): en fazla 64 KB yorumla birlikte dosyanın sonunda.
        let tailLength = Int(min(fileSize, 22 + 65_535))
        let tail = try read(fileSize - UInt64(tailLength), tailLength)
        guard let eocdIndex = (0...(tail.count - 22)).reversed().first(where: {
            tail.u32($0) == 0x0605_4b50 && $0 + 22 + Int(tail.u16($0 + 20)) == tail.count
        })
        else { throw SparkleInstallError.unsafeArchive }
        let eocdOffset = fileSize - UInt64(tailLength) + UInt64(eocdIndex)
        guard tail.u16(eocdIndex + 4) == 0, tail.u16(eocdIndex + 6) == 0,
              tail.u16(eocdIndex + 8) == tail.u16(eocdIndex + 10) else { throw SparkleInstallError.unsafeArchive }
        var count = UInt64(tail.u16(eocdIndex + 10))
        var cdSize = UInt64(tail.u32(eocdIndex + 12))
        var cdOffset = UInt64(tail.u32(eocdIndex + 16))
        if count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            guard eocdOffset >= 20 else { throw SparkleInstallError.unsafeArchive }
            let locator = try read(eocdOffset - 20, 20)
            guard locator.u32(0) == 0x0706_4b50, locator.u32(4) == 0, locator.u32(16) == 1 else { throw SparkleInstallError.unsafeArchive }
            let record = try read(locator.u64(8), 56)
            guard record.u32(0) == 0x0606_4b50, record.u32(16) == 0, record.u32(20) == 0,
                  record.u64(24) == record.u64(32) else { throw SparkleInstallError.unsafeArchive }
            count = record.u64(32)
            cdSize = record.u64(40)
            cdOffset = record.u64(48)
        }
        // Akıl sınırları: merkezi dizin en fazla 256 MB, en fazla 2 milyon girdi.
        guard cdSize <= 256 * 1024 * 1024, count <= 2_000_000, cdOffset <= eocdOffset, cdSize <= eocdOffset - cdOffset
        else { throw SparkleInstallError.unsafeArchive }
        let cd = try read(cdOffset, Int(cdSize))
        var entries: [ZipEntry] = []
        var ranges: [(UInt64, UInt64)] = []
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= cd.count, cd.u32(p) == 0x0201_4b50 else { throw SparkleInstallError.unsafeArchive }
            let madeBy = cd.u16(p + 4) >> 8
            var uncompressed = UInt64(cd.u32(p + 24))
            var compressed = UInt64(cd.u32(p + 20))
            var localOffset = UInt64(cd.u32(p + 42))
            let flags = cd.u16(p + 8), method = cd.u16(p + 10)
            guard flags & 1 == 0, cd.u16(p + 34) == 0 else { throw SparkleInstallError.unsafeArchive }
            let nameLength = Int(cd.u16(p + 28)), extraLength = Int(cd.u16(p + 30)), commentLength = Int(cd.u16(p + 32))
            let external = cd.u32(p + 38)
            let end = p + 46 + nameLength + extraLength + commentLength
            guard end <= cd.count else { throw SparkleInstallError.unsafeArchive }
            let nameData = cd.subdata(in: (p + 46)..<(p + 46 + nameLength))
            guard let name = String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1)
            else { throw SparkleInstallError.unsafeArchive }
            // ZIP64 alanı yalnızca taşan değerleri sırasıyla içerir.
            let zip64Sizes = uncompressed == 0xFFFF_FFFF || compressed == 0xFFFF_FFFF
            let needsZip64 = zip64Sizes || localOffset == 0xFFFF_FFFF
            var e = p + 46 + nameLength
            let extraEnd = e + extraLength
            var foundZip64 = false
            while e < extraEnd {
                guard e + 4 <= extraEnd else { throw SparkleInstallError.unsafeArchive }
                let id = cd.u16(e), length = Int(cd.u16(e + 2))
                let fieldEnd = e + 4 + length
                guard fieldEnd <= extraEnd else { throw SparkleInstallError.unsafeArchive }
                // Unicode yol eki, yerel/merkezi ad denetiminden farklı bir yol seçebilir.
                guard id != 0x7075 else { throw SparkleInstallError.unsafeArchive }
                if id == 0x0001 && needsZip64 {
                    guard !foundZip64 else { throw SparkleInstallError.unsafeArchive }
                    var cursor = e + 4
                    func next64() throws -> UInt64 {
                        guard cursor + 8 <= fieldEnd else { throw SparkleInstallError.unsafeArchive }
                        defer { cursor += 8 }
                        return cd.u64(cursor)
                    }
                    if uncompressed == 0xFFFF_FFFF { uncompressed = try next64() }
                    if compressed == 0xFFFF_FFFF { compressed = try next64() }
                    if localOffset == 0xFFFF_FFFF { localOffset = try next64() }
                    foundZip64 = true
                }
                e = fieldEnd
            }
            guard !needsZip64 || foundZip64 else { throw SparkleInstallError.unsafeArchive }
            // Açıcı yerel başlığı okur: adı, bayrakları ve yöntemi merkezi dizinle eşleşmeli.
            // Veri merkezi dizine veya dosya sonuna taşmamalı.
            guard localOffset <= cdOffset, cdOffset - localOffset >= 30 else { throw SparkleInstallError.unsafeArchive }
            let local = try read(localOffset, 30)
            guard local.u32(0) == 0x0403_4b50, local.u16(6) == flags, local.u16(8) == method,
                  Int(local.u16(26)) == nameLength else { throw SparkleInstallError.unsafeArchive }
            let localExtraLength = Int(local.u16(28))
            let headerLength = UInt64(30 + nameLength + localExtraLength)
            guard headerLength <= cdOffset - localOffset,
                  compressed <= cdOffset - localOffset - headerLength,
                  try read(localOffset + 30, nameLength) == nameData
            else { throw SparkleInstallError.unsafeArchive }
            let localExtra = try read(localOffset + 30 + UInt64(nameLength), localExtraLength)
            var extraPos = 0
            var localZip64: Data?
            while extraPos < localExtra.count {
                guard extraPos + 4 <= localExtra.count else { throw SparkleInstallError.unsafeArchive }
                let id = localExtra.u16(extraPos), length = Int(localExtra.u16(extraPos + 2))
                guard id != 0x7075, extraPos + 4 + length <= localExtra.count else { throw SparkleInstallError.unsafeArchive }
                if id == 0x0001 {
                    guard localZip64 == nil else { throw SparkleInstallError.unsafeArchive }
                    localZip64 = localExtra.subdata(in: (extraPos + 4)..<(extraPos + 4 + length))
                }
                extraPos += 4 + length
            }
            let payloadEnd = localOffset + headerLength + compressed
            var recordEnd = payloadEnd
            if flags & 8 == 0 {
                guard local.u32(14) == cd.u32(p + 16) else { throw SparkleInstallError.unsafeArchive }
                var localCompressed = UInt64(local.u32(18)), localUncompressed = UInt64(local.u32(22))
                if localCompressed == 0xFFFF_FFFF || localUncompressed == 0xFFFF_FFFF {
                    guard let extra = localZip64 else { throw SparkleInstallError.unsafeArchive }
                    var cursor = 0
                    func localSize() throws -> UInt64 {
                        guard cursor + 8 <= extra.count else { throw SparkleInstallError.unsafeArchive }
                        defer { cursor += 8 }
                        return extra.u64(cursor)
                    }
                    if localUncompressed == 0xFFFF_FFFF { localUncompressed = try localSize() }
                    if localCompressed == 0xFFFF_FFFF { localCompressed = try localSize() }
                }
                guard localCompressed == compressed, localUncompressed == uncompressed
                else { throw SparkleInstallError.unsafeArchive }
            } else {
                // Veri tanımlayıcısı boyutları da merkezi dizinle aynı olmalı.
                guard payloadEnd <= cdOffset, cdOffset - payloadEnd >= 12 else { throw SparkleInstallError.unsafeArchive }
                let first = try read(payloadEnd, 4).u32(0)
                let signatureLength: UInt64 = first == 0x0807_4b50 ? 4 : 0
                let use64 = zip64Sizes || local.u32(18) == 0xFFFF_FFFF || local.u32(22) == 0xFFFF_FFFF
                let descriptorLength: UInt64 = signatureLength + (use64 ? 20 : 12)
                guard descriptorLength <= cdOffset - payloadEnd else { throw SparkleInstallError.unsafeArchive }
                let descriptor = try read(payloadEnd + signatureLength, Int(descriptorLength - signatureLength))
                let descriptorCompressed = use64 ? descriptor.u64(4) : UInt64(descriptor.u32(4))
                let descriptorUncompressed = use64 ? descriptor.u64(12) : UInt64(descriptor.u32(8))
                guard descriptor.u32(0) == cd.u32(p + 16), descriptorCompressed == compressed,
                      descriptorUncompressed == uncompressed else { throw SparkleInstallError.unsafeArchive }
                recordEnd += descriptorLength
            }
            ranges.append((localOffset, recordEnd))
            entries.append(ZipEntry(path: name, mode: madeBy == 3 ? external >> 16 : nil, uncompressedSize: uncompressed))
            p = end
        }
        guard p == cd.count else { throw SparkleInstallError.unsafeArchive }
        ranges.sort { $0.0 < $1.0 }
        for i in 1..<max(ranges.count, 1) where ranges[i - 1].1 > ranges[i].0 {
            throw SparkleInstallError.unsafeArchive
        }
        return entries
    }

    /// ZIP girdilerini açmadan önce denetler.
    static func checkZip(_ url: URL, maxBytes: Int64 = maxExtractedBytes) throws {
        try checkZipEntries(try zipEntries(url), maxBytes: maxBytes)
    }

    static func checkZipEntries(_ entries: [ZipEntry], maxBytes: Int64) throws {
        var total: UInt64 = 0
        var links: [String] = []
        var seen: Set<String> = []
        for entry in entries {
            guard isSafeEntryPath(entry.path), !entry.path.contains("\\"),
                  !trimmed(entry.path).isEmpty, seen.insert(trimmed(entry.path)).inserted
            else { throw SparkleInstallError.unsafeArchive }
            if let mode = entry.mode {
                let type = mode_t(mode) & S_IFMT
                guard [0, S_IFREG, S_IFDIR, S_IFLNK].contains(type), mode_t(mode) & (S_ISUID | S_ISGID) == 0
                else { throw SparkleInstallError.unsafeArchive }
                if type == S_IFLNK { links.append(trimmed(entry.path)) }
            }
            guard maxBytes >= 0, entry.uncompressedSize <= UInt64(maxBytes),
                  total <= UInt64(maxBytes) - entry.uncompressedSize else { throw SparkleInstallError.unsafeArchive }
            total += entry.uncompressedSize
        }
        // Bir sembolik bağın "içine" yazan girdi (bağ dışarıyı gösteriyorsa dışarıya yazılırdı).
        let normalizedLinks = Set(links)
        for entry in entries {
            let parts = trimmed(entry.path).split(separator: "/")
            for i in 1..<max(parts.count, 1) where normalizedLinks.contains(parts[0..<i].joined(separator: "/")) {
                throw SparkleInstallError.unsafeArchive
            }
        }
    }

    private static func trimmed(_ path: String) -> String {
        path.split(separator: "/").filter { $0 != "." }.joined(separator: "/")
            .precomposedStringWithCanonicalMapping.lowercased()
    }

    // MARK: - Açılmış ağaç

    /// Açılmış ağacı bağları izlemeden gezer. Kural ihlalinde `unsafeArchive` fırlatır.
    static func checkTree(_ root: URL, maxBytes: Int64 = maxExtractedBytes) throws {
        guard let base = RootSwap.realPath(root.path) else { throw SparkleInstallError.unsafeArchive }
        var total: Int64 = 0
        /// Birden çok bağlantılı dosyalar: inode → (bağlantı sayısı, ağaçta görülen).
        struct FileIdentity: Hashable { let device: UInt64; let inode: UInt64 }
        var hardLinks: [FileIdentity: (links: Int, seen: Int)] = [:]
        func inside(_ path: String) -> Bool { path == base || path.hasPrefix(base == "/" ? "/" : base + "/") }

        func walk(_ dir: String) throws {
            let names: [String]
            do { names = try FileManager.default.contentsOfDirectory(atPath: dir) } catch { throw SparkleInstallError.unsafeArchive }
            for name in names {
                let path = dir + "/" + name
                var st = stat()
                guard lstat(path, &st) == 0 else { throw SparkleInstallError.unsafeArchive }
                guard st.st_mode & (S_ISUID | S_ISGID) == 0 else { throw SparkleInstallError.unsafeArchive }
                switch st.st_mode & S_IFMT {
                case S_IFDIR:
                    try walk(path)
                case S_IFREG:
                    guard st.st_size >= 0, maxBytes >= 0, st.st_size <= maxBytes,
                          total <= maxBytes - st.st_size else { throw SparkleInstallError.unsafeArchive }
                    total += st.st_size
                    if st.st_nlink > 1 {
                        let identity = FileIdentity(device: UInt64(bitPattern: Int64(st.st_dev)), inode: UInt64(st.st_ino))
                        let entry = hardLinks[identity] ?? (Int(st.st_nlink), 0)
                        hardLinks[identity] = (entry.links, entry.seen + 1)
                    }
                case S_IFLNK:
                    guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path),
                          !target.isEmpty, !target.hasPrefix("/"),
                          inside(lexicallyNormalized(dir + "/" + target)) else { throw SparkleInstallError.unsafeArchive }
                    // Bağ zinciri sözcüksel denetimi atlatmasın: çözülebiliyorsa gerçek yol da içeride olmalı.
                    if let real = RootSwap.realPath(path), !inside(real) { throw SparkleInstallError.unsafeArchive }
                default:
                    throw SparkleInstallError.unsafeArchive   // aygıt, FIFO, soket
                }
            }
        }
        try walk(base)
        // Sabit bağın her bağlantısı ağacın içinde olmalı (dışarıdaki bir dosyaya bağlanmamış).
        guard hardLinks.values.allSatisfy({ $0.links == $0.seen }) else { throw SparkleInstallError.unsafeArchive }
    }

    /// "." ve ".." bileşenlerini dosya sistemine bakmadan çözer (mutlak yol için).
    static func lexicallyNormalized(_ path: String) -> String {
        var out: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { _ = out.popLast(); continue }
            out.append(part)
        }
        return "/" + out.joined(separator: "/")
    }
}

private extension Data {
    func u16(_ i: Int) -> UInt16 { UInt16(self[startIndex + i]) | UInt16(self[startIndex + i + 1]) << 8 }
    func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | UInt32(u16(i + 2)) << 16 }
    func u64(_ i: Int) -> UInt64 { UInt64(u32(i)) | UInt64(u32(i + 4)) << 32 }
}
