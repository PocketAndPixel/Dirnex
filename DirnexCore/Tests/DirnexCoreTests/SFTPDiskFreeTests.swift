import Foundation
import Testing

@testable import DirnexCore

/// The space an SFTP server has left, as `sftp`'s `df` reports it (PLAN.md §M38's SFTP follow-up).
/// Every transcript here was captured on 2026-11-11 by feeding ``SFTPBatchCommand/diskFree`` to this
/// Mac's `sftp` (OpenSSH 10.3) with standard error folded into standard output, as the app's
/// transport runs it, from four servers:
///
/// - the throwaway macOS `sshd` of `scripts/live_test_servers.sh` (APFS), by key and interactively,
///   which is the shape the password route runs;
/// - the same `sshd` with `sftp-server -P statvfs`, the extension withheld;
/// - an Alpine container (OpenSSH 10.3p1): `root` on its ext4-backed overlay, and an account
///   chrooted to a 64 MiB `tmpfs`;
/// - and two sessions that never got as far: a key the server does not know, and a closed port.
///
/// `df-linux-proc-path` is the one asked with a path (`-df /proc`), since no login directory sits on
/// a pseudo-filesystem.
enum SFTPFixtures {
    static func text(_ name: String) throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures/SFTP")
        )
        return try String(contentsOf: url, encoding: .utf8)
    }
}

@Suite("SFTP disk free")
struct SFTPDiskFreeTests {
    private func space(_ name: String) throws -> ServerSpace? {
        try SFTPDiskFree.space(in: SFTPFixtures.text(name))
    }

    /// The macOS capture with its numbers line replaced, for the values no server here could be made
    /// to send.
    private func macOSAnswer(withNumbers numbers: String) throws -> String {
        let text = try SFTPFixtures.text("df-macos-apfs")
        let real = "  1948455240   1417895304    530559936    530559936          72%"
        #expect(text.contains(real))
        return text.replacingOccurrences(of: real, with: numbers)
    }

    // MARK: - The request

    @Test("the question is one df with no path, allowed to fail")
    func request() {
        #expect(SFTPBatchCommand.diskFree == "-df")
    }

    // MARK: - Answers

    @Test("an APFS volume answers its space and its total, in bytes, by key and interactively")
    func macOS() throws {
        // Size and Avail are KiB; `(root)` equals Avail on APFS, which keeps no reserve.
        #expect(try space("df-macos-apfs") == ServerSpace(
            availableBytes: 530_559_936 * 1024, totalBytes: 1_948_455_240 * 1024
        ))
        #expect(
            try SFTPFixtures.text("df-macos-apfs-interactive").hasPrefix("Connected to 127.0.0.1.")
        )
        #expect(try space("df-macos-apfs-interactive") == ServerSpace(
            availableBytes: 530_559_680 * 1024, totalBytes: 1_948_455_240 * 1024
        ))
    }

    @Test("on ext4 the space is what an account may write, not the reserve only root may use")
    func ext4Reserve() throws {
        let text = try SFTPFixtures.text("df-linux-ext4-reserve")
        #expect(text.contains("    61202244     45538616     12522304     15663628          74%"))
        #expect(try space("df-linux-ext4-reserve") == ServerSpace(
            availableBytes: 12_522_304 * 1024, totalBytes: 61_202_244 * 1024
        ))
    }

    @Test("a chrooted account answers its chroot's filesystem: a 64 MiB tmpfs is 64 MiB of 64 MiB")
    func chroot() throws {
        let mebibytes64: Int64 = 64 * 1024 * 1024
        #expect(try space("df-linux-chroot-tmpfs") == ServerSpace(
            availableBytes: mebibytes64, totalBytes: mebibytes64
        ))
    }

    @Test("a filesystem of size zero has nothing to say, which is not a full disk")
    func pseudoFilesystem() throws {
        #expect(try SFTPFixtures.text("df-linux-proc-path").contains("ERR"))
        #expect(try space("df-linux-proc-path") == nil)
    }

    @Test("a full disk is zero bytes left of its total, which is a space to show")
    func full() throws {
        let text = try macOSAnswer(
            withNumbers: "  1948455240   1948455240            0            0         100%"
        )
        #expect(try SFTPDiskFree.space(in: text) == ServerSpace(
            availableBytes: 0, totalBytes: 1_948_455_240 * 1024
        ))
    }

    @Test("a filesystem too wide for its column still splits, and one past Int64 is no answer")
    func wideColumns() throws {
        // 2 EiB in KiB is 2^51, sixteen digits, past `%12llu`'s width; the separating spaces stay.
        let wide = try macOSAnswer(
            withNumbers: "2251799813685248 1 2251799813685247 2251799813685247 0%"
        )
        #expect(try SFTPDiskFree.space(in: wide) == ServerSpace(
            availableBytes: 2_251_799_813_685_247 * 1024, totalBytes: 2_251_799_813_685_248 * 1024
        ))
        let tooBig = try macOSAnswer(
            withNumbers: "9007199254740992 0 9007199254740992 9007199254740992 0%"
        )
        #expect(throws: SFTPTransportError.self) { try SFTPDiskFree.space(in: tooBig) }
    }

    @Test("a numbers line that is not four whole numbers is no answer")
    func malformed() throws {
        for numbers in [
            "  1948455240   1417895304    530559936          72%",
            "  1.8TB 1.3TB 507GB 507GB 72%"
        ] {
            let text = try macOSAnswer(withNumbers: numbers)
            #expect(throws: SFTPTransportError.self) { try SFTPDiskFree.space(in: text) }
        }
    }

    // MARK: - Refusals

    @Test("a server without the extension cannot say, on either route, which is not a failure")
    func withheld() throws {
        for name in ["df-withheld", "df-withheld-interactive"] {
            #expect(try SFTPFixtures.text(name).hasSuffix("extension\r\n"))
            #expect(throws: ServerSpaceUnsupported()) { try space(name) }
        }
    }

    @Test("a session that never got as far as df is no answer, and not a server that cannot say")
    func noAnswer() throws {
        #expect(throws: SFTPTransportError.permissionDenied) { try space("df-login-refused") }
        #expect {
            try space("df-connection-refused")
        } throws: { error in
            guard case let .failure(text)? = error as? SFTPTransportError else { return false }
            return text.contains("Connection refused")
        }
        // A `df` whose path is gone prints nothing at all, so its transcript is the echo alone.
        #expect(throws: SFTPTransportError.self) { try SFTPDiskFree.space(in: "sftp> -df\n") }
    }

    // MARK: - The backend

    @Test("the backend asks once, in one session, and reads the answer")
    func backendAsks() throws {
        let transport = ListingOnlySFTPTransport(
            diskFreeTranscript: try SFTPFixtures.text("df-linux-chroot-tmpfs")
        )
        let backend = SFTPBackend(
            location: SFTPLocation(host: "127.0.0.1", username: "probe"),
            transport: transport
        )

        #expect(try backend.space()?.totalBytes == 64 * 1024 * 1024)
        #expect(transport.diskFreeAsks == 1)
    }

    @Test("a server that cannot say reaches the caller as such, not as a failed session")
    func cannotSayPassesThrough() {
        let backend = SFTPBackend(
            location: SFTPLocation(host: "127.0.0.1", username: "probe"),
            transport: ListingOnlySFTPTransport()
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

/// An `SFTPTransport` with only what the protocol demands, and a `df` transcript when it is given one:
/// without one it is a server that cannot say.
private final class ListingOnlySFTPTransport: SFTPTransport, @unchecked Sendable {
    private let diskFreeTranscript: String?
    /// How many times the backend asked, which is how a test sees one question cost one session.
    private(set) var diskFreeAsks = 0

    init(diskFreeTranscript: String? = nil) {
        self.diskFreeTranscript = diskFreeTranscript
    }

    func diskFree() throws -> String {
        diskFreeAsks += 1
        guard let diskFreeTranscript else { throw ServerSpaceUnsupported() }
        return diskFreeTranscript
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
