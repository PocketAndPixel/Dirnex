import Foundation
import Testing

@testable import DirnexCore

/// Which app containers belong in iCloud Drive. The merged listing and the Full Disk Access
/// degradation live in `ICloudDriveMergeTests`.
@Suite("ICloudDrive")
struct ICloudDriveTests {
    // MARK: - Layout

    @Test("the containers live as siblings under Mobile Documents, not inside CloudDocs")
    func mobileDocumentsIsTheParent() {
        // Probed 2026-07-21 — the M8 row browsed CloudDocs, and every app library is beside
        // it rather than under it, which is the whole reason this merge exists.
        let parent = ICloudDrive.mobileDocuments(home: "/Users/test")
        #expect(parent.path == "/Users/test/Library/Mobile Documents")
        #expect(
            VFSPath.local("/Users/test/Library/Mobile Documents/com~apple~CloudDocs").parent == parent
        )
    }

    // MARK: - Which containers qualify

    @Test("a public container with content becomes a library row under the app's name")
    func publicContainerWithContentQualifies() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        try ICloudFixture.makeContainer(
            temp,
            bundleID: "com.apple.Pages",
            name: "Pages",
            public: true,
            contents: ["a.pages"]
        )

        let scan = ICloudDrive.appLibraries(home: temp.root.path, languageCode: nil)
        let library = try #require(scan.libraries.first)
        #expect(scan.libraries.count == 1)
        #expect(library.name == "Pages")
        #expect(library.containerID == "com~apple~Pages")
        #expect(
            library.documents == temp.vfsPath("Library/Mobile Documents/com~apple~Pages/Documents")
        )
        #expect(!scan.isRestricted)
    }

    @Test("a private container is skipped however much it holds")
    func privateContainerIsSkipped() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        try ICloudFixture.makeContainer(
            temp,
            bundleID: "com.apple.notes",
            name: "Notes",
            public: false,
            contents: ["x"]
        )

        #expect(ICloudDrive.appLibraries(home: temp.root.path, languageCode: nil).libraries.isEmpty)
    }

    @Test("an empty public container is skipped")
    func emptyContainerIsSkipped() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        try ICloudFixture.makeContainer(
            temp,
            bundleID: "com.apple.Keynote",
            name: "Keynote",
            public: true,
            contents: []
        )

        #expect(ICloudDrive.appLibraries(home: temp.root.path, languageCode: nil).libraries.isEmpty)
    }

    @Test("a .DS_Store does not count as content")
    func dsStoreIsNotContent() throws {
        // Finder's own bookkeeping appears in containers the user has never touched; counting
        // it would put every empty app folder in iCloud Drive.
        let temp = try TempTree()
        defer { temp.cleanup() }
        try ICloudFixture.makeContainer(
            temp,
            bundleID: "com.apple.TextEdit",
            name: "TextEdit",
            public: true,
            contents: [".DS_Store"]
        )

        #expect(ICloudDrive.appLibraries(home: temp.root.path, languageCode: nil).libraries.isEmpty)
    }

    @Test("any other dotfile does count as content")
    func markerDotfileIsContent() throws {
        // Shortcuts holds only `.WorkflowHiddenFile` and Curve only `.keep-default`, and
        // Finder lists both — so "hidden" is not the test, "is it Finder's own file" is.
        let temp = try TempTree()
        defer { temp.cleanup() }
        try ICloudFixture.makeContainer(
            temp,
            bundleID: "iCloud.is.workflow.my.workflows",
            name: "Shortcuts",
            public: true,
            contents: [".WorkflowHiddenFile"]
        )

        let scan = ICloudDrive.appLibraries(home: temp.root.path, languageCode: nil)
        #expect(scan.libraries.map(\.name) == ["Shortcuts"])
    }

    // MARK: - Naming and order

    @Test("libraries come back sorted by display name, not by container id")
    func sortedByDisplayName() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        try ICloudFixture.makeContainer(
            temp,
            bundleID: "iCloud.is.workflow.my.workflows",
            name: "Shortcuts",
            public: true,
            contents: ["a"]
        )
        try ICloudFixture.makeContainer(
            temp,
            bundleID: "com.apple.Pages",
            name: "Pages",
            public: true,
            contents: ["a"]
        )
        try ICloudFixture.makeContainer(
            temp,
            bundleID: "iCloud.com.linearity.vn",
            name: "Curve",
            public: true,
            contents: ["a"]
        )

        let scan = ICloudDrive.appLibraries(home: temp.root.path, languageCode: nil)
        #expect(scan.libraries.map(\.name) == ["Curve", "Pages", "Shortcuts"])
    }

    @Test("a library takes the localized name for the current language")
    func localizedLibraryName() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        try ICloudFixture.makeContainer(
            temp,
            bundleID: "com.apple.Pages",
            name: "Pages",
            public: true,
            contents: ["a"],
            localizedNames: ["uk": "Сторінки"]
        )

        let scan = ICloudDrive.appLibraries(home: temp.root.path, languageCode: "uk")
        #expect(scan.libraries.map(\.name) == ["Сторінки"])
    }
}
