import Foundation
import Testing

@testable import DirnexCore

/// The two facts a rename rests on: whether a row's displayed name is its file's, and what the row
/// becomes once it has been renamed.
///
/// `nameMatchesPath` exists because the merged iCloud listing draws an **app's** name over its
/// `Documents` folder — `ICloudDrive.libraryRow(for:stat:)` calls that out as the one place in the
/// codebase where a row's name and path disagree — and the app's rename gate is the caller that has
/// to know. It replaced a gate keyed on the whole listing being synthetic, which refused every
/// ordinary row standing beside those (`RenameReachTests`).
@Suite("FileEntry — the name a row shows")
struct FileEntryNameTests {
    private func entry(
        named name: String,
        at path: VFSPath,
        kind: FileEntry.Kind = .file
    ) -> FileEntry {
        FileEntry(
            path: path,
            name: name,
            kind: kind,
            byteSize: 4096,
            modificationDate: Date(timeIntervalSince1970: 1_000_000),
            creationDate: Date(timeIntervalSince1970: 900_000),
            isHidden: false,
            permissions: 0o755,
            inode: 42
        )
    }

    @Test("an ordinary row is named after its own path")
    func ordinaryRowMatches() {
        #expect(entry(named: "notes.txt", at: .local("/docs/notes.txt")).nameMatchesPath)
    }

    /// The real row, built by the real producer, rather than a hand-made pair that merely differs:
    /// what is being pinned is that `libraryRow` still makes them disagree, since a change there is
    /// what would silently re-open the gate.
    @Test("an iCloud app-library row is not")
    func libraryRowDoesNotMatch() {
        let library = ICloudAppLibrary(
            containerID: "com~apple~Pages",
            bundleID: "com.apple.Pages",
            name: "Pages",
            documents: .local("/Users/t/Library/Mobile Documents/com~apple~Pages/Documents")
        )
        let row = ICloudDrive.libraryRow(
            for: library,
            stat: entry(named: "Documents", at: library.documents, kind: .directory)
        )
        #expect(row.name == "Pages")
        #expect(row.path.lastComponent == "Documents")
        #expect(!row.nameMatchesPath)
    }

    /// A rename changes the name and nothing else — which is what makes substituting a row cheaper
    /// than re-`stat`ing it, and correct on a backend where a `stat` is a network round trip.
    @Test("a renamed row keeps everything but its name")
    func renamedKeepsTheRest() {
        let original = entry(named: "old.txt", at: .local("/docs/old.txt"))
        let renamed = original.renamed(to: "new.txt")

        #expect(renamed.path == .local("/docs/new.txt"))
        #expect(renamed.name == "new.txt")
        #expect(renamed.nameMatchesPath)
        #expect(renamed.byteSize == original.byteSize)
        #expect(renamed.modificationDate == original.modificationDate)
        #expect(renamed.creationDate == original.creationDate)
        #expect(renamed.inode == original.inode)
        #expect(renamed.kind == original.kind)
    }

    /// A row on another backend keeps it — the caller is a search snapshot, whose hits can be
    /// anywhere the search reached.
    @Test("renaming preserves the row's backend")
    func renamedStaysOnItsBackend() {
        let location = S3Location(host: "h", bucket: "b", region: "r", accessKeyID: "AK")
        let path = VFSPath(backend: .s3(location), path: "/dir/old.txt")
        let renamed = entry(named: "old.txt", at: path).renamed(to: "new.txt")

        #expect(renamed.path == VFSPath(backend: .s3(location), path: "/dir/new.txt"))
    }
}
