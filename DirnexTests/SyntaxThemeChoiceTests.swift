import AppKit
import DirnexCore
import Foundation
import os
import SwiftUI
import Testing

@testable import Dirnex

/// The syntax theme as a choice (PLAN.md §M39 ▸ Slice 10): what is saved, what a rendered page is
/// generated in, and how a page already on screen takes a new theme without a reload.
///
/// Nothing here selects a theme for the whole app. `SyntaxTheme.current` follows the shared
/// preferences, which are the developer's own settings inside the test host, and every other suite
/// running beside this one draws through it, so each test names its theme instead.
@MainActor
@Suite("Syntax theme choice")
struct SyntaxThemeChoiceTests {
    private func isolatedDefaults(_ variant: String? = nil, function: String = #function) -> UserDefaults {
        ScratchDefaults.fresh(variant, function: function)
    }

    // MARK: - The preference

    @Test("a fresh install draws in VS Code's colors")
    func freshInstallIsVSCode() {
        #expect(AppPreferences(defaults: isolatedDefaults()).syntaxTheme == .vsCode)
    }

    @Test("a chosen theme is saved and restored")
    func choiceIsRestored() {
        let defaults = isolatedDefaults()
        AppPreferences(defaults: defaults).syntaxTheme = .gitHub

        #expect(defaults.string(forKey: "Dirnex.pref.syntaxTheme") == "github")
        #expect(AppPreferences(defaults: defaults).syntaxTheme == .gitHub)
    }

    /// A defaults domain is hand-editable, and a newer build may add a theme an older one never heard
    /// of: either reads as the default rather than trapping.
    @Test("a theme this build doesn't know reads as the default")
    func unknownThemeFallsBack() {
        let defaults = isolatedDefaults()
        defaults.set("solarized", forKey: "Dirnex.pref.syntaxTheme")

        #expect(AppPreferences(defaults: defaults).syntaxTheme == .vsCode)
    }

    @Test("a change posts once, and a scratch instance leaves the screen's theme alone")
    func changePostsAndStaysLocal() {
        let preferences = AppPreferences(defaults: isolatedDefaults())
        let before = SyntaxTheme.current
        let posts = OSAllocatedUnfairLock(initialState: 0)
        let token = NotificationCenter.default.addObserver(
            forName: AppPreferences.syntaxThemeDidChange,
            object: preferences,
            queue: nil
        ) { _ in posts.withLock { $0 += 1 } }
        defer { NotificationCenter.default.removeObserver(token) }

        preferences.syntaxTheme = before == .xcode ? .gitHub : .xcode
        preferences.syntaxTheme = preferences.syntaxTheme

        #expect(posts.withLock { $0 } == 1)
        #expect(SyntaxTheme.current == before)
    }

    // MARK: - The sample in Settings

    @Test("the Settings sample is scanned as Swift and colored in the chosen theme")
    func sampleUsesTheTheme() throws {
        let sample = SyntaxThemeSample.attributed(SyntaxThemeSample.source, in: .xcode)
        let light = try #require(NSAppearance(named: .aqua))
        var found: Set<String> = []
        for run in sample.runs {
            guard let color = run.swiftUI.foregroundColor else { continue }
            found.insert(SyntaxThemeTests.hex(NSColor(color), in: light))
        }
        // Keyword, type, string, number and comment, each in Xcode's light value.
        for kind: SyntaxToken.Kind in [.keyword, .typeOrTag, .string, .number, .comment] {
            let expected = try SyntaxThemeTests.hex(
                #require(SyntaxTheme.color(for: kind, in: .xcode)),
                in: light
            )
            #expect(found.contains(expected), "no \(kind) run in \(expected)")
        }
    }

    // MARK: - A rendered page

    @Test("a page carries the theme's token colors for both appearances, in a style of their own")
    func pageCarriesTheTheme() throws {
        let page = QuickViewMarkdownStyle.document(body: "<p>x</p>", theme: .gitHub)
        let opener = "<style \(QuickViewMarkdownStyle.syntaxStyleAttribute)>"
        let start = try #require(page.range(of: opener))
        let block = page[start.upperBound...].prefix { $0 != "<" }

        #expect(block.contains("--tok-keyword: #CF222E;"))
        #expect(block.contains("--tok-keyword: #FF7B72;"))
        #expect(block.contains("prefers-color-scheme: dark"))
        // No token color anywhere else, or a restyle would leave a stale copy behind.
        #expect(page.components(separatedBy: "--tok-keyword:").count == 3)
        #expect(!page.contains("#0000FF"))
    }

    /// The whole point of the separate `<style>`: a change of theme reaches a page already on screen
    /// in place, with no reload, so the reader keeps their place. Two changes in a row, so the test
    /// holds whatever theme the page was first generated in.
    @Test("a page on screen takes a new theme in place, keeping its scroll")
    func restyleInPlace() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let filler = (1...80).map { "Line \($0) of prose." }.joined(separator: "\n\n")
        let url = try tree.write("theme.md", contents: "```swift\nlet x = 1\n```\n\n\(filler)\n")
        let (surface, window) = try await QuickViewLinkSurface.hosted()
        window.appearance = NSAppearance(named: .aqua)
        let scan = try #require(QuickViewPreviewView.MarkdownScan.read(url))
        surface.showMarkdown(scan, source: url)
        try await Self.until { await Self.has(".tok-keyword", in: surface) }
        _ = await Self.evaluate("(window.scrollTo(0, 400), window.scrollY)", in: surface)
        let scrolled = await Self.number("window.scrollY", in: surface)
        #expect(scrolled > 300)

        for (theme, expected) in [
            (SyntaxColorTheme.gitHub, "rgb(207, 34, 46)"),
            (.xcode, "rgb(155, 35, 147)")
        ] {
            let replaced = await Self.restyle(surface, to: theme)
            #expect(replaced)
            try await Self.until { await Self.keywordColor(in: surface) == expected }
            #expect(await Self.number("window.scrollY", in: surface) == scrolled)
        }

        // The repaint walk finds the page inside its surface and brings it to the screen's theme.
        let current = try SyntaxThemeTests.hex(
            #require(SyntaxTheme.color(for: .keyword, in: SyntaxTheme.current)),
            in: #require(NSAppearance(named: .aqua))
        )
        SyntaxThemeRepaint.repaint([window])
        try await Self.until { await Self.keywordColor(in: surface) == Self.rgb(current) }
    }

    @Test("a page with no syntax style is left alone")
    func otherPagesAreLeftAlone() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try tree.write("page.html", contents: "<p class=\"tok-keyword\">plain</p>")
        let (surface, _) = try await QuickViewLinkSurface.hosted()
        surface.show(url)
        try await Self.until { await Self.has("p", in: surface) }

        #expect(await !Self.restyle(surface, to: .gitHub))
    }

    // MARK: - Helpers

    private static func restyle(_ surface: QuickViewWebView, to theme: SyntaxColorTheme) async -> Bool {
        await withCheckedContinuation { continuation in
            SyntaxThemeRepaint.restyle(
                surface.webView,
                css: QuickViewMarkdownStyle.syntaxPalette(theme)
            ) { continuation.resume(returning: $0) }
        }
    }

    private static func has(_ selector: String, in surface: QuickViewWebView) async -> Bool {
        await evaluate("document.querySelector('\(selector)') !== null", in: surface) as? Bool == true
    }

    private static func keywordColor(in surface: QuickViewWebView) async -> String? {
        await evaluate("getComputedStyle(document.querySelector('.tok-keyword')).color", in: surface)
            as? String
    }

    /// `#RRGGBB` as WebKit's computed style spells it.
    private static func rgb(_ hex: String) -> String {
        let value = Int(hex.dropFirst(), radix: 16) ?? 0
        return "rgb(\((value >> 16) & 0xFF), \((value >> 8) & 0xFF), \(value & 0xFF))"
    }

    private static func evaluate(_ expression: String, in surface: QuickViewWebView) async -> Any? {
        try? await surface.webView.callAsyncJavaScript(
            "return \(expression);",
            arguments: [:],
            in: nil,
            contentWorld: .defaultClient
        )
    }

    private static func number(_ expression: String, in surface: QuickViewWebView) async -> Double {
        (await evaluate(expression, in: surface) as? NSNumber)?.doubleValue ?? -1
    }

    /// Wait for `predicate`, up to two minutes, for the reason `QuickViewLinkClickTests.until` gives.
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
}
