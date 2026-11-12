import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The space an SFTP server has left, on its saved sidebar row (PLAN.md §M38, the SFTP follow-up of
/// 2026-11-11): the book's rule for a server that cannot say, the pane's question, and the tooltip's
/// "of". The schedule itself is WebDAV's and is pinned in `ServerQuotaTests`; what a `df` transcript
/// means is the core's (`SFTPDiskFreeTests`, over captured transcripts).
@MainActor
@Suite("Server quota over SFTP")
struct ServerQuotaSFTPTests {
    private static let location = SFTPLocation(host: "shell.example", username: "probe")
    private static let server = ServerQuotaBook.Server.sftp(location)
    /// The throwaway macOS server's answer of 2026-11-11, in bytes.
    private static let apfs = ServerSpace(
        availableBytes: 530_559_936 * 1024,
        totalBytes: 1_948_455_240 * 1024
    )

    /// A clock a test moves by hand.
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    /// Answers what the test says and counts the asks, from any thread.
    private final class Question: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var reply: Result<ServerSpace?, any Error>

        init(answering answer: Result<ServerSpace?, any Error>) {
            reply = answer
        }

        var asked: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func answer(with result: Result<ServerSpace?, any Error>) {
            lock.lock()
            reply = result
            lock.unlock()
        }

        func ask() throws -> ServerSpace? {
            lock.lock()
            count += 1
            let reply = reply
            lock.unlock()
            return try reply.get()
        }
    }

    /// Hand a listing to `book` and wait for any question it sends to be answered.
    @discardableResult
    private func listing(_ book: ServerQuotaBook, _ question: Question) async -> Bool {
        guard let task = book.listingArrived(at: Self.server, asking: { try question.ask() }) else {
            return false
        }
        await task.value
        return true
    }

    private func row(_ endpoint: ServerEndpoint) -> ServerConnection {
        ServerConnection(name: "Shell", endpoint: endpoint)
    }

    // MARK: - A server that cannot say

    @Test("a server without the extension clears what it said and is not asked again this launch")
    func cannotSay() async {
        let clock = Clock()
        let book = ServerQuotaBook { clock.now }
        let question = Question(answering: .success(Self.apfs))
        await listing(book, question)
        #expect(book.space(for: Self.server) == Self.apfs)

        clock.now += 300
        question.answer(with: .failure(ServerSpaceUnsupported()))
        #expect(await listing(book, question))
        #expect(book.space(for: Self.server) == nil)

        clock.now += 3600
        question.answer(with: .success(Self.apfs))
        #expect(!(await listing(book, question)))
        #expect(question.asked == 2)
    }

    @Test(
        "a failed session is not a server that cannot say: the answer stands and it is asked again"
    )
    func failedSession() async {
        let clock = Clock()
        let book = ServerQuotaBook { clock.now }
        let question = Question(answering: .success(Self.apfs))
        await listing(book, question)

        clock.now += 300
        question.answer(with: .failure(SFTPTransportError.permissionDenied))
        #expect(await listing(book, question))
        #expect(book.space(for: Self.server) == Self.apfs)

        clock.now += 300
        #expect(await listing(book, question))
        #expect(question.asked == 3)
    }

    // MARK: - The row

    @Test("an SFTP row's tooltip is its address, then the space left of its filesystem's total")
    func tooltip() async {
        let book = ServerQuotaBook()
        let shell = row(.sftp(location: Self.location, authentication: .password))
        #expect(SidebarViewController.serverTooltip(for: shell, quotas: book) == shell.address)

        await listing(book, Question(answering: .success(Self.apfs)))
        let lines = SidebarViewController.serverTooltip(for: shell, quotas: book)
            .components(separatedBy: "\n")
        let available = FileFormatting.byteString(530_559_936 * 1024)
        let total = FileFormatting.byteString(1_948_455_240 * 1024)
        #expect(lines == [shell.address, SidebarViewController.capacityLine(
            available: 530_559_936 * 1024, total: 1_948_455_240 * 1024
        )])
        // Whatever the language, the line names both sizes, the space left first.
        let line = lines.last ?? ""
        let first = line.range(of: available)
        let second = line.range(of: total)
        #expect(first != nil && second != nil)
        if let first, let second { #expect(first.lowerBound < second.lowerBound) }
    }

    @Test("a WebDAV row on the same host and account shows none of the SFTP server's space")
    func otherProtocolSameAccount() async {
        let book = ServerQuotaBook()
        await listing(book, Question(answering: .success(Self.apfs)))
        let cloud = row(.webdav(
            location: WebDAVLocation(host: "shell.example", username: "probe"),
            authentication: .basic,
            trustedPublicKey: nil
        ))
        let elsewhere = row(.sftp(
            location: SFTPLocation(host: "shell.example", port: 2222, username: "probe"),
            authentication: .password
        ))
        for server in [cloud, elsewhere] {
            #expect(SidebarViewController.serverTooltip(for: server, quotas: book) == server.address)
        }
    }

    // MARK: - The pane

    @Test("a listing that arrives on a connected SFTP pane asks the server once, in one session")
    func paneAsks() async throws {
        // A host no other test uses, since the pane reaches the shared book.
        let location = SFTPLocation(host: "space-pane.example", username: "probe")
        let transport = DiskFreeSFTPTransport()
        let composite = CompositeBackend(local: LocalBackend())
        composite.register(
            sftp: SFTPBackend(location: location, transport: transport),
            authentication: .password
        )
        let home = VFSPath(backend: .sftp(location), path: "/home/probe")
        let pane = PanelViewController(
            backend: composite, restoration: nil, defaultPath: home, restorationKey: nil
        )

        pane.noteRemoteListingArrived(at: home)
        try await settleUntil { ServerQuotaBook.shared.space(for: .sftp(location)) != nil }
        #expect(ServerQuotaBook.shared.space(for: .sftp(location)) == ServerSpace(
            availableBytes: 64 * 1024 * 1024, totalBytes: 64 * 1024 * 1024
        ))
        pane.noteRemoteListingArrived(at: home.appending("sub"))
        #expect(transport.asks == 1)
    }
}

/// An SFTP server whose only answer is the first `df` session's transcript, the chrooted `tmpfs` one
/// captured on 2026-11-11 (an empty login directory, so no second session), counting the asks. Nothing
/// here lists or writes.
private final class DiskFreeSFTPTransport: SFTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var asks: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func diskFree(_ batch: String) throws -> String {
        lock.lock()
        count += 1
        lock.unlock()
        guard batch == SFTPDiskFree.loginBatch else { throw ServerSpaceUnsupported() }
        return "sftp> -df\n"
            + "        Size         Used        Avail       (root)    %Capacity\n"
            + "       65536            0        65536        65536           0%\n"
            + "sftp> -ls -la\n"
            + "drwxr-xr-x    ? 1000     0              40 Nov 11 02:22 .\n"
            + "drwxr-xr-x    ? 0        0              60 Nov 11 02:22 ..\n"
            + "sftp> pwd\n"
            + "Remote working directory: /probe\n"
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
