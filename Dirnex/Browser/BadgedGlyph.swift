import AppKit

/// A template SF Symbol with a smaller one in its bottom-right corner: a pinned folder, marked with
/// where it lives (`SidebarPlacePresentation.badgeSymbolName`).
///
/// Drawn here because SF Symbols has no such pairs. It ships `folder.badge.plus` and a few like it,
/// and nothing for a drive, a cloud or a protocol. The badge is cut out of the folder by a ring of
/// clear pixels that follows its own outline, so the two shapes read apart at sidebar size. What
/// comes out is still one template image, so AppKit tints it like every other row glyph, and the
/// sidebar's cursor color reaches it through `.sourceAtop` like every other (`SidebarCellView`).
enum BadgedGlyph {
    /// `symbol` at `pointSize`, with `badge` at two thirds of that size in its corner, or the plain
    /// symbol when `badge` is `nil`.
    ///
    /// `canvas` is the box the image will be shown in. The sidebar's image view is a fixed square
    /// that scales a wider symbol down, so the folder is drawn here exactly as that view would draw
    /// the plain one, and a marked folder lines up with the unmarked ones around it. `nil` keeps the
    /// symbol's own size, which is how a menu shows its images.
    static func image(
        symbol: String,
        pointSize: CGFloat,
        badge: String?,
        canvas: NSSize? = nil,
        describedAs description: String? = nil
    ) -> NSImage {
        let base = templateSymbol(symbol, pointSize: pointSize, weight: .regular, description)
        guard let badge else { return base }
        let mark = templateSymbol(badge, pointSize: pointSize * 2 / 3, weight: .semibold, nil)
        let size = canvas ?? base.size
        let halo = pointSize * 0.08
        let image = NSImage(size: size, flipped: false) { bounds in
            base.draw(in: fitted(base.size, in: bounds))
            // Half a point past the corner: a symbol's box carries a margin around its ink, and this
            // keeps the mark's ink near the folder's edge rather than inset from it.
            let corner = NSRect(
                x: bounds.maxX - mark.size.width + 0.5,
                y: bounds.minY - 0.5,
                width: mark.size.width,
                height: mark.size.height
            )
            for step in 0..<16 {
                let angle = CGFloat(step) * .pi / 8
                let ring = corner.offsetBy(dx: cos(angle) * halo, dy: sin(angle) * halo)
                mark.draw(in: ring, from: .zero, operation: .destinationOut, fraction: 1)
            }
            mark.draw(in: corner)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }

    /// Where an image view with `scaleProportionallyDown` would draw something `size` big: shrunk to
    /// fit `bounds` if it is larger, never enlarged, and centered.
    static func fitted(_ size: NSSize, in bounds: NSRect) -> NSRect {
        let scale = min(1, bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return NSRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
    }

    private static func templateSymbol(
        _ name: String,
        pointSize: CGFloat,
        weight: NSFont.Weight,
        _ description: String?
    ) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = true
        return image
    }
}
