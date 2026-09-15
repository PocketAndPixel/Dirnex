import AppKit
import DirnexCore
import UniformTypeIdentifiers

/// Quick View's text backend: which files it takes, and how their bytes reach it.
///
/// The third in-process backend, and it exists for the reason the other two do — something the
/// out-of-process `QLPreviewView` cannot give the user. `PDFView` was zoom, `NSImageView` was a
/// swipe that doesn't judder; this one is **selecting and copying the text**, which a Quick Look
/// preview can never offer here because the surface has to swallow the mouse (a click it declines is
/// re-dispatched to the file table underneath — docs/NOTES.md).
extension QuickViewPreviewView {
    /// Show `url` as text, standing the other backends down.
    ///
    /// The read is off the main actor, like the image backend's, so a multi-megabyte log does not
    /// stall the flip animation; `TextPreview` is `Sendable` where an `NSTextView` is not, which is
    /// why only the decoded value crosses back.
    ///
    /// A file that turns out not to be text after all — a binary someone named `.txt`, bytes in an
    /// encoding nothing claims — decodes to `nil` and falls back to Quick Look, which is exactly
    /// what it got before this backend existed.
    ///
    /// `refusingPlaceholders` is for a file routed here by its bytes alone (`isUnclaimed`): one whose
    /// bytes are in a cloud goes to Quick Look unread, since reading its first byte would download it
    /// because the cursor passed over a row that Quick Look drew as an icon.
    func showText(_ url: URL, refusingPlaceholders: Bool = false) {
        let surface = ensureTextSurface()
        standDownPDF()
        standDownQuickLook()
        standDownImage()
        standDownWeb()
        surface.isHidden = false
        loadToken += 1
        let token = loadToken
        // Asked here, on the main actor, and handed to the read: a delimited file is colored by
        // column rather than by a grammar.
        let isDelimited = Self.isDelimitedTable(url)
        let delimited = isDelimited ? Self.delimiterHint(for: url) : nil
        Task { [weak self] in
            let scan = await BlockingWork.run { () -> TextScan? in
                if refusingPlaceholders, Self.isPlaceholder(url) { return nil }
                return isDelimited
                    ? TextScan.readDelimited(url, delimiterHint: delimited)
                    : TextScan.read(url)
            }
            guard let self, token == loadToken else { return }
            guard let scan else {
                standDownText()
                showQuickLook(url)
                return
            }
            surface.show(scan.preview, tokens: scan.tokens, columns: scan.columns)
        }
    }

    /// A decoded file and its colored spans — everything the detached read produces, crossing back
    /// to the main actor as one value (PLAN.md §M17 ▸ Slice 3).
    ///
    /// The tokenize rides the read task rather than taking one of its own, for the reason the read
    /// is detached at all: the preview re-runs on **every cursor step**, so both have to be off the
    /// main actor and both have to be discarded together by the one `loadToken` guard. Measured
    /// at the 4 MB ceiling `TextPreview.byteLimit` allows, the scan is ~58 ms; a source file of any
    /// ordinary size is under 3 ms.
    ///
    /// `Sendable` is the whole reason this is a struct and not two `inout`s: an
    /// `NSMutableAttributedString` cannot cross an actor boundary, so what crosses is the *tokens*,
    /// and the app builds the attributed string on the main actor from them.
    struct TextScan: Sendable {
        let preview: TextPreview
        let tokens: [SyntaxToken]
        /// Where each field of a CSV or TSV file sits, for coloring by column. Empty for any other
        /// file.
        var columns: [DelimitedFieldSpan] = []

        /// The most fields a source view colors. Each is an attribute run built and installed on the
        /// main actor, and a 4 MB file of short values is a million of them: measured (release),
        /// coloring all 1.13 million costs 129 ms to build and 93 ms to install, and this many 23 +
        /// 17 ms. Past it the rest of the file is drawn in the text color, as it was before columns
        /// were colored. A 3 MB, 18 800-row matrix is 131 000 fields and is colored whole.
        static let columnSpanLimit = 200_000

        /// Blocking; call it off the main thread. `nil` for a file that is not text after all,
        /// which is `TextPreview`'s own answer and sends the caller back to Quick Look.
        static func read(_ url: URL) -> TextScan? {
            guard let preview = TextPreview.read(contentsOf: url) else { return nil }
            // By name, not by content type — the inversion is argued in `SyntaxLanguage`: `UTType`
            // answers `public.c-header` for a `.h` and cannot say which of three languages it is.
            // A name that claims nothing falls back to a `#!` line, which is how a script with no
            // extension gets colored. A file neither claims tokenizes to nothing and renders exactly
            // as it did before.
            let name = url.lastPathComponent
            guard let language = SyntaxLanguage.forFile(named: name, text: preview.text) else {
                return TextScan(preview: preview, tokens: [])
            }
            return TextScan(
                preview: preview,
                tokens: SyntaxHighlighter.tokens(in: preview.text, language: language)
            )
        }

        /// Read a CSV or TSV file and find its fields. A file that does not parse as a table is
        /// shown in one color, exactly as a file no grammar claims is.
        static func readDelimited(
            _ url: URL,
            delimiterHint: DelimitedTable.Delimiter?
        ) -> TextScan? {
            guard let preview = TextPreview.read(contentsOf: url) else { return nil }
            let table = DelimitedTable.parse(
                preview.text,
                isTruncated: preview.isTruncated,
                delimiterHint: delimiterHint
            )
            return TextScan(
                preview: preview,
                tokens: [],
                columns: table?.fieldSpans(limit: columnSpanLimit) ?? []
            )
        }
    }

    func standDownText() {
        textSurface?.isHidden = true
        textSurface?.clearText()
    }

    /// Whether `url` is text this backend should render rather than Quick Look.
    ///
    /// Anything conforming to `public.text` — which is `.txt` and `.md`, but also JSON, XML, YAML,
    /// `.strings`, source code and logs — **except** the two families Quick Look renders as
    /// documents rather than as their source. An HTML file previews as the page it describes and RTF
    /// with its formatting; showing either as raw markup would be a regression dressed up as a
    /// feature.
    ///
    /// Content type first (an odd extension still classifies), extension as the fallback, matching
    /// the PDF and image routing beside it.
    ///
    /// **A property list too**, which is not `public.text`: `.plist` is `com.apple.property-list`
    /// and `.stringsdict` conforms to it, because either may be binary. Probed 2026-09-16, only
    /// those two and `.entitlements` and `.xcprivacy` (already text) conform; `.webloc` and the other
    /// plist-shaped Finder files do not. An XML one shows as its markup, colored; a binary one
    /// holds a NUL in its first bytes, so `TextPreview` refuses it and it goes to Quick Look as
    /// before, which shows it converted to XML with its keys sorted, in one color.
    static func isText(_ url: URL) -> Bool {
        guard let type = contentType(of: url) else { return false }
        if type.conforms(to: .propertyList) { return true }
        guard type.conforms(to: .text) else { return false }
        return !type.conforms(to: .html) && !type.conforms(to: .rtf)
    }

    /// Whether no type on this Mac says what `url` is, so only its bytes can say whether it is text.
    ///
    /// Probed 2026-09-15: a name with no extension resolves to bare `public.data` (`VERSION`,
    /// `NOTICE`, `Dockerfile`, `.gitignore`, `.zshrc`), a name with an extension nothing declares to
    /// a dynamic type that conforms to nothing (`.conf`, `.env`, `.lock`, `.vue`, `.dart`), and a
    /// script with its execute bit set to `public.unix-executable`. `isText` refuses all three, so
    /// they went to Quick Look, which draws a question-mark document for them. Of the 46 000 such files
    /// on this Mac, 11 687 were text.
    ///
    /// A type that is declared but not text (a certificate, a VLC module) keeps whatever Quick Look
    /// does with it; only the three shapes above are asked.
    static func isUnclaimed(_ url: URL) -> Bool {
        guard let type = contentType(of: url) else { return true }
        return type == .data || type == .unixExecutable || type.isDynamic
    }

    /// Whether `url` is a cloud placeholder (`SF_DATALESS`), whose first read downloads it. A `stat`
    /// that follows a symlink, since the read that would download it follows one too.
    nonisolated static func isPlaceholder(_ url: URL) -> Bool {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return false }
        return info.st_flags & UInt32(SF_DATALESS) != 0
    }

    private static func contentType(of url: URL) -> UTType? {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type
        }
        return UTType(filenameExtension: url.pathExtension)
    }

    /// Build the text backend on first use and pin it over the surface, alongside the other two.
    /// Internal, not private: the rich-text backend draws into the same surface from its own file.
    func ensureTextSurface() -> QuickViewTextView {
        if let textSurface { return textSurface }
        let surface = QuickViewTextView()
        pin(surface, inside: content)
        textSurface = surface
        return surface
    }
}
