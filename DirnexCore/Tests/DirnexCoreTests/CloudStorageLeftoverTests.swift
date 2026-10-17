import Foundation
import Testing

@testable import DirnexCore

/// Folders a sync client left behind under `~/Library/CloudStorage`, which are not File Provider
/// domains and must not be read as mounts (``CloudStorageMounts/domainMarkerAttribute``).
///
/// These run against real directories stamped with the real attribute, like `FinderTagStorage`'s
/// suite: the subject is what macOS writes and what `getxattr` answers, and a fake would only hand
/// this pass's assumptions back to it. The one injected read is the failure no directory can be
/// made to produce on demand.
@Suite("CloudStorageMounts — leftover folders")
struct CloudStorageLeftoverTests {
    @Test("the marker is the attribute macOS writes, spelled out")
    func markerIsTheSystemsName() {
        // Every fixture below stamps through the constant, so a typo in it would pass them all while
        // the real mounts read as leftovers. The literal is copied from `xattr` on this Mac's mounts
        // and from the "CloudStorage xattrs" section of `fileproviderctl dump -l`.
        #expect(CloudStorageMounts.domainMarkerAttribute == "com.apple.file-provider-domain-id")
    }

    /// The real shape found on this Mac 2026-10-18: Dropbox set its domain up again as `Dropbox`
    /// and left the old folder beside it under a dated name, without the domain marker.
    private func dropboxWithLeftover() throws -> TempTree {
        let temp = try TempTree()
        try temp.makeDomainRoot("Library/CloudStorage/Dropbox")
        try temp.makeDir("Library/CloudStorage/Dropbox-Home (18.10.2026 00:09)/Oleg V")
        try temp.makeDomainRoot("Library/CloudStorage/GoogleDrive-a@gmail.com")
        return temp
    }

    @Test("a folder a sync client left behind is not a mount")
    func leftoverFolderIsNotAMount() throws {
        // Before the filter this listed "Dropbox" beside "Home (18.10.2026 00:09) — Dropbox".
        let temp = try dropboxWithLeftover()
        defer { temp.cleanup() }

        let mounts = CloudStorageMounts.mounts(home: temp.root.path)
        #expect(mounts.map(\.name) == ["Dropbox", "Google Drive"])
        #expect(mounts.map(\.directoryName) == ["Dropbox", "GoogleDrive-a@gmail.com"])
    }

    @Test("the real account is named as if the leftover were not there")
    func leftoverDoesNotMakeTheRealAccountAmbiguous() throws {
        // The real mount needs an account label for this to bite: a bare `Dropbox` reads "Dropbox"
        // either way. Counted with the leftover, this one was "Personal — Dropbox".
        let temp = try TempTree()
        defer { temp.cleanup() }
        try temp.makeDomainRoot("Library/CloudStorage/Dropbox-Personal")
        try temp.makeDir("Library/CloudStorage/Dropbox-Home (18.10.2026 00:09)")

        #expect(CloudStorageMounts.mounts(home: temp.root.path).map(\.name) == ["Dropbox"])
    }

    @Test("two real accounts of one provider are still both listed and told apart")
    func twoMarkedAccountsAreBothKept() throws {
        // The control for the test above: the filter drops the folder without the marker, not the
        // second account of a provider.
        let temp = try TempTree()
        defer { temp.cleanup() }
        try temp.makeDomainRoot("Library/CloudStorage/Dropbox-Home")
        try temp.makeDomainRoot("Library/CloudStorage/Dropbox-Personal")
        try temp.makeDir("Library/CloudStorage/Dropbox-Home (18.10.2026 00:09)")

        #expect(CloudStorageMounts.mounts(home: temp.root.path).map(\.name) == [
            "Home — Dropbox", "Personal — Dropbox"
        ])
    }

    @Test("a path inside a leftover folder has no provider to name it")
    func pathInsideLeftoverHasNoMount() throws {
        let temp = try dropboxWithLeftover()
        defer { temp.cleanup() }
        let home = temp.root.path

        let leftover = temp.vfsPath("Library/CloudStorage/Dropbox-Home (18.10.2026 00:09)/Oleg V")
        #expect(CloudStorageMounts.mount(containing: leftover, home: home) == nil)
        let real = temp.vfsPath("Library/CloudStorage/Dropbox/Team")
        #expect(CloudStorageMounts.mount(containing: real, home: home)?.name == "Dropbox")
    }

    @Test("a Mac whose system writes no domain marker keeps every folder")
    func noMarkerAnywhereKeepsEverything() throws {
        // The package targets macOS 14 and the marker is measured on 26 only. If a system does not
        // write it, every folder reads as a leftover, and filtering anyway would empty the section.
        let temp = try TempTree()
        defer { temp.cleanup() }
        try temp.makeDir("Library/CloudStorage/Dropbox")
        try temp.makeDir("Library/CloudStorage/Dropbox-Home (18.10.2026 00:09)")

        #expect(CloudStorageMounts.mounts(home: temp.root.path).map(\.directoryName) == [
            "Dropbox", "Dropbox-Home (18.10.2026 00:09)"
        ])
    }

    @Test("a marker that cannot be read keeps its folder")
    func unreadableMarkerKeepsTheFolder() throws {
        // A failed read says nothing about the folder, and hiding a real account costs far more than
        // showing a stale one. The read is injected because a real directory cannot be made to fail
        // it on demand.
        let temp = try TempTree()
        defer { temp.cleanup() }
        try temp.makeDir("Library/CloudStorage/Box-Box")
        try temp.makeDir("Library/CloudStorage/Dropbox")
        try temp.makeDir("Library/CloudStorage/OneDrive-Personal")
        // Dropbox has no answer: its read fails.
        let answers = ["Box-Box": true, "OneDrive-Personal": false]

        let mounts = CloudStorageMounts.named(home: temp.root.path) { path in
            answers[(path as NSString).lastPathComponent]
        }
        #expect(mounts.map(\.directoryName) == ["Box-Box", "Dropbox"])
    }

    @Test("a symlink beside the mounts is not a domain, whatever it points at")
    func symlinkToADomainIsNotOne() throws {
        // `isDirectory` follows the link, so only `XATTR_NOFOLLOW` keeps it out. Following would
        // read the target's marker and list the same account twice.
        let temp = try TempTree()
        defer { temp.cleanup() }
        try temp.makeDomainRoot("Library/CloudStorage/Dropbox")
        try temp.symlink(
            "Library/CloudStorage/Dropbox-Alias",
            to: temp.path("Library/CloudStorage/Dropbox")
        )

        #expect(CloudStorageMounts.mounts(home: temp.root.path).map(\.directoryName) == ["Dropbox"])
    }

    @Test("the marker read answers present, absent, and failed")
    func markerReadHasThreeAnswers() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        try temp.makeDomainRoot("domain")
        try temp.makeDir("leftover")

        #expect(CloudStorageMounts.carriesDomainMarker(atPath: temp.path("domain")) == true)
        #expect(CloudStorageMounts.carriesDomainMarker(atPath: temp.path("leftover")) == false)
        // `ENOENT` is not `ENOATTR`: a read that failed is not evidence of a leftover.
        #expect(CloudStorageMounts.carriesDomainMarker(atPath: temp.path("missing")) == nil)
    }
}
