import AppKit
import WebKit

/// An exported Markdown page printed to PDF (PLAN.md §M39 ▸ Slice 12): the HTML file's own bytes,
/// laid out on paper by WebKit's print path, in the light palette.
///
/// ## Why the print path
///
/// Probed when M39 opened: `WKWebView.createPDF` gives one page as long as the document (800 ×
/// 10 420 pt for a long one), which is a picture of a page and not a document. A `printOperation`
/// run headlessly, its job saved to a file, gives real pages at the user's own paper size with the
/// text selectable, 17 A4 pages in under 0.1 s for a long page (measured again 2026-11-14).
///
/// ## How it runs
///
/// Headless: a web view in a window that is never shown, the print and progress panels off, and the
/// job's disposition `.save`. `runModal(for:…)` returns at once and calls back **off the main
/// thread** when the file is written (measured), so the callback only resumes a continuation.
///
/// The page is drawn as the preview draws it and reaches no further: under the preview's own
/// block-remote rules, with no script, and with no navigation past the page itself. So a remote
/// image is not in the PDF, as it is not in the preview (Oleg's call that the export holds what the
/// preview drew).
///
/// **Light whatever the app's appearance**, and WebKit's print path sees to that by itself: measured
/// 2026-11-14 on a dark Mac, a web view drawing the dark palette on screen printed the light one,
/// while `createPDF` of the same view came out dark (71 % dark pixels against 9 %). That is where
/// M39's opening probe saw the dark appearance leak. The view is still set to `.aqua`, so the page
/// it lays out for paper is the one it would draw, rather than resting on how print resolves the
/// media query; a negative control that set it dark therefore changes nothing on paper.
@MainActor
enum MarkdownExportPDF {
    enum Failure: Error {
        /// The block-remote rules could not be compiled, so the page is not drawn at all rather
        /// than drawn unprotected.
        case noContentRules
        /// The page did not load.
        case pageDidNotLoad
        /// The print ran and wrote no file.
        case printFailed
    }

    /// The margin on every side of a sheet, in points: three quarters of an inch.
    static let margin: CGFloat = 54

    /// Print `html` to a PDF at `url`.
    static func write(_ html: Data, to url: URL) async throws {
        guard let rules = await withCheckedContinuation({ continuation in
            QuickViewWebView.contentRules { continuation.resume(returning: $0) }
        }) else { throw Failure.noContentRules }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(rules)
        // Or the inline code's fill and every alert's icon are left off the paper (measured).
        configuration.preferences.shouldPrintBackgrounds = true
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: configuration
        )
        webView.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.contentView = webView
        let load = PageLoad()
        guard let page = String(data: html, encoding: .utf8),
              await load.load(page, into: webView)
        else { throw Failure.pageDidNotLoad }
        let operation = webView.printOperation(with: printInfo(savingTo: url))
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        let succeeded = await PrintRun.run(operation, for: window)
        // Everything the job reads stays alive until it has called back.
        withExtendedLifetime((webView, window, load)) {}
        guard succeeded, FileManager.default.fileExists(atPath: url.path) else {
            throw Failure.printFailed
        }
    }

    /// The user's own paper, from the shared print info, saving to `url` with ``margin`` all round.
    private static func printInfo(savingTo url: URL) -> NSPrintInfo {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        info.topMargin = margin
        info.bottomMargin = margin
        info.leftMargin = margin
        info.rightMargin = margin
        return info
    }

    /// One load of a generated page: the page itself and nothing it would go on to, scripts off.
    @MainActor
    private final class PageLoad: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Bool, Never>?
        private var started = false

        func load(_ html: String, into webView: WKWebView) async -> Bool {
            webView.navigationDelegate = self
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
                webView.loadHTMLString(html, baseURL: nil)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            preferences: WKWebpagePreferences
        ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
            preferences.allowsContentJavaScript = false
            guard !started else { return (.cancel, preferences) }
            started = true
            return (.allow, preferences)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finish(true)
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: any Error
        ) {
            finish(false)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: any Error
        ) {
            finish(false)
        }

        private func finish(_ loaded: Bool) {
            continuation?.resume(returning: loaded)
            continuation = nil
        }
    }

    /// The print's completion, which arrives on a thread of the print system's choosing.
    private final class PrintRun: NSObject, @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        @MainActor
        static func run(_ operation: NSPrintOperation, for window: NSWindow) async -> Bool {
            let run = PrintRun()
            let succeeded = await withCheckedContinuation { continuation in
                run.hold(continuation)
                operation.runModal(
                    for: window,
                    delegate: run,
                    didRun: #selector(PrintRun.printOperationDidRun(_:success:contextInfo:)),
                    contextInfo: nil
                )
            }
            withExtendedLifetime((run, operation)) {}
            return succeeded
        }

        private func hold(_ continuation: CheckedContinuation<Bool, Never>) {
            lock.withLock { self.continuation = continuation }
        }

        @objc nonisolated func printOperationDidRun(
            _ operation: NSPrintOperation,
            success: Bool,
            contextInfo: UnsafeMutableRawPointer?
        ) {
            let continuation = lock.withLock {
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume(returning: success)
        }
    }
}
