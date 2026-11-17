import Foundation
import Testing

@testable import DirnexCore

/// GitHub alerts, `> [!NOTE]` (PLAN.md §M39 ▸ Slice 6).
///
/// GitHub's `/markdown` API draws no alerts, so the rule comes from the files on this Mac that use
/// them and from how GitHub serves two of those files: a marker in mixed case (`tough-cookie`) and
/// one inside a list item (`eslint-plugin-import`'s `order.md`) are both alerts there.
@Suite("Markdown alerts")
struct MarkdownAlertTests {
    private func blocks(_ text: String) -> [MarkdownBlock] {
        MarkdownBlockParser.scan(text).blocks
    }

    private func html(_ text: String, options: MarkdownRenderOptions = MarkdownRenderOptions()) -> String {
        MarkdownDocument.render(text, options: options).html
    }

    @Test(
        "a quote opening on a marker is an alert of that kind",
        arguments: MarkdownAlertKind.allCases
    )
    func kinds(_ kind: MarkdownAlertKind) {
        let marker = kind.rawValue.uppercased()
        #expect(blocks("> [!\(marker)]\n> Useful information.")
            == [.alert(kind, [.paragraph("Useful information.")])])
    }

    @Test("GitHub's markup, with the title the options give")
    func markup() {
        #expect(html("> [!NOTE]\n> Useful information.") == """
        <div class="markdown-alert markdown-alert-note">
        <p class="markdown-alert-title">Note</p>
        <p>Useful information.</p>
        </div>
        """)
        let options = MarkdownRenderOptions(alertTitle: { _ in "Hinweis & <mehr>" })
        #expect(html("> [!TIP]\n> x", options: options)
            .contains("<p class=\"markdown-alert-title\">Hinweis &amp; &lt;mehr&gt;</p>"))
    }

    @Test("the marker's case and the spaces after it do not matter")
    func spelling() {
        let expected: [MarkdownBlock] = [.alert(.tip, [.paragraph("Lowercase type.")])]
        #expect(blocks("> [!tip]\n> Lowercase type.") == expected)
        #expect(blocks("> [!Tip]\n> Lowercase type.") == expected)
        #expect(blocks(">[!TIP]\n>Lowercase type.") == expected)
        // 20 of the corpus' markers end in two spaces, a hard break after the marker.
        #expect(blocks("> [!TIP]  \n> Lowercase type.") == expected)
    }

    @Test("an alert holds blocks, and continues lazily like any quote")
    func body() {
        #expect(blocks("> [!NOTE]\n> First.\n>\n> Second with **bold**.") == [
            .alert(.note, [.paragraph("First."), .paragraph("Second with **bold**.")])
        ])
        #expect(blocks("> [!NOTE]\nLazy continuation line.")
            == [.alert(.note, [.paragraph("Lazy continuation line.")])])
        // The corpus' own shape: a blank quoted line between the marker and the text.
        #expect(blocks("> [!NOTE]\n>\n> Text.") == [.alert(.note, [.paragraph("Text.")])])
        guard case let .alert(.warning, inner)? = blocks("> [!WARNING]\n> - a\n> - b").first,
              case .list? = inner.first
        else {
            Issue.record("an alert's list was not a list")
            return
        }
    }

    @Test("inside a list item, as GitHub draws eslint-plugin-import's order.md")
    func inList() {
        let source = """
        - If set to `always`, at least one new line.

          > [!TIP]
          >
          > To prevent multiple lines between imports.
        """
        guard case let .list(list)? = blocks(source).first else {
            Issue.record("no list")
            return
        }
        #expect(list.items.first?.blocks.last
            == .alert(.tip, [.paragraph("To prevent multiple lines between imports.")]))
    }

    @Test("anything else stays the quote it is")
    func notAlerts() {
        // Text beside the marker, a marker under the first line, an unknown kind, a space inside the
        // brackets, and a marker with nothing under it.
        for source in [
            "> [!IMPORTANT] Same line text.",
            "> Text before\n> [!NOTE]\n> marker not first.",
            "> [!UNKNOWN]\n> Not an alert type.",
            "> [! NOTE]\n> Space inside.",
            "> [!CAUTION]",
            "> [!NOTE]\n>",
            "> [!]\n> Empty kind."
        ] {
            guard case .blockQuote? = blocks(source).first else {
                Issue.record("\(source.debugDescription) is not a plain quote")
                continue
            }
        }
        #expect(html("> [!CAUTION]") == "<blockquote><p>[!CAUTION]</p></blockquote>")
    }

    @Test("a heading inside an alert takes its anchor in order")
    func headings() {
        let scan = MarkdownBlockParser.scan("# One\n\n> [!NOTE]\n> ## Two\n\n# Three")
        #expect(scan.headings.map(\.slug) == ["one", "two", "three"])
        #expect(html("> [!NOTE]\n> ## Two").contains("<h2 id=\"two\">Two</h2>"))
    }
}
