import AppKit
import DirnexCore
import UniformTypeIdentifiers

/// Quick View's rendered-Markdown backend: which files it takes, and how their bytes become a page
/// (PLAN.md §M18 ▸ Slice 3).
///
/// The second **dual-style** type, after HTML. `1` keeps the source, coloured by M17's Markdown
/// scanner; `2` shows the document those bytes describe. A `.md` is the format most likely to be
/// *read* in a file manager rather than opened, and what Quick Look shows for one today is plain
/// text with the syntax on display.
///
/// It shares the web surface with the HTML backend and almost nothing else. The page here is
/// **generated** — no HTML exists on disk — which changes three things at once: the bytes have to be
/// read and rendered before there is anything to load, the load carries a base URL rather than a
/// file URL, and the result is inert by construction. `MarkdownDocument` escapes the file's raw HTML
/// instead of passing it through, so the page has no script for the JavaScript switch to be about
/// and no remote `<img>` for the content rules to have to catch — which is why the `(no JavaScript)`
/// mark is suppressed for markdown: it would be true and meaningless.
extension QuickViewPreviewView {
    /// Show `url` as the document it describes, standing the other backends down.
    ///
    /// Two asynchronous things have to land before anything is on screen, and they are independent:
    /// the read-and-render (off the main actor, because the preview re-runs on **every cursor
    /// step** — measured in Slice 1 at 4.5 ms for this repo's `PLAN.md` and 96 ms for its
    /// `HISTORY.md`), and the web surface itself, which cannot be built until the block-remote
    /// content rules have compiled. Both are guarded by the one `loadToken` the image and text
    /// backends already share, so a slow render landing after the cursor moved on is discarded
    /// rather than replacing the file now on screen.
    ///
    /// Two fallbacks, and both are the ones this surface already had: a file that turns out not to
    /// be text after all shows as text (which itself falls back to Quick Look), and a surface that
    /// cannot be built at all shows the source rather than rendering unprotected.
    func showRenderedMarkdown(_ url: URL) {
        standDownPDF()
        standDownQuickLook()
        standDownImage()
        standDownText()
        loadToken += 1
        let token = loadToken
        Task { [weak self] in
            let scan = await Task.detached(priority: .userInitiated) {
                MarkdownScan.read(url)
            }.value
            guard let self, token == loadToken else { return }
            guard let scan else {
                showText(url)
                return
            }
            ensureWebSurface { [weak self] surface in
                guard let self, token == loadToken else { return }
                guard let surface else {
                    showText(url)
                    return
                }
                surface.isHidden = false
                surface.showMarkdown(scan, source: url)
            }
        }
    }

    /// A rendered document and the one thing about it the page itself cannot show — everything the
    /// detached read produces, crossing back to the main actor as one value.
    ///
    /// The read goes through `TextPreview` rather than opening the file directly, so a `.md` gets
    /// exactly the decoding every other text file gets: the BOM check, the NUL gate that refuses a
    /// binary somebody named `.md`, the encoding fallbacks, and the 4 MB ceiling. `nil` is
    /// `TextPreview`'s own answer for "this is not text", and it sends the caller to the text
    /// backend, which is where that answer is already handled.
    ///
    /// `isTruncated` rides along because it *has* to: a source view that stops at 4 MB is visibly
    /// mid-file, while a rendered page just ends, and looks finished doing it.
    struct MarkdownScan: Sendable {
        /// The core's HTML **fragment**. The wrapper and the stylesheet are added at load time,
        /// where the appearance is known.
        let html: String
        let isTruncated: Bool

        /// Blocking; call it off the main thread — which is also where the images are read, since
        /// the resolver runs inside the render (`QuickViewMarkdownImages`).
        static func read(_ url: URL) -> MarkdownScan? {
            guard let preview = TextPreview.read(contentsOf: url) else { return nil }
            let options = MarkdownRenderOptions(
                resolveImageSource: QuickViewMarkdownImages.resolver(for: url)
            )
            return MarkdownScan(
                html: MarkdownDocument.render(preview.text, options: options).html,
                isTruncated: preview.isTruncated
            )
        }
    }

    /// Whether `url` is Markdown this backend can render.
    ///
    /// Named types rather than one conformance test, which is the lesson `.xhtml` taught §M16: it
    /// is `public.xhtml` and does *not* conform to `public.html`, so a single-conformance gate
    /// dropped it silently for the whole life of that exclusion. Markdown has the same shape —
    /// `net.daringfireball.markdown` is the registered type, and a `.mkd` or `.mdown` on a Mac that
    /// has never seen one resolves to nothing at all, so the extensions are named too.
    static func isRenderableMarkdown(_ url: URL) -> Bool {
        if markdownExtensions.contains(url.pathExtension.lowercased()) { return true }
        guard let markdownType,
              let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        else { return false }
        return type.conforms(to: markdownType)
    }

    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    /// Left **optional** rather than given a fallback: every plausible stand-in is a type this
    /// backend must not claim, and `?? .plainText` would quietly hand it every `.txt` on the Mac.
    /// A machine where the identifier is unregistered falls back to the extensions above, which is
    /// the answer that cannot be wrong in the expensive direction.
    private static let markdownType = UTType("net.daringfireball.markdown")
}
