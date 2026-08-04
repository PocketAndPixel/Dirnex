import AppKit

/// One item row in the sidebar: an icon, a name, and a trailing eject button (for ejectable
/// volumes). The eject button is always visible when applicable, and the name reserves space
/// before it so it never runs underneath. Headers use `SidebarHeaderView` instead.
///
/// The eject action routes through a stored closure rather than target/action so the controller
/// can hand each reused cell the right behavior without subclass bookkeeping. Removing a row
/// (saved searches, servers, favorites) is a right-click-menu action, not a per-row button.
final class SidebarCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarItemCell")

    /// Invoked when the eject button is clicked; `nil` hides the button.
    var onEject: (() -> Void)?

    /// What the label and glyph draw in while this row is the sidebar's cursor, or `nil` — the
    /// untouched case — to leave both to AppKit. Pushed by `SidebarRowView`, which is the only place
    /// that knows the row's selection *and* emphasis; a cell sees only `backgroundStyle`, which is
    /// `.normal` for a selected-but-unfocused row and so cannot tell it from an ordinary one.
    ///
    /// The tag rows are unaffected by construction: their dot is not a template image, so no tint
    /// reaches it (`SidebarViewController+Tags`), which is exactly the intent — a tag's colour is
    /// the one thing it has to say.
    var selectionForeground: NSColor? {
        didSet {
            guard selectionForeground != oldValue else { return }
            applySelectionForeground()
        }
    }

    private let icon = NSImageView()
    /// The glyph exactly as the row builder handed it over, so a tint is always derived from the
    /// original rather than compounded onto the last tinted copy.
    private var baseImage: NSImage?
    private let label = NSTextField(labelWithString: "")
    private let ejectButton = NSButton()
    /// Overlays the icon while a server row is connecting; a spinner replaces the leading glyph so
    /// the row visibly reads as "working" without shifting its layout.
    private let spinner = NSProgressIndicator()

    /// The label's trailing edge has two possible anchors, chosen per row by
    /// `updateTrailingLayout`: against the eject button, or close to the cell's own trailing edge
    /// (rows with no eject button, so the name uses full width). Exactly one is active at a time so
    /// the name never overlaps the button.
    private var labelTrailingToEject: NSLayoutConstraint!
    private var labelTrailingToEdge: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = SidebarCellView.identifier

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        addSubview(icon)
        imageView = icon

        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        addSubview(label)
        textField = label

        ejectButton.translatesAutoresizingMaskIntoConstraints = false
        ejectButton.isBordered = false
        ejectButton.bezelStyle = .accessoryBarAction
        ejectButton.imagePosition = .imageOnly
        ejectButton.image = NSImage(
            systemSymbolName: "eject.fill",
            accessibilityDescription: String(
                localized: "Eject",
                comment: "Accessibility label and tooltip for a volume row's eject button."
            )
        )
        ejectButton.contentTintColor = .secondaryLabelColor
        ejectButton.target = self
        ejectButton.action = #selector(eject)
        ejectButton.toolTip = String(
            localized: "Eject",
            comment: "Accessibility label and tooltip for a volume row's eject button."
        )
        addSubview(ejectButton)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true // shown by `setBusy` only while a server row is connecting
        addSubview(spinner)

        labelTrailingToEject = ejectButton.leadingAnchor.constraint(
            greaterThanOrEqualTo: label.trailingAnchor,
            constant: 4
        )
        labelTrailingToEdge = label.trailingAnchor.constraint(
            equalTo: trailingAnchor,
            constant: -6
        )

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            ejectButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            ejectButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            ejectButton.widthAnchor.constraint(equalToConstant: 16),

            // The spinner sits exactly over the icon so swapping the two doesn't nudge the label.
            spinner.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The image arrives already sized by the caller — an SF Symbol at its natural aspect;
    /// the 18×18 image view + proportional scaling keeps it in bounds without squashing
    /// non-square symbols.
    func configure(
        name: String,
        image: NSImage,
        canEject: Bool,
        tooltip: String?,
        isBusy: Bool = false
    ) {
        label.stringValue = name
        baseImage = image
        ejectButton.isHidden = !canEject
        toolTip = tooltip
        setBusy(isBusy)
        updateTrailingLayout()
        // Last, and unconditionally: a recycled cell may already be the cursor's, and the glyph it
        // has just been given has to arrive tinted rather than a repaint later.
        applySelectionForeground()
    }

    /// Paint the label, the glyph and the eject button in the cursor colour's foreground — or hand
    /// all three back to AppKit, which tints a template symbol and colours a label from the cell's
    /// own `backgroundStyle`. `nil` restores exactly what the cell was built with, so an untouched
    /// palette leaves the sidebar drawing as it always did.
    ///
    /// **The glyph cannot go through `contentTintColor`, which is the obvious spelling and is
    /// silently ignored.** Probed on a real cell: an emphasized `NSTableCellView` draws its
    /// `imageView`'s template image white whatever tint the view carries — pixel-identical to an
    /// untinted control, in either assignment order — so a pale cursor colour got a black label
    /// beside a white house. It works only while the cell is `.normal`, which is exactly the half
    /// that already looked right. Baking the colour into the image is what the emphasized row
    /// honours, because the result is no longer a template for AppKit to re-tint.
    private func applySelectionForeground() {
        label.textColor = selectionForeground
        ejectButton.contentTintColor = selectionForeground ?? .secondaryLabelColor
        guard let baseImage else { return }
        if let selectionForeground, baseImage.isTemplate {
            icon.image = Self.tinted(baseImage, selectionForeground)
        } else {
            icon.image = baseImage
        }
    }

    /// `image` painted in `color`, keeping its shape: `.sourceAtop` replaces the colour of every
    /// pixel the glyph covers and leaves its coverage — so the antialiased edges survive.
    ///
    /// Deliberately general rather than an SF Symbol configuration (`paletteColors:`, measured to
    /// render identically): it works for any template image, so a sidebar glyph that is not a symbol
    /// tints too. A **non**-template image is never handed here — a tag's dot carries the one colour
    /// that must not be overwritten (`SidebarViewController+Tags`).
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

    /// Swap the leading icon for a spinning indicator while a server row connects — the icon is hidden
    /// (not removed) so the layout holds. Reset on every `configure` so a reused cell never inherits a
    /// stale spinner from the server row it last rendered.
    private func setBusy(_ busy: Bool) {
        icon.isHidden = busy
        spinner.isHidden = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    /// Reserve the label's trailing space against the eject button when a volume shows one, so the
    /// name never runs underneath; otherwise let the name use the full width. Runs from `configure`.
    private func updateTrailingLayout() {
        let showsEject = !ejectButton.isHidden
        labelTrailingToEject.isActive = showsEject
        labelTrailingToEdge.isActive = !showsEject
    }

    @objc private func eject() {
        onEject?()
    }
}

/// A section header ("Favorites", "Volumes") in the sidebar. A source-list group row
/// AppKit already renders with the right vibrancy; this supplies the label and the disclosure
/// triangle that folds the section (PLAN.md §M8).
///
/// **The triangle is always visible, not revealed on hover** (which is what Finder does with its
/// Show/Hide button). It is a state indicator before it is a control: with nothing drawn, a folded
/// Volumes section and a Volumes section on a machine with no volumes look exactly alike — the
/// sidebar would claim there is nothing there when the truth is that the user hid it. The click
/// target is the whole header row, so the glyph only has to be legible, not hittable.
final class SidebarHeaderView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarHeaderCell")

    private let disclosure = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = SidebarHeaderView.identifier

        disclosure.translatesAutoresizingMaskIntoConstraints = false
        disclosure.imageScaling = .scaleProportionallyDown
        disclosure.contentTintColor = .tertiaryLabelColor
        addSubview(disclosure)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        addSubview(label)
        textField = label

        NSLayoutConstraint.activate([
            disclosure.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            disclosure.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
            disclosure.widthAnchor.constraint(equalToConstant: 9),

            label.leadingAnchor.constraint(equalTo: disclosure.trailingAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, isCollapsed: Bool) {
        label.stringValue = title
        disclosure.image = Self.chevron(isCollapsed: isCollapsed)
        // Says which way the click goes, and — unlike the glyph — states the current state in
        // words, which is what VoiceOver and a hovering user each get nothing else from.
        toolTip = isCollapsed
            ? String(
                localized: "Show \(title)",
                comment: "Tooltip on a folded sidebar section header; %@ is the section name."
            )
            : String(
                localized: "Hide \(title)",
                comment: "Tooltip on an open sidebar section header; %@ is the section name."
            )
    }

    /// Down when open, right when folded — the direction every macOS source list points.
    private static func chevron(isCollapsed: Bool) -> NSImage {
        let name = isCollapsed ? "chevron.right" : "chevron.down"
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        let image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: isCollapsed
                ? String(
                    localized: "Collapsed",
                    comment: "Accessibility state of a folded sidebar section's disclosure triangle."
                )
                : String(
                    localized: "Expanded",
                    comment: "Accessibility state of an open sidebar section's disclosure triangle."
                )
        )?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image ?? NSImage()
    }
}
