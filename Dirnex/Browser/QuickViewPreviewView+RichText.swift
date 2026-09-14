import AppKit
import DirnexCore
import UniformTypeIdentifiers

/// Quick View's rich-text backend: RTF, RTFD and OpenDocument text, read by AppKit in-process and
/// shown with their formatting in the text view (follow-on, 2026-09-14).
///
/// RTF used to reach Quick Look's own view — no selection, no zoom — and an `.odt` reached it too and
/// got nothing, since no generator on macOS claims OpenDocument (measured: `qlmanage` "did not
/// produce any preview"). `NSAttributedString` reads all three, so they take the text backend's
/// surface, where a drag selects and ⌘C copies.
///
/// Word files are deliberately *not* read this way even though `NSAttributedString` accepts `.docx`:
/// it drops a document's images (a real 1 MB `.docx` came back as 744 characters), where the Office
/// generator keeps them (`QuickViewPreviewView+Document`).
extension QuickViewPreviewView {
    /// Show `url` as formatted text, standing the other backends down.
    ///
    /// Read off the main actor, because an RTF parse is not free: measured at ~41 ms per megabyte
    /// (248 ms for a 6 MB file), on a preview that re-runs on every cursor step.
    func showRichText(_ url: URL) {
        guard let documentType = Self.richTextDocumentType(of: url),
              Self.richTextByteSize(of: url) <= Self.richTextByteLimit else {
            showQuickLook(url)
            return
        }
        let surface = ensureTextSurface()
        standDownPDF()
        standDownQuickLook()
        standDownImage()
        standDownWeb()
        surface.isHidden = false
        surface.clearText()
        loadToken += 1
        let token = loadToken
        flipGate.isLoading = true
        Task { [weak self] in
            let document = await BlockingWork.run {
                RichTextDocument.read(url, as: documentType)
            }
            guard let self, token == loadToken else { return }
            guard let document else {
                standDownText()
                showQuickLook(url)
                contentDidLoad()
                return
            }
            surface.showRichText(document.text)
            contentDidLoad()
        }
    }

    /// A parsed document crossing back to the main actor.
    ///
    /// `@unchecked Sendable` around an `NSAttributedString`, which Swift 6 marks non-`Sendable`, and
    /// the claim is narrow enough to state: the string is built on the reading thread, never
    /// mutated, and handed over exactly once. There is no `Sendable` intermediate that would avoid
    /// it — the only one is the file's bytes, and parsing those is the work that has to leave the main
    /// actor.
    final class RichTextDocument: @unchecked Sendable {
        let text: NSAttributedString

        private init(text: NSAttributedString) {
            self.text = text
        }

        /// Blocking. The document type is always given explicitly: left to detect it, AppKit reads a
        /// file that *looks* like HTML through WebKit, which must run on the main thread and may load
        /// what the page names.
        static func read(_ url: URL, as type: NSAttributedString.DocumentType) -> RichTextDocument? {
            guard let text = try? NSAttributedString(
                url: url,
                options: [.documentType: type],
                documentAttributes: nil
            ) else { return nil }
            return RichTextDocument(text: text)
        }
    }

    /// The largest rich-text file read in-process. At the measured ~41 ms per megabyte this is about
    /// 1.3 s of parsing off the main actor, which is the most a preview can spend on a file the cursor
    /// may only be passing over; anything larger keeps Quick Look's own view.
    static let richTextByteLimit: Int64 = 32 * 1024 * 1024

    /// Whether `url` is a rich-text document this backend reads.
    static func isRichTextDocument(_ url: URL) -> Bool {
        richTextDocumentType(of: url) != nil
    }

    private static func richTextDocumentType(of url: URL) -> NSAttributedString.DocumentType? {
        guard let type = documentContentType(of: url) else { return nil }
        if type.conforms(to: .rtfd) || type.conforms(to: .flatRTFD) { return .rtfd }
        if type.conforms(to: .rtf) { return .rtf }
        if let openDocumentText, type.conforms(to: openDocumentText) { return .openDocument }
        return nil
    }

    /// Optional rather than given a fallback, for the reason `markdownType` is: every stand-in is a
    /// type this backend must not claim.
    private static let openDocumentText = UTType("org.oasis-open.opendocument.text")

    /// The bytes a parse has to read: the file itself, or an RTFD package's text (its images are
    /// attachments the view draws lazily, not text the parser walks).
    private static func richTextByteSize(of url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        let measured = isDirectory.boolValue ? url.appendingPathComponent("TXT.rtf") : url
        let size = (
            try? FileManager.default.attributesOfItem(atPath: measured.path)[.size] as? NSNumber
        )
        return size?.int64Value ?? 0
    }
}
