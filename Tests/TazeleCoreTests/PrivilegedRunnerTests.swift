import Foundation
import Testing
@testable import TazeleCore

/// Bu testler hiçbir zaman izin penceresi açmaz ve hiçbir komutu root olarak çalıştırmaz.
/// Sarmalayıcı betikler yetkisiz (kullanıcı olarak) çalıştırılıp davranışları denetlenir.
/// Tek istisna `manualSelfTest`: yalnızca TAZELE_PRIV_SELFTEST=1 ile, elle çalıştırılır.
@Suite struct PrivilegedRunnerTests {

    // MARK: Doğrulama ve tırnaklama

    @Test func validatesMasWithNumericIDs() throws {
        let cmd = try PrivilegedCommand.validate(["mas", "update", "111", "222"], searchPath: "/opt/homebrew/bin:/usr/local/bin")
        if let first = cmd.first { #expect(first.hasPrefix("/") && first.hasSuffix("/mas")) }
        #expect(Array(cmd.dropFirst()) == ["update", "111", "222"])
    }

    @Test(arguments: [
        ["mas", "update", "123; rm -rf /"],
        ["mas", "update", "12a"],
        ["mas", "update"],
        ["mas", "purchase", "123"],
        ["mas", "update", "$(id)"],
        ["softwareupdate", "-i", "--all"],
        ["softwareupdate", "-i", "Label`id`"],
        ["softwareupdate", "-i", "Label\nnext"],
        ["softwareupdate", "-l"],
        ["softwareupdate", "-i"],
        ["softwareupdate", "-i", "İçerik"],
        ["/bin/sh", "-c", "id"],
        ["rm", "-rf", "/"],
        [],
    ])
    func rejectsUnsafeCommands(_ command: [String]) {
        #expect(throws: PrivilegeError.self) { try PrivilegedCommand.validate(command, searchPath: "/opt/homebrew/bin") }
    }

    @Test func validatesSoftwareUpdateLabels() throws {
        let cmd = try PrivilegedCommand.validate(["softwareupdate", "-i", "Command Line Tools for Xcode 26.1-26.1 (beta)"],
                                                 searchPath: "")
        #expect(cmd == ["/usr/sbin/softwareupdate", "-i", "Command Line Tools for Xcode 26.1-26.1 (beta)"])
        let flagged = try PrivilegedCommand.validate(["softwareupdate", "-i", "--agree-to-license", "A-1"], searchPath: "")
        #expect(flagged.last == "A-1")
    }

    @Test func toolPathsMustBeCleanAbsoluteAndExecutable() {
        #expect(throws: PrivilegeError.toolNotFound("/usr/sbin/../sbin/softwareupdate")) {
            try PrivilegedCommand.validate(["/usr/sbin/../sbin/softwareupdate", "-i", "A"], searchPath: "")
        }
        #expect(throws: PrivilegeError.toolNotFound("/nonexistent/mas")) {
            try PrivilegedCommand.validate(["/nonexistent/mas", "update", "1"], searchPath: "")
        }
        #expect(throws: PrivilegeError.toolNotFound("mas")) {
            try PrivilegedCommand.validate(["mas", "update", "1"], searchPath: "/nonexistent")
        }
    }

    @Test func safeArgumentPattern() {
        for ok in ["abc", "A.b_c 1+2(3)-4", "123"] { #expect(PrivilegedCommand.isSafeArgument(ok)) }
        for bad in ["", "a;b", "a'b", "a\"b", "a$b", "a\\b", "ç", "a/b", "a\tb"] { #expect(!PrivilegedCommand.isSafeArgument(bad)) }
        #expect(PrivilegedCommand.isNumeric("0123") && !PrivilegedCommand.isNumeric("1.2") && !PrivilegedCommand.isNumeric("١"))
    }

    @Test func quoting() {
        #expect(PrivilegedCommand.shellQuote("it's") == "'it'\\''s'")
        #expect(PrivilegedCommand.appleScriptLiteral("a\"b\\c\nd") == "\"a\\\"b\\\\c\\nd\"")
        let s = RootScript.appleScript(shell: "echo 1", administrator: true, prompt: "P \"x\"")
        #expect(s == "do shell script \"echo 1\" with prompt \"P \\\"x\\\"\" with administrator privileges")
        #expect(RootScript.appleScript(shell: "echo 1", administrator: false, prompt: "P") == "do shell script \"echo 1\"")
    }

    // MARK: Yöntem seçimi ve yedek zinciri

    @Test func chainSelection() {
        let all: (PrivilegeMechanism) -> Bool = { _ in true }
        #expect(PrivilegeMechanism.chain(preferred: nil, isAvailable: all) == [.authorizationServices, .osascript, .sudoAskpass])
        #expect(PrivilegeMechanism.chain(preferred: .osascript, isAvailable: all) == [.osascript, .sudoAskpass])
        #expect(PrivilegeMechanism.chain(preferred: .sudoAskpass, isAvailable: all) == [.sudoAskpass])
        #expect(PrivilegeMechanism.chain(preferred: nil, isAvailable: { $0 != .authorizationServices }) == [.osascript, .sudoAskpass])
        #expect(PrivilegeMechanism.chain(preferred: .authorizationServices, isAvailable: { $0 == .sudoAskpass }) == [.sudoAskpass])
        #expect(PrivilegeMechanism.chain(preferred: nil, isAvailable: { _ in false }).isEmpty)
    }

    @Test func preferredMechanismFromDefaults() throws {
        let suite = "tazele-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(PrivilegeMechanism.preferred(in: defaults) == nil)
        defaults.set("osascript", forKey: PrivilegeMechanism.defaultsKey)
        #expect(PrivilegeMechanism.preferred(in: defaults) == .osascript)
        defaults.set("bogus", forKey: PrivilegeMechanism.defaultsKey)
        #expect(PrivilegeMechanism.preferred(in: defaults) == nil)
    }

    @Test func thisSystemHasAtLeastOneMechanism() {
        #expect(PrivilegeMechanism.allCases.contains { $0.isAvailableOnThisSystem })
    }

    struct FakeBackend: PrivilegeBackend {
        let outcome: Result<Int32, PrivilegeError>
        let calls: Calls
        let mechanism: PrivilegeMechanism
        func run(_ command: [String], onLine: (@Sendable (String) -> Void)?) async throws -> CommandResult {
            calls.add(mechanism)
            switch outcome {
            case .success(let s): return CommandResult(status: s, output: Data(), timedOut: false)
            case .failure(let e): throw e
            }
        }
    }

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [PrivilegeMechanism] = []
        func add(_ m: PrivilegeMechanism) { lock.withLock { list.append(m) } }
        var all: [PrivilegeMechanism] { lock.withLock { list } }
    }

    private func runChain(_ outcomes: [PrivilegeMechanism: Result<Int32, PrivilegeError>],
                          chain: [PrivilegeMechanism] = PrivilegeMechanism.allCases) async -> (Result<Int32, Error>, [PrivilegeMechanism]) {
        let calls = Calls()
        do {
            let r = try await PrivilegedRunner.run(["/usr/bin/true"], chain: chain, backend: { m in
                FakeBackend(outcome: outcomes[m] ?? .success(0), calls: calls, mechanism: m)
            }, onLine: nil)
            return (.success(r.status), calls.all)
        } catch { return (.failure(error), calls.all) }
    }

    @Test func fallsBackOnlyWhenUnavailable() async {
        let (r1, c1) = await runChain([.authorizationServices: .failure(.unavailable(.authorizationServices, "x")),
                                       .osascript: .success(7)])
        #expect(c1 == [.authorizationServices, .osascript])
        #expect((try? r1.get()) == 7)

        // Kullanıcı iptal ederse başka pencere açılmaz.
        let (r2, c2) = await runChain([.authorizationServices: .failure(.canceled)])
        #expect(c2 == [.authorizationServices])
        #expect(throws: PrivilegeError.canceled) { try r2.get() }

        let (r3, c3) = await runChain([.authorizationServices: .failure(.denied)])
        #expect(c3 == [.authorizationServices])
        #expect(throws: PrivilegeError.denied) { try r3.get() }

        // Komutun kendi hata kodu yöntem değiştirmez.
        let (r4, c4) = await runChain([.authorizationServices: .success(3)])
        #expect(c4 == [.authorizationServices] && (try? r4.get()) == 3)

        let unavailable: Result<Int32, PrivilegeError> = .failure(.unavailable(.sudoAskpass, "x"))
        let (r5, c5) = await runChain([.authorizationServices: unavailable, .osascript: unavailable, .sudoAskpass: unavailable])
        #expect(c5 == PrivilegeMechanism.allCases)
        #expect(throws: PrivilegeError.unavailable(.sudoAskpass, "x")) { try r5.get() }

        let (r6, c6) = await runChain([:], chain: [])
        #expect(c6.isEmpty)
        #expect(throws: PrivilegeError.noMechanism) { try r6.get() }
    }

    @Test func publicRunRejectsBeforeAnyPrompt() async {
        await #expect(throws: PrivilegeError.self) {
            try await PrivilegedRunner.run(["mas", "update", "1;id"], runner: CommandRunner())
        }
    }

    // MARK: Çıktı ayrıştırıcı

    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        func add(_ s: String) { lock.withLock { list.append(s) } }
        var all: [String] { lock.withLock { list } }
    }

    @Test func parserSplitsChunksAndStripsMarkers() {
        let lines = Lines()
        let p = PrivilegedOutputParser(nonce: "N1", onLine: { lines.add($0) })
        p.feed(Data("__TAZELE_N1_PID__ 4242\nbir".utf8))
        p.feed(Data(" iki\nüç\n__TAZELE_OTHER_EXIT__ 9\n".utf8))
        #expect(p.exitStatus == nil)
        p.feed(Data("son__TAZELE_N1_EXIT__ 3\nsonra\n".utf8))
        p.finish()
        #expect(p.childPID == 4242)
        #expect(p.exitStatus == 3)
        #expect(lines.all == ["bir iki", "üç", "__TAZELE_OTHER_EXIT__ 9", "son"])
        #expect(String(decoding: p.output, as: UTF8.self) == "bir iki\nüç\n__TAZELE_OTHER_EXIT__ 9\nson\n")
        #expect(p.result()?.status == 3)
    }

    @Test func parserFlushesUnterminatedTail() {
        let lines = Lines()
        let p = PrivilegedOutputParser(nonce: "N", onLine: { lines.add($0) })
        p.feed(Data("yarım".utf8))
        #expect(lines.all.isEmpty)
        p.finish()
        #expect(lines.all == ["yarım"] && p.result() == nil)
    }

    @Test func fileTailReadsOnlyNewBytes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tazele-tail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let tail = FileTail(url: url)
        #expect(tail.readNew().isEmpty)   // henüz yok
        try Data("a\nb".utf8).write(to: url)
        let lines = Lines()
        let p = PrivilegedOutputParser(nonce: "T", onLine: { lines.add($0) })
        p.feed(tail.readNew())
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd(); try h.write(contentsOf: Data("c\n__TAZELE_T_EXIT__ 0\n".utf8)); try h.close()
        p.feed(tail.readNew())
        #expect(tail.readNew().isEmpty)
        #expect(lines.all == ["a", "bc"] && p.exitStatus == 0)
    }

    // MARK: authorizationServices sarmalayıcısı (yetkisiz çalıştırılır)

    /// `zsh` sarmalayıcısını bir soket üzerinden, AEWP'nin yaptığı gibi başlatır.
    private func startZsh(_ command: [String], nonce: String) throws -> (Process, PrivilegedChannel) {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: RootScript.zsh)
        process.arguments = RootScript.zshArguments(nonce: nonce, command: command)
        let child = FileHandle(fileDescriptor: fds[1], closeOnDealloc: false)
        process.standardInput = child
        process.standardOutput = child
        process.standardError = FileHandle.nullDevice
        try process.run()
        close(fds[1])
        return (process, PrivilegedChannel(fd: fds[0]))
    }

    @Test func zshWrapperStreamsOutputAndExitCode() async throws {
        let lines = Lines()
        let parser = PrivilegedOutputParser(nonce: "Z1", onLine: { lines.add($0) })
        let (process, channel) = try startZsh(["/bin/sh", "-c", "echo 'bir iki'; echo hata >&2; exit 3", "x"], nonce: "Z1")
        await PrivilegedChannel.collect(channel, into: parser)
        channel.close()
        process.waitUntilExit()
        #expect(parser.exitStatus == 3)
        #expect(parser.childPID == process.processIdentifier)
        #expect(lines.all == ["bir iki", "hata"])
    }

    @Test func zshWrapperPassesArgumentsVerbatim() async throws {
        let lines = Lines()
        let parser = PrivilegedOutputParser(nonce: "Z2", onLine: { lines.add($0) })
        let (process, channel) = try startZsh(["/bin/echo", "a  b", "$(id)", "'q'", "*"], nonce: "Z2")
        await PrivilegedChannel.collect(channel, into: parser)
        channel.close()
        process.waitUntilExit()
        #expect(parser.exitStatus == 0)
        #expect(lines.all == ["a  b $(id) 'q' *"])
    }

    @Test func zshWrapperStopsCommandOnCancel() async throws {
        let parser = PrivilegedOutputParser(nonce: "Z3", onLine: nil)
        let (process, channel) = try startZsh(["/bin/sleep", "30"], nonce: "Z3")
        let start = Date()
        let task = Task { await PrivilegedChannel.collect(channel, into: parser) }
        try await Task.sleep(for: .milliseconds(500))
        task.cancel()
        await task.value
        channel.close()
        process.waitUntilExit()
        #expect(Date().timeIntervalSince(start) < 10)
        #expect(parser.exitStatus == 143)
    }

    @Test func zshWrapperStopsCommandWhenSocketCloses() async throws {
        let (process, channel) = try startZsh(["/bin/sleep", "30"], nonce: "Z4")
        let start = Date()
        try await Task.sleep(for: .milliseconds(300))
        channel.close()   // Tazele'nin çökmesi gibi
        process.waitUntilExit()
        #expect(Date().timeIntervalSince(start) < 10)
    }

    // MARK: osascript yolu (yönetici yetkisi olmadan, pencere açılmaz)

    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tazele-priv-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func contents(_ url: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? ["?"]
    }

    @Test func osascriptPathStreamsAndCleansUp() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = OsascriptBackend(runner: CommandRunner(), administrator: false, temporaryRoot: root, pollInterval: 0.05)
        let lines = Lines()
        let r = try await backend.run(["/bin/sh", "-c", "echo \"it's ok\"; echo 'çıktı \\ \"x\"'; exit 4", "x"],
                                      onLine: { lines.add($0) })
        #expect(r.status == 4)
        #expect(lines.all == ["it's ok", "çıktı \\ \"x\""])
        #expect(contents(root).isEmpty)
    }

    @Test func osascriptPathCancelStopsCommandAndRemovesTempFiles() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = OsascriptBackend(runner: CommandRunner(), administrator: false, temporaryRoot: root, pollInterval: 0.05)
        let start = Date()
        let task = Task { try await backend.run(["/bin/sleep", "30"], onLine: nil) }
        try await Task.sleep(for: .milliseconds(1500))
        #expect(contents(root).count == 1)   // çalışırken özel dizin var
        task.cancel()
        let r = try await task.value
        #expect(Date().timeIntervalSince(start) < 12)
        #expect(r.status == 143)
        #expect(contents(root).isEmpty)
    }

    @Test func osascriptErrorsMapToPrivilegeErrors() {
        func r(_ status: Int32, _ text: String) -> Result<CommandResult, Error> {
            .success(CommandResult(status: status, output: Data(text.utf8), timedOut: false))
        }
        #expect(OsascriptBackend.error(from: r(1, "execution error: User canceled. (-128)")) == .canceled)
        #expect(OsascriptBackend.error(from: r(1, "execution error: incorrect (-60005)")) == .denied)
        #expect(OsascriptBackend.error(from: r(1, "syntax error")) == .unavailable(.osascript, "syntax error"))
        #expect(OsascriptBackend.error(from: r(0, "")) == .incompleteOutput)
    }

    @Test func privateDirectoryIsOwnerOnly() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try OsascriptBackend.makePrivateDirectory(in: root)
        let mode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
    }

    // MARK: Elle doğrulama (insan gerekir)

    /// GERÇEK izin penceresi açar ve `/usr/bin/id -u` komutunu iki kez root olarak çalıştırır.
    /// Yalnızca elle: `TAZELE_PRIV_SELFTEST=1 swift test --filter PrivilegedRunnerTests/manualSelfTest`
    /// İsteğe bağlı: `TAZELE_PRIV_MECHANISM=osascript` (ya da sudoAskpass) ile yöntem seçilir.
    /// Beklenen: tek pencere (Touch ID seçeneğiyle), iki çıktı da "0".
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TAZELE_PRIV_SELFTEST"] == "1"))
    func manualSelfTest() async throws {
        let preferred = ProcessInfo.processInfo.environment["TAZELE_PRIV_MECHANISM"].flatMap(PrivilegeMechanism.init(rawValue:))
        let chain = PrivilegeMechanism.chain(preferred: preferred, isAvailable: { $0.isAvailableOnThisSystem })
        print("Yöntem zinciri:", chain.map(\.rawValue))
        let runner = CommandRunner()
        for round in 1...2 {
            let lines = Lines()
            let r = try await PrivilegedRunner.run(["/usr/bin/id", "-u"], chain: chain,
                                                   backend: { PrivilegedRunner.backend(for: $0, runner: runner) },
                                                   onLine: { lines.add($0) })
            print("Tur \(round): durum \(r.status), çıktı \(lines.all)")
            #expect(r.status == 0)
            #expect(lines.all.last == "0")
        }
    }
}
