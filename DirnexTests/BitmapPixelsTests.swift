import AppKit
import Testing

@Suite("Display capture bytes")
struct BitmapPixelsTests {
    @Test("RGBA components match colorAt, including partial alpha and padded rows")
    func components() throws {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: 16, bitsPerPixel: 32
        ))
        let data = try #require(rep.bitmapData)
        let bytes: [UInt8] = [
            0, 0, 0, 0, 10, 5, 0, 17, 128, 64, 32, 128, 99, 99, 99, 99,
            0, 1, 0, 1, 1, 127, 253, 254, 255, 128, 0, 255, 99, 99, 99, 99
        ]
        for (index, byte) in bytes.enumerated() { data[index] = byte }
        let pixels = try BitmapPixels(rep)
        #expect(pixels.width == 3 && pixels.height == 2)
        for y in 0..<2 {
            for x in 0..<3 {
                let expected = try #require(rep.colorAt(x: x, y: y))
                let actual = pixels.rgba(x: x, y: y)
                #expect(abs(actual.x - expected.redComponent) < 1e-12)
                #expect(abs(actual.y - expected.greenComponent) < 1e-12)
                #expect(abs(actual.z - expected.blueComponent) < 1e-12)
                #expect(abs(actual.w - expected.alphaComponent) < 1e-12)
            }
        }
        // Dividing RGB by 255 would lose color at the antialiased edges of a field.
        #expect(pixels.rgba(x: 2, y: 0) == SIMD4(1, 0.5, 0.25, 128.0 / 255))
        #expect(pixels.rgba(x: 0, y: 0) == .zero)
    }
}
