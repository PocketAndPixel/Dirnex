import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Quick View's table, on the app side (2026-09-15): which files take this route, which style they
/// open in, and the colors a CSV's source is drawn in. Parsing is `DirnexCore`'s (`DelimitedTable`)
/// and is tested there; what reaches the screen is `QuickViewTableSurfaceTests`.
@Suite("Quick View table preview")
@MainActor
struct QuickViewTablePreviewTests {
    static let sample = #"""
    id,name,note
    1,Alice,"Paris, France"
    2,Bob,"said ""hi"""
    3,Carol,plain

    """#

    // MARK: - Routing

    @Test("CSV and TSV files are tables, and nothing else is")
    func routesDelimitedFiles() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        for name in ["data.csv", "DATA.CSV", "export.tsv", "matrix.tab"] {
            let url = try tree.write(name, contents: "a,b")
            #expect(QuickViewPreviewView.isDelimitedTable(url), "\(name) should be a table")
            #expect(QuickViewPreviewView.dualStyleKind(of: url) == .table)
            #expect(QuickViewPreviewView.offersBothStyles(url))
        }
        for name in ["notes.txt", "config.json", "README.md", "page.html", "budget.xlsx"] {
            let url = try tree.write(name, contents: "a,b")
            #expect(!QuickViewPreviewView.isDelimitedTable(url), "\(name) should not be a table")
        }
        let markdown = try tree.write("README.md", contents: "#")
        let text = try tree.write("notes.txt", contents: "x")
        #expect(QuickViewPreviewView.dualStyleKind(of: markdown) == .page)
        #expect(QuickViewPreviewView.dualStyleKind(of: text) == nil)
    }

    @Test("a .tsv promises tabs, and a .csv promises nothing, since semicolon files wear its name")
    func delimiterHints() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let tsv = try tree.write("a.tsv", contents: "x")
        let tab = try tree.write("a.tab", contents: "x")
        let csv = try tree.write("a.csv", contents: "x")
        #expect(QuickViewPreviewView.delimiterHint(for: tsv) == .tab)
        #expect(QuickViewPreviewView.delimiterHint(for: tab) == .tab)
        #expect(QuickViewPreviewView.delimiterHint(for: csv) == nil)
    }

    // MARK: - Styles

    /// The user's own request: a CSV opens as a table. And the page family must not move with it —
    /// HTML and Markdown still open as their source, which is §M16's headline decision.
    @Test("a table opens as a table and a page as its source, and each remembers its own choice")
    func stylesArePerFamily() {
        let defaults = ScratchDefaults.fresh()
        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.quickViewRenderStyle(for: .table) == .rendered)
        #expect(preferences.quickViewRenderStyle(for: .page) == .source)

        preferences.setQuickViewRenderStyle(.source, for: .table)
        #expect(preferences.quickViewRenderStyle(for: .table) == .source)
        #expect(preferences.quickViewRenderStyle(for: .page) == .source)
        preferences.setQuickViewRenderStyle(.rendered, for: .page)
        #expect(preferences.quickViewRenderStyle(for: .table) == .source)

        let reread = AppPreferences(defaults: defaults)
        #expect(reread.quickViewRenderStyle(for: .table) == .source)
        #expect(reread.quickViewRenderStyle(for: .page) == .rendered)
    }

    @Test("the rendered style is named for what it renders, and the source for neither")
    func headerLabels() {
        #expect(QuickViewRenderStyle.rendered.headerLabel(for: .table)
            != QuickViewRenderStyle.rendered.headerLabel(for: .page))
        #expect(QuickViewRenderStyle.source.headerLabel(for: .table)
            == QuickViewRenderStyle.source.headerLabel(for: .page))
    }

    @Test("neighboring columns never share a color, and the palette repeats")
    func columnPalette() {
        #expect(DelimitedColumnTheme.color(forColumn: 0) == nil)
        let count = DelimitedColumnTheme.palette.count
        for column in 0..<(count * 2) {
            let color = DelimitedColumnTheme.color(forColumn: column)
            #expect(color != DelimitedColumnTheme.color(forColumn: column + 1))
            #expect(color == DelimitedColumnTheme.color(forColumn: column + count))
        }
    }
}
