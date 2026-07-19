import Foundation
import Testing

@testable import DirnexCore

/// The panel's computed-directory-size behaviour: Space-on-dir (§M1) and the bulk seed that
/// size-visualization mode fills a panel from (§M6). Split out of `PanelTests`, which had grown
/// past its body-length budget, along the same seam the suite's own `MARK` already drew.
@Suite("Panel — computed sizes")
struct PanelSizeTests {
    private func directory(_ name: String) -> FileEntry {
        entry(name, kind: .directory, size: 0)
    }

    private func entry(_ name: String, kind: FileEntry.Kind = .file, size: Int64 = 0) -> FileEntry {
        FileEntry(
            path: .local("/dir/\(name)"),
            name: name,
            kind: kind,
            byteSize: size,
            modificationDate: Date(timeIntervalSince1970: 0),
            creationDate: Date(timeIntervalSince1970: 0),
            isHidden: false,
            permissions: 0o644,
            inode: 0
        )
    }

    /// Sized ascending with directories ungrouped, so a landing total visibly reorders rows.
    private func panel(_ entries: [FileEntry]) -> Panel {
        Panel(model: DirectoryModel(
            listing: DirectoryListing(path: .local("/dir"), entries: entries),
            sort: FileSort(key: .size, ascending: true, directoriesFirst: false)
        ))
    }

    @Test("recording a directory size preserves the cursor by identity across the re-sort")
    func directorySizePreservesCursor() throws {
        var subject = panel([directory("folder"), entry("file.bin", size: 500)])
        // Unsized directory (0) sorts before the 500-byte file.
        #expect(subject.model.visibleEntries.map(\.name) == ["folder", "file.bin"])
        subject.moveCursor(to: 1)
        #expect(subject.currentEntry?.name == "file.bin")

        let folder = try #require(subject.model.visibleEntries.first { $0.name == "folder" })
        subject.setDirectorySize(folder.id, bytes: 1000) // folder now heaviest → moves last
        #expect(subject.model.visibleEntries.map(\.name) == ["file.bin", "folder"])
        // The cursor followed file.bin by identity, not by its old row index.
        #expect(subject.currentEntry?.name == "file.bin")
        #expect(subject.cursor == 0)
    }

    @Test("a bulk size seed reorders rows but keeps the cursor on its entry by identity")
    func bulkSizesPreserveCursor() throws {
        var subject = panel([directory("alpha"), directory("beta"), entry("file.bin", size: 500)])
        subject.moveCursor(to: 2)
        #expect(subject.currentEntry?.name == "file.bin")

        let alpha = try #require(subject.model.visibleEntries.first { $0.name == "alpha" })
        let beta = try #require(subject.model.visibleEntries.first { $0.name == "beta" })
        // Seeding from the cache lands both totals at once; both now outweigh the file.
        subject.setDirectorySizes([alpha.id: 9000, beta.id: 1000])

        #expect(subject.model.visibleEntries.map(\.name) == ["file.bin", "beta", "alpha"])
        #expect(subject.currentEntry?.name == "file.bin")
        #expect(subject.cursor == 0)
    }

    @Test("clearing computed sizes drops the totals, re-sorts, and keeps the cursor by identity")
    func clearSizesPreservesCursor() throws {
        // The `.gitignore`-aware toggle (§M6): every total was counted under the other rule, so they
        // are not stale but wrong, and dropping them re-sorts a size-sorted listing exactly as
        // landing them did. The cursor must survive that, in both directions.
        var subject = panel([directory("folder"), entry("file.bin", size: 500)])
        let folder = try #require(subject.model.visibleEntries.first { $0.name == "folder" })
        subject.setDirectorySize(folder.id, bytes: 1000)
        #expect(subject.model.visibleEntries.map(\.name) == ["file.bin", "folder"])
        subject.moveCursor(to: 0)
        #expect(subject.currentEntry?.name == "file.bin")

        subject.clearDirectorySizes()

        #expect(subject.model.computedSize(of: folder) == nil)
        #expect(subject.model.visibleEntries.map(\.name) == ["folder", "file.bin"])
        #expect(subject.currentEntry?.name == "file.bin")
        #expect(subject.cursor == 1)
    }

    @Test("clearing a panel that holds no totals changes nothing")
    func clearSizesWithNoneIsNoOp() {
        var subject = panel([directory("folder"), entry("file.bin", size: 500)])
        let before = subject.model.visibleEntries.map(\.name)

        subject.clearDirectorySizes()

        #expect(subject.model.visibleEntries.map(\.name) == before)
    }
}
