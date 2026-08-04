import DirnexCore
import Foundation

/// The per-directory scan machine three providers share: cache what a background read found, keep it
/// bounded, and never let filesystem churn turn into a scan storm.
///
/// `FinderTagProvider`, `CloudSyncStatusProvider` and `GitStatusProvider` each answer the same
/// question about a directory — "what should the rows here draw?" — by reading something expensive
/// off the main thread (`getxattr`s, provider round trips, a `git` subprocess). They arrived at the
/// same design independently and then carried it as three verbatim copies of the same seven stored
/// properties and the same three methods. This is that design, once.
///
/// What stays with each provider is what actually differs: the *scan* itself, and whatever it wants
/// to do with a result (learn tags, poll a transfer that is still moving, forget a repository that
/// stopped being one). The rule of the split is the one those files already stated — the provider is
/// nothing but cache and scheduling, and the scanner is nothing but I/O; this takes the first half.
///
/// `Input` is whatever the scan needs beyond the directory itself: the listing to read for tags and
/// cloud status, and nothing at all for Git, which reads the working tree. `Snapshot` is optional in
/// the scan's result so a read that fails to produce one (no usable `git`, a working tree that went
/// away) can be told apart from one that found nothing.
@MainActor
final class DirectoryScanCache<Input: Sendable, Snapshot: Sendable> {
    /// Read `key`, given the input recorded with the most recent request. `nil` means the read could
    /// not produce a snapshot at all — distinct from a snapshot that happens to be empty.
    typealias Scan = (VFSPath, Input) async -> Snapshot?

    /// Called on the main actor once a run has stored (or failed to produce) its snapshot. Where a
    /// provider posts its notification and does its own bookkeeping.
    ///
    /// `willReplay` is true when a request arrived mid-scan and this key is about to be re-read.
    /// Every provider posts its notification either way — the snapshot just stored is real, and a
    /// pane should paint it rather than wait — but work that *schedules* something (the cloud
    /// follow-up poll) must sit out, or it would be cancelled by the replay a line later while
    /// still counting against its own budget.
    typealias Completion = (VFSPath, Snapshot?, _ willReplay: Bool) -> Void

    /// A burst of filesystem events collapses into one scan at the end of this window — several
    /// events for one logical change is the norm, not the exception.
    private let debounceInterval: Duration
    /// The longest a visible snapshot may stay stale while changes keep arriving. Past this a request
    /// skips the debounce and runs now, so sustained churn (a build, a folder mid-sync) still updates
    /// the rows instead of starving the trailing edge.
    private let maximumStaleness: TimeInterval
    /// How many directories keep a cached snapshot. Panes are two and tabs are few.
    private let cacheLimit: Int

    private let scan: Scan
    private let completion: Completion

    private var snapshots: [VFSPath: Snapshot] = [:]
    /// Cached keys in least-recently-used order, most recent last.
    private var usage: [VFSPath] = []
    private var lastRun: [VFSPath: Date] = [:]
    /// The input for each key, as of its most recent request — kept so a debounced or replayed run
    /// uses the *latest* listing rather than the one that happened to schedule it.
    private var requested: [VFSPath: Input] = [:]
    /// The pending debounce timer per key — cancelled and replaced by each new request.
    private var scheduled: [VFSPath: Task<Void, Never>] = [:]
    /// Keys with a scan in flight, and those whose changes arrived while it ran (so the snapshot we
    /// are about to store is already known to be stale and must be re-read once).
    private var running: Set<VFSPath> = []
    private var repeatRequested: Set<VFSPath> = []

    init(
        debounceInterval: Duration = .milliseconds(300),
        maximumStaleness: TimeInterval = 2,
        cacheLimit: Int = 8,
        scan: @escaping Scan,
        completion: @escaping Completion
    ) {
        self.debounceInterval = debounceInterval
        self.maximumStaleness = maximumStaleness
        self.cacheLimit = cacheLimit
        self.scan = scan
        self.completion = completion
    }

    // MARK: - Reading

    /// The snapshot already in hand for `key`, or `nil` when none has been read yet. Synchronous and
    /// O(1) — this is what a pane calls while rendering rows.
    func cachedSnapshot(for key: VFSPath) -> Snapshot? {
        snapshots[key]
    }

    /// Every key currently holding a snapshot, for a provider that needs to edit them in place.
    var cachedKeys: [VFSPath] {
        Array(snapshots.keys)
    }

    /// Replace one snapshot without touching its recency or its run stamp — an *edit* of what is
    /// already cached, not a fresh read. `FinderTagProvider.forget(_:)` uses this to strip a deleted
    /// tag from every snapshot still painting its dot, which is why eviction would be wrong: it would
    /// blank every visible dot in the pane until a fresh scan landed.
    func replaceSnapshot(_ snapshot: Snapshot, for key: VFSPath) {
        guard snapshots[key] != nil else { return }
        snapshots[key] = snapshot
    }

    /// Drop what we knew about `key` while **keeping its run stamp** — the stamp is what rate-limits
    /// the next attempt, so a read that just failed must not lose it and re-run immediately.
    func forget(_ key: VFSPath) {
        snapshots.removeValue(forKey: key)
        usage.removeAll { $0 == key }
    }

    // MARK: - Scheduling

    /// Ask for `key` to be brought up to date, reading `input`. The first look runs immediately —
    /// nobody wants to watch a column or a badge appear a third of a second after the folder does —
    /// and later ones are rate-limited.
    func requestRefresh(for key: VFSPath, input: Input) {
        requested[key] = input
        // "Have we ever run this?", not "do we have a snapshot?" — a read that fails caches nothing,
        // and an all-quiet directory caches an *empty* snapshot; asking about the snapshot would call
        // every request its first and re-scan on every filesystem event, which is precisely what this
        // rate limiting exists to prevent. Eviction drops the run stamp with the snapshot, so a key
        // that has aged out is a first look again.
        let isFirstLook = lastRun[key] == nil
        let isOverdue = Date.now.timeIntervalSince(lastRun[key] ?? .distantPast) > maximumStaleness
        if isFirstLook || isOverdue {
            scheduled.removeValue(forKey: key)?.cancel()
            Task { await run(key) }
            return
        }
        scheduleRun(for: key, after: debounceInterval)
    }

    /// Run `key` again after `interval`, replacing any pending timer.
    ///
    /// Exposed for a provider that must look again for a reason the filesystem will not announce —
    /// `CloudSyncStatusProvider`'s follow-up while a transfer is still moving.
    func scheduleRun(for key: VFSPath, after interval: Duration) {
        scheduled[key]?.cancel()
        scheduled[key] = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            await self?.run(key)
        }
    }

    /// Read `key` now and publish the result. Serialized per key: a request arriving mid-scan is
    /// remembered and replayed afterwards rather than starting a second pass over the same rows —
    /// the answer it would get is the one this scan is already fetching.
    private func run(_ key: VFSPath) async {
        guard let input = requested[key] else { return }
        guard !running.contains(key) else {
            repeatRequested.insert(key)
            return
        }
        // This request is being served now, so whatever timer produced it is spent.
        scheduled.removeValue(forKey: key)
        running.insert(key)
        lastRun[key] = .now
        let snapshot = await scan(key, input)
        running.remove(key)

        if let snapshot {
            store(snapshot, for: key)
        } else {
            forget(key)
        }

        let willReplay = repeatRequested.remove(key) != nil
        completion(key, snapshot, willReplay)
        if willReplay {
            requestRefresh(for: key, input: requested[key] ?? input)
        }
    }

    private func store(_ snapshot: Snapshot, for key: VFSPath) {
        snapshots[key] = snapshot
        usage.removeAll { $0 == key }
        usage.append(key)
        while usage.count > cacheLimit {
            let evicted = usage.removeFirst()
            snapshots.removeValue(forKey: evicted)
            lastRun.removeValue(forKey: evicted)
            requested.removeValue(forKey: evicted)
        }
    }
}

extension DirectoryScanCache where Input == Void {
    /// The no-input form, for a scan that needs nothing but the key itself (`GitStatusProvider`,
    /// which reads the working tree rather than a listing handed to it).
    func requestRefresh(for key: VFSPath) {
        requestRefresh(for: key, input: ())
    }
}
