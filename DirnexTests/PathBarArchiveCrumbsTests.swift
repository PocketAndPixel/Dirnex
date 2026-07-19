import DirnexCore
import Testing
@testable import Dirnex

/// The path bar renders a browsed archive as a full, clickable breadcrumb trail — the archive's
/// real on-disk ancestors, then the archive itself, then its inner path — styled exactly like a
/// local path. `PathBarView.archiveCrumbs` derives that trail (title + navigable target per crumb);
/// these tests pin its output, especially the nested-archive chain whose frames cross backends.
@MainActor
@Suite("PathBarView archive crumbs")
struct PathBarArchiveCrumbsTests {
    private func archive(_ onDisk: String) -> VFSBackendID { .archive(forArchiveAt: onDisk) }

    @Test("top-level archive: full path, then archive name, then inner directories")
    func topLevelArchive() {
        let zip = "/Users/oleg/Downloads/archive.zip"
        let path = VFSPath(backend: archive(zip), path: "/folder/sub")

        let crumbs = PathBarView.archiveCrumbs(for: path, ancestry: [])

        #expect(crumbs.map(\.title) == [
            "Macintosh HD", "Users", "oleg", "Downloads", "archive.zip", "folder", "sub"
        ])
        // The containing folders exit the archive to a real local directory.
        #expect(crumbs[3].target == .local("/Users/oleg/Downloads"))
        // The archive-name crumb re-enters the archive at its root.
        #expect(crumbs[4].target == VFSPath(backend: archive(zip), path: "/"))
        // Inner crumbs jump within the archive; the last is the current location.
        #expect(crumbs[5].target == VFSPath(backend: archive(zip), path: "/folder"))
        #expect(crumbs[6].target == VFSPath(backend: archive(zip), path: "/folder/sub"))
    }

    @Test("nested archive: the trail spans the whole chain (matches the screenshot scenario)")
    func nestedArchive() {
        let outer = "/Users/oleg/Downloads/time-sync_v3log.zip"
        let innerMount = "/private/tmp/xyz/time-sync_v2.zip" // the extracted-to-temp inner archive
        // The one enclosing member: time-sync_v2.zip lives inside the outer archive.
        let ancestry = [VFSPath(backend: archive(outer), path: "/time-sync_v2.zip")]
        let path = VFSPath(backend: archive(innerMount), path: "/time-sync_v2/build")

        let crumbs = PathBarView.archiveCrumbs(for: path, ancestry: ancestry)

        #expect(crumbs.map(\.title) == [
            "Macintosh HD", "Users", "oleg", "Downloads",
            "time-sync_v3log.zip", "time-sync_v2.zip", "time-sync_v2", "build"
        ])
        // Outer archive name → the outer archive's (real, on-disk) root.
        #expect(crumbs[4].target == VFSPath(backend: archive(outer), path: "/"))
        // The nested-archive boundary crumb → the inner (temp-mounted) archive's root.
        #expect(crumbs[5].target == VFSPath(backend: archive(innerMount), path: "/"))
        // Inner directories resolve within the inner archive; the last is where we are.
        #expect(crumbs[6].target == VFSPath(backend: archive(innerMount), path: "/time-sync_v2"))
        #expect(
            crumbs[7].target == VFSPath(backend: archive(innerMount), path: "/time-sync_v2/build")
        )
    }

    @Test("doubly-nested archive: middle-frame directories appear in order")
    func doublyNestedArchive() {
        let outer = "/a/b/outer.zip"
        let midMount = "/private/tmp/mid.zip"
        let innerMount = "/private/tmp/inner.zip"
        let ancestry = [
            VFSPath(backend: archive(outer), path: "/sub/mid.zip"), // outermost enclosing member
            VFSPath(backend: archive(midMount), path: "/deep/inner.zip")
        ]
        let path = VFSPath(backend: archive(innerMount), path: "/x/y")

        let crumbs = PathBarView.archiveCrumbs(for: path, ancestry: ancestry)

        #expect(crumbs.map(\.title) == [
            "Macintosh HD", "a", "b",
            "outer.zip", "sub", "mid.zip", "deep", "inner.zip", "x", "y"
        ])
        // A directory inside a middle (outer) frame resolves within that frame's backend.
        #expect(crumbs[4].target == VFSPath(backend: archive(outer), path: "/sub"))
        #expect(crumbs[6].target == VFSPath(backend: archive(midMount), path: "/deep"))
        #expect(crumbs[9].target == VFSPath(backend: archive(innerMount), path: "/x/y"))
    }
}
