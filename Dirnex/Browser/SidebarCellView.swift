import AppKit

/// One item row in the sidebar: an icon, a name, and a trailing action button — an eject
/// (for ejectable volumes) or a delete (for saved searches). Both are always visible when
/// applicable, and the name reserves space before them so it never runs underneath. Headers
/// use `SidebarHeaderView` instead.
///
/// Both actions route through stored closures rather than target/action so the controller
/// can hand each reused cell the right behavior without subclass bookkeeping.
final class SidebarCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarItemCell")

    /// Invoked when the eject button is clicked; `nil` hides the button.
    var onEject: (() -> Void)?
    /// Invoked when the delete button is clicked; `nil` means this row has no delete affordance
    /// (only saved searches do). Setting it shows/hides the always-visible trash button and
    /// re-reserves the label's trailing space.
    var onDelete: (() -> Void)? {
        didSet { updateTrailingLayout() }
    }

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let ejectButton = NSButton()
    private let deleteButton = NSButton()
    /// Overlays the icon while a server row is connecting; a spinner replaces the leading glyph so
    /// the row visibly reads as "working" without shifting its layout.
    private let spinner = NSProgressIndicator()

    /// The label's trailing edge has three possible anchors, chosen per row by
    /// `updateTrailingLayout`: against the eject button, against the delete button, or close to
    /// the cell's own trailing edge (rows with no trailing button, so the name uses full width).
    /// Exactly one is active at a time so the name never overlaps a button.
    private var labelTrailingToEject: NSLayoutConstraint!
    private var labelTrailingToDelete: NSLayoutConstraint!
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

        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.isBordered = false
        deleteButton.bezelStyle = .accessoryBarAction
        deleteButton.imagePosition = .imageOnly
        deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")
        deleteButton.contentTintColor = .secondaryLabelColor
        deleteButton.target = self
        deleteButton.action = #selector(delete)
        deleteButton.toolTip = "Delete saved search"
        deleteButton.isHidden = true // shown by `updateTrailingLayout` only when `onDelete` is set
        addSubview(deleteButton)

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
        labelTrailingToDelete = deleteButton.leadingAnchor.constraint(
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

            // The delete button shares the eject slot — a row is never both ejectable and deletable.
            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant: 16),

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

    /// Show the trailing button this row needs (eject for a volume, delete for a saved search —
    /// a row is never both) and reserve the label's trailing space against it so the name never
    /// runs underneath. Runs from `configure` (eject state) and `onDelete`'s `didSet`.
    private func updateTrailingLayout() {
        let showsEject = !ejectButton.isHidden
        let showsDelete = onDelete != nil
        deleteButton.isHidden = !showsDelete
        labelTrailingToEject.isActive = showsEject
        labelTrailingToDelete.isActive = showsDelete && !showsEject
        labelTrailingToEdge.isActive = !showsEject && !showsDelete
    }

    @objc private func eject() {
        onEject?()
    }

    @objc private func delete() {
        onDelete?()
    }
}

/// A section header ("Favorites", "Volumes") in the sidebar. A source-list group row
/// AppKit already renders with the right vibrancy; this just supplies the label.
final class SidebarHeaderView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarHeaderCell")

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = SidebarHeaderView.identifier

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        addSubview(label)
        textField = label

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String) {
        label.stringValue = title
    }
}
