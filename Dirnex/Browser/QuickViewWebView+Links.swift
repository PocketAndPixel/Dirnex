import AppKit
import DirnexCore
import WebKit

/// Following a link out of a rendered page (PLAN.md §M39 ▸ Slice 5).
///
/// The decision is that a link to another file **moves the pane**: its cursor lands on the target, the
/// preview follows the cursor, and the pane's own Back is the way back, so the file list stays the
/// navigation and the preview gains no history. A web link opens in the user's browser, since a click
/// is a deliberate act where a cursor step is not. This surface only works out where a click leads,
/// from the page it was clicked in (`DirnexCore.DocumentLink`), and hands that on; the window moves
/// the pane, opens the browser or says why it will do neither.
extension QuickViewWebView {
    /// Hand on a click the navigation policy refused: where it leads, and the location of the document
    /// it was clicked in. A link to the page itself does nothing, since an `#anchor` on it was allowed
    /// and scrolled before it got here.
    ///
    /// Deferred to the next turn of the main actor: following a link moves the pane, which loads the
    /// target into this very view, and that must not happen inside WebKit's own policy decision.
    func followLink(_ url: URL) {
        guard let page, let (link, location) = page.link(for: url) else { return }
        if case .sameDocument = link { return }
        Task { @MainActor [weak self] in
            self?.onFollowLink?(link, location)
        }
    }

    /// Scroll to ``scrollTarget`` now that the page it is in has loaded, once: a reload of the same
    /// page keeps the reading position the user has moved to since.
    func scrollToTarget() {
        guard let fragment = scrollTarget else { return }
        scrollTarget = nil
        Task { @MainActor [weak self] in
            _ = try? await self?.webView.callAsyncJavaScript(
                Self.fragmentScript,
                arguments: ["fragment": fragment],
                in: nil,
                contentWorld: .defaultClient
            )
        }
    }

    /// Bring the element a fragment names to the top: the `id` a heading's slug became, or failing
    /// that the `name` an older page's `<a name>` carries, which is how a browser looks one up. In the
    /// isolated world the find uses (`QuickViewPageFindScript`), so it works with the page's own
    /// scripts off. Answers whether there was anything to scroll to.
    static let fragmentScript = """
    const target = document.getElementById(fragment) ?? document.getElementsByName(fragment)[0];
    if (!target) { return false; }
    target.scrollIntoView({ block: 'start', behavior: 'instant' });
    return true;
    """
}

extension QuickViewWebView.Page {
    /// Where a click on `url` leads, and the location of the document it was clicked in — `nil` for a
    /// click that goes nowhere.
    ///
    /// Each kind of page resolves against what its URLs mean. A generated page's base URL spells the
    /// document's own path, and so does a copied HTML file's, so WebKit's URL is read as it is; an
    /// HTML file on this disk resolves against itself, so its links are the `file:` URLs they name.
    /// A saved page's links are in the seal's scheme, and go back to the real URL its author wrote. A
    /// converted office document is the generator's page, not the user's file, so only its links to
    /// the web and to mail lead anywhere.
    ///
    /// On a `file:` page WebKit asks about a link only when it names a file that exists inside the
    /// page's read access (measured 2026-11-13): one to a missing file, or out of the page's folder,
    /// is dropped before it gets here, so a local HTML file says nothing about either.
    func link(for url: URL) -> (DocumentLink, VFSPath)? {
        switch self {
        case let .generated(_, _, location), let .copied(_, _, location), let .file(_, location):
            return (DocumentLink.resolve(url.absoluteString, from: location), location)
        case let .archive(saved):
            let original = WebArchiveSeal.originalURL(
                for: url.absoluteString,
                origins: saved.origins
            ) ?? url.absoluteString
            return (DocumentLink.resolve(original, from: saved.location), saved.location)
        case let .converted(page, _, _, _):
            let location = VFSPath.local(page.path)
            let link = DocumentLink.resolve(url.absoluteString, from: location)
            guard case .external = link else { return nil }
            return (link, location)
        }
    }
}
