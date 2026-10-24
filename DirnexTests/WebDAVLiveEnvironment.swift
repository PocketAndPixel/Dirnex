import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The opt-in configuration for the live WebDAV suite: the same file-gated shape
/// `FTPLiveEnvironment` uses, for the same reason (`xcodebuild` forwards no shell environment to
/// the test runner), with one difference — the file names **several endpoints**, and every test
/// runs once against each.
///
/// That is what PLAN.md §M32's risk row asks of the suite. Its fixtures and probes all agree with
/// Apache, so a second server family has to be able to join a run without a second suite, and the
/// NAS has to be able to join over both its ports. `scripts/live_test_servers.sh up` writes four:
/// macOS's Apache over HTTP with Basic, with Digest and as a public folder, and over HTTPS with a
/// self-signed certificate it pins.
///
/// ```json
/// { "endpoints": [ {
///     "name": "NAS, HTTPS",
///     "host": "nas", "port": 5006, "tls": true, "root": "",
///     "user": "dirnex-test",
///     "keychain": { "service": "com.dirnex.sftp", "account": "dirnex-test@nas:22" },
///     "scheme": "basic", "trustedPublicKey": "…", "selfSigned": true,
///     "remotePath": "/home", "connectWithinSeconds": 1
/// } ] }
/// ```
///
/// Each field past the location is a **claim about that endpoint**, written down rather than
/// inferred, since a live test's constants are the ones that expire (docs/NOTES.md ▸ Live suites).
/// `keychain` stands in for `password` so a real account's password never has to be written into
/// `/tmp`: it is read from the login Keychain once per run, which raises the Keychain's own prompt
/// for whoever runs it (CLAUDE.md ▸ How to work here).
enum WebDAVLiveEnvironment {
    /// The opt-in config path. A file here turns the suite on; its absence keeps it off in CI.
    static let configPath = "/tmp/dirnex_webdav_live_test.json"

    /// Every endpoint the config names, in its order, or none without a config.
    ///
    /// A `static let`, so a Keychain-backed password is asked for once however many tests use it.
    static let endpoints: [WebDAVLiveEndpoint] = {
        guard let data = FileManager.default.contents(atPath: configPath),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        // Each named item is read once, however many endpoints name it: every read of an item
        // another binary filed raises the Keychain's prompt, and the NAS's two ports share one.
        var secrets: [String: String?] = [:]
        let secret = { (item: KeychainItem) -> String? in
            let key = item.service + "\n" + item.account
            if let known = secrets[key] { return known }
            let read = KeychainSecretStore().secret(service: item.service, account: item.account)
                .flatMap { String(data: $0, encoding: .utf8) }
            secrets[key] = read
            return read
        }
        return file.endpoints.compactMap { WebDAVLiveEndpoint($0, secret: secret) }
    }()

    static var isEnabled: Bool { !endpoints.isEmpty }

    fileprivate struct File: Decodable {
        let endpoints: [Endpoint]
    }

    fileprivate struct KeychainItem: Decodable {
        let service: String
        let account: String
    }

    fileprivate struct Endpoint: Decodable {
        let name: String
        let host: String
        let port: Int?
        let tls: Bool?
        let root: String?
        let user: String?
        let password: String?
        let keychain: KeychainItem?
        let scheme: String?
        let trustedPublicKey: String?
        let selfSigned: Bool?
        let remotePath: String?
        let mayTryWrongPassword: Bool?
        let accessLog: String?
        let servedFrom: String?
        let connectWithinSeconds: Double?
        let recycleFolder: String?
        let composesNames: Bool?
        let lockGuardsFolder: Bool?
        let keepsUploadDates: Bool?
    }
}

/// One server the live suite runs against.
struct WebDAVLiveEndpoint: Sendable, CustomTestStringConvertible {
    let name: String
    let location: WebDAVLocation
    let password: String
    let trustedPublicKey: String?
    /// The scheme the connect probe must settle on: `nil` for a public folder, which sends none.
    let expectedScheme: WebDAVAuthScheme?
    /// The folder, in the pane's paths, under which the suite may write its UUID-named fixtures.
    /// The NAS account's `/` lists shared folders and refuses a new one, so it writes in `/home`.
    let remotePath: String
    /// Whether the certificate is one no system store trusts, so a connect without the pin must
    /// fail with exit 60. A CA-signed server would connect, and a test claiming otherwise would be
    /// a claim about the certificate.
    let isSelfSigned: Bool
    /// Whether a wrong password may be sent at all. Only for a throwaway server: the NAS locks the
    /// account after a few failed logins.
    let mayTryWrongPassword: Bool
    /// The server's access log, when it is a file on this Mac. What a request cost is the server's
    /// bookkeeping, and only a loopback server's can be read.
    let accessLog: String?
    /// The local folder the server serves the root from, when there is one. A second witness for a
    /// name's bytes, which reads the disk rather than the protocol.
    let servedFrom: String?
    /// How long a connect may take, for an endpoint where that is the claim — the NAS by its bare
    /// name, which an unresolved mDNS stall would cost five seconds a request (PLAN.md §M32).
    let connectWithinSeconds: Double?
    /// Where the server keeps what a DELETE removed, for a server that keeps it at all — the NAS
    /// moves it into the share's `#recycle` (PLAN.md §M32). The suite empties its own folders out
    /// of it, so a run against the NAS leaves nothing behind.
    let recycleFolder: String?
    /// Whether the server stores a name in Unicode's composed form whatever it was sent in.
    /// Nextcloud does: `cafe\u{301}` comes back as `café`, in a file's name and a folder's, while
    /// both Apaches keep the bytes they were sent (PLAN.md §M32).
    let composesNames: Bool
    /// Whether a lock on a file refuses a DELETE or MOVE of the folder holding it. Apache answers
    /// 424 and deletes nothing; Nextcloud deletes the folder, locked file and all, refusing only
    /// writes to the file itself.
    let lockGuardsFolder: Bool
    /// Whether a PUT asking for a date with `X-OC-Mtime` gets it, which the server says in its
    /// answer. Nextcloud does; Apache ignores the header (``WebDAVModificationTime``).
    let keepsUploadDates: Bool

    var testDescription: String { name }

    fileprivate init?(
        _ file: WebDAVLiveEnvironment.Endpoint,
        secret: (WebDAVLiveEnvironment.KeychainItem) -> String?
    ) {
        let user = file.user ?? ""
        let password: String
        if let keychain = file.keychain {
            guard let read = secret(keychain) else { return nil }
            password = read
        } else {
            password = file.password ?? ""
        }
        name = file.name
        location = WebDAVLocation(
            host: file.host,
            port: file.port,
            username: user,
            usesTLS: file.tls ?? true,
            rootPath: file.root ?? ""
        )
        self.password = password
        trustedPublicKey = file.trustedPublicKey
        expectedScheme = file.scheme.flatMap(WebDAVAuthScheme.init(rawValue:))
        remotePath = file.remotePath ?? "/"
        isSelfSigned = file.selfSigned ?? false
        mayTryWrongPassword = file.mayTryWrongPassword ?? false
        accessLog = file.accessLog
        servedFrom = file.servedFrom
        connectWithinSeconds = file.connectWithinSeconds
        recycleFolder = file.recycleFolder
        composesNames = file.composesNames ?? false
        lockGuardsFolder = file.lockGuardsFolder ?? true
        keepsUploadDates = file.keepsUploadDates ?? false
    }

    /// `name`'s bytes as this server stores them.
    func stored(_ name: String) -> [UInt8] {
        WebDAVLive.bytes(composesNames ? name.precomposedStringWithCanonicalMapping : name)
    }

    /// A transport for this endpoint as the app builds one after a connect: the scheme the probe
    /// settled, the pin, and the password held in memory.
    func transport(
        password: String? = nil,
        trustedPublicKey: String?? = nil,
        authentication: WebDAVAuthScheme?? = nil
    ) -> WebDAVCurlTransport {
        WebDAVCurlTransport(
            location: location,
            password: password ?? self.password,
            trustedPublicKey: trustedPublicKey ?? self.trustedPublicKey,
            authentication: authentication ?? expectedScheme
        )
    }

    /// A backend over a counting wrapper around the real transport, so a test can say what a verb
    /// cost in requests — the client's own claim, which holds whatever server answers it.
    func backend(password: String? = nil) -> (WebDAVBackend, CountingWebDAVTransport) {
        let counting = CountingWebDAVTransport(transport(password: password))
        return (WebDAVBackend(location: location, transport: counting), counting)
    }

    /// The folder the suite writes under, as a path on this endpoint's backend.
    var base: VFSPath { VFSPath(backend: location.backendID, path: remotePath) }

    /// A fresh scratch folder under ``base``, created on the server. Every test makes its own, so
    /// nothing has to be prepared by hand and the endpoints' runs cannot collide.
    func scratchFolder(_ backend: WebDAVBackend, _ label: String) throws -> VFSPath {
        let folder = base.appending("dirnex_webdav_\(label)_\(UUID().uuidString)")
        try backend.createDirectory(at: folder)
        return folder
    }

    /// Remove a scratch folder, and its copy in ``recycleFolder`` when the server keeps one. Either
    /// may already be gone, since several tests delete their folder as part of what they check.
    func discard(_ folder: VFSPath, on backend: WebDAVBackend) {
        try? backend.removeItem(at: folder)
        guard let recycleFolder else { return }
        let recycled = VFSPath(backend: location.backendID, path: recycleFolder)
        try? backend.removeItem(at: recycled.appending(folder.lastComponent))
    }
}

/// A ``WebDAVTransport`` that forwards to the real one and writes down every request it sent.
///
/// A lock rather than an actor because the protocol is synchronous, as ``InMemorySecretStore``
/// argues for its own.
final class CountingWebDAVTransport: WebDAVTransport, @unchecked Sendable {
    /// One request, by method, with what a test asserts about it.
    enum Request: Equatable, Sendable {
        case propfind(WebDAVDepth)
        case propfindBatch(folders: Int)
        case get(resume: Bool)
        /// One `curl` carrying this many guarded ranges of one file.
        case getRanges(Int)
        case mkcol
        /// A PUT of a local file, and whether it asked the server for a date.
        case put(S3WriteCondition, askedForDate: Bool = false)
        case putEmpty(S3WriteCondition)
        case move
        case copy
        case delete
    }

    private let base: any WebDAVTransport
    private let lock = NSLock()
    private var log: [Request] = []

    init(_ base: any WebDAVTransport) {
        self.base = base
    }

    /// Every request so far, in order.
    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    /// Forget what was sent, so a test counts only the gesture it is about.
    func reset() {
        lock.lock()
        log.removeAll()
        lock.unlock()
    }

    private func record(_ request: Request) {
        lock.lock()
        log.append(request)
        lock.unlock()
    }

    func propfind(_ backendPath: String, depth: WebDAVDepth, isCollection: Bool) throws
        -> WebDAVHTTPResponse {
        record(.propfind(depth))
        return try base.propfind(backendPath, depth: depth, isCollection: isCollection)
    }

    func propfindBatch(_ backendPaths: [String], isCancelled: () -> Bool) throws
        -> [WebDAVBatchAnswer] {
        record(.propfindBatch(folders: backendPaths.count))
        return try base.propfindBatch(backendPaths, isCancelled: isCancelled)
    }

    func download(
        _ backendPath: String,
        to localPath: String,
        resume: Bool,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> WebDAVHTTPResponse {
        record(.get(resume: resume))
        return try base.download(
            backendPath,
            to: localPath,
            resume: resume,
            progress: progress,
            isCancelled: isCancelled
        )
    }

    /// Forwarded rather than left to the protocol's default, which would answer with one plain GET
    /// and hide every split from the count.
    func downloadSegments(
        _ segments: [DownloadSegment],
        of file: WebDAVTaggedFile,
        to localPath: String,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> WebDAVSegmentedDownload {
        record(.getRanges(segments.count))
        return try base.downloadSegments(
            segments,
            of: file,
            to: localPath,
            progress: progress,
            isCancelled: isCancelled
        )
    }

    func mkcol(_ backendPath: String) throws -> WebDAVHTTPResponse {
        record(.mkcol)
        return try base.mkcol(backendPath)
    }

    func upload(
        localPath: String,
        to backendPath: String,
        headers: WebDAVPutHeaders,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> WebDAVHTTPResponse {
        record(.put(headers.condition, askedForDate: headers.modificationTime != nil))
        return try base.upload(
            localPath: localPath,
            to: backendPath,
            headers: headers,
            progress: progress,
            isCancelled: isCancelled
        )
    }

    func putEmpty(_ backendPath: String, condition: S3WriteCondition) throws -> WebDAVHTTPResponse {
        record(.putEmpty(condition))
        return try base.putEmpty(backendPath, condition: condition)
    }

    func move(_ backendPath: String, to destinationPath: String) throws -> WebDAVHTTPResponse {
        record(.move)
        return try base.move(backendPath, to: destinationPath)
    }

    func copy(_ backendPath: String, to destinationPath: String) throws -> WebDAVHTTPResponse {
        record(.copy)
        return try base.copy(backendPath, to: destinationPath)
    }

    func delete(_ backendPath: String) throws -> WebDAVHTTPResponse {
        record(.delete)
        return try base.delete(backendPath)
    }
}

/// The moves every live WebDAV test makes, written once. Each blocks on `curl`, so each is called
/// inside ``offCooperativePool``.
enum WebDAVLive {
    /// Put `data` at `path` the way F5 does: one unconditional PUT of a local file.
    static func upload(_ data: Data, to path: VFSPath, on backend: WebDAVBackend) throws {
        let local = scratchFile()
        try data.write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        try backend.copyFile(
            at: .local(local.path),
            to: path,
            progress: { _ in },
            isCancelled: { false }
        )
    }

    /// The bytes at `path`, fetched the way F5 fetches them, into a file nobody else owns.
    static func download(_ path: VFSPath, on backend: WebDAVBackend) throws -> Data {
        let local = scratchFile()
        defer { try? FileManager.default.removeItem(at: local) }
        try backend.copyFile(
            at: path,
            to: .local(local.path),
            progress: { _ in },
            isCancelled: { false }
        )
        return try Data(contentsOf: local)
    }

    /// The `VFSError` `body` threw, or `nil` when it threw nothing. Anything else is rethrown, so
    /// an unexpected failure still fails the test as itself.
    static func caught(_ body: () throws -> Void) throws -> VFSError? {
        do {
            try body()
            return nil
        } catch let error as VFSError {
            return error
        }
    }

    /// Sleep until the server's clock has left the second `written` fell in, plus a margin.
    ///
    /// Nextcloud keeps **one strong tag for every write inside a second**, whatever the size: a
    /// file rewritten twice in one second, 10 bytes then 22, kept its tag, and `If-Match` with the
    /// first reading passed over the second write (measured 2026-10-24, 3 of 3). No tag can see a
    /// colleague's save in that second, on that server or on Apache, whose tag is weak for it. A
    /// test about a later save waits it out.
    static func waitOutTheSecond(of written: Date) {
        let next = (written.timeIntervalSince1970 + 1).rounded(.down) + 0.1
        let wait = next - Date().timeIntervalSince1970
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
    }

    /// The tag a save-back may send for `path`, waiting out the second in which Apache hands out a
    /// weak one after any write (docs/NOTES.md ▸ curl (WebDAV)). `nil` if none turned strong in
    /// five seconds, which the caller reports.
    static func strongTag(of path: VFSPath, on backend: WebDAVBackend) throws -> String? {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if let tag = RemoteFileRevision(try backend.stat(at: path)).preconditionTag {
                return tag
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return nil
    }

    /// `count` bytes nobody would type, so a byte-exact comparison means something.
    static func payload(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    /// A name's bytes, exactly. `String`'s `==` calls the two spellings of é equal, which is the
    /// one difference the name tests exist to see.
    static func bytes(_ name: String) -> [UInt8] { Array(name.utf8) }

    static func scratchFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-webdav-live-\(UUID().uuidString)")
    }
}

extension CountingWebDAVTransport.Request {
    /// Whether the request carried a file's bytes across this Mac's connection, either way.
    var movesBytes: Bool {
        switch self {
        case .get, .getRanges, .put: true
        default: false
        }
    }
}
