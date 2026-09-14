import Foundation
import Testing

@testable import DirnexCore

/// Reading back what `qlmanage -p -o` wrote for an office document (PLAN.md follow-on, 2026-09-14).
///
/// The five fixture bundles are **real** generator output, captured on macOS 26.6 from
/// `/System/Library/QuickLook/Office.qlgenerator` and `iWork.qlgenerator`, with two edits: the
/// document name in each `<title>` is replaced, and the attachment *bytes* embedded in each
/// `PreviewProperties.plist` are removed (the page names its attachments, and that is all a reader
/// consults). The Office workbook and deck are synthetic documents built for the probe; the Pages,
/// Numbers and Keynote bundles are real documents' structure with no content in them — an iWork page
/// is nothing but image references.
@Suite("Quick Look preview bundle")
struct QuickLookPreviewBundleTests {
    private struct Output {
        let html: String
        let properties: Data?
        let attachments: [String: String]

        var content: QuickLookPreviewBundle.Content? {
            QuickLookPreviewBundle.content(
                previewHTML: html,
                properties: properties,
                attachment: { attachments[$0] }
            )
        }
    }

    private func fixture(_ name: String, attachments: [String] = []) throws -> Output {
        func url(_ file: String) throws -> URL {
            let base = (file as NSString).deletingPathExtension
            let ext = (file as NSString).pathExtension
            return try #require(
                Bundle.module.url(
                    forResource: base,
                    withExtension: ext,
                    subdirectory: "Fixtures/QuickLookPreview/\(name)"
                )
            )
        }
        var pages: [String: String] = [:]
        for attachment in attachments {
            pages[attachment] = try String(contentsOf: url(attachment), encoding: .utf8)
        }
        return try Output(
            html: String(contentsOf: url("Preview.html"), encoding: .utf8),
            properties: Data(contentsOf: url("PreviewProperties.plist")),
            attachments: pages
        )
    }

    private func properties(_ values: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
    }

    private static let iWork = "/System/Library/QuickLook/iWork.qlgenerator"
    private static let office = "/System/Library/QuickLook/Office.qlgenerator"

    // MARK: - The command

    @Test("previews into the output directory, both paths as given")
    func arguments() {
        #expect(
            QuickLookPreviewBundle.arguments(
                documentPath: "/Users/me/Звіт — 2026.docx",
                outputDirectory: "/private/tmp/q/1"
            ) == ["-p", "-o", "/private/tmp/q/1", "/Users/me/Звіт — 2026.docx"]
        )
    }

    // MARK: - iWork: pages merged into one PDF

    @Test("a Pages bundle is its PDFs in document order, not attachment-number order")
    func pagesOrder() throws {
        let content = try fixture("pages").content
        // The real bundle numbers its attachments in the order the generator wrote them, which is
        // not the order the pages appear — sorting by name would shuffle the document.
        #expect(content == .pdfPages([
            "Attachment7.pdf", "Attachment8.pdf", "Attachment10.pdf", "Attachment12.pdf",
            "Attachment11.pdf", "Attachment9.pdf", "Attachment1.pdf", "Attachment13.pdf",
            "Attachment2.pdf", "Attachment6.pdf", "Attachment3.pdf", "Attachment4.pdf"
        ], fitsWidth: true))
    }

    @Test("a Keynote bundle is one PDF per slide")
    func keynote() throws {
        #expect(
            try fixture("keynote").content == .pdfPages(
                ["Attachment2.pdf", "Attachment3.pdf"],
                fitsWidth: true
            )
        )
    }

    @Test("a Numbers bundle reaches its sheet's PDF through the sheet page")
    func numbers() throws {
        let content = try fixture("numbers", attachments: ["Attachment1.html"]).content
        // The real bundle says `ShouldNotScale`, as every workbook does: a sheet is read at its size.
        #expect(content == .pdfPages(["Attachment2.pdf"], fitsWidth: false))
    }

    @Test("a sheet page that cannot be read leaves the bundle a page, never an empty PDF")
    func unreadableSheetFallsBackToPage() throws {
        let content = try fixture("numbers").content
        #expect(content == .page(allowsJavaScript: true, centersContent: false, fitWidth: nil))
    }

    @Test("sheets follow the tab strip, not the sheet the iframe happens to show")
    func sheetOrderFollowsTabStrip() throws {
        // The real single-sheet shape, widened to three: the iframe names the *selected* sheet.
        let html = """
        <script>function SelectSheet(sheetNumber, sheetURL){ frames[0].src = sheetURL; }
        function init(){ SelectSheet(0, sheetURL); }</script>
        <iframe id="SheetFrame" src="Attachment4.html" name="sheetPane"></iframe>
        <div onclick="javascript:SelectSheet(2, 'Attachment7.html');" id="Tab2">Totals</div>
        <div onclick="javascript:SelectSheet(0, 'Attachment1.html');" id="Tab0">Sheet 1</div>
        <div onclick="javascript:SelectSheet(1, 'Attachment4.html');" id="Tab1">Sheet 2</div>
        """
        let bundle = try Output(
            html: html,
            properties: properties(["MimeType": "text/html", "BaseBundlePath": Self.iWork]),
            attachments: [
                "Attachment1.html": #"<img src="Attachment2.pdf">"#,
                "Attachment4.html": #"<img src="Attachment5.pdf">"#,
                "Attachment7.html": #"<img src="Attachment8.pdf">"#,
                "sheetURL": #"<img src="Wrong.pdf">"#
            ]
        )
        #expect(
            bundle.content == .pdfPages(
                ["Attachment2.pdf", "Attachment5.pdf", "Attachment8.pdf"],
                fitsWidth: true
            )
        )
    }

    @Test("with no tab strip, the iframe's sheet is the one to read")
    func sheetFromIframeWithoutStrip() throws {
        let bundle = try Output(
            html: #"<iframe src="Attachment1.html"></iframe>"#,
            properties: properties(["MimeType": "text/html", "BaseBundlePath": Self.iWork]),
            attachments: [
                "Attachment1.html": #"<div><img src="Attachment2.pdf" width="1125"></div>"#
            ]
        )
        #expect(bundle.content == .pdfPages(["Attachment2.pdf"], fitsWidth: true))
    }

    @Test("an iWork page drawing no PDFs is still shown, as a page")
    func iWorkWithoutPDFs() throws {
        let bundle = try Output(
            html: #"<body><img src="Attachment1.png"></body>"#,
            properties: properties([
                "MimeType": "text/html", "BaseBundlePath": Self.iWork, "AllowJavascript": true
            ]),
            attachments: [:]
        )
        #expect(
            bundle.content == .page(allowsJavaScript: true, centersContent: false, fitWidth: nil)
        )
    }

    // MARK: - Office: a page

    @Test(
        "an Office workbook is a page with the generator's scripts, even though it has sheet pages"
    )
    func officeWorkbook() throws {
        // The narrowness control for the iWork rule: this page has an `<iframe src>` and three sheet
        // pages too, and none of it is a PDF page set.
        #expect(
            try fixture("xlsx-three-sheets").content == .page(
                allowsJavaScript: true,
                centersContent: false,
                // The bundle carries a `Width` of 685 *and* `ShouldNotScale`: a sheet is read at its
                // own size, so no fit width comes through.
                fitWidth: nil
            )
        )
    }

    @Test("an Office page that embeds a PDF image stays a page — its text is HTML, not the image")
    func officeWithPDFImage() throws {
        // What makes the generator the discriminator rather than the markup: a Word document with a
        // vector figure could reference a PDF, and reading it as a page set would discard every word.
        let bundle = try Output(
            html: #"<p>Real text</p><img src="Attachment1.pdf"><p>More text</p>"#,
            properties: properties([
                "MimeType": "text/html", "BaseBundlePath": Self.office, "AllowJavascript": true
            ]),
            attachments: [:]
        )
        #expect(
            bundle.content == .page(allowsJavaScript: true, centersContent: false, fitWidth: nil)
        )
    }

    @Test("an Office deck is a page")
    func officeDeck() throws {
        // No `ShouldNotScale`, so the deck's own width is carried and the page may fit the surface.
        #expect(
            try fixture("pptx").content == .page(
                allowsJavaScript: true,
                centersContent: false,
                fitWidth: 753
            )
        )
    }

    @Test("a Word document's CenterContent is carried")
    func wordCenters() throws {
        // The keys a real `.docx` bundle carries, measured.
        let bundle = try Output(
            html: "<html><body><div class=\"s1\"><p>Text</p></div></body></html>",
            properties: properties([
                "AllowJavascript": true, "AllowNetworkAccess": false, "BaseBundlePath": Self.office,
                "CanHavePages": true, "CenterContent": true, "MimeType": "text/html", "Width": 620,
                "Height": 841
            ]),
            attachments: [:]
        )
        #expect(bundle.content == .page(allowsJavaScript: true, centersContent: true, fitWidth: 620))
    }

    @Test("with no readable properties, a page gets neither scripts nor centering")
    func missingProperties() {
        let page = Output(html: "<p>x</p>", properties: nil, attachments: [:])
        let garbage = Output(
            html: "<p>x</p>",
            properties: Data("not a plist".utf8),
            attachments: [:]
        )
        #expect(page.content == .page(allowsJavaScript: false, centersContent: false, fitWidth: nil))
        #expect(
            garbage.content == .page(allowsJavaScript: false, centersContent: false, fitWidth: nil)
        )
    }

    @Test("a preview that is not HTML is not something this reads")
    func nonHTML() throws {
        let bundle = try Output(
            html: "",
            properties: properties(["MimeType": "application/pdf", "BaseBundlePath": Self.iWork]),
            attachments: [:]
        )
        #expect(bundle.content == nil)
    }

    // MARK: - Names

    @Test("only plain file names inside the bundle are ever returned")
    func attachmentNamesStayInside() {
        let html = """
        <img src="../secret.pdf"><img src="/etc/hosts.pdf"><img src="http://example.com/a.pdf">
        <img src="file:///tmp/b.pdf"><img src=".."><img src="">
        <IMG SRC='Attachment3.PDF'><img src="Attachment4.pdf"><img src=Unquoted.pdf>
        """
        #expect(
            QuickLookPreviewBundle.attributeValues(named: "src", in: html)
                == ["Attachment3.PDF", "Attachment4.pdf"]
        )
    }

    @Test("a page referenced twice is merged once")
    func deduplicates() {
        let html = #"<img src="A.pdf"><img src="B.pdf"><img src="A.pdf">"#
        #expect(
            QuickLookPreviewBundle.pdfPageSources(inPreviewHTML: html) { _ in nil } == [
                "A.pdf",
                "B.pdf"
            ]
        )
    }
}

/// The two pure pieces around the bundle: which types the generators claim, and the centering a Word
/// page asks for.
@Suite("Quick Look generator types and centering")
struct QuickLookGeneratorTypesTests {
    private func generatorInfo(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: "\(name)-generator-Info",
                withExtension: "plist",
                subdirectory: "Fixtures/QuickLookPreview"
            )
        )
        return try Data(contentsOf: url)
    }

    @Test("reads every type the Office generator claims, CSV included")
    func officeTypes() throws {
        // The generator's own `CFBundleDocumentTypes`, trimmed to the two keys that matter.
        let types = try QuickLookPreviewBundle.contentTypes(inGeneratorInfo: generatorInfo("Office"))
        #expect(types.count == 23)
        #expect(types.contains("org.openxmlformats.wordprocessingml.document"))
        #expect(types.contains("org.openxmlformats.spreadsheetml.sheet"))
        #expect(types.contains("org.openxmlformats.presentationml.presentation"))
        #expect(types.contains("com.microsoft.excel.xls"))
        #expect(types.contains("public.comma-separated-values-text"))
    }

    @Test("reads every type the iWork generator claims")
    func iWorkTypes() throws {
        let types = try QuickLookPreviewBundle.contentTypes(inGeneratorInfo: generatorInfo("iWork"))
        #expect(types.count == 16)
        #expect(types.contains("com.apple.iwork.pages.sffpages"))
        #expect(types.contains("com.apple.iwork.numbers.sffnumbers"))
        #expect(types.contains("com.apple.iwork.keynote.sffkey"))
    }

    @Test("an unreadable Info.plist claims nothing")
    func unreadableInfo() {
        #expect(QuickLookPreviewBundle.contentTypes(inGeneratorInfo: Data()).isEmpty)
        #expect(QuickLookPreviewBundle.contentTypes(inGeneratorInfo: Data("<plist/>".utf8)).isEmpty)
    }

    @Test("centering goes inside the head, ahead of the page's own rules")
    func centeringInHead() {
        let html = "<html><head><meta charset=\"utf-8\"><style>.s1.s1.s1 {width: 481;}</style></HEAD><body>"
        let centered = QuickLookPreviewBundle.centering(html)
        #expect(
            centered == "<html><head><meta charset=\"utf-8\"><style>.s1.s1.s1 {width: 481;}</style>"
                + QuickLookPreviewBundle.centeringStyle + "</HEAD><body>"
        )
    }

    @Test("a page with no head gets the centering at its start")
    func centeringWithoutHead() {
        #expect(
            QuickLookPreviewBundle.centering("<p>x</p>") == QuickLookPreviewBundle.centeringStyle + "<p>x</p>"
        )
    }
}
