import DirnexCore
import Foundation

/// Images that were renamed or moved **while attached**, and the paths `hdiutil` is consequently
/// still reporting them under (PLAN.md §M19).
///
/// Probed on macOS 26, and the reason this type exists at all: renaming a mounted `.sparsebundle`
/// succeeds, the volume stays mounted, and `hdiutil info` goes on naming the image by the path it
/// had when it was attached — **forever**, until it is detached. There is nothing else in the info
/// plist to match on; it carries no inode, no device id for the image file, only `image-path`.
///
/// So once Dirnex follows the move in its saved list, every "is this vault unlocked?" question —
/// asked by path — starts answering *no* for a vault that is plainly mounted: the row draws a shut
/// padlock, the eject button disappears, and Lock becomes unreachable from the app. Nothing is
/// damaged (measured: attaching the same image under its new name exits 0, mounts nothing extra, and
/// hands back the existing mount point), but the app would be visibly lying about a state the user
/// can see in Finder.
///
/// One `hdiutil` answer is rewritten on the way out of ``DiskImageRunner/attachedImages()``, which is
/// the single place that answer is produced — so the sidebar, the Lock command, the privacy rule and
/// the unlock funnel are all corrected at once, with no API of theirs changed and no chance of one
/// site being missed.
///
/// **The applies-only-when-stale rule is what makes this need no cleanup.** An alias is honored only
/// while the path `hdiutil` reports is *missing from disk*, which is precisely the condition a
/// renamed-while-attached image creates. If something later occupies that path again the alias stops
/// applying on its own, so there is no expiry to get wrong and no way for a stale entry to
/// misattribute somebody else's disk image to a vault.
final class MovedVaultImages: @unchecked Sendable {
    static let shared = MovedVaultImages()

    /// Resolved path `hdiutil` reports → resolved path the image actually lives at now.
    private var aliases: [String: String] = [:]
    private let lock = NSLock()

    private init() {}

    /// A vault's image just moved from `old` to `new` while it was attached.
    ///
    /// Chained rather than appended: after a second rename `hdiutil` is *still* reporting the
    /// original path, so what changes is where that path now leads, not the key. Recording a fresh
    /// `old → new` pair each time would leave the first alias pointing at a file that has moved on
    /// again, and the second keyed on a path `hdiutil` never mentions.
    func note(movedFrom old: String, to new: String) {
        let from = VaultLocation.normalizedPath(old)
        let to = VaultLocation.normalizedPath(new)
        lock.lock()
        defer { lock.unlock() }
        if let reported = aliases.first(where: { $0.value == from })?.key {
            aliases[reported] = to
        } else {
            aliases[from] = to
        }
    }

    /// Where the image `hdiutil` reports at `reportedPath` actually is, or `nil` if that path is
    /// not one we know to be stale.
    func currentPath(forReported reportedPath: String) -> String? {
        let key = VaultLocation.normalizedPath(reportedPath)
        lock.lock()
        defer { lock.unlock() }
        guard let moved = aliases[key], moved != key else { return nil }
        return moved
    }

    /// Rewrite `hdiutil`'s answer so every caller sees an image where it now lives.
    ///
    /// The existence check is the whole safety story (see the type's note), and it is cheap next to
    /// the subprocess whose output this is correcting.
    func resolving(_ images: [DiskImageMount.AttachedImage]) -> [DiskImageMount.AttachedImage] {
        images.map { image in
            guard let moved = currentPath(forReported: image.imagePath),
                  !FileManager.default.fileExists(atPath: image.imagePath)
            else { return image }
            return image.relocated(to: moved)
        }
    }

    /// Testing seam: drop everything remembered, so one test's aliases cannot reach another's.
    func forgetAll() {
        lock.lock()
        defer { lock.unlock() }
        aliases.removeAll()
    }
}
