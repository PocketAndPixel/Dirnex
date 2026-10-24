import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A transport whose every PROPFIND is answered by one closure — a server that has the bin, has
/// none, or, held at a gate, has not answered yet. The write half is a server that will not, since
/// nothing here writes.
private final class BinServer: WebDAVTransport, @unchecked Sendable {
    let answer: @Sendable (String) -> WebDAVHTTPResponse
    /// When set, every PROPFIND waits here until the test opens it: a server that has not answered
    /// **yet**, by construction rather than by a clock a busy test host cannot keep.
    let gate: DispatchSemaphore?
    private let lock = NSLock()
    private var asked: [String] = []
    private var answered = 0

    init(gate: DispatchSemaphore? = nil, answer: @escaping @Sendable (String) -> WebDAVHTTPResponse) {
        self.gate = gate
        self.answer = answer
    }

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return asked
    }

    var answers: Int {
        lock.lock()
        defer { lock.unlock() }
        return answered
    }

    static func folder(_ href: String) -> WebDAVHTTPResponse {
        WebDAVHTTPResponse(status: 207, body: Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:"><D:response>\
        <D:href>\(href.replacingOccurrences(of: "#", with: "%23"))</D:href><D:propstat><D:prop>
        <D:resourcetype><D:collection/></D:resourcetype></D:prop>
        <D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>
        """.utf8))
    }

    func propfind(_ path: String, depth _: WebDAVDepth, isCollection _: Bool) throws
        -> WebDAVHTTPResponse {
        lock.lock()
        asked.append(path)
        lock.unlock()
        gate?.wait()
        defer {
            lock.lock()
            answered += 1
            lock.unlock()
        }
        return answer(path)
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

    func move(_: String, to _: String) throws -> WebDAVHTTPResponse { WebDAVHTTPResponse(status: 403) }

    func copy(_: String, to _: String) throws -> WebDAVHTTPResponse { WebDAVHTTPResponse(status: 403) }

    func delete(_: String) throws -> WebDAVHTTPResponse { WebDAVHTTPResponse(status: 403) }
}

/// The question F8 and ⇧F8 ask a WebDAV share before they word themselves: is there a `#recycle`
/// that may keep a copy (PLAN.md §M32, after Slice 6). The rule naming the bin is the core's
/// (`ShareRecycleBinWebDAVTests`); what is pinned here is that the pane asks the server exactly
/// that, believes only a folder, and never waits past its budget.
@MainActor
@Suite("WebDAV recycle bin check")
struct WebDAVRecycleBinCheckTests {
    private static let location = WebDAVLocation(host: "nas", port: 5006, username: "dirnex-test")

    private func pane(over server: BinServer) -> PanelViewController {
        let composite = CompositeBackend(local: LocalBackend())
        composite.register(
            webDAV: WebDAVBackend(location: Self.location, transport: server),
            authentication: .basic
        )
        return PanelViewController(
            backend: composite,
            restoration: nil,
            defaultPath: VFSPath(backend: Self.location.backendID, path: "/home"),
            restorationKey: nil
        )
    }

    private func path(_ path: String) -> VFSPath {
        VFSPath(backend: Self.location.backendID, path: path)
    }

    /// The answer the pane gives for `paths`, waited for without a run-loop spin.
    private func answer(
        _ pane: PanelViewController,
        _ paths: [VFSPath],
        within budget: Duration = .seconds(30)
    ) async -> [Bool] {
        var answers: [Bool] = []
        pane.askWhetherARecycleBinGoverns(paths, within: budget) { answers.append($0) }
        await settle { !answers.isEmpty }
        return answers
    }

    @Test("a share whose #recycle is a folder softens the sheet, asked in one request")
    func binThere() async {
        let server = BinServer { Self.folderOrMissing($0, folder: "/home/#recycle") }
        let answers = await answer(pane(over: server), [path("/home/a.txt"), path("/home/b/c")])
        #expect(answers == [true])
        #expect(server.paths == ["/home/#recycle"])
    }

    @Test("no #recycle, or a file by that name, keeps the strong warning")
    func noBin() async {
        let missing = BinServer { _ in WebDAVHTTPResponse(status: 404) }
        #expect(await answer(pane(over: missing), [path("/home/a.txt")]) == [false])

        let file = BinServer { _ in
            WebDAVHTTPResponse(status: 207, body: Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <D:multistatus xmlns:D="DAV:"><D:response><D:href>/home/%23recycle</D:href>
            <D:propstat><D:prop><D:resourcetype/></D:prop>
            <D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>
            """.utf8))
        }
        #expect(await answer(pane(over: file), [path("/home/a.txt")]) == [false])
    }

    @Test("a path the rule names no bin for asks the server nothing")
    func nothingToAsk() async {
        let server = BinServer { Self.folderOrMissing($0, folder: "/home/#recycle") }
        let pane = pane(over: server)
        #expect(await answer(pane, [path("/home/#recycle/a.txt")]) == [false])
        #expect(await answer(pane, [path("/home")]) == [false])
        #expect(server.paths.isEmpty)
    }

    /// The server is held until the pane has answered, so the answer cannot have been the server's:
    /// the strong wording goes up at the deadline, and the bin's late "yes" is dropped rather than
    /// answered a second time.
    @Test("a server too slow to answer gets the strong warning at the deadline, once")
    func slowServer() async {
        let gate = DispatchSemaphore(value: 0)
        let server = BinServer(gate: gate) { Self.folderOrMissing($0, folder: "/home/#recycle") }
        defer { gate.signal() }
        let pane = pane(over: server)
        var answers: [Bool] = []
        var serverHadAnswered: [Int] = []
        pane.askWhetherARecycleBinGoverns([path("/home/a.txt")], within: .milliseconds(100)) {
            answers.append($0)
            serverHadAnswered.append(server.answers)
        }
        await settle { !answers.isEmpty }
        #expect(answers == [false])
        #expect(serverHadAnswered == [0], "the answer came before the server's")

        // Now let the server say yes, which must find the question already answered.
        gate.signal()
        await settle { server.answers == 1 }
        try? await Task.sleep(for: .milliseconds(500))
        #expect(answers == [false])
    }

    private nonisolated static func folderOrMissing(_ path: String, folder: String) -> WebDAVHTTPResponse {
        path == folder ? BinServer.folder(path) : WebDAVHTTPResponse(status: 404)
    }
}
