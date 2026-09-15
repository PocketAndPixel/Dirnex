import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Property lists reach the text preview, a binary one converted to XML, and the development files a
/// survey of `~/Dev` found previewing in one color are colored there (docs/HISTORY.md, 2026-09-16).
/// Which language each file gets, and the conversion, are the core's (`SyntaxLanguageTests`,
/// `SyntaxConfigurationScannerTests`, `TextPreviewPropertyListTests`); what is left here is that the
/// preview routes and asks as the core expects.
@Suite("Quick View development files")
@MainActor
struct QuickViewDevelopmentFilesTests {
    @Test("a property list takes the text backend, and a .webloc does not")
    func propertyListsAreText() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        for name in ["Info.plist", "Localizable.stringsdict"] {
            let url = try tree.write(name, contents: "x")
            #expect(QuickViewPreviewView.isText(url), "\(name) should preview as text")
        }
        // A plist-shaped Finder file whose type does not conform to a property list keeps Quick Look.
        let link = try tree.write("site.webloc", contents: "x")
        #expect(!QuickViewPreviewView.isText(link))
    }

    @Test("an XML property list previews as its markup, colored")
    func xmlPropertyListIsColored() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>CFBundleName</key>
            <string>Dirnex</string>
        </dict>
        </plist>

        """
        let url = try tree.write("Info.plist", contents: xml)
        let preview = try await QuickViewTextPreviewTests.loaded(url)

        let textView = await Self.settledTextView(of: preview)
        #expect(textView?.string == xml)
        #expect(Self.foregroundColors(in: textView).contains(SyntaxTheme.typeOrTag))
    }

    @Test("a binary property list previews as the XML it converts to, colored")
    func binaryPropertyListIsColored() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleName": "Dirnex", "Count": 3],
            format: .binary,
            options: 0
        )
        let url = tree.root.appendingPathComponent("Info.plist")
        try data.write(to: url)
        let preview = try await QuickViewTextPreviewTests.loaded(url)

        let textView = await Self.settledTextView(of: preview)
        #expect(textView?.string.hasPrefix("<?xml") == true)
        #expect(textView?.string.contains("<string>Dirnex</string>") == true)
        #expect(Self.foregroundColors(in: textView).contains(SyntaxTheme.typeOrTag))
    }

    /// A compiled `.strings` table is a binary plist too, and its converted text is XML rather than
    /// `"key" = "value";`, so the `.strings` grammar its name picks would color nothing but strings.
    @Test("a compiled .strings table is colored as the XML it converts to")
    func compiledStringsTableIsMarkup() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["OK": "Хорошо"],
            format: .binary,
            options: 0
        )
        let url = tree.root.appendingPathComponent("Localizable.strings")
        try data.write(to: url)

        let scan = try #require(QuickViewPreviewView.TextScan.read(url))
        #expect(scan.preview.text.contains("<string>Хорошо</string>"))
        #expect(scan.tokens.contains { $0.kind == .typeOrTag })
    }

    @Test("the development files that previewed in one color are colored")
    func developmentFilesAreColored() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let fixtures = [
            ".gitignore": "# build products\n*.o\n",
            // No name says nginx: the contents do.
            "default.conf": "server {\n    listen 80;\n}\n",
            "dockerfile.dev": "FROM node:20\nRUN npm ci\n",
            ".env.local": "API_KEY=secret\n",
            "run.bat": "@echo off\n",
            "App.csproj": "<Project Sdk=\"Microsoft.NET.Sdk\">\n</Project>\n"
        ]
        for (name, contents) in fixtures {
            let url = try tree.write(name, contents: contents)
            let scan = try #require(QuickViewPreviewView.TextScan.read(url))
            #expect(!scan.tokens.isEmpty, "\(name) should be colored")
        }
    }

    // MARK: - Helpers

    /// The document's text view once its text has landed, or `nil` if it never does within 10 s.
    private static func settledTextView(of preview: QuickViewPreviewView) async -> NSTextView? {
        for _ in 0..<2000 {
            if let text = QuickViewTableFixtures.documentTextView(of: preview), !text.string.isEmpty {
                return text
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    private static func foregroundColors(in textView: NSTextView?) -> Set<NSColor> {
        guard let storage = textView?.textStorage else { return [] }
        var found: Set<NSColor> = []
        storage.enumerateAttribute(
            .foregroundColor,
            in: NSRange(location: 0, length: storage.length)
        ) { value, _, _ in
            if let color = value as? NSColor { found.insert(color) }
        }
        return found
    }
}
