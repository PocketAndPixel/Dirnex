import DirnexCore
import Foundation

/// The app's live source of Finder tags: it reads the extended attribute off every row of a
/// directory on a background thread and caches the result for the panes to render (PLAN.md §M6
/// "Finder tags: column…").
///
/// Deliberately shaped like `GitStatusProvider` — off-main, cached, rate-limited, published by
/// notification — for the same reason, which the core *measured*: one `getxattr` costs ~10 µs
/// whether the file is tagged or not, so a 100k-row directory costs ~1 s of pure attribute reads
/// against M1's 150 ms budget for opening one. That is why the column is filled from a cache
/// afterwards and never folded into `LocalBackend.listDirectory`.
///
/// **What differs from the Git provider, and why.** Its unit of caching is the *repository*,
/// because one `git status` answers for a whole tree. There is no such command for tags: the answer
/// is per file, so the unit here is the **directory**, and the caller passes the paths to read. Two
/// panes on the same folder still share one scan; a pane and its neighbour on different folders
/// legitimately do their own.
@MainActor
final class FinderTagProvider {
    static let shared = FinderTagProvider()

    /// Posted when a directory's tags change, so every pane showing it re-renders. The directory
    /// rides in `userInfo` under `directoryKey`; panes ignore directories they aren't showing.
    static let didChangeNotification = Notification.Name("Dirnex.finderTagsDidChange")
    static let directoryKey = "directory"

    /// A burst of filesystem events collapses into one scan at the end of this window. Tagging in
    /// Finder, or our own editor writing a tag across a marked set, is exactly such a burst: one
    /// `setxattr` per file, each landing as its own event.
    private let debounceInterval: Duration = .milliseconds(300)
    /// The longest a visible snapshot may stay stale while changes keep arriving. Past this, a
    /// request skips the debounce and runs now, so sustained churn still updates the column instead
    /// of starving the trailing edge.
    private let maximumStaleness: TimeInterval = 2
    /// How many directories keep a cached snapshot — panes are two and tabs are few, so this makes
    /// stepping back and forth between the folders someone actually has open instant, while
    /// bounding what a session spent wandering a source tree retains.
    private let cacheLimit = 8

    private var snapshots: [VFSPath: FinderTagSnapshot] = [:]
    /// Cached directories in least-recently-used order, most recent last.
    private var usage: [VFSPath] = []
    private var lastRun: [VFSPath: Date] = [:]
    /// The paths to read for each directory, as of its most recent request — the scan's input, kept
    /// here so a debounced or replayed run uses the *latest* listing rather than the one that
    /// happened to schedule it.
    private var requested: [VFSPath: [VFSPath]] = [:]
    /// The pending debounce timer per directory — cancelled and replaced by each new request.
    private var scheduled: [VFSPath: Task<Void, Never>] = [:]
    /// Directories with a scan in flight, and those whose changes arrived while it ran (so the
    /// snapshot we are about to store is already known to be stale and must be re-read once).
    private var running: Set<VFSPath> = []
    private var repeatRequested: Set<VFSPath> = []

    /// Every tag seen this session, plus the seven macOS ships with — the app's approximation of the
    /// name → colour database Finder resolves dots against. The tag editor offers these, the
    /// sidebar's Tags section lists them, the search sheet completes against them, and `resolve`
    /// paints with them.
    ///
    /// There is no public API for "the user's tags": the system's own list lives in a private synced
    /// store that is Finder's business, not a contract. So this accumulates tags as directories are
    /// scanned, which is honest about what it knows — it grows as the user browses rather than
    /// pretending to be authoritative, and the stock seven are always offered because they always
    /// exist. The rules for what a sighting is allowed to teach it — and why an iCloud file's colour
    /// byte teaches it nothing — live in the core's `FinderTagIndex`.
    private var index = FinderTagIndex()

    /// Every known tag with its colour: the stock seven in Finder's order, then the custom ones
    /// sorted by name. This is what a list of tags should show.
    var knownTags: [FinderTag] { index.tags }

    /// Just the names, in the spelling they were seen in — for the search sheet's chip completion,
    /// which matches by name because names are all Spotlight indexes.
    var knownTagNames: Set<String> { index.names }

    /// `tags` as they should be **drawn**: each one's colour taken from what its name is known to
    /// carry, rather than from the byte the file happens to hold.
    ///
    /// This is what keeps iCloud Drive's dots honest. Every tagged file in the drive stores colour
    /// 1 — Finder's own Tags UI writes it that way, as does everything else, because the provider
    /// rewrites the byte — so a pane that trusts the file paints the whole drive grey while Finder
    /// two inches away paints it red. See `FinderTagIndex` for the probe that established it.
    func resolve(_ tags: [FinderTag]) -> [FinderTag] {
        index.resolve(tags)
    }

    // MARK: - Snapshots

    /// The snapshot already in hand for `directory`, or `nil` when none has been read yet.
    /// Synchronous and O(1) — this is what a pane calls while rendering rows.
    func cachedSnapshot(for directory: VFSPath) -> FinderTagSnapshot? {
        snapshots[directory]
    }

    /// Ask for `directory`'s tags to be brought up to date, reading `entries`. The first look runs
    /// immediately (nobody wants to watch dots appear a third of a second after the folder does);
    /// later ones are rate-limited as described on the type.
    ///
    /// `entries` should be the **whole** listing, not just the visible rows: two panes on one
    /// folder can have different hidden/filter settings, and a scan of the narrower one would
    /// otherwise evict rows the other still shows — leaving tagged files looking untagged.
    func requestRefresh(for directory: VFSPath, entries: [VFSPath]) {
        requested[directory] = entries
        // "Have we ever run this?", not "do we have a snapshot?" — a directory we cannot read
        // caches nothing, so asking about the snapshot would call every request its first and
        // re-scan on every filesystem event, which is precisely what this rate limiting exists to
        // prevent. Eviction drops the run stamp with the snapshot, so an aged-out directory is a
        // first look again.
        let isFirstLook = lastRun[directory] == nil
        let isOverdue = Date.now.timeIntervalSince(lastRun[directory] ?? .distantPast) > maximumStaleness
        if isFirstLook || isOverdue {
            scheduled.removeValue(forKey: directory)?.cancel()
            Task { await run(directory) }
            return
        }
        scheduled[directory]?.cancel()
        let interval = debounceInterval
        scheduled[directory] = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            await self?.run(directory)
        }
    }

    /// Read `directory` now and publish the result. Serialized per directory: a request arriving
    /// mid-scan is remembered and replayed afterwards rather than starting a second pass over the
    /// same rows — the answer it would get is the one this scan is already fetching.
    private func run(_ directory: VFSPath) async {
        guard let entries = requested[directory] else { return }
        guard !running.contains(directory) else {
            repeatRequested.insert(directory)
            return
        }
        // This request is being served now, so whatever timer produced it is spent.
        scheduled.removeValue(forKey: directory)
        running.insert(directory)
        lastRun[directory] = .now
        let snapshot = await FinderTagScanner.scan(entries)
        running.remove(directory)

        store(snapshot, for: directory)
        record(snapshot)
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: self,
            userInfo: [Self.directoryKey: directory]
        )
        if repeatRequested.remove(directory) != nil {
            requestRefresh(for: directory, entries: requested[directory] ?? entries)
        }
    }

    /// Learn the tags a scan turned up. Only tagged files appear in a snapshot, so this is cheap
    /// even after a scan of a hundred thousand rows.
    ///
    /// Unlike the snapshots, this is **never evicted**: a tag's existence is a fact about the user,
    /// not about a directory, and forgetting `Zebra` because they browsed nine folders since would
    /// make the tag list flicker in and out. It is bounded by how many tags one person has.
    private func record(_ snapshot: FinderTagSnapshot) {
        for tags in snapshot.tagsByPath.values {
            index.learn(tags)
        }
    }

    /// Drop a tag from everything the app holds in memory: the list it offers, and any cached
    /// snapshot still painting its dot. The in-memory half of deleting a tag — the caller
    /// (`SidebarViewController+Tags`) has already stripped it from the files on disk.
    ///
    /// **Snapshots are edited, not evicted.** Eviction would be simpler, but it would blank every
    /// visible dot in the pane until a fresh scan landed — a folder full of tags flickering because
    /// one of them was deleted. Removing just this tag leaves every other one on screen untouched,
    /// which is the only thing that actually changed.
    ///
    /// A stock tag is refused: `FinderTag.isSystem` explains why there is nothing there to forget —
    /// `known` is seeded with the seven at launch, so removing one would only make it reappear.
    func forget(_ tag: FinderTag) {
        guard !tag.isSystem else { return }
        index.forget(tag)

        // Collect, then mutate, then post — rather than posting inside the walk. An observer runs
        // synchronously on `post` and is free to call straight back in here (a pane re-reads its
        // snapshot), and it should not be able to see a half-purged cache.
        var touched: [VFSPath] = []
        for (directory, snapshot) in snapshots {
            let carriers = snapshot.tagsByPath.filter { $0.value.contains(tag) }
            guard !carriers.isEmpty else { continue }
            var updated = snapshot
            for (path, tags) in carriers {
                let remaining = tags.filter { $0 != tag }
                // A file whose only tag this was leaves the snapshot entirely: it holds tagged
                // files, so an empty list would be a row claiming tags it no longer has.
                if remaining.isEmpty {
                    updated.tagsByPath.removeValue(forKey: path)
                } else {
                    updated.tagsByPath[path] = remaining
                }
            }
            snapshots[directory] = updated
            touched.append(directory)
        }
        for directory in touched {
            NotificationCenter.default.post(
                name: Self.didChangeNotification,
                object: self,
                userInfo: [Self.directoryKey: directory]
            )
        }
    }

    private func store(_ snapshot: FinderTagSnapshot, for directory: VFSPath) {
        snapshots[directory] = snapshot
        usage.removeAll { $0 == directory }
        usage.append(directory)
        while usage.count > cacheLimit {
            let evicted = usage.removeFirst()
            snapshots.removeValue(forKey: evicted)
            lastRun.removeValue(forKey: evicted)
            requested.removeValue(forKey: evicted)
        }
    }
}

// MARK: - Snapshot

/// One directory's tags, keyed by the path they sit on. Untagged files are simply absent, so the
/// dictionary is small even in a folder of thousands: only what has something to draw.
struct FinderTagSnapshot: Equatable {
    var tagsByPath: [VFSPath: [FinderTag]]

    /// The tags on one row, `[]` when it has none (or has not been scanned).
    func tags(for path: VFSPath) -> [FinderTag] {
        tagsByPath[path] ?? []
    }

    /// Hand-rolled, and it must be: `FinderTag`'s own `==` compares **names, case-insensitively,
    /// ignoring the colour** — the right rule for identity (macOS folds case to identify a tag, and
    /// a file cannot hold `Work` and `work` as two tags), and the wrong one for "did the pixels
    /// change". The synthesized version would answer "equal" when a tag was recoloured — which the
    /// core documented as something Finder *does* on its own, reconciling a file's stored colour
    /// against the system's name → colour database — and the column would keep painting the old
    /// dot. So this compares what is actually drawn: names verbatim and colours.
    static func == (lhs: FinderTagSnapshot, rhs: FinderTagSnapshot) -> Bool {
        guard lhs.tagsByPath.count == rhs.tagsByPath.count else { return false }
        return lhs.tagsByPath.allSatisfy { path, tags in
            guard let other = rhs.tagsByPath[path], other.count == tags.count else { return false }
            return zip(tags, other).allSatisfy { $0.name == $1.name && $0.color == $1.color }
        }
    }
}

// MARK: - The scan

/// The attribute reads themselves. Split from the provider so the provider is nothing but cache and
/// scheduling and this is nothing but I/O — the same division `GitStatusProvider` draws around its
/// subprocess, and `SpotlightSearchRunner` around `mdfind`.
private enum FinderTagScanner {
    /// Read every path's tags off the main thread. Non-local paths (an archive member, an SFTP
    /// file) throw `.unsupported` from the core and are skipped: they have no extended attributes,
    /// so they simply have no dots.
    static func scan(_ paths: [VFSPath]) async -> FinderTagSnapshot {
        await Task.detached(priority: .userInitiated) {
            var tagsByPath: [VFSPath: [FinderTag]] = [:]
            for path in paths {
                guard let tags = try? FinderTagStorage.tags(at: path), !tags.isEmpty else { continue }
                tagsByPath[path] = tags
            }
            return FinderTagSnapshot(tagsByPath: tagsByPath)
        }.value
    }
}
