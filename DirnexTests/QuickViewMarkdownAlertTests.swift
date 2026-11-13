import AppKit
import DirnexCore
import Testing
import WebKit

@testable import Dirnex

/// GitHub alerts and footnotes on the rendered page (PLAN.md §M39 ▸ Slice 6): the app's titles, the
/// rules the core's classes are drawn with, and a footnote link followed in a real page.
@Suite("Quick View Markdown alerts and footnotes", .serialized)
@MainActor
struct QuickViewMarkdownAlertTests {
    /// Every alert kind and a footnote, so the class sweep below sees the whole vocabulary.
    private static let everyConstruct = MarkdownAlertKind.allCases
        .map { "> [!\($0.rawValue.uppercased())]\n> Text of the \($0.rawValue)." }
        .joined(separator: "\n\n") + "\n\nA reference[^1] and again[^1].\n\n[^1]: The note."

    private func render(_ source: String) -> String {
        MarkdownDocument.render(
            source,
            options: MarkdownRenderOptions(alertTitle: { QuickViewMarkdownAlerts.title($0) })
        ).html
    }

    // MARK: - The join

    @Test("every class the core emits for an alert or a footnote has a rule")
    func everyEmittedClassIsStyled() {
        let rules = QuickViewMarkdownAlerts.rules
        let classes = QuickViewMarkdownDiagramTests.classNames(in: render(Self.everyConstruct))
            .subtracting(Self.hooks)
        #expect(classes.count == 9)
        for name in classes.sorted() {
            #expect(rules.contains(".\(name)"), "no stylesheet rule names “\(name)”")
        }
    }

    /// A class the core writes to name a thing rather than to style it: a reference is drawn by its
    /// `<sup>`, which has its rule.
    private static let hooks: Set<String> = ["footnote-ref"]

    @Test("the rules reach the page the preview loads")
    func rulesAreInTheDocument() {
        let page = QuickViewMarkdownStyle.document(body: render(Self.everyConstruct))
        #expect(page.contains(".markdown-alert-title::before"))
        #expect(page.contains("section.footnotes"))
    }

    /// GitHub's palette was measured against GitHub's page; this page's backgrounds are AppKit's, so
    /// the claim is checked here, per kind and per appearance.
    @Test("every alert's color clears 4.5:1 on the page background, in both appearances")
    func colorsAreLegible() {
        let page = QuickViewMarkdownStyle.document(body: "<p>x</p>")
        let backgrounds = QuickViewMarkdownAlertTests.values(of: "--background", in: page)
        #expect(backgrounds.count == 2)
        for kind in MarkdownAlertKind.allCases {
            let values = Self.values(of: "--alert-\(kind.rawValue)", in: page)
            #expect(values.count == 2, "\(kind) should be declared once per appearance")
            for (ink, paper) in zip(values, backgrounds) {
                let ratio = Self.contrast(ink, paper)
                #expect(ratio >= 4.5, "\(kind) \(ink) on \(paper) scores \(ratio)")
            }
        }
    }

    @Test("every kind has an icon, a mask with ink and clear around it")
    func icons() throws {
        for kind in MarkdownAlertKind.allCases {
            let uri = try #require(
                QuickViewMarkdownAlerts.iconMask(QuickViewMarkdownAlerts.symbol(kind))
            )
            let prefix = "data:image/png;base64,"
            #expect(uri.hasPrefix(prefix))
            let data = try #require(Data(base64Encoded: String(uri.dropFirst(prefix.count))))
            let bitmap = try #require(NSBitmapImageRep(data: data))
            var opaque = 0
            var clear = 0
            for x in 0..<bitmap.pixelsWide {
                for y in 0..<bitmap.pixelsHigh {
                    let alpha = bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
                    if alpha > 0.9 { opaque += 1 } else if alpha < 0.1 { clear += 1 }
                }
            }
            #expect(opaque > 20, "\(kind)'s icon has no ink")
            #expect(clear > 20, "\(kind)'s icon has nothing around its ink")
            #expect(QuickViewMarkdownAlerts.rules.contains(uri))
        }
    }

    // MARK: - The titles

    @Test("the title on the page is the app's, escaped")
    func titleReachesThePage() {
        let html = render("> [!WARNING]\n> Careful.")
        let title = MarkdownHTMLEscape.text(QuickViewMarkdownAlerts.title(.warning))
        #expect(html.contains("<p class=\"markdown-alert-title\">\(title)</p>"))
    }

    @Test("every title is in all 14 languages", arguments: MarkdownAlertKind.allCases)
    func everyLanguage(_ kind: MarkdownAlertKind) {
        let key = MarkdownRenderOptions.englishAlertTitle(kind)
        let app = Bundle(for: PanelViewController.self)
        var found: [String: String] = [:]
        for lproj in app.paths(forResourcesOfType: "lproj", inDirectory: nil) {
            let language = (lproj as NSString).lastPathComponent
                .replacingOccurrences(of: ".lproj", with: "")
            guard language != "Base", let bundle = Bundle(path: lproj) else { continue }
            let value = bundle.localizedString(
                forKey: key,
                value: "\u{0}missing",
                table: "Localizable"
            )
            guard value != "\u{0}missing" else { continue }
            found[language] = value
        }
        #expect(found.count >= 14, "expected 14 languages for \(key), found \(found.keys.sorted())")
        #expect(found["en"] == key)
        #expect(found["de"] != nil && found["de"] != key)
        #expect(found["ja"] != nil && found["ja"] != key)
    }

    // MARK: - In a real page

    @Test("a footnote link scrolls to its note and the way back returns, an encoded label included")
    func followingAFootnote() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let filler = (1...120).map { "Paragraph \($0) of the filler." }.joined(separator: "\n\n")
        let url = try tree.write("notes.md", contents: """
        A plain reference[^1] and an accented one[^é].

        > [!NOTE]
        > An alert.

        \(filler)

        [^1]: The first note.
        [^é]: The accented note.
        """)
        let (surface, _) = try await QuickViewLinkSurface.hosted()
        let scan = try #require(QuickViewPreviewView.MarkdownScan.read(url))
        surface.showMarkdown(scan, source: url)
        try await Self.until { await Self.top(of: "fn-1", in: surface) != nil }
        #expect(await Self.scrollY(of: surface) == 0)

        // The icon reached the title, as a mask the page loaded.
        let mask = await Self.evaluate(
            "getComputedStyle(document.querySelector('.markdown-alert-title'), '::before')"
                + ".webkitMaskImage",
            in: surface
        ) as? String
        #expect(mask?.contains("data:image/png") == true)

        // Down to the note, which sits under 120 paragraphs, and back up to the reference.
        try await Self.click("a[href='#fn-1']", in: surface)
        try await Self.until { await Self.isOnScreen("fn-1", in: surface) }
        #expect(await Self.scrollY(of: surface) > 1000)
        try await Self.click("#fn-1 a.footnote-backref", in: surface)
        try await Self.until { await Self.scrollY(of: surface) < 200 }
        #expect(await Self.isOnScreen("fnref-1", in: surface))

        // A label outside ASCII anchors percent-encoded, and the link still lands.
        _ = await Self.evaluate("window.scrollTo(0, 0)", in: surface)
        try await Self.click("a[href='#fn-%C3%A9']", in: surface)
        try await Self.until { await Self.isOnScreen("fn-%C3%A9", in: surface) }
        #expect(await Self.scrollY(of: surface) > 1000)
    }

    // MARK: - Helpers

    private static func evaluate(_ expression: String, in surface: QuickViewWebView) async -> Any? {
        try? await surface.webView.callAsyncJavaScript(
            "return \(expression);",
            arguments: [:],
            in: nil,
            contentWorld: .defaultClient
        )
    }

    private static func click(_ selector: String, in surface: QuickViewWebView) async throws {
        _ = try await surface.webView.callAsyncJavaScript(
            "document.querySelector(selector).click(); return true;",
            arguments: ["selector": selector],
            in: nil,
            contentWorld: .defaultClient
        )
    }

    private static func scrollY(of surface: QuickViewWebView) async -> Double {
        (await evaluate("window.scrollY", in: surface) as? NSNumber)?.doubleValue ?? -1
    }

    /// Where the element with `id` sits in the viewport, or `nil` before the page has it.
    private static func top(of id: String, in surface: QuickViewWebView) async -> Int? {
        let value = try? await surface.webView.callAsyncJavaScript(
            """
            const element = document.getElementById(id);
            return element ? Math.round(element.getBoundingClientRect().top) : null;
            """,
            arguments: ["id": id],
            in: nil,
            contentWorld: .defaultClient
        )
        return (value as? NSNumber)?.intValue
    }

    /// Whether the element's top is inside the 300-point window the surface is hosted in.
    private static func isOnScreen(_ id: String, in surface: QuickViewWebView) async -> Bool {
        guard let top = await top(of: id, in: surface) else { return false }
        return (0..<300).contains(top)
    }

    /// Wait for `predicate`, up to two minutes, for the reason `QuickViewLinkClickTests.until` gives:
    /// the main actor is shared with every other suite, so the deadline only bounds a real failure.
    private static func until(
        within: Duration = .seconds(120),
        sourceLocation: SourceLocation = #_sourceLocation,
        _ predicate: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + within
        while await !predicate() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out waiting for the page", sourceLocation: sourceLocation)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The declared values of one custom property, in source order — one per appearance.
    static func values(of property: String, in css: String) -> [String] {
        css.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(property + ":") else { return nil }
            return trimmed
                .dropFirst(property.count + 1)
                .trimmingCharacters(in: CharacterSet(charactersIn: " ;"))
        }
    }

    private static func contrast(_ ink: String, _ paper: String) -> Double {
        let (front, back) = (luminance(ink), luminance(paper))
        return (max(front, back) + 0.05) / (min(front, back) + 0.05)
    }

    /// Written out by hand rather than borrowed from the code under test (docs/NOTES.md ▸ Testing).
    private static func luminance(_ hex: String) -> Double {
        let digits = Array(hex.dropFirst())
        guard digits.count == 6 else { return 0 }
        func channel(_ pair: ArraySlice<Character>) -> Double {
            let value = Double(Int(String(pair), radix: 16) ?? 0) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(digits[0..<2])
            + 0.7152 * channel(digits[2..<4])
            + 0.0722 * channel(digits[4..<6])
    }
}

/// The five characters the page escapes, written out so the title test does not borrow the core's
/// own escaper.
private enum MarkdownHTMLEscape {
    static func text(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
