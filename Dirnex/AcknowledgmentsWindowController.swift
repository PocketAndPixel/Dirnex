import AppKit

/// About ▸ Acknowledgments: the notices of the open-source code inside Dirnex.app, and the license
/// Dirnex itself is under.
///
/// It shows two files the Xcode project copies into the bundle's Resources, as they are: `NOTICE`,
/// which names every bundled component and carries its license in full, and `LICENSE` (Apache 2.0).
/// The MIT and BSD licenses of the bundled code ask for their text in every copy, so the files are
/// what matters, and `scripts/build_app.sh` refuses an export without them. This window is where a
/// person can read them. The text stays in English, as licenses are, in a monospaced font that keeps
/// their own layout.
///
/// The About panel can only open links, through Launch Services, so it links to
/// `dirnex://acknowledgments`, which comes back to this app through `application(_:open:)`. Any web
/// page can open that link too, and all it does is show this window.
@MainActor
final class AcknowledgmentsWindowController: NSWindowController {
    static let shared = AcknowledgmentsWindowController()

    static let link = URL(string: "dirnex://acknowledgments")!

    /// The window's title, and the About panel's link to it.
    static var title: String {
        String(
            localized: "Acknowledgments",
            comment: "About panel link, and the title of the window listing the open-source code in Dirnex."
        )
    }

    /// The files shown, in order, by their names in the bundle's Resources.
    static let files = ["NOTICE", "LICENSE"]

    let textView: NSTextView

    private init() {
        let scrollView = NSTextView.scrollableTextView()
        textView = scrollView.documentView as? NSTextView ?? NSTextView()
        textView.isEditable = false
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.string = Self.text() ?? ""
        textView.setAccessibilityLabel(Self.title)

        // Wide enough for the files' 80 columns; a longer line wraps.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.title = Self.title
        window.contentView = scrollView
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 240)
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Whether `url` is ``link``. The scheme and host are case-insensitive, as URL schemes and hosts
    /// are.
    static func isLink(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme?.lowercased() == link.scheme
            && components.host?.lowercased() == link.host
            && (components.path.isEmpty || components.path == "/")
    }

    /// Shows the window if `url` is ``link``, and says whether it was.
    @discardableResult
    static func handle(_ url: URL) -> Bool {
        guard isLink(url) else { return false }
        shared.present()
        return true
    }

    /// The files' text, one after the other under a rule, or `nil` when one is missing from `bundle`.
    static func text(in bundle: Bundle = .main) -> String? {
        let texts = files.compactMap { name in
            bundle.url(forResource: name, withExtension: nil).flatMap {
                try? String(contentsOf: $0, encoding: .utf8)
            }
        }
        guard texts.count == files.count else { return nil }
        return texts.joined(separator: "\n" + String(repeating: "=", count: 80) + "\n\n")
    }

    func present() {
        guard let window else { return }
        if !window.isVisible {
            window.centerOnScreen()
            textView.scrollToBeginningOfDocument(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
