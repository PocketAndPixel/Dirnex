import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Quick View's JSON preview, on the app side (2026-09-15): which files take this route, which style
/// they open in, and what the header calls it. Reading JSON is `DirnexCore`'s (`JSONDocument`) and is
/// tested there; what reaches the screen is `QuickViewJSONSurfaceTests`.
@Suite("Quick View JSON preview")
@MainActor
struct QuickViewJSONPreviewTests {
    /// A `tsconfig.json` as people write them: a comment, and commas before closing brackets.
    static let config = """
    {
      // the compiler's settings
      "compilerOptions": {"target": "ES2022", "strict": true, "paths": {"@/*": ["./src/*"]}},
      "include": ["src",],
    }
    """

    /// A JSON Lines log whose lines are alike, which is a table.
    static let lines = """
    {"role": "user", "content": "Rename it"}
    {"role": "assistant", "content": "Done", "ts": 3}

    """

    @Test(
        "the JSON family is JSON by name, the names no Mac registers included, and nothing else is"
    )
    func routesJSONFiles() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let names = [
            "package.json", "DATA.JSON", "events.jsonl", "log.ndjson", "tsconfig.jsonc",
            "app.json5",
            "notes.ipynb", "map.geojson", "Localizable.xcstrings", "Package.resolved",
            "site.webmanifest", "trace.har"
        ]
        for name in names {
            let url = try tree.write(name, contents: "{}")
            #expect(QuickViewPreviewView.isJSON(url), "\(name) should be JSON")
            #expect(QuickViewPreviewView.dualStyleKind(of: url) == .json, "\(name)")
        }
        for name in ["data.csv", "notes.txt", "README.md", "page.html", "Package.swift", "resolved"] {
            let url = try tree.write(name, contents: "{}")
            #expect(!QuickViewPreviewView.isJSON(url), "\(name) should not be JSON")
            #expect(QuickViewPreviewView.dualStyleKind(of: url) != .json, "\(name)")
        }
    }

    /// The user's choice: JSON opens as its tree, and pressing `1` on it changes JSON files only.
    @Test("JSON opens as its tree, and remembers its choice apart from tables and pages")
    func stylesArePerFamily() {
        let defaults = ScratchDefaults.fresh()
        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.quickViewRenderStyle(for: .json) == .rendered)

        preferences.setQuickViewRenderStyle(.source, for: .json)
        #expect(preferences.quickViewRenderStyle(for: .json) == .source)
        #expect(preferences.quickViewRenderStyle(for: .table) == .rendered)
        #expect(preferences.quickViewRenderStyle(for: .page) == .source)
        preferences.setQuickViewRenderStyle(.rendered, for: .page)
        preferences.setQuickViewRenderStyle(.source, for: .table)
        #expect(preferences.quickViewRenderStyle(for: .json) == .source)

        let reread = AppPreferences(defaults: defaults)
        #expect(reread.quickViewRenderStyle(for: .json) == .source)
        #expect(reread.quickViewRenderStyle(for: .table) == .source)
        #expect(reread.quickViewRenderStyle(for: .page) == .rendered)
    }

    @Test("the rendered style is called Tree for JSON, unlike a table's and a page's")
    func headerLabels() {
        let tree = QuickViewRenderStyle.rendered.headerLabel(for: .json)
        #expect(tree != QuickViewRenderStyle.rendered.headerLabel(for: .table))
        #expect(tree != QuickViewRenderStyle.rendered.headerLabel(for: .page))
        #expect(QuickViewRenderStyle.source.headerLabel(for: .json)
            == QuickViewRenderStyle.source.headerLabel(for: .page))
    }
}
