import Foundation
import Testing

@testable import DirnexCore

/// A volume that keeps **no Trash** refuses `trashItem` with `NSFeatureUnsupportedError` (3328),
/// and `LocalBackend` has to name that rather than pass the number on. Reported by a user
/// 2026-08-25 as *"The system reported an error (code 3 328)"* on F8 over a mounted SMB share.
///
/// Driven against ``LocalBackend/trashFailure(_:path:)`` rather than against a real volume,
/// because the state cannot be arranged on this Mac: every filesystem a `hdiutil` image can carry
/// **does** trash (measured 2026-08-25 — freshly created ExFAT and HFS+ volumes both landed the
/// file in `<volume>/.Trashes/501`), so producing the refusal needs a network share. The split is
/// the one `ByteComparator` draws for `SF_DATALESS`: the rule is a pure function of the error, and
/// only the syscall that raises it needs the real thing.
@Suite("LocalBackend trash refusal")
struct LocalBackendTrashRefusalTests {
    private let path = VFSPath.local("/Volumes/Photos/t.txt")

    private func cocoa(_ code: Int, underlying: NSError? = nil) -> NSError {
        var info: [String: Any] = [:]
        if let underlying { info[NSUnderlyingErrorKey] = underlying }
        return NSError(domain: NSCocoaErrorDomain, code: code, userInfo: info)
    }

    // MARK: - The refusal

    /// The whole bug: without this the sentence is a number, and the number describes a volume
    /// that is working perfectly and simply has nowhere to put a deleted file.
    @Test("a volume with no Trash is named, not reported as a numeric I/O error")
    func featureUnsupportedBecomesNamedRefusal() {
        let mapped = LocalBackend.trashFailure(cocoa(NSFeatureUnsupportedError), path: path)
        #expect(mapped == .unsupported(.trash))
    }

    /// `trashItem` is the *only* verb that reads 3328 this way, and the ordering it needs is
    /// non-obvious: `mapCocoaError` prefers an errno tucked under `NSUnderlyingErrorKey`, so the
    /// feature check has to run first or a refusal carrying one is reported as that errno instead.
    /// Real 3328s do arrive with an underlying `ENOENT` — `FileManager.url(for: .trashDirectory,
    /// appropriateFor:)` produced exactly that shape on both probe volumes.
    @Test("the feature verdict wins over an errno tucked underneath it")
    func featureUnsupportedOutranksUnderlyingErrno() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        let mapped = LocalBackend.trashFailure(
            cocoa(NSFeatureUnsupportedError, underlying: underlying),
            path: path
        )
        #expect(mapped == .unsupported(.trash))
    }

    // MARK: - Narrowness

    /// The controls that keep the fix from becoming "every trash failure is a missing Trash". Each
    /// of these is a real failure the user must still be told about: offering to delete a file for
    /// good because its permissions are wrong would be the fix doing harm.
    @Test("every other trash failure keeps the mapping it had")
    func otherFailuresAreUnchanged() {
        #expect(
            LocalBackend.trashFailure(cocoa(NSFileNoSuchFileError), path: path) == .notFound(path)
        )
        #expect(
            LocalBackend.trashFailure(cocoa(NSFileWriteNoPermissionError), path: path)
                == .permissionDenied(path)
        )
        #expect(
            LocalBackend.trashFailure(cocoa(NSFileWriteFileExistsError), path: path)
                == .alreadyExists(path)
        )
        // An unrecognised Cocoa code still falls through to the number, which is right: an
        // unknown failure should say so rather than borrow a sentence that fits it by accident.
        #expect(
            LocalBackend.trashFailure(cocoa(NSFileWriteOutOfSpaceError), path: path)
                == .io(path: path, code: Int32(NSFileWriteOutOfSpaceError))
        )
    }

    @Test("an underlying errno is still recovered when the outer code is not the feature verdict")
    func underlyingErrnoStillWins() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        let mapped = LocalBackend.trashFailure(
            cocoa(NSFileWriteUnknownError, underlying: underlying),
            path: path
        )
        #expect(mapped == .permissionDenied(path))
    }

    /// 3328 is a *verdict about the volume*, not about the item, so it must not be confused with
    /// the refusal `LocalBackend` raises itself for an item that is already in a trash — the app
    /// re-offers a permanent delete for one and not for the other.
    @Test("the volume refusal is distinct from the already-in-Trash refusal")
    func distinctFromAlreadyInTrash() {
        #expect(VFSError.unsupported(.trash) != .unsupported(.alreadyInTrash(name: "t.txt")))
    }
}
