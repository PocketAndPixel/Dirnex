import AppKit
import DirnexCore

/// What a preview surface keeps for links on the pages it renders (PLAN.md §M39 ▸ Slice 5).
///
/// One stored value rather than three properties on `QuickViewPreviewView`, whose file is near
/// SwiftLint's length ceiling (docs/NOTES.md ▸ Lint ceilings and file splitting).
struct QuickViewLinks {
    /// A heading a followed link named, waiting for the document it is in to render here.
    struct PendingFragment: Equatable {
        let location: VFSPath
        let fragment: String
    }

    /// Where the file on screen is on its own backend, as the window named it with the file. `nil`
    /// for a file on this disk named by its URL alone, which is its own location.
    var location: VFSPath?
    /// The heading the last followed link named. It survives a placeholder card, since a server's
    /// file is fetched before it renders, and is dropped by the next document rendered, its own or
    /// another's.
    var pendingFragment: PendingFragment?
    /// What a click on a link does: the window's, set when the surface is built. Given where the link
    /// leads, the location of the document it was clicked in, and the surface it was clicked on.
    var follow: ((DocumentLink, VFSPath, QuickViewPreviewView) -> Void)?
    /// The files the active pane lists in the folder of the document at a location: what a page's
    /// wiki links find when the document is not on this disk (`QuickViewMarkdownWikiLinks`). The
    /// window's, set when the surface is built, and asked only when such a page renders.
    var namesListed: ((VFSPath) -> Set<String>)?
}

extension QuickViewPreviewView {
    /// Where `url`, the file being rendered, is on its own backend.
    func documentLocation(for url: URL) -> VFSPath {
        links.location ?? .local(url.path)
    }

    /// The heading to scroll to as the document at `location` renders, taken so it is used once. One
    /// waiting for another document is dropped too: the user has moved on from the link that set it.
    func takePendingFragment(for location: VFSPath) -> String? {
        defer { links.pendingFragment = nil }
        guard let pending = links.pendingFragment, pending.location == location else { return nil }
        return pending.fragment
    }

    /// What finds the files a rendered page's wiki links name, for the document at `location` shown
    /// from `url`: the disk beside it when it is on this one, the pane's listing anywhere else.
    func wikiLinkFiles(for url: URL, at location: VFSPath) -> @Sendable (String) -> String? {
        guard location.backend != .local else { return QuickViewMarkdownWikiLinks.onDisk(beside: url) }
        return QuickViewMarkdownWikiLinks.listed(links.namesListed?(location) ?? [])
    }

    /// Wire a new web surface's clicks to ``QuickViewLinks/follow``, naming this surface, so the
    /// window knows which preview a heading is waiting on.
    func routeLinks(of surface: QuickViewWebView) {
        surface.onFollowLink = { [weak self] link, location in
            guard let self else { return }
            links.follow?(link, location, self)
        }
    }
}
