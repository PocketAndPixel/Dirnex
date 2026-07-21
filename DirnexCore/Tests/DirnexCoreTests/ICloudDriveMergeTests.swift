import Foundation
import Testing

@testable import DirnexCore

/// The merged listing itself, and what it does when Full Disk Access is missing. Split from
/// `ICloudDriveTests` (which covers *which* containers qualify) to stay under SwiftLint's
/// `type_body_length`.
@Suite("ICloudDrive — merged listing")
struct ICloudDriveMergeTests {
    // MARK: - The merged rows

    @Test("a library row wears the app's name over the real Documents path")
    func libraryRowRenames() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        let documents = try ICloudFixture.makeContainer(
            temp,
            bundleID: "com.apple.Pages",
            name: "Pages",
            public: true,
            contents: ["a.pages"]
        )
        let library = try #require(
            ICloudDrive.appLibraries(home: temp.root.path, languageCode: nil).libraries.first
        )
        let stat = try LocalBackend().stat(at: .local(documents))

        let row = ICloudDrive.libraryRow(for: library, stat: stat)
        #expect(row.name == "Pages")
        #expect(row.path == library.documents)
        #expect(row.path.lastComponent == "Documents") // name and path disagree, by design
        #expect(row.isDirectory)
        #expect(row.modificationDate == stat.modificationDate)
        #expect(!row.isHidden)
    }

    @Test("the merge keeps CloudDocs' own files and adds the library rows")
    func mergeUnionsBothSides() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        try temp.makeDir("Library/Mobile Documents/com~apple~CloudDocs")
        try temp.writeFile("Library/Mobile Documents/com~apple~CloudDocs/loose.txt", bytes: 4)
        let documents = try ICloudFixture.makeContainer(
            temp,
            bundleID: "com.apple.Pages",
            name: "Pages",
            public: true,
            contents: ["a.pages"]
        )

        let backend = LocalBackend()
        let loose = try backend.listDirectory(
            at: temp.vfsPath("Library/Mobile Documents/com~apple~CloudDocs")
        )
        let library = try #require(
            ICloudDrive.appLibraries(home: temp.root.path, languageCode: nil).libraries.first
        )
        let stat = try backend.stat(at: .local(documents))
        let row = ICloudDrive.libraryRow(for: library, stat: stat)

        let merged = ICloudDrive.merge(looseFiles: loose, libraryRows: [row])
        #expect(merged.map(\.name).sorted() == ["Pages", "loose.txt"])
    }

    // MARK: - Degrading without Full Disk Access

    @Test("no metadata cache at all is an empty scan, not a restricted one")
    func noMetadataDirectory() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }

        let scan = ICloudDrive.appLibraries(home: temp.root.path, languageCode: nil)
        #expect(scan.libraries.isEmpty)
        #expect(!scan.isRestricted)
    }

    @Test("a container with metadata but no folder on this Mac is simply absent")
    func metadataWithoutFolder() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        try ICloudFixture.writeMetadata(
            temp,
            bundleID: "iCloud.com.example.absent",
            name: "Absent",
            public: true
        )

        let scan = ICloudDrive.appLibraries(home: temp.root.path, languageCode: nil)
        #expect(scan.libraries.isEmpty)
        // Missing is not restricted — the pane must not offer a Full Disk Access grant for it.
        #expect(!scan.isRestricted)
    }

    @Test("a Documents folder that refuses to be read reports the scan as restricted")
    func unreadableDocumentsIsRestricted() throws {
        // Stands in for the TCC refusal: without Full Disk Access every container's
        // `Documents` reads back "Operation not permitted". The pane must be able to tell
        // that apart from "this Mac has no app libraries" so it can offer the grant.
        let temp = try TempTree()
        defer { temp.cleanup() }
        let documents = try ICloudFixture.makeContainer(
            temp,
            bundleID: "com.apple.Pages",
            name: "Pages",
            public: true,
            contents: ["a.pages"]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: documents)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: documents
            )
        }

        let scan = ICloudDrive.appLibraries(home: temp.root.path, languageCode: nil)
        #expect(scan.libraries.isEmpty)
        #expect(scan.isRestricted)
    }

    // MARK: - What "up" means from inside the merge

    @Test("the folders the merged listing stands in front of are recognized as its roots")
    func mergedRoots() {
        let home = "/Users/oleg"
        let containers = ICloudDrive.mobileDocuments(home: home)

        // The two shapes a merged row points at: the loose-files container, and any app
        // library's Documents. Walking up out of either lands back in the merged listing.
        #expect(ICloudDrive.isMergedRoot(containers.appending("com~apple~CloudDocs"), home: home))
        #expect(ICloudDrive.isMergedRoot(
            containers.appending("com~apple~Pages").appending("Documents"), home: home
        ))
    }

    @Test("neither the containers folder itself nor anything deeper is a merged root")
    func nonMergedRoots() {
        let home = "/Users/oleg"
        let containers = ICloudDrive.mobileDocuments(home: home)

        // `~/Library/Mobile Documents` is the machinery *under* the listing, not a row in it.
        #expect(!ICloudDrive.isMergedRoot(containers, home: home))
        // A container's own folder is not a row either — only its `Documents` is.
        #expect(!ICloudDrive.isMergedRoot(containers.appending("com~apple~Pages"), home: home))
        // A subfolder inside a library walks up normally, and so does a "Documents" that
        // merely shares the name from somewhere else entirely.
        #expect(!ICloudDrive.isMergedRoot(
            containers.appending("com~apple~Pages").appending("Documents").appending("Drafts"),
            home: home
        ))
        #expect(!ICloudDrive.isMergedRoot(.local(home + "/Documents"), home: home))
    }

    @Test("a loose folder walks up to the merge, a folder inside an app library does not")
    func walkingUpOutOfTheMerge() {
        let home = "/Users/oleg"
        let containers = ICloudDrive.mobileDocuments(home: home)
        let documents = containers.appending("com~apple~Pages").appending("Documents")

        // "Car" is shown loose in iCloud Drive, so iCloud Drive is what is above it — its real
        // parent, the CloudDocs container, is never a place the user should land in.
        #expect(ICloudDrive.walksUpToMerge(
            from: ICloudDrive.cloudDocs(home: home).appending("Car"), home: home
        ))
        // Both roots keep walking up to the merge, as before.
        #expect(ICloudDrive.walksUpToMerge(from: ICloudDrive.cloudDocs(home: home), home: home))
        #expect(ICloudDrive.walksUpToMerge(from: documents, home: home))
        // But a folder *inside* an app library walks up to that library's own folder: the "Pages"
        // row opens it, so skipping to the merge would skip a level that is visibly there.
        #expect(!ICloudDrive.walksUpToMerge(from: documents.appending("Drafts"), home: home))
    }
}
