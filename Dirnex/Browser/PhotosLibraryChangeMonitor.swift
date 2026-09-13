import AppKit
import Photos

/// The Photos library's own change notification, turned into something a pane can wait on (PLAN.md
/// §M28 Slice 4).
///
/// A pane on the library used to re-list on the remote poll's clock, because the library answers
/// `isRemoteConnection`. It does not have to: PhotoKit tells any process holding the grant when the
/// library changed — measured 2026-09-13, an observer in another process heard all 51 changes
/// Photos.app made while an album fixture was built, each on a background thread — so a pane is
/// woken by the library the way a local pane is woken by FSEvents (`RemoteRefreshPolicy.trigger`).
///
/// **One observer for the process, counted rather than forwarded.** `generation` goes up once per
/// delivery, and a pane remembers the generation it last refreshed at. That is what lets a pane that
/// stood down while covered catch up when it is uncovered — it compares two numbers — where a pane
/// that could only hear deliveries live would miss every change made while nobody was looking.
///
/// **It never asks for access.** Registering an observer before the grant is decided is not
/// something to risk raising a system prompt over, so ``startIfPermitted()`` registers only once
/// access is already granted, and tries again when it might have become so: after the sidebar's own
/// prompt, and whenever the app comes back to the front (a grant made in System Settings).
@MainActor
final class PhotosLibraryChangeMonitor: NSObject {
    static let shared = PhotosLibraryChangeMonitor()

    /// How many library changes this process has heard. Only ever goes up.
    private(set) var generation = 0

    private var isRegistered = false
    private var subscribers: [UUID: AsyncStream<Int>.Continuation] = [:]
    private lazy var relay = PhotosLibraryChangeRelay(monitor: self)

    /// Internal rather than private so a test can drive a monitor of its own; the app uses
    /// ``shared``, which is the only one that ever registers with PhotoKit.
    override init() {
        super.init()
    }

    /// The number of streams still waiting on a change — for a test to see that a cancelled wait
    /// is forgotten.
    var subscriberCount: Int { subscribers.count }

    /// Register with PhotoKit, once, if the library may already be read.
    ///
    /// The first registration counts as a change of its own, and it is one: until it, the library
    /// could not be read at all, so every pane that listed it without access — a tab restored
    /// before the grant — has something new to learn.
    func startIfPermitted() {
        guard !isRegistered, PhotoKitLibrary.hasAccess else { return }
        PHPhotoLibrary.shared().register(relay)
        isRegistered = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        noteLibraryChanged()
    }

    /// Every generation from now on, as it is reached.
    ///
    /// Buffers only the newest, because a waiter wants to know *that* the library moved, never how
    /// many times: it re-reads ``generation`` when it wakes. Ends when the task iterating it is
    /// cancelled, which is how a pane that stops refreshing stops waiting.
    func changes() -> AsyncStream<Int> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Int.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.subscribers[id] = nil }
        }
        return stream
    }

    /// Count one change and wake everybody waiting.
    func noteLibraryChanged() {
        generation += 1
        for subscriber in subscribers.values {
            subscriber.yield(generation)
        }
    }

    /// A grant made in System Settings while the app was in the background reaches no callback, so
    /// coming back to the front is the moment to find out.
    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        startIfPermitted()
    }
}

/// The `PHPhotoLibraryChangeObserver` itself, apart from the monitor because PhotoKit calls it on a
/// background thread (measured) and the monitor is the main actor's.
private final class PhotosLibraryChangeRelay: NSObject, PHPhotoLibraryChangeObserver {
    private weak var monitor: PhotosLibraryChangeMonitor?

    init(monitor: PhotosLibraryChangeMonitor) {
        self.monitor = monitor
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak monitor] in
            monitor?.noteLibraryChanged()
        }
    }
}
