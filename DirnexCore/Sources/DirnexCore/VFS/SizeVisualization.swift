import Foundation

/// One row's entry in the size-visualization bar column (PLAN.md §M6 "toggle panel to
/// ncdu-style bars").
///
/// Two denominators, deliberately, because ncdu's manual splits them and probing says it is
/// right: *"Percentage is relative to the size of the current directory, graph is relative to
/// the largest item in the current directory."* They answer different questions and one number
/// cannot do both — `share` says how much of this folder the row accounts for, `fraction` says
/// how it stands against its biggest sibling, and only the latter makes a bar column legible
/// when one row dominates.
public struct SizeBar: Sendable, Hashable {
    /// Bytes attributed to the row: a file's own size, or a directory's recursive total.
    ///
    /// These are **logical** bytes, matching the panel's own size column — deliberately *not*
    /// ncdu's default of allocated disk usage. Measured on this machine the two disagree in both
    /// directions and by up to 2x (a `.git` full of small files allocates ~2x its logical bytes
    /// in block round-up; one 64 MB sparse LMDB file in a Swift `.build` allocates 27 MB), so the
    /// choice is real. The bar must agree with the number rendered beside it: a row whose bar is
    /// twice its neighbour's while its size column reads smaller is incoherent, and Dirnex is a
    /// file manager with a size column, where ncdu is a disk-usage tool without one.
    public let bytes: Int64
    /// Bar length in `0...1`, relative to the largest visible sibling — ncdu's *graph* rule. The
    /// heaviest row always fills the bar, so the column uses its full width whatever the
    /// directory's absolute scale.
    public let fraction: Double
    /// Row weight in `0...1`, relative to the visible directory total — ncdu's *percentage* rule.
    public let share: Double

    public init(bytes: Int64, fraction: Double, share: Double) {
        self.bytes = bytes
        self.fraction = fraction
        self.share = share
    }

    /// How much bar to actually draw in a column `width` points wide, never less than `minimum`
    /// points for a row that holds any bytes at all.
    ///
    /// **The floor is not a rounding nicety — it is the difference between "negligible" and "empty",
    /// and measurement says it fires constantly.** Probed against real directories at an 80 pt bar:
    /// in `~`, **86 of 93 rows** compute to under half a point, and in this repo 12 of 15 do. Without
    /// a floor a real 17 GB folder beside a 1 TB one renders as *literally nothing* — indistinguishable
    /// from an empty directory, and from the `nil` bar that means "not walked yet". Three different
    /// facts collapsing onto the same pixels is the one outcome the type is built to avoid (see the
    /// note on unknown-is-not-zero above).
    ///
    /// **Zero bytes draws zero ink**, deliberately: an empty folder is not negligible, it is empty,
    /// and that is the one row for which nothing is the honest picture.
    ///
    /// This does *not* make the long tail legible, and no width rule could — pass 9 expected
    /// continuous drawing to dissolve the problem ("~8x finer than eighth-blocks"), but the measured
    /// dynamic range in `~` is ~10⁶ between Movies and the smallest dotfile, against which 8x is
    /// nothing. Every floored row draws the same stub, which reads correctly as "all of these are
    /// noise"; the row's *own* size column, and `share`, carry the low end. A log or sqrt scale would
    /// make the tail visible by making the bar mean something other than proportion — the one thing a
    /// bar cannot be allowed to lie about — so it is rejected rather than deferred.
    public func inkWidth(in width: Double, minimum: Double) -> Double {
        guard bytes > 0, width > 0 else { return 0 }
        // `fraction` is already 0...1 by construction, but it is built from backend-supplied bytes,
        // so the clamp is kept at the boundary for the same reason the core's sum saturates.
        return min(width, max(min(minimum, width), fraction * width))
    }
}

/// The per-row bar lookup a panel performs while rendering size-visualization mode.
///
/// Shaped like `GitStatusSnapshot`: every scan happens once at construction so `bar(for:)` is
/// O(1) per row, because a panel asks once per visible row on every render.
///
/// Three properties worth knowing, each of which a test pins:
/// - **Unknown is not zero.** A directory with no recursive walk yet has *no* bar, not a zero-width
///   one — `nil` from `bar(for:)`. A 0 % bar on an unsized 40 GB folder is a lie, and the two states
///   are visually identical if collapsed. Only `DirectoryModel.computedSize` can tell them apart.
/// - **Both denominators cover the *visible* rows only.** Hiding dotfiles or typing a filter
///   re-scales every bar, because a bar drawn relative to a row you cannot see is unexplainable,
///   and shares that silently fail to reach 100 % are worse than shares of what is on screen.
/// - **It re-scales for free while results stream in.** Sizing a directory is slow (measured: 7.5 s
///   for `~/Dev`, and cost tracks *entry count*, not bytes — a 1 TB `~/Movies` walks fast while a
///   17 GB tree of `node_modules` does not), so bars must appear progressively and the maximum
///   grows underneath them. Rebuilding this whole projection per render handles that with no
///   incremental bar-width bookkeeping; `share` is therefore a share of what is *known so far* and
///   settles as walks land.
///
/// **A row's denominators are its own parent directory's, not the whole projection's** (PLAN.md §M15,
/// re-scoped per level). In a flat listing that is a distinction without a difference — every row
/// shares one parent. In a tree it is the whole point: an expanded folder's children are measured
/// against *each other*, so `share` is "how much of this folder" whatever level the row sits at, and
/// `fraction` fills the bar against the heaviest *sibling* rather than the heaviest row on screen (a
/// deep 4 KB file next to the 40 GB root folder that contains it would otherwise floor to a stub at
/// every level). A whole-tree denominator cannot express this: a child's bytes are a subset of its
/// parent's, so the shares would not sum and the number would answer a question nobody asked.
public struct SizeVisualization: Sendable {
    /// The heaviest **primary-group** row's bytes — `fraction`'s denominator for that group. The
    /// primary group is the flat listing, or the tree's depth-0 root level; per-group maxima that
    /// actually scale each bar live inside the projection. Zero when nothing is known yet.
    public let maximumBytes: Int64
    /// The sum of every *known* **primary-group** row — `share`'s denominator for that group.
    /// Saturates rather than trapping.
    public let totalBytes: Int64
    /// Directories still awaiting a recursive walk, in display order — exactly the work the app's
    /// scan queue consumes, ordered so the rows the user is looking at are sized first. In a tree this
    /// spans every level, so expanding a folder queues its children. Kept here rather than recomputed
    /// by the caller so the file/directory/symlink rule lives in one place.
    public let pendingDirectories: [FileEntry]

    private let bars: [VFSPath: SizeBar]

    /// `isExcluded` marks rows the current sizing rule leaves out entirely — under `.gitignore`-aware
    /// sizing, what Git ignores (§M6). They are **omitted, not zeroed**: no bar, nothing added to
    /// either denominator, and *not* queued for a walk.
    ///
    /// Zeroing them was the first attempt and it lies. An ignored `build/` holding 1.6 GB rendered as
    /// "Zero KB · 0.0 %", which reads as *"measured, and this folder is empty"* — a claim about the
    /// folder rather than about the question being asked. There is no third rendering to invent
    /// either: the row falls back to the same "—" and blank bar an unwalked directory shows, which is
    /// exactly right, because in both cases the honest answer is *we are not telling you a number
    /// here*. The status line carries the reason ("sizes exclude Git-ignored"), and the Git column
    /// already paints the row `!`.
    ///
    /// Keeping them out of `pendingDirectories` is what makes that stable rather than a flicker: a
    /// row with no total is otherwise pending forever, and the pane would re-queue a walk for it on
    /// every render.
    public init(model: DirectoryModel, isExcluded: (VFSPath) -> Bool = { _ in false }) {
        var accumulator = Accumulator()
        // One group: the whole listing shares a parent, so every row is primary and the projection's
        // scalar figures are that group's.
        for entry in model.visibleEntries {
            accumulator.add(
                entry,
                inGroup: model.listing.path,
                isPrimary: true,
                knownBytes: Self.knownBytes(of: entry, computedSize: model.computedSize(of: entry)),
                isExcluded: isExcluded(entry.id)
            )
        }
        self.init(accumulator)
    }

    /// The tree analogue: a bar per row grouped by its **parent directory**, so each expanded folder
    /// is its own denominator (see the type's note). Rows are grouped by `entry.path.parent`, which is
    /// unambiguous because a `VFSPath` appears in the tree at most once; the depth-0 rows are the
    /// primary group, matching the flat listing they would be if nothing were expanded.
    ///
    /// `pendingDirectories` spans every level, in display order, so a folder just expanded queues its
    /// unsized children ahead of anything deeper the user is not looking at.
    public init(tree: TreeProjection, isExcluded: (VFSPath) -> Bool = { _ in false }) {
        var accumulator = Accumulator()
        for row in tree.rows {
            let entry = row.entry
            accumulator.add(
                entry,
                inGroup: entry.path.parent ?? tree.rootPath,
                isPrimary: row.depth == 0,
                knownBytes: Self.knownBytes(of: entry, computedSize: tree.computedSize(of: entry)),
                isExcluded: isExcluded(entry.id)
            )
        }
        self.init(accumulator)
    }

    private init(_ accumulator: Accumulator) {
        bars = accumulator.bars()
        maximumBytes = accumulator.primaryMaximum
        totalBytes = accumulator.primaryTotal
        pendingDirectories = accumulator.pending
    }

    /// This row's bar, or `nil` while its recursive total is still unknown (see the type's note on
    /// unknown-is-not-zero). Files always have one; directories only once sized.
    public func bar(for entry: FileEntry) -> SizeBar? {
        bars[entry.id]
    }

    /// The bytes a row contributes, or `nil` when a directory has not been walked yet — its computed
    /// recursive total if one has landed, otherwise a file's own size and a directory's absence.
    ///
    /// Directory-*like* is the test, not `.directory`, matching `DirectoryModel.effectiveByteSize`
    /// and `Panel.openTarget`: a symlink resolving to a directory is navigable, so it is sized like
    /// one rather than counted as its own link inode.
    ///
    /// Negatives are clamped to zero at the boundary for the same reason the sum saturates.
    static func knownBytes(of entry: FileEntry, computedSize: Int64?) -> Int64? {
        if let computedSize { return max(0, computedSize) }
        guard !entry.isDirectoryLike else { return nil }
        return max(0, entry.byteSize)
    }
}

/// Builds the per-parent-directory groups both initializers share (see `SizeVisualization`'s note on
/// per-level denominators). A *group* is one containing directory; a bar is scaled against its own
/// group's maximum and total, never the projection's. The *primary* group — the flat listing or the
/// tree root — feeds the scalar `maximumBytes`/`totalBytes`, which exist only for the status line.
private struct Accumulator {
    private struct Group {
        var known: [(id: VFSPath, bytes: Int64)] = []
        var maximum: Int64 = 0
        var total: Int64 = 0
    }

    private var groups: [VFSPath: Group] = [:]
    private(set) var pending: [FileEntry] = []
    private(set) var primaryMaximum: Int64 = 0
    private(set) var primaryTotal: Int64 = 0

    mutating func add(
        _ entry: FileEntry,
        inGroup group: VFSPath,
        isPrimary: Bool,
        knownBytes: Int64?,
        isExcluded: Bool
    ) {
        // Excluded rows are not "unknown pending a walk" and not "known to be zero" — they are
        // outside the question, so they leave no trace in the projection at all.
        guard !isExcluded else { return }
        guard let bytes = knownBytes else {
            pending.append(entry)
            return
        }
        var accumulated = groups[group] ?? Group()
        accumulated.known.append((entry.id, bytes))
        accumulated.maximum = max(accumulated.maximum, bytes)
        accumulated.total = Self.saturating(accumulated.total, plus: bytes)
        groups[group] = accumulated
        if isPrimary {
            primaryMaximum = max(primaryMaximum, bytes)
            primaryTotal = Self.saturating(primaryTotal, plus: bytes)
        }
    }

    func bars() -> [VFSPath: SizeBar] {
        var bars: [VFSPath: SizeBar] = [:]
        for group in groups.values {
            for row in group.known {
                bars[row.id] = SizeBar(
                    bytes: row.bytes,
                    fraction: group.maximum > 0 ? Double(row.bytes) / Double(group.maximum) : 0,
                    share: group.total > 0 ? Double(row.bytes) / Double(group.total) : 0
                )
            }
        }
        return bars
    }

    /// Saturate rather than trap. `SFTPListingParser` builds sizes out of *text*, so a hostile or
    /// broken server's numbers reach this sum; a panel must not crash on arithmetic overflow.
    private static func saturating(_ running: Int64, plus bytes: Int64) -> Int64 {
        let (sum, overflowed) = running.addingReportingOverflow(bytes)
        return overflowed ? .max : sum
    }
}
