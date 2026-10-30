import Foundation

/// Root gerektiren komutları yürütür. Şimdilik `sudo -A` + parola penceresi (SUDO_ASKPASS) kullanır.
public enum PrivilegedRunner {
    public static func run(_ command: [String], runner: CommandRunner,
                           onLine: (@Sendable (String) -> Void)? = nil) async throws -> CommandResult {
        try await runner.run(["sudo", "-A"] + command, onLine: onLine)
    }
}
