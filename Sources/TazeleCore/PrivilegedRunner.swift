import Foundation
import Security

// Root gerektiren komutlar (`mas update <kimlikler>`, `softwareupdate -i <etiket>`) nasıl çalışır?
//
// Yöntem zinciri (`PrivilegeMechanism`), kullanılabilir olan ilk yöntemden başlar:
//  1. authorizationServices: `AuthorizationCopyRights` sistemin izin penceresini açar (Touch ID /
//     Apple Watch destekli, Tazele adı ve simgesiyle, kendi açıklama metnimizle). Ardından
//     `AuthorizationExecuteWithPrivileges` ile `/bin/zsh` kısa bir sarmalayıcı betik olarak root
//     yetkisiyle başlatılır; araç mutlak yoluyla ve argümanları ayrı ayrı (kabuk ayrıştırması olmadan)
//     geçirilir. Bu işlev Swift'te "kullanılamaz" olarak işaretli; bu yüzden çalışma anında
//     `dlsym` ile bulunur. macOS 27'de hâlâ mevcut; yoksa zincir bir sonraki yönteme geçer.
//     Çıktı, işlevin verdiği soket üzerinden satır satır okunur. İptalde sokete bir bayt yazılır;
//     root kabuktaki gözcü bunu (ya da Tazele kapanınca soketin kapanmasını) görüp komutu sonlandırır.
//  2. osascript: `do shell script … with administrator privileges` (yine sistem penceresi). Komut
//     çıktısı Tazele'ye ait özel bir geçici dizindeki dosyaya yazılır ve oradan izlenir. İptal için o
//     dizinde bir işaret dosyası oluşturulur; root betik bunu, dizinin silinmesini ya da Tazele'nin
//     kapanmasını görünce komutu sonlandırır. Geçici dizin her durumda silinir.
//  3. sudoAskpass: `sudo -A` + `SUDO_ASKPASS` parola penceresi (eski yol).
//
// Bir yöntem `PrivilegeError.unavailable` ile başarısız olursa sıradaki denenir. Kullanıcı pencereyi
// iptal ederse ya da izin verilmezse zincir durur (aynı soru farklı bir pencereyle tekrar sorulmaz).
// Yöntem `UserDefaults` içindeki "privilegeMechanism" anahtarıyla elle seçilebilir.
//
// Yetkinin yeniden kullanımı (bir güncelleme turunda tek soru):
//  - authorizationServices: tek bir `AuthorizationRef` süreç boyunca saklanır. `system.privilege.admin`
//    hakkının kimlik bilgisi 300 sn geçerlidir (`security authorizationdb read system.privilege.admin`
//    → timeout 300, shared false); bu süre içindeki ikinci adım pencere açmaz. 300 sn boşta kalan
//    referans hakları silinerek bırakılır, sonraki adım yeniden sorar.
//  - sudoAskpass: terminal olmadığından `sudo` zaman damgasını üst süreç kimliğine (Tazele) bağlar;
//    varsayılan 5 dakika içinde ikinci `sudo` parola sormaz.
//  - osascript: her `osascript` ayrı bir süreç olduğundan her adımda yeniden sorabilir. Bu yöntem
//    yalnızca birincisi kullanılamazsa devreye girer.
//
// Güvenlik sınırları: Tazele'nin kendi ikili dosyası hiçbir zaman root olarak çalışmaz; ayrıcalıklı
// yardımcı ya da launch daemon kurulmaz; sistem dosyalarına dokunulmaz. Root olarak yalnızca
// `PrivilegedCommand.allowedTools` içindeki araçlar, doğrulanmış argümanlarla çalışır.
//
// Not (yalnızca belge): sudo yolunda da Touch ID istenirse kullanıcı kendisi
// `/etc/pam.d/sudo_local` dosyasına `auth sufficient pam_tid.so` satırını ekleyebilir
// (`/etc/pam.d/sudo_local.template` örneğine bakın). Tazele bu dosyaları değiştirmez.

/// Ayrıcalıklı komutu yürüten bir yöntem. Testlerde sahtesi verilir.
protocol PrivilegeBackend: Sendable {
    /// `command` doğrulanmış ve mutlak yollu olmalıdır.
    func run(_ command: [String], onLine: (@Sendable (String) -> Void)?) async throws -> CommandResult
}

/// Root gerektiren komutları yürütür.
public enum PrivilegedRunner {
    /// İzin penceresinde gösterilen açıklama.
    static var prompt: String {
        String(localized: "Tazele, App Store ve macOS güncellemelerini yüklemek için yönetici izni istiyor.", bundle: .main)
    }

    public static func run(_ command: [String], runner: CommandRunner,
                           onLine: (@Sendable (String) -> Void)? = nil) async throws -> CommandResult {
        let resolved = try PrivilegedCommand.validate(command)
        let chain = PrivilegeMechanism.chain(preferred: .preferred(), isAvailable: { $0.isAvailableOnThisSystem })
        return try await run(resolved, chain: chain, backend: { backend(for: $0, runner: runner) }, onLine: onLine)
    }

    static func backend(for mechanism: PrivilegeMechanism, runner: CommandRunner) -> any PrivilegeBackend {
        switch mechanism {
        case .authorizationServices: AuthorizationServicesBackend()
        case .osascript: OsascriptBackend(runner: runner)
        case .sudoAskpass: SudoAskpassBackend(runner: runner)
        }
    }

    /// Zinciri sırayla dener; yalnızca `.unavailable` bir sonrakine geçirir.
    static func run(_ command: [String], chain: [PrivilegeMechanism],
                    backend: (PrivilegeMechanism) -> any PrivilegeBackend,
                    onLine: (@Sendable (String) -> Void)?) async throws -> CommandResult {
        var lastError = PrivilegeError.noMechanism
        for (index, mechanism) in chain.enumerated() {
            try Task.checkCancellation()
            do {
                return try await backend(mechanism).run(command, onLine: onLine)
            } catch let error as PrivilegeError {
                guard case .unavailable = error else { throw error }
                lastError = error
                if index < chain.count - 1 {
                    onLine?(String(localized: "Sistem izin penceresi açılamadı; başka bir yöntem deneniyor.", bundle: .main))
                }
            }
        }
        throw lastError
    }

    /// Sarmalayıcı betiklerin işaret satırları için tahmin edilemez bir belirteç.
    static func makeNonce() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "") }
}

// MARK: - Root sarmalayıcı betikleri

enum RootScript {
    static let zsh = "/bin/zsh"
    static let safePath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// authorizationServices için: `zsh -f -p -c <betik> tazele-priv <belirteç> <araç> <argümanlar…>`.
    /// Betik sabittir; araç ve argümanlar konumsal parametre olarak geçer, kabukça ayrıştırılmaz.
    /// `-p`: etkin kimlik ≠ gerçek kimlik olduğunda zsh yetkiyi bırakmasın; ardından `UID=0` ile
    /// gerçek kimlik de root yapılır (bazı araçlar `getuid() == 0` bekler). `-f`: başlangıç dosyası okunmaz.
    /// Standart girdi Tazele'ye giden sokettir: oradan bir satır gelirse ya da soket kapanırsa komut sonlandırılır.
    static let zshBody = """
    n=$1; shift
    if [ "$EUID" -eq 0 ] && [ "$UID" -ne 0 ]; then UID=0; fi
    if [ "$EUID" -eq 0 ]; then HOME=/var/root; export HOME; fi
    PATH=\(safePath); export PATH
    print -r -- "__TAZELE_${n}_PID__ $$"
    exec 3<&0
    "$@" </dev/null 3<&- 2>&1 &
    p=$!
    { read -r -u 3 x; kill -TERM $p 2>/dev/null; sleep 2; kill -KILL $p 2>/dev/null } &
    w=$!
    wait $p; s=$?
    kill $w 2>/dev/null
    print -r -- "__TAZELE_${n}_EXIT__ $s"
    """

    static func zshArguments(nonce: String, command: [String]) -> [String] {
        ["-f", "-p", "-c", zshBody, "tazele-priv", nonce] + command
    }

    /// osascript için POSIX `sh` betiği. Çıktı `directory/output.log` dosyasına eklenir; `directory/cancel`
    /// oluşursa, dizin silinirse ya da `watchedPID` sona ererse komut sonlandırılır.
    static func shell(command: [String], nonce: String, directory: URL, watchedPID: pid_t) -> String {
        let q = PrivilegedCommand.shellQuote
        let marker = "printf '__TAZELE_%s_EXIT__ %d\\n' \(q(nonce))"
        return """
        d=\(q(directory.path)); o="$d/output.log"; c="$d/cancel"; w=\(watchedPID)
        [ -d "$d" ] && [ -f "$o" ] && [ ! -L "$o" ] || exit 0
        exec 3>>"$o"
        if [ -e "$c" ]; then \(marker) 143 >&3; exit 0; fi
        PATH=\(safePath); export PATH
        if [ "$(id -u)" = 0 ]; then HOME=/var/root; export HOME; fi
        \(command.map(q).joined(separator: " ")) </dev/null >&3 2>&1 3>&- &
        p=$!
        while kill -0 "$p" 2>/dev/null; do
          if [ -e "$c" ] || [ ! -d "$d" ] || ! kill -0 "$w" 2>/dev/null; then
            kill -TERM "$p" 2>/dev/null; sleep 2; kill -KILL "$p" 2>/dev/null; break
          fi
          sleep 0.2
        done
        wait "$p"; s=$?
        \(marker) "$s" >&3
        exit 0
        """
    }

    static func appleScript(shell: String, administrator: Bool, prompt: String) -> String {
        var s = "do shell script " + PrivilegedCommand.appleScriptLiteral(shell)
        if administrator {
            s += " with prompt " + PrivilegedCommand.appleScriptLiteral(prompt) + " with administrator privileges"
        }
        return s
    }
}

// MARK: - Çıktı ayrıştırıcı

/// Root kabuğunun çıktısını satırlara böler; sarmalayıcının işaret satırlarını (süreç kimliği,
/// çıkış kodu) ayıklar. Çıkış kodundan sonra gelenler yok sayılır.
final class PrivilegedOutputParser: @unchecked Sendable {
    private let lock = NSLock()
    private let exitMarker: String
    private let pidMarker: String
    private let onLine: (@Sendable (String) -> Void)?
    private var buffer = Data()
    private var partial = Data()
    private var status: Int32?
    private var pid: pid_t?

    init(nonce: String, onLine: (@Sendable (String) -> Void)?) {
        exitMarker = "__TAZELE_\(nonce)_EXIT__ "
        pidMarker = "__TAZELE_\(nonce)_PID__ "
        self.onLine = onLine
    }

    var exitStatus: Int32? { lock.withLock { status } }
    var childPID: pid_t? { lock.withLock { pid } }
    var output: Data { lock.withLock { buffer } }

    func feed(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        let lines: [String] = lock.withLock {
            partial.append(chunk)
            var visible: [String] = []
            while let nl = partial.firstIndex(of: 0x0A) {
                let line = String(decoding: partial[partial.startIndex..<nl], as: UTF8.self)
                partial = Data(partial[partial.index(after: nl)...])
                if let text = consume(line) { visible.append(text) }
            }
            return visible
        }
        lines.forEach { onLine?($0) }
    }

    /// Satır sonu olmadan kalan son parçayı da işler.
    func finish() {
        let line: String? = lock.withLock {
            guard !partial.isEmpty else { return nil }
            let text = String(decoding: partial, as: UTF8.self)
            partial = Data()
            return consume(text)
        }
        if let line { onLine?(line) }
    }

    /// Kilit altında çağrılır. Görünür metni döndürür; işaret satırıysa nil.
    private func consume(_ line: String) -> String? {
        guard status == nil else { return nil }
        if let r = line.range(of: exitMarker) {
            status = Int32(line[r.upperBound...].trimmingCharacters(in: .whitespaces)) ?? -1
            let head = String(line[..<r.lowerBound])
            guard !head.isEmpty else { return nil }
            buffer.append(Data((head + "\n").utf8))
            return head
        }
        if line.hasPrefix(pidMarker) {
            pid = pid_t(line.dropFirst(pidMarker.count).trimmingCharacters(in: .whitespaces))
            return nil
        }
        buffer.append(Data((line + "\n").utf8))
        return line
    }

    func result(timedOut: Bool = false) -> CommandResult? {
        guard let status = exitStatus else { return nil }
        return CommandResult(status: status, output: output, timedOut: timedOut)
    }
}

/// Büyüyen bir dosyanın yeni eklenen kısmını okur.
final class FileTail {
    let url: URL
    private(set) var offset: UInt64 = 0

    init(url: URL) { self.url = url }

    func readNew() -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd() else { return Data() }
        offset += UInt64(data.count)
        return data
    }
}

/// Engellemeyen bekleme: iptal edilmiş görevde de gerçekten bekler (temizlik döngüleri için).
func pause(_ seconds: Double) async {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { c.resume() }
    }
}

// MARK: - 1) Authorization Services

/// `AuthorizationExecuteWithPrivileges` Swift'e aktarılmıyor; sembol çalışma anında bulunur.
enum AuthorizationTool {
    typealias Function = @convention(c) (
        OpaquePointer, UnsafePointer<CChar>, UInt32,
        UnsafePointer<UnsafeMutablePointer<CChar>?>, UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
    ) -> OSStatus

    static var function: Function? {
        // RTLD_DEFAULT == (void *)-2
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "AuthorizationExecuteWithPrivileges")
        else { return nil }
        return unsafeBitCast(symbol, to: Function.self)
    }

    static func error(for status: OSStatus) -> PrivilegeError {
        switch status {
        case errAuthorizationCanceled: .canceled
        case errAuthorizationDenied: .denied
        default: .unavailable(.authorizationServices, "OSStatus \(status)")
        }
    }
}

/// Root kabuğuyla iki yönlü soket. Okuma tek iş parçacığında; iptal baytı başka yerden yazılabilir.
final class PrivilegedChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var file: UnsafeMutablePointer<FILE>?
    let fd: Int32
    private var closed = false
    private var cancelSent = false

    init(file: UnsafeMutablePointer<FILE>) {
        self.file = file
        fd = fileno(file)
        Self.disableSigpipe(fd)
    }

    /// Testler için: doğrudan bir soket ucu.
    init(fd: Int32) {
        self.fd = fd
        Self.disableSigpipe(fd)
    }

    private static func disableSigpipe(_ fd: Int32) {
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Root kabuktaki gözcüye "durdur" der. Birden çok çağrı zararsızdır.
    func requestCancel() {
        lock.withLock {
            guard !closed, !cancelSent else { return }
            cancelSent = true
            _ = "x\n".withCString { write(fd, $0, 2) }
        }
    }

    /// Çıkış kodu gelene ya da soket kapanana kadar okur (engeller).
    func pump(into parser: PrivilegedOutputParser) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while parser.exitStatus == nil {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 { parser.feed(Data(buffer[0..<n])) }
            else if n < 0 && errno == EINTR { continue }
            else { break }
        }
        parser.finish()
    }

    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            if let file { fclose(file) } else { Darwin.close(fd) }
            file = nil
        }
    }

    /// Okumayı arka planda yapar; görev iptal edilirse gözcüye haber verir.
    static func collect(_ channel: PrivilegedChannel, into parser: PrivilegedOutputParser) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    channel.pump(into: parser)
                    c.resume()
                }
            }
        } onCancel: {
            channel.requestCancel()
        }
    }
}

/// Süreç boyunca tek `AuthorizationRef`. Tüm durum seri kuyrukta değişir.
final class AuthorizationSession: @unchecked Sendable {
    static let shared = AuthorizationSession()
    /// `system.privilege.admin` kuralındaki zaman aşımıyla aynı.
    static let idleLimit: TimeInterval = 300

    private let queue = DispatchQueue(label: "com.yigitbuyukeren.tazele.authorization")
    private var ref: AuthorizationRef?
    private var lastUse: Date?

    /// Gerekirse izin penceresini açar, sonra `tool`'u root olarak başlatır ve soketini döndürür.
    func launch(tool: String, arguments: [String], prompt: String, iconPath: String?,
                isCancelled: @escaping @Sendable () -> Bool) async throws -> PrivilegedChannel {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<PrivilegedChannel, Error>) in
            queue.async {
                c.resume(with: Result {
                    try self.launchOnQueue(tool: tool, arguments: arguments, prompt: prompt,
                                           iconPath: iconPath, isCancelled: isCancelled)
                })
            }
        }
    }

    private func launchOnQueue(tool: String, arguments: [String], prompt: String, iconPath: String?,
                               isCancelled: () -> Bool) throws -> PrivilegedChannel {
        guard let execute = AuthorizationTool.function else {
            throw PrivilegeError.unavailable(.authorizationServices, "AuthorizationExecuteWithPrivileges")
        }
        if let lastUse, Date().timeIntervalSince(lastUse) > Self.idleLimit { reset() }
        if ref == nil {
            var created: AuthorizationRef?
            let status = AuthorizationCreate(nil, nil, [], &created)
            guard status == errAuthorizationSuccess, let created else { throw AuthorizationTool.error(for: status) }
            ref = created
        }
        guard let ref else { throw PrivilegeError.noMechanism }

        // Önceden yetkilendirme: pencere burada açılır (hak geçerliyse açılmaz).
        let status = Self.copyRights(ref, prompt: prompt, iconPath: iconPath)
        guard status == errAuthorizationSuccess else {
            if status != errAuthorizationCanceled { reset() }
            throw AuthorizationTool.error(for: status)
        }
        if isCancelled() { throw CancellationError() }

        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pipe: UnsafeMutablePointer<FILE>?
        let launched = tool.withCString { path in
            argv.withUnsafeBufferPointer { execute(ref, path, 0, $0.baseAddress!, &pipe) }
        }
        guard launched == errAuthorizationSuccess, let pipe else {
            reset()
            throw AuthorizationTool.error(for: launched)
        }
        lastUse = Date()
        return PrivilegedChannel(file: pipe)
    }

    private static func copyRights(_ ref: AuthorizationRef, prompt: String, iconPath: String?) -> OSStatus {
        var owned: [UnsafeMutablePointer<CChar>] = []
        defer { owned.forEach { free($0) } }
        func c(_ s: String) -> UnsafeMutablePointer<CChar> { let p = strdup(s)!; owned.append(p); return p }

        var right = AuthorizationItem(name: c(kAuthorizationRightExecute), valueLength: 0, value: nil, flags: 0)
        var env: [AuthorizationItem] = []
        let promptC = c(prompt)
        env.append(AuthorizationItem(name: c(kAuthorizationEnvironmentPrompt), valueLength: strlen(promptC),
                                     value: UnsafeMutableRawPointer(promptC), flags: 0))
        if let iconPath {
            let iconC = c(iconPath)
            env.append(AuthorizationItem(name: c(kAuthorizationEnvironmentIcon), valueLength: strlen(iconC),
                                         value: UnsafeMutableRawPointer(iconC), flags: 0))
        }
        let flags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
        return withUnsafeMutablePointer(to: &right) { rightPtr in
            env.withUnsafeMutableBufferPointer { envPtr in
                var rights = AuthorizationRights(count: 1, items: rightPtr)
                var environment = AuthorizationEnvironment(count: UInt32(envPtr.count), items: envPtr.baseAddress)
                return AuthorizationCopyRights(ref, &rights, &environment, flags, nil)
            }
        }
    }

    /// Hakları silerek referansı bırakır; sonraki çalıştırma yeniden sorar.
    private func reset() {
        if let ref { AuthorizationFree(ref, [.destroyRights]) }
        ref = nil
        lastUse = nil
    }

    /// Kuyruktaki kullanımdan sonra boşta kalma süresi yeniden başlar.
    func touch() { queue.async { if self.ref != nil { self.lastUse = Date() } } }
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

struct AuthorizationServicesBackend: PrivilegeBackend {
    var session = AuthorizationSession.shared

    func run(_ command: [String], onLine: (@Sendable (String) -> Void)?) async throws -> CommandResult {
        let nonce = PrivilegedRunner.makeNonce()
        let cancelled = CancelFlag()
        let icon = Bundle.main.path(forResource: "AppIcon", ofType: "icns")
        let channel = try await withTaskCancellationHandler {
            try await session.launch(tool: RootScript.zsh,
                                     arguments: RootScript.zshArguments(nonce: nonce, command: command),
                                     prompt: PrivilegedRunner.prompt, iconPath: icon,
                                     isCancelled: { cancelled.isSet })
        } onCancel: { cancelled.set() }
        defer { session.touch() }

        let parser = PrivilegedOutputParser(nonce: nonce, onLine: onLine)
        await PrivilegedChannel.collect(channel, into: parser)
        channel.close()
        if let pid = parser.childPID { Self.reap(pid) }
        if let result = parser.result() { return result }
        if Task.isCancelled { return CommandResult(status: 128 + SIGTERM, output: parser.output, timedOut: false) }
        throw PrivilegeError.incompleteOutput
    }

    /// `AuthorizationExecuteWithPrivileges` çocuğu Tazele'nin alt sürecidir; zombi kalmasın.
    static func reap(_ pid: pid_t) {
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            for _ in 0..<50 {
                let r = waitpid(pid, &status, WNOHANG)
                if r != 0 { return }   // toplandı ya da bizim çocuğumuz değil
                usleep(100_000)
            }
        }
    }
}

// MARK: - 2) osascript

private final class LaunchBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<CommandResult, Error>?
    var result: Result<CommandResult, Error>? { lock.withLock { value } }
    func set(_ r: Result<CommandResult, Error>) { lock.withLock { value = r } }
}

struct OsascriptBackend: PrivilegeBackend {
    let runner: CommandRunner
    /// Testlerde false: aynı betik yetkisiz çalışır, pencere açılmaz.
    var administrator = true
    var temporaryRoot = FileManager.default.temporaryDirectory
    var pollInterval = 0.2
    /// İptalden sonra root betiğin çıkış kodunu yazması için beklenen en uzun süre.
    var cancelGrace = 5.0

    func run(_ command: [String], onLine: (@Sendable (String) -> Void)?) async throws -> CommandResult {
        let directory = try Self.makePrivateDirectory(in: temporaryRoot)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("output.log")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw PrivilegeError.unavailable(.osascript, outputURL.path) }

        let nonce = PrivilegedRunner.makeNonce()
        let shell = RootScript.shell(command: command, nonce: nonce, directory: directory, watchedPID: getpid())
        let script = RootScript.appleScript(shell: shell, administrator: administrator, prompt: PrivilegedRunner.prompt)
        let parser = PrivilegedOutputParser(nonce: nonce, onLine: onLine)
        let tail = FileTail(url: outputURL)

        let box = LaunchBox()
        let runner = self.runner
        let launch = Task {
            do { box.set(.success(try await runner.run(["/usr/bin/osascript", "-e", script]))) }
            catch { box.set(.failure(error)) }
        }

        var cancelledAt: Date?
        while true {
            parser.feed(tail.readNew())
            if parser.exitStatus != nil { break }
            if let launched = box.result {
                parser.feed(tail.readNew())
                parser.finish()
                if parser.exitStatus != nil { break }
                if cancelledAt != nil { break }
                throw Self.error(from: launched)
            }
            if Task.isCancelled {
                if cancelledAt == nil {
                    cancelledAt = Date()
                    FileManager.default.createFile(atPath: directory.appendingPathComponent("cancel").path, contents: nil)
                } else if let at = cancelledAt, Date().timeIntervalSince(at) > cancelGrace {
                    break
                }
            }
            await pause(pollInterval)
        }
        parser.finish()
        if cancelledAt != nil { launch.cancel() }
        await launch.value
        if let result = parser.result() { return result }
        return CommandResult(status: 128 + SIGTERM, output: parser.output, timedOut: false)
    }

    /// osascript çıkış koduna göre hata: -128 iptal, -60005 ret, diğerleri yöntem kullanılamaz.
    static func error(from launched: Result<CommandResult, Error>) -> PrivilegeError {
        switch launched {
        case .failure(let error):
            return .unavailable(.osascript, error.localizedDescription)
        case .success(let r):
            if r.text.contains("(-128)") { return .canceled }
            if r.text.contains("(-60005)") { return .denied }
            if r.status == 0 { return .incompleteOutput }
            return .unavailable(.osascript, r.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Yalnızca kullanıcının erişebildiği (0700) yeni bir dizin.
    static func makePrivateDirectory(in root: URL) throws -> URL {
        var template = Array(root.appendingPathComponent("tazele-priv-XXXXXXXX").path.utf8CString)
        guard let made = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) }) else {
            throw PrivilegeError.unavailable(.osascript, "mkdtemp \(errno)")
        }
        return URL(fileURLWithPath: String(cString: made), isDirectory: true)
    }
}

// MARK: - 3) sudo -A

struct SudoAskpassBackend: PrivilegeBackend {
    let runner: CommandRunner

    func run(_ command: [String], onLine: (@Sendable (String) -> Void)?) async throws -> CommandResult {
        // SUDO_ASKPASS ortamı `ShellEnvironment.make()` içinde kurulur.
        try await runner.run(["/usr/bin/sudo", "-A", "--"] + command, onLine: onLine)
    }
}
