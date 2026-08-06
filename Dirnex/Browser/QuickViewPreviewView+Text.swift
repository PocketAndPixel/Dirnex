import AppKit
import DirnexCore
import UniformTypeIdentifiers

/// Quick View's text backend: which files it takes, and how their bytes reach it.
///
/// The third in-process backend, and it exists for the reason the other two do — something the
/// out-of-process `QLPreviewView` cannot give the user. `PDFView` was zoom, `NSImageView` was a
/// swipe that doesn't judder; this one is **selecting and copying the text**, which a Quick Look
/// preview can never offer here because the surface has to swallow the mouse (a click it declines is
/// re-dispatched to the file table underneath — docs/NOTES.md).
extension QuickViewPreviewView {
    /// Show `url` as text, standing the other backends down.
    ///
    /// The read is off the main actor, like the image backend's, so a multi-megabyte log does not
    /// stall the flip animation; `TextPreview` is `Sendable` where an `NSTextView` is not, which is
    /// why only the decoded value crosses back.
    ///
    /// A file that turns out not to be text after all — a binary someone named `.txt`, bytes in an
    /// encoding nothing claims — decodes to `nil` and falls back to Quick Look, which is exactly
    /// what it got before this backend existed.
    func showText(_ url: URL) {
        let surface = ensureTextSurface()
        standDownPDF()
        standDownQuickLook()
        standDownImage()
        standDownWeb()
        surface.isHidden = false
        loadToken += 1
        let token = loadToken
        Task { [weak self] in
            let scan = await Task.detached(priority: .userInitiated) {
                TextScan.read(url)
            }.value
            guard let self, token == loadToken else { return }
            guard let scan else {
                standDownText()
                showQuickLook(url)
                return
            }
            surface.show(scan.preview, tokens: scan.tokens)
        }
    }

    /// A decoded file and its coloured spans — everything the detached read produces, crossing back
    /// to the main actor as one value (PLAN.md §M17 ▸ Slice 3).
    ///
    /// The tokenize rides the read task rather than taking one of its own, for the reason the read
    /// is detached at all: the preview re-runs on **every cursor step**, so both have to be off the
    /// main actor and both have to be discarded together by the one `loadToken` guard. Measured
    /// at the 4 MB ceiling `TextPreview.byteLimit` allows, the scan is ~58 ms; a source file of any
    /// ordinary size is under 3 ms.
    ///
    /// `Sendable` is the whole reason this is a struct and not two `inout`s: an
    /// `NSMutableAttributedString` cannot cross an actor boundary, so what crosses is the *tokens*,
    /// and the app builds the attributed string on the main actor from them.
    struct TextScan: Sendable {
        let preview: TextPreview
        let tokens: [SyntaxToken]

        /// Blocking; call it off the main thread. `nil` for a file that is not text after all,
        /// which is `TextPreview`'s own answer and sends the caller back to Quick Look.
        static func read(_ url: URL) -> TextScan? {
            guard let preview = TextPreview.read(contentsOf: url) else { return nil }
            // By name, not by content type — the inversion is argued in `SyntaxLanguage`: `UTType`
            // answers `public.c-header` for a `.h` and cannot say which of three languages it is.
            // A file no grammar claims tokenizes to nothing and renders exactly as it did before.
            guard let language = SyntaxLanguage.forFile(named: url.lastPathComponent) else {
                return TextScan(preview: preview, tokens: [])
            }
            return TextScan(
                preview: preview,
                tokens: SyntaxHighlighter.tokens(in: preview.text, language: language)
            )
        }
    }

    func standDownText() {
        textSurface?.isHidden = true
        textSurface?.clearText()
    }

    /// Whether `url` is text this backend should render rather than Quick Look.
    ///
    /// Anything conforming to `public.text` — which is `.txt` and `.md`, but also JSON, XML, YAML,
    /// `.strings`, source code and logs — **except** the two families Quick Look renders as
    /// documents rather than as their source. An HTML file previews as the page it describes and RTF
    /// with its formatting; showing either as raw markup would be a regression dressed up as a
    /// feature.
    ///
    /// Content type first (an odd extension still classifies), extension as the fallback, matching
    /// the PDF and image routing beside it.
    static func isText(_ url: URL) -> Bool {
        guard let type = contentType(of: url) else { return false }
        guard type.conforms(to: .text) else { return false }
        return !type.conforms(to: .html) && !type.conforms(to: .rtf)
    }

    private static func contentType(of url: URL) -> UTType? {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type
        }
        return UTType(filenameExtension: url.pathExtension)
    }

    /// Build the text backend on first use and pin it over the surface, alongside the other two.
    private func ensureTextSurface() -> QuickViewTextView {
        if let textSurface { return textSurface }
        let surface = QuickViewTextView()
        pin(surface, inside: content)
        textSurface = surface
        return surface
    }
}
