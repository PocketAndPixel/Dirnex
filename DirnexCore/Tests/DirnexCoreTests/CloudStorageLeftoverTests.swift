import Foundation
import Testing

@testable import DirnexCore

/// Real directory scans with marker results supplied through the existing `named` seam.
/// macOS can refuse writes to its File Provider marker, so a test must not mint a fake domain.
/// The system marker's positive read is covered by the live probe in docs/NOTES.md ▸ Google Drive.
@Suite("CloudStorageMounts — leftover folders")
struct CloudStorageLeftoverTests {
    @Test("the marker is the attribute macOS writes, spelled out")
    func markerIsTheSystemsName() {
        // Copied from `xattr` on this Mac's mounts and the "CloudStorage xattrs" section of
        // `fileproviderctl dump -l`. Injected marker results cannot catch a typo in this name.
        #expect(CloudStorageMounts.domainMarkerAttribute == "com.apple.file-provider-domain-id")
    }

    /// Only these exact paths answer as marked. No shared state or system attributes are changed.
    private func namedMounts(in temp: TempTree, marked names: [String]) -> [CloudStorageMount] {
        let marked = Set(names.map { temp.path("Library/CloudStorage/\($0)") })
        return CloudStorageMounts.named(home: temp.root.path) { marked.contains($0) }
    }

    /// The shape found on this Mac: Dropbox set its domain up again and left a dated folder behind.
    private func makeDropboxWithLeftover(in temp: TempTree) throws {
        try temp.makeDir("Library/CloudStorage/Dropbox")
        try temp.makeDir("Library/CloudStorage/Dropbox-Home (18.10.2026 00:09)/Oleg V")
        try temp.makeDir("Library/CloudStorage/GoogleDrive-a@gmail.com")
    }

    @Test("a folder a sync client left behind is not a mount")
    func leftoverFolderIsNotAMount() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        try makeDropboxWithLeftover(in: temp)

        let mounts = namedMounts(in: temp, marked: ["Dropbox", "GoogleDrive-a@gmail.com"])
        #expect(mounts.map(\.name) == ["Dropbox", "Google Drive"])
        #expect(mounts.map(\.directoryName) == ["Dropbox", "GoogleDrive-a@gmail.com"])
    }

    @Test("the real account is named as if the leftover were not there")
    func leftoverDoesNotMakeTheRealAccountAmbiguous() throws {
        // A bare `Dropbox` reads "Dropbox" either way; this label makes the wrong count visible.
        let temp = try TempTree()
        defer { temp.cleanup() }
        try temp.makeDir("Library/CloudStorage/Dropbox-Personal")
        try temp.makeDir("Library/CloudStorage/Dropbox-Home (18.10.2026 00:09)")

        #expect(namedMounts(in: temp, marked: ["Dropbox-Personal"]).map(\.name) == ["Dropbox"])
    }

    @Test("two real accounts of one provider are still both listed and told apart")
    func twoMarkedAccountsAreBothKept() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        try temp.makeDir("Library/CloudStorage/Dropbox-Home")
        try temp.makeDir("Library/CloudStorage/Dropbox-Personal")
        try temp.makeDir("Library/CloudStorage/Dropbox-Home (18.10.2026 00:09)")

        #expect(namedMounts(in: temp, marked: ["Dropbox-Home", "Dropbox-Personal"]).map(\.name) == [
            "Home — Dropbox", "Personal — Dropbox"
        ])
    }

    @Test("the shared mount list contains only current root paths")
    func sharedMountPathsExcludeLeftovers() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        try makeDropboxWithLeftover(in: temp)

        // This is the list the public path lookup consumes. Its matching logic has separate tests
        // in CloudStorageMountEntryTests; the marker-dependent filtering is checked here.
        let mounts = namedMounts(in: temp, marked: ["Dropbox", "GoogleDrive-a@gmail.com"])
        #expect(mounts.map(\.path) == [
            temp.vfsPath("Library/CloudStorage/Dropbox"),
            temp.vfsPath("Library/CloudStorage/GoogleDrive-a@gmail.com")
        ])
    }

    @Test("a leftover with a trash folder is absent from the shared mount list")
    func leftoverWithTrashIsNotAMount() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        let cloud = "Library/CloudStorage"
        try temp.makeDir("\(cloud)/GoogleDrive-a@gmail.com/.Trash")
        try temp.makeDir("\(cloud)/GoogleDrive-old@gmail.com/.Trash")

        // Trash enumeration consumes `named` too. Its public entry point has no marker seam:
        // pin the shared filtered input here, and leave trash-path assembly to TrashLocationsTests.
        let mounts = namedMounts(in: temp, marked: ["GoogleDrive-a@gmail.com"])
        #expect(mounts.map(\.path) == [temp.vfsPath("\(cloud)/GoogleDrive-a@gmail.com")])
    }

    @Test("a Mac whose system writes no domain marker keeps every folder")
    func noMarkerAnywhereKeepsEverything() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        try temp.makeDir("Library/CloudStorage/Dropbox")
        try temp.makeDir("Library/CloudStorage/Dropbox-Home (18.10.2026 00:09)")

        #expect(namedMounts(in: temp, marked: []).map(\.directoryName) == [
            "Dropbox", "Dropbox-Home (18.10.2026 00:09)"
        ])
    }

    @Test("a marker that cannot be read keeps its folder")
    func unreadableMarkerKeepsTheFolder() throws {
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

    @Test("the scan asks for the symlink's marker, not its target's")
    func markerReadUsesTheSymlinkPath() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        let root = try temp.makeDir("Library/CloudStorage/Dropbox")
        let alias = temp.path("Library/CloudStorage/Dropbox-Alias")
        try temp.symlink("Library/CloudStorage/Dropbox-Alias", to: root)
        var queried: Set<String> = []

        let mounts = CloudStorageMounts.named(home: temp.root.path) { path in
            queried.insert(path)
            return path == root
        }
        #expect(queried == [root, alias])
        #expect(mounts.map(\.directoryName) == ["Dropbox"])
    }

    @Test(
        "the marker reader separates an absent attribute from a failed read without following links"
    )
    func markerReaderHandlesMissingAttributesAndPaths() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        try temp.makeDir("leftover")
        try temp.symlink("dangling", to: temp.path("missing"))

        #expect(CloudStorageMounts.carriesDomainMarker(atPath: temp.path("leftover")) == false)
        // ENOENT is not ENOATTR. The missing target fails a read, but the link itself has no marker.
        #expect(CloudStorageMounts.carriesDomainMarker(atPath: temp.path("missing")) == nil)
        #expect(CloudStorageMounts.carriesDomainMarker(atPath: temp.path("dangling")) == false)
    }
}
