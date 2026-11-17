import AppKit
import DirnexCore
import UniformTypeIdentifiers
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
/// never asked to go. A refused click is handed on instead, and moves the *pane* to the file it
/// names, which the preview then follows (`QuickViewWebView+Links`, §M39).
///
/// The rule list is a **precondition, not a decoration**: compiling it is asynchronous, so this view
/// cannot be built until it exists (`withContentRules`). A build that starts before the rules land
/// would render one page unprotected, and it would be the quietest possible failure — the preview
/// looks right, and only a server somewhere else knows.
@MainActor
final class QuickViewWebView: NSView {
    /// Internal, not private: `QuickViewWebView+Find` reads the page through it, and Swift's
    /// `private` does not cross files.
    let webView: QuickViewDocumentWebView
    /// What is on screen, which is the *one* navigation `decidePolicyFor` allows.
    private(set) var page: Page?
    /// Whether the web view has faded in. A new one starts transparent over the surface's own
    /// backing, and fades in when its first load ends (`fadeInOnce`).
    private var hasFadedIn = false

    /// The view the surface must let the mouse reach for the page to scroll at all.
    var interactiveSubtree: NSView { webView }

    /// Whether anything is rendered — what View ▸ Filter asks before offering to find in it.
    var hasPage: Bool { page != nil }

    // Finding in the page (`QuickViewWebView+Find`), stored here because an extension cannot.

    /// The bar over the page, hidden until ⌥⌘F.
    let filterBar: QuickViewTableFilterBar
    /// The matches, the current one and the search in flight (`QuickViewFind`).
    let find = QuickViewFind()
    /// Every child frame this page has loaded, newest last — a converted workbook's sheets. Captured
    /// in `decidePolicyFor`, which is the only place a `WKFrameInfo` for one can be had; a frame the
    /// tab strip has since replaced answers nothing and is dropped when the text is read.
    var childFrames: [WKFrameInfo] = []
    /// The frames the last read of the text actually reached, in the order it joined them.
    var findFrames: [WKFrameInfo] = []
    /// How that joined text is cut back into the documents it came from.
    var findSegments = TextSegmentMap(lengths: [])
    /// The web view's top edge: against the surface, or under the bar while it is shown.
    var filterTopToSurface: NSLayoutConstraint?
    var filterTopToBar: NSLayoutConstraint?
    /// Where the keyboard goes when the bar lets go of it: the file list the arrows walk.
    var returnKeyboard: (() -> Void)?

    // Following a link (`QuickViewWebView+Links`, PLAN.md §M39).

    /// What a click on a link that leaves the page does, given where it leads and the location of
    /// the document it was clicked in. The preview surface's, which hands it to the window.
    var onFollowLink: ((DocumentLink, VFSPath) -> Void)?
    /// The heading to scroll to once the page loading now has finished, when a link named one.
    var scrollTarget: String?

    /// Block everything, then put `file://` back — the order matters, since
    /// `ignore-previous-rules` is what re-admits the page's own bytes and its local siblings.
    /// `data:` URIs are unaffected by either rule (probed), so inlined images survive.
    ///
    /// The third rule re-admits the scheme a sealed web archive's every URL is in (PLAN.md §M39).
    /// Nothing serves that scheme but the archive WebKit was handed, so a resource the archive lacks
    /// has no network path at all, and a plain page naming it gets nothing. Measured 2026-11-12: a
    /// sealed archive drew whole under exactly these three rules with scripts on, and the server
    /// saw no request.
    private static let blockRemoteRules = """
    [
      { "trigger": { "url-filter": ".*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": "^file://" }, "action": { "type": "ignore-previous-rules" } },
      { "trigger": { "url-filter": "^\(WebArchiveSeal.scheme):" }, "action": { "type": "ignore-previous-rules" } }
    ]
    """

    private static let ruleListIdentifier = "app.dirnex.quickview.block-remote"

    /// The compiled rule list, kept for the life of the process: compiling is asynchronous and the
    /// preview is re-driven on every cursor step, so paying it once is the difference between a
    /// gate and a race.
    private static var compiledRules: WKContentRuleList?

    private init(rules: WKContentRuleList, findOptions: QuickViewFindOptionsStore) {
        filterBar = QuickViewTableFilterBar(findOptions: findOptions)
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
    static func withContentRules(
        findOptions: QuickViewFindOptionsStore,
        _ completion: @escaping (QuickViewWebView?) -> Void
    ) {
        contentRules { rules in
            completion(rules.map { QuickViewWebView(rules: $0, findOptions: findOptions) })
        }
    }

    /// The block-remote rules, compiled once for the process. Also what an exported page is printed
    /// under (`MarkdownExportPDF`), so the PDF reaches no further than the preview did.
    static func contentRules(_ completion: @escaping (WKContentRuleList?) -> Void) {
        if let compiledRules {
            completion(compiledRules)
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
                } else {
                    NSLog(
                        "Quick View: content rules failed to compile — \(String(describing: error))"
                    )
                }
                completion(list)
            }
        }
    }

    // MARK: - Content

    /// Render `url`. The read access is scoped to the file's own directory, so a page reaches the
    /// sibling stylesheet and images that make it a saved page, and nothing above it.
    ///
    /// `location` is the file's place on its own backend, which its links lead from, and `fragment`
    /// the heading a link to it named, scrolled to once it has loaded (PLAN.md §M39). A file on this
    /// disk is its own location. A file elsewhere is a local copy, and is drawn from its bytes under
    /// its location's base URL (``Page/copied(_:base:location:)``).
    func show(_ url: URL, location: VFSPath? = nil, fragment: String? = nil) {
        startNewPage(scrollingTo: fragment)
        guard let location, location.backend != .local else {
            load(.file(url.standardizedFileURL, location: location ?? .local(url.path)))
            return
        }
        load(.copied(url, base: DocumentLink.baseURL(for: location), location: location))
    }

    /// Render a document generated from `source`'s bytes — Markdown, today (PLAN.md §M18).
    ///
    /// The scan's fragment is `DirnexCore`'s; the wrapper and the stylesheet are added here, at load
    /// time, so a page always carries the palette for the appearance it is being drawn in.
    ///
    /// The base URL is the document's own path on its own backend, in a scheme nothing serves
    /// (``DirnexCore/DocumentLink/baseURL(for:)``), and it is not what reaches the file's images —
    /// measured, `loadHTMLString(_:baseURL:)` grants no filesystem access at all, which is why the
    /// images arrive already inlined (`QuickViewMarkdownImages`). What it is for is *identity*: a
    /// `#anchor` click arrives against the document, and a link to another file arrives as that
    /// file's path on the same backend, which is what lets a click move the pane there (§M39). The
    /// file's `file://` folder, the base before §M39, resolved `#anchor`, `""` and `.` all to the
    /// folder.
    func showMarkdown(
        _ scan: QuickViewPreviewView.MarkdownScan,
        source: URL,
        location: VFSPath? = nil,
        fragment: String? = nil
    ) {
        startNewPage(scrollingTo: fragment)
        let location = location ?? .local(source.path)
        load(.generated(scan, base: DocumentLink.baseURL(for: location), location: location))
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

    /// Render a saved page: `archive` is the sealed property list, `document` the sealed URL of its
    /// page, `origins` the seal's table, and `source` the file it was read from, whose place on its
    /// own backend is `location`.
    func showArchive(
        _ archive: Data,
        document: URL,
        source: URL,
        origins: [String: String] = [:],
        location: VFSPath? = nil,
        fragment: String? = nil
    ) {
        startNewPage(scrollingTo: fragment)
        load(.archive(SavedArchive(
            data: archive,
            directory: source.deletingLastPathComponent().standardizedFileURL,
            document: document,
            origins: origins,
            location: location ?? .local(source.path)
        )))
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

    private func startNewPage(scrollingTo fragment: String? = nil) {
        scrollTarget = fragment
        zoomLevel = 1
        webView.magnification = 1
        // The matches were in the page being replaced, and the new one carries no highlight to take
        // off — including the frames, whose infos belong to the document going away.
        resetFindForNewPage()
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
        resetFindForNewPage()
        webView.stopLoading()
        webView.loadHTMLString(Self.blankPage, baseURL: nil)
    }

    /// The empty document a cleared surface holds, declaring both color schemes so that WebKit paints
    /// its canvas in the view's own appearance.
    ///
    /// It is on screen for longer than its name suggests. The next rendered file unhides the surface
    /// and *then* loads, so this page is what shows until that one first paints — 40–120 ms for a
    /// Markdown file, and each time Quick View reopens on one. Measured 2026-10-18 by sampling a dark
    /// window's pixels every 8 ms: a bare `""` paints `#FFFFFF`, a white flash ahead of every dark
    /// page, while this holds `#1E1E1E`, `.textBackgroundColor`'s own dark value, so the step into the
    /// page does not show. Light paints `#FFFFFF` either way, and a blank cleared in light follows a
    /// flip to dark with no reload.
    ///
    /// What it cannot reach is a brand-new view's very first page, which still paints a frame or two
    /// of `#FFFFFF` in dark, once per surface per launch. That is not this page and not the page's
    /// palette (tinting the light one yellow left it white); loading this blank into a new view and
    /// holding the first page until it finished, and declaring `color-scheme` in the Markdown page,
    /// each measured no change in the app. A new view fades in over it instead (`fadeInOnce`).
    private static let blankPage = #"<meta name="color-scheme" content="light dark">"#

    private func load(_ page: Page) {
        self.page = page
        applyZoom()
        switch page {
        case let .file(url, _):
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        case let .copied(url, base, _):
            // The type's MIME type rather than `text/html` for all of them: XHTML parsed as HTML is
            // a different document. No encoding is named, so the page's own `<meta charset>` decides.
            let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "text/html"
            webView.load(
                (try? Data(contentsOf: url)) ?? Data(),
                mimeType: mimeType,
                characterEncodingName: "",
                baseURL: base
            )
        case let .converted(page, bundle, _, _):
            webView.loadFileURL(page, allowingReadAccessTo: bundle)
        case let .generated(scan, base, _):
            webView.loadHTMLString(
                QuickViewMarkdownStyle.document(body: scan.html, isTruncated: scan.isTruncated),
                baseURL: base
            )
        case let .archive(saved):
            webView.load(
                saved.data,
                mimeType: DirnexCore.WebArchive.mimeType,
                characterEncodingName: "",
                baseURL: saved.directory
            )
        }
    }

    // MARK: - Setup

    private func buildWebView() {
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.allowsMagnification = true
        webView.alphaValue = 0
        addSubview(webView)
        let top = webView.topAnchor.constraint(equalTo: topAnchor)
        filterTopToSurface = top
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            top,
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        installFilterBar()
        installFinding()
    }

    /// Fade the web view in over the surface's backing, the first time a load ends.
    ///
    /// A new view's first page paints a frame or two of `#FFFFFF` before its own background, in
    /// dark, once per surface per launch (`blankPage`). Measured 2026-10-18 by window capture, that
    /// frame lands 7–40 ms *after* `didFinish`, so the fade starts there and eases **in**: still a
    /// few percent opaque when it arrives, it peaked at `#35`–`#3E` over the `#1E1E1E` backing across
    /// four launches, where ease-out reached `#63`–`#76`. A fade begun when the surface appears would
    /// be most of the way opaque by then. The first load only, so stepping between files stays
    /// instant, and a failed one fades in too, so a view is never left invisible.
    func fadeInOnce() {
        guard !hasFadedIn else { return }
        hasFadedIn = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeInDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            webView.animator().alphaValue = 1
        }
    }

    private static let fadeInDuration: TimeInterval = 0.15
}
