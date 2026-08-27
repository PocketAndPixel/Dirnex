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
            return entry.isDataless ? .cloudPlaceholder : .present
        }
        if isCached(entry) { return .cached }
        if entry.path.backend.isArchive { return .archiveMember }
        return .remote
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
