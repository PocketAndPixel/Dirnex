import Foundation
import Testing

@testable import DirnexCore

/// The space an SFTP server has left, as the backend asks it: one session for an ordinary login
/// directory, a second for one made only of mount points (``SFTPBackend/space()``), over the
/// transcripts `SFTPDiskFreeTests` reads. And what the sidebar keeps of either protocol's answer.
@Suite("SFTP disk free, the backend")
struct SFTPDiskFreeBackendTests {
    private static let mebibyte: Int64 = 1024 * 1024

    // MARK: - The backend

    @Test("an ordinary server costs one session")
    func backendOneSession() throws {
        let transport = DiskFreeOnlySFTPTransport(answering: [
            SFTPDiskFree.loginBatch: try SFTPFixtures.text("login-linux-chroot-tmpfs")
        ])
        let backend = SFTPBackend(
            location: SFTPLocation(host: "127.0.0.1", username: "probe"),
            transport: transport
        )
        #expect(try backend.space()?.totalBytes == 64 * Self.mebibyte)
        #expect(transport.batches == [SFTPDiskFree.loginBatch])
    }

    @Test("a root of mount points costs a second session, asking its folders")
    func backendTwoSessions() throws {
        let folderBatch = SFTPDiskFree.folderBatch(["home", "media"])
        let transport = DiskFreeOnlySFTPTransport(answering: [
            SFTPDiskFree.loginBatch: try SFTPFixtures.text("login-junction-one-volume"),
            folderBatch: try SFTPFixtures.text("folders-junction-one-volume")
        ])
        let backend = SFTPBackend(
            location: SFTPLocation(host: "127.0.0.1", username: "share1"),
            transport: transport
        )
        #expect(try backend.space()?.totalBytes == 48 * Self.mebibyte)
        #expect(transport.batches == [SFTPDiskFree.loginBatch, folderBatch])
    }

    @Test("a second session that fails is no answer, so the last one stands")
    func backendSecondSessionFails() throws {
        let transport = DiskFreeOnlySFTPTransport(answering: [
            SFTPDiskFree.loginBatch: try SFTPFixtures.text("login-junction-one-volume")
        ])
        let backend = SFTPBackend(
            location: SFTPLocation(host: "127.0.0.1", username: "share1"),
            transport: transport
        )
        #expect(throws: SFTPTransportError.self) { try backend.space() }
    }

    @Test("a server that cannot say reaches the caller as such, not as a failed session")
    func cannotSayPassesThrough() {
        let backend = SFTPBackend(
            location: SFTPLocation(host: "127.0.0.1", username: "probe"),
            transport: DiskFreeOnlySFTPTransport(answering: [:], cannotSay: true)
        )
        #expect(throws: ServerSpaceUnsupported()) { try backend.space() }
    }

    // MARK: - What the sidebar keeps

    @Test("a WebDAV quota becomes a space with no total")
    func webDAVHasNoTotal() {
        #expect(
            ServerSpace(WebDAVQuota(availableBytes: 98_857_600)) == ServerSpace(
                availableBytes: 98_857_600
            )
        )
        #expect(ServerSpace(WebDAVQuota(availableBytes: 98_857_600)).totalBytes == nil)
    }

    @Test("a listing asks again five minutes after the last ask, and at once if the clock went back")
    func schedule() {
        let asked = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(ServerSpace.isDue(lastAsked: nil, now: asked))
        #expect(!ServerSpace.isDue(lastAsked: asked, now: asked))
        #expect(!ServerSpace.isDue(lastAsked: asked, now: asked.addingTimeInterval(299)))
        #expect(ServerSpace.isDue(lastAsked: asked, now: asked.addingTimeInterval(300)))
        #expect(ServerSpace.isDue(lastAsked: asked, now: asked.addingTimeInterval(-1)))
    }
}

/// An `SFTPTransport` with only what the protocol demands, answering each `df` batch it was given a
/// transcript for and recording what it was asked. A batch with no transcript is a session that
/// never connected; `cannotSay` makes every batch a server without the extension.
private final class DiskFreeOnlySFTPTransport: SFTPTransport, @unchecked Sendable {
    private let transcripts: [String: String]
    private let cannotSay: Bool
    private(set) var batches: [String] = []

    init(answering transcripts: [String: String], cannotSay: Bool = false) {
        self.transcripts = transcripts
        self.cannotSay = cannotSay
    }

    func diskFree(_ batch: String) throws -> String {
        batches.append(batch)
        if cannotSay { throw ServerSpaceUnsupported() }
        return transcripts[batch] ?? "ssh: connect to host 127.0.0.1 port 2229: Connection refused\r\n"
    }

    func listDirectory(_: String) throws -> String { "" }
    func createSymbolicLink(_: String, target _: String) throws {}
    func makeDirectory(_: String) throws {}
    func createEmptyFile(_: String) throws {}
    func rename(_: String, to _: String) throws {}
    func removeFile(_: String) throws {}
    func removeDirectory(_: String) throws {}

    func download(
        _: String, to _: String, resume _: Bool,
        progress _: (Int64) -> Void, isCancelled _: () -> Bool
    ) throws -> Int64 { 0 }

    func upload(
        _: String, to _: String, resume _: Bool,
        progress _: (Int64) -> Void, isCancelled _: () -> Bool
    ) throws -> Int64 { 0 }
}
