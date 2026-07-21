import DirnexCore
import Foundation

/// The app's live source of cloud sync status: it reads the ubiquity attributes off every row of a
/// directory on a background thread and caches the result for the panes to render (PLAN.md §M6
/// "iCloud/provider sync status").
///
/// Deliberately shaped like `FinderTagProvider` — off-main, per-directory, cached, rate-limited,
/// published by notification — because the problem is the same one, only much more so. A read inside
/// a File Provider domain was **re-measured at 650–1000 µs warm** (2026-07-22, live iCloud Drive and
/// streaming Google Drive alike): it is a round trip to the provider, so a 5000-row cloud folder is
/// ~3–5 s of pure reads against M1's 150 ms budget for opening one. `CloudSyncStorage` carries the
/// numbers and why the ~24 µs this used to quote described the wrong case.
///
/// **What differs from the tags provider, and why it matters more here: the directory gate.** Tags
/// can be on any file anywhere, so that scan has to look at every row to find out. Cloud items
/// cannot: a cloud file lives in a cloud folder, and a cloud folder announces itself in one read
/// (`CloudSyncStorage.isCloudDirectory`). So a directory is asked once, and an ordinary folder —
/// which is nearly every folder, on nearly every Mac — skips the per-row scan entirely instead of
/// performing 100k reads to conclude nothing. That gate is why this feature costs a non-iCloud user
/// exactly one resource read per folder visit.
///
/// **The provider being scanned need not be iCloud, and that is not a hope — it is measured.**
/// Verified 2026-07-22 against a streaming-mode Google Drive: every row reported the standard
/// ubiquity attributes, so `CloudItemAttributes.status` classified them with no Drive-specific code,
/// and the badges matched the filesystem row for row. Even the awkward part transfers — Drive reports
/// `isDownloading == true` while its downloading *status* still reads `NotDownloaded`, the same lie
/// iCloud tells and the reason `status` consults the flag before the status.
@MainActor
final class CloudSyncStatusProvider {
    static let shared = CloudSyncStatusProvider()

    /// Posted when a directory's sync status changes, so every pane showing it re-renders. The
    /// directory rides in `userInfo` under `directoryKey`; panes ignore directories they aren't
    /// showing.
    static let didChangeNotification = Notification.Name("Dirnex.cloudSyncStatusDidChange")
    static let directoryKey = "directory"

    /// A burst of filesystem events collapses into one scan at the end of this window — a provider
    /// materializing a file lands as several events, as does a download finishing.
    private let debounceInterval: Duration = .milliseconds(300)
    /// The longest a visible snapshot may stay stale while changes keep arriving. Past this a
    /// request skips the debounce and runs now, so sustained churn (a folder mid-sync) still updates
    /// the badges instead of starving the trailing edge.
    private let maximumStaleness: TimeInterval = 2
    /// How many directories keep a cached snapshot. Panes are two and tabs are few — the same
    /// bargain `FinderTagProvider` strikes.
    private let cacheLimit = 8
    /// How long after a scan that found a transfer in flight to look again — see `scheduleFollowUp`,
    /// which explains why a filesystem event cannot answer this on its own. A second is fast enough
    /// that a finished download stops claiming to be downloading before anyone notices, and slow
    /// enough that a folder mid-sync costs one directory scan per second rather than a spin.
    private let followUpInterval: Duration = .seconds(1)
    /// The most consecutive follow-ups a directory gets before it must wait for a real event again.
    /// A minute of looking covers any transfer that is actually progressing; past that the provider
    /// is wedged or paused, and polling it forever would be a busy-wait on someone else's problem.
    private let followUpLimit = 60

    private var snapshots: [VFSPath: CloudSyncSnapshot] = [:]
    /// Cached directories in least-recently-used order, most recent last.
    private var usage: [VFSPath] = []
    private var lastRun: [VFSPath: Date] = [:]
    /// The paths to read for each directory, as of its most recent request — kept so a debounced or
    /// replayed run uses the *latest* listing rather than the one that happened to schedule it.
    private var requested: [VFSPath: [VFSPath]] = [:]
    /// The pending debounce timer per directory — cancelled and replaced by each new request.
    private var scheduled: [VFSPath: Task<Void, Never>] = [:]
    /// Directories with a scan in flight, and those whose changes arrived while it ran (so the
    /// snapshot we are about to store is already known to be stale and must be re-read once).
    private var running: Set<VFSPath> = []
    private var repeatRequested: Set<VFSPath> = []
    /// Consecutive follow-up scans per directory, so a wedged transfer cannot poll forever. Reset
    /// the moment a scan finds nothing in flight.
    private var followUps: [VFSPath: Int] = [:]

    // MARK: - Snapshots

    /// The snapshot already in hand for `directory`, or `nil` when none has been read yet.
    /// Synchronous and O(1) — this is what a pane calls while rendering rows.
    func cachedSnapshot(for directory: VFSPath) -> CloudSyncSnapshot? {
        snapshots[directory]
    }

    /// Ask for `directory`'s sync status to be brought up to date, reading `entries`. The first look
    /// runs immediately (a badge that arrives a third of a second after the folder reads as a
    /// glitch); later ones are rate-limited as described on the type.
    ///
    /// `entries` should be the **whole** listing, not just the visible rows: two panes on one folder
    /// can have different hidden/filter settings, and a scan of the narrower one would evict rows
    /// the other still shows — leaving a not-downloaded file looking local.
    func requestRefresh(for directory: VFSPath, entries: [VFSPath]) {
        requested[directory] = entries
        // "Have we ever run this?", not "do we have a snapshot?" — an all-synced cloud folder caches
        // an *empty* snapshot, and a directory we cannot read caches nothing; asking about the
        // snapshot would call every request its first and re-scan on every filesystem event, which
        // is precisely what this rate limiting exists to prevent.
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
        let snapshot = await CloudSyncScanner.scan(directory: directory, entries: entries)
        running.remove(directory)

        store(snapshot, for: directory)
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: self,
            userInfo: [Self.directoryKey: directory]
        )
        if repeatRequested.remove(directory) != nil {
            requestRefresh(for: directory, entries: requested[directory] ?? entries)
            return
        }
        scheduleFollowUp(for: directory, after: snapshot)
    }

    /// Keep looking while something is still moving.
    ///
    /// **This exists because a live run caught the badge stuck.** Every other refresh in this
    /// provider is driven by a filesystem event, and that is enough for a state the filesystem
    /// announces — a file evicted, a file materialized. It is *not* enough for a transfer: the last
    /// event of a download arrives while the file is still arriving, so the scan it triggers sees
    /// `isDownloading` and paints the blue arrow, and then nothing ever fires again. The download
    /// finishes, the attributes settle to "current", and the badge says "downloading…" until the
    /// user happens to navigate. Observed exactly that, on a real 3 MB file.
    ///
    /// So a snapshot with anything in flight asks itself one more time, a second later, until
    /// nothing is. The poll is bounded twice over: it only ever runs while a transfer is genuinely
    /// in progress in the directory on screen, and `followUpLimit` stops it from spinning forever on
    /// a transfer that is wedged (a paused provider, an upload with nowhere to go) — after which the
    /// next real event picks things up again.
    private func scheduleFollowUp(for directory: VFSPath, after snapshot: CloudSyncSnapshot) {
        guard snapshot.hasTransfersInFlight else {
            followUps[directory] = 0
            return
        }
        let count = followUps[directory, default: 0] + 1
        guard count <= followUpLimit else { return }
        followUps[directory] = count

        let interval = followUpInterval
        scheduled[directory]?.cancel()
        scheduled[directory] = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            await self?.run(directory)
        }
    }

    private func store(_ snapshot: CloudSyncSnapshot, for directory: VFSPath) {
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

/// One directory's sync status, keyed by the path it sits on.
///
/// **Only rows with something to say are in here.** An up-to-date file is absent, exactly as an
/// untagged file is absent from a `FinderTagSnapshot` — so a fully synced iCloud folder of thousands
/// caches an empty dictionary, which is both the common case and the one where a per-row entry would
/// buy nothing. It also means "absent" and "up to date" are the same answer to a renderer, which is
/// correct: both draw nothing.
struct CloudSyncSnapshot: Equatable {
    var statusByPath: [VFSPath: CloudSyncStatus]

    /// The status of one row, `nil` when it has nothing to report (or has not been scanned).
    func status(for path: VFSPath) -> CloudSyncStatus? {
        statusByPath[path]
    }

    /// Whether anything here is mid-transfer, and so will change without the filesystem saying so —
    /// the condition `CloudSyncStatusProvider.scheduleFollowUp` looks again on.
    var hasTransfersInFlight: Bool {
        statusByPath.values.contains(where: \.isTransfer)
    }
}

// MARK: - The scan

/// The attribute reads themselves. Split from the provider so the provider is nothing but cache and
/// scheduling and this is nothing but I/O — the same division `FinderTagProvider` draws around its
/// `getxattr`s and `GitStatusProvider` around its subprocess.
private enum CloudSyncScanner {
    /// Read every path's status off the main thread, or skip the directory wholesale when it isn't a
    /// cloud folder. The gate runs on the same background hop as the scan: it is a filesystem read
    /// like any other, and doing it on the main thread to "save a hop" would put a provider round
    /// trip in the way of every folder that opens.
    static func scan(directory: VFSPath, entries: [VFSPath]) async -> CloudSyncSnapshot {
        await Task.detached(priority: .userInitiated) {
            guard CloudSyncStorage.isCloudDirectory(directory) else {
                return CloudSyncSnapshot(statusByPath: [:])
            }
            var statusByPath: [VFSPath: CloudSyncStatus] = [:]
            for path in entries {
                // `attributes(at:)` throws only for a non-local path, and a local directory cannot
                // hold one; `try?` keeps the scan going over a row that vanished mid-scan.
                guard let status = try? CloudSyncStorage.attributes(at: path).status,
                      status.isNoteworthy else { continue }
                statusByPath[path] = status
            }
            return CloudSyncSnapshot(statusByPath: statusByPath)
        }.value
    }
}
