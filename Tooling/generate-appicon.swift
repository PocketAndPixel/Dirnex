// Dirnex app-icon generator.
//
// Renders the AppIcon set natively with CoreGraphics — no external tools, no
// SVG conversion — so the icon is fully reproducible from source. The design
// is authored in a 1024x1024 top-left-origin (y-down) space and rendered at
// each required pixel size for crisp small-icon output.
//
// The mark: a system-blue squircle holding a white dual-pane card, split
// full-height, with three bold list bars per pane. One bar in the active
// (right) pane is brand blue — the keyboard-selection cursor. Kept deliberately
// low-detail so it still reads at 16-32px.
//
// Run:  swift Tooling/generate-appicon.swift
//       (writes into Dirnex/Assets.xcassets/AppIcon.appiconset by default)
//       swift Tooling/generate-appicon.swift <output-dir>

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [CGFloat(r), CGFloat(g), CGFloat(b), CGFloat(a)])!
}

func roundedRectPath(_ rect: CGRect, radius r: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
}

func drawIcon(into ctx: CGContext, size S: CGFloat) {
    let k = S / 1024.0
    ctx.saveGState()
    ctx.translateBy(x: 0, y: S)
    ctx.scaleBy(x: 1, y: -1)
    ctx.scaleBy(x: k, y: k)

    // ---- Background squircle ----
    let inset: CGFloat = 92
    let bg = CGRect(x: inset, y: inset, width: 1024 - 2 * inset, height: 1024 - 2 * inset)
    let bgPath = roundedRectPath(bg, radius: bg.width * 0.2237)

    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    // On-brand system-blue diagonal gradient.
    let grad = CGGradient(
        colorsSpace: sRGB,
        colors: [rgb(0.29, 0.64, 1.00), rgb(0.02, 0.33, 0.86)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        grad,
        start: CGPoint(x: bg.minX, y: bg.minY),
        end: CGPoint(x: bg.maxX, y: bg.maxY),
        options: []
    )
    // Top sheen.
    let sheen = CGGradient(
        colorsSpace: sRGB,
        colors: [rgb(1, 1, 1, 0.22), rgb(1, 1, 1, 0)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawRadialGradient(
        sheen,
        startCenter: CGPoint(x: 512, y: 250),
        startRadius: 0,
        endCenter: CGPoint(x: 512, y: 250),
        endRadius: 560,
        options: []
    )
    // Bottom vignette.
    let vignette = CGGradient(
        colorsSpace: sRGB,
        colors: [rgb(0, 0.10, 0.35, 0), rgb(0, 0.06, 0.24, 0.28)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        vignette,
        start: CGPoint(x: 512, y: 560),
        end: CGPoint(x: 512, y: bg.maxY),
        options: []
    )
    ctx.restoreGState()

    // Inner top rim highlight.
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.setStrokeColor(rgb(1, 1, 1, 0.18))
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()

    // ---- Dual-pane card ----
    let card = CGRect(x: 214, y: 286, width: 596, height: 452)
    let cardPath = roundedRectPath(card, radius: 58)

    // Floating drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 22), blur: 46, color: rgb(0.02, 0.10, 0.30, 0.38))
    ctx.addPath(cardPath)
    ctx.setFillColor(rgb(1, 1, 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(cardPath)
    ctx.clip()

    let cx: CGFloat = 512
    // Full-height dual-pane split.
    ctx.setFillColor(rgb(0.80, 0.84, 0.90))
    ctx.fill(CGRect(x: cx - 2.5, y: card.minY, width: 5, height: card.height))

    // ---- Three bold bars per pane ----
    let sidePad: CGFloat = 52
    let midPad: CGFloat = 40
    let leftStart = card.minX + sidePad
    let leftEnd = cx - midPad
    let rightStart = cx + midPad
    let rightEnd = card.maxX - sidePad
    let leftW = leftEnd - leftStart
    let rightW = rightEnd - rightStart

    let barH: CGFloat = 48
    let ys: [CGFloat] = [372, 488, 604]
    let gray = rgb(0.73, 0.78, 0.85)
    let leftFrac: [CGFloat] = [1.0, 0.72, 0.88]
    let rightFrac: [CGFloat] = [0.85, 1.0, 0.6]
    let selected = 1

    func bar(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, color: CGColor) {
        ctx.addPath(roundedRectPath(CGRect(x: x, y: y, width: w, height: h), radius: h / 2.6))
        ctx.setFillColor(color)
        ctx.fillPath()
    }

    for i in 0..<3 {
        let y = ys[i]
        bar(x: leftStart, y: y, w: leftW * leftFrac[i], h: barH, color: gray)
        if i == selected {
            // Bold brand-blue selection bar (the keyboard cursor).
            bar(
                x: rightStart - 10,
                y: y - 6,
                w: rightW + 20,
                h: barH + 12,
                color: rgb(0.04, 0.52, 1.0)
            )
        } else {
            bar(x: rightStart, y: y, w: rightW * rightFrac[i], h: barH, color: gray)
        }
    }

    ctx.restoreGState() // card clip

    // Card hairline border.
    ctx.saveGState()
    ctx.addPath(cardPath)
    ctx.setStrokeColor(rgb(0.62, 0.70, 0.82, 0.32))
    ctx.setLineWidth(2)
    ctx.strokePath()
    ctx.restoreGState()

    ctx.restoreGState()
}

func renderPNG(size: Int, to url: URL) {
    let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    drawIcon(into: ctx, size: CGFloat(size))
    let image = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    )!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let defaultOut = "Dirnex/Assets.xcassets/AppIcon.appiconset"
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : defaultOut
let out = URL(fileURLWithPath: outDir, isDirectory: true)

let files: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, size) in files {
    renderPNG(size: size, to: out.appendingPathComponent(name))
}

print("Rendered \(files.count) icon files to \(out.path)")
