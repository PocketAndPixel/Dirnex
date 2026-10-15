import AppKit
import Testing

/// A display capture's RGBA bytes, without an NSColor and two assertions for every pixel.
/// Keep the same components as `colorAt`: RGB is divided by alpha, not by 255, because
/// AppKit's 8-bit display captures store premultiplied colors. Row padding is kept too.
struct BitmapPixels {
    let width: Int
    let height: Int
    let colorSpace: NSColorSpace
    private let bytesPerRow: Int
    private let bytes: [UInt8]

    @MainActor
    init(capturing view: NSView) throws {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try self.init(rep)
    }

    /// `view` drawn at `scale` pixels per point, whatever display the test host is on. The capture
    /// above follows the window's screen, which is 2x on a Mac with a Retina display and 1x on the
    /// CI runner, so an assertion about where anti-aliasing lands needs this one.
    @MainActor
    init(capturing view: NSView, scale: CGFloat) throws {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((view.bounds.width * scale).rounded(.up)),
            pixelsHigh: Int((view.bounds.height * scale).rounded(.up)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32
        ))
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        try self.init(rep)
    }

    init(_ rep: NSBitmapImageRep) throws {
        // Fail on a different format instead of silently comparing the wrong channels.
        try #require(rep.bitsPerSample == 8 && rep.samplesPerPixel == 4 && rep.bitsPerPixel == 32)
        try #require(rep.hasAlpha && !rep.isPlanar && rep.bitmapFormat.isEmpty)
        try #require(rep.bytesPerRow >= rep.pixelsWide * 4)
        let data = try #require(rep.bitmapData)
        width = rep.pixelsWide
        height = rep.pixelsHigh
        colorSpace = rep.colorSpace
        bytesPerRow = rep.bytesPerRow
        bytes = Array(UnsafeBufferPointer(start: data, count: bytesPerRow * height))
    }

    func rgba(x: Int, y: Int) -> SIMD4<Double> {
        let offset = y * bytesPerRow + x * 4
        let alpha = Double(bytes[offset + 3])
        guard alpha > 0 else { return .zero }
        return SIMD4(
            Double(bytes[offset]) / alpha,
            Double(bytes[offset + 1]) / alpha,
            Double(bytes[offset + 2]) / alpha,
            alpha / 255
        )
    }
}
