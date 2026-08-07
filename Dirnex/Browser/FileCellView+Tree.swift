import AppKit
import DirnexCore

/// The tree disclosure triangle. It draws a chevron but is invisible to the mouse: `hitTest`
/// returns `nil`, so a click on it passes through to the `FileTableView` beneath, which toggles the
/// row from `mouseDown`. See the note at its construction in `FileCellView` — a live button ran its
/// own tracking loop and dropped trackpad clicks that drifted off the narrow glyph.
final class DisclosureTriangleView: NSButton {
    override func hitTest(_: NSPoint) -> NSView? { nil }
}

/// The name cell's tree geometry (PLAN.md §M15 Slice 4): the indentation a row takes for its depth,
/// the disclosure triangle, and the colour that triangle is painted in.
///
/// Split out of `FileCellView` when the Git badge arrived and the file reached SwiftLint's 500-line
/// ceiling — by concept rather than by line count, which is what docs/NOTES.md asks for. The stored
/// properties stay in the class (Swift has no other choice) and the members this file touches widen
/// to internal, since `private` does not cross a file boundary.
extension FileCellView {
    /// Position the icon and the disclosure triangle for this row's depth and state. A no-op on the
    /// cells that carry no icon (size/date never show tree structure). Runs per render from the
    /// controller, after `isTreeRow`/`treeDepth`/`treeDisclosure` are set — never from
    /// `backgroundStyle`'s `didSet`, since the layout does not depend on the cursor.
    func applyTreeLayout() {
        guard let iconLeading else { return }
        guard isTreeRow else {
            // List mode (or a cell recycled out of the tree): the shipped rendering, exactly.
            disclosureButton?.isHidden = true
            iconLeading.constant = Self.iconInsetList
            return
        }
        let indent = CGFloat(treeDepth) * Self.treeIndentPerLevel
        // Every tree row reserves the disclosure slot — a file lines up under its sibling folders
        // rather than jutting a triangle's width to the left of them.
        iconLeading.constant = Self.treeLeadingInset + indent + Self.treeDisclosureSlot
        if let treeDisclosure {
            disclosureLeading?.constant = Self.treeLeadingInset + indent
            disclosureBaseImage = Self.chevron(expanded: treeDisclosure == .expanded)
            applyDisclosureForeground()
            disclosureButton?.isHidden = false
        } else {
            disclosureButton?.isHidden = true
        }
    }

    /// Paint the triangle in the same foreground the name draws in — on the cursor row the derived
    /// `cursorForeground`, elsewhere the secondary label colour AppKit's own outline disclosure uses.
    /// Runs from both `applyTreeLayout` (which has just chosen the glyph) and `applyStyle` (which
    /// runs again on its own when the cursor moves onto or off this row).
    ///
    /// **`contentTintColor` is the obvious spelling and is silently ignored**, exactly as it is for
    /// an `NSTableCellView`'s `imageView` — an emphasized cell repaints a template image white
    /// whatever tint the control carries, so a pale cursor colour left a white chevron beside black
    /// text. Baking the colour in is what the emphasized row honours, because the result is no longer
    /// a template for AppKit to re-tint. See `SidebarCellView.applySelectionForeground`, which hit
    /// the same wall on the sidebar's glyphs.
    /// Only the emphasized half is baked. Off the cursor the glyph stays a template tinted the
    /// ordinary way, so `.secondaryLabelColor` goes on resolving itself against the live appearance
    /// — a baked copy would hold whichever appearance it was drawn in until the next render.
    func applyDisclosureForeground() {
        guard let disclosureBaseImage else { return }
        guard backgroundStyle == .emphasized else {
            disclosureButton?.image = disclosureBaseImage
            disclosureButton?.contentTintColor = .secondaryLabelColor
            return
        }
        disclosureButton?.image = Self.tinted(disclosureBaseImage, palette.cursorForeground)
    }

    /// `image` painted in `color`, keeping its coverage: `.sourceAtop` replaces the colour of every
    /// pixel the glyph covers and leaves its alpha, so the antialiased edges survive. The copy is no
    /// longer a template, which is the whole point — there is nothing left for AppKit to re-tint.
    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        let copy = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        copy.isTemplate = false
        return copy
    }

    /// Whether `windowPoint` (window coordinates) lands on this row's disclosure triangle — the
    /// whole full-height hit box, not just the glyph, and `false` on a file, `..`, or list mode
    /// where the triangle is hidden. `FileTableView.mouseDown` calls this to toggle the row itself
    /// instead of letting the click reach the button through `NSTableView`'s tracking loop, where a
    /// trackpad's slight finger movement is read as a drag and the triangle needs several taps.
    func disclosureHitTarget(containsWindowPoint windowPoint: NSPoint) -> Bool {
        guard let disclosureButton, !disclosureButton.isHidden,
              let disclosureLeading, let iconLeading else { return false }
        let hit = convert(windowPoint, from: nil)
        guard hit.y >= 0, hit.y <= bounds.height else { return false }
        // The triangle's zone is the whole slot from its leading edge to the folder icon, full row
        // height, plus a few points of slop toward the panel edge. A wide, forgiving target on
        // purpose: the glyph is small and sits in the thin left margin, so a click a pixel shy of it
        // (or in that margin) must still toggle rather than fall through to the drag-prone path.
        return hit.x >= disclosureLeading.constant - 4 && hit.x < iconLeading.constant
    }

    /// Right when closed, down when open — the direction every macOS disclosure points, matching the
    /// sidebar's own section chevrons.
    private static func chevron(expanded: Bool) -> NSImage {
        let name = expanded ? "chevron.down" : "chevron.right"
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        let image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: expanded
                ? String(
                    localized: "Expanded",
                    comment: "Accessibility state of an open tree folder's disclosure triangle."
                )
                : String(
                    localized: "Collapsed",
                    comment: "Accessibility state of a closed tree folder's disclosure triangle."
                )
        )?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image ?? NSImage()
    }
}
