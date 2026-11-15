import Foundation
import UniformTypeIdentifiers

/// Which rows a Quick View slideshow stops on, which one it goes to next, and how long it may wait on
/// each (PLAN.md §M39 ▸ Slice 16). The timer and the page turn are the app's; this is every decision
/// they need, with no I/O.
///
/// The slideshow walks the pane's cursor, so the file list stays the navigation (M11's reason for
/// leaving it out, answered rather than overruled): the rows it stops on are the pane's own displayed
/// rows, in their order, filtered and sorted as the user has them.
public enum Slideshow {
    /// Seconds per image when nothing has been set: Preview's own value, read out of its binary on
    /// 2026-11-15 (`_startAutoplayTimer` schedules a repeating 5.0 s `NSTimer`).
    public static let defaultInterval = 5

    /// What Settings ▸ Panels offers. One second is the fastest a person can still look at each
    /// picture; a minute is past where a slideshow stops being one.
    public static let intervalRange = 1...60

    /// `seconds` brought into ``intervalRange``. A defaults domain is hand-editable, so the stored
    /// value is clamped on the way in as well as when Settings writes it.
    public static func clampedInterval(_ seconds: Int) -> Int {
        min(max(seconds, intervalRange.lowerBound), intervalRange.upperBound)
    }

    /// Whether the slideshow stops on `entry`: a file, or a link to one, whose name says it is an
    /// image.
    ///
    /// Decided by the **name**, as the row's icon is (`RowIcon.fileType`): the rows it skips may be on
    /// a server or inside an archive, and choosing the next stop must never cost a request. The type
    /// test is the preview's own (`QuickViewPreviewView.isImage`, which conforms the type to
    /// `public.image`), so a row the slideshow stops on is one the preview draws as a picture: camera
    /// RAW, SVG and HEIC included, PDF and video not. A GoPro RAW is named by its extension alone,
    /// since macOS gives `.gpr` a placeholder type that conforms to nothing.
    public static func isSlide(_ entry: FileEntry) -> Bool {
        switch entry.kind {
        case .file: break
        case .symlink where entry.symlinkTargetKind == .file: break
        default: return false
        }
        if GoProRAW.namesGoProRAW(entry.name) { return true }
        // Not lowercased: `UTType` matches an extension in any case (probed `JPG`, `HEIC`, `NEF`), and
        // a lowercasing control left every test green.
        let ext = (entry.name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image)
    }

    /// Where a slideshow opens: on `cursor` when that row is an image, so the picture already on
    /// screen gets its full turn, and otherwise on the next image after it, wrapping past the end.
    /// `nil` when no row is an image, or there are no rows; a `nil` cursor (the `..` row) starts from
    /// the top.
    public static func firstSlide(from cursor: Int?, in entries: [FileEntry]) -> Int? {
        if let cursor, entries.indices.contains(cursor), isSlide(entries[cursor]) { return cursor }
        return nextSlide(after: cursor ?? -1, in: entries)
    }

    /// The image after `cursor`, wrapping past the last row to the first, since a slideshow loops
    /// until it is stopped (Oleg's call, 2026-11-15). `cursor` itself when it is the only image, and
    /// `nil` when there is none. A `cursor` outside the rows counts from before the first.
    public static func nextSlide(after cursor: Int, in entries: [FileEntry]) -> Int? {
        guard !entries.isEmpty else { return nil }
        let start = entries.indices.contains(cursor) ? cursor : -1
        for offset in 1...entries.count {
            let index = (start + offset) % entries.count
            if isSlide(entries[index]) { return index }
        }
        return nil
    }
}
