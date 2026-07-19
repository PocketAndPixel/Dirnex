import Foundation
import Testing

@testable import DirnexCore

@Suite("NestedArchiveMap")
struct NestedArchiveMapTests {
    /// The member `VFSPath` of `member` inside the archive at `archiveOnDiskPath`.
    private func member(_ member: String, inArchiveAt archiveOnDiskPath: String) -> VFSPath {
        VFSPath(backend: .archive(forArchiveAt: archiveOnDiskPath), path: member)
    }

    @Test("origin returns the member a mount came from, nil for an unrecorded (top-level) mount")
    func originOfMount() {
        var map = NestedArchiveMap()
        let origin = member("/sub/inner.zip", inArchiveAt: "/Users/me/outer.zip")
        map.record(mountOnDiskPath: "/tmp/DirnexExtract/A/sub/inner.zip", origin: origin)

        #expect(map.origin(ofMountOnDiskPath: "/tmp/DirnexExtract/A/sub/inner.zip") == origin)
        // A top-level archive opened from a local file was never recorded — no origin to walk to.
        #expect(map.origin(ofMountOnDiskPath: "/Users/me/outer.zip") == nil)
    }

    @Test("mountOnDiskPath reuses a prior extraction for the same member")
    func mountForOriginReuse() {
        var map = NestedArchiveMap()
        let origin = member("/inner.zip", inArchiveAt: "/Users/me/outer.zip")
        #expect(map.mountOnDiskPath(forOrigin: origin) == nil)

        map.record(mountOnDiskPath: "/tmp/DirnexExtract/A/inner.zip", origin: origin)
        #expect(map.mountOnDiskPath(forOrigin: origin) == "/tmp/DirnexExtract/A/inner.zip")
    }

    @Test("ancestry is empty for a top-level archive")
    func ancestryTopLevel() {
        let map = NestedArchiveMap()
        #expect(map.ancestry(ofMountOnDiskPath: "/Users/me/outer.zip").isEmpty)
    }

    @Test("ancestry walks the whole chain outermost-first for a doubly-nested archive")
    func ancestryTwoDeep() {
        var map = NestedArchiveMap()
        // outer.zip (local) ▸ sub/mid.zip ▸ inner.zip, each extracted to its own temp file.
        let midMount = "/tmp/DirnexExtract/A/sub/mid.zip"
        let midOrigin = member("/sub/mid.zip", inArchiveAt: "/Users/me/outer.zip")
        map.record(mountOnDiskPath: midMount, origin: midOrigin)

        let innerMount = "/tmp/DirnexExtract/B/inner.zip"
        let innerOrigin = member("/inner.zip", inArchiveAt: midMount)
        map.record(mountOnDiskPath: innerMount, origin: innerOrigin)

        // Outermost member first, ending with the member that produced the current mount.
        #expect(map.ancestry(ofMountOnDiskPath: innerMount) == [midOrigin, innerOrigin])
        // The intermediate mount resolves to just its own single ancestor.
        #expect(map.ancestry(ofMountOnDiskPath: midMount) == [midOrigin])
    }

    @Test("re-recording a member repoints its reuse index to the newest extraction")
    func rerecordRepointsReuse() {
        var map = NestedArchiveMap()
        let origin = member("/inner.zip", inArchiveAt: "/Users/me/outer.zip")
        map.record(mountOnDiskPath: "/tmp/DirnexExtract/A/inner.zip", origin: origin)
        map.record(mountOnDiskPath: "/tmp/DirnexExtract/B/inner.zip", origin: origin)

        #expect(map.mountOnDiskPath(forOrigin: origin) == "/tmp/DirnexExtract/B/inner.zip")
        // Both temp paths still resolve back to the same origin (each keeps its own reverse link).
        #expect(map.origin(ofMountOnDiskPath: "/tmp/DirnexExtract/A/inner.zip") == origin)
        #expect(map.origin(ofMountOnDiskPath: "/tmp/DirnexExtract/B/inner.zip") == origin)
    }
}
