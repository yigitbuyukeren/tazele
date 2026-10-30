import Foundation
import CryptoKit
import Testing
@testable import TazeleCore

@Suite struct ArchiveSafetyTests {
    @Test func rejectsUnsafeZipEntries() throws {
        func entry(_ path: String, _ size: UInt64 = 1, _ mode: UInt32? = nil) -> ArchiveGuard.ZipEntry {
            .init(path: path, mode: mode, uncompressedSize: size)
        }
        try ArchiveGuard.checkZipEntries([entry("App.app/file")], maxBytes: 10)
        for bad in [entry("../escape"), entry("/absolute"), entry("a\\b"), entry("file", 11), entry("file", UInt64.max), entry("file", 1, 0o104755)] {
            #expect(throws: SparkleInstallError.self) { try ArchiveGuard.checkZipEntries([bad], maxBytes: 10) }
        }
        #expect(throws: SparkleInstallError.self) {
            try ArchiveGuard.checkZipEntries([entry("link", 1, 0o120777), entry("./LINK/file")], maxBytes: 10)
        }
    }

    @Test func rejectsInsecureFetchURLs() {
        #expect(!BoundedFetch.isSecure(URL(string: "http://example.com")))
        #expect(BoundedFetch.isSecure(URL(string: "https://example.com")))
    }

    @Test func rejectsOptionLikePackageNames() {
        let items = [OutdatedItem(source: .homebrewFormula, name: "--help", installed: "1", latest: "2")]
        let plan = Updater.plan(for: items, masPath: nil)
        #expect(plan.steps.isEmpty)
        #expect(plan.skipped.count == 1)
    }
    @Test func executableTrustRejectsWritableAncestorsAndACLs() {
        let file = ExecutableTrust.Node(uid: 0, mode: S_IFREG | 0o755)
        let directory = ExecutableTrust.Node(uid: 0, mode: S_IFDIR | 0o755)
        func trust(_ bad: ExecutableTrust.Node?) -> ExecutableTrust {
            ExecutableTrust(inspect: { path in
                if path == "/safe/mas" { return file }
                if path == "/safe" { return bad ?? directory }
                return directory
            }, realPath: { $0 })
        }
        #expect(trust(nil).trustedPath("/safe/mas") == "/safe/mas")
        #expect(trust(.init(uid: 501, mode: S_IFDIR | 0o755)).trustedPath("/safe/mas") == nil)
        #expect(trust(.init(uid: 0, mode: S_IFDIR | 0o777)).trustedPath("/safe/mas") == nil)
        #expect(trust(.init(uid: 0, mode: S_IFDIR | 0o755, hasACL: true)).trustedPath("/safe/mas") == nil)
    }

    @Test func rejectsEscapingTreeLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("escape").path, withDestinationPath: "../../outside")
        #expect(throws: SparkleInstallError.self) { try ArchiveGuard.checkTree(root) }
    }
    @Test func verifiedArchiveReplacementIsDetected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("archive.zip")
        let data = Data("signed bytes".utf8)
        try data.write(to: archive)
        let key = Curve25519.Signing.PrivateKey()
        let signature = try key.signature(for: data).base64EncodedString()
        let fingerprint = try #require(ArchiveGuard.verify(file: archive, signature: signature, publicKey: key.publicKey.rawRepresentation.base64EncodedString()))
        #expect(ArchiveGuard.matches(fingerprint, file: archive))
        try Data("other bytes!".utf8).write(to: archive, options: .atomic)
        #expect(!ArchiveGuard.matches(fingerprint, file: archive))
        #expect(ArchiveGuard.verify(file: archive, signature: signature, publicKey: key.publicKey.rawRepresentation.base64EncodedString()) == nil)
    }

    @Test func rejectsMalformedZipWithoutCrashing() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var bytes = Data(repeating: 0, count: 42)
        bytes.replaceSubrange(0..<4, with: [0x50, 0x4b, 0x06, 0x07])
        bytes.replaceSubrange(8..<16, with: [UInt8](repeating: 0xff, count: 8))
        bytes.replaceSubrange(16..<20, with: [1, 0, 0, 0])
        bytes.replaceSubrange(20..<24, with: [0x50, 0x4b, 0x05, 0x06])
        bytes.replaceSubrange(28..<32, with: [0xff, 0xff, 0xff, 0xff])
        try bytes.write(to: file)
        #expect(throws: SparkleInstallError.self) { try ArchiveGuard.zipEntries(file) }
    }
    @Test func localZipNameMustMatchCentralDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("content".utf8).write(to: root.appendingPathComponent("safe.txt"))
        let archive = root.appendingPathComponent("sample.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = root
        process.arguments = ["-q", archive.path, "safe.txt"]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        try ArchiveGuard.checkZip(archive)
        var bytes = try Data(contentsOf: archive)
        try #require(bytes.prefix(4) == Data([0x50, 0x4b, 0x03, 0x04]))
        bytes[30] = 0x78 // yerel ad değişir, merkezi ad değişmez.
        try bytes.write(to: archive)
        #expect(throws: SparkleInstallError.self) { try ArchiveGuard.checkZip(archive) }
        bytes[30] = UInt8(ascii: "s")
        // Yerel açılmış boyut, merkezi dizinden farklı olamaz.
        bytes[22] ^= 1
        try bytes.write(to: archive)
        #expect(throws: SparkleInstallError.self) { try ArchiveGuard.checkZip(archive) }
    }
    @Test func extractedTreeRejectsExternalHardlinksAndSpecialFiles() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let tree = base.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let outside = base.appendingPathComponent("outside")
        try Data("data".utf8).write(to: outside)
        let inside = tree.appendingPathComponent("linked")
        try FileManager.default.linkItem(at: outside, to: inside)
        #expect(throws: SparkleInstallError.self) { try ArchiveGuard.checkTree(tree) }
        try FileManager.default.removeItem(at: inside)
        let fifo = tree.appendingPathComponent("fifo")
        try #require(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: SparkleInstallError.self) { try ArchiveGuard.checkTree(tree) }
    }
    @Test func archivePermissionsRejectLinksWithoutChangingTargets() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let work = base.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let outside = base.appendingPathComponent("outside")
        try Data("data".utf8).write(to: outside)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outside.path)
        let archive = work.appendingPathComponent("archive")
        try FileManager.default.linkItem(at: outside, to: archive)
        #expect(throws: SparkleInstallError.self) { try ArchiveGuard.restrict(workDirectory: work, archive: archive) }
        let mode = try #require(FileManager.default.attributesOfItem(atPath: outside.path)[.posixPermissions] as? Int)
        #expect(mode == 0o600)
        try FileManager.default.removeItem(at: archive)
        try FileManager.default.createSymbolicLink(at: archive, withDestinationURL: outside)
        #expect(throws: SparkleInstallError.self) { try ArchiveGuard.restrict(workDirectory: work, archive: archive) }
        let linkedWork = base.appendingPathComponent("linked-work")
        try FileManager.default.createSymbolicLink(at: linkedWork, withDestinationURL: work)
        #expect(throws: SparkleInstallError.self) { try ArchiveGuard.restrict(workDirectory: linkedWork, archive: archive) }
    }
    @Test func packageNamesCannotBecomeOptions() {
        for name in ["--help", "-x", "", "a/b/../../evil"] {
            #expect(!PackageName.isBrew(name))
            #expect(!PackageName.isNpm(name))
            #expect(!PackageName.isGem(name))
            #expect(!PackageName.isPython(name))
        }
        #expect(PackageName.isBrew("homebrew/core/git"))
        #expect(PackageName.isNpm("@scope/package"))
        #expect(PackageName.isGem("my-gem"))
        #expect(PackageName.isPython("my_package"))
    }
    @Test func rejectsZipWhoseActualExpansionExceedsItsHeaders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 65, count: 100_000).write(to: root.appendingPathComponent("payload"))
        let archive = root.appendingPathComponent("payload.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = root
        process.arguments = ["-q", archive.path, "payload"]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        try await SparkleInstaller.verifyArchivePayload(archive)
        var bytes = try Data(contentsOf: archive)
        let cd = try #require(bytes.range(of: Data([0x50, 0x4b, 0x01, 0x02]))?.lowerBound)
        bytes.replaceSubrange(22..<26, with: [1, 0, 0, 0])
        bytes.replaceSubrange((cd + 24)..<(cd + 28), with: [1, 0, 0, 0])
        try bytes.write(to: archive)
        // İki başlık anlaşır; yalnızca verinin açılması gerçek boyutu ortaya çıkarır.
        try ArchiveGuard.checkZip(archive)
        await #expect(throws: SparkleInstallError.unsafeArchive) { try await SparkleInstaller.verifyArchivePayload(archive) }
    }
    @Test func tarPayloadIsBoundedBeforeExtraction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = root.appendingPathComponent("payload")
        try Data(repeating: 65, count: 10_000).write(to: payload)
        let archive = root.appendingPathComponent("sample.tar.gz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.currentDirectoryURL = root
        process.arguments = ["-czf", archive.path, "payload"]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        try await SparkleInstaller.verifyArchivePayload(archive, maxBytes: 10_000)
        await #expect(throws: SparkleInstallError.unsafeArchive) {
            try await SparkleInstaller.verifyArchivePayload(archive, maxBytes: 9_999)
        }
        #expect(try Data(contentsOf: payload).count == 10_000)
    }
}
