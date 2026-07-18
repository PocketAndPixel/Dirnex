// Dirnex app-icon generator.
//
// Renders the AppIcon set natively with CoreGraphics — no external tools, no
// SVG conversion — so the icon is fully reproducible from source. The design
// is authored in a 1024x1024 top-left-origin (y-down) space and rendered at
// each required pixel size for crisp small-icon output.
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
    let bgInset: CGFloat = 92
    let bgRect = CGRect(
        x: bgInset,
        y: bgInset,
        width: 1024 - 2 * bgInset,
        height: 1024 - 2 * bgInset
    )
    let bgRadius = bgRect.width * 0.2237
    let bgPath = roundedRectPath(bgRect, radius: bgRadius)

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
        start: CGPoint(x: bgRect.minX, y: bgRect.minY),
        end: CGPoint(x: bgRect.maxX, y: bgRect.maxY),
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
        end: CGPoint(x: 512, y: bgRect.maxY),
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

    // ---- Dual-pane window card ----
    let cardRect = CGRect(x: 232, y: 268, width: 560, height: 496)
    let cardRadius: CGFloat = 60
    let cardPath = roundedRectPath(cardRect, radius: cardRadius)

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

    let headerH: CGFloat = 96
    let centerX: CGFloat = 512
    let headerBottom = cardRect.minY + headerH

    // Inactive (left) and active (right, blue-tinted) pane headers.
    ctx.setFillColor(rgb(0.945, 0.960, 0.976))
    ctx.fill(
        CGRect(x: cardRect.minX, y: cardRect.minY, width: centerX - cardRect.minX, height: headerH)
    )
    ctx.setFillColor(rgb(0.898, 0.949, 1.0))
    ctx.fill(CGRect(x: centerX, y: cardRect.minY, width: cardRect.maxX - centerX, height: headerH))
    ctx.setFillColor(rgb(0.86, 0.89, 0.93))
    ctx.fill(CGRect(x: cardRect.minX, y: headerBottom - 2, width: cardRect.width, height: 3))

    func headerPill(centerAt cx: CGFloat, color: CGColor, width w: CGFloat) {
        let pill = CGRect(x: cx - w / 2, y: cardRect.minY + headerH / 2 - 12, width: w, height: 24)
        ctx.addPath(roundedRectPath(pill, radius: 12))
        ctx.setFillColor(color)
        ctx.fillPath()
    }
    headerPill(centerAt: (cardRect.minX + centerX) / 2, color: rgb(0.78, 0.82, 0.87), width: 150)
    headerPill(centerAt: (centerX + cardRect.maxX) / 2, color: rgb(0.36, 0.60, 0.98), width: 150)

    // Full-height dual-pane split.
    ctx.setFillColor(rgb(0.85, 0.88, 0.92))
    ctx.fill(CGRect(x: centerX - 1.5, y: cardRect.minY, width: 3, height: cardRect.height))

    // ---- Directory rows ----
    let rowH: CGFloat = 40
    let rowGap: CGFloat = 42
    let firstRowY: CGFloat = headerBottom + 44
    let sidePad: CGFloat = 40
    let midPad: CGFloat = 30
    let dotW: CGFloat = 30

    let leftStart = cardRect.minX + sidePad
    let leftEnd = centerX - midPad
    let rightStart = centerX + midPad
    let rightEnd = cardRect.maxX - sidePad

    let barWidths: [CGFloat] = [1.0, 0.66, 0.82, 0.5]
    let selectedRow = 1

    func drawRow(
        y: CGFloat,
        xStart: CGFloat,
        xEnd: CGFloat,
        widthFrac: CGFloat,
        dotColor: CGColor,
        barColor: CGColor
    ) {
        let dot = CGRect(x: xStart, y: y + (rowH - dotW) / 2, width: dotW, height: dotW)
        ctx.addPath(roundedRectPath(dot, radius: 8))
        ctx.setFillColor(dotColor)
        ctx.fillPath()
        let barX = xStart + dotW + 18
        let maxBar = xEnd - barX
        let barRect = CGRect(x: barX, y: y + (rowH - 20) / 2, width: maxBar * widthFrac, height: 20)
        ctx.addPath(roundedRectPath(barRect, radius: 10))
        ctx.setFillColor(barColor)
        ctx.fillPath()
    }

    let grayDot = rgb(0.72, 0.77, 0.84)
    let grayBar = rgb(0.80, 0.84, 0.89)

    for i in 0..<4 {
        let y = firstRowY + CGFloat(i) * (rowH + rowGap)
        drawRow(
            y: y,
            xStart: leftStart,
            xEnd: leftEnd,
            widthFrac: barWidths[i],
            dotColor: grayDot,
            barColor: grayBar
        )
        if i == selectedRow {
            // Keyboard-cursor selection highlight in brand blue.
            let hi = CGRect(
                x: rightStart - 14,
                y: y - 8,
                width: (rightEnd - rightStart) + 28,
                height: rowH + 16
            )
            ctx.addPath(roundedRectPath(hi, radius: 14))
            ctx.setFillColor(rgb(0.04, 0.52, 1.0))
            ctx.fillPath()
            drawRow(
                y: y,
                xStart: rightStart,
                xEnd: rightEnd,
                widthFrac: barWidths[i],
                dotColor: rgb(1, 1, 1, 0.95),
                barColor: rgb(1, 1, 1, 0.92)
            )
        } else {
            drawRow(
                y: y,
                xStart: rightStart,
                xEnd: rightEnd,
                widthFrac: barWidths[i],
                dotColor: grayDot,
                barColor: grayBar
            )
        }
    }

    ctx.restoreGState() // card clip

    // Card hairline border.
    ctx.saveGState()
    ctx.addPath(cardPath)
    ctx.setStrokeColor(rgb(0.62, 0.70, 0.82, 0.35))
    ctx.setLineWidth(2)
    ctx.strokePath()
    ctx.restoreGState()

    ctx.restoreGState() // design space
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
