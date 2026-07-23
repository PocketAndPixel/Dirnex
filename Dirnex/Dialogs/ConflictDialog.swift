import AppKit
import DirnexCore
import QuickLookThumbnailing

/// Total Commander's rich per-file conflict dialog (PLAN.md §M2 "Conflict engine"): when a
/// copy or move would overwrite an existing item, show the incoming and existing items side
/// by side — thumbnail, name, size, modification date, with the newer one flagged — and let
/// the user choose Replace / Keep Both / Skip / Replace If Newer, optionally applying that
/// choice to every remaining conflict.
///
/// Presented as a sheet on the pane's window; the engine's resolver (`ConflictPrompter`)
/// awaits the answer while its copy thread is parked. Full text diffing is still deferred —
/// the thumbnails already give images real previews and text files a content peek.
@MainActor
enum ConflictDialog {
    /// Present the dialog for one conflict and return the chosen resolution plus whether the
    /// user asked to apply it to every remaining conflict in this operation.
    static func present(
        _ context: ConflictContext,
        in window: NSWindow?
    ) async -> (resolution: ConflictResolution, applyToAll: Bool) {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        // Fetch both thumbnails before showing the sheet so it appears fully rendered.
        async let sourceThumbnail = thumbnail(for: context.source, scale: scale)
        async let existingThumbnail = thumbnail(for: context.existing, scale: scale)
        let accessory = ConflictComparisonView(
            context: context,
            sourceThumbnail: await sourceThumbnail,
            existingThumbnail: await existingThumbnail
        )

        let alert = NSAlert()
        alert.alertStyle = .warning
        let folder = context.existing.path.parent?.lastComponent ?? ""
        alert.messageText = String(
            localized: "“\(context.source.name)” already exists in “\(folder)”"
        )
        alert.informativeText = String(
            localized: "An item with the same name is already here. Choose how to resolve it."
        )
        alert.accessoryView = accessory
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Apply to all remaining conflicts")

        // Order (and response mapping) mirror the earlier single-policy prompt for parity.
        alert.addButton(withTitle: String(localized: "Replace"))
        alert.addButton(withTitle: String(localized: "Keep Both"))
        alert.addButton(withTitle: String(localized: "Skip"))
        alert.addButton(withTitle: String(localized: "Replace If Newer"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let response = await runAlert(alert, in: window)
        let applyToAll = alert.suppressionButton?.state == .on
        return (resolution(for: response), applyToAll)
    }

    /// Show the alert as a sheet on the window, or app-modal if there is none (window closed
    /// mid-operation — a rare fallback, never the common path).
    private static func runAlert(
        _ alert: NSAlert,
        in window: NSWindow?
    ) async -> NSApplication.ModalResponse {
        guard let window else { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    /// The fourth `NSAlert` button ("Replace If Newer"); AppKit only names the first three,
    /// the rest counting up from `.alertThirdButtonReturn`.
    private static let fourthButtonReturn = NSApplication.ModalResponse(
        rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1
    )

    private static func resolution(for response: NSApplication.ModalResponse) -> ConflictResolution {
        switch response {
        case .alertFirstButtonReturn: .overwrite
        case .alertSecondButtonReturn: .keepBoth
        case .alertThirdButtonReturn: .skip
        case fourthButtonReturn: .overwriteIfNewer
        default: .cancel // fifth button ("Cancel") or sheet dismissal
        }
    }

    // MARK: - Thumbnails

    /// A Quick Look thumbnail for an item (images preview as images, text files as a content
    /// peek), falling back to the workspace file icon when Quick Look can't render one.
    private static func thumbnail(for entry: FileEntry, scale: CGFloat) async -> NSImage {
        let url = URL(fileURLWithPath: entry.path.path)
        let fallback = NSWorkspace.shared.icon(forFile: url.path)
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 72, height: 72),
            scale: scale,
            representationTypes: .thumbnail
        )
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            return rep.nsImage
        }
        return fallback
    }
}
