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

    /// FSEvents' coalescing window: a burst of changes within it collapses into one callback.
    ///
    /// Named rather than left as a default argument because a *second* thing now has to wait the
    /// same length. Each edited copy is watched through its own stream, so a script rewriting forty
    /// files produces forty independent callbacks — clustered within about this long of each other,
    /// since that is what each stream is holding them for. Anything gathering those into one batch
    /// is therefore waiting out the delivery mechanism's own window rather than picking a number,
    /// which is the difference between a constant with a reason and a guess
    /// (`BrowserWindowController+WriteBackBatch`).
    public static let coalescingWindow: TimeInterval = 0.15

    /// Begin watching `path` immediately. `latency` is FSEvents' coalescing window —
    /// bursts of changes within it collapse into one callback.
    public init(
        path: VFSPath,
        latency: TimeInterval = DirectoryWatcher.coalescingWindow,
        queue: DispatchQueue = DispatchQueue(label: "com.dirnex.fsevents", qos: .utility),
        onChange: @escaping @Sendable () -> Void
    ) {
        self.onChange = onChange
        self.queue = queue
        start(paths: [path.path], latency: latency)
    }

    /// Watch **several** directories through one stream, firing the same `onChange` for a change
    /// under any of them — what a merged listing needs (PLAN.md §M8 Trash, §M9 iCloud Drive).
    ///
    /// The Trash is not a directory: it is `~/.Trash`, iCloud's own trash, and every mounted
    /// volume's, presented as one place. A pane showing it therefore has nothing to watch by path,
    /// and until now watched nothing at all — so a file trashed in Finder didn't appear until the
    /// row was clicked again. FSEvents takes an array natively, so this costs one stream, not one
    /// per source.
    ///
    /// An empty `paths` is a watcher that never fires rather than an error: a merge with no sources
    /// (no trash exists yet, iCloud Drive is off) has nothing to notice.
    public init(
        paths: [VFSPath],
        latency: TimeInterval = DirectoryWatcher.coalescingWindow,
        queue: DispatchQueue = DispatchQueue(label: "com.dirnex.fsevents", qos: .utility),
        onChange: @escaping @Sendable () -> Void
    ) {
        self.onChange = onChange
        self.queue = queue
        guard !paths.isEmpty else { return }
        start(paths: paths.map(\.path), latency: latency)
    }

    /// Watch one **file**, firing `onChange` whenever the bytes at that path change — what a pane
    /// browsing an archive needs, since its rows are read from a `.zip` rather than from a directory
    /// (PLAN.md ▸ Still open, "an archive pane does not notice its own file changing").
    ///
    /// `kFSEventStreamCreateFlagFileEvents` is the whole difference and it is load-bearing rather
    /// than a tuning choice. Measured 2026-09-01 against a real stream, a file path *without* it
    /// reports only the path itself appearing and disappearing: a delete-and-repack fired, a rename
    /// fired, and an archive **rewritten in place** fired `0` times — which is precisely the case
    /// ``ArchiveIdentity``'s size and modification-time fields exist for, and the quiet direction
    /// (the pane goes on listing members that are no longer in the file). With the flag, all four
    /// shapes fire.
    ///
    /// Two more properties from the same run decide this over watching the archive's enclosing
    /// directory, which also sees everything. The stream is keyed to the **path**, not to an inode,
    /// so it survives the file being deleted and recreated under the same name and goes on
    /// reporting writes to the new one — the ordinary way to redo an archive. And it stays silent
    /// for siblings: a sibling created, written five times, and written again after the repack
    /// produced `0` callbacks here against one apiece on the directory. So a pane sitting inside an
    /// archive in a busy folder pays nothing for the churn around it.
    public init(
        filePath: String,
        latency: TimeInterval = DirectoryWatcher.coalescingWindow,
        queue: DispatchQueue = DispatchQueue(label: "com.dirnex.fsevents", qos: .utility),
        onChange: @escaping @Sendable () -> Void
    ) {
        self.onChange = onChange
        self.queue = queue
        start(paths: [filePath], latency: latency, fileEvents: true)
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

    private func start(paths: [String], latency: TimeInterval, fileEvents: Bool = false) {
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
        // File events only where the watched path *is* a file (see `init(filePath:)`): asking for
        // them over a directory would report one callback per file instead of one per directory,
        // multiplying an event rate this app already treats as a cost (docs/NOTES.md ▸ AppKit, the
        // recursive-stream measurement).
        var flags = UInt32(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        if fileEvents { flags |= UInt32(kFSEventStreamCreateFlagFileEvents) }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
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
