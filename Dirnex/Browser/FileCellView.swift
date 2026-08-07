import AppKit
import DirnexCore

/// One cell in a file pane.
///
/// The panel distinguishes two independent states the way Total Commander does
/// (PLAN.md §1 "selection is independent of the cursor"):
/// - the **cursor** is the table's own row selection (blue when the pane is active),
/// - a **mark** is drawn as bold, accent-red text.
///
/// When a row is both marked *and* the cursor, the emphasized (blue) background wins
/// for legibility and we keep the bold weight so the mark is still visible.
///
/// The name cell also carries the row's three trailing badges, in the order Finder puts the two it
/// has: the Finder-tag dots, the cloud sync badge, and Git's status letter outermost. The tree
/// geometry lives in `FileCellView+Tree`.
final class FileCellView: NSTableCellView {
    var marked = false
    /// Fades the whole cell — icon and text alike — for a hidden (dot) entry, the way
    /// Finder greys out invisibles once you reveal them. Set per render alongside `marked`.
    var dimmed = false

    /// The colour a file-type rule gives this row (PLAN.md §M15 Slice 3), or `nil` when no rule
    /// claims it — which is every row on an untouched install.
    ///
    /// **Ranks below the mark, deliberately, and that is the one thing about it worth arguing.** A
    /// type colour says what a file already announces through its name and icon, while the mark says
    /// the user picked this one and is about to act on it. Let `*.jpg`'s teal outrank the mark and a
    /// marked photograph becomes indistinguishable from an unmarked one at the exact moment F5 is
    /// aimed at it — silent, and in the expensive direction. So the ranking is: cursor → mark → type
    /// rule → label colour.
    ///
    /// It used to rank below one more thing. Git's status colour sat above the mark, because in the
    /// gutter the letter *was* the information and it had nowhere else to go; now that the letter
    /// rides in `GitBadgeView`, which carries its own colour, no Git state reaches the text at all.
    var typeColor: NSColor?

    /// The Finder-tag dots at the right edge of the name (PLAN.md §M6), or `nil` on the cells that
    /// aren't the name. Where Finder puts them, and their own view rather than styled text, because
    /// the content *is* the colour.
    private(set) var tagDots: TagDotsView?

    /// The cloud sync badge, next out from the dots (PLAN.md §M6), or `nil` on the cells that aren't
    /// the name. Outside the dots because that is where Finder puts it when a file is both tagged and
    /// not downloaded — measured, like the dots' own placement.
    private(set) var syncBadge: SyncBadgeView?

    /// Git's one-letter status, outermost (PLAN.md §M6), or `nil` on the cells that aren't the name.
    /// It was a column of its own until it joined the cluster; `GitBadgeView` argues the move.
    private(set) var gitBadge: GitBadgeView?

    /// The row's tags. The name column truncates before them, so a long name gives way to its dots
    /// rather than running underneath them.
    var tags: [FinderTag] {
        get { tagDots?.tags ?? [] }
        set { tagDots?.tags = newValue }
    }

    /// The row's cloud sync status, `nil` for the ordinary and the fully synced alike — both draw
    /// nothing. Carries its own tooltip: the glyph is small and monochrome, and "not downloaded"
    /// versus "sync failed" is exactly what it cannot say on its own.
    var syncStatus: CloudSyncStatus? {
        get { syncBadge?.status }
        set {
            syncBadge?.status = newValue
            syncBadge?.toolTip = syncBadge?.accessibilityText
        }
    }

    /// The row's Git status, `nil` outside a repository and for every unmodified file in one — both
    /// draw nothing. Carries a tooltip for the same reason the cloud does, and more so: `!` and `U`
    /// are Git's vocabulary, not a reader's.
    var gitStatus: GitFileStatus? {
        get { gitBadge?.status }
        set {
            gitBadge?.status = newValue
            gitBadge?.toolTip = gitBadge?.accessibilityText
        }
    }

    /// How far the sync badge hangs past the name cell's trailing edge, into the table's intercell
    /// gutter — see the constraint below for why it is positive at all. The Git badge shares the
    /// anchor and holds the same distance as empty space (`GitBadgeView.gutterInset`), so whichever
    /// of the two is outermost puts its ink on the same spot.
    static let badgeOverhang: CGFloat = 4

    /// The icon box, sized from `AppPreferences.rowDensity` (PLAN.md §M15). `nil` on the cells that
    /// carry no image, where setting a density is a no-op.
    private var iconWidth: NSLayoutConstraint?
    private var iconHeight: NSLayoutConstraint?

    /// The density this cell is currently laid out for. Re-applied on **every** render rather than
    /// baked in at build time, because cells are recycled: `makeView(withIdentifier:)` hands back a
    /// cell built at whatever density was current when it was made.
    ///
    /// Measured, in a throwaway harness against a real 300-row table: `reloadData` empties
    /// `NSTableView`'s reuse pool outright — every row after one is a fresh build, even at an
    /// unchanged density — so a density change *today* happens to hand out correctly sized cells
    /// with no help from here. That is undocumented behaviour, and it fails in the quiet direction:
    /// a macOS that kept the pool would draw 16 pt icons in a 28 pt row with nothing logged. So the
    /// cell owns the invariant instead of relying on the table to. Re-assigning the same value
    /// costs one comparison.
    var density: RowDensity = .regular {
        didSet {
            guard density != oldValue else { return }
            iconWidth?.constant = density.iconSize
            iconHeight?.constant = density.iconSize
        }
    }

    /// The user's colours (PLAN.md §M15 Slice 2). **Stored** rather than passed into `applyStyle`,
    /// for the same reason `density` is stored: `applyStyle` also runs from `backgroundStyle`'s
    /// `didSet`, which fires when the cursor moves onto or off this row — outside any render pass,
    /// with no caller to hand it anything. Re-set on every render alongside `density`.
    var palette: PanelPalette = .followSystem

    // MARK: - Tree layout (PLAN.md §M15 Slice 4) — the geometry lives in `FileCellView+Tree`

    /// A directory row's disclosure state in tree mode — a folder that can be opened or closed. `nil`
    /// on a file, on `..`, and on every row in list mode, i.e. the rows with no triangle.
    enum TreeDisclosure { case collapsed, expanded }

    /// Whether this cell is drawn inside a tree (any depth). When `false` the name column renders
    /// byte-for-byte as the shipped flat list — the icon flush at its original inset, no triangle,
    /// no reserved slot. When `true` every row reserves the disclosure slot so files line up under
    /// their sibling folders. Only the name cell (the one that carries an icon) reads this.
    var isTreeRow = false
    /// The row's indentation depth (0 = the tree root's own entries). Drives the leading inset so a
    /// child sits under its parent. Always 0 in list mode.
    var treeDepth = 0
    /// Whether this row shows a disclosure triangle, and which way it points — `nil` for a file, a
    /// symlink-to-file, and `..`, which cannot be opened.
    var treeDisclosure: TreeDisclosure?
    /// Invoked when the disclosure triangle is clicked — toggles this row's expansion **without
    /// moving the cursor** (Finder's behaviour), which is why it carries the row's own path rather
    /// than acting on the pane's cursor. Set per render on directory rows; the closure pattern
    /// mirrors `SidebarCellView.onEject`.
    var onDisclosureToggle: (() -> Void)?

    /// The name cell's icon inset in the shipped flat list — the leading constant every list-mode
    /// row keeps, so nothing shifts when the tree is off.
    static let iconInsetList: CGFloat = 3
    /// The tree block's leading inset, measured from the name cell's leading edge. Negative on
    /// purpose: the `.plain` table style leaves an ~8 pt empty margin before the first column, and a
    /// tree row reaches back into it so the disclosure triangle sits nearer the panel's left border
    /// than a flat-list icon does — halving the border-to-`>` gap without disturbing the column
    /// header, the inter-column spacing, or list mode. Only the tree branch reads it.
    static let treeLeadingInset: CGFloat = -3
    /// One level of tree indentation.
    static let treeIndentPerLevel: CGFloat = 16
    /// The width reserved before the icon for the disclosure triangle, in tree mode.
    static let treeDisclosureSlot: CGFloat = 14

    /// The disclosure triangle for a directory row in tree mode; `nil` on the cells that carry no
    /// image (size/date), which never show tree structure. Borderless with a per-cell action
    /// closure, exactly like `SidebarCellView`'s eject button — a control in a table cell receives
    /// its own click, so toggling never disturbs the row selection underneath.
    var disclosureButton: NSButton?
    /// The untinted chevron this row currently shows, kept so `applyDisclosureForeground` can
    /// re-derive a cursor-coloured copy from it without knowing which way the triangle points — and
    /// so successive tints never compound onto the last copy.
    var disclosureBaseImage: NSImage?
    /// The two leading constraints tree layout moves: the icon's own inset and the triangle's. Held
    /// so `applyTreeLayout` can slide them per depth without rebuilding the cell.
    var iconLeading: NSLayoutConstraint?
    var disclosureLeading: NSLayoutConstraint?

    init(showsImage: Bool, identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        let text = NSTextField(labelWithString: "")
        text.translatesAutoresizingMaskIntoConstraints = false
        text.lineBreakMode = .byTruncatingTail
        text.cell?.usesSingleLineMode = true
        addSubview(text)
        textField = text

        guard showsImage else {
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
            return
        }

        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        image.imageScaling = .scaleProportionallyDown
        addSubview(image)
        imageView = image

        // Only the name cell carries a disclosure triangle — the one column that shows tree
        // structure. Hidden until `applyTreeLayout` gives it a state; in list mode it stays hidden
        // and the icon keeps its original inset, so nothing changes. It is a `DisclosureTriangleView`
        // — an NSButton that is *transparent to the mouse* (`hitTest` → nil), so a click on the
        // triangle passes through to the file table and is toggled from `FileTableView.mouseDown` at
        // press time. A real button ran its own tracking loop, where a trackpad's small horizontal
        // drift off the 14 pt glyph released outside it and the action never fired — ~1 click in 5
        // lost. Handling the toggle on mouse-down removes tracking, drift and drag from the path.
        let disclosure = DisclosureTriangleView()
        disclosure.translatesAutoresizingMaskIntoConstraints = false
        disclosure.isBordered = false
        disclosure.bezelStyle = .accessoryBarAction
        disclosure.imagePosition = .imageOnly
        // The tint is not set here: `applyDisclosureForeground` owns it, and on the cursor row it
        // has to bake the colour into the glyph rather than tint the control.
        disclosure.isHidden = true
        addSubview(disclosure)
        disclosureButton = disclosure

        // The three trailing badges live in their own builder — one concept, and the initializer is
        // at SwiftLint's function ceiling. The name yields to them, never the reverse: the text is
        // allowed to compress and truncate (it already does), while they hold their intrinsic width.
        // An untagged, non-cloud row outside a repository — nearly all of them — has a zero-width
        // cluster, and the name gets the full cell.
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let badgeConstraints = installBadges(besides: text)

        // Built at `density`'s own size — the property's initial value — so the stored constraints
        // and the stored density never disagree, and `didSet` has nothing to correct on a cell
        // that is already at the current density.
        let width = image.widthAnchor.constraint(equalToConstant: density.iconSize)
        let height = image.heightAnchor.constraint(equalToConstant: density.iconSize)
        iconWidth = width
        iconHeight = height

        // The icon inset and the triangle's leading are the two constants tree layout slides; both
        // start at the shipped list-mode values (triangle hidden, icon at `iconInsetList`).
        let icon = image.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: Self.iconInsetList
        )
        iconLeading = icon
        let disclosureLead = disclosure.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: Self.iconInsetList
        )
        disclosureLeading = disclosureLead

        NSLayoutConstraint.activate([
            icon,
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            width,
            height,
            disclosureLead,
            // Pin the triangle top-to-bottom rather than centring it: `.imageOnly` keeps the glyph
            // vertically centred, but the *button* now fills the whole row height, so its click
            // target spans the row instead of the ~10 pt chevron — a folder is easy to aim at.
            disclosure.topAnchor.constraint(equalTo: topAnchor),
            disclosure.bottomAnchor.constraint(equalTo: bottomAnchor),
            disclosure.widthAnchor.constraint(equalToConstant: Self.treeDisclosureSlot),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
            text.centerYAnchor.constraint(equalTo: centerYAnchor)
        ] + badgeConstraints)
    }

    /// Build the trailing badge cluster — tag dots, cloud, Git letter — and hand back the
    /// constraints that place it. Called once from the initializer, for the name cell only.
    ///
    /// **Each badge keeps its own measured place against the cell and gives way only when the one
    /// outside it is actually there.** They must not ride on each other's edges unconditionally, or
    /// an outer badge's overhang drags the inner ones out into the gutter with it — which is exactly
    /// the 5 pt the dots once lost to the cloud. So each sits flush at `.defaultHigh` and yields at
    /// `.required`, which also means an *empty* outer badge (zero-width, sitting on its own anchor)
    /// constrains nothing and leaves its neighbour where it was measured.
    private func installBadges(besides text: NSTextField) -> [NSLayoutConstraint] {
        // Innermost first: Finder's order for a file that is both tagged and not downloaded is
        // name, dots, cloud. Git's letter goes outermost, sharing the cloud's trailing anchor and
        // holding the overhang as empty space of its own (`GitBadgeView.gutterInset`).
        let dots = TagDotsView()
        let cloud = SyncBadgeView()
        let git = GitBadgeView(gutterInset: Self.badgeOverhang)
        tagDots = dots
        syncBadge = cloud
        gitBadge = git
        for badge in [dots, cloud, git] as [NSView] {
            badge.translatesAutoresizingMaskIntoConstraints = false
            badge.setContentCompressionResistancePriority(.required, for: .horizontal)
            badge.setContentHuggingPriority(.required, for: .horizontal)
            addSubview(badge)
        }

        let dotsFlush = dots.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1)
        dotsFlush.priority = .defaultHigh
        // Positive — the cluster's outermost badge deliberately hangs past the cell, into the
        // table's own 17pt intercell gutter. Right-aligning the cloud flush like the dots *looks*
        // wrong even though it is the same alignment: a dot is 9pt and the cloud's ink is 16pt, so
        // flush right puts the cloud's centre ~7pt left of where a dot's lands, and the eye reads
        // the centre. Measured against the live table: this puts the cloud's centre on the dot's
        // (x=296) and under the header's sort arrow (x=298), where the dots already sit. The gutter
        // is empty space between cells — nothing else draws there, and the column's padding is
        // untouched. `GitBadgeView` reserves the same distance inside itself, so its 11pt letter
        // slot centres on that spot too.
        let cloudFlush = cloud.trailingAnchor.constraint(
            equalTo: trailingAnchor, constant: Self.badgeOverhang
        )
        cloudFlush.priority = .defaultHigh

        return [
            text.trailingAnchor.constraint(lessThanOrEqualTo: dots.leadingAnchor, constant: -6),
            dotsFlush,
            dots.trailingAnchor.constraint(lessThanOrEqualTo: cloud.leadingAnchor),
            dots.centerYAnchor.constraint(equalTo: centerYAnchor),
            cloudFlush,
            cloud.trailingAnchor.constraint(lessThanOrEqualTo: git.leadingAnchor),
            cloud.centerYAnchor.constraint(equalTo: centerYAnchor),
            git.trailingAnchor.constraint(equalTo: trailingAnchor, constant: Self.badgeOverhang),
            git.centerYAnchor.constraint(equalTo: centerYAnchor)
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyStyle() }
    }

    func applyStyle() {
        guard let textField else { return }
        // Dim the whole item (icon + every column) for a hidden entry. The row's selection
        // highlight is drawn behind the cell by `NSTableRowView`, so a dimmed hidden row still
        // shows a full-strength cursor background — only its content fades, as in Finder.
        alphaValue = dimmed ? 0.5 : 1
        let size = NSFont.systemFontSize
        textField.font = marked ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)

        applyDisclosureForeground()
        // The Git letter is the one badge with a *legibility* stake in the cursor's background: the
        // dots and the cloud are shapes read by colour, while a small character in `.systemOrange`
        // on a colour the user chose can simply disappear. Pushed down for the same reason the
        // chevron's colour is — `backgroundStyle` is this cell's property, not the badge's.
        gitBadge?.isEmphasized = backgroundStyle == .emphasized
        gitBadge?.emphasizedInk = palette.cursorForeground

        if backgroundStyle == .emphasized {
            // Derived from the cursor colour, never picked: a user who could choose both would
            // reach a white-on-pale-yellow row on their first try. Untouched, this *is*
            // `.alternateSelectedControlTextColor` — see `PanelPalette.cursorForeground`.
            textField.textColor = palette.cursorForeground
        } else if marked {
            textField.textColor = palette.resolvedMark
        } else if let typeColor {
            textField.textColor = typeColor
        } else {
            textField.textColor = .labelColor
        }
    }

    /// Only the name cell carries a disclosure triangle (and thus an icon); the size/date cells do
    /// not. `FileTableView` uses this to pick the name cell out of a row's subviews.
    var isNameCell: Bool { disclosureButton != nil }

    /// Clear every trailing badge. The `..` row draws none of them, and its cell is recycled out of
    /// the same pool as the real rows — so without this, scrolling a tagged file's cell back to the
    /// top hands the way *out of* the folder that file's dots.
    func clearBadges() {
        tags = []
        syncStatus = nil
        gitStatus = nil
    }

    // MARK: - Inline rename

    /// Turn the name label into an editable field for an in-place rename (F2). Runs after
    /// `applyStyle`, so it overrides the mark's bold-red styling with a plain editable box
    /// sized to the same text area beside the icon. `delegate` receives the edit lifecycle.
    func beginNameEditing(delegate: NSTextFieldDelegate) {
        guard let textField else { return }
        // Editing a hidden file — show the field at full opacity so the text stays legible;
        // the next render pass reapplies the dim once editing ends.
        alphaValue = 1
        // Give the editor the whole cell: the name field stops short of the badges, so a tagged,
        // not-downloaded or modified file would otherwise be renamed through a box narrower than
        // every other row's. Clearing them (rather than hiding the views) is what actually returns
        // the space — a hidden view still holds its Auto Layout width. Nothing to restore: the next
        // render sets all three again from the model, as it does for every other property on a
        // recycled cell.
        clearBadges()
        textField.isEditable = true
        textField.isSelectable = true
        textField.isBordered = true
        textField.bezelStyle = .squareBezel
        textField.drawsBackground = true
        textField.backgroundColor = .textBackgroundColor
        textField.textColor = .labelColor
        textField.font = .systemFont(ofSize: NSFont.systemFontSize)
        textField.focusRingType = .default
        textField.delegate = delegate
    }

    /// Revert a (possibly reused) cell back to a plain, non-editable label. Idempotent —
    /// only touches a field that had been made editable — so the normal render path can
    /// call it unconditionally.
    func endNameEditing() {
        guard let textField, textField.isEditable else { return }
        textField.isEditable = false
        textField.isSelectable = false
        textField.isBordered = false
        textField.drawsBackground = false
        textField.delegate = nil
    }
}
