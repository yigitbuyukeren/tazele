import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let output: Data
    public var text: String { String(decoding: output, as: UTF8.self) }
}

/// GUI uygulamaları kabuğun PATH'ini almaz; bu yüzden ortam açıkça kurulur.
public enum Environment {
    public static func make() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extra = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "\(home)/.local/bin",
                     "\(home)/.cargo/bin", "\(home)/.volta/bin"]
        env["PATH"] = (extra + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["MAS_NO_AUTO_INDEX"] = "1"
        env["NONINTERACTIVE"] = "1"
        env["CI"] = "1"
        return env
    }
}

/// Tek seferde bir komut çalıştırır (brew gibi kilitli araçlar sıralı olmalı).
public actor CommandRunner {
    public init() {}

    /// Komutu çalıştırır; satırlar geldikçe `onLine` ile bildirilir. İptalde süreç sonlandırılır.
    public func run(_ command: [String], onLine: (@Sendable (String) -> Void)? = nil) async throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.environment = Environment.make()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let collector = Collector(onLine: onLine)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { collector.append(chunk) }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CommandResult, Error>) in
                process.terminationHandler = { p in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    collector.append(pipe.fileHandleForReading.readDataToEndOfFile())
                    cont.resume(returning: CommandResult(status: p.terminationStatus, output: collector.data))
                }
                do { try process.run() } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    cont.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
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
