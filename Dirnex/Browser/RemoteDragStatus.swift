import AppKit
import DirnexCore

/// The line drawn under a dragged row while its bytes come down.
///
/// On the drag image because that is the one thing still in front of somebody holding a drag over
/// another app. It says what the receiving app cannot: that the file is on its way, and, when that app
/// has already been told there was nothing, that it has to be left and come back to.
@MainActor
final class RemoteDragStatus {
    private let session: NSDraggingSession
    /// The drag image as AppKit made it, so a line can be added to it and taken away again.
    private var original: [NSDraggingImageComponent]?
    private var shown: String?

    private static let componentKey = NSDraggingItem.ImageComponentKey("app.dirnex.dragStatus")

    init(session: NSDraggingSession) {
        self.session = session
    }

    /// Show `text` under the first row's image, or nothing. Redraws only when the text has changed.
    func show(_ text: String?) {
        guard text != shown else { return }
        shown = text
        session.enumerateDraggingItems(
            options: [],
            for: nil,
            classes: [NSPasteboardItem.self],
            searchOptions: [:]
        ) { item, index, stop in
            guard index == 0 else {
                stop.pointee = true
                return
            }
            let base = self.original ?? item.imageComponents ?? []
            self.original = base
            let line = text.map(Self.component)
            item.imageComponentsProvider = { line.map { base + [$0] } ?? base }
        }
    }

    private static func component(showing text: String) -> NSDraggingImageComponent {
        let label = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
            .foregroundColor: NSColor.white
        ])
        let size = NSSize(
            width: ceil(label.size().width) + 16,
            height: ceil(label.size().height) + 6
        )
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill(
            )
            label.draw(at: NSPoint(x: 8, y: 3))
            return true
        }
        let component = NSDraggingImageComponent(key: componentKey)
        component.contents = image
        // Below the row, which is what the frame's origin is the corner of.
        component.frame = NSRect(x: 0, y: -(size.height + 3), width: size.width, height: size.height)
        return component
    }

    // MARK: - The wording

    /// How far a download has got, with a percentage wherever the listing gave the sizes and the
    /// transfer has said anything yet. Not "0%", which reads as stuck: SFTP's first count arrives well
    /// into a slow file (measured, still nothing a second past a 3 s hold on a 5.5 s transfer).
    static func downloading(moved: Int64, of total: Int64?) -> String {
        guard let total, total > 0, moved > 0 else {
            return String(
                localized: "Downloading…",
                comment: "Under a file being dragged out of a server: how much has arrived isn't known yet."
            )
        }
        let percent = Int(min(moved, total) * 100 / total)
        return String(
            localized: "Downloading \(percent)%",
            comment: "Under a file being dragged out of a server; %lld is how much of it has arrived."
        )
    }

    /// The file is here, and the app under the pointer has to be told again.
    static var ready: String {
        String(
            localized: "Ready: move out and back in",
            comment: """
            Under a file being dragged out of a server, once it has downloaded: the app under the \
            pointer only notices if the pointer leaves its window and comes back.
            """
        )
    }

    static var failed: String {
        String(
            localized: "Download failed",
            comment: "Under a file being dragged out of a server, when it could not be downloaded."
        )
    }

    /// Under a member being dragged out of an archive. No percentage: an extraction reports nothing
    /// until a member is out, and the usual one is out before this could be drawn.
    static var extracting: String {
        String(
            localized: "Extracting…",
            comment: "Under a file being dragged out of an archive to another app, while it is extracted."
        )
    }

    static var extractionFailed: String {
        String(
            localized: "Couldn’t extract",
            comment: "Under a file being dragged out of an archive, when it could not be extracted."
        )
    }

    /// Under a folder being dragged to another app, while it is made into the zip that app is handed.
    /// No percentage, for the reason extraction has none: the usual folder is done before it is drawn.
    static var compressing: String {
        String(
            localized: "Compressing…",
            comment: """
            Under a folder being dragged to another app, while Dirnex makes the zip that app is \
            handed in the folder's place.
            """
        )
    }

    static var compressionFailed: String {
        String(
            localized: "Couldn’t compress",
            comment: """
            Under a folder being dragged to another app, when the zip of it could not be made.
            """
        )
    }
}
