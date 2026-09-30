import Foundation
import Testing

@testable import DirnexCore

/// The server-side duplicate (PLAN.md §M25 Slice 3): what `SFTPBackend` asks for when both ends are
/// on one account, what it does with a refusal, and — the half this milestone exists for — what it
/// records as *lost* rather than claiming.
///
/// The claims here are about the **decision**, which is what breaks silently: whether a copy was
/// asked of the server at all, what plan rode with it, and whether the connection remembers a
/// refusal. Whether the resulting file is right is a question only a real server answers, and
/// `RemoteMetadataCarryLiveTests` asks it.
@Suite("SFTP server-side copy")
struct SFTPServerSideCopyTests {
    private let location = SFTPLocation(host: "example.com", port: 22, username: "oleg")

    private func backend(_ transport: FakeSFTPTransport) -> SFTPBackend {
        SFTPBackend(location: location, transport: transport)
    }

    private func path(_ remote: String) -> VFSPath {
        VFSPath(backend: .sftp(location), path: remote)
    }

    private func transport() -> FakeSFTPTransport {
        let transport = FakeSFTPTransport()
        transport.supportsServerSideCopy = true
        transport.metadataCapabilities = .sftp
        return transport
    }

    @Test("a duplicate within one account is copied by the server, with nothing staged through here")
    func copiesServerSide() throws {
        let transport = transport()
        try backend(transport).copyFile(
            at: path("/home/oleg/a.txt"),
            to: path("/home/oleg/b.txt"),
            progress: { _ in },
            isCancelled: { false }
        )
        #expect(transport.serverSideCopies.count == 1)
        #expect(transport.serverSideCopies.first?.source == "/home/oleg/a.txt")
        #expect(transport.serverSideCopies.first?.destination == "/home/oleg/b.txt")
        // The whole point of the route: no bytes crossed this machine.
        #expect(transport.downloads.isEmpty && transport.uploads.isEmpty)
    }

    @Test("the copy carries the source's mode and reports the time it cannot carry")
    func carriesModeAndReportsTheLostTime() throws {
        let transport = transport()
        let sut = backend(transport)
        try sut.copyFile(
            at: path("/home/oleg/a.txt"),
            to: path("/home/oleg/b.txt"),
            hint: CopySourceHint(
                expectedSize: 12,
                metadata: RemoteSourceMetadata(
                    permissions: 0o644,
                    modificationTime: Date(timeIntervalSince1970: 1_528_358_950)
                )
            ),
            progress: { _ in },
            isCancelled: { false }
        )
        let carry = try #require(transport.serverSideCopies.first?.carry)
        // No `-p` to ride on: `cp` takes no preserve flag, so the mode goes as its own line — and it
        // is sent for an *ordinary* mode too, because an occupied destination keeps its own.
        #expect(!carry.usesPreserveFlag)
        #expect(carry.steps == [.setMode(POSIXPermissions(rawValue: 0o644))])
        // Measured against a real `sshd`: `cp` stamps the copy with *now*, and this language has no
        // verb that sets a time. Reporting it is what the milestone buys with the speed.
        #expect(carry.dropped == [.modificationTime])
        #expect(sut.metadata.loss?.aspects == [.modificationTime])
        #expect(sut.metadata.loss?.itemCount == 1)
    }

    @Test("a special mode bit rides the same copy, since cp drops it like -p does")
    func carriesSpecialModeBits() throws {
        let transport = transport()
        try backend(transport).copyFile(
            at: path("/home/oleg/setuid.bin"),
            to: path("/home/oleg/copy.bin"),
            hint: CopySourceHint(
                expectedSize: 13,
                metadata: RemoteSourceMetadata(permissions: 0o4755, modificationTime: nil)
            ),
            progress: { _ in },
            isCancelled: { false }
        )
        let carry = try #require(transport.serverSideCopies.first?.carry)
        #expect(carry.steps == [.setMode(POSIXPermissions(rawValue: 0o4755))])
        // A source with no date has nothing to lose, which is the distinction a sentinel would have
        // destroyed: absent is not dropped.
        #expect(carry.dropped.isEmpty)
    }

    @Test("a source that reported no metadata carries nothing and claims no loss")
    func carriesNothingForAHintlessSource() throws {
        let transport = transport()
        let sut = backend(transport)
        try sut.copyFile(
            at: path("/home/oleg/a.txt"),
            to: path("/home/oleg/b.txt"),
            progress: { _ in },
            isCancelled: { false }
        )
        #expect(transport.serverSideCopies.first?.carry == .carryingNothing)
        #expect(sut.metadata.loss == nil)
    }

    @Test("the file's size is reported once, so the queue's bar is not left short")
    func reportsTheFilesSizeAsProgress() throws {
        let transport = transport()
        var reported: Int64 = 0
        try backend(transport).copyFile(
            at: path("/home/oleg/a.txt"),
            to: path("/home/oleg/b.txt"),
            expectedSize: 4096,
            progress: { reported += $0 },
            isCancelled: { false }
        )
        // Nothing moved through this machine, so the hint is the only thing that knows — and a route
        // reporting zero would leave a job's denominator short by exactly one file.
        #expect(reported == 4096)
    }

    @Test("a server without the copy extension is refused, latched, and asked only once")
    func latchesTheRefusalForTheConnection() throws {
        let transport = FakeSFTPTransport() // the default: no `copy-data`
        transport.metadataCapabilities = .sftp
        let sut = backend(transport)
        #expect(sut.mayAttemptInternalCopy(from: path("/a"), to: path("/b")))

        #expect(throws: VFSError.unsupported(.remoteToRemoteCopy)) {
            try sut.copyFile(
                at: path("/a"),
                to: path("/b"),
                progress: { _ in },
                isCancelled: { false }
            )
        }
        // Latched: the router now stages without spending a round trip to be told again.
        #expect(!sut.mayAttemptInternalCopy(from: path("/a"), to: path("/b")))
        #expect(throws: VFSError.unsupported(.remoteToRemoteCopy)) {
            try sut.copyFile(
                at: path("/c"),
                to: path("/d"),
                progress: { _ in },
                isCancelled: { false }
            )
        }
        #expect(transport.serverSideCopies.isEmpty)
        #expect(transport.downloads.isEmpty && transport.uploads.isEmpty)
    }

    @Test("a failure that is about the two paths does not latch the connection")
    func doesNotLatchAnOperationsOwnFailure() {
        let transport = transport()
        transport.error = .notFound
        let sut = backend(transport)
        #expect(throws: VFSError.notFound(path("/home/oleg/b.txt"))) {
            try sut.copyFile(
                at: path("/home/oleg/a.txt"),
                to: path("/home/oleg/b.txt"),
                progress: { _ in },
                isCancelled: { false }
            )
        }
        // The narrowness the latch depends on: a missing file says nothing about the server, and
        // latching on it is how one absent name would cost every later copy its fast path.
        #expect(sut.mayAttemptInternalCopy(from: path("/a"), to: path("/b")))
    }

    @Test("a refused chmod is counted as a loss and does not fail the copy")
    func recordsARefusedFollowUp() throws {
        let transport = transport()
        transport.metadataRefusals = [
            .itemRefused("remote setstat \"/home/oleg/b.txt\": Permission denied")
        ]
        let sut = backend(transport)
        try sut.copyFile(
            at: path("/home/oleg/a.txt"),
            to: path("/home/oleg/b.txt"),
            hint: CopySourceHint(
                expectedSize: 12,
                metadata: RemoteSourceMetadata(permissions: 0o644, modificationTime: nil)
            ),
            progress: { _ in },
            isCancelled: { false }
        )
        // The bytes are on the server, so this is a loss rather than a failure — and the aspects the
        // refused step was carrying are what it cost.
        #expect(sut.metadata.loss?.aspects == [.mode, .specialModeBits])
        // A refusal about one item must not latch the *mode* capability for the connection either.
        #expect(sut.metadata.capabilities.contains(.changeMode))
    }

    @Test("cancellation reaches the copy rather than only the file boundary")
    func cancels() {
        let transport = transport()
        #expect(throws: CancellationError.self) {
            try backend(transport).copyFile(
                at: path("/home/oleg/a.txt"),
                to: path("/home/oleg/b.txt"),
                progress: { _ in },
                isCancelled: { true }
            )
        }
        #expect(transport.serverSideCopies.isEmpty)
    }

    @Test("only a pair of ends on this account is offered to the server")
    func offersOnlyItsOwnPairs() {
        let sut = backend(transport())
        let other = SFTPLocation(host: "elsewhere.com", port: 22, username: "oleg")
        #expect(sut.mayAttemptInternalCopy(from: path("/a"), to: path("/b")))
        #expect(!sut.mayAttemptInternalCopy(from: path("/a"), to: .local("/tmp/b")))
        #expect(!sut.mayAttemptInternalCopy(from: .local("/tmp/a"), to: path("/b")))
        #expect(!sut.mayAttemptInternalCopy(
            from: path("/a"),
            to: VFSPath(backend: .sftp(other), path: "/b")
        ))
    }

    @Test("a backend with no copy verb of its own answers no, so nothing is attempted")
    func otherBackendsDoNotOffer() {
        let local = LocalBackend()
        #expect(!local.mayAttemptInternalCopy(from: .local("/tmp/a"), to: .local("/tmp/b")))
    }
}
