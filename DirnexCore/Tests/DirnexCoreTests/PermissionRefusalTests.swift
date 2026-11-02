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
        let folder = try tree.makeDir("closed")
        #expect(chmod(folder, 0) == 0)
        defer { chmod(folder, 0o755) }

        let closed = tree.vfsPath("closed")
        #expect(throws: VFSError.permissionDenied(closed, refusedBy: .itemPermissions)) {
            try LocalBackend().listDirectory(at: closed)
        }
    }

    // MARK: - A locked item

    private static let locked = BSDFileFlags.userImmutable

    @Test("an EPERM names the locked item, or else the locked folder it is in")
    func lockedItemOrFolder() {
        let file = VFSPath.local("/Volumes/data/folder/file.txt")
        let folder = VFSPath.local("/Volumes/data/folder")
        let onItem = PermissionRefusal.notPermitted(at: [file]) { $0 == file.path ? Self.locked : [] }
        #expect(onItem == .locked(file))
        let onFolder = PermissionRefusal.notPermitted(at: [file]) { $0 == folder.path ? Self.locked : nil }
        #expect(onFolder == .locked(folder))
        let neither = PermissionRefusal.notPermitted(at: [file]) { _ in [] }
        #expect(neither == .unattributed)
    }

    /// The root-only bit blocks the same writes, so it is the same answer.
    @Test("the root-only immutable flag counts as locked")
    func systemImmutable() {
        let file = VFSPath.local("/Volumes/data/file.txt")
        let immutable = PermissionRefusal.notPermitted(at: [file]) { _ in .systemImmutable }
        #expect(immutable == .locked(file))
        let hidden = PermissionRefusal.notPermitted(at: [file]) { _ in .hidden }
        #expect(hidden == .unattributed)
    }

    @Test("a move is checked at both ends")
    func bothEndsOfAMove() {
        let source = VFSPath.local("/Volumes/data/open/a.txt")
        let destination = VFSPath.local("/Volumes/data/locked/a.txt")
        let refusal = PermissionRefusal.notPermitted(at: [source, destination]) {
            $0 == "/Volumes/data/locked" ? Self.locked : nil
        }
        #expect(refusal == .locked(VFSPath.local("/Volumes/data/locked")))
    }

    @Test("a path on a server is never looked up on this Mac")
    func remoteIsNotLookedUp() {
        let server = VFSBackendID.sftp(SFTPLocation(host: "srv", username: "o"))
        var asked: [String] = []
        let refusal = PermissionRefusal.notPermitted(at: [VFSPath(backend: server, path: "/x")]) {
            asked.append($0)
            return Self.locked
        }
        #expect(refusal == .unattributed)
        #expect(asked.isEmpty)
    }

    /// The real syscalls, on a folder and a file locked with `chflags uchg`, through the backend's
    /// own create, move, delete and Trash mapping.
    @Test("the backend names a real locked folder or file")
    func realLocks() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let folder = try tree.makeDir("locked")
        try tree.makeDir("open")
        try tree.writeFile("open/a.txt", contents: "a")
        let file = try tree.writeFile("file.txt", contents: "f")
        #expect(chflags(folder, UInt32(UF_IMMUTABLE)) == 0)
        #expect(chflags(file, UInt32(UF_IMMUTABLE)) == 0)
        defer {
            chflags(folder, 0)
            chflags(file, 0)
        }
        let backend = LocalBackend()
        let lockedFolder = tree.vfsPath("locked")
        let lockedFile = tree.vfsPath("file.txt")
        let created = tree.vfsPath("locked/new.txt")
        let moved = tree.vfsPath("open/a.txt")

        #expect(throws: VFSError.permissionDenied(created, refusedBy: .locked(lockedFolder))) {
            try backend.createFile(at: created)
        }
        #expect(throws: VFSError.permissionDenied(moved, refusedBy: .locked(lockedFolder))) {
            try backend.moveItem(at: moved, to: tree.vfsPath("locked/a.txt"))
        }
        #expect(throws: VFSError.permissionDenied(lockedFile, refusedBy: .locked(lockedFile))) {
            try backend.removeItem(at: lockedFile)
        }
        // The shape `trashItem` gave on the same fixture: Cocoa's 513 over an OSStatus, no errno.
        let trash = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteNoPermissionError,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -5000)]
        )
        let mapped = LocalBackend.trashFailure(trash, path: lockedFile)
        #expect(mapped == .permissionDenied(lockedFile, refusedBy: .locked(lockedFile)))
    }

    /// The negative half on the same disk: an `EPERM` with nothing locked stays unattributed, so the
    /// refusals Full Disk Access does lift keep the sentence that names it.
    @Test("nothing locked leaves an EPERM unattributed")
    func unlockedStaysUnattributed() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("plain.txt", contents: "p")
        let file = tree.vfsPath("plain.txt")
        let mapped = VFSError.fromErrno(EPERM, path: file)
        #expect(mapped == .permissionDenied(file, refusedBy: .unattributed))
    }
}
