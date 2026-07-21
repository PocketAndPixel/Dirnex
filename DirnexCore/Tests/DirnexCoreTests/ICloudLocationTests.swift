import Foundation
import Testing

@testable import DirnexCore

/// The path-bar trail for a real folder inside iCloud Drive (PLAN.md §M9) — the same treatment
/// `CloudStorageMountsTests` covers for a Google Drive mount.
@Suite("ICloudLocation")
struct ICloudLocationTests {
    // MARK: - The loose files

    @Test("a folder among the loose files is rooted at the merged listing")
    func looseFolderStartsAtTheRoot() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        let path = temp.vfsPath("Library/Mobile Documents/com~apple~CloudDocs/Car/Photos")

        let trail = try #require(ICloudLocation.trail(for: path, home: temp.root.path))
        #expect(trail.map(\.title) == ["Car", "Photos"])
        #expect(trail.last?.directory == path)
        #expect(
            trail.first?.directory
                == temp.vfsPath("Library/Mobile Documents/com~apple~CloudDocs/Car")
        )
    }

    @Test("the CloudDocs container itself is the merged root and adds no steps")
    func cloudDocsIsTheRoot() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        let trail = ICloudLocation.trail(
            for: temp.vfsPath("Library/Mobile Documents/com~apple~CloudDocs"),
            home: temp.root.path
        )
        #expect(trail == [])
    }

    // MARK: - App libraries

    @Test("an app library appears under the app's name, with its container hidden")
    func libraryWearsTheAppName() throws {
        // The whole point: the real path is `…/com~apple~Pages/Documents/Drafts`, three
        // components of which the user never asked to see.
        let temp = try TempTree()
        defer { temp.cleanup() }
        try ICloudFixture.makeContainer(
            temp,
            bundleID: "com.apple.Pages",
            name: "Pages",
            public: true,
            contents: ["a.pages"]
        )
        let path = temp.vfsPath("Library/Mobile Documents/com~apple~Pages/Documents/Drafts")

        let trail = try #require(
            ICloudLocation.trail(for: path, home: temp.root.path, languageCode: nil)
        )
        #expect(trail.map(\.title) == ["Pages", "Drafts"])
        #expect(
            trail.first?.directory
                == temp.vfsPath("Library/Mobile Documents/com~apple~Pages/Documents")
        )
    }

    @Test("the library's own Documents folder is a single named step")
    func libraryRootIsOneStep() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        try ICloudFixture.makeContainer(
            temp,
            bundleID: "com.apple.Pages",
            name: "Pages",
            public: true,
            contents: ["a.pages"]
        )

        let trail = ICloudLocation.trail(
            for: temp.vfsPath("Library/Mobile Documents/com~apple~Pages/Documents"),
            home: temp.root.path,
            languageCode: nil
        )
        #expect(trail?.map(\.title) == ["Pages"])
    }

    @Test("a library the metadata cache has forgotten falls back to its bundle id")
    func unknownContainerFallsBackToItsIdentifier() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        try temp.makeDir("Library/Mobile Documents/com~acme~Sketch/Documents")

        let trail = ICloudLocation.trail(
            for: temp.vfsPath("Library/Mobile Documents/com~acme~Sketch/Documents"),
            home: temp.root.path,
            languageCode: nil
        )
        #expect(trail?.map(\.title) == ["com.acme.Sketch"])
    }

    @Test("an unreadable metadata cache falls back to what the OS calls the folder")
    func deniedCacheAsksTheSystemForTheName() throws {
        // The live state of a build without Full Disk Access: `Application Support/CloudDocs` is
        // refused while the container itself still lists, so the crumb would read
        // `com.apple.Pages` with nothing but the plist to go on.
        let temp = try TempTree()
        defer { temp.cleanup() }
        let documents = temp.vfsPath("Library/Mobile Documents/com~apple~Pages/Documents")
        try temp.makeDir("Library/Mobile Documents/com~apple~Pages/Documents")

        let trail = ICloudLocation.trail(
            for: documents,
            home: temp.root.path,
            languageCode: nil,
            fallbackName: { $0 == documents ? "Pages" : nil }
        )
        #expect(trail?.map(\.title) == ["Pages"])
    }

    @Test("the cached name wins over the system's, so a crumb matches its row in the listing")
    func cachedNameIsPreferred() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        try ICloudFixture.makeContainer(
            temp,
            bundleID: "com.apple.Pages",
            name: "Pages",
            public: true,
            contents: ["a.pages"]
        )

        let trail = ICloudLocation.trail(
            for: temp.vfsPath("Library/Mobile Documents/com~apple~Pages/Documents"),
            home: temp.root.path,
            languageCode: nil,
            fallbackName: { _ in "Documents" }
        )
        #expect(trail?.map(\.title) == ["Pages"])
    }

    @Test("a localized container name wins where the language has one")
    func localizedNameIsUsed() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        try ICloudFixture.makeContainer(
            temp,
            bundleID: "com.apple.Pages",
            name: "Pages",
            public: true,
            contents: ["a.pages"],
            localizedNames: ["de": "Seiten"]
        )

        let trail = ICloudLocation.trail(
            for: temp.vfsPath("Library/Mobile Documents/com~apple~Pages/Documents"),
            home: temp.root.path,
            languageCode: "de"
        )
        #expect(trail?.map(\.title) == ["Seiten"])
    }

    // MARK: - Outside iCloud Drive

    @Test("the container machinery itself is not a place inside iCloud Drive")
    func bareContainerIsNotInside() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        // `com~apple~Pages` holds one child the user never asked to see, and Mobile Documents
        // holds nothing but containers — neither has a crumb in the merged view.
        #expect(
            ICloudLocation.trail(
                for: temp.vfsPath("Library/Mobile Documents/com~apple~Pages"),
                home: temp.root.path
            ) == nil
        )
        #expect(
            ICloudLocation.trail(
                for: temp.vfsPath("Library/Mobile Documents"),
                home: temp.root.path
            ) == nil
        )
    }

    @Test("an ordinary folder gets no trail and pays no disk access for the answer")
    func ordinaryFolderIsNotInside() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        #expect(ICloudLocation.trail(for: .local("/Users/test/Dev"), home: temp.root.path) == nil)
    }

    @Test("a virtual location has no real trail of its own")
    func virtualPathIsNotInside() {
        #expect(ICloudLocation.trail(for: ICloudLocation.mergedPath) == nil)
        #expect(ICloudLocation.trail(for: VFSPath(backend: .trash, path: "/Trash")) == nil)
    }

    // MARK: - The row a root-crumb click lands on

    @Test("clicking the root crumb lands on the row the current folder came from")
    func mergeRowIsTheFirstStep() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        let loose = temp.vfsPath("Library/Mobile Documents/com~apple~CloudDocs/Car/Photos")
        #expect(
            ICloudLocation.mergeRow(towards: loose, home: temp.root.path)
                == temp.vfsPath("Library/Mobile Documents/com~apple~CloudDocs/Car")
        )

        let library = temp.vfsPath("Library/Mobile Documents/com~apple~Pages/Documents/Drafts")
        #expect(
            ICloudLocation.mergeRow(towards: library, home: temp.root.path)
                == temp.vfsPath("Library/Mobile Documents/com~apple~Pages/Documents")
        )
    }

    @Test("the merged root and anywhere outside select no row")
    func mergeRowIsNilWithoutOne() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        #expect(
            ICloudLocation.mergeRow(
                towards: temp.vfsPath("Library/Mobile Documents/com~apple~CloudDocs"),
                home: temp.root.path
            ) == nil
        )
        #expect(ICloudLocation.mergeRow(towards: .local("/Users/test"), home: temp.root.path) == nil)
    }

    // MARK: - The merged listing's own identity

    @Test("the merged path is the virtual location the listing installs as")
    func mergedPathIsTheSyntheticOne() {
        #expect(ICloudLocation.mergedPath.backend == .icloud)
        #expect(ICloudLocation.mergedPath.path == "/iCloud Drive")
        #expect(ICloudLocation.mergedName == "iCloud Drive")
    }
}
