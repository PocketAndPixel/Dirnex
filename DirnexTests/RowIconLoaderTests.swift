import AppKit
import DirnexCore
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import Dirnex

/// The name column's icons beyond the type icon (2026-11-11): the View-menu toggle, the placeholders
/// `FileIconProvider` draws, and real loads through `RowIconLoader` — an application's own icon
/// through `NSWorkspace` and a picture's thumbnail through Quick Look.
@MainActor
@Suite("Row icon loader")
struct RowIconLoaderTests {
    @Test("the View-menu toggle is wired to a real selector")
    func toggleCommandIsWired() {
        #expect(CommandCatalog.command(for: "view.toggleIconPreviews") != nil)
        #expect(CommandBinding.selector(for: "view.toggleIconPreviews") != nil)
    }

    @Test("previews are on for a fresh install, and the toggle turns them off and says so")
    func preferenceDefaultsOn() {
        let defaults = ScratchDefaults.fresh()
        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.showIconPreviews)

        let posted = PostCount()
        let observer = NotificationCenter.default.addObserver(
            forName: AppPreferences.showIconPreviewsDidChange,
            object: preferences,
            queue: nil
        ) { _ in posted.value += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        preferences.toggleShowIconPreviews()
        #expect(!preferences.showIconPreviews)
        #expect(posted.value == 1)
        #expect(AppPreferences(defaults: defaults).showIconPreviews == false)
    }

    @Test("an application on a server is drawn as an application, not as a folder")
    func remotePackageKeepsItsType() {
        let app = Self.entry(
            "/home/probe/Tools.app",
            kind: .directory,
            backend: VFSBackendID("sftp://p@h:22")
        )
        let drawn = FileIconProvider.icon(for: app)
        #expect(drawn !== FileIconProvider.parentIcon)
        #expect(drawn === FileIconProvider.placeholder(for: .type(.applicationBundle)))
        // And a local one shows the same picture until its own icon is in.
        #expect(FileIconProvider.placeholder(for: .item(packageType: .applicationBundle)) === drawn)
        #expect(
            FileIconProvider.placeholder(for: .item(packageType: nil)) === FileIconProvider.parentIcon
        )
    }

    @Test("an application's own icon loads off the main thread, at the row's size")
    func itemIconLoads() async throws {
        let preview = Self.entry("/System/Applications/Preview.app", kind: .directory)
        let appearance = try #require(NSAppearance(named: .darkAqua))
        let image = await Self.load(preview, kind: .item, appearance: appearance)
        let loaded = try #require(image)
        #expect(loaded.size == NSSize(width: 16, height: 16))
        // The control: Preview's icon is not the generic folder the row drew before.
        let folder = Self.pixels(FileIconProvider.parentIcon)
        #expect(Self.pixels(loaded) != folder)
    }

    @Test("a picture's thumbnail is a picture of its content")
    func thumbnailLoads() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("RowIconLoaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("red.png")
        try Self.redSquarePNG().write(to: file)
        // The fixture first, so a fixture that is not red fails here rather than as the loader. The
        // first version of it set each pixel with an sRGB `NSColor` on a device-RGB bitmap, which
        // AppKit refuses without a word, and wrote a transparent PNG.
        let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
        let written = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(Self.centerRGBA(of: written) == [255, 0, 0, 255])

        let entry = Self.entry(file.path)
        let appearance = try #require(NSAppearance(named: .aqua))
        let image = await Self.load(entry, kind: .thumbnail, appearance: appearance)
        let loaded = try #require(image)
        let cgImage = try #require(loaded.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let center = try #require(Self.centerRGBA(of: cgImage))
        #expect(center[0] > 200)
        #expect(center[1] < 50)
        #expect(center[2] < 50)
        #expect(center[3] > 200)
    }

    // MARK: - Helpers

    /// Ask until the loader has the image, as a pane does on each `didLoadNotification`.
    private static func load(
        _ entry: FileEntry,
        kind: RowIconLoader.Kind,
        appearance: NSAppearance
    ) async -> NSImage? {
        let ask = {
            RowIconLoader.shared.image(
                for: entry,
                kind: kind,
                pointSize: 16,
                scale: 2,
                appearance: appearance
            )
        }
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if let image = ask() { return image }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return ask()
    }

    private static func entry(
        _ path: String,
        kind: FileEntry.Kind = .file,
        backend: VFSBackendID = .local
    ) -> FileEntry {
        FileEntry(
            path: VFSPath(backend: backend, path: path),
            name: (path as NSString).lastPathComponent,
            kind: kind,
            byteSize: 1,
            modificationDate: Date(),
            creationDate: Date(),
            isHidden: false,
            permissions: 0o644,
            inode: 0
        )
    }

    /// A 64-pixel opaque red square, as PNG.
    private static func redSquarePNG() throws -> Data {
        let context = try #require(sRGBContext(side: 64))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let image = try #require(context.makeImage())
        return try #require(
            NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        )
    }

    /// The middle pixel of `image` drawn into an sRGB bitmap, as `[r, g, b, a]` in 0…255.
    private static func centerRGBA(of image: CGImage) -> [UInt8]? {
        guard let context = sRGBContext(side: 1) else { return nil }
        // Draw the image so that only its middle pixel lands in the one-pixel bitmap.
        context.interpolationQuality = .none
        context.draw(
            image,
            in: CGRect(
                x: -CGFloat(image.width / 2),
                y: -CGFloat(image.height / 2),
                width: CGFloat(image.width),
                height: CGFloat(image.height)
            )
        )
        guard let data = context.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        return (0..<4).map { bytes[$0] }
    }

    private static func sRGBContext(side: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    /// The image drawn at 32 px, as bytes to compare.
    private static func pixels(_ image: NSImage) -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 32,
            pixelsHigh: 32,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return Data() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData else { return Data() }
        return Data(bytes: data, count: rep.bytesPerRow * 32)
    }
}

/// How many times a notification arrived. Read on the main actor after a synchronous post.
private final class PostCount: @unchecked Sendable {
    var value = 0
}
