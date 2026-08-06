import AppKit
import DirnexCore

/// The text view a Quick View text preview draws into. A named subclass because two places have to
/// recognize it: the preview surface, which lets the mouse through to it (see
/// `QuickViewPreviewView.hitTest`), and the window's Esc monitor, which stands aside for every
/// `NSText` *except* this one — a rename field editor owns Esc, a preview does not.
@MainActor
final class QuickViewDocumentTextView: NSTextView {}

/// A text file's contents, selectable and copyable, as one of `QuickViewPreviewView`'s backends
/// (PLAN.md §M11).
///
/// This exists because Quick Look's preview cannot give the user their text: `QLPreviewView` renders
/// out of process, and the surface deliberately swallows the mouse rather than handing it over —
/// clicks it declines are re-dispatched to the file table underneath, which moved the covered pane's
/// cursor invisibly (docs/NOTES.md). So text takes the route PDFs and images already take: decode it
/// ourselves (`TextPreview`) and render it in-process, where a drag selects and ⌘C copies because
/// `NSTextView` implements those itself.
@MainActor
final class QuickViewTextView: NSView {
    private let scrollView = NSScrollView()
    private let textView = QuickViewDocumentTextView()
    /// Shown only for a file too big to read whole — a preview that stops early without saying so
    /// is a preview that lies about where the file ends.
    private let truncationNotice = NSVisualEffectView()

    /// The view the surface must let the mouse reach for a selection drag to work at all.
    var interactiveSubtree: NSView { scrollView }

    /// Set on the view *and* into the attributed string: `setAttributedString` replaces every
    /// attribute, so the font the view carries stops governing the moment a document is installed
    /// through the storage. One constant so the two cannot drift into different sizes.
    private static let documentFont = NSFont.monospacedSystemFont(
        ofSize: NSFont.systemFontSize,
        weight: .regular
    )

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildTextView()
        buildNotice()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Content

    /// Show a decoded file, coloured by `tokens` — which is empty for a file no grammar claims, and
    /// that case is not special: an empty loop leaves the document in the view's own `.textColor`,
    /// exactly as it rendered before M17 existed.
    func show(_ preview: TextPreview, tokens: [SyntaxToken]) {
        textView.textStorage?.setAttributedString(attributed(preview.text, tokens: tokens))
        // Back to the top for each new file: the surface is reused as the cursor walks the list, and
        // arriving at line 4000 of a file you have never opened is nobody's idea of a preview.
        textView.scroll(.zero)
        truncationNotice.isHidden = !preview.isTruncated
    }

    /// The document as one attributed string: the view's font and default colour over the whole of
    /// it, then a foreground colour per token.
    ///
    /// `textStorage` is measured safe here, which is worth stating because the neighbouring rule is
    /// the opposite: reading `.layoutManager` drops the view back to TextKit 1, where forcing layout
    /// on a large document takes seconds (docs/NOTES.md), and `NSTextView.textStorage` is
    /// historically `layoutManager.textStorage`. Probed on a real window before this was written —
    /// `textLayoutManager` is still non-`nil` after reading `.textStorage` *and* after a 4 MB
    /// `setAttributedString` through it, first display 0.03 ms and scroll-to-end 2.7 ms. The lazy
    /// layout an attributed string might have cost is intact.
    private func attributed(_ text: String, tokens: [SyntaxToken]) -> NSMutableAttributedString {
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [.font: Self.documentFont, .foregroundColor: NSColor.textColor]
        )
        let length = attributed.length
        for token in tokens {
            // The core promises in-range, ordered, non-overlapping offsets and its tests pin all
            // three — but an out-of-range `NSRange` here would *raise*, so a mismatched pair (a
            // string and tokens scanned from a different one) has to fail as a missing colour
            // rather than as a crash in a preview. Ordered, so the first miss ends the loop.
            guard token.end <= length else { break }
            guard let colour = SyntaxTheme.color(for: token.kind) else { continue }
            attributed.addAttribute(
                .foregroundColor,
                value: colour,
                range: NSRange(location: token.offset, length: token.length)
            )
        }
        return attributed
    }

    func clearText() {
        textView.string = ""
        truncationNotice.isHidden = true
    }

    // MARK: - Layout

    /// The standard non-editable, width-tracking text view — built by hand rather than through
    /// `NSTextView.scrollableTextView()` because the subclass is what the Esc monitor recognizes.
    /// Nothing here touches `layoutManager`: reading it drops the view back to TextKit 1, and it is
    /// TextKit 2's lazy layout that makes a large file free to show (measured: ~10 ms for 64 MiB).
    private func buildTextView() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        // Monospaced, like Quick Look's own text preview: a preview of a log or a config file is
        // read by column as often as by sentence.
        textView.font = Self.documentFont
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        let unbounded = CGFloat.greatestFiniteMagnitude
        textView.maxSize = NSSize(width: unbounded, height: unbounded)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: unbounded)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.documentView = textView
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    /// The "first N of this file" strip, floating over the bottom of the text. A vibrant bar for the
    /// same reason the header is one: it sits over the user's own content, where any fixed colour is
    /// wrong against half of it.
    private func buildNotice() {
        truncationNotice.material = .hudWindow
        truncationNotice.blendingMode = .withinWindow
        truncationNotice.state = .active
        truncationNotice.wantsLayer = true
        truncationNotice.layer?.cornerRadius = 6
        truncationNotice.isHidden = true
        truncationNotice.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: Self.truncationText)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        truncationNotice.addSubview(label)
        addSubview(truncationNotice)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: truncationNotice.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: truncationNotice.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: truncationNotice.topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: truncationNotice.bottomAnchor, constant: -5),
            truncationNotice.centerXAnchor.constraint(equalTo: centerXAnchor),
            truncationNotice.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
    }

    /// "Showing the first 4 MB of this file." — the limit formatted in the user's own locale, so a
    /// Russian build reads «4 МБ» like every other size in the app.
    ///
    /// `.memory`, not the `.file` style sizes are shown in: the limit is a power of two, and the
    /// decimal style renders it as the odd, over-precise "4.2 MB" for a number that was chosen as a
    /// round one.
    /// Internal, not private, and that is the point: the rendered-Markdown page ends with the same
    /// sentence (`QuickViewMarkdownStyle`), and a display string that exists twice gets localized
    /// once (docs/NOTES.md ▸ Localization).
    static var truncationText: String {
        let size = ByteCountFormatter.string(
            fromByteCount: Int64(TextPreview.byteLimit),
            countStyle: .memory
        )
        return String(
            localized: "Showing the first \(size) of this file",
            comment: "Quick View text preview footer; %@ is a formatted size such as “4 MB”."
        )
    }
}
