import Foundation

/// A rendered Markdown page saved as a file of its own (PLAN.md §M39 ▸ Slice 11): the name it is
/// offered under, the title it carries, and the HTML document around the page.
///
/// The page is the preview's: the same fragment, its images inlined by the same resolver within
/// the same folder and budget, under the app's stylesheet with both appearances. So the file holds
/// what the preview drew and nothing more (Oleg's three calls, 2026-11-14). A link to another file
/// stays as written, relative, as pandoc and GitHub leave one, and no folder path of the user's is
/// written into a file they may send. A remote image keeps its URL, for the browser that opens the
/// file to fetch, as it would on any page. A document on a server carries no sibling image, since
/// the preview draws none there.
///
/// The PDF is drawn by the app through the print path (Slice 12); only its name is the core's.
public enum MarkdownExport {
    /// What a page is exported as.
    public enum Format: String, CaseIterable, Sendable {
        case html
        case pdf

        /// The extension the exported file takes, always in lower case.
        public var fileExtension: String { rawValue }
    }

    // MARK: - The name

    /// The longest name the export is offered under, in UTF-16 units and, where the source's own
    /// name kept to it, in UTF-8 bytes too.
    ///
    /// Probed 2026-11-14 on APFS: the limit there is 255 **UTF-16 units**, not bytes. 255 `é` (510
    /// bytes) and 255 `漢` (765 bytes) were created, 127 `😀` (254 units) was and 128 (256 units)
    /// was refused with `ENAMETOOLONG`. A Linux server's ext4 counts 255 bytes instead.
    public static let maximumNameLength = 255

    /// The name `source` is exported under: `README.md` gives `README.html` and `README.pdf`.
    ///
    /// The last extension is dropped by `NSString`'s rule, which leaves a dotfile whole (`.md` gives
    /// `.md.html`) and reads no extension into a name whose last dot is followed by a space. A name
    /// without one takes the format's: `README` gives `README.html`.
    ///
    /// A name grows by five units at most, when it had no extension, so it can only outgrow a limit
    /// its source was already within reach of. Then the stem loses characters from its
    /// end until the name fits every limit the source fitted: 255 UTF-16 units always, and 255
    /// UTF-8 bytes when the source kept to them. A source of 200 `é` (403 bytes) keeps all 200,
    /// since the disk it came from does not count bytes. Whole characters go, so a flag or a
    /// family emoji is never cut in half; only a single character too long to fit on its own,
    /// which takes hundreds of combining marks, is cut between its scalars.
    public static func fileName(forSource source: String, as format: Format) -> String {
        let suffix = "." + format.fileExtension
        let countsBytes = source.utf8.count <= maximumNameLength
        func fits(_ stem: some StringProtocol) -> Bool {
            stem.utf16.count + suffix.utf16.count <= maximumNameLength
                && (!countsBytes || stem.utf8.count + suffix.utf8.count <= maximumNameLength)
        }
        var stem = Substring(stemOf(source))
        while !fits(stem), stem.count > 1 {
            stem = stem.dropLast()
        }
        guard fits(stem) else {
            var scalars = String.UnicodeScalarView(stem.unicodeScalars)
            while !fits(String(scalars)) {
                scalars.removeLast()
            }
            return String(scalars) + suffix
        }
        return stem + suffix
    }

    /// `name` with its extension following a change of format: `README.html` becomes `README.pdf`.
    ///
    /// Only an extension that is the old format's, in any case, gives way. A name typed with no
    /// extension, or with one of its own, is the user's and is left as it is.
    public static func renamed(_ name: String, from old: Format, to new: Format) -> String {
        let extensionName = (name as NSString).pathExtension
        guard old != new, extensionName.lowercased() == old.fileExtension else { return name }
        return stemOf(name) + "." + new.fileExtension
    }

    /// What is wrong with a name typed for the exported file, if anything.
    public enum NameProblem: Equatable, Sendable {
        /// Nothing, or only whitespace.
        case empty
        /// A `/`, which separates folders and can be in no name.
        case containsSlash
        /// `.` or `..`, which name a folder and not a file.
        case reserved
    }

    /// Why `name` cannot be the exported file's name, or `nil` when it can. The name is taken as
    /// typed: spaces at its ends are the user's, as they are in a rename.
    public static func problem(withName name: String) -> NameProblem? {
        if name.allSatisfy(\.isWhitespace) { return .empty }
        if name.contains("/") { return .containsSlash }
        if name == "." || name == ".." { return .reserved }
        return nil
    }

    /// The largest Markdown file that is exported, in bytes: a saved page's ceiling (PLAN.md §M39 ▸
    /// Slice 2). Export reads the whole file, where the preview reads its first 4 MB, since it is one
    /// deliberate act and not a cursor step (Oleg's call, 2026-11-14).
    public static let sourceByteLimit = 64 * 1024 * 1024

    /// The title an exported page carries: the document's own (``MarkdownRender/title``), or the
    /// stem of the file's name when it names none.
    public static func title(of render: MarkdownRender, sourceName: String) -> String {
        render.title ?? stemOf(sourceName)
    }

    private static func stemOf(_ name: String) -> String {
        (name as NSString).deletingPathExtension
    }

    // MARK: - The document

    /// The policy every exported page declares: no script of any kind, no plug-in, no `<base>`
    /// and no form.
    ///
    /// The fragment can hold none of these, since `MarkdownHTML` escapes every raw tag, so this is
    /// the second wall the preview's own pages have in their content rules and their scripts
    /// switch, carried into a file that a browser will open. Images and styles are left alone,
    /// which is what keeps a remote image's URL working (Oleg's call). Probed 2026-11-14 in an
    /// offscreen `WKWebView` and in headless Chrome, a `file://` page carrying it in a `<meta>`:
    /// an inline `<script>`, an `onerror` handler and a `javascript:` link did nothing, and ran
    /// without it; a `data:` image, a sibling file and an image from a local server all drew, and
    /// the server logged the fetch.
    public static let contentSecurityPolicy =
        "script-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"

    /// The exported HTML file's bytes: `body` under `stylesheet`, titled `title`, in UTF-8.
    ///
    /// `body` is the page as the preview draws it, the core's fragment with whatever the app adds
    /// after it, and is written verbatim. `stylesheet` is the app's own, both appearances and the
    /// syntax theme, and is trusted as the preview trusts it. The title is escaped, its runs of
    /// whitespace made one space, as a browser draws it in a tab.
    ///
    /// Bytes rather than a string because the file says it is UTF-8, and this is where that is
    /// made true. The wrapper itself names nothing to load, so whatever the file fetches is what
    /// `body` and `stylesheet` ask for.
    public static func htmlDocument(title: String, stylesheet: String, body: String) -> Data {
        let page = """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(MarkdownHTML.escaped(MarkdownTitle.collapsed(title)))</title>
        <style>
        \(stylesheet)
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>

        """
        return Data(page.utf8)
    }
}
