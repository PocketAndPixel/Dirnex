import AppKit
import DirnexCore

/// What a Quick View web surface can be showing. Moved out of `QuickViewWebView.swift` at M39 Slice 5,
/// when the copied HTML file and the link fields every page now carries took that file past SwiftLint's
/// length ceiling (docs/NOTES.md ▸ Lint ceilings and file splitting): the kinds of page, and the
/// questions each answers differently.
extension QuickViewWebView {
    /// What this surface is showing, which is two different things and only one of them is a file.
    ///
    /// A `.md` has no HTML on disk — the page is generated from it (PLAN.md §M18) — so there is no
    /// URL to re-load and the body has to be kept in order to draw it again. An enum rather than a
    /// second pair of optionals because the two cases answer *every* question differently: what a
    /// reload re-issues, and which URL `decidePolicyFor` measures a link against.
    enum Page {
        /// An HTML file on this disk, loaded from disk with read access scoped to its own directory
        /// (§M16). `location` is where it is, which its links lead from (§M39).
        case file(URL, location: VFSPath)
        /// An HTML file shown from a local copy — a server's file, or an archive member — whose bytes
        /// are loaded under the base URL of its `location`, as a generated page's are, rather than from
        /// the copy (§M39). WebKit asks about a link on a `file:` page only when it names a file that
        /// exists inside the page's read access, and the copy sits alone in a temp folder, so every link
        /// to a sibling was dropped unasked. Measured 2026-11-13. The copy's folder held none of the
        /// page's stylesheets or images either, so loading from it gave the page nothing this does not.
        case copied(URL, base: URL, location: VFSPath)
        /// A document rendered from the bytes of the file at `location`, loaded under that
        /// location's own path as the base URL (``DirnexCore/DocumentLink/baseURL(for:)``) — the
        /// page's identity, not its read access (see `showMarkdown`). The scan's fragment is wrapped
        /// afresh on every load, so the stylesheet is the one the current appearance calls for.
        case generated(QuickViewPreviewView.MarkdownScan, base: URL, location: VFSPath)
        /// An office document converted by macOS's own Quick Look generator
        /// (`QuickViewPreviewView+Document`): `page` inside the bundle directory `bundle`, which is
        /// also the read access, since a workbook's sheets and a document's images are its siblings.
        /// `allowsJavaScript` is the **generator's** answer, not the user's preference — the only
        /// scripts such a page carries are the generator's own tab strip (``DirnexCore/QuickLookPreviewBundle/Content``).
        /// `fitWidth` is the width to scale the page to the surface from, when the generator allows it.
        case converted(page: URL, bundle: URL, allowsJavaScript: Bool, fitWidth: Double?)
        /// A saved page, `.webarchive` or `.mhtml`, sealed by `DirnexCore` so nothing in it names a
        /// real origin (``DirnexCore/WebArchiveSeal``): the property list WebKit loads, and the file's
        /// directory as the base URL, which is the main frame's one navigation and grants no read
        /// access, as a generated page's does not (PLAN.md §M39). `document` is the sealed URL of the
        /// archive's own page, which its `#anchor` links arrive against; `origins` is the seal's table,
        /// which sends a clicked link back to the real URL its author pointed it at.
        case archive(SavedArchive)

        /// The one navigation `decidePolicyFor` allows, fragments aside. For a generated page that
        /// is the base URL, because that is what the page's own links resolve against — measured:
        /// a `#anchor` click arrives as `<document>#anchor` and really moves the reading position.
        var permittedURL: URL {
            switch self {
            case let .file(url, _): url
            case let .copied(_, base, _): base
            case let .generated(_, base, _): base
            case let .converted(page, _, _, _): page
            case let .archive(saved): saved.directory
            }
        }

        /// Whether scripts run on this page: the user's switch for a file somebody wrote, the
        /// generator's own request for a page it wrote.
        @MainActor var allowsJavaScript: Bool {
            switch self {
            case .file, .copied, .generated, .archive: AppPreferences.quickViewJavaScriptValue
            case let .converted(_, _, allowsJavaScript, _): allowsJavaScript
            }
        }

        /// The directory an *embedded frame* may load from — a converted workbook shows each sheet
        /// in an iframe the tab strip re-points. `nil` for everything else, which keeps the rule a
        /// file-backed page has always had: nothing but the page itself.
        var frameDirectory: URL? {
            if case let .converted(_, bundle, _, _) = self { return bundle }
            return nil
        }

        /// The sealed URL of a saved page's own document, which its in-page anchors arrive against.
        /// `nil` for every other page, whose anchors arrive against ``permittedURL``.
        var archiveDocument: URL? {
            if case let .archive(saved) = self { return saved.document }
            return nil
        }
    }

    /// A saved page as the web surface holds it (``Page/archive(_:)``): the sealed property list
    /// WebKit loads, and what a click on one of its links needs (`QuickViewWebView+Links`).
    struct SavedArchive {
        let data: Data
        let directory: URL
        let document: URL
        let origins: [String: String]
        let location: VFSPath
    }
}
