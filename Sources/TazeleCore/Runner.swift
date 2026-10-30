import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let output: Data
    public let timedOut: Bool
    public var text: String { String(decoding: output, as: UTF8.self) }
}

/// GUI uygulamaları kabuğun PATH'ini almaz; bu yüzden ortam açıkça kurulur.
public enum ShellEnvironment {
    /// Kullanıcının giriş kabuğundaki PATH (nvm, asdf, pnpm vb.). Bir kez okunur, önbelleğe alınır.
    static let loginPath: [String] = readLoginPath()

    private static func readLoginPath(timeout: TimeInterval = 5) -> [String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap {
            FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "printf '\\n__TAZELE_PATH__%s\\n' \"$PATH\""]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        guard (try? process.run()) != nil else { return [] }
        if done.wait(timeout: .now() + timeout) == .timedOut { process.terminate(); return [] }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let line = text.split(separator: "\n").last(where: { $0.hasPrefix("__TAZELE_PATH__") }) else { return [] }
        return line.dropFirst("__TAZELE_PATH__".count).split(separator: ":").map(String.init)
    }

    /// Bilinen kalan risk: bu PATH'teki kullanıcı klasörleri (Homebrew, ~/.local/bin, giriş kabuğundan gelenler)
    /// sistem klasörlerinden önce gelir ve giriş kabuğu okunurken kullanıcının başlangıç dosyaları çalışır.
    /// Aynı kullanıcıyla çalışan bir süreç buralara bir `brew`/`npm`/`sh` koyarak kullanıcı yetkisiyle kod
    /// çalıştırabilir; bu, kullanıcının kendi terminalindeki durumla aynıdır ve yetki yükseltmez. Root olarak
    /// çalışan hiçbir şey bu PATH'e güvenmez: araçlar `PrivilegedCommand.trustedTool` ile yalnızca root'a ait
    /// konumlardan seçilir, root sarmalayıcıları PATH'i sistem klasörlerine sıfırlar.
    public static func make() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let known = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "\(home)/.local/bin",
                     "\(home)/.cargo/bin", "\(home)/.volta/bin"]
        var seen = Set<String>()
        env["PATH"] = (known + loginPath + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
            .filter { seen.insert($0).inserted }.joined(separator: ":")
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_NO_ASK"] = "1"   // brew 6 varsayılan olarak onay ister; GUI'de takılır
        env["MAS_NO_AUTO_INDEX"] = "1"
        env["NONINTERACTIVE"] = "1"
        env["CI"] = "1"
        // Terminalsiz ortamda sudo / brew parolayı bu pencereden sorar. Betik burada, yani her komut
        // başlatılmadan hemen önce, bütünlüğü için yeniden denetlenir (bkz. `Privilege.installAskpass`).
        // Kurulum başarısız olsa bile devralınmış bir askpass yolunu kullanma.
        env.removeValue(forKey: "SUDO_ASKPASS")
        if let askpass = try? Privilege.installAskpass() { env["SUDO_ASKPASS"] = askpass.path }
        return env
    }
}

/// Tek seferde bir komut çalıştırır (brew gibi kilitli araçlar sıralı olmalı).
public actor CommandRunner {
    public init() {}

    /// Komutu çalıştırır; satırlar geldikçe `onLine` ile bildirilir. İptalde veya zaman aşımında
    /// süreç sonlandırılır (önce SIGTERM, 2 sn sonra SIGKILL).
    public func run(_ command: [String], timeout: TimeInterval? = nil,
                    onLine: (@Sendable (String) -> Void)? = nil) async throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.environment = ShellEnvironment.make()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let collector = Collector(onLine: onLine)
        let timeoutFlag = TimeoutFlag()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { collector.append(chunk) }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CommandResult, Error>) in
                process.terminationHandler = { p in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    collector.append(pipe.fileHandleForReading.readDataToEndOfFile())
                    cont.resume(returning: CommandResult(status: p.terminationStatus, output: collector.data,
                                                         timedOut: timeoutFlag.value))
                }
                do { try process.run() } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    cont.resume(throwing: error)
                    return
                }
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                        guard process.isRunning else { return }
                        timeoutFlag.set()
                        process.terminate()
                        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                        }
                    }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var partial = ""
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

    var data: Data { lock.withLock { buffer } }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        let lines: [String] = lock.withLock {
            buffer.append(chunk)
            partial += String(decoding: chunk, as: UTF8.self)
            var parts = partial.components(separatedBy: "\n")
            partial = parts.removeLast()
            return parts
        }
        lines.forEach { onLine?($0) }
    }
}
