// Dirnex app-icon generator.
//
// Renders the AppIcon set natively with CoreGraphics — no external tools, no
// SVG conversion — so the icon is fully reproducible from source.
//
// The mark: a system-blue squircle holding a white dual-pane card, split
// full-height, with list bars per pane. One bar in the active (right) pane is
// brand blue — the keyboard-selection cursor.
//
// Small-size quality: a single detailed artwork shrunk to 16-32px turns to
// mush — the drop shadow becomes a halo and thin strokes fall below one pixel.
// So the drawing is SIZE-AWARE (the same thing Apple does by shipping distinct
// 16/32 vs 128+ artwork):
//   * >=128px  full detail: shadow, rim highlight, hairline border, 3 bars.
//   * 64px     3 crisp bars, flat (no shadow/border).
//   * <=32px   2 chunky bars, larger card, no decoration.
//   * every edge/length is snapped to the device-pixel grid, strokes clamped
//     to a whole-pixel minimum, so nothing blurs.
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
    let scale = S / 1024.0
    let px = 1024.0 / S // design units per device pixel
    // Snap a design coordinate to the device-pixel grid.
    func sv(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
    // Snap a length to whole device pixels, at least `minPx`.
    func sl(_ v: CGFloat, _ minPx: CGFloat = 1) -> CGFloat { max((v * scale).rounded(), minPx) / scale }

    let decorate = S >= 128 // shadow, rim highlight, hairline border
    let useVignette = S >= 96
    let barsN = S <= 40 ? 2 : 3

    ctx.saveGState()
    ctx.translateBy(x: 0, y: S)
    ctx.scaleBy(x: 1, y: -1)
    ctx.scaleBy(x: scale, y: scale)

    // ---- Background squircle ----
    let inset: CGFloat = 92
    let bg = CGRect(x: inset, y: inset, width: 1024 - 2 * inset, height: 1024 - 2 * inset)
    let bgPath = roundedRectPath(bg, radius: bg.width * 0.2237)

    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
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
    let sheen = CGGradient(
        colorsSpace: sRGB,
        colors: [rgb(1, 1, 1, 0.20), rgb(1, 1, 1, 0)] as CFArray,
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
    if useVignette {
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
    }
    ctx.restoreGState()

    if decorate {
        ctx.saveGState()
        ctx.addPath(bgPath)
        ctx.setStrokeColor(rgb(1, 1, 1, 0.18))
        ctx.setLineWidth(3)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // ---- Dual-pane card (pixel-snapped edges) ----
    let marginX: CGFloat = S <= 40 ? 176 : 214
    let cardTopY: CGFloat = S <= 40 ? 250 : 286
    let cardBotY: CGFloat = S <= 40 ? 774 : 738
    let cx = sv(512)
    let cardL = sv(marginX), cardR = sv(1024 - marginX)
    let cardT = sv(cardTopY), cardB = sv(cardBotY)
    let card = CGRect(x: cardL, y: cardT, width: cardR - cardL, height: cardB - cardT)
    let cardPath = roundedRectPath(card, radius: S <= 40 ? sl(38) : 58)

    if decorate {
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: 22),
            blur: 46,
            color: rgb(0.02, 0.10, 0.30, 0.38)
        )
        ctx.addPath(cardPath)
        ctx.setFillColor(rgb(1, 1, 1))
        ctx.fillPath()
        ctx.restoreGState()
    } else {
        ctx.addPath(cardPath)
        ctx.setFillColor(rgb(1, 1, 1))
        ctx.fillPath()
    }

    ctx.saveGState()
    ctx.addPath(cardPath)
    ctx.clip()

    // Full-height dual-pane split, >= 2 device px, snapped.
    let dividerW = sl(max(5, 2 * px), 2)
    ctx.setFillColor(rgb(0.78, 0.83, 0.89))
    ctx.fill(CGRect(x: sv(cx - dividerW / 2), y: card.minY, width: dividerW, height: card.height))

    // ---- Bars ----
    let sidePad: CGFloat = S <= 40 ? 34 : 52
    let midPad: CGFloat = S <= 40 ? 26 : 40
    let leftStart = sv(card.minX + sidePad)
    let leftEnd = cx - midPad
    let rightStart = cx + midPad
    let rightEnd = sv(card.maxX - sidePad)
    let leftW = leftEnd - leftStart
    let rightW = rightEnd - rightStart

    let vPad: CGFloat = S <= 40 ? 74 : 86
    let barTop = card.minY + vPad
    let barBot = card.maxY - vPad
    let barHpx: CGFloat = S <= 24 ? 2 : (S <= 40 ? 3 : (S < 128 ? 4 : 48 * scale))
    let barH = sl(barHpx * px, 2)

    let gray = rgb(0.71, 0.76, 0.84)
    let blue = rgb(0.04, 0.52, 1.0)

    func bar(x: CGFloat, cY: CGFloat, w: CGFloat, h: CGFloat, color: CGColor) {
        let rect = CGRect(x: x, y: sv(cY - h / 2), width: w, height: h)
        ctx.addPath(roundedRectPath(rect, radius: min(h / 2.4, w / 2)))
        ctx.setFillColor(color)
        ctx.fillPath()
    }

    // Row centers.
    var centers: [CGFloat] = []
    if barsN == 2 {
        // Two rows grouped near the middle (a tidy short list), not pinned to edges.
        let mid = (barTop + barBot) / 2
        let spread = (barBot - barTop) * 0.24
        centers = [mid - spread, mid + spread]
    } else {
        for i in 0..<barsN {
            centers.append(barTop + (barBot - barTop) * CGFloat(i) / CGFloat(barsN - 1))
        }
    }

    let leftFrac: [CGFloat] = barsN == 2 ? [1.0, 0.74] : [1.0, 0.72, 0.88]
    let rightFrac: [CGFloat] = barsN == 2 ? [0.82, 1.0] : [0.85, 1.0, 0.6]
    let selected = 1

    for i in 0..<barsN {
        let cY = centers[i]
        bar(x: leftStart, cY: cY, w: sl(leftW * leftFrac[i]), h: barH, color: gray)
        if i == selected {
            // Bold brand-blue selection bar (the keyboard cursor).
            let selH = sl(barH + (S <= 40 ? 0 : 12), 2)
            bar(
                x: sv(rightStart - (S <= 40 ? 0 : 10)),
                cY: cY,
                w: sl(rightW + (S <= 40 ? 0 : 20)),
                h: selH,
                color: blue
            )
        } else {
            bar(x: rightStart, cY: cY, w: sl(rightW * rightFrac[i]), h: barH, color: gray)
        }
    }

    ctx.restoreGState() // card clip

    if decorate {
        ctx.saveGState()
        ctx.addPath(cardPath)
        ctx.setStrokeColor(rgb(0.62, 0.70, 0.82, 0.32))
        ctx.setLineWidth(2)
        ctx.strokePath()
        ctx.restoreGState()
    }

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
