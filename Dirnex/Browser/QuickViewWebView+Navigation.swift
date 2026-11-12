import AppKit
import DirnexCore
import WebKit

/// What a previewed page may navigate to: the one load it was pointed at, its own fragments, and the
/// frames its kind of page is allowed. Moved out of `QuickViewWebView.swift` at M39 Slice 2, when the
/// web archive's frames arrived and the class file met SwiftLint's length ceiling.
extension QuickViewWebView: WKNavigationDelegate {
    /// Allow the file this preview was pointed at, and nothing else.
    ///
    /// The rule list already stops a remote *load*; refusing the navigation covers a different
    /// case. A click on a link in a previewed page would otherwise replace what the header names
    /// with something else — a preview that has quietly become a browser, showing a document the
    /// user never selected. An in-page anchor (`#top`) is the one exception, since it moves the
    /// reading position rather than the document.
    ///
    /// Refused is not ignored, since §M39: a click the policy turns down is handed on
    /// (`followLink`), and a link to another file moves the pane's cursor there, which the preview
    /// then follows with its header naming the new file. So the preview never shows what the list
    /// does not, and the pane's Back is the way back.
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
        let isClick = Self.isClick(navigationAction)
        let allowed = isPermitted(url, inFrame: inFrame, isClick: isClick)
        // The one place a `WKFrameInfo` for a child frame can be had, and the only way to search a
        // converted workbook's sheet: a `file://` frame is a different origin, so no script running
        // in the page can reach into it (`QuickViewWebView+Find`).
        if allowed, inFrame, let frame = navigationAction.targetFrame {
            childFrames.append(frame)
        }
        if !allowed, isClick, !inFrame { followLink(url) }
        return (allowed ? .allow : .cancel, preferences)
    }

    /// A load finished. The DOM a reload rebuilds carries none of the highlights the search drew, so
    /// they go back on rather than the user having to retype; and a heading the link that led here
    /// named is scrolled to, now that it exists.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        fadeInOnce()
        redrawFindAfterReload()
        scrollToTarget()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        fadeInOnce()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        fadeInOnce()
    }

    /// The empty document `clearPage` loads, and the page this preview is showing — compared
    /// without the fragment, so an in-page anchor still works.
    ///
    /// For a generated document that comparison is against its base URL, the document's own path
    /// (``DirnexCore/DocumentLink/baseURL(for:)``), which is what the page's links resolve against.
    /// A **click** must also carry a fragment to be allowed: since §M39 a refused click is followed
    /// rather than dropped, so a link to the page itself with no `#anchor` — `""`, `index.html` from
    /// `index.html` — is refused here and lands on the document it already shows. The initial load
    /// and a reload are not clicks, so they still pass on the comparison alone.
    ///
    /// An embedded frame is the one other thing a *converted* page may load: a sheet page from inside
    /// its own bundle, and nothing outside it — a link in a workbook cell must no more replace a sheet
    /// with a web page than it may replace the document.
    ///
    /// A saved page (PLAN.md §M39) has two more. Its frames load from the archive, so a frame may go
    /// anywhere in the sealed scheme that is not a click: the scheme reaches nothing but the archive,
    /// and a click in a frame is the same small browser a click in the page would be. And its
    /// `#anchor` links arrive against the archive's own document, not the base URL the load named.
    func isPermitted(_ url: URL, inFrame: Bool, isClick: Bool) -> Bool {
        if url.absoluteString.hasPrefix("about:") { return true }
        guard let page else { return false }
        if inFrame, let directory = page.frameDirectory, url.isFileURL {
            let candidate = url.standardizedFileURL.deletingFragment
            return candidate.deletingLastPathComponent().path == directory.path
        }
        if let document = page.archiveDocument {
            if inFrame { return !isClick && url.scheme?.lowercased() == WebArchiveSeal.scheme }
            if url.fragment != nil, url.deletingFragment == document.deletingFragment { return true }
        }
        if isClick, !inFrame, url.fragment == nil { return false }
        return url.standardizedFileURL.deletingFragment == page.permittedURL
    }

    /// Whether `action` is the user following a link or sending a form, rather than the page loading
    /// what it is made of.
    static func isClick(_ action: WKNavigationAction) -> Bool {
        action.navigationType == .linkActivated || action.navigationType == .formSubmitted
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
