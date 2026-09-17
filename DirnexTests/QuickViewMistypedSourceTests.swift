import AppKit
import DirnexCore
import Testing
import UniformTypeIdentifiers

@testable import Dirnex

/// A file whose *name* a grammar claims but whose declared type says otherwise reaches the text
/// preview by its bytes, the way a file no type claims already did (2026-09-18).
///
/// The case that made it: LaunchServices resolves `.ts` to `public.mpeg-2-transport-stream` and
/// `.mts` to `public.avchd-mpeg-2-transport-stream`, so every TypeScript file went to Quick Look to
/// be drawn as a video — 52 934 `.ts` and 287 `.mts` of them under `~/Dev` on this Mac, beside
/// `.tsx` and `.cts` files that resolve to dynamic types and previewed correctly all along.
///
/// Nothing here decides anything by the name: it only buys the file `TextPreview`'s byte test, which
/// a real transport stream fails. The decode and that early refusal are the core's and are tested
/// there; what these pin is the routing, and that it stayed narrow.
@Suite("Quick View files whose type contradicts their name")
@MainActor
struct QuickViewMistypedSourceTests {
    @Test("a TypeScript file typed as video is routed by its bytes")
    func typeScriptIsRoutedByItsBytes() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        for name in ["vite.config.ts", "index.d.mts"] {
            let url = try tree.write(name, contents: "export const beta = 1\n")
            // The premise, asserted rather than assumed: macOS really does call these video, so the
            // test fails loudly if a future macOS re-types them instead of passing for a new reason.
            let type = try #require(try url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            #expect(type.conforms(to: .movie), "\(name) is expected to be typed as video")
            #expect(!QuickViewPreviewView.isText(url), "\(name) is not text by its type")
            #expect(!QuickViewPreviewView.isUnclaimed(url), "\(name) has a declared type")
            #expect(
                QuickViewPreviewView.isMistypedSource(url),
                "\(name) should be asked about its bytes"
            )
        }
    }

    /// The narrowness half, and the one that matters most: this may only ever *widen* what reaches
    /// the text preview. A file already routed by its type keeps that route untouched.
    @Test("a file whose type already says what it is is not second-guessed")
    func declaredTypesKeepTheirRoute() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        for name in [
            "main.swift", "notes.md", "page.html", "data.json", "styles.css", "Info.plist"
        ] {
            let url = try tree.write(name, contents: "x")
            #expect(
                !QuickViewPreviewView.isMistypedSource(url),
                "\(name) is already routed by its type"
            )
        }
    }

    /// The other narrowness half: a declared type no grammar claims keeps Quick Look, which is what
    /// stops this from becoming "show everything as text".
    @Test("a binary no grammar claims still goes to Quick Look")
    func unclaimedBinariesKeepQuickLook() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        for name in ["clip.mov", "photo.jpg", "archive.zip", "cert.pem", "font.ttf", "app.dylib"] {
            let url = try tree.write(name, contents: "x")
            #expect(
                !QuickViewPreviewView.isMistypedSource(url),
                "\(name) should keep Quick Look's own preview"
            )
        }
    }

    /// The control that makes the routing safe rather than merely wider: a real transport stream
    /// named `.ts` is refused by the byte test and goes on to Quick Look and its video preview.
    ///
    /// Built to the spec rather than captured, since the bytes that matter are the first few: packet
    /// one is a PAT, whose `pointer_field` and `table_id` are both `0x00`, so the first NUL lands at
    /// byte 2 — far inside `TextPreview.sniffLength`.
    @Test("a real transport stream named .ts is still refused")
    func realTransportStreamIsRefused() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = tree.root.appendingPathComponent("clip.ts")
        try Self.transportStream(packets: 64).write(to: url)
        #expect(QuickViewPreviewView.isMistypedSource(url), "it is asked about its bytes")
        #expect(TextPreview.read(contentsOf: url) == nil, "and its bytes refuse it")
    }

    /// And the positive half beside it: the same extension, source bytes, reaches the text preview
    /// and is colored as TypeScript — the grammar that has claimed `.ts` since M17 and that the
    /// router could never deliver a file to.
    @Test("a TypeScript file decodes and is colored as TypeScript")
    func typeScriptDecodesAndIsColored() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try tree.write(
            "vite.config.ts",
            contents: "import { defineConfig } from 'vite'\nexport const beta = 1\n"
        )
        let preview = try #require(TextPreview.read(contentsOf: url))
        #expect(preview.text.contains("defineConfig"))
        #expect(SyntaxLanguage.forFile(named: url.lastPathComponent) == .typeScript)
    }

    /// 188-byte packets with the 0x47 sync byte, stuffed to length: enough of a stream for the byte
    /// test, and faithful where it counts.
    private static func transportStream(packets: Int) -> Data {
        var data = Data()
        for index in 0..<packets {
            var packet = Data()
            if index == 0 {
                // PID 0, payload unit start: the Program Association Table.
                packet.append(contentsOf: [0x47, 0x40, 0x00, 0x10])
                packet.append(contentsOf: [0x00]) // pointer_field
                packet.append(contentsOf: [0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00])
                packet.append(contentsOf: [0x00, 0x01, 0xE1, 0x00])
                packet.append(contentsOf: [0x2A, 0xB1, 0x04, 0xB2]) // CRC32
            } else {
                packet.append(contentsOf: [0x47, 0x41, 0x00, 0x10 | UInt8(index % 16)])
                packet.append(contentsOf: [0x00, 0x00, 0x01, 0xE0]) // PES start code
            }
            while packet.count < 188 { packet.append(0xFF) }
            data.append(packet)
        }
        return data
    }
}
