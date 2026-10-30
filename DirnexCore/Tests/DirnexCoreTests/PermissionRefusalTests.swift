import Foundation
import Testing

@testable import DirnexCore

/// Which local refusals are the item's own permissions (``PermissionRefusal``). Reported
/// 2026-10-30: another account's Documents refused its listing, and the sheet sent an administrator
/// to Full Disk Access, which cannot open a `drwx------` folder owned by someone else.
@Suite("Permission refusal")
struct PermissionRefusalTests {
    private let path = VFSPath.local("/Users/someone/Documents")

    @Test("EACCES is the item's own permissions")
    func eaccesIsTheItem() {
        let mapped = VFSError.fromErrno(EACCES, path: path)
        #expect(mapped == .permissionDenied(path, refusedBy: .itemPermissions))
    }

    /// TCC's errno, measured from an app that was its own responsible process. It stays unattributed
    /// so the sentence that names Full Disk Access keeps reaching the refusals that grant lifts.
    @Test("EPERM is not attributed to the item")
    func epermIsUnattributed() {
        let mapped = VFSError.fromErrno(EPERM, path: path)
        #expect(mapped == .permissionDenied(path, refusedBy: .unattributed))
    }

    /// Every server backend and every Cocoa-only refusal constructs the case without saying, so the
    /// default is what keeps them out of the new sentence.
    @Test("a refusal that does not say is unattributed")
    func defaultIsUnattributed() {
        #expect(VFSError.permissionDenied(path) == .permissionDenied(path, refusedBy: .unattributed))
    }

    @Test("a Cocoa refusal with no errno under it is unattributed")
    func cocoaWithoutErrno() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        #expect(LocalBackend.trashFailure(error, path: path) == .permissionDenied(path))
    }

    /// The real syscall, on a folder this account owns with every mode bit cleared: the same
    /// `EACCES` another account's `drwx------` folder gives, without needing a second account.
    @Test("a folder whose mode refuses its listing is the item's own permissions")
    func realModeRefusal() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let folder = try tree.makeDir("locked")
        #expect(chmod(folder, 0) == 0)
        defer { chmod(folder, 0o755) }

        let locked = tree.vfsPath("locked")
        #expect(throws: VFSError.permissionDenied(locked, refusedBy: .itemPermissions)) {
            try LocalBackend().listDirectory(at: locked)
        }
    }
}
