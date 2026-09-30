import DirnexCore
import Foundation

/// `CompositeBackend`'s live remote connections: establishing one, remembering what it was made
/// with, and handing it back to the routing.
///
/// Split out of `CompositeBackend` when the endpoint memory arrived and left the file twelve lines
/// under SwiftLint's ceiling — by concept rather than by line count, which is the seam this half
/// already had: everything here is about *a connection existing*, and what is left there is about
/// which backend a `VFSPath` belongs to. The four lookups come along because they are the one place
/// a missing connection turns into `serverNotConnected`, and that is the answer this file owes the
/// router rather than a fact about routing.
///
/// The storage stays in the main file and is `internal` for the ordinary reason: Swift's `private`
/// does not cross files (docs/NOTES.md ▸ Lint ceilings and file splitting).
extension CompositeBackend {
    /// Establish (or replace) an SFTP connection for `location`, returning its backend so the caller
    /// can test it (list the home directory) before navigating a pane onto it. `authentication` is a
    /// key file or a password; for password auth `password` is the plaintext the transport feeds to
    /// `sftp` out-of-band (held only in memory for the connection's lifetime, mirrored into the
    /// Keychain separately). An identity-file path is a reference, not a secret, so it is safe to
    /// retain either way.
    @discardableResult
    func connectSFTP(
        location: SFTPLocation,
        authentication: SFTPAuthentication,
        password: String? = nil
    ) -> SFTPBackend {
        let transport = SFTPProcessTransport(
            location: location,
            authentication: authentication,
            password: password
        )
        let backend = SFTPBackend(location: location, transport: transport)
        lock.lock()
        defer { lock.unlock() }
        sftpConnections[location.descriptor] = backend
        endpoints[location.descriptor] = .sftp(location: location, authentication: authentication)
        return backend
    }

    /// Establish (or replace) an FTP connection for `location`, returning its backend so the caller
    /// can test it before navigating a pane onto it. `password` is the plaintext the transport feeds
    /// to `curl` on stdin (held only in memory for the connection's lifetime, mirrored into the
    /// Keychain separately); `trustedPublicKey` is the certificate pin the user accepted, which is a
    /// public key digest rather than a secret.
    @discardableResult
    func connectFTP(
        location: FTPLocation,
        authentication: FTPAuthentication,
        password: String = "",
        trustedPublicKey: String? = nil
    ) -> FTPBackend {
        let transport = FTPCurlTransport(
            location: location,
            authentication: authentication,
            password: password,
            trustedPublicKey: trustedPublicKey
        )
        let backend = FTPBackend(location: location, transport: transport)
        lock.lock()
        defer { lock.unlock() }
        ftpConnections[location.descriptor] = backend
        endpoints[location.descriptor] = .ftp(
            location: location,
            authentication: authentication,
            trustedPublicKey: trustedPublicKey
        )
        return backend
    }

    /// Establish (or replace) an S3 connection for `location`, returning its backend so the caller
    /// can test it (list the bucket root) before navigating a pane onto it. `secretAccessKey` is
    /// the plaintext the transport feeds to `curl` on stdin (held only in memory for the
    /// connection's lifetime, mirrored into the Keychain separately); the *access key id* is not a
    /// secret and rides in the location itself.
    @discardableResult
    func connectS3(location: S3Location, secretAccessKey: String) -> S3Backend {
        let transport = S3CurlTransport(location: location, secretAccessKey: secretAccessKey)
        return register(s3: S3Backend(location: location, transport: transport))
    }

    /// Install an already-built bucket backend under its own descriptor — `connectS3` without the
    /// `curl` transport.
    ///
    /// The split exists because **the routing is what breaks silently while running it needs a
    /// network**: a copy that reaches the wrong backend, or a hint that stops at this class, reports
    /// nothing at all (docs/HISTORY.md ▸ After M19, and the `subtreeListing` shape docs/NOTES.md records). A backend
    /// over a fake transport is how those are asserted headlessly. Nothing in the app calls it.
    @discardableResult
    func register(s3 backend: S3Backend) -> S3Backend {
        lock.lock()
        defer { lock.unlock() }
        s3Connections[backend.location.descriptor] = backend
        endpoints[backend.location.descriptor] = .s3(backend.location)
        return backend
    }

    /// Establish (or replace) a connection to a whole S3 account, returning its backend so the
    /// caller can test it (list the buckets) before navigating a pane onto it. `secretAccessKey` is
    /// the plaintext the transport feeds to `curl` on stdin, exactly as the bucket connection's is.
    ///
    /// An account is a *second* root and never the only one, which is why this sits beside
    /// `connectS3` rather than replacing it: a key scoped to one bucket cannot make this call at
    /// all, and the bucket-rooted connection it does use is untouched by any of this.
    @discardableResult
    func connectS3Account(account: S3Account, secretAccessKey: String) -> S3AccountBackend {
        let transport = S3AccountCurlTransport(
            account: account,
            secretAccessKey: secretAccessKey
        )
        let backend = S3AccountBackend(account: account, transport: transport)
        lock.lock()
        defer { lock.unlock() }
        s3AccountConnections[account.descriptor] = backend
        endpoints[account.descriptor] = .s3Account(account)
        return backend
    }

    /// What the connection serving `backendID` was established with, or `nil` when nothing here is
    /// serving it. Never a secret — see ``endpoints``.
    func endpoint(for backendID: VFSBackendID) -> ServerEndpoint? {
        lock.lock()
        defer { lock.unlock() }
        return endpoints[backendID.rawValue]
    }

    /// Whether a path on `backendID` can be listed right now without connecting first.
    ///
    /// Asked of the **endpoint memory** rather than of the four connection dictionaries, which is
    /// what keeps it one question with one answer: every registration writes here, so a backend
    /// added later cannot be connected-but-invisible to a caller that forgot to name it. That is
    /// this project's most repeated bug, and a reconnect that reads the wrong answer spends a
    /// second connection rather than reporting anything (docs/NOTES.md ▸ AppKit).
    func isConnected(_ backendID: VFSBackendID) -> Bool {
        endpoint(for: backendID) != nil
    }

    // MARK: - Handing a connection to the router

    func connectedS3Account(for backendID: VFSBackendID) throws -> S3AccountBackend {
        guard let backend = s3AccountBackend(for: backendID) else {
            throw VFSError.unsupported(.serverNotConnected(server: "\(backendID)"))
        }
        return backend
    }

    /// The connected S3 account backend for `backendID`, or `nil` when there's no live connection —
    /// the non-throwing lookup `capabilities(for:)` needs (it must never throw and must stay cheap).
    func s3AccountBackend(for backendID: VFSBackendID) -> S3AccountBackend? {
        lock.lock()
        defer { lock.unlock() }
        return s3AccountConnections[backendID.rawValue]
    }

    func connectedS3(for backendID: VFSBackendID) throws -> S3Backend {
        guard let backend = s3Backend(for: backendID) else {
            throw VFSError.unsupported(.serverNotConnected(server: "\(backendID)"))
        }
        return backend
    }

    /// The connected S3 backend for `backendID`, or `nil` when there's no live connection — the
    /// non-throwing lookup `capabilities(for:)` needs (it must never throw and must stay cheap).
    ///
    /// Internal rather than private for `CompositeBackend+Transfer`'s cross-bucket route, which
    /// asks the same question of the *destination* (Swift's `private` does not cross files).
    func s3Backend(for backendID: VFSBackendID) -> S3Backend? {
        lock.lock()
        defer { lock.unlock() }
        return s3Connections[backendID.rawValue]
    }

    func connectedFTP(for backendID: VFSBackendID) throws -> FTPBackend {
        guard let backend = ftpBackend(for: backendID) else {
            throw VFSError.unsupported(.serverNotConnected(server: "\(backendID)"))
        }
        return backend
    }

    /// The connected FTP backend for `backendID`, or `nil` when there's no live connection — the
    /// non-throwing lookup `capabilities(for:)` needs (it must never throw and must stay cheap).
    func ftpBackend(for backendID: VFSBackendID) -> FTPBackend? {
        lock.lock()
        defer { lock.unlock() }
        return ftpConnections[backendID.rawValue]
    }

    func connectedSFTP(for backendID: VFSBackendID) throws -> SFTPBackend {
        guard let backend = sftpBackend(for: backendID) else {
            throw VFSError.unsupported(.serverNotConnected(server: "\(backendID)"))
        }
        return backend
    }

    /// The connected SFTP backend for `backendID`, or `nil` when there's no live connection — the
    /// non-throwing lookup `capabilities(for:)` needs (it must never throw and must stay cheap).
    func sftpBackend(for backendID: VFSBackendID) -> SFTPBackend? {
        lock.lock()
        defer { lock.unlock() }
        return sftpConnections[backendID.rawValue]
    }}
