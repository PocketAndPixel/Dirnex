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

    /// The scan machine — debounce, LRU cache, per-directory serialization — is
    /// `DirectoryScanCache`'s; only the `getxattr` sweep below and the tag index are this provider's.
    ///
    /// Tagging in Finder, or our own editor writing a tag across a marked set, is exactly the burst
    /// the debounce exists for: one `setxattr` per file, each landing as its own event.
    private lazy var cache = DirectoryScanCache<[VFSPath], FinderTagSnapshot>(
        scan: { _, entries in await FinderTagScanner.scan(entries) },
        completion: { [weak self] directory, snapshot, _ in
            guard let self, let snapshot else { return }
            record(snapshot)
            NotificationCenter.default.post(
                name: Self.didChangeNotification,
                object: self,
                userInfo: [Self.directoryKey: directory]
            )
        }
    )

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
        cache.cachedSnapshot(for: directory)
    }

    /// Ask for `directory`'s tags to be brought up to date, reading `entries`.
    ///
    /// `entries` should be the **whole** listing, not just the visible rows: two panes on one
    /// folder can have different hidden/filter settings, and a scan of the narrower one would
    /// otherwise evict rows the other still shows — leaving tagged files looking untagged.
    func requestRefresh(for directory: VFSPath, entries: [VFSPath]) {
        cache.requestRefresh(for: directory, input: entries)
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
        for directory in cache.cachedKeys {
            guard let snapshot = cache.cachedSnapshot(for: directory) else { continue }
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
            cache.replaceSnapshot(updated, for: directory)
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
