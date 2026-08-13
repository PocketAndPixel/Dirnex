import AppKit

/// The card a preview surface draws in place of a remote file nobody has asked for yet
/// (PLAN.md §M21 Slice 10).
///
/// Quick View follows the cursor, and a remote fetch costs a billed request and somebody's
/// bandwidth — so a row the cursor merely passed over is deliberately *not* downloaded. What is left
/// to draw is the question this answers. A blank surface would be the natural thing to leave, and it
/// is the wrong one: blank reads as "this file is empty" or as the preview being broken, where the
/// truth is a decision Dirnex made on the user's behalf. So the card names the file, says how large
/// it is, and says which key fetches it.
extension QuickViewPreviewView {
    /// Show the card for `placeholder`, blanking whatever the backends were holding.
    ///
    /// Routed through `showQuickLook(nil)` rather than a fifth stand-down at every other backend's
    /// call site: the four `show*` methods each list the others by hand, and a fifth entry in four
    /// lists is four chances to forget one. Here the existing empty-preview path does it once.
    func showPlaceholder(_ placeholder: RemotePreviewPlaceholder) {
        let card = ensurePlaceholderCard()
        showQuickLook(nil)
        card.isHidden = false
        card.show(placeholder)
    }

    /// Take the card down. Called by the one funnel every render goes through (`show(_:style:_:)`),
    /// so no individual backend has to know it exists.
    func standDownPlaceholder() {
        placeholderCard?.isHidden = true
    }

    private func ensurePlaceholderCard() -> QuickViewPlaceholderCard {
        if let placeholderCard { return placeholderCard }
        let card = QuickViewPlaceholderCard()
        pin(card, inside: content)
        placeholderCard = card
        return card
    }
}

/// The card itself: a glyph, the file's name, its size, and what to press.
///
/// Centered rather than filling, and deliberately quiet — it is a statement about why there is
/// nothing here, not a thing to read.
@MainActor
final class QuickViewPlaceholderCard: NSView {
    private let glyph = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // `NSView` does not clip, and `draw(_:)`'s `dirtyRect` can exceed the bounds — the same
        // whole-window bug the surface itself guards against (docs/NOTES.md ▸ AppKit).
        clipsToBounds = true
        buildSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ placeholder: RemotePreviewPlaceholder) {
        nameLabel.stringValue = placeholder.name
        sizeLabel.stringValue = placeholder.size ?? String(
            localized: "Size not reported by the server",
            comment: "Quick View placeholder subtitle when a remote file's size is unknown."
        )
    }

    private func buildSubviews() {
        glyph.image = NSImage(
            systemSymbolName: "arrow.down.circle",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 40, weight: .regular))
        glyph.contentTintColor = .tertiaryLabelColor
        // An `NSImageView` defends its image's size at priority 750, which in a stack is enough to
        // push a container outward (docs/NOTES.md ▸ AppKit). It is a passenger here, not the thing
        // being sized.
        glyph.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        glyph.setContentHuggingPriority(.defaultLow, for: .horizontal)

        nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        sizeLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.alignment = .center

        hintLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.alignment = .center
        // Wrapping, and therefore needing a width to wrap *within*: a wrapping label with no width
        // constraint takes its intrinsic single-line width and overruns instead (docs/NOTES.md ▸
        // Localization). The stack's own width constraint below is that bound, and it is what keeps
        // a longer translation on two lines rather than off the edge.
        hintLabel.lineBreakMode = .byWordWrapping
        hintLabel.maximumNumberOfLines = 0
        hintLabel.stringValue = String(
            localized: """
            This file is on the server and hasn’t been downloaded. Press ⌘Y to fetch it, or ⏎ to \
            open it.
            """,
            comment: "Quick View placeholder hint naming the keys that download a remote file."
        )

        let stack = NSStackView(views: [glyph, nameLabel, sizeLabel, hintLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(12, after: glyph)
        stack.setCustomSpacing(14, after: sizeLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // 280 pt is what the hint wants, not what it must have: a pane narrower than that would
        // otherwise have an unsatisfiable layout, and this surface is shown at three sizes down to
        // half of a 640 pt window. Preferred rather than required, bounded by the surface itself.
        let preferredWidth = stack.widthAnchor.constraint(equalToConstant: 280)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            preferredWidth,
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32)
        ])
    }
}
