import Foundation

/// A backend whose paths all belong to **one** account, endpoint or bucket — every remote backend
/// in the project, and the one guard they all need before a path reaches the wire.
///
/// The rule is small and the consequence of skipping it is not: a `VFSPath` under a *different*
/// connection carries nothing but a raw string, so handing it to this connection would act on
/// whatever happens to live at that path here. `FTPBackend` and `SFTPBackend` got the check from
/// `RemoteTransportBackend`, which they share because their *writes* are the same four verbs.
/// `S3Backend` shares neither — a bucket has no `MKD` and no rename — but needs the identical
/// guard, so it lives one level up rather than being written a second time.
///
/// That is the recurring lesson in docs/NOTES.md stated as a type: one rule with two spellings is
/// how the two drift, and the compiler checks neither.
public protocol ConnectionScopedBackend: VFSBackend {
    /// How this connection names itself in an error the user reads (`user@host:port`, `bucket on
    /// host`).
    var connectionDescriptor: String { get }
}

public extension ConnectionScopedBackend {
    /// Refuse a path belonging to another connection before it reaches the wire.
    func requireOwnBackend(_ path: VFSPath) throws {
        guard path.backend == id else {
            throw VFSError.unsupported(
                .pathOutsideConnection(path: "\(path)", connection: connectionDescriptor)
            )
        }
    }
}
