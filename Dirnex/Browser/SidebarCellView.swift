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

    private let icon = NSImageView()
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
            accessibilityDescription: "Eject"
        )
        ejectButton.contentTintColor = .secondaryLabelColor
        ejectButton.target = self
        ejectButton.action = #selector(eject)
        ejectButton.toolTip = "Eject"
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
        icon.image = image
        ejectButton.isHidden = !canEject
        toolTip = tooltip
        setBusy(isBusy)
        updateTrailingLayout()
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
        toolTip = isCollapsed ? "Show \(title)" : "Hide \(title)"
    }

    /// Down when open, right when folded — the direction every macOS source list points.
    private static func chevron(isCollapsed: Bool) -> NSImage {
        let name = isCollapsed ? "chevron.right" : "chevron.down"
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        let image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: isCollapsed ? "Collapsed" : "Expanded"
        )?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image ?? NSImage()
    }
}
