import Foundation
import Testing

@testable import DirnexCore

/// Saved pages captured 2026-11-12 for PLAN.md §M39, from pages served by a throwaway `http.server` on
/// 127.0.0.1:8765: `webkit-*` written by WebKit's own `createWebArchiveData`, `chrome-*` by Chrome
/// headless through `Page.captureSnapshot`. Real writers rather than hand-built files, so the reader is
/// measured against the format as it exists and not against this test's idea of it.
///
/// - `*-page`: a page, its stylesheet and a PNG.
/// - `webkit-frames` / `chrome-frames`: a windows-1252 page with an iframe, and an image at a path with
///   spaces and `é`. The frame is UTF-8 with its own `<style>` and the same PNG.
/// - `webkit-types`: a script, a CSS background, an SVG as `<img>` and as `<object>`, and the iframe.
enum WebArchiveFixtures {
    static func data(_ name: String) throws -> Data {
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        let url = try #require(Bundle.module.url(
            forResource: parts[0],
            withExtension: parts[1],
            subdirectory: "Fixtures/WebArchive"
        ))
        return try Data(contentsOf: url)
    }

    static func archive(_ name: String) throws -> WebArchive {
        try #require(WebArchive(propertyList: data(name)))
    }

    static let origin = "http://127.0.0.1:8765"

    /// `data` read as UTF-8, a malformed byte as U+FFFD. Lossy on purpose: a windows-1252 page is read
    /// for its ASCII, and a failable decode would turn the whole resource into `nil`.
    static func text(_ data: Data) -> String {
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: data, as: UTF8.self)
    }

    /// The bytes of `red.png`, as every fixture holds it.
    static func png() throws -> Data {
        let archive = try archive("webkit-page.webarchive")
        return try #require(archive.subresources.first { $0.url.hasSuffix("/red.png") }).data
    }
}

@Suite("WebArchive")
struct WebArchiveTests {
    @Test("WebKit's own archive of a page reads as its page and two subresources")
    func readsWebKitPage() throws {
        let archive = try WebArchiveFixtures.archive("webkit-page.webarchive")
        #expect(archive.mainResource.url == WebArchiveFixtures.origin + "/index.html")
        #expect(archive.mainResource.mimeType == "text/html")
        #expect(archive.mainResource.textEncodingName == "UTF-8")
        #expect(archive.frameName.isEmpty)
        #expect(archive.subresources.map(\.url) == [
            WebArchiveFixtures.origin + "/style.css", WebArchiveFixtures.origin + "/red.png"
        ])
        #expect(archive.subresources.map(\.mimeType) == ["text/css", "image/png"])
        #expect(try WebArchiveFixtures.png().starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(archive.subframes.isEmpty)
    }

    @Test("a frame is an archive of its own, named as WebKit names it, holding its own resources")
    func readsFrames() throws {
        let archive = try WebArchiveFixtures.archive("webkit-frames.webarchive")
        let frame = try #require(archive.subframes.first)
        #expect(archive.subframes.count == 1)
        #expect(frame.frameName == "<!--frame1-->")
        #expect(frame.mainResource.url == WebArchiveFixtures.origin + "/frame.html")
        #expect(frame.subresources.map(\.url) == [WebArchiveFixtures.origin + "/red.png"])
        // The page names the image with spaces percent-encoded, and WebKit wrote it the same way.
        #expect(archive.subresources.map(\.url) == [
            WebArchiveFixtures.origin + "/dir%20with%20space/r%20%C3%A9%20d.png"
        ])
    }

    @Test("WebKit numbers frames in the order it creates them, not in document order")
    func frameNamesFollowCreation() throws {
        // The `<object>` comes first in `types.html` and is `<!--frame2-->`: the iframe is created
        // while the page parses, the object when it loads.
        let archive = try WebArchiveFixtures.archive("webkit-types.webarchive")
        #expect(archive.subframes.map(\.frameName) == ["<!--frame2-->", "<!--frame1-->"])
        #expect(archive.subframes.map { URL(string: $0.mainResource.url)?.lastPathComponent } == [
            "pic.svg", "frame.html"
        ])
    }

    @Test("every resource is listed depth first, the page before its frames")
    func allResourcesDepthFirst() throws {
        let archive = try WebArchiveFixtures.archive("webkit-frames.webarchive")
        #expect(archive.allURLs.map { URL(string: $0)?.lastPathComponent } == [
            "outer.html", "r é d.png", "frame.html", "red.png"
        ])
    }

    @Test("a round trip keeps every resource and drops the archived responses")
    func roundTrip() throws {
        let data = try WebArchiveFixtures.data("webkit-types.webarchive")
        let archive = try #require(WebArchive(propertyList: data))
        let written = try archive.propertyListData()
        #expect(WebArchive(propertyList: written) == archive)
        // The capture carries `WebResourceResponse` on every subresource; the written archive none.
        #expect(Self.containsKey("WebResourceResponse", in: data))
        #expect(!Self.containsKey("WebResourceResponse", in: written))
    }

    @Test("bytes that are not an archive read as nil")
    func notAnArchive() throws {
        #expect(WebArchive(propertyList: Data("<html></html>".utf8)) == nil)
        let noMain = try PropertyListSerialization.data(
            fromPropertyList: ["WebSubresources": [] as [Any]], format: .binary, options: 0
        )
        #expect(WebArchive(propertyList: noMain) == nil)
        let mainWithoutURL = try PropertyListSerialization.data(
            fromPropertyList: [
                "WebMainResource": ["WebResourceData": Data(), "WebResourceMIMEType": "text/html"]
            ],
            format: .binary, options: 0
        )
        #expect(WebArchive(propertyList: mainWithoutURL) == nil)
    }

    @Test("a subresource missing its URL is skipped, and the page still reads")
    func incompleteSubresourceSkipped() throws {
        let plist: [String: Any] = [
            "WebMainResource": Self.resource("http://a.example/", type: "text/html"),
            "WebSubresources": [
                ["WebResourceData": Data([1]), "WebResourceMIMEType": "image/png"],
                Self.resource("http://a.example/b.png", type: "image/png")
            ]
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        )
        let archive = try #require(WebArchive(propertyList: data))
        #expect(archive.subresources.map(\.url) == ["http://a.example/b.png"])
    }

    @Test("frames nested past the bound are dropped rather than recursed into")
    func frameDepthBounded() throws {
        var plist: [String: Any] = [
            "WebMainResource": Self.resource("http://a.example/0", type: "text/html")
        ]
        for level in 1...40 {
            plist = [
                "WebMainResource": Self.resource("http://a.example/\(level)", type: "text/html"),
                "WebSubframeArchives": [plist]
            ]
        }
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        )
        let archive = try #require(WebArchive(propertyList: data))
        var depth = 1
        var frame = archive
        while let next = frame.subframes.first {
            depth += 1
            frame = next
        }
        #expect(depth == WebArchive.maximumFrameDepth)
    }

    @Test("an empty encoding name reads as none")
    func emptyEncodingIsNone() throws {
        var main = Self.resource("http://a.example/", type: "text/html")
        main["WebResourceTextEncodingName"] = ""
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["WebMainResource": main], format: .binary, options: 0
        )
        #expect(try #require(WebArchive(propertyList: data)).mainResource.textEncodingName == nil)
    }

    private static func resource(_ url: String, type: String) -> [String: Any] {
        ["WebResourceData": Data("x".utf8), "WebResourceURL": url, "WebResourceMIMEType": type]
    }

    private static func containsKey(_ key: String, in data: Data) -> Bool {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            return false
        }
        func search(_ value: Any) -> Bool {
            if let dictionary = value as? [String: Any] {
                return dictionary.keys.contains(key) || dictionary.values.contains(where: search)
            }
            if let array = value as? [Any] { return array.contains(where: search) }
            return false
        }
        return search(plist)
    }
}
