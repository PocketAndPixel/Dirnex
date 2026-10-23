import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A transport that answers every PROPFIND with one listing: a folder at the root holding
/// `notes.txt`. Enough for the routing to be seen reaching the backend it registered, which is the
/// thing that breaks silently (`CompositeBackend.register(s3:)` gives the history).
private struct OneFolderTransport: WebDAVTransport {
    static let body = """
    <?xml version="1.0" encoding="utf-8"?>
    <D:multistatus xmlns:D="DAV:">
    <D:response><D:href>/</D:href><D:propstat><D:prop>
    <D:resourcetype><D:collection/></D:resourcetype>
    </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
    <D:response><D:href>/notes.txt</D:href><D:propstat><D:prop>
    <D:resourcetype/><D:getcontentlength>6</D:getcontentlength>
    <D:getlastmodified>Thu, 22 Oct 2026 20:49:08 GMT</D:getlastmodified>
    </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
    </D:multistatus>
    """

    func propfind(_: String, depth _: WebDAVDepth, isCollection _: Bool) throws -> WebDAVHTTPResponse {
        WebDAVHTTPResponse(status: 207, body: Data(Self.body.utf8))
    }

    func download(
        _: String,
        to _: String,
        resume _: Bool,
        progress _: (Int64) -> Void,
        isCancelled _: () -> Bool
    ) throws -> WebDAVHTTPResponse {
        WebDAVHTTPResponse(status: 404)
    }
}

/// A WebDAV account in the pane's routing backend (PLAN.md §M32 Slice 3): what it can do, where
/// its paths go, and what it remembers for a restored tab.
@Suite("WebDAV in the pane's backend")
struct WebDAVCompositeTests {
    private static let location = WebDAVLocation(host: "nas", port: 5006, username: "dirnex-test")
    private static let path = VFSPath(backend: .webDAV(location), path: "/")

    @Test("a WebDAV path is read-only connected or not, until the write half lands")
    func readOnly() {
        let backend = CompositeBackend(local: LocalBackend())
        #expect(backend.capabilities(for: Self.path) == .read)
        backend.connectWebDAV(location: Self.location, password: "pw", authentication: .basic)
        #expect(backend.capabilities(for: Self.path) == .read)
    }

    @Test("listing an unconnected WebDAV path says it is not connected")
    func unconnectedThrows() {
        let backend = CompositeBackend(local: LocalBackend())
        #expect(throws: VFSError.self) { try backend.listDirectory(at: Self.path) }
    }

    @Test("a connected account's listing is routed to its own backend")
    func listingIsRouted() throws {
        let backend = CompositeBackend(local: LocalBackend())
        backend.register(
            webDAV: WebDAVBackend(location: Self.location, transport: OneFolderTransport()),
            authentication: .basic
        )
        let entries = try backend.listDirectory(at: Self.path)
        #expect(entries.map(\.name) == ["notes.txt"])
        #expect(entries.first?.path == VFSPath(backend: .webDAV(Self.location), path: "/notes.txt"))
    }

    /// What a quit writes into the tab, and what a relaunch registers from: the scheme the probe
    /// settled and the pin the user accepted, beside the location.
    @Test("the endpoint memory keeps the scheme and the pin a connection was made with")
    func endpointMemory() {
        let backend = CompositeBackend(local: LocalBackend())
        #expect(!backend.isConnected(Self.path.backend))
        backend.connectWebDAV(
            location: Self.location,
            password: "pw",
            authentication: .digest,
            trustedPublicKey: "pin="
        )
        #expect(backend.isConnected(Self.path.backend))
        #expect(backend.endpoint(for: Self.path.backend) == .webdav(
            location: Self.location, authentication: .digest, trustedPublicKey: "pin="
        ))
    }

    @Test("two roots on one server are two connections")
    func rootsAreSeparate() {
        let backend = CompositeBackend(local: LocalBackend())
        let home = WebDAVLocation(
            host: "nas",
            port: 5006,
            username: "dirnex-test",
            rootPath: "/home"
        )
        backend.connectWebDAV(location: home, password: "pw", authentication: .basic)
        #expect(backend.isConnected(home.backendID))
        #expect(!backend.isConnected(Self.location.backendID))
    }

    @Test("a download from WebDAV is routed to the WebDAV backend")
    func downloadRoute() throws {
        let backend = CompositeBackend(local: LocalBackend())
        backend.register(
            webDAV: WebDAVBackend(location: Self.location, transport: OneFolderTransport()),
            authentication: nil
        )
        let source = VFSPath(backend: .webDAV(Self.location), path: "/notes.txt")
        let destination = VFSPath.local(NSTemporaryDirectory() + "WebDAVRoute-\(UUID().uuidString)")
        // The fake answers the GET with 404, so reaching it is a `notFound` for the source rather
        // than the composite's own "nothing serves this pair".
        #expect {
            try backend.copyFile(
                at: source,
                to: destination,
                progress: { _ in },
                isCancelled: { false }
            )
        } throws: { error in
            guard case let VFSError.notFound(path) = error else { return false }
            return path == source
        }
    }
}

/// Bringing a restored WebDAV tab's connection back (`PanelViewController+Reconnect`). Nothing here
/// reaches a server: registering is bookkeeping, and the Keychain is the test host's in-memory one.
@Suite("WebDAV reconnect")
@MainActor
struct WebDAVReconnectTests {
    private static func pane(at path: VFSPath, pending: ServerEndpoint) -> PanelViewController {
        let vc = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: path,
            restorationKey: nil
        )
        vc.panel = Panel(path: path)
        vc.tabs[0].pendingConnection = pending
        return vc
    }

    /// The scheme is why the endpoint carries it: the NAS wants Basic and macOS's Apache Digest, and
    /// nothing in a restore asks the server which.
    @Test("a restored public share reconnects with no secret, keeping what it was saved with")
    func publicShareReconnects() throws {
        let location = WebDAVLocation(host: "dav.example", username: "")
        let endpoint = ServerEndpoint.webdav(
            location: location,
            authentication: nil,
            trustedPublicKey: "pin="
        )
        let path = VFSPath(backend: .webDAV(location), path: "/pub")
        let vc = Self.pane(at: path, pending: endpoint)
        let composite = try #require(vc.backend as? CompositeBackend)

        #expect(vc.reconnectVerdict(to: path, unasked: false, floor: 0) == .connect(endpoint))
        #expect(vc.canListAfterReconnecting(to: path, unasked: false, floor: 0))
        #expect(composite.endpoint(for: path.backend) == endpoint)
    }

    @Test("a restored account with no stored password stands down instead of connecting")
    func missingPasswordStandsDown() {
        let location = WebDAVLocation(host: "nobody-saved-this.example", username: "u")
        let endpoint = ServerEndpoint.webdav(location: location, authentication: .digest)
        let path = VFSPath(backend: .webDAV(location), path: "/")
        let vc = Self.pane(at: path, pending: endpoint)
        #expect(
            vc.reconnectVerdict(to: path, unasked: false, floor: 0) == .standDown(.credentialMissing)
        )
    }

    @Test("a restored account with its password reconnects in the scheme it settled")
    func accountReconnectsInItsScheme() throws {
        let location = WebDAVLocation(host: "reconnect-test.example", username: "u")
        SecretKeychain.store(password: "pw", for: location)
        defer { SecretKeychain.removePassword(for: location) }
        let endpoint = ServerEndpoint.webdav(location: location, authentication: .digest)
        let path = VFSPath(backend: .webDAV(location), path: "/")
        let vc = Self.pane(at: path, pending: endpoint)
        let composite = try #require(vc.backend as? CompositeBackend)

        #expect(vc.canListAfterReconnecting(to: path, unasked: false, floor: 0))
        #expect(composite.endpoint(for: path.backend) == endpoint)
    }
}

/// The process half of the WebDAV transport, run against the real `/usr/bin/curl` with nothing on
/// the network: a `file://` URL and a port nothing listens on.
@Suite("curl runs for WebDAV")
struct WebDAVCurlRunTests {
    /// The configuration reaches `curl` on stdin and is read from there: a write-out that appears
    /// only in the config comes back on stdout, and the argument list never names it.
    @Test("a configuration goes in on stdin, not in the arguments")
    func configurationOnStandardInput() throws {
        let arguments = ["-q", "-sS", "-K", "-", "--output", "/dev/null", "file:///dev/null"]
        let result = try CurlProcess.run(
            arguments,
            configuration: "write-out = \"from-stdin\"\n",
            backstop: 30
        )
        #expect(result.exitCode == 0)
        #expect(String(bytes: result.standardOutput, encoding: .utf8) == "from-stdin")
        #expect(!arguments.contains { $0.contains("from-stdin") })
    }

    /// The whole chain below the backend — arguments, process, write-out reader — on a request that
    /// gets no answer: a refused connection is `curl`'s exit 7, read as a transport failure rather
    /// than as a status.
    @Test("a server that is not there is a transport failure, not a refusal")
    func refusedConnection() {
        let location = WebDAVLocation(host: "127.0.0.1", port: 1, username: "u", usesTLS: false)
        let transport = WebDAVCurlTransport(
            location: location,
            password: "pw",
            authentication: .basic
        )
        #expect(throws: WebDAVResponseError.transport(.couldNotConnect)) {
            try transport.propfind("/", depth: .zero, isCollection: true)
        }
    }

    @Test("the backstop is curl's own limit plus thirty seconds")
    func backstop() {
        #expect(CurlProcess.backstop(for: ["--max-time", "120"], fallback: 30) == 150)
        #expect(CurlProcess.backstop(for: ["-sS"], fallback: 30) == 60)
    }
}
