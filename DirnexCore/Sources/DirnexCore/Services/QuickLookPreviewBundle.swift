import Foundation

/// What macOS's own Quick Look generator made of a document, read back from the `.qlpreview`
/// directory `qlmanage -p -o` writes — the pure half of Quick View's office-document backend.
///
/// ## Why a generator's output and not the generator's view
///
/// Word, Excel, PowerPoint, Pages, Numbers and Keynote files used to reach Quick View's out-of-process
/// `QLPreviewView`, which cannot give the user any of what a document preview is for: the surface has
/// to swallow the mouse (a click the remote view declines is re-dispatched to the file table
/// underneath — docs/NOTES.md), so a `.docx`'s page arrows could not be clicked, nothing could be
/// selected, nothing zoomed, and a spreadsheet was a thumbnail. What the remote view *draws*, though,
/// is ordinary data. Measured 2026-09-14 on macOS 26.6, `/System/Library/QuickLook/Office.qlgenerator`
/// turns every Office format into real HTML — text, tables, a tab strip for a workbook's sheets, images
/// as sibling files — and `iWork.qlgenerator` turns every Pages, Numbers and Keynote document into one
/// vector PDF per page or sheet, carrying real text. Both land in 50–740 ms.
///
/// That output is reachable two ways, and only one is supported: the in-process `QLPreview*` C API
/// exists in `QuickLook.tbd` and has no header, so it is private; `qlmanage -p -o <dir>` is the stock
/// tool, documented in its own `-h` ("Output result in dir"). So the app spawns the tool and this
/// reads what it wrote: Office output renders as a page, iWork output is merged into one PDF, and
/// the in-process web view and `PDFView` give back scrolling, zoom and selection.
///
/// The app owns the spawn (non-hermetic, like every other tool), this owns the reading, so the rules
/// about a directory somebody else's code wrote are tested against captured bytes.
public enum QuickLookPreviewBundle {
    /// The stock tool. An absolute path, never a `PATH` lookup: this runs for every document the
    /// cursor rests on.
    public static let executablePath = "/usr/bin/qlmanage"

    /// The page the generator wrote, inside the bundle.
    public static let previewFileName = "Preview.html"
    /// The generator's own description of that page.
    public static let propertiesFileName = "PreviewProperties.plist"
    /// The extension of the one directory `qlmanage` creates inside the output directory. Found by
    /// extension rather than predicted by name, because the name is the document's own and the
    /// document may be called anything.
    public static let bundleExtension = "qlpreview"

    /// The generator whose pages are PDF images — see ``Content/pdfPages(_:fitsWidth:)``.
    static let pageImageGenerator = "iWork.qlgenerator"

    /// The two generators this route exists for, as the `Info.plist` each declares its types in.
    ///
    /// Read rather than transcribed, so the route covers exactly what the system can convert today:
    /// 23 Office types and 16 iWork types on macOS 26.6, including the template, macro-enabled and
    /// slideshow variants nobody would think to list. (One of the 23 is CSV, which the app keeps as
    /// a text file: the caller filters out anything that is text.) And if a later macOS drops a generator, its
    /// types simply stop routing here and go back to Quick Look's own view — the degradation that
    /// cannot be wrong, where a transcribed list would send every such file to a tool that answers
    /// nothing.
    public static let generatorInfoPaths = [
        "/System/Library/QuickLook/Office.qlgenerator/Contents/Info.plist",
        "/System/Library/QuickLook/iWork.qlgenerator/Contents/Info.plist"
    ]

    /// The content type identifiers a generator's `Info.plist` claims, in declaration order.
    public static func contentTypes(inGeneratorInfo data: Data) -> [String] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any],
            let documentTypes = plist["CFBundleDocumentTypes"] as? [[String: Any]]
        else { return [] }
        return documentTypes.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
    }

    /// The stylesheet that honors a bundle's `CenterContent`: a Word page is one fixed-width block,
    /// and the generator leaves placing it to whoever shows it.
    ///
    /// `!important` because the generator styles that block through triple-class selectors
    /// (`.s1.s1.s1`) that outrank anything shorter.
    static let centeringStyle = "<style>body > div { margin-left: auto !important; "
        + "margin-right: auto !important; }</style>"

    /// `html` with ``centeringStyle`` added — inside the head when there is one, so it applies before
    /// the page's own rules are parsed, and at the very start otherwise.
    public static func centering(_ html: String) -> String {
        if let head = html.range(of: "</head>", options: .caseInsensitive) {
            return html.replacingCharacters(
                in: head.lowerBound..<head.lowerBound,
                with: centeringStyle
            )
        }
        return centeringStyle + html
    }

    /// The argument vector for previewing `documentPath` into `outputDirectory`.
    ///
    /// `-p` asks for a preview rather than a thumbnail and `-o` writes it instead of opening a
    /// window. Both paths are absolute, so neither can begin with a `-` and be read as a flag.
    public static func arguments(documentPath: String, outputDirectory: String) -> [String] {
        ["-p", "-o", outputDirectory, documentPath]
    }

    /// How a generated bundle is to be shown.
    public enum Content: Equatable, Sendable {
        /// Load ``QuickLookPreviewBundle/previewFileName`` as a page, with scripts on only when the
        /// generator asked for them.
        ///
        /// An Office workbook with more than one sheet draws a tab strip that re-points an iframe
        /// from a script *the generator wrote* — measured: with scripts off the tabs are drawn and do
        /// nothing. Quick Look itself renders these pages with scripts on and network off
        /// (`AllowJavascript` true, `AllowNetworkAccess` false in every Office bundle measured), which
        /// is exactly the posture the app's content rules already enforce. The document's own content
        /// cannot become script: cell text arrives escaped (`<script>` in a cell was measured coming
        /// out as `&lt;script>`).
        ///
        /// `centersContent` is the generator's `CenterContent` — set for Word documents, whose page is
        /// a fixed-width block that otherwise sits against the left edge of a wide surface.
        ///
        /// `fitWidth` is the width the generator laid the page out at, when it may be scaled to fit
        /// the surface: its `Width`, unless the bundle says `ShouldNotScale`. Measured, every workbook
        /// says so (a sheet is read at its own size and scrolls sideways) and a Word document (620)
        /// and a deck (753) do not — which is why Quick Look's own view draws a Word page across the
        /// panel and a sheet at 100 %.
        case page(allowsJavaScript: Bool, centersContent: Bool, fitWidth: Double?)
        /// Merge these bundle files, in order, into one PDF: the iWork generator's page is a column
        /// of `<img src="AttachmentN.pdf">`, one per page, slide or sheet — so as a *web* page every
        /// word in it is a picture. The PDFs themselves carry real text (measured with PDFKit on a
        /// Pages, a Numbers and a Keynote bundle), which is what makes a PDF view the right surface.
        ///
        /// `fitsWidth` is the same `ShouldNotScale` answer the page case carries: a Pages document and
        /// a Keynote deck are fitted to the surface, a Numbers sheet is shown at its own size — fitted
        /// into a narrow pane, a 1 110-point sheet came out at half size, the thumbnail problem again.
        case pdfPages([String], fitsWidth: Bool)
    }

    /// Interpret a bundle from its page and properties, reading any sheet page it references through
    /// `attachment`. `nil` when the generator produced something that is not a page at all — which is
    /// the caller's cue to fall back to Quick Look's own view rather than to guess.
    ///
    /// `properties` is optional because the page is what matters: a missing or unreadable plist reads
    /// as "no scripts, no centering", the safe answer to both questions.
    public static func content(
        previewHTML: String,
        properties: Data?,
        attachment: (String) -> String?
    ) -> Content? {
        let plist = properties.flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        } ?? [:]
        if let mime = plist["MimeType"] as? String, mime.lowercased() != "text/html" {
            return nil
        }
        let generator = (plist["BaseBundlePath"] as? String).map { ($0 as NSString).lastPathComponent }
        let scalable = !(plist["ShouldNotScale"] as? Bool ?? false)
        if generator == pageImageGenerator {
            let pages = pdfPageSources(inPreviewHTML: previewHTML, attachment: attachment)
            // A future generator that stops drawing pages as PDFs still wrote a page; showing it as
            // one loses selection and nothing else.
            if !pages.isEmpty { return .pdfPages(pages, fitsWidth: scalable) }
        }
        let width = (plist["Width"] as? NSNumber)?.doubleValue
        return .page(
            allowsJavaScript: plist["AllowJavascript"] as? Bool ?? false,
            centersContent: plist["CenterContent"] as? Bool ?? false,
            fitWidth: scalable ? width.flatMap { $0 > 0 ? $0 : nil } : nil
        )
    }

    /// The PDF files an iWork page draws, in reading order.
    ///
    /// Two shapes, both measured. Pages and Keynote list their pages directly as `<img>` elements in
    /// document order. Numbers wraps each sheet in its own page — `SelectSheet(n, 'AttachmentK.html')`
    /// in the tab strip, plus an `<iframe src>` pointing at whichever sheet is showing — and each sheet
    /// page holds the sheet's PDF. The tab strip is the order when there is one, because the iframe
    /// names the sheet that happened to be *selected*, which need not be the first; the iframe is the
    /// fallback for a bundle with no strip.
    static func pdfPageSources(inPreviewHTML html: String, attachment: (String) -> String?) -> [
        String
    ] {
        var sources = attributeValues(named: "src", in: html).filter(isPDF)
        let sheets = sheetPages(in: html)
        let sheetPages = sheets.isEmpty
            ? attributeValues(named: "src", in: html).filter(isHTML)
            : sheets
        for sheet in sheetPages {
            guard let body = attachment(sheet) else { continue }
            sources += attributeValues(named: "src", in: body).filter(isPDF)
        }
        var seen = Set<String>()
        return sources.filter { seen.insert($0).inserted }
    }

    /// The sheet pages a Numbers tab strip selects, ordered by the index the strip gives them.
    static func sheetPages(in html: String) -> [String] {
        var sheets: [(index: Int, page: String)] = []
        var rest = html[...]
        while let call = rest.range(of: "SelectSheet(") {
            rest = rest[call.upperBound...]
            guard let close = rest.firstIndex(of: ")") else { break }
            let arguments = rest[..<close].split(separator: ",", maxSplits: 1)
            rest = rest[close...]
            guard arguments.count == 2,
                  let index = Int(arguments[0].trimmingCharacters(in: .whitespaces)) else { continue }
            // Only a quoted literal is a page: the generator's own script calls the same function
            // with a *variable* (`SelectSheet(0, sheetURL)`, in the real bundle), which is a plain
            // name as far as the file-name rule can tell.
            let argument = arguments[1].trimmingCharacters(in: .whitespaces)
            guard let quote = argument.first, quote == "'" || quote == "\"",
                  argument.count >= 2, argument.last == quote else { continue }
            let page = String(argument.dropFirst().dropLast())
            if isAttachmentName(page) { sheets.append((index, page)) }
        }
        return sheets.sorted { $0.index < $1.index }.map(\.page)
    }

    /// Every value of `attribute` in `html`, in document order, keeping only plain bundle file names.
    ///
    /// A scanner rather than a parser, and deliberately narrow: the input is a generator's own
    /// markup, the only question is which sibling files it names, and a name that is not a plain
    /// file name — a path, `..`, a URL — is dropped rather than resolved, so nothing this returns can
    /// point outside the bundle it came from.
    static func attributeValues(named attribute: String, in html: String) -> [String] {
        var values: [String] = []
        var rest = html[...]
        let marker = attribute + "="
        while let found = rest.range(of: marker, options: .caseInsensitive) {
            rest = rest[found.upperBound...]
            guard let quote = rest.first, quote == "\"" || quote == "'" else { continue }
            rest = rest.dropFirst()
            guard let end = rest.firstIndex(of: quote) else { break }
            let value = String(rest[..<end])
            rest = rest[end...]
            if isAttachmentName(value) { values.append(value) }
        }
        return values
    }

    /// Whether `name` is a file directly inside the bundle: non-empty, no separator, not `.` or `..`.
    static func isAttachmentName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
            && !name.contains(":") && !name.contains("\0")
    }

    private static func isPDF(_ name: String) -> Bool {
        (name as NSString).pathExtension.lowercased() == "pdf"
    }

    private static func isHTML(_ name: String) -> Bool {
        ["html", "htm"].contains((name as NSString).pathExtension.lowercased())
    }
}
