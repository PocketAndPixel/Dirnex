import Foundation

/// How ``LocalBackend`` actually moves an item to the Trash (PLAN.md §M26).
///
/// A seam rather than a call, for the reason the archive and transport work already needed one: the
/// only spelling that *works* lives in AppKit, and this package is headless. `LocalBackend` keeps
/// every decision — the already-in-a-trash refusal, the Trash-less-volume refusal
/// ``LocalBackend/trashFailure(_:path:)`` reads back, the landing path a `DeletePass.Restoration`
/// needs — and hands the one byte-touching step to whoever was injected.
///
/// **`FileManager.trashItem` refuses any item inside a File Provider domain**, which is every
/// Dropbox, OneDrive, Box, Google Drive and iCloud Drive file. Measured 2026-08-31: it throws
/// `NSCocoaErrorDomain` **513** with **no underlying POSIX errno**, while the same process — at the
/// instant of the throw — can `open` the file, `rename` it in place, `rename` it into `~/.Trash`
/// and read `~/.Trash`. So nothing was refused underneath and no grant the user can reach is
/// involved: `tccutil reset FileProviderDomain` changed nothing, macOS never prompts, and no TCC
/// service is consulted during the call.
///
/// **It depends on how the app was launched, which is why it shipped.** Launched from a shell the
/// same binary trashes fine (2/2); launched by LaunchServices — the Dock, Finder, `open` — it fails
/// (2/2). A shell-launched app inherits the launching process as its TCC *responsible* process, so
/// a developer running from a terminal borrows that process's Full Disk Access and sees a working
/// feature. Nothing automated can see it: the suites are green, the pane lists the folder, and only
/// F8 from a normally launched app shows it.
///
/// The app therefore injects ``WorkspaceTrashPerformer`` (`NSWorkspace.recycle`), which succeeds in
/// exactly that context on all five domains, writes the `ptbL`/`ptbN` pair so **Put Back keeps
/// working**, and sends an iCloud item to that container's own trash the way Finder does.
public protocol TrashPerformer: Sendable {
    /// Move `url` to the Trash it belongs to.
    ///
    /// - Returns: where the item landed, or `nil` when the performer cannot say. A `nil` is not a
    ///   failure — it costs the caller an undo record, not correctness — so a performer that knows
    ///   the landing URL must return it.
    /// - Throws: whatever the platform reported, untranslated. `LocalBackend` maps it, because the
    ///   mapping is a decision (a Trash-less volume is not a failure) and decisions stay in the core.
    func moveToTrash(_ url: URL) throws -> URL?
}

/// `FileManager.trashItem`, the platform's own answer — and the one the note above measures as
/// unable to trash anything inside a File Provider domain.
///
/// Kept as the default so `LocalBackend()` stays constructible in tests and in callers that never
/// trash, and never used by the app, which injects ``WorkspaceTrashPerformer`` at every site. It is
/// deliberately *not* a fallback the shipping path can reach: two routes differing only by which one
/// macOS happens to refuse is the shape this codebase keeps paying for, and there is no case this
/// one handles better.
public struct FileManagerTrashPerformer: TrashPerformer {
    public init() {}

    public func moveToTrash(_ url: URL) throws -> URL? {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        return resultingURL as URL?
    }
}
