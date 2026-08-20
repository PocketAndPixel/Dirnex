import AppKit
import DirnexCore

/// Which volumes are unlocked vaults right now — the live half of ``VaultPrivacy`` (PLAN.md §M19).
///
/// The rule the core states needs a list of mount points, and the only authority for that is
/// `hdiutil`, which costs a subprocess (measured at 12–14 ms). That is nothing once, and far too
/// much on the path it has to guard: `FrecencyStore.recordVisit` runs on **every navigation**, and
/// a pane's tabs are written whenever the session is saved. So the answer is cached and kept current
/// by events rather than re-asked per question.
///
/// Three things keep it current, and the first is the one that matters:
///
/// - **Dirnex's own unlock and lock tell it directly**, synchronously, at the moment they know. That
///   closes the window an event-driven cache would otherwise have — a navigation landing between the
///   attach and the notification would be recorded before anything knew a vault was open.
/// - `NSWorkspace`'s mount/unmount notifications cover a vault unlocked **somewhere else** (Disk
///   Utility, or `hdiutil` in Terminal), which Dirnex has no other way to hear about.
/// - The saved-vault list changing, since a newly saved vault may already be attached.
///
/// A stale answer is only ever wrong in one direction worth thinking about: an unlocked vault this
/// has not heard of yet is a path that *could* reach the frecency index. Locking purges the index of
/// anything under the mount point (`BrowserWindowController.lock`), which is what makes that window
/// close behind itself rather than leaving residue.
@MainActor
final class VaultMounts: NSObject {
    static let shared = VaultMounts()

    /// The mount points of every unlocked vault, as `hdiutil` spells them.
    private(set) var mountPoints: [String] = []

    override private init() {
        super.init()
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            self, selector: #selector(volumesChanged), name: NSWorkspace.didMountNotification,
            object: nil
        )
        workspace.addObserver(
            self, selector: #selector(volumesChanged), name: NSWorkspace.didUnmountNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(volumesChanged), name: VaultStore.didChangeNotification,
            object: nil
        )
        refresh()
    }

    /// Touch the singleton at launch so it is observing before the first navigation, rather than
    /// being built lazily by the first question — which would answer that one question with an empty
    /// list.
    static func start() { _ = shared }

    // MARK: - Asking

    /// Whether `path` is inside an unlocked vault, and so must stay out of anything Dirnex remembers
    /// without being asked.
    func contains(_ path: VFSPath) -> Bool {
        VaultPrivacy.isInside(path, mountPoints: mountPoints)
    }

    func contains(_ path: String) -> Bool {
        VaultPrivacy.isInside(path, mountPoints: mountPoints)
    }

    // MARK: - Keeping current

    /// A vault just opened at `mountPoint`. Recorded immediately, before the notification arrives.
    func note(mountPoint: String) {
        guard !mountPoint.isEmpty, !mountPoints.contains(mountPoint) else { return }
        mountPoints.append(mountPoint)
    }

    /// A vault at `mountPoint` just locked.
    func forget(mountPoint: String) {
        mountPoints.removeAll { VaultLocation.normalizedPath($0) == VaultLocation.normalizedPath(
            mountPoint
        ) }
    }

    /// Re-ask `hdiutil`. Off the main actor, since it spawns.
    func refresh() {
        let vaults = VaultStore.load()
        Task { [weak self] in
            let attached = await BlockingWork.run(qos: .utility) {
                DiskImageRunner.attachedImages()
            }
            self?.mountPoints = VaultPrivacy.mountPoints(of: vaults, attached: attached)
        }
    }

    @objc private func volumesChanged() {
        refresh()
    }
}
