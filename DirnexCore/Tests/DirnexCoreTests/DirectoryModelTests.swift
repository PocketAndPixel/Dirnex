import Foundation
import Testing

@testable import DirnexCore

@Suite("DirectoryModel")
struct DirectoryModelTests {
    /// Builds a `FileEntry` with sensible defaults; tests override only what they assert on.
    private func entry(
        _ name: String,
        kind: FileEntry.Kind = .file,
        size: Int64 = 0,
        modified: Date = Date(timeIntervalSince1970: 1_000_000),
        hidden: Bool = false
    ) -> FileEntry {
        FileEntry(
            path: .local("/test/\(name)"),
            name: name,
            kind: kind,
            byteSize: size,
            modificationDate: modified,
            creationDate: modified,
            isHidden: hidden,
            permissions: 0o644,
            inode: 0
        )
    }

    private func model(
        _ entries: [FileEntry],
        sort: FileSort = .default,
        showHidden: Bool = false,
        filter: String = ""
    ) -> DirectoryModel {
        DirectoryModel(
            listing: DirectoryListing(path: .local("/test"), entries: entries),
            sort: sort,
            showHidden: showHidden,
            filter: filter
        )
    }

    // MARK: - Sorting

    @Test("name sort is natural (numeric-aware), not lexicographic")
    func naturalNameSort() {
        let subject = model(
            [entry("item10.txt"), entry("item2.txt"), entry("item1.txt")],
            sort: FileSort(key: .name, ascending: true, directoriesFirst: false)
        )
        #expect(subject.visibleEntries.map(\.name) == ["item1.txt", "item2.txt", "item10.txt"])
    }

    @Test("descending name sort reverses order")
    func descendingNameSort() {
        let subject = model(
            [entry("a.txt"), entry("b.txt"), entry("c.txt")],
            sort: FileSort(key: .name, ascending: false, directoriesFirst: false)
        )
        #expect(subject.visibleEntries.map(\.name) == ["c.txt", "b.txt", "a.txt"])
    }

    @Test("directoriesFirst groups directories ahead of files regardless of direction")
    func directoriesFirstGrouping() {
        let entries = [
            entry("aaa.txt"),
            entry("zzz", kind: .directory),
            entry("mmm", kind: .directory)
        ]

        let asc = model(entries, sort: FileSort(key: .name, ascending: true, directoriesFirst: true))
        #expect(asc.visibleEntries.map(\.name) == ["mmm", "zzz", "aaa.txt"])

        // Even descending, directories stay on top; only the key order within a group flips.
        let desc = model(
            entries,
            sort: FileSort(key: .name, ascending: false, directoriesFirst: true)
        )
        #expect(desc.visibleEntries.map(\.name) == ["zzz", "mmm", "aaa.txt"])
    }

    @Test("size sort orders by byte size")
    func sizeSort() {
        let subject = model(
            [entry("big", size: 1000), entry("small", size: 10), entry("mid", size: 100)],
            sort: FileSort(key: .size, ascending: true, directoriesFirst: false)
        )
        #expect(subject.visibleEntries.map(\.name) == ["small", "mid", "big"])
    }

    @Test("modified sort orders by date")
    func dateSort() {
        let subject = model(
            [
                entry("new", modified: Date(timeIntervalSince1970: 3000)),
                entry("old", modified: Date(timeIntervalSince1970: 1000)),
                entry("mid", modified: Date(timeIntervalSince1970: 2000))
            ],
            sort: FileSort(key: .modified, ascending: true, directoriesFirst: false)
        )
        #expect(subject.visibleEntries.map(\.name) == ["old", "mid", "new"])
    }

    @Test("extension sort groups by extension, then name")
    func extensionSort() {
        let subject = model(
            [entry("b.zip"), entry("c.txt"), entry("a.txt")],
            sort: FileSort(key: .fileExtension, ascending: true, directoriesFirst: false)
        )
        #expect(subject.visibleEntries.map(\.name) == ["a.txt", "c.txt", "b.zip"])
    }

    // MARK: - Computed directory sizes (Space-on-dir)

    @Test("computedSize is nil until recorded, then returns the total")
    func computedSizeRecorded() {
        var subject = model([entry("folder", kind: .directory)])
        let folder = subject.visibleEntries[0]
        #expect(subject.computedSize(of: folder) == nil)

        subject.setDirectorySize(folder.id, bytes: 4096)
        #expect(subject.computedSize(of: folder) == 4096)
    }

    @Test("effectiveByteSize is zero for an unsized directory and the file size for a file")
    func effectiveByteSizes() {
        var subject = model([entry("folder", kind: .directory), entry("f.bin", size: 500)])
        let folder = subject.visibleEntries.first { $0.name == "folder" }!
        let file = subject.visibleEntries.first { $0.name == "f.bin" }!
        #expect(subject.effectiveByteSize(of: folder) == 0)
        #expect(subject.effectiveByteSize(of: file) == 500)

        subject.setDirectorySize(folder.id, bytes: 8192)
        #expect(subject.effectiveByteSize(of: folder) == 8192)
    }

    @Test("size sort reflects a computed directory total")
    func sizeSortReflectsComputed() {
        var subject = model(
            [entry("big", kind: .directory), entry("small.bin", size: 5)],
            sort: FileSort(key: .size, ascending: true, directoriesFirst: false)
        )
        // The unsized directory counts as zero, so it sorts before the 5-byte file.
        #expect(subject.visibleEntries.map(\.name) == ["big", "small.bin"])

        let big = subject.visibleEntries.first { $0.name == "big" }!
        subject.setDirectorySize(big.id, bytes: 1000)
        // Now the directory outweighs the file and moves after it.
        #expect(subject.visibleEntries.map(\.name) == ["small.bin", "big"])
    }

    @Test("computed sizes are pruned when their entry disappears on refresh")
    func computedSizePruned() {
        var subject = model([entry("keep", kind: .directory), entry("drop", kind: .directory)])
        let keep = subject.visibleEntries.first { $0.name == "keep" }!
        let drop = subject.visibleEntries.first { $0.name == "drop" }!
        subject.setDirectorySize(keep.id, bytes: 1)
        subject.setDirectorySize(drop.id, bytes: 2)

        subject.updateListing(DirectoryListing(path: .local("/test"), entries: [keep]))
        #expect(subject.computedSize(of: keep) == 1)
        #expect(subject.directorySizes[drop.id] == nil)
    }

    @Test("setDirectorySizes records a whole burst at once — the cache-seeding path")
    func bulkSizesRecorded() {
        var subject = model([
            entry("alpha", kind: .directory),
            entry("beta", kind: .directory),
            entry("gamma", kind: .directory)
        ])
        let alpha = subject.visibleEntries[0]
        let beta = subject.visibleEntries[1]

        subject.setDirectorySizes([alpha.id: 100, beta.id: 200])

        #expect(subject.computedSize(of: alpha) == 100)
        #expect(subject.computedSize(of: beta) == 200)
        #expect(subject.computedSize(of: subject.visibleEntries[2]) == nil)
    }

    @Test("setDirectorySizes merges rather than replacing, with the new value winning")
    func bulkSizesMerge() {
        var subject = model([entry("alpha", kind: .directory), entry("beta", kind: .directory)])
        let alpha = subject.visibleEntries[0]
        let beta = subject.visibleEntries[1]
        subject.setDirectorySize(alpha.id, bytes: 1)

        subject.setDirectorySizes([beta.id: 2])
        #expect(subject.computedSize(of: alpha) == 1) // untouched, not discarded
        #expect(subject.computedSize(of: beta) == 2)

        subject.setDirectorySizes([alpha.id: 9])
        #expect(subject.computedSize(of: alpha) == 9) // a re-walk supersedes the cached total
    }

    @Test("setDirectorySizes re-sorts once, and an empty burst changes nothing")
    func bulkSizesResortAndEmpty() {
        var subject = model(
            [entry("big", kind: .directory), entry("small.bin", size: 5)],
            sort: FileSort(key: .size, ascending: true, directoriesFirst: false)
        )
        let big = subject.visibleEntries.first { $0.name == "big" }!

        subject.setDirectorySizes([:])
        #expect(subject.visibleEntries.map(\.name) == ["big", "small.bin"]) // no-op

        subject.setDirectorySizes([big.id: 1000])
        #expect(subject.visibleEntries.map(\.name) == ["small.bin", "big"]) // ordering applied
    }

    // MARK: - Hidden

    @Test("hidden entries are excluded unless showHidden is on")
    func hiddenToggle() {
        let entries = [entry("visible.txt"), entry(".secret", hidden: true)]

        let hiddenOff = model(entries, showHidden: false)
        #expect(hiddenOff.visibleEntries.map(\.name) == ["visible.txt"])

        let hiddenOn = model(
            entries,
            sort: FileSort(key: .name, ascending: true, directoriesFirst: false),
            showHidden: true
        )
        #expect(hiddenOn.visibleEntries.map(\.name) == [".secret", "visible.txt"])
    }

    @Test("toggling showHidden recomputes the visible list")
    func toggleRecomputes() {
        var subject = model([entry("visible.txt"), entry(".secret", hidden: true)])
        #expect(subject.count == 1)
        subject.showHidden = true
        #expect(subject.count == 2)
    }

    // MARK: - Filter

    @Test("type-to-filter matches case-insensitive substrings")
    func filterMatchesSubstring() {
        let subject = model(
            [entry("Report.pdf"), entry("image.png"), entry("report-2.pdf")],
            sort: FileSort(key: .name, ascending: true, directoriesFirst: false),
            filter: "report"
        )
        #expect(subject.visibleEntries.map(\.name) == ["report-2.pdf", "Report.pdf"])
    }

    @Test("empty filter matches everything")
    func emptyFilterMatchesAll() {
        let subject = model([entry("a.txt"), entry("b.txt")], filter: "")
        #expect(subject.count == 2)
    }

    // MARK: - Identity

    @Test("index(ofID:) locates an entry by its stable path identity")
    func indexByIdentity() {
        let target = entry("mid", size: 100)
        let subject = model(
            [entry("small", size: 10), target, entry("big", size: 1000)],
            sort: FileSort(key: .size, ascending: true, directoriesFirst: false)
        )
        #expect(subject.index(ofID: target.id) == 1)
        #expect(subject.index(ofID: .local("/test/absent")) == nil)
    }
}

// MARK: - Filter (sort/filter split — PLAN.md §M7 perf pass)

/// The perf pass split the projection into a cached sort stage and a cheap re-filter
/// stage, and added an ASCII byte fast path with a Unicode fallback. These pin that the
/// split preserves the observable behaviour across every input that drives a re-filter.
private extension DirectoryModelTests {
    @Test("mutating the filter re-narrows without disturbing sort order")
    func filterMutationPreservesOrder() {
        var subject = model(
            [entry("alpha.txt"), entry("beta.txt"), entry("alto.txt"), entry("gamma.txt")],
            sort: FileSort(key: .name, ascending: true, directoriesFirst: false)
        )
        subject.filter = "al"
        #expect(subject.visibleEntries.map(\.name) == ["alpha.txt", "alto.txt"])
        subject.filter = "alt"
        #expect(subject.visibleEntries.map(\.name) == ["alto.txt"])
        subject.filter = ""
        #expect(
            subject.visibleEntries.map(\.name) == ["alpha.txt", "alto.txt", "beta.txt", "gamma.txt"]
        )
    }

    @Test("an ASCII needle matches names that also contain non-ASCII bytes")
    func filterAsciiNeedleAcrossUnicodeName() {
        // The byte fast path must find "report" inside a name whose other characters are
        // multi-byte UTF-8 — an ASCII byte never occurs inside a UTF-8 continuation byte.
        let subject = model(
            [entry("café-report.txt"), entry("café-photo.txt"), entry("日本語.txt")],
            sort: FileSort(key: .name, ascending: true, directoriesFirst: false),
            filter: "report"
        )
        #expect(subject.visibleEntries.map(\.name) == ["café-report.txt"])
    }

    @Test("an ASCII needle never matches inside a purely non-ASCII name")
    func filterAsciiNeedleRejectsUnicodeOnlyName() {
        let subject = model(
            [entry("日本語.txt"), entry("data.txt")],
            filter: "a"
        )
        #expect(subject.visibleEntries.map(\.name) == ["data.txt"])
    }

    @Test("a non-ASCII needle matches case-insensitively via the Unicode fallback")
    func filterUnicodeNeedle() {
        var subject = model(
            [entry("Café.txt"), entry("Cafe.txt"), entry("tea.txt")],
            sort: FileSort(key: .name, ascending: true, directoriesFirst: false)
        )
        subject.filter = "café"
        #expect(subject.visibleEntries.map(\.name) == ["Café.txt"])
        subject.filter = "CAFÉ"
        #expect(subject.visibleEntries.map(\.name) == ["Café.txt"])
    }

    @Test("changing sort while a filter is active keeps the filter applied")
    func filterSurvivesResort() {
        var subject = model(
            [
                entry("report-b.txt", size: 30),
                entry("image.txt", size: 20),
                entry("report-a.txt", size: 10)
            ],
            sort: FileSort(key: .name, ascending: true, directoriesFirst: false),
            filter: "report"
        )
        #expect(subject.visibleEntries.map(\.name) == ["report-a.txt", "report-b.txt"])
        subject.sort = FileSort(key: .size, ascending: false, directoriesFirst: false)
        #expect(subject.visibleEntries.map(\.name) == ["report-b.txt", "report-a.txt"])
    }

    @Test("toggling hidden files re-applies the active filter")
    func filterSurvivesHiddenToggle() {
        var subject = model(
            [entry(".report-hidden.txt", hidden: true), entry("report.txt"), entry("image.txt")],
            sort: FileSort(key: .name, ascending: true, directoriesFirst: false),
            filter: "report"
        )
        #expect(subject.visibleEntries.map(\.name) == ["report.txt"])
        subject.showHidden = true
        #expect(subject.visibleEntries.map(\.name) == [".report-hidden.txt", "report.txt"])
    }
}
