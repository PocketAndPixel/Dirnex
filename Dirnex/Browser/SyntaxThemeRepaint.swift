import AppKit
import WebKit

/// Redraw everything a syntax color reaches, after the user picks another theme (PLAN.md §M39 ▸
/// Slice 10).
///
/// Every surface already holds `SyntaxTheme`'s following colors, which resolve to the new theme at
/// their next draw, so what is left is to make them draw. This does by hand what AppKit does on a
/// light/dark flip: it walks every window's views rather than asking each surface to know about the
/// theme, so a surface added later (or a compare window nobody thought of) is reached without being
/// listed anywhere.
///
/// - **Every view** is marked for display, subviews included, since each layer-backed view keeps its
///   own drawing. That is all a TextKit 2 text view needs as well as a label: measured 2026-11-14 in
///   the running app, the open Swift preview took the new theme's colors with no layout invalidated,
///   and kept the old ones when this walk was switched off.
/// - A **rendered Markdown page** has its baked token colors replaced in place: one `<style>`,
///   rewritten by a script in the client world, which runs with the page's own scripts off and keeps
///   the reader's place where a reload would throw it away. A page with no such `<style>` (an HTML
///   file, a saved page) is left alone, and any page loaded later is generated in the new theme.
@MainActor
final class SyntaxThemeRepaint: NSObject {
    private static let shared = SyntaxThemeRepaint()

    override private init() {
        super.init()
        // The shared preferences only: a test's own instance, on a scratch domain, changes no color
        // on screen (`SyntaxTheme.current` follows the shared one alone).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeChanged),
            name: AppPreferences.syntaxThemeDidChange,
            object: AppPreferences.shared
        )
    }

    /// Touch the singleton at launch so it is observing before the Settings window can be opened,
    /// as `VaultVisibility.start()` does.
    static func start() { _ = shared }

    @objc private func themeChanged() {
        Self.repaint(NSApp.windows)
    }

    static func repaint(_ windows: [NSWindow]) {
        let css = QuickViewMarkdownStyle.syntaxPalette(SyntaxTheme.current)
        for window in windows {
            guard let content = window.contentView else { continue }
            repaint(content, css: css)
        }
    }

    private static func repaint(_ view: NSView, css: String) {
        if let webView = view as? QuickViewDocumentWebView {
            restyle(webView, css: css)
        }
        view.needsDisplay = true
        for subview in view.subviews {
            repaint(subview, css: css)
        }
    }

    /// Replace the page's token colors with `css`. Internal so a test can drive it with a palette
    /// of its own; the completion says whether the page had the `<style>` to replace.
    static func restyle(
        _ webView: WKWebView,
        css: String,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        Task { @MainActor in
            let replaced = try? await webView.callAsyncJavaScript(
                restyleScript,
                arguments: ["css": css],
                in: nil,
                contentWorld: .defaultClient
            )
            completion?(replaced as? Bool == true)
        }
    }

    private static let restyleScript = """
    const style = document.head
      && document.head.querySelector('style[\(QuickViewMarkdownStyle.syntaxStyleAttribute)]');
    if (!style) { return false; }
    style.textContent = css;
    return true;
    """
}
