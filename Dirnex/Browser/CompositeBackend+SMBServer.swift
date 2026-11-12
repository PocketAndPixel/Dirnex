import DirnexCore
import Foundation

/// One connected SMB server: the backend listing its shares, and the password it was opened with.
///
/// The password is kept because Return on a share mounts it with the same account, and the pane may
/// be on the other side of the window from the one that connected. Held in memory for the window's
/// life like every other connection's secret here, and mirrored into the Keychain separately.
struct SMBServerConnection {
    let backend: SMBServerBackend
    /// `nil` for a guest.
    let password: String?
}

/// `CompositeBackend`'s SMB servers (PLAN.md §M35), apart from the other connections for the line
/// ceiling's sake (docs/NOTES.md ▸ Lint ceilings and file splitting). The storage is in the main file,
/// since an extension cannot hold any.
extension CompositeBackend {
    /// Establish (or replace) the connection listing `server`'s shares. Nothing is asked of the server
    /// here: the caller has already listed it once, to learn whether the account is let in.
    @discardableResult
    func connectSMBServer(server: SMBLocation, password: String?) -> SMBServerBackend {
        let enumerator = SMBShareEnumerator(server: server.server, password: password)
        return register(
            smbServer: SMBServerBackend(server: server, enumerator: enumerator),
            password: password
        )
    }

    /// Install an already-built server backend — `connectSMBServer` without NetFS, so the routing can
    /// be asserted over a fake enumerator (``register(s3:)`` gives the reason).
    @discardableResult
    func register(smbServer backend: SMBServerBackend, password: String?) -> SMBServerBackend {
        lock.lock()
        defer { lock.unlock() }
        let key = backend.id.rawValue
        smbServerConnections[key] = SMBServerConnection(backend: backend, password: password)
        endpoints[key] = .smb(backend.server)
        return backend
    }

    func connectedSMBServer(for backendID: VFSBackendID) throws -> SMBServerBackend {
        guard let connection = smbServerConnection(for: backendID) else {
            throw VFSError.unsupported(.serverNotConnected(server: "\(backendID)"))
        }
        return connection.backend
    }

    /// The connected server for `backendID`, or `nil` when there is none — the non-throwing lookup.
    func smbServerConnection(for backendID: VFSBackendID) -> SMBServerConnection? {
        lock.lock()
        defer { lock.unlock() }
        return smbServerConnections[backendID.rawValue]
    }
}
