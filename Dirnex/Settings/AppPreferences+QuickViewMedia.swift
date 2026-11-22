import Foundation

/// Panels ▸ whether a movie or a sound starts playing as soon as Quick View has it up (PLAN.md §M42,
/// asked 2026-11-21). **On by default**, as Finder's Quick Look plays one. Off, it opens paused on its
/// first frame and waits for ⌘P, which is how the player shipped.
///
/// Whatever this says, a sound never outlives its file: stepping to another file, or closing Quick
/// View, stops the player (`QuickViewPreviewView.standDownMedia`).
///
/// Computed straight over `defaults`, as `confirmTransfers` is, for the same reason: the class file
/// sits at SwiftLint's file-length ceiling, and the surface asks each time a file goes up, so a
/// change applies from the next file with nobody having to listen.
extension AppPreferences {
    var quickViewAutoplayMedia: Bool {
        get { defaults.object(forKey: Keys.quickViewAutoplayMedia) as? Bool ?? true }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.quickViewAutoplayMedia)
        }
    }
}
