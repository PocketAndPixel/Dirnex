import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Quick View's XML preview, on the app side (2026-09-16): which files take this route, which style
/// they open in, and what reaches the screen — the element tree with its attribute rows, a property
/// list's keys and values, a list of like elements in the table — sharing the JSON tree's surface.
/// Reading XML is `DirnexCore`'s (`XMLTree`, `PropertyListTree`) and is tested there.
@Suite("Quick View XML preview")
@MainActor
struct QuickViewXMLPreviewTests {
    static let project = """
    <?xml version="1.0" encoding="utf-8"?>
    <Project Sdk="Microsoft.NET.Sdk">
      <PropertyGroup>
        <TargetFramework>net8.0</TargetFramework>
      </PropertyGroup>
      <ItemGroup>
        <PackageReference Include="Serilog" Version="3.1.1" />
      </ItemGroup>
    </Project>
    """

    static let resources = """
    <resources>
      <string name="app_name">Market</string>
      <string name="ok">OK</string>
    </resources>
    """

    static let info = """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0">
    <dict>
      <key>CFBundleName</key>
      <string>Dirnex</string>
      <key>LSUIElement</key>
      <false/>
    </dict>
    </plist>
    """

    private func loaded(
        _ name: String,
        _ contents: String,
        in tree: TempDirectory,
        style: QuickViewRenderStyle = .rendered,
        function: String = #function
    ) async throws -> QuickViewPreviewView {
        try await QuickViewTableFixtures.loaded(
            try tree.write(name, contents: contents),
            style: style,
            function: function
        )
    }

    // MARK: - Routing

    @Test(
        "the XML family is XML by name or by type, plists included, and pages, images and JSON are not"
    )
    func routesXMLFiles() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let names = [
            "pom.xml", "DATA.XML", "App.csproj", "Directory.Build.props", "App.config",
            "Main.storyboard",
            "View.xib", "Window.xaml", "Strings.resx", "Info.plist", "App.entitlements",
            "route.gpx",
            "feed.rss", "Suite.sdef"
        ]
        for name in names {
            let url = try tree.write(name, contents: "<a/>")
            #expect(QuickViewPreviewView.isXML(url), "\(name) should be XML")
            #expect(QuickViewPreviewView.dualStyleKind(of: url) == .xml, "\(name)")
        }
        for name in ["icon.svg", "page.xhtml", "page.html", "package.json", "data.csv", "notes.txt"] {
            let url = try tree.write(name, contents: "<a/>")
            #expect(!QuickViewPreviewView.isXML(url), "\(name) should not be XML")
            #expect(QuickViewPreviewView.dualStyleKind(of: url) != .xml, "\(name)")
        }
    }

    /// JSON's rule, taken for XML: `1` on an XML file changes XML files only.
    @Test("XML opens as its tree, remembers its choice apart, and calls it Tree")
    func stylesArePerFamily() {
        let defaults = ScratchDefaults.fresh()
        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.quickViewRenderStyle(for: .xml) == .rendered)
        preferences.setQuickViewRenderStyle(.source, for: .xml)
        #expect(preferences.quickViewRenderStyle(for: .json) == .rendered)
        #expect(AppPreferences(defaults: defaults).quickViewRenderStyle(for: .xml) == .source)
        #expect(QuickViewRenderStyle.rendered.headerLabel(for: .xml)
            == QuickViewRenderStyle.rendered.headerLabel(for: .json))
    }

    // MARK: - What reaches the screen

    @Test("an XML file fills the tree: attributes as @ rows, a leaf's text, and a Name column")
    func treeReachesTheScreen() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let preview = try await loaded("App.csproj", Self.project, in: tree)
        let surface = try #require(preview.treeSurface)
        #expect(!surface.isHidden)
        #expect(preview.textSurface?.isHidden != false)
        #expect(QuickViewJSONFixtures.rows(surface) == [
            #"Project Sdk="Microsoft.NET.Sdk""#,
            #"@Sdk "Microsoft.NET.Sdk""#,
            "PropertyGroup ‹1›",
            "TargetFramework net8.0",
            "ItemGroup ‹1›",
            #"PackageReference Include="Serilog" Version="3.1.1""#
        ])
        #expect(surface.outlineView.tableColumns.map(\.title) == [
            QuickViewTreeView.nameTitle, QuickViewTreeView.valueTitle
        ])
        #expect(
            surface.filterBar.columnPicker.itemTitles.first == String(localized: "Names and Values")
        )

        surface.outlineView.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        #expect(surface.strip.text.contains("/Project/PropertyGroup/TargetFramework"))
        #expect(surface.strip.text.contains("net8.0"))

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dirnex-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        surface.outlineView.pasteboard = pasteboard
        surface.outlineView.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        surface.outlineView.copy(nil)
        #expect(pasteboard.string(forType: .string)
            == "<PropertyGroup>\n  <TargetFramework>net8.0</TargetFramework>\n</PropertyGroup>")
    }

    @Test(
        "a property list reads as keys and values, and a JSON file after it gives the Key column back"
    )
    func propertyList() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let preview = try await loaded("Info.plist", Self.info, in: tree)
        let surface = try #require(preview.treeSurface)
        #expect(
            QuickViewJSONFixtures.rows(surface) == [#"CFBundleName "Dirnex""#, "LSUIElement false"]
        )
        #expect(surface.outlineView.tableColumns.first?.title == QuickViewTreeView.keyTitle)
        #expect(surface.strip.text.contains(":CFBundleName"))

        let csproj = try tree.write("App.csproj", contents: Self.project)
        preview.show(csproj, style: .rendered)
        await QuickViewJSONFixtures.settle { QuickViewJSONFixtures.rows(surface).count == 6 }
        #expect(surface.outlineView.tableColumns.first?.title == QuickViewTreeView.nameTitle)

        preview.show(try tree.write("a.json", contents: #"{"b": 1}"#), style: .rendered)
        await QuickViewJSONFixtures.settle { QuickViewJSONFixtures.rows(surface) == ["b 1"] }
        #expect(surface.outlineView.tableColumns.first?.title == QuickViewTreeView.keyTitle)
        #expect(
            surface.filterBar.columnPicker.itemTitles.first == String(localized: "Keys and Values")
        )
    }

    @Test("a binary property list reads as its keys and values too")
    func binaryPropertyList() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Name": "Dirnex", "Count": 3],
            format: .binary,
            options: 0
        )
        let url = tree.root.appendingPathComponent("Prefs.plist")
        try data.write(to: url)
        let preview = try await QuickViewTableFixtures.loaded(url)
        let surface = try #require(preview.treeSurface)
        #expect(Set(QuickViewJSONFixtures.rows(surface)) == ["Count 3", #"Name "Dirnex""#])
    }

    @Test("a root of like elements opens in the table, and the header says Table")
    func recordsOpenInTheTable() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let preview = try await loaded("strings.xml", Self.resources, in: tree)
        let table = try #require(preview.tableSurface)
        #expect(!table.isHidden)
        #expect(table.tableView.tableColumns.map(\.title) == ["#", "@name", "#text"])
        #expect(table.tableView.numberOfRows == 2)
        #expect(preview.treeSurface?.isHidden != false)
        let caption = QuickViewCaption(
            name: "strings.xml",
            position: 1,
            count: 1,
            style: .rendered,
            styleKind: .xml
        )
        #expect(preview.captionForHeader(caption)?.styleKind == .table)
    }

    @Test("a file under an XML name that is not XML shows as text, and the source style is text")
    func fallsBackToText() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let ini = try await loaded("build.props", "key=value\nother=1\n", in: tree)
        #expect(ini.treeSurface?.isHidden != false)
        #expect(ini.textSurface?.isHidden == false)

        let source = try await loaded("App.csproj", Self.project, in: tree, style: .source)
        #expect(source.treeSurface?.isHidden != false)
        let text = try #require(QuickViewTableFixtures.documentTextView(of: source))
        #expect(text.string.contains("PackageReference"))
    }

    @Test("the filter narrows the tree by names or by values, and View ▸ Filter reaches it")
    func filters() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let preview = try await loaded("App.csproj", Self.project, in: tree)
        let surface = try #require(preview.treeSurface)
        #expect(preview.filterableSurface === surface)

        try await QuickViewJSONFilterFixtures.type("serilog", into: surface)
        #expect(QuickViewJSONFixtures.rows(surface) == [
            #"Project Sdk="Microsoft.NET.Sdk""#,
            "ItemGroup ‹1›",
            #"PackageReference Include="Serilog" Version="3.1.1""#,
            #"@Include "Serilog""#
        ])
        #expect(surface.strip.text.contains("/Project/ItemGroup/PackageReference/@Include"))
        try await QuickViewJSONFilterFixtures.choose(.keys, in: surface)
        #expect(QuickViewJSONFixtures.rows(surface).isEmpty)
        try await QuickViewJSONFilterFixtures.type("sdk", into: surface)
        #expect(QuickViewJSONFixtures.rows(surface) == [
            #"Project Sdk="Microsoft.NET.Sdk""#, #"@Sdk "Microsoft.NET.Sdk""#
        ])
    }
}
