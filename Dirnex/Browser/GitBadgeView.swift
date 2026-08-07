import AppKit
import DirnexCore

/// Git's one-letter status at the right edge of a file's name (PLAN.md §M6 "Git awareness: status
/// column (M/A/?/ignored)"). Lives inside `FileCellView`, outside the tag dots and the cloud badge —
/// the order a row shows them in is dots, cloud, Git.
///
/// **This was a column of its own until it wasn't**, and the move is the same one the tags and the
/// cloud badge each made before it. A contextual column costs the Name column its own width *plus*
/// an intercell spacing — 20 + 17 = 37 pt, measured — to draw one letter about 20 pt to the right of
/// where the name cell's trailing edge already is. The only thing that width bought was the letters
/// lining up in a vertical run, and a badge right-aligned inside a fixed-width Name column lines them
/// up just as well. So the gutter is gone and Name keeps the 37 pt.
///
/// Text rather than a symbol, unlike `SyncBadgeView`: the letters are Git's own vocabulary
/// (`GitFileStatus.code`), and the colour alone cannot carry the state — added and untracked are both
/// green, deleted and conflicted both red. A dot would say "something is up with this file" where the
/// letter says which thing.
final class GitBadgeView: NSView {
    /// The row's status, or `nil` for a row with nothing to report — every file outside a repository
    /// and every unmodified file inside one, which is the overwhelming majority. Setting it resizes
    /// and redraws.
    var status: GitFileStatus? {
        didSet {
            guard status != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    /// Whether this row is the cursor, so the letter can be drawn in a colour that survives the
    /// emphasized background behind it. Pushed down by `FileCellView` — `backgroundStyle` is
    /// `NSTableCellView`'s property, not `NSView`'s, so this view cannot observe it directly. Same
    /// wiring as `SizeBarView`.
    var isEmphasized = false {
        didSet {
            guard isEmphasized != oldValue else { return }
            needsDisplay = true
        }
    }

    /// What the letter is drawn in on the cursor row. Derived from the cursor colour rather than
    /// chosen (`PanelPalette.cursorForeground`), for the reason `FileCellView.applyStyle` gives: a
    /// status colour picked for a white background is not legible on a colour the user chose. This is
    /// what the gutter did too — its cell was an ordinary `FileCellView`, and the emphasized branch
    /// of `applyStyle` already outranked the status colour there — so the cursor row has always
    /// traded the colour for legibility and keeps the letter, which carries the state anyway.
    var emphasizedInk: NSColor = .alternateSelectedControlTextColor {
        didSet {
            guard emphasizedInk != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Empty space held at the trailing edge, so this badge can share the cloud's trailing anchor —
    /// which deliberately hangs `FileCellView.badgeOverhang` into the table's intercell gutter — while
    /// its own ink stops short of it. The cloud wants the overhang because its 19 pt symbol has to
    /// centre where a 9 pt dot does; a letter in an 11 pt slot centres there with none. Reserving it
    /// here rather than giving this badge a trailing anchor of its own is what keeps the cloud's
    /// measured position untouched on the rows that have no Git status: an empty badge is zero-width,
    /// so it lands exactly on the cloud's own edge and constrains nothing.
    private let gutterInset: CGFloat

    /// The slot the letter is centred in. Sized to the widest code Git has — measured at this font,
    /// `M` is 10.74 pt and every other letter is narrower — so the run of letters down a repository's
    /// rows is a column rather than a ragged edge, whatever mix of states it holds.
    private static let slotWidth: CGFloat = 11
    /// Breathing room between whatever is inside and the letter. The cloud's own is 3, and 3 here
    /// looked tighter beside a tag dot — because an SF Symbol carries ~1.25–1.5 pt of transparent
    /// margin inside its box (docs/NOTES.md) and a glyph drawn as *text* carries none, so the same
    /// number buys less gap. 5 puts the ink the same distance apart. It only ever moves the badges
    /// *inside* this one: the letter's own position is measured from the trailing edge.
    private static let leadingGap: CGFloat = 5
    private static let glyphHeight: CGFloat = 15

    /// A step down from the name's 13 pt and half a weight up: at a glance it reads as a badge beside
    /// the 9 pt dots rather than as a second word in the filename, and semibold is what keeps one
    /// small character legible at that size.
    private static let font = NSFont.systemFont(ofSize: 12, weight: .semibold)

    init(gutterInset: CGFloat = 0) {
        self.gutterInset = gutterInset
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The width the letter needs, so Auto Layout gives the name exactly the room it doesn't — and
    /// **all** of it when there is nothing to say, which is every row outside a repository. This is
    /// what keeps the badge from costing anything at all in a folder Git has never heard of.
    override var intrinsicContentSize: NSSize {
        guard status?.code != nil else { return NSSize(width: 0, height: Self.glyphHeight) }
        return NSSize(
            width: Self.leadingGap + Self.slotWidth + gutterInset,
            height: Self.glyphHeight
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let status, let code = status.code else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: isEmphasized ? emphasizedInk : GitStatusStyle.color(for: status)
        ]
        let text = code as NSString
        let size = text.size(withAttributes: attributes)
        // Centred in the slot, not right-aligned in it: the letters differ in width by 7 pt between
        // `!` and `M`, so aligning their edges would leave the column visibly ragged.
        let slotMidX = bounds.maxX - gutterInset - Self.slotWidth / 2
        text.draw(
            at: NSPoint(
                x: (slotMidX - size.width / 2).rounded(),
                y: ((bounds.height - size.height) / 2).rounded()
            ),
            withAttributes: attributes
        )
    }

    /// What this badge is saying, in words — the cell hands it to the row's tooltip. One letter is
    /// exactly as much as the gutter ever showed, and `!` or `U` means nothing to someone who has not
    /// memorised `git status`'s short format; the gutter could only name itself in its header.
    var accessibilityText: String? {
        status.map(GitStatusStyle.label(for:))
    }
}

/// How a status is painted and named. The letters are Git's own (`GitFileStatus.code` in the core);
/// the colours and the words are the app's — the same core-decides-meaning / app-decides-look split
/// as `SyncBadgeStyle` and `TagDotStyle`. The colours follow the convention every Git client has
/// converged on: green for what is new, orange for what changed, red for what is gone or broken, grey
/// for what Git is deliberately not looking at.
enum GitStatusStyle {
    static func color(for status: GitFileStatus) -> NSColor {
        switch status {
        case .unmodified: .labelColor
        case .modified: .systemOrange
        case .added, .untracked: .systemGreen
        case .deleted: .systemRed
        case .renamed: .systemBlue
        // Ignored is the one status that means "pay no attention" — it must recede, not announce.
        case .ignored: .tertiaryLabelColor
        // A conflict is the only status that is *blocking* something; it gets the loudest colour
        // the palette has.
        case .conflicted: .systemRed
        }
    }

    /// The tooltip text: Git's own vocabulary, one word where Git has one.
    ///
    /// Each literal sits *at* its `String(localized:)` call rather than being switched into one, so
    /// the extractor sees it — a `String(localized: someLabel)` over a variable extracts nothing
    /// (docs/NOTES.md).
    ///
    /// `.unmodified` never reaches here — it draws nothing, and `gitStatus(for:)` collapses it to
    /// `nil` — but it is answered for completeness rather than crashed on.
    static func label(for status: GitFileStatus) -> String {
        switch status {
        case .unmodified:
            String(
                localized: "Unmodified",
                comment: "Git status badge tooltip: tracked, and identical to the last commit."
            )
        case .modified:
            String(
                localized: "Modified",
                comment: "Git status badge tooltip: the file's contents have changed."
            )
        case .added:
            String(
                localized: "Added",
                comment: "Git status badge tooltip: a new file staged for the next commit."
            )
        case .deleted:
            String(
                localized: "Deleted",
                comment: "Git status badge tooltip: a tracked file that is gone."
            )
        case .renamed:
            String(
                localized: "Renamed",
                comment: "Git status badge tooltip: the file was moved or copied from another path."
            )
        case .untracked:
            String(
                localized: "Untracked",
                comment: "Git status badge tooltip: Git knows nothing about this file."
            )
        case .ignored:
            String(
                localized: "Ignored",
                comment: "Git status badge tooltip: excluded by a .gitignore rule."
            )
        case .conflicted:
            String(
                localized: "Merge conflict",
                comment: "Git status badge tooltip: an unresolved merge — the one state that blocks."
            )
        }
    }
}
