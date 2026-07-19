import Foundation
import Testing

@testable import DirnexCore

@Suite("SizeVisualization")
struct SizeVisualizationTests {
    /// Builds a `FileEntry` with sensible defaults; tests override only what they assert on.
    private func entry(
        _ name: String,
        kind: FileEntry.Kind = .file,
        size: Int64 = 0,
        hidden: Bool = false,
        symlinkTargetKind: FileEntry.Kind? = nil
    ) -> FileEntry {
        FileEntry(
            path: .local("/test/\(name)"),
            name: name,
            kind: kind,
            byteSize: size,
            modificationDate: Date(timeIntervalSince1970: 1_000_000),
            creationDate: Date(timeIntervalSince1970: 1_000_000),
            isHidden: hidden,
            permissions: 0o644,
            inode: 0,
            symlinkDestination: symlinkTargetKind != nil ? "/elsewhere" : nil,
            symlinkTargetKind: symlinkTargetKind
        )
    }

    private func model(
        _ entries: [FileEntry],
        sizes: [String: Int64] = [:],
        showHidden: Bool = false,
        filter: String = ""
    ) -> DirectoryModel {
        var model = DirectoryModel(
            listing: DirectoryListing(path: .local("/test"), entries: entries),
            sort: FileSort(key: .name),
            showHidden: showHidden,
            filter: filter
        )
        for (name, bytes) in sizes {
            model.setDirectorySize(.local("/test/\(name)"), bytes: bytes)
        }
        return model
    }

    // MARK: - The two denominators (ncdu's split)

    @Test("the bar is relative to the largest sibling, the share relative to the total")
    func twoDenominators() {
        // 100 / 300 / 100: ncdu's rule makes the biggest row a full bar at half the total.
        let viz = SizeVisualization(model: model([
            entry("a.bin", size: 100),
            entry("b.bin", size: 300),
            entry("c.bin", size: 100)
        ]))

        #expect(viz.maximumBytes == 300)
        #expect(viz.totalBytes == 500)
        // Graph: relative to the largest item.
        #expect(viz.bar(for: entry("b.bin", size: 300))?.fraction == 1.0)
        #expect(viz.bar(for: entry("a.bin", size: 100))?.fraction == 100.0 / 300.0)
        // Percentage: relative to the current directory.
        #expect(viz.bar(for: entry("b.bin", size: 300))?.share == 0.6)
        #expect(viz.bar(for: entry("a.bin", size: 100))?.share == 0.2)
    }

    @Test("the heaviest row always fills the bar, whatever the absolute scale")
    func maximumAlwaysFull() {
        let tiny = SizeVisualization(model: model([entry("a", size: 1), entry("b", size: 2)]))
        let huge = SizeVisualization(model: model([
            entry("a", size: 1_000_000_000_000),
            entry("b", size: 2_000_000_000_000)
        ]))

        #expect(tiny.bar(for: entry("b", size: 2))?.fraction == 1.0)
        #expect(huge.bar(for: entry("b", size: 2_000_000_000_000))?.fraction == 1.0)
    }

    // MARK: - Unknown is not zero

    @Test("an unsized directory has no bar at all, rather than a zero-width one")
    func unsizedDirectoryHasNoBar() {
        let viz = SizeVisualization(model: model([
            entry("file.bin", size: 100),
            entry("folder", kind: .directory)
        ]))

        #expect(viz.bar(for: entry("folder", kind: .directory)) == nil)
        #expect(viz.bar(for: entry("file.bin", size: 100)) != nil)
        // The unsized folder contributes nothing to either denominator while unknown.
        #expect(viz.totalBytes == 100)
        #expect(viz.maximumBytes == 100)
    }

    @Test("a sized-but-empty directory has a real zero bar, unlike an unsized one")
    func emptyDirectoryIsDistinctFromUnsized() {
        let viz = SizeVisualization(model: model(
            [entry("file.bin", size: 100), entry("hollow", kind: .directory)],
            sizes: ["hollow": 0]
        ))

        let bar = viz.bar(for: entry("hollow", kind: .directory))
        #expect(bar != nil)
        #expect(bar?.bytes == 0)
        #expect(bar?.fraction == 0)
        #expect(bar?.share == 0)
    }

    @Test("pending directories are reported in display order, and sized ones drop out")
    func pendingTracksUnsizedDirectories() {
        let viz = SizeVisualization(model: model([
            entry("zeta", kind: .directory),
            entry("alpha", kind: .directory),
            entry("file.bin", size: 5)
        ]))

        #expect(viz.pendingDirectories.map(\.name) == ["alpha", "zeta"])

        let sized = SizeVisualization(model: model(
            [entry("zeta", kind: .directory), entry("alpha", kind: .directory)],
            sizes: ["zeta": 10, "alpha": 20]
        ))
        #expect(sized.pendingDirectories.isEmpty)
    }

    @Test("a symlink to a directory is sized like a directory, not counted as its own inode")
    func symlinkToDirectoryIsPending() {
        let link = entry("link", kind: .symlink, size: 12, symlinkTargetKind: .directory)
        let broken = entry("broken", kind: .symlink, size: 9)
        let viz = SizeVisualization(model: model([link, broken]))

        // Directory-like: awaits a walk rather than contributing 12 link bytes.
        #expect(viz.bar(for: link) == nil)
        #expect(viz.pendingDirectories.map(\.name) == ["link"])
        // A broken symlink is not directory-like, so it counts as itself.
        #expect(viz.bar(for: broken)?.bytes == 9)
    }

    // MARK: - Streaming re-scale

    @Test("bars re-scale when a larger total lands, without incremental bookkeeping")
    func rescalesAsWalksLand() {
        let rows = [entry("small.bin", size: 100), entry("big", kind: .directory)]

        // Before the walk: the file is the only known row, so it fills the bar.
        let before = SizeVisualization(model: model(rows))
        #expect(before.bar(for: rows[0])?.fraction == 1.0)
        #expect(before.bar(for: rows[0])?.share == 1.0)

        // The walk lands a much larger directory; the same file is now a sliver of both.
        let after = SizeVisualization(model: model(rows, sizes: ["big": 900]))
        #expect(after.bar(for: rows[0])?.fraction == 100.0 / 900.0)
        #expect(after.bar(for: rows[0])?.share == 0.1)
        #expect(after.maximumBytes == 900)
    }

    // MARK: - Denominators cover visible rows only

    @Test("hidden rows are excluded from both denominators, and showing them re-scales")
    func hiddenRowsExcluded() {
        let rows = [entry("visible.bin", size: 100), entry(".cache.bin", size: 900, hidden: true)]

        let hidden = SizeVisualization(model: model(rows))
        #expect(hidden.totalBytes == 100)
        #expect(hidden.bar(for: rows[0])?.share == 1.0)

        let shown = SizeVisualization(model: model(rows, showHidden: true))
        #expect(shown.totalBytes == 1000)
        #expect(shown.bar(for: rows[0])?.share == 0.1)
    }

    @Test("a filter re-scales the bars to the rows that survive it")
    func filterRescales() {
        let rows = [entry("keep.bin", size: 100), entry("drop.bin", size: 900)]
        let viz = SizeVisualization(model: model(rows, filter: "keep"))

        #expect(viz.totalBytes == 100)
        #expect(viz.bar(for: rows[0])?.fraction == 1.0)
        #expect(viz.bar(for: rows[1]) == nil) // filtered out entirely
    }

    // MARK: - Excluded rows (.gitignore-aware sizing)

    @Test("an excluded directory gets no bar and is never queued for a walk")
    func excludedDirectoryIsOmitted() {
        // The distinction the user caught on screen: an ignored `build/` holding gigabytes must not
        // render "Zero KB · 0.0 %", which claims it was measured and found empty. It falls back to
        // the unwalked look — no total, no bar — and, crucially, stays out of `pendingDirectories`,
        // or the pane would re-queue a walk for it on every render forever.
        let rows = [entry("build", kind: .directory), entry("src", kind: .directory)]
        let viz = SizeVisualization(model: model(rows)) { $0.lastComponent == "build" }

        #expect(viz.bar(for: rows[0]) == nil)
        #expect(viz.pendingDirectories.map(\.name) == ["src"])
    }

    @Test("an excluded row is left out of both denominators, not counted as zero")
    func excludedRowLeavesNoTrace() {
        // Counting it as zero would be harmless arithmetic and a misleading chart: the row would
        // still occupy the projection, and every other row's share would be computed against a
        // total that pretends to include it.
        let rows = [entry("keep.bin", size: 100), entry("ignored.log", size: 900)]
        let viz = SizeVisualization(model: model(rows)) { $0.lastComponent == "ignored.log" }

        #expect(viz.totalBytes == 100)
        #expect(viz.maximumBytes == 100)
        #expect(viz.bar(for: rows[0])?.share == 1.0)
        #expect(viz.bar(for: rows[1]) == nil)
    }

    @Test("a sized directory that becomes excluded stops showing its total")
    func excludedWinsOverAKnownTotal() {
        // Order matters: the exclusion is tested before the model's computed size, so a total
        // banked under the previous rule cannot leak through the moment the rules change.
        let rows = [entry("build", kind: .directory), entry("src", kind: .directory)]
        let sized = model(rows, sizes: ["build": 1_600_000_000, "src": 2000])
        let viz = SizeVisualization(model: sized) { $0.lastComponent == "build" }

        #expect(viz.bar(for: rows[0]) == nil)
        #expect(viz.totalBytes == 2000)
        #expect(viz.pendingDirectories.isEmpty)
    }

    @Test("excluding nothing is the default and changes no existing behaviour")
    func defaultExcludesNothing() {
        let rows = [entry("a.bin", size: 100), entry("b.bin", size: 300)]
        let plain = SizeVisualization(model: model(rows))
        let explicit = SizeVisualization(model: model(rows)) { _ in false }

        #expect(plain.totalBytes == explicit.totalBytes)
        #expect(plain.maximumBytes == explicit.maximumBytes)
        #expect(plain.bar(for: rows[0])?.share == explicit.bar(for: rows[0])?.share)
    }

    // MARK: - Degenerate and hostile input

    @Test("an empty directory yields no bars and divides by nothing")
    func emptyDirectory() {
        let viz = SizeVisualization(model: model([]))

        #expect(viz.maximumBytes == 0)
        #expect(viz.totalBytes == 0)
        #expect(viz.pendingDirectories.isEmpty)
    }

    @Test("all-zero rows produce zero bars rather than a division by zero")
    func allZeroRows() {
        let rows = [entry("a.bin", size: 0), entry("b.bin", size: 0)]
        let viz = SizeVisualization(model: model(rows))

        #expect(viz.maximumBytes == 0)
        #expect(viz.bar(for: rows[0])?.fraction == 0)
        #expect(viz.bar(for: rows[0])?.share == 0)
    }

    @Test("a negative size from a backend is clamped, not propagated")
    func negativeSizesClamped() {
        // `SFTPListingParser` builds sizes out of text, so nonsense can reach this projection.
        let rows = [entry("bogus.bin", size: -500), entry("real.bin", size: 100)]
        let viz = SizeVisualization(model: model(rows))

        #expect(viz.bar(for: rows[0])?.bytes == 0)
        #expect(viz.totalBytes == 100)
        #expect(viz.bar(for: rows[0])?.fraction == 0)
    }

    @Test("an overflowing total saturates instead of trapping the panel")
    func totalSaturates() {
        let rows = [entry("a.bin", size: .max), entry("b.bin", size: .max)]
        let viz = SizeVisualization(model: model(rows))

        #expect(viz.totalBytes == .max)
        #expect(viz.maximumBytes == .max)
        // Each row is half of a saturated total — nonsense in, but finite and renderable.
        #expect(viz.bar(for: rows[0])?.fraction == 1.0)
    }

    // MARK: - The measured real-world shape

    @Test("reproduces the measured ~ dynamic range: one dominant row leaves the rest slivers")
    func measuredHomeDirectoryDynamicRange() throws {
        // The real numbers probed from this machine's ~: Movies 1 TB dwarfs everything.
        let rows = [
            entry("Movies", kind: .directory),
            entry("Library", kind: .directory),
            entry("Documents", kind: .directory),
            entry("Dev", kind: .directory)
        ]
        let viz = SizeVisualization(model: model(rows, sizes: [
            "Movies": 1_027_840 * 1_048_576,
            "Library": 122_349 * 1_048_576,
            "Documents": 38622 * 1_048_576,
            "Dev": 16981 * 1_048_576
        ]))

        #expect(viz.bar(for: rows[0])?.fraction == 1.0)
        // Everything else lands under an eighth of the bar — which is exactly why ncdu grew its
        // eighth-block graph style. Pass 10 measured what that costs and found drawing at
        // continuous width does *not* rescue it: the real range here is ~10⁶, so 86 of ~'s 93 rows
        // still compute to under half a point at an 80 pt bar. `SizeBar.inkWidth` floors them
        // instead (see `SizeBarTests`); the fractions below stay tiny but must never reach zero.
        for row in rows.dropFirst() {
            let fraction = try #require(viz.bar(for: row)?.fraction)
            #expect(fraction < 0.125)
            #expect(fraction > 0) // ...but never zero: a real 17 GB folder must not read as empty
        }
    }
}
