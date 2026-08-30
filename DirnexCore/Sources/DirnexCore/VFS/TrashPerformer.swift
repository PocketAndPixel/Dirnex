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
/// **`NSWorkspace.recycle` is not the way out, and the run that said it was is the lesson.** It was
/// measured succeeding in the failing context on all five domains — and that measurement was
/// contaminated by the diagnostic probe above it, which had renamed each item out to `~/.Trash` and
/// straight back before `recycle` was asked, detaching it from its provider. Asked with no probe in
/// front of it, `recycle` fails with the byte-identical `NSCocoaErrorDomain` 513: it wraps the same
/// `trashItem`. Re-adding the bounce flips it back, 1/1 each way.
///
/// So the shipping performer is ``ProviderAwareTrashPerformer``, which routes on where the item
/// lives: `FileManager.trashItem` wherever it works, and the rename macOS would have made — into
/// the same trash, verified by a `stat` — for an item inside a domain. It is core rather than app
/// code because nothing in that answer is AppKit, which is what §2 asks for once the byte-touching
/// step is expressible headlessly.
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
/// Still the right answer for every item *outside* a provider domain, and still what runs there:
/// ``ProviderAwareTrashPerformer`` delegates to it rather than replacing it, so an ordinary delete
/// keeps Finder's destination, Finder's collision naming and Finder's `ptbL`/`ptbN` **Put Back**
/// record — none of which this package can write. What it is deliberately *not* is a fallback the
/// provider route can reach: two routes differing only by which one macOS happens to refuse is the
/// shape this codebase keeps paying for, so the choice is made up front from the path.
public struct FileManagerTrashPerformer: TrashPerformer {
    public init() {}

    public func moveToTrash(_ url: URL) throws -> URL? {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        return resultingURL as URL?
    }
}
