import Foundation

/// Why a set of rows is not yet a set of readable files on this disk (PLAN.md §M24 Slice 1).
///
/// Seven gestures spent seven milestones refusing anything that is not local, each in one line, and
/// what every one of those lines really meant was *"I need a path I can open."* The cases below are
/// the reasons a row does not have one yet — and they are kept apart rather than collapsed into a
/// `Bool`, because what it costs to get one differs by an order of magnitude and by *who pays*: a
/// remote transfer is a network round trip this app performs and S3 bills, a placeholder is a wait
/// the file provider owns and we merely block on, and an archive member is neither.
public enum MaterializationSource: Sendable, Equatable, CaseIterable {
    /// The bytes are on this disk, at the path the row already names. Nothing to do.
    case present
    /// A copy was pulled down earlier and the caller says it is still current — see
    /// `RemoteFileCache`, which is the only thing that can answer that and lives in the app.
    case cached
    /// A local file carrying `SF_DATALESS`: real name, real size, no bytes here. Reading one
    /// materializes it and *blocks* while it does (measured 1.1 s for 200 KB), which is the whole
    /// reason `ByteComparator` refuses to read through one rather than discovering it mid-sweep.
    case cloudPlaceholder
    /// Inside an archive on this disk. Extraction rather than a transfer: no network, no request to
    /// bill, and — since M19's member filter — 0.001 s for one member of a 600 MB encrypted archive.
    case archiveMember
    /// On a server. One transfer, whose floor is a round trip rather than the bytes.
    case remote

    /// Whether anything has to happen before this row is a file something else can open.
    ///
    /// Two cases answer `false` and they are not the same fact: ``present`` is a property of the
    /// row, ``cached`` is a property of what this window has already done. Keeping them apart is
    /// what lets a caller say "one of these three is already downloaded" rather than reporting a
    /// smaller total with no explanation for where it went.
    public var needsBytes: Bool {
        switch self {
        case .present, .cached: false
        case .cloudPlaceholder, .archiveMember, .remote: true
        }
    }
}

/// What stands between a marked set of rows and the real paths a gesture is about to hand to an
/// engine: which of them are already here, what the rest weigh, and how many round trips that is.
///
/// **This is a plan, not a fetch.** `RemoteFetchPolicy` has answered the same question per *file*
/// since M21 Slice 10, because one file under a cursor was the only shape that existed — ⏎, F4 and
/// the preview surface each ask about the row they are pointing at. Every gesture M24 reaches is a
/// **set**: ⌥F3 is two files, a checksum run and ⌥F5 are whatever the user marked, and a user script
/// is whatever they marked plus the argument they meant. Asking per file would either interrupt once
/// per file or, far worse, weigh each one alone and start a transfer no single row ever justified.
///
/// So the plan is the deliverable and the totals are the point: the confirmation names *this*
/// number, once, before anything moves.
///
/// **It never fetches, and nothing it hands back does either.** That is the milestone's one
/// structural rule (PLAN.md §6, the M24 risk row): the *gesture* materializes and reports, and the
/// engines behind it — `ByteComparator`, `ChecksumEngine`, `bsdtar` — go on seeing only files that
/// are already on this disk. The tell that the boundary is going is an engine learning to
/// materialize, or a second threshold table appearing beside `RemoteFetchPolicy`'s.
public struct MaterializationPlan: Sendable, Equatable {
    /// One row and what it will take to read it.
    public struct Item: Sendable, Equatable {
        public let entry: FileEntry
        public let source: MaterializationSource

        public init(entry: FileEntry, source: MaterializationSource) {
            self.entry = entry
            self.source = source
        }
    }

    /// Every row the plan was built over, in the order it was given them, each classified.
    ///
    /// The rows that need nothing are kept rather than filtered away: a gesture runs over the whole
    /// set, and a plan that only listed the missing half could not be handed to it.
    public let items: [Item]

    public init(items: [Item]) {
        self.items = items
    }

    // MARK: - Building

    /// Classify `entries` against what is on this disk and what `isCached` says has already been
    /// pulled down.
    ///
    /// `isCached` is the seam, and it has to be one: the cache is a window-scoped `@MainActor`
    /// object holding temp URLs and revisions (`RemoteFileCache`), which is exactly the kind of
    /// thing `DirnexCore` may not import. It is asked **only about rows whose own path is not the
    /// file** — a remote object or an archive member — and never about a local one, placeholder
    /// included: a dataless file's bytes land at the path it already names, so there is no copy
    /// anywhere for a cache to be holding and asking would invite a wrong answer.
    ///
    /// **Duplicates collapse, first spelling wins.** Two rows naming one object is not hypothetical
    /// — ⌥F3 takes one entry from each pane and the two panes can be showing the same folder — and
    /// counting it twice would put a request in the total that nothing is going to make.
    public static func plan(
        for entries: [FileEntry],
        isCached: (FileEntry) -> Bool
    ) -> MaterializationPlan {
        var seen: Set<VFSPath> = []
        var items: [Item] = []
        for entry in entries where seen.insert(entry.path).inserted {
            items.append(Item(entry: entry, source: source(of: entry, isCached: isCached)))
        }
        return MaterializationPlan(items: items)
    }

    private static func source(
        of entry: FileEntry,
        isCached: (FileEntry) -> Bool
    ) -> MaterializationSource {
        if entry.path.backend == .local {
            // A dataless placeholder is the one local row whose bytes are not here. Asked before
            // anything else about a local path, because every other signal — the name, the size,
            // the dates — says the file is present and complete.
            //
            // **A dataless *directory* is present**, which is not a special case so much as the flag
            // meaning something else on one: some providers set `SF_DATALESS` on directories too
            // (docs/NOTES.md ▸ iCloud Drive), and a directory has no bytes anyone could fetch — what
            // is lazy is each *child*, which the provider materializes when something reads it, and
            // which arrives here as a row of its own. `ArchiveSourceEnumerator` already draws this
            // line for the same reason, in the same words. Calling it a placeholder would put a
            // *"download this first"* wait in front of a folder whose listing costs nothing, and put
            // it in the set of folders the gestures reading ``pendingDirectories`` refuse outright.
            return entry.isDataless && !entry.isDirectoryLike ? .cloudPlaceholder : .present
        }
        if isCached(entry) { return .cached }
        if entry.path.backend.isArchive { return .archiveMember }
        return .remote
    }

    /// The same plan with every row of `source` dropped — for a gesture that is not the one to
    /// move those bytes.
    ///
    /// Written for ``MaterializationSource/cloudPlaceholder``, which is the one case whose answer
    /// genuinely differs by gesture. A hand-off gives another application the placeholder's own
    /// path and the file provider materializes it when that application reads it, exactly as Finder
    /// does — so those bytes are neither ours to confirm nor ours to move, and counting them would
    /// put a dialog about a *download from a server* in front of a file that is already on this
    /// disk. A compare or a checksum is the other side of it: `ByteComparator` refuses to read
    /// through a placeholder rather than discovering one mid-sweep, so there the gesture does
    /// materialize it and must weigh it.
    ///
    /// Only what a decision reads is affected — ``pending`` and the three totals over it. A caller
    /// that iterates rows should iterate the set it was given rather than ``items``, since this is
    /// the one place a plan stops standing for the whole of it.
    public func excluding(_ source: MaterializationSource) -> MaterializationPlan {
        MaterializationPlan(items: items.filter { $0.source != source })
    }

    // MARK: - What it costs

    /// The rows that need something to happen first, in the order they were given.
    public var pending: [Item] { items.filter(\.source.needsBytes) }

    /// Nothing has to move: every row is already a readable file on this disk.
    ///
    /// The common case for every one of these gestures — a marked set of ordinary local files — and
    /// it must cost nothing to discover, which is why the whole type is pure and synchronous.
    public var needsNothing: Bool { pending.isEmpty }

    /// The rows to pull over the network, in order.
    public var remoteFetches: [FileEntry] { entries(from: .remote) }

    /// The rows to extract from an archive on this disk, in order.
    public var archiveExtractions: [FileEntry] { entries(from: .archiveMember) }

    /// The local placeholders to ask the file provider for, in order.
    public var cloudMaterializations: [FileEntry] { entries(from: .cloudPlaceholder) }

    private func entries(from source: MaterializationSource) -> [FileEntry] {
        items.filter { $0.source == source }.map(\.entry)
    }

    /// How many bytes are known to have to move before the gesture can start.
    ///
    /// A **floor** rather than a total whenever ``totalsAreExact`` is `false`, and the two must be
    /// read together — a number presented as the cost of an operation, when it is really the part of
    /// the cost that could be measured, is the kind of wrong that nobody catches until the transfer
    /// is minutes past it.
    public var byteTotal: Int64 {
        pending.reduce(into: Int64(0)) { total, item in
            total += max(0, measurableSize(of: item.entry) ?? 0)
        }
    }

    /// How many network round trips the plan is, which on S3 is how many billed requests.
    ///
    /// Counts ``MaterializationSource/remote`` alone. An archive member is extracted locally and a
    /// placeholder is the provider's own wait — neither pays the connect-and-handshake this number
    /// exists to measure, and folding them in would make the one quantity the request rule is
    /// derived from mean something else.
    public var requestCount: Int { items.count { $0.source == .remote } }

    /// The rows that need bytes and are **directories** — a folder that is not already on this
    /// disk.
    ///
    /// A fact, deliberately, rather than a policy, because it is the gesture that decides what to do
    /// about it. Every gesture that has since read it refuses such a row outright and says so by
    /// name — a hand-off, a compare, a checksum and a pack — because a folder on a server is not one
    /// transfer that could stand in for one, and copying a tree out is F5's job. Staging the subtree
    /// instead is reachable (F5's own engine pointed at a temp directory) and is nobody's yet; this
    /// property is what a gesture that wanted it would build on, and a shared verdict here would be
    /// one gesture's answer inherited by the next one that asked.
    ///
    /// The claim in the first version of this comment — that a pack stages the subtree — was written
    /// before any gesture read it and was wrong when Slice 6 came to (PLAN.md §M24).
    ///
    /// A local `SF_DATALESS` **directory** is not one of them, and that falls out of
    /// ``plan(for:isCached:)`` rather than being filtered here — a directory has no bytes to fetch,
    /// so it never needed any.
    ///
    /// Otherwise it is the same rows that make ``totalsAreExact`` false — a directory entry's
    /// `byteSize` is the directory file's own and never its subtree's — read from the other side:
    /// there the question is what the confirmation may claim, here it is whether there is anything
    /// to confirm.
    public var pendingDirectories: [FileEntry] {
        pending.filter(\.entry.isDirectoryLike).map(\.entry)
    }

    /// Whether ``byteTotal`` and ``requestCount`` are the real totals rather than floors.
    ///
    /// False for exactly two shapes, both of which are the unknown-size row of
    /// `RemoteFetchPolicy`'s table arriving over a set:
    ///
    /// - A **directory** that is not already here. `FileEntry.byteSize` is the directory file's own
    ///   size and never its subtree's, so a folder marked for ⌥F5 on a server stands for an unknown
    ///   number of bytes in an unknown number of requests. Nothing here can size it, and pretending
    ///   the 4 KB of the directory entry is the answer would confirm nothing and download gigabytes.
    /// - A **negative size**, which can only come from a field a listing did not understand.
    ///
    /// Only pending rows are weighed, so a set of local folders — the ordinary ⌥F5 — is exact and
    /// costs nothing, which is what keeps `needsNothing` from needing a special case anywhere.
    public var totalsAreExact: Bool {
        pending.allSatisfy { measurableSize(of: $0.entry) != nil }
    }

    /// What a row is worth to the total, or `nil` when it cannot stand for its own cost.
    private func measurableSize(of entry: FileEntry) -> Int64? {
        guard !entry.isDirectoryLike else { return nil }
        return entry.byteSize >= 0 ? entry.byteSize : nil
    }
}
