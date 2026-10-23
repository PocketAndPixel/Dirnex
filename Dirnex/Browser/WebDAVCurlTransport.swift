import DirnexCore
import Foundation

/// Drives the system `curl` to satisfy a `WebDAVBackend`'s requests — the non-hermetic half of
/// WebDAV (PLAN.md §M32), as `FTPCurlTransport` is FTP's and `S3CurlTransport` S3's. Every decision
/// lives in `DirnexCore`: the arguments (`WebDAVProcessArguments`), what a run answered
/// (`WebDAVWriteOut`), and everything the backend and the connect probe make of the answer. This
/// spawns the process through ``CurlProcess`` and pipes the password in.
///
/// What it owns that the core cannot:
///
/// - **The password never touches `argv` or the disk.** It goes to `curl`'s stdin as a `-K -`
///   config, and only when the session sends credentials at all (``WebDAVSession/sendsCredentials``)
///   — the same answer the argument builder reads to decide whether to pass `-K -`, so the two
///   cannot disagree.
/// - **The dial name is resolved once per connection** (``HostDialer``), which is what keeps an
///   mDNS name from costing five seconds a request: `nas.local` took 5.37 s without `-4` and
///   0.016 s with it (PLAN.md §M32).
/// - **The scheme is fixed per transport.** The connect probe asks the server which one it wants and
///   builds a transport per answer (``authenticating(with:)``); the connection keeps the one that
///   worked, rather than paying `--anyauth`'s extra round trip on every request.
struct WebDAVCurlTransport: WebDAVTransport {
    let location: WebDAVLocation
    /// The plaintext password, resolved from the Keychain or the sheet by the caller and held for
    /// the connection's lifetime, since every request is a new `curl`. Empty for a public share.
    let password: String
    /// The certificate key the user has explicitly trusted for this server, if any.
    let trustedPublicKey: String?
    /// The scheme credentials go out with, or `nil` to send none.
    let authentication: WebDAVAuthScheme?
    /// Shared by every transport of one connection, the probe's included, so the name is resolved
    /// once however many schemes the probe tries.
    let dialer: HostDialer
    var connectTimeout = 15
    /// Wall-clock bound for a PROPFIND: generous for a large folder over a slow link, tight enough
    /// that a server that stopped answering doesn't hang the pane.
    var metadataTimeout = 30
    /// Wall-clock bound for a download, which may legitimately run for a long time.
    var transferTimeout = 3600

    init(
        location: WebDAVLocation,
        password: String = "",
        trustedPublicKey: String? = nil,
        authentication: WebDAVAuthScheme?,
        dialer: HostDialer? = nil
    ) {
        self.location = location
        self.password = password
        self.trustedPublicKey = trustedPublicKey
        self.authentication = authentication
        self.dialer = dialer ?? HostDialer(host: location.host)
    }

    /// The same connection sending credentials in `scheme` — or none — which is how the probe asks
    /// first with nothing and then in the scheme the server's challenge named.
    func authenticating(with scheme: WebDAVAuthScheme?) -> WebDAVCurlTransport {
        WebDAVCurlTransport(
            location: location,
            password: password,
            trustedPublicKey: trustedPublicKey,
            authentication: scheme,
            dialer: dialer
        )
    }

    func session(maxTime: Int) -> WebDAVSession {
        WebDAVSession(
            location: location,
            dial: dialer.dialed,
            trust: trustedPublicKey.map { .pinned(publicKey: $0) } ?? .systemDefault,
            authentication: authentication,
            connectTimeout: connectTimeout,
            maxTime: maxTime
        )
    }

    // MARK: - Requests

    func propfind(
        _ backendPath: String,
        depth: WebDAVDepth,
        isCollection: Bool
    ) throws -> WebDAVHTTPResponse {
        let session = session(maxTime: metadataTimeout)
        return try perform(
            WebDAVProcessArguments.propfind(
                session: session,
                backendPath: backendPath,
                depth: depth,
                isCollection: isCollection
            ),
            session: session
        )
    }

    /// Progress comes from the destination file, as for FTP and S3: it is a local file that grows,
    /// so its size is exact and free. The exact total is the write-out's, which the backend settles
    /// the bar on.
    func download(
        _ backendPath: String,
        to localPath: String,
        resume: Bool,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> WebDAVHTTPResponse {
        let session = session(maxTime: transferTimeout)
        return try perform(
            WebDAVProcessArguments.download(
                session: session,
                backendPath: backendPath,
                localPath: localPath,
                resume: resume
            ),
            session: session,
            watching: .destinationFile(path: localPath),
            progress: progress,
            isCancelled: isCancelled
        )
    }

    // MARK: - Certificate

    /// Fetch the server's certificate without trusting it, so the trust sheet can show what it is
    /// asking the user to accept. Sends no credential and keeps no body — which is why the one
    /// invocation with `--insecure` and no pin is safe (`WebDAVProcessArguments.certificateProbe`).
    func fetchCertificate() throws -> FTPCertificate {
        let session = session(maxTime: metadataTimeout).with(authentication: nil)
        let arguments = WebDAVProcessArguments.certificateProbe(session: session)
        let result = try run(arguments, configuration: nil)
        guard result.exitCode == 0,
              let certificate = FTPCertificate.parse(
                  curlCertificateBlock: SubprocessText.lossyUTF8(result.standardOutput)
              )
        else { throw WebDAVResponseError.transport(.classify(curlExit: result.exitCode)) }
        return certificate
    }

    // MARK: - Running

    /// Run one request and read it. The config goes on stdin exactly when the session sends
    /// credentials, which is when the arguments carry `-K -` to read it.
    private func perform(
        _ arguments: [String],
        session: WebDAVSession,
        watching source: TransferProgressWatch.Source = .none,
        progress: (Int64) -> Void = { _ in },
        isCancelled: () -> Bool = { false }
    ) throws -> WebDAVHTTPResponse {
        let configuration = session.sendsCredentials
            ? WebDAVConfigFile.credentials(username: location.username, password: password)
            : nil
        let result = try run(
            arguments,
            configuration: configuration,
            watching: source,
            progress: progress,
            isCancelled: isCancelled
        )
        return try WebDAVWriteOut.response(
            exitCode: result.exitCode,
            standardOutput: result.standardOutput,
            standardError: result.standardError
        )
    }

    /// ``CurlProcess/run(_:configuration:backstop:watching:progress:isCancelled:)``, its two
    /// failures spoken in the transport's vocabulary: a `curl` that could not start, or one that
    /// wedged past its backstop, is a request that got no answer.
    private func run(
        _ arguments: [String],
        configuration: String?,
        watching source: TransferProgressWatch.Source = .none,
        progress: (Int64) -> Void = { _ in },
        isCancelled: () -> Bool = { false }
    ) throws -> CurlProcess.Result {
        do {
            return try CurlProcess.run(
                arguments,
                configuration: configuration,
                backstop: CurlProcess.backstop(for: arguments, fallback: metadataTimeout),
                watching: source,
                progress: progress,
                isCancelled: isCancelled
            )
        } catch CurlProcess.Failure.launchFailed {
            throw WebDAVResponseError.transport(.other)
        } catch CurlProcess.Failure.timedOut {
            throw WebDAVResponseError.transport(.operationTimedOut)
        }
    }
}
