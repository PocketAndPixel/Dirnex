import AppKit
import DirnexCore

/// The cloud sync badge that rides at the right edge of a file's name (PLAN.md §M6 "iCloud/provider
/// sync status"). Lives inside `FileCellView`, to the right of the tag dots.
///
/// **The placement is Finder's, and it was measured rather than guessed** (a file was evicted with
/// `brctl evict`, opened in Finder's list view, and zoomed into — the same method the tag dots'
/// reverse stacking came from). Two things that fell out of looking:
///
/// - **The badge sits at the trailing edge of the *name* column**, not in a column of its own —
///   which is what the plan's "sync-status column" turned out to mean in practice, exactly as the
///   tags "column" did.
/// - **When a file is both tagged and not downloaded, Finder draws the dots first and the cloud
///   outermost.** So this view is the last thing in the cell, after `TagDotsView`.
///
/// An SF Symbol rather than a hand-drawn path (unlike the dots, where the content *is* the colour):
/// the cloud-with-arrow glyph is a system idiom people already read, and Apple ships it.
final class SyncBadgeView: NSView {
    /// The row's status, or `nil` for a file with nothing to report — which is every ordinary file
    /// and every synced one. Setting it resizes and redraws.
    var status: CloudSyncStatus? {
        didSet {
            guard status != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private let glyphHeight: CGFloat = 15
    /// Breathing room between the tag dots and the cloud, on the badge's own leading edge.
    private let leadingGap: CGFloat = 3

    /// The width the badge needs, so Auto Layout gives the name exactly the room it doesn't — and
    /// **all** of it when there is no badge, which is the overwhelmingly common row. This is what
    /// keeps the feature from costing anything at all outside a cloud folder.
    ///
    /// Taken from the glyph rather than assumed square, because the symbols aren't: measured at this
    /// configuration, `icloud.and.arrow.down` is 19×18 and `xmark.icloud` 19×14.
    override var intrinsicContentSize: NSSize {
        guard let status, let image = SyncBadgeStyle.image(for: status) else {
            return NSSize(width: 0, height: glyphHeight)
        }
        return NSSize(
            width: image.size.width + leadingGap,
            height: max(glyphHeight, image.size.height)
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let status, let image = SyncBadgeStyle.image(for: status) else { return }
        // At its natural size rather than scaled into a box of our choosing: the box was square and
        // the symbols are not, and — the reason this was too small to read — a box smaller than the
        // symbol silently shrank it. The configuration's point size is now the only size control.
        let size = image.size
        let rect = NSRect(
            x: bounds.maxX - size.width,
            y: ((bounds.height - size.height) / 2).rounded(),
            width: size.width,
            height: size.height
        )
        image.draw(in: rect)
    }

    /// What this badge is saying, in words — the cell hands it to the row's tooltip. A cloud glyph
    /// is recognisable but not self-explaining, and "not downloaded" versus "failed" is exactly the
    /// distinction a small monochrome icon is worst at.
    var accessibilityText: String? {
        status.map(SyncBadgeStyle.label(for:))
    }
}

/// How a sync status is painted and named. The core picks the *state*; this picks the pixels and the
/// words — the same core-decides-meaning / app-decides-look split as `GitStatusStyle` and
/// `TagDotStyle`.
enum SyncBadgeStyle {
    /// The glyph for a status, tinted. System symbols and system colours throughout, so the badge
    /// tracks the user's appearance and accessibility settings rather than freezing literals.
    ///
    /// `.upToDate` never reaches here — it draws nothing, and the snapshot doesn't even store it —
    /// but it is answered for completeness rather than crashed on.
    static func image(for status: CloudSyncStatus) -> NSImage? {
        guard let symbol = NSImage(
            systemSymbolName: symbolName(for: status),
            accessibilityDescription: label(for: status)
        ) else { return nil }
        // Sized against the 16pt file icon at the other end of the row rather than against the
        // 13pt name text: a monochrome cloud at text weight reads as a smudge at a glance, and this
        // badge only ever appears on the rows where it is the point.
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color(for: status)]))
        return symbol.withSymbolConfiguration(configuration)
    }

    private static func symbolName(for status: CloudSyncStatus) -> String {
        switch status {
        case .upToDate: "icloud"
        // The hollow cloud-and-down-arrow Finder itself shows for a placeholder.
        case .notDownloaded: "icloud.and.arrow.down"
        case .downloading: "arrow.down.circle"
        case .uploading: "icloud.and.arrow.up"
        case .conflicted: "exclamationmark.icloud"
        case .failed: "xmark.icloud"
        case .excluded: "icloud.slash"
        }
    }

    private static func color(for status: CloudSyncStatus) -> NSColor {
        switch status {
        // The quiet states are the *normal* ones — a placeholder is not a problem, and a file on its
        // way up is not either. Secondary keeps them legible without turning a cloud folder into a
        // wall of colour, which is the failure mode Finder avoids by drawing nothing at all here.
        case .upToDate, .notDownloaded, .excluded: .secondaryLabelColor
        case .downloading, .uploading: .systemBlue
        case .conflicted: .systemOrange
        case .failed: .systemRed
        }
    }

    /// The tooltip text. Phrased as what is true of the file, not as an error code.
    ///
    /// Each literal sits *at* its `String(localized:)` call rather than being switched into one, so
    /// the extractor sees it — a `String(localized: someLabel)` over a variable extracts nothing
    /// (docs/NOTES.md). The badge rides on every cloud row, so this is permanently on screen.
    static func label(for status: CloudSyncStatus) -> String {
        switch status {
        case .upToDate:
            String(
                localized: "Up to date",
                comment: "Cloud sync badge tooltip: the local file matches the cloud."
            )
        case .notDownloaded:
            String(
                localized: "Not downloaded — stored in the cloud",
                comment: "Cloud sync badge tooltip: a placeholder whose bytes are not local yet."
            )
        case .downloading:
            String(
                localized: "Downloading…",
                comment: "Cloud sync badge tooltip: the file is being fetched from the provider."
            )
        case .uploading:
            String(
                localized: "Waiting to upload",
                comment: "Cloud sync badge tooltip: local changes have not reached the cloud yet."
            )
        case .conflicted:
            String(
                localized: "Sync conflict — resolve in Finder",
                comment: "Cloud sync badge tooltip: two versions diverged; Finder owns the fix."
            )
        case .failed:
            String(
                localized: "Sync failed",
                comment: "Cloud sync badge tooltip: the provider gave up on a transfer."
            )
        case .excluded:
            String(
                localized: "Excluded from sync",
                comment: "Cloud sync badge tooltip: the file is deliberately not synced."
            )
        }
    }
}
