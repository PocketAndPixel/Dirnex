import AppKit
import DirnexCore
import PDFKit
import UniformTypeIdentifiers

/// Quick View's office-document backend: Word, Excel, PowerPoint, Pages, Numbers and Keynote files,
/// converted by macOS's own Quick Look generators and shown in-process (follow-on, 2026-09-14).
///
/// These used to reach the out-of-process `QLPreviewView`, and a user reported what that costs: a
/// `.docx` showed one page with arrows that could not be clicked, a spreadsheet was a thumbnail too
/// small to read, and nothing could be zoomed or selected. The surface has to swallow the mouse for
/// that view (docs/NOTES.md), so none of it was fixable there. The generator's *output* is ordinary
/// data, though — ``DirnexCore/QuickLookPreviewBundle`` records what it is and why this route — so the
/// app has `qlmanage` write it and shows it on the two surfaces that already do everything a document
/// needs: Office pages in the web view (scroll, pinch zoom, select, a workbook's sheet tabs), iWork
/// pages merged into one PDF (scroll, zoom, select, find).
///
/// Every failure falls back to exactly what these files got before: Quick Look's own view.
extension QuickViewPreviewView {
    /// Show `url` converted, standing the other backends down.
    ///
    /// Asynchronous for the reason every other backend's read is: the conversion is a spawn of 50–740
    /// ms (measured over Word, Excel, PowerPoint, Pages, Numbers and Keynote files, the slowest a
    /// 50 000-row workbook), and the preview re-runs on every cursor step. The load token discards a
    /// conversion that lands after the cursor moved on, and the cancellation flag stops the process
    /// behind it — ``cancelDocumentConversion()`` runs in `show`'s own funnel, whichever backend takes
    /// the surface next.
    func showConvertedDocument(_ url: URL) {
        standDownQuickLook()
        standDownImage()
        standDownText()
        standDownPDF()
        standDownWeb()
        loadToken += 1
        let token = loadToken
        flipGate.isLoading = true
        if let cached = QuickLookDocumentCache.shared.conversion(for: url) {
            present(cached, from: url, token: token)
            return
        }
        // Stamped before the spawn, so a file saved again while the generator reads it misses the
        // cache next time instead of passing its older conversion off as current.
        guard let identity = ArchiveIdentity.current(ofFileAt: url.path) else {
            fallBackToQuickLook(url)
            return
        }
        let cancellation = CancellationFlag()
        documentConversion = cancellation
        Task { [weak self] in
            let converted = await BlockingWork.run {
                QuickLookDocumentConverter.convert(url) { cancellation.isCancelled }
            }
            guard let self else { return }
            // Kept even if the cursor moved on in the moment it took to hop back here: it finished,
            // and stepping back onto the file is exactly when it is wanted. A conversion cancelled
            // by the move returns nothing and keeps nothing.
            let conversion = converted.map {
                QuickLookDocumentCache.shared.store($0, for: url, identity: identity)
            }
            guard token == loadToken else { return }
            documentConversion = nil
            guard let conversion else {
                fallBackToQuickLook(url)
                return
            }
            present(conversion, from: url, token: token)
        }
    }

    /// Stop the conversion in flight, if any. Safe to call when there is none.
    func cancelDocumentConversion() {
        documentConversion?.isCancelled = true
        documentConversion = nil
    }

    private func present(
        _ conversion: QuickLookDocumentConverter.Conversion,
        from url: URL,
        token: Int
    ) {
        switch conversion.content {
        case let .page(allowsJavaScript, _, fitWidth):
            ensureWebSurface { [weak self] surface in
                guard let self, token == loadToken else { return }
                guard let surface else {
                    fallBackToQuickLook(url)
                    return
                }
                surface.isHidden = false
                surface.showConverted(
                    page: conversion.page,
                    bundle: conversion.bundle,
                    allowsJavaScript: allowsJavaScript,
                    fitWidth: fitWidth
                )
                contentDidLoad()
            }
        case let .pdfPages(names, fitsWidth):
            let files = names.map(conversion.attachment)
            Task { [weak self] in
                // `Data` crosses the actor boundary where a `PDFDocument` cannot; the pages are
                // small (a Pages document measured at 12 pages in 15 files), so parsing them back
                // here costs well under a frame.
                let pages = await BlockingWork.run {
                    files.compactMap { try? Data(contentsOf: $0) }
                }
                guard let self, token == loadToken else { return }
                guard let document = Self.mergedDocument(pages) else {
                    fallBackToQuickLook(url)
                    return
                }
                showPDFDocument(document, fitsWidth: fitsWidth)
                contentDidLoad()
            }
        }
    }

    /// One document holding every page of `pages`, in order — `nil` when none of them parses.
    static func mergedDocument(_ pages: [Data]) -> PDFDocument? {
        MergedPDFDocument(parts: pages)
    }

    private func fallBackToQuickLook(_ url: URL) {
        documentConversion = nil
        showQuickLook(url)
        contentDidLoad()
    }

    // MARK: - Routing

    /// Whether `url` is an office document this backend converts: a type one of the two generators
    /// claims, less anything that is text — the Office generator also claims CSV, which previews as
    /// the text it is (and reaches the text backend first anyway).
    static func isConvertibleDocument(_ url: URL) -> Bool {
        guard let type = documentContentType(of: url) else { return false }
        return convertibleDocumentTypes.contains { type.conforms(to: $0) }
    }

    /// The types the generators on *this* Mac claim, read once — see
    /// ``DirnexCore/QuickLookPreviewBundle/generatorInfoPaths`` for why they are read, not listed.
    static let convertibleDocumentTypes: [UTType] = QuickLookPreviewBundle.generatorInfoPaths
        .compactMap { FileManager.default.contents(atPath: $0) }
        .flatMap(QuickLookPreviewBundle.contentTypes(inGeneratorInfo:))
        .compactMap { UTType($0) }
        .filter { !$0.conforms(to: .text) }

    /// Content type first (an odd extension still classifies), extension as the fallback — the
    /// routing every other backend uses.
    static func documentContentType(of url: URL) -> UTType? {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type
        }
        return UTType(filenameExtension: url.pathExtension)
    }
}

/// A PDF assembled from the pages of several others, which **owns** those others.
///
/// The ownership is the whole point, and it was found by crashing. Inserting a page into another
/// document does not keep the page's original document alive, and once that document is released the
/// page still draws, scrolls and selects perfectly — until anything walks the view's accessibility
/// tree. Then `CGPDFPageCopyRootTaggedNode` aborts the process on a recursively locked
/// `os_unfair_lock`. Measured 2026-09-14: the app died the first time an accessibility client read the
/// preview of a Pages document, and a 60-line harness reproduced it **3 of 3** with the parts
/// released, and **0 of 3** with them retained, with every page copied, and in this shape. VoiceOver is
/// such a client, so this is not a test-harness artifact. Holding the parts on the merged document
/// makes their lifetime the document's by construction — nothing on the view has to remember them.
final class MergedPDFDocument: PDFDocument {
    private var parts: [PDFDocument] = []

    /// `nil` when no part parses to at least one page.
    convenience init?(parts data: [Data]) {
        self.init()
        for bytes in data {
            guard let part = PDFDocument(data: bytes) else { continue }
            parts.append(part)
            for index in 0..<part.pageCount {
                guard let page = part.page(at: index) else { continue }
                insert(page, at: pageCount)
            }
        }
        guard pageCount > 0 else { return nil }
    }
}
