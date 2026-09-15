import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Files no type claims — `VERSION`, `.gitignore`, `nginx.conf` — reach the text backend and let
/// their bytes decide, where they used to get Quick Look's blank document icon. The decoding and the
/// early binary refusal are `TextPreview`'s and are tested in the core.
@Suite("Quick View files no type claims")
@MainActor
struct QuickViewUnclaimedTextTests {
    @Test("a name with no extension, or one nothing declares, is routed by its bytes")
    func unclaimedNames() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        for name in [
            "VERSION",
            "NOTICE",
            "Dockerfile",
            ".gitignore",
            "nginx.conf",
            "App.vue",
            "yarn.lock"
        ] {
            let url = try tree.write(name, contents: "x")
            #expect(QuickViewPreviewView.isUnclaimed(url), "\(name) should be asked about its bytes")
        }
    }

    @Test("a script with its execute bit set is routed by its bytes")
    func executableScript() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try tree.write("gradlew", contents: "#!/bin/sh\necho hi\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        #expect(QuickViewPreviewView.isUnclaimed(url))
    }

    /// The narrowness half: a declared type keeps its own route, text or not.
    @Test("a file whose type is declared is not")
    func claimedNames() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        for name in ["notes.txt", "photo.jpg", "paper.pdf", "archive.zip", "cert.pem"] {
            let url = try tree.write(name, contents: "x")
            #expect(!QuickViewPreviewView.isUnclaimed(url), "\(name) should keep its own route")
        }
    }

    /// The language comes from the `#!` line, since the name has no extension to route by.
    @Test("a script with no extension is colored by its #! line, and plain text is not")
    func extensionlessScriptIsColored() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let script = try tree.write(
            "deploy",
            contents: "#!/usr/bin/env bash\n# ship it\necho \"done\"\n"
        )
        let version = try tree.write("VERSION", contents: "1.0.10\n")

        let scripted = try #require(QuickViewPreviewView.TextScan.read(script))
        let plain = try #require(QuickViewPreviewView.TextScan.read(version))
        #expect(!scripted.tokens.isEmpty)
        #expect(plain.tokens.isEmpty)
    }

    @Test("a text file with no extension previews as its text")
    func extensionlessTextShowsItsText() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try tree.write("VERSION", contents: "1.0.10\n")
        let preview = try await QuickViewTextPreviewTests.loaded(url)

        let shown = await Self.settledText(of: preview)
        #expect(shown == "1.0.10\n")
    }

    /// `showText` raises the text surface before its read lands, so what is waited for is the surface
    /// going away again, which only a refused read does.
    @Test("a binary with no extension still goes to Quick Look")
    func extensionlessBinaryFallsBack() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try tree.write("blob", contents: "\u{CF}\u{0}\u{0}\u{1}binary")
        #expect(QuickViewPreviewView.isUnclaimed(url))
        let preview = try await QuickViewTextPreviewTests.loaded(url)

        for _ in 0..<2000 where preview.textSurface?.isHidden == false {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(preview.textSurface?.isHidden == true)
        #expect(preview.hitTest(NSPoint(x: 200, y: 200)) === preview)
    }

    /// The text the surface shows once the read has landed, or `nil` if it never does within 10 s.
    private static func settledText(of preview: QuickViewPreviewView) async -> String? {
        for _ in 0..<2000 {
            if let text = QuickViewTableFixtures.documentTextView(of: preview), !text.string.isEmpty {
                return text.string
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }
}
