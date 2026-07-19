import CoreServices
import Foundation

/// Watches a single directory and fires `onChange` — coalesced by FSEvents' own
/// latency — whenever something under it changes, so a panel can re-list and refresh
/// live (PLAN.md §2 "FSEvents (per-directory, coalesced)", §M1 "panels refresh live").
///
/// The callback carries no payload: any event means "re-list this directory." The
/// panel hands the fresh snapshot to `Panel.setListing`, which re-anchors the cursor
/// and marks by identity (PLAN.md §6 "reapplies cursor by identity, not row index"),
/// so a live refresh never fights the selection.
///
/// Lifetime contract: the stream holds an *unretained* pointer back to this object
/// (a retained pointer would be a cycle that never stops watching), so `stop()` — run
/// automatically from `deinit` — must tear the stream down before the object is freed.
/// `FSEventStreamInvalidate` drains the dispatch queue, so no callback outlives it.
///
/// Not `Sendable` on purpose: the owner touches it from one actor and the C callback
/// reaches it only through the raw `info` pointer, reading the immutable `onChange`.
public final class DirectoryWatcher {
    private let onChange: @Sendable () -> Void
    private let queue: DispatchQueue
    private var stream: FSEventStreamRef?

    /// Begin watching `path` immediately. `latency` is FSEvents' coalescing window —
    /// bursts of changes within it collapse into one callback.
    public init(
        path: VFSPath,
        latency: TimeInterval = 0.15,
        queue: DispatchQueue = DispatchQueue(label: "com.dirnex.fsevents", qos: .utility),
        onChange: @escaping @Sendable () -> Void
    ) {
        self.onChange = onChange
        self.queue = queue
        start(path: path.path, latency: latency)
    }

    deinit {
        stop()
    }

    /// Stop watching. Idempotent, so reassigning or dropping the watcher is safe.
    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func start(path: String, latency: TimeInterval) {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        // A non-capturing closure so it bridges to the C function pointer; it recovers
        // the watcher from `info` and forwards to the immutable `onChange`.
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        let flags = UInt32(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }
}
