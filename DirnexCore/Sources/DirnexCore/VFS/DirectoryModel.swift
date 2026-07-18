import Foundation

/// A raw, unsorted directory snapshot straight from a backend.
public struct DirectoryListing: Sendable, Hashable {
    public let path: VFSPath
    public let entries: [FileEntry]

    public init(path: VFSPath, entries: [FileEntry]) {
        self.path = path
        self.entries = entries
    }
}

/// How a panel orders its rows. Persisted per tab (PLAN.md §M1 "sort/column state
/// per tab"), so the `Key` raw values are part of the on-disk format.
public struct FileSort: Sendable, Hashable, Codable {
    public enum Key: String, Sendable, Hashable, CaseIterable, Codable {
        case name
        case size
        case modified
        case fileExtension
    }

    public var key: Key
    public var ascending: Bool
    /// Keep directories grouped ahead of files regardless of key/direction — the
    /// Total Commander default, and what most macOS users expect.
    public var directoriesFirst: Bool

    public init(key: Key = .name, ascending: Bool = true, directoriesFirst: Bool = true) {
        self.key = key
        self.ascending = ascending
        self.directoriesFirst = directoriesFirst
    }

    public static let `default` = FileSort()
}

/// The sorted, filtered view of a directory that a panel actually renders.
///
/// Purely a projection of `listing` under `sort` + `showHidden` + `filter`; it holds
/// no disk state. The materialized `visibleEntries` is recomputed whenever an input
/// changes, so the panel can treat it as a stable array to index into. Cursor
/// preservation across refreshes is done by identity via `index(ofID:)`.
///
/// The projection is split into two stages so a **type-to-filter keystroke never
/// re-sorts** (PLAN.md §M7 perf pass): `sortedEntries` applies `showHidden` + `sort`
/// (the expensive `localizedStandardCompare` pass), and `visibleEntries` applies the
/// text `filter` on top of it — an order-preserving subset, so changing `filter`
/// only re-runs the cheap filter. Measured on a 100k listing, that drops a keystroke
/// from ~51 ms (filter + full re-sort) to ~1 ms.
public struct DirectoryModel: Sendable {
    public private(set) var listing: DirectoryListing
    public var sort: FileSort { didSet { resort() } }
    public var showHidden: Bool { didSet { resort() } }
    /// Type-to-filter text; case-insensitive substring match on the name.
    public var filter: String { didSet { refilter() } }

    /// `listing.entries` under `showHidden` + `sort`, but *before* the text filter — the
    /// stable base a keystroke filters without re-sorting. Rebuilt only when the listing,
    /// sort, hidden-toggle, or computed sizes change.
    private var sortedEntries: [FileEntry]

    /// Lazily-built lowercased UTF-8 of the `sortedEntries` names, used by the ASCII filter
    /// fast path. Invalidated (to `nil`) on every resort and rebuilt on the first non-empty
    /// ASCII keystroke after it. Byte-substring matching is ~27× faster than Swift's
    /// grapheme-aware `String.contains`, which is what keeps a keystroke under the 16 ms
    /// budget; see `refilter`.
    ///
    /// All names live in one contiguous `bytes` buffer with `bounds[i]..<bounds[i + 1]`
    /// delimiting entry `i` — a single allocation instead of 100k tiny ones, so the build is
    /// both faster and far lighter on memory than a `[[UInt8]]` (which matters for the
    /// huge-directory memory ceiling, PLAN.md §M7).
    private struct LoweredNames: Sendable {
        var bytes: [UInt8]
        var bounds: [Int]
    }

    private var loweredNames: LoweredNames?

    /// Recursively-computed directory totals recorded via Space-on-dir, keyed by entry
    /// identity. Kept out of `FileEntry` (a pure stat snapshot) and layered on top of it
    /// for display, selection totals, and size-sorting. Pruned to present entries on
    /// refresh, so it never grows unbounded or resurrects a deleted folder's number.
    public private(set) var directorySizes: [VFSPath: Int64]

    public private(set) var visibleEntries: [FileEntry]

    public init(
        listing: DirectoryListing,
        sort: FileSort = .default,
        showHidden: Bool = false,
        filter: String = ""
    ) {
        self.listing = listing
        self.sort = sort
        self.showHidden = showHidden
        self.filter = filter
        directorySizes = [:]
        sortedEntries = []
        loweredNames = nil
        visibleEntries = []
        resort()
    }

    /// Replace the underlying snapshot (e.g. after a live FSEvents refresh) while
    /// keeping the current sort/filter/hidden settings. Computed sizes for entries that
    /// vanished from the listing are dropped.
    public mutating func updateListing(_ listing: DirectoryListing) {
        self.listing = listing
        if !directorySizes.isEmpty {
            let present = Set(listing.entries.map(\.id))
            directorySizes = directorySizes.filter { present.contains($0.key) }
        }
        resort()
    }

    public var count: Int { visibleEntries.count }

    public var isEmpty: Bool { visibleEntries.isEmpty }

    public subscript(index: Int) -> FileEntry { visibleEntries[index] }

    /// Row index of a specific entry, or `nil` if it is not currently visible.
    public func index(ofID id: VFSPath) -> Int? {
        visibleEntries.firstIndex { $0.id == id }
    }

    // MARK: - Computed directory sizes (Space-on-dir)

    /// Record a recursively-computed size for the directory identified by `id`
    /// (Space-on-dir). Re-materializes the visible list because size-sorting may move
    /// the row.
    public mutating func setDirectorySize(_ id: VFSPath, bytes: Int64) {
        directorySizes[id] = bytes
        resort()
    }

    /// Record many recursively-computed totals at once, re-materializing the visible list **once**
    /// instead of once per entry. Existing totals for paths not mentioned are kept; a repeated path
    /// takes the new value.
    ///
    /// This exists for one measured reason: seeding a panel from `DirectorySizeCache` arrives as a
    /// burst of N totals, and `setDirectorySize` re-sorts the whole listing on every call. Measured
    /// on this machine, seeding one-by-one costs 5.7 ms at 68 rows but **284 ms at 1,000 and 2.5 s
    /// at 3,000** — on the main actor, and quadratic. That would make the cache *slower* than no
    /// cache at the one job it has, which is making bars appear the instant a directory opens.
    public mutating func setDirectorySizes(_ sizes: [VFSPath: Int64]) {
        guard !sizes.isEmpty else { return }
        directorySizes.merge(sizes) { _, new in new }
        resort()
    }

    /// The computed recursive size recorded for `entry`, or `nil` if none — only
    /// directories ever carry one. The size column shows a dash until this is present.
    public func computedSize(of entry: FileEntry) -> Int64? {
        directorySizes[entry.id]
    }

    /// The byte weight to attribute to `entry` in selection totals and size-sorting: a
    /// computed directory total when present, a file's own size, otherwise zero — an
    /// unsized directory's inode size is noise, not content.
    public func effectiveByteSize(of entry: FileEntry) -> Int64 {
        Self.effectiveByteSize(of: entry, sizes: directorySizes)
    }

    private static func effectiveByteSize(of entry: FileEntry, sizes: [VFSPath: Int64]) -> Int64 {
        if let computed = sizes[entry.id] { return computed }
        return entry.isDirectoryLike ? 0 : entry.byteSize
    }

    /// Stage 1: rebuild the `showHidden` + `sort` projection (the expensive one), drop the
    /// stale filter cache, then re-apply the text filter. Called whenever the listing, sort,
    /// hidden-toggle, or computed sizes change.
    private mutating func resort() {
        var items = listing.entries
        if !showHidden {
            items = items.filter { !$0.isHidden }
        }
        items.sort(by: Self.comparator(for: sort, sizes: directorySizes))
        sortedEntries = items
        loweredNames = nil
        refilter()
    }

    /// Stage 2: project `visibleEntries` from the already-sorted `sortedEntries` by applying
    /// the text filter. Order-preserving, so it never re-sorts. Called on every keystroke.
    ///
    /// A pure-ASCII needle (every real filter keystroke) takes the byte fast path: match the
    /// needle's bytes against each name's lowercased UTF-8. This is provably identical to the
    /// old `name.lowercased().contains(needle)` for ASCII needles — an ASCII byte can only
    /// occur at a real ASCII character position, never inside a multi-byte UTF-8 sequence — so
    /// it is a speedup with no behaviour change. A non-ASCII needle (rare) falls back to the
    /// exact grapheme-aware path so canonical-equivalence matching is preserved.
    private mutating func refilter() {
        guard !filter.isEmpty else {
            visibleEntries = sortedEntries
            return
        }
        let needle = filter.lowercased()
        let needleBytes = Array(needle.utf8)
        guard needleBytes.allSatisfy({ $0 < 0x80 }) else {
            visibleEntries = sortedEntries.filter { $0.name.lowercased().contains(needle) }
            return
        }
        if loweredNames == nil {
            loweredNames = Self.buildLoweredNames(sortedEntries)
        }
        let lowered = loweredNames ?? LoweredNames(bytes: [], bounds: [0])
        var result: [FileEntry] = []
        result.reserveCapacity(sortedEntries.count)
        lowered.bytes.withUnsafeBufferPointer { buffer in
            for index in sortedEntries.indices
                where Self.bytesContain(
                    buffer,
                    from: lowered.bounds[index],
                    to: lowered.bounds[index + 1],
                    needle: needleBytes
                ) {
                result.append(sortedEntries[index])
            }
        }
        visibleEntries = result
    }

    /// Concatenate every entry's name — with a **byte-level ASCII case fold** — into one
    /// buffer, recording each name's `[start, end)` in `bounds` (which ends up
    /// `entries.count + 1` long).
    ///
    /// Only `A`–`Z` are folded; non-ASCII bytes pass through untouched. That is deliberately
    /// *not* `String.lowercased()`, and it is exactly right for the ASCII-needle fast path:
    /// an ASCII needle byte can never match a non-ASCII byte, so folding non-ASCII (e.g.
    /// `É`→`é`) would change no match outcome — while `String.lowercased()` would allocate a
    /// fresh String per name and cost ~4× as much on the cold first keystroke.
    private static func buildLoweredNames(_ entries: [FileEntry]) -> LoweredNames {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(entries.count * 16)
        var bounds: [Int] = [0]
        bounds.reserveCapacity(entries.count + 1)
        for entry in entries {
            for byte in entry.name.utf8 {
                bytes.append(byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte)
            }
            bounds.append(bytes.count)
        }
        return LoweredNames(bytes: bytes, bounds: bounds)
    }

    /// Whether `haystack[from..<to]` contains `needle` as a contiguous byte subsequence.
    /// `needle` is never empty at the one call site (an empty filter short-circuits in
    /// `refilter`).
    private static func bytesContain(
        _ haystack: UnsafeBufferPointer<UInt8>,
        from: Int,
        to: Int,
        needle: [UInt8]
    ) -> Bool {
        let span = to - from
        guard span >= needle.count else { return false }
        let first = needle[0]
        let lastStart = from + span - needle.count
        var i = from
        while i <= lastStart {
            if haystack[i] == first {
                var j = 1
                while j < needle.count, haystack[i + j] == needle[j] { j += 1 }
                if j == needle.count { return true }
            }
            i += 1
        }
        return false
    }

    /// Builds the row-ordering predicate for a sort. Directory grouping (when on)
    /// wins over the key; the key's direction never moves directories below files.
    /// Name is the stable tiebreaker so equal keys yield a deterministic order.
    static func comparator(
        for sort: FileSort,
        sizes: [VFSPath: Int64] = [:]
    ) -> (FileEntry, FileEntry) -> Bool {
        { lhs, rhs in
            if sort.directoriesFirst, lhs.isDirectoryLike != rhs.isDirectoryLike {
                return lhs.isDirectoryLike
            }

            var result = compare(lhs, rhs, key: sort.key, sizes: sizes)
            if result == .orderedSame, sort.key != .name {
                result = lhs.name.localizedStandardCompare(rhs.name)
            }
            if result == .orderedSame {
                return false
            }
            return sort.ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private static func compare(
        _ lhs: FileEntry,
        _ rhs: FileEntry,
        key: FileSort.Key,
        sizes: [VFSPath: Int64]
    ) -> ComparisonResult {
        switch key {
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name)
        case .size:
            return compareValues(
                effectiveByteSize(of: lhs, sizes: sizes),
                effectiveByteSize(of: rhs, sizes: sizes)
            )
        case .modified:
            return compareValues(lhs.modificationDate, rhs.modificationDate)
        case .fileExtension:
            let byExt = lhs.fileExtension.localizedStandardCompare(rhs.fileExtension)
            return byExt == .orderedSame ? lhs.name.localizedStandardCompare(rhs.name) : byExt
        }
    }

    private static func compareValues<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }
}
