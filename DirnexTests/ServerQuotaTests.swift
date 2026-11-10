import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The space a WebDAV server says is left, on its sidebar row (PLAN.md §M38 Slice 7): when a pane
/// asks (``ServerQuotaBook``), and what the row's tooltip then says. What the server's answer means
/// is the core's (`WebDAVQuotaTests`, over captured Nextcloud and Apache answers).
@MainActor
@Suite("Server quota")
struct ServerQuotaTests {
    private static let location = WebDAVLocation(
        host: "cloud.example",
        username: "probe",
        rootPath: "/remote.php/dav/files/probe"
    )
    private static let server = ServerQuotaBook.Server.webDAV(location)

    /// A clock a test moves by hand.
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    /// Counts what a book asked and answers what the test says, from any thread.
    private final class Question: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var reply: Result<ServerSpace?, any Error>

        init(answering answer: ServerSpace?) {
            reply = .success(answer)
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

    /// How many changes were posted. Posted on the main thread, where the book settles.
    private final class Posts: @unchecked Sendable {
        var count = 0
    }

    private func book(_ clock: Clock) -> ServerQuotaBook {
        ServerQuotaBook { clock.now }
    }

    /// Hand a listing to `book` and wait for any question it sends to be answered.
    @discardableResult
    private func listing(
        _ book: ServerQuotaBook,
        _ question: Question,
        at server: ServerQuotaBook.Server = Self.server
    ) async -> Bool {
        guard let task = book.listingArrived(at: server, asking: { try question.ask() }) else {
            return false
        }
        await task.value
        return true
    }

    // MARK: - When it asks

    @Test("the first listing asks, and what the server said is kept for the row")
    func firstListingAsks() async {
        let clock = Clock()
        let book = book(clock)
        let question = Question(answering: ServerSpace(availableBytes: 98_857_600))
        #expect(book.space(for: Self.server) == nil)

        #expect(await listing(book, question))
        #expect(question.asked == 1)
        #expect(book.space(for: Self.server) == ServerSpace(availableBytes: 98_857_600))
    }

    @Test("a listing within five minutes asks nothing, and the first one after asks again")
    func fiveMinutesApart() async {
        let clock = Clock()
        let book = book(clock)
        let question = Question(answering: ServerSpace(availableBytes: 1000))
        await listing(book, question)

        clock.now += 299
        #expect(!(await listing(book, question)))
        #expect(question.asked == 1)

        clock.now += 1
        question.answer(with: .success(ServerSpace(availableBytes: 400)))
        #expect(await listing(book, question))
        #expect(question.asked == 2)
        #expect(book.space(for: Self.server) == ServerSpace(availableBytes: 400))
    }

    @Test("a listing while the question is out asks nothing more")
    func oneQuestionAtATime() async {
        let clock = Clock()
        let book = book(clock)
        let question = Question(answering: ServerSpace(availableBytes: 1))
        let first = book.listingArrived(at: Self.server) { try question.ask() }
        clock.now += 600
        // Before the first answer has been settled on this actor, so it is still out.
        #expect(book.listingArrived(at: Self.server) { try question.ask() } == nil)
        await first?.value
        #expect(question.asked == 1)
    }

    @Test("each server is asked on its own schedule")
    func serversApart() async {
        let clock = Clock()
        let book = book(clock)
        let other = WebDAVLocation(host: "cloud.example", username: "someone-else")
        let question = Question(answering: ServerSpace(availableBytes: 5))
        await listing(book, question)
        #expect(await listing(book, question, at: .webDAV(other)))
        #expect(question.asked == 2)
        #expect(book.space(for: .webDAV(other)) == ServerSpace(availableBytes: 5))
    }

    // MARK: - What it keeps

    @Test("a request that got no answer leaves the last answer standing")
    func noAnswerKeepsTheLast() async {
        let clock = Clock()
        let book = book(clock)
        let question = Question(answering: ServerSpace(availableBytes: 77))
        await listing(book, question)

        clock.now += 300
        question.answer(with: .failure(WebDAVResponseError.transport(.couldNotConnect)))
        #expect(await listing(book, question))
        #expect(book.space(for: Self.server) == ServerSpace(availableBytes: 77))
    }

    @Test("an answer with no quota clears one, and a change tells the sidebar")
    func noQuotaClears() async {
        let clock = Clock()
        let book = book(clock)
        let question = Question(answering: ServerSpace(availableBytes: 77))
        let posted = Posts()
        // This book's posts only: every other test's book posts the same name, in parallel.
        let observer = NotificationCenter.default.addObserver(
            forName: ServerQuotaBook.didChangeNotification,
            object: book,
            queue: nil
        ) { _ in posted.count += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        await listing(book, question)
        #expect(posted.count == 1)

        clock.now += 300
        await listing(book, question)
        #expect(posted.count == 1, "the same answer is no change")

        clock.now += 300
        question.answer(with: .success(nil))
        await listing(book, question)
        #expect(book.space(for: Self.server) == nil)
        #expect(posted.count == 2)
    }

    // MARK: - The row

    @Test("a WebDAV row's tooltip is its address, then the space left once the server has said")
    func tooltip() async {
        let clock = Clock()
        let book = book(clock)
        let server = ServerConnection(
            name: "Cloud",
            endpoint: .webdav(location: Self.location, authentication: .basic, trustedPublicKey: nil)
        )
        #expect(SidebarViewController.serverTooltip(for: server, quotas: book) == server.address)

        await listing(book, Question(answering: ServerSpace(availableBytes: 98_857_600)))
        let lines = SidebarViewController.serverTooltip(for: server, quotas: book)
            .components(separatedBy: "\n")
        #expect(lines == [server.address, "\(FileFormatting.byteString(98_857_600)) available"])
    }

    @Test("a row for another account, or another protocol, shows no one else's space")
    func tooltipOtherRows() async {
        let clock = Clock()
        let book = book(clock)
        await listing(book, Question(answering: ServerSpace(availableBytes: 1)))

        let elsewhere = ServerConnection(
            name: "Elsewhere",
            endpoint: .webdav(
                location: WebDAVLocation(host: "cloud.example", username: "someone-else"),
                authentication: .basic,
                trustedPublicKey: nil
            )
        )
        let sftp = ServerConnection(
            name: "Shell",
            endpoint: .sftp(
                location: SFTPLocation(host: "cloud.example", username: "probe"),
                authentication: .password
            )
        )
        for server in [elsewhere, sftp] {
            #expect(SidebarViewController.serverTooltip(for: server, quotas: book) == server.address)
        }
    }

    // MARK: - The pane

    @Test("a listing that arrives on a connected WebDAV pane asks its root, once")
    func paneAsks() async throws {
        // A host no other test uses, since the pane reaches the shared book.
        let location = WebDAVLocation(host: "quota-pane.example", username: "probe")
        let server = QuotaServer()
        let composite = CompositeBackend(local: LocalBackend())
        composite.register(
            webDAV: WebDAVBackend(location: location, transport: server),
            authentication: .basic
        )
        let pane = PanelViewController(
            backend: composite,
            restoration: nil,
            defaultPath: VFSPath(backend: location.backendID, path: "/docs"),
            restorationKey: nil
        )

        pane.noteRemoteListingArrived(at: VFSPath(backend: location.backendID, path: "/docs"))
        try await settleUntil { ServerQuotaBook.shared.space(for: .webDAV(location)) != nil }
        #expect(
            ServerQuotaBook.shared.space(for: .webDAV(location)) == ServerSpace(availableBytes: 4096)
        )
        pane.noteRemoteListingArrived(at: VFSPath(backend: location.backendID, path: "/docs"))
        #expect(server.paths == ["/"])
    }

    @Test("a listing from a server this pane is not connected to asks nothing")
    func paneNotConnected() {
        let location = WebDAVLocation(host: "quota-nowhere.example", username: "probe")
        let pane = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: .local(NSTemporaryDirectory()),
            restorationKey: nil
        )
        pane.noteRemoteListingArrived(at: VFSPath(backend: location.backendID, path: "/"))
        pane.noteRemoteListingArrived(at: .local(NSTemporaryDirectory()))
        #expect(ServerQuotaBook.shared.space(for: .webDAV(location)) == nil)
    }
}

/// A server that answers a quota request with 4 KiB left, counting the paths it was asked about,
/// and refuses everything else, since nothing here lists or writes.
private final class QuotaServer: WebDAVTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String] = []

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return asked
    }

    func propfindQuota(_ path: String) throws -> WebDAVHTTPResponse {
        lock.lock()
        asked.append(path)
        lock.unlock()
        return WebDAVHTTPResponse(status: 207, body: Data("""
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:"><d:response><d:href>/</d:href><d:propstat><d:prop>\
        <d:quota-available-bytes>4096</d:quota-available-bytes></d:prop>\
        <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>
        """.utf8))
    }

    func propfind(_: String, depth _: WebDAVDepth, isCollection _: Bool) throws -> WebDAVHTTPResponse {
        WebDAVHTTPResponse(status: 403)
    }

    func propfindBatch(_ paths: [String], isCancelled _: () -> Bool) throws -> [WebDAVBatchAnswer] {
        paths.map { _ in .notSent }
    }

    func download(
        _: String,
        to _: String,
        resume _: Bool,
        progress _: (Int64) -> Void,
        isCancelled _: () -> Bool
    ) throws -> WebDAVHTTPResponse {
        WebDAVHTTPResponse(status: 403)
    }

    func mkcol(_: String) throws -> WebDAVHTTPResponse { WebDAVHTTPResponse(status: 403) }

    func upload(
        localPath _: String,
        to _: String,
        headers _: WebDAVPutHeaders,
        progress _: (Int64) -> Void,
        isCancelled _: () -> Bool
    ) throws -> WebDAVHTTPResponse {
        WebDAVHTTPResponse(status: 403)
    }

    func putEmpty(_: String, condition _: S3WriteCondition) throws -> WebDAVHTTPResponse {
        WebDAVHTTPResponse(status: 403)
    }

    func move(_: String, to _: String, collections _: WebDAVCollectionEnds) throws
        -> WebDAVHTTPResponse { WebDAVHTTPResponse(status: 403) }

    func copy(_: String, to _: String, collections _: WebDAVCollectionEnds) throws
        -> WebDAVHTTPResponse { WebDAVHTTPResponse(status: 403) }

    func delete(_: String, isCollection _: Bool) throws -> WebDAVHTTPResponse {
        WebDAVHTTPResponse(status: 403)
    }
}
