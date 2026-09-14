import AppKit
import WebKit

/// The web view a Quick View *rendered* HTML preview draws into. A named subclass because two places
/// have to recognize it: the preview surface, which lets the mouse through so the page scrolls (see
/// `QuickViewPreviewView.hitTest`), and the window's Esc monitor, which must not mistake it for a
/// field editor.
@MainActor
final class QuickViewDocumentWebView: WKWebView {}

/// A local HTML file rendered as the page it describes, as one of `QuickViewPreviewView`'s backends
/// (PLAN.md §M16).
///
/// The fourth in-process backend, and it exists for the reason the other three do — something the
/// out-of-process `QLPreviewView` cannot give the user. Quick Look draws HTML as a fixed-width
/// document *card* that no constraint of ours can stretch, and the surface has to swallow the mouse
/// (a click it declines is re-dispatched to the file table underneath — docs/NOTES.md), so a page
/// taller than the surface could not be scrolled at all. In-process, both are ordinary.
///
/// ## What it is allowed to do
///
/// A previewed file is *untrusted input*: a page saved from anywhere renders here the moment the
/// cursor lands on it, with no click and no confirmation. Measured against a real HTTP server on
/// 127.0.0.1 before this was written — one such page issued three requests (a stylesheet, an image,
/// a `fetch`) from a plain `WKWebView`, which is a page confirming to its author that this Mac
/// previewed the file. Worth stating because the page's *own* error handlers reported all three as
/// blocked: the responses fail CORS, the requests still go out, and a tracking pixel needs only the
/// request.
///
/// So: **network off, unconditionally; JavaScript off by default and switchable.**
/// `blockRemoteRules` blocks every load that is not `file://`, which measured as zero requests
/// reaching the server while scripts still ran, the page's own stylesheet still applied and `data:`
/// images — what a self-contained report inlines — still loaded. That closed network is what makes
/// the script switch *offerable*: a local script with no network cannot exfiltrate, so turning it on
/// costs the user nothing beyond what a page can draw, and it is what makes a report render instead
/// of showing the raw LaTeX Quick Look shows today. It ships off all the same, because a preview
/// renders as the cursor moves and running a file's code takes more than passing over it
/// (`AppPreferences.quickViewJavaScriptEnabled`). The store is non-persistent so nothing a preview
/// touches outlives it, the file load is scoped to the file's own directory, and `decidePolicyFor`
/// refuses every navigation but the first, so a link cannot take the preview somewhere the user
/// never asked to go.
///
/// The rule list is a **precondition, not a decoration**: compiling it is asynchronous, so this view
/// cannot be built until it exists (`withContentRules`). A build that starts before the rules land
/// would render one page unprotected, and it would be the quietest possible failure — the preview
/// looks right, and only a server somewhere else knows.
@MainActor
final class QuickViewWebView: NSView {
    /// What this surface is showing, which is two different things and only one of them is a file.
    ///
    /// A `.md` has no HTML on disk — the page is generated from it (PLAN.md §M18) — so there is no
    /// URL to re-load and the body has to be kept in order to draw it again. An enum rather than a
    /// second pair of optionals because the two cases answer *every* question differently: what a
    /// reload re-issues, and which URL `decidePolicyFor` measures a link against.
    private enum Page {
        /// An HTML file, loaded from disk with read access scoped to its own directory (§M16).
        case file(URL)
        /// A document rendered from a file's bytes, loaded with that file's **directory** as the
        /// base URL — the page's identity, not its read access (see `showMarkdown`). The scan's
        /// fragment is wrapped afresh on every load, so the stylesheet is the one the current
        /// appearance calls for.
        case generated(QuickViewPreviewView.MarkdownScan, directory: URL)
        /// An office document converted by macOS's own Quick Look generator
        /// (`QuickViewPreviewView+Document`): `page` inside the bundle directory `bundle`, which is
        /// also the read access, since a workbook's sheets and a document's images are its siblings.
        /// `allowsJavaScript` is the **generator's** answer, not the user's preference — the only
        /// scripts such a page carries are the generator's own tab strip (``DirnexCore/QuickLookPreviewBundle/Content``).
        /// `fitWidth` is the width to scale the page to the surface from, when the generator allows it.
        case converted(page: URL, bundle: URL, allowsJavaScript: Bool, fitWidth: Double?)

        /// The one navigation `decidePolicyFor` allows, fragments aside. For a generated page that
        /// is the base URL, because that is what the page's own links resolve against — measured:
        /// a `#anchor` click arrives as `<directory>#anchor` and really moves the reading position.
        var permittedURL: URL {
            switch self {
            case let .file(url): url
            case let .generated(_, directory): directory
            case let .converted(page, _, _, _): page
            }
        }

        /// Whether scripts run on this page: the user's switch for a file somebody wrote, the
        /// generator's own request for a page it wrote.
        @MainActor var allowsJavaScript: Bool {
            switch self {
            case .file, .generated: AppPreferences.quickViewJavaScriptValue
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
    }

    private let webView: QuickViewDocumentWebView
    /// What is on screen, which is the *one* navigation `decidePolicyFor` allows.
    private var page: Page?

    /// The view the surface must let the mouse reach for the page to scroll at all.
    var interactiveSubtree: NSView { webView }

    /// Block everything, then put `file://` back — the order matters, since
    /// `ignore-previous-rules` is what re-admits the page's own bytes and its local siblings.
    /// `data:` URIs are unaffected by either rule (probed), so inlined images survive.
    private static let blockRemoteRules = """
    [
      { "trigger": { "url-filter": ".*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": "^file://" }, "action": { "type": "ignore-previous-rules" } }
    ]
    """

    private static let ruleListIdentifier = "com.dirnex.quickview.block-remote"

    /// The compiled rule list, kept for the life of the process: compiling is asynchronous and the
    /// preview is re-driven on every cursor step, so paying it once is the difference between a
    /// gate and a race.
    private static var compiledRules: WKContentRuleList?

    private init(rules: WKContentRuleList) {
        let configuration = WKWebViewConfiguration()
        // Nothing a preview touches should outlive it: no cookies, no cache, no local storage.
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(rules)
        // JavaScript is *not* configured here — see `decidePolicyFor`, which answers it per
        // navigation so the Settings toggle takes effect on a view that already exists.
        webView = QuickViewDocumentWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildWebView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Build a rendering surface, once the block-remote rules exist to build it with.
    ///
    /// `nil` when they cannot be compiled at all — a `WKContentRuleListStore` the OS declines to
    /// hand over, which should not happen and must not degrade into rendering anyway. The caller
    /// falls back to showing the file as text, which is this milestone's default and loses the user
    /// nothing but the rendering.
    static func withContentRules(_ completion: @escaping (QuickViewWebView?) -> Void) {
        if let compiledRules {
            completion(QuickViewWebView(rules: compiledRules))
            return
        }
        guard let store = WKContentRuleListStore.default() else {
            NSLog("Quick View: no content rule list store; HTML will not be rendered")
            completion(nil)
            return
        }
        store.compileContentRuleList(
            forIdentifier: ruleListIdentifier,
            encodedContentRuleList: blockRemoteRules
        ) { list, error in
            // Documented as delivered on the main queue, and asserted rather than assumed: this
            // closure builds a view and touches main-actor state.
            MainActor.assumeIsolated {
                if let list {
                    compiledRules = list
                    completion(QuickViewWebView(rules: list))
                } else {
                    NSLog(
                        "Quick View: content rules failed to compile — \(String(describing: error))"
                    )
                    completion(nil)
                }
            }
        }
    }

    // MARK: - Content

    /// Render `url`. The read access is scoped to the file's own directory, so a page reaches the
    /// sibling stylesheet and images that make it a saved page, and nothing above it.
    func show(_ url: URL) {
        startNewPage()
        load(.file(url.standardizedFileURL))
    }

    /// Render a document generated from `source`'s bytes — Markdown, today (PLAN.md §M18).
    ///
    /// The scan's fragment is `DirnexCore`'s; the wrapper and the stylesheet are added here, at load
    /// time, so a page always carries the palette for the appearance it is being drawn in.
    ///
    /// The base URL is the file's **directory**, and it is not what reaches the file's images —
    /// measured, `loadHTMLString(_:baseURL:)` grants no filesystem access at all, which is why the
    /// images arrive already inlined (`QuickViewMarkdownImages`). What it is for is *identity*: it
    /// gives the page a real URL, so a `#anchor` click resolves against something `isPermitted` can
    /// compare exactly and a link to a sibling file resolves to a path it can refuse by name.
    func showMarkdown(_ scan: QuickViewPreviewView.MarkdownScan, source: URL) {
        startNewPage()
        load(.generated(scan, directory: source.deletingLastPathComponent().standardizedFileURL))
    }

    /// Render a page Quick Look's generator wrote for an office document, from inside its bundle.
    func showConverted(page: URL, bundle: URL, allowsJavaScript: Bool, fitWidth: Double?) {
        startNewPage()
        load(.converted(
            page: page.standardizedFileURL,
            bundle: bundle.standardizedFileURL,
            allowsJavaScript: allowsJavaScript,
            fitWidth: fitWidth
        ))
    }

    // MARK: - Zoom

    /// ⌘+ / ⌘−'s level, relative to how the page first drew (``DirnexCore/QuickViewZoom``). A new
    /// file starts back at 1, the way the text and PDF backends reset theirs — arriving on the next
    /// file at the zoom somebody wanted for the last one is nobody's idea of a preview. A reload of
    /// the *same* page (a changed JavaScript preference) keeps it.
    private(set) var zoomLevel = 1.0

    /// Whether the page is exactly as it opened: no ⌘+ / ⌘− step, and no pinch either.
    var isAtStartingZoom: Bool {
        abs(zoomLevel - 1) < 0.001 && abs(webView.magnification - 1) < 0.001
    }

    /// Show the page at `level` times its starting size.
    func setZoomLevel(_ level: Double) {
        zoomLevel = level
        applyZoom()
    }

    /// Back to how the page opened — the ⌘+ / ⌘− level *and* a pinch, since ⌘0 is the one key that
    /// promises "as it was".
    func resetZoom() {
        webView.magnification = 1
        setZoomLevel(1)
    }

    private func startNewPage() {
        zoomLevel = 1
        webView.magnification = 1
    }

    /// Apply the page's starting size times ``zoomLevel`` as `pageZoom`.
    ///
    /// The starting size is 100 % for an HTML file or a Markdown page, and for a converted office page
    /// that allows it, the surface's width over the generator's — the way Quick Look's own view draws
    /// a Word page or a slide across its panel, within bounds, so a phone-width pane still gets a
    /// readable page and a full-screen one does not get letters an inch high. `pageZoom` rather than
    /// magnification because it lays the page out again at the new size: text stays sharp, a page
    /// reflows like a browser's ⌘+, and the user's own pinch still magnifies on top of it.
    private func applyZoom() {
        var start: CGFloat = 1
        if case let .converted(_, _, _, fitWidth?) = page, bounds.width > 0 {
            start = min(
                max(bounds.width / fitWidth, Self.fitZoomRange.lowerBound),
                Self.fitZoomRange.upperBound
            )
        }
        let zoom = start * zoomLevel
        if abs(webView.pageZoom - zoom) > 0.001 { webView.pageZoom = zoom }
    }

    private static let fitZoomRange: ClosedRange<CGFloat> = 0.5...2

    override func layout() {
        super.layout()
        applyZoom()
    }

    /// Load the current page again — what a changed JavaScript preference needs, since the answer
    /// is given per navigation and an already-rendered page has had its. A no-op when nothing is
    /// loaded.
    ///
    /// An appearance change deliberately does **not** come through here: probed, the page's own
    /// `prefers-color-scheme` follows the web view's effective appearance and re-evaluates live, so
    /// a light/dark flip keeps the reading position a reload would have thrown away.
    func reloadPage() {
        guard let page else { return }
        load(page)
    }

    /// Drop the rendered page, so nothing stays live while the surface is put away. Loading an
    /// empty document rather than merely stopping: a page that finished loading keeps its timers.
    func clearPage() {
        page = nil
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    private func load(_ page: Page) {
        self.page = page
        applyZoom()
        switch page {
        case let .file(url):
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        case let .converted(page, bundle, _, _):
            webView.loadFileURL(page, allowingReadAccessTo: bundle)
        case let .generated(scan, directory):
            webView.loadHTMLString(
                QuickViewMarkdownStyle.document(body: scan.html, isTruncated: scan.isTruncated),
                baseURL: directory
            )
        }
    }

    // MARK: - Setup

    private func buildWebView() {
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.allowsMagnification = true
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}

// MARK: - Navigation

extension QuickViewWebView: WKNavigationDelegate {
    /// Allow the file this preview was pointed at, and nothing else.
    ///
    /// The rule list already stops a remote *load*; refusing the navigation covers a different
    /// case. A click on a link in a previewed page would otherwise replace what the header names
    /// with something else — a preview that has quietly become a browser, showing a document the
    /// user never selected. An in-page anchor (`#top`) is the one exception, since it moves the
    /// reading position rather than the document.
    /// This is also where the JavaScript preference is applied, and it has to be here rather than
    /// on the configuration: `WKWebViewConfiguration` is copied at init, so a view built with
    /// scripts enabled keeps them for life. Probed on one live view over four loads — the delegate's
    /// `preferences` re-gated it off and on again each time, while assigning
    /// `webView.configuration.defaultWebpagePreferences.allowsContentJavaScript` did nothing at all
    /// **and read back as `false` afterwards**, which is the shape of an edit that looks applied and
    /// is not.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        preferences.allowsContentJavaScript = page?.allowsJavaScript
            ?? AppPreferences.quickViewJavaScriptValue
        guard let url = navigationAction.request.url else { return (.cancel, preferences) }
        let inFrame = navigationAction.targetFrame.map { !$0.isMainFrame } ?? false
        return (isPermitted(url, inFrame: inFrame) ? .allow : .cancel, preferences)
    }

    /// The empty document `clearPage` loads, and the page this preview is showing — compared
    /// without the fragment, so an in-page anchor still works.
    ///
    /// For a generated document that comparison is against the file's *directory*, which is what
    /// the page's links resolve against. Probed, so the difference is stated rather than assumed: a
    /// `#anchor` is allowed and scrolls; a sibling `other.md` is refused; a remote URL is refused;
    /// `../` is never even attempted. A link to `.` or `""` does compare equal and is allowed — and
    /// measured harmless, since WebKit leaves the generated document on screen. A tightening that
    /// admitted only fragments was written and measured to change nothing else, so it was dropped
    /// rather than carried: it would have had to carve out the initial load and the reload, both of
    /// which arrive here too.
    ///
    /// An embedded frame is the one other thing a *converted* page may load: a sheet page from inside
    /// its own bundle, and nothing outside it — a link in a workbook cell must no more replace a sheet
    /// with a web page than it may replace the document.
    private func isPermitted(_ url: URL, inFrame: Bool) -> Bool {
        if url.absoluteString.hasPrefix("about:") { return true }
        guard let page else { return false }
        if inFrame, let directory = page.frameDirectory, url.isFileURL {
            let candidate = url.standardizedFileURL.deletingFragment
            return candidate.deletingLastPathComponent().path == directory.path
        }
        return url.standardizedFileURL.deletingFragment == page.permittedURL
    }
}

private extension URL {
    /// This URL with any `#fragment` removed, for comparing "the same document" against a link.
    var deletingFragment: URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }
        components.fragment = nil
        return components.url ?? self
    }
}
