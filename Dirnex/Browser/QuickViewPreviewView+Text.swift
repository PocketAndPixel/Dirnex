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
        surface.isHidden = false
        loadToken += 1
        let token = loadToken
        Task { [weak self] in
            let preview = await Task.detached(priority: .userInitiated) {
                TextPreview.read(contentsOf: url)
            }.value
            guard let self, token == loadToken else { return }
            guard let preview else {
                standDownText()
                showQuickLook(url)
                return
            }
            surface.show(preview)
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
