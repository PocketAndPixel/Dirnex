import AppKit
import UniformTypeIdentifiers

/// Quick View's rendered-HTML backend: which files it takes, and how they reach the web view
/// (PLAN.md §M16).
///
/// The routing decision lives here rather than in `DirnexCore` for the reason `TextPreview`'s own
/// doc comment states: which backend a file belongs to is a UTType question, and therefore a UI one.
extension QuickViewPreviewView {
    /// Show `url` as a rendered page, standing the other backends down.
    ///
    /// The surface is built asynchronously the first time, because the block-remote content rules
    /// have to be compiled before there is anything safe to build (`QuickViewWebView
    /// .withContentRules`). Two things follow from that gap, and both are the same shape as the
    /// image and text backends' own asynchronous reads: the load token guards against the cursor
    /// having moved on, and a surface that cannot be built at all falls back to text rather than
    /// rendering unprotected.
    func showRenderedHTML(_ url: URL) {
        standDownPDF()
        standDownQuickLook()
        standDownImage()
        standDownText()
        loadToken += 1
        let token = loadToken
        ensureWebSurface { [weak self] surface in
            guard let self, token == loadToken else { return }
            guard let surface else {
                showText(url)
                return
            }
            surface.isHidden = false
            surface.show(url)
        }
    }

    func standDownWeb() {
        webSurface?.isHidden = true
        webSurface?.clearPage()
    }

    /// Whether `url` is a file this backend can render.
    ///
    /// Named types rather than one conformance test, because the obvious derivation is wrong:
    /// probed, `.xhtml` is `public.xhtml` and does **not** conform to `public.html`, so a
    /// `conforms(to: .html)` gate would silently exclude it — which is exactly how it ended up
    /// previewing as source before this milestone, unnoticed. `.mhtml` and `.webarchive` conform to
    /// neither and are left with Quick Look: they are archives of a page, and rendering one needs a
    /// `loadData` path rather than a file load.
    static func isRenderableHTML(_ url: URL) -> Bool {
        guard let type = htmlContentType(of: url) else { return false }
        return type.conforms(to: .html) || type.conforms(to: UTType("public.xhtml") ?? .html)
    }

    private static func htmlContentType(of url: URL) -> UTType? {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type
        }
        return UTType(filenameExtension: url.pathExtension)
    }

    /// Build the web backend on first use and pin it over the surface, alongside the other three.
    /// Asynchronous where the others are not — see `showRenderedHTML`.
    private func ensureWebSurface(_ completion: @escaping (QuickViewWebView?) -> Void) {
        if let webSurface {
            completion(webSurface)
            return
        }
        QuickViewWebView.withContentRules { [weak self] surface in
            guard let self, let surface else {
                completion(nil)
                return
            }
            pin(surface, inside: content)
            webSurface = surface
            completion(surface)
        }
    }
}
