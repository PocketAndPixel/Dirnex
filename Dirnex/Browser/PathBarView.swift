import AppKit
import DirnexCore

/// Owner of a `PathBarView` — the file pane. Navigation and focus decisions stay in
/// the pane (PLAN.md §2 "UI is a thin client"); the bar only reports intent.
@MainActor
protocol PathBarViewDelegate: AnyObject {
    /// A crumb was clicked — navigate straight to this already-real path.
    func pathBar(_ bar: PathBarView, didActivate path: VFSPath)
    /// Edited text was committed with Return. `resolved` is the literal location the text
    /// expands to (tilde/relative resolved); `rawText` is exactly what was typed, so the
    /// pane can fall back to a frecency fuzzy match ("dl" → ~/Downloads) when `resolved`
    /// isn't a real directory (PLAN.md §M3 "path bar accepts fuzzy fragments").
    func pathBar(_ bar: PathBarView, didCommit rawText: String, resolved: VFSPath)
    /// Editing was abandoned (Esc) — the pane should take keyboard focus back.
    func pathBarDidCancel(_ bar: PathBarView)
    /// Text editing began — the pane should become the active one.
    func pathBarDidBeginEditing(_ bar: PathBarView)
    /// Directory names contained directly in `directory`, for path completion. Called
    /// on the main actor; the bar caches the result to answer synchronous completion.
    func pathBar(_ bar: PathBarView, childDirectoriesOf directory: VFSPath) async -> [String]
}

/// The pane's location bar. Two modes over the same footprint:
///
/// - **Breadcrumbs** (default): one clickable button per ancestor, so a click jumps
///   straight to `/Users` or `/Users/oleg` without walking up a level at a time.
/// - **Edit** (Cmd+L): a text field prefilled with the path; Return navigates, Esc
///   reverts, and Tab completes against the child directories of what's typed —
///   shell-style, which is more predictable than a popup on every keystroke.
@MainActor
final class PathBarView: NSView, NSTextFieldDelegate {
    weak var delegate: PathBarViewDelegate?

    /// Bold + accent the current (trailing) crumb when this pane is active.
    var isActive = false {
        didSet { restyleCrumbs() }
    }

    private let crumbStack = NSStackView()
    private let editField = NSTextField()
    /// The Git branch of the location on screen, trailing the crumbs. It rides *inside* the crumb
    /// stack (after the greedy spacer) rather than being pinned to the view: an `NSStackView`
    /// collapses a hidden arranged view, whereas a hidden pinned one keeps reserving its width —
    /// which would leave a branch-shaped hole in the path bar of every folder that isn't a repo.
    private let branchChip = GitBranchChipView()

    /// The location each crumb button navigates to, indexed by the button's `tag`. Populated
    /// alongside the buttons so a click resolves to a full `VFSPath` — crucial for an archive
    /// trail, whose crumbs span *different* backends (local ancestors, then `archive:…`) and so
    /// can't be reconstructed from a shared backend the way a same-backend local path could.
    private var crumbTargets: [VFSPath] = []

    private var path: VFSPath?
    private var isEditing = false

    /// The location Cmd+L started from — the base for resolving relative/`~` input.
    private var editBase: VFSPath = .local("/")

    // Completion cache: the directory whose children we last fetched, plus those names.
    private var completionDirectory: VFSPath?
    private var completionChildren: [String] = []
    /// Guards the field editor's `complete(_:)` against re-entrant text-change events.
    private var isCompleting = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 20)
    }

    /// A double-click on the bar's empty area enters text-edit mode — the mouse-driven
    /// equivalent of Cmd+L "Go to Location". Clicks that land on a crumb are consumed by
    /// the button (single-click navigates), so only the gap propagates here; single clicks
    /// still fall through so nothing changes for an ordinary tap.
    override func mouseDown(with event: NSEvent) {
        // A double-click enters text-edit mode, but only where the location has a real directory
        // behind it — a search snapshot isn't a path the user can retype.
        guard !isEditing, event.clickCount == 2, let path, let base = Self.editBase(for: path) else {
            super.mouseDown(with: event)
            return
        }
        beginEditing(base: base)
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .vertical)

        crumbStack.orientation = .horizontal
        crumbStack.alignment = .centerY
        crumbStack.spacing = 1
        // `.fill` (not the default `.gravityAreas`) is what lets the trailing spacer take up the
        // slack: a gravity area packs its views against the leading edge and leaves the leftover as
        // dead space at the far end, which parks the branch chip right next to the crumbs.
        crumbStack.distribution = .fill
        crumbStack.translatesAutoresizingMaskIntoConstraints = false

        editField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        editField.isBordered = true
        editField.bezelStyle = .roundedBezel
        editField.focusRingType = .none
        editField.delegate = self
        editField.isHidden = true
        editField.translatesAutoresizingMaskIntoConstraints = false
        editField.usesSingleLineMode = true
        editField.lineBreakMode = .byTruncatingHead

        addSubview(crumbStack)
        addSubview(editField)
        NSLayoutConstraint.activate([
            crumbStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            // Pinned to *both* edges, not `lessThanOrEqualTo` the trailing one: the row has to span
            // the whole bar for the trailing spacer to have any slack to hand the branch chip. With
            // only a leading pin the stack's width is an underdetermined free variable, and the chip
            // lands wherever that got solved — beside the path as often as at the end of the pane.
            // Safe at required priority because everything in the row resists compression below the
            // 250 the panes' split items hold at, so a full-width row still truncates rather than
            // widening the pane past the user's divider.
            crumbStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            crumbStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            editField.leadingAnchor.constraint(equalTo: leadingAnchor),
            editField.trailingAnchor.constraint(equalTo: trailingAnchor),
            editField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    // MARK: - Breadcrumb mode

    /// Rebuild the crumb row for `path`. A no-op when the path is unchanged, so it's
    /// cheap to call from the pane's per-keystroke chrome refresh — and, crucially, a
    /// background refresh that re-reports the same location never disturbs an open Cmd+L
    /// edit field. A genuine change rebuilds, dropping out of edit mode first if it was
    /// active (the location moved underneath the editor).
    func setPath(_ path: VFSPath, archiveAncestry: [VFSPath] = []) {
        guard self.path != path else { return }
        self.path = path
        if isEditing { endEditing(restoreFocus: false) }
        rebuildContents(for: path, archiveAncestry: archiveAncestry)
    }

    /// Internal, not private: `rebuildContents` drives it from `PathBarView+Location`, and Swift's
    /// `private` does not reach across files.
    func rebuildCrumbs(for path: VFSPath, rootTitle: String = "Macintosh HD") {
        installCrumbs(path.ancestorsFromRoot.map { ancestor in
            Crumb(title: ancestor.isRoot ? rootTitle : ancestor.lastComponent, target: ancestor)
        })
    }

    private func makeCrumb(title: String, tag: Int, isCurrent: Bool) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(crumbClicked(_:)))
        button.isBordered = false
        button.bezelStyle = .inline
        button.setButtonType(.momentaryChange)
        button.controlSize = .small
        button.lineBreakMode = .byTruncatingTail
        button.imagePosition = .noImage
        button.tag = tag
        styleCrumb(button, isCurrent: isCurrent)
        return button
    }

    private func styleCrumb(_ button: NSButton, isCurrent: Bool) {
        if isCurrent {
            button.contentTintColor = isActive ? .controlAccentColor : .labelColor
            button.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        } else {
            button.contentTintColor = .secondaryLabelColor
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
    }

    private func restyleCrumbs() {
        let buttons = crumbStack.arrangedSubviews.compactMap { $0 as? NSButton }
        for (index, button) in buttons.enumerated() {
            styleCrumb(button, isCurrent: index == buttons.count - 1)
        }
    }

    private func makeSeparator() -> NSTextField {
        let label = NSTextField(labelWithString: "›")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .tertiaryLabelColor
        // A divider must never be the thing that collapses when the path overflows — a
        // crumb row without its `›`s reads as one run-on name. Resist compression harder
        // than the leading crumbs (which truncate their tails instead), so every visible
        // crumb stays flanked by its separators — but still below 250 so the separators,
        // like the crumbs, never widen the pane past the user's divider.
        label.setContentCompressionResistancePriority(
            NSLayoutConstraint.Priority(200),
            for: .horizontal
        )
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }

    @objc private func crumbClicked(_ sender: NSButton) {
        guard crumbTargets.indices.contains(sender.tag) else { return }
        delegate?.pathBar(self, didActivate: crumbTargets[sender.tag])
    }

    // MARK: - Edit mode

    /// Enter Cmd+L text-edit mode, prefilled with `base` and fully selected.
    func beginEditing(base: VFSPath) {
        guard !isEditing else { return }
        isEditing = true
        editBase = base
        completionDirectory = nil
        completionChildren = []

        editField.stringValue = base.path
        crumbStack.isHidden = true
        editField.isHidden = false
        delegate?.pathBarDidBeginEditing(self)
        window?.makeFirstResponder(editField)
        editField.currentEditor()?.selectAll(nil)
    }

    private func endEditing(restoreFocus: Bool) {
        guard isEditing else { return }
        isEditing = false
        editField.isHidden = true
        crumbStack.isHidden = false
        if restoreFocus {
            delegate?.pathBarDidCancel(self)
        }
    }

    private func commit() {
        let raw = editField.stringValue
        let target = resolvedPath(from: raw)
        endEditing(restoreFocus: false)
        delegate?.pathBar(self, didCommit: raw, resolved: target)
    }

    /// Resolve typed text into a location: expand a leading `~`, and treat non-absolute
    /// input as relative to the directory Cmd+L was pressed in.
    private func resolvedPath(from text: String) -> VFSPath {
        var full = (text as NSString).expandingTildeInPath
        if full.isEmpty {
            full = editBase.path
        } else if !full.hasPrefix("/") {
            full = editBase.path + "/" + full
        }
        return VFSPath(backend: editBase.backend, path: full)
    }

    // MARK: - Completion

    /// The directory to complete within and the partial name being typed, derived from
    /// the raw text so a trailing slash (list all children) is distinct from a partial.
    private func completionContext(for text: String) -> (directory: VFSPath, partial: String) {
        let full = (text as NSString).expandingTildeInPath
        let absolute = full.hasPrefix("/") ? full : editBase.path + "/" + full
        if let slash = absolute.range(of: "/", options: .backwards) {
            let directory = VFSPath(
                backend: editBase.backend,
                path: String(absolute[..<slash.lowerBound])
            )
            let partial = String(absolute[slash.upperBound...])
            return (directory, partial)
        }
        return (editBase, absolute)
    }

    private func requestCompletion() {
        let (directory, _) = completionContext(for: editField.stringValue)
        if directory == completionDirectory {
            showCompletions()
            return
        }
        completionDirectory = directory
        Task { [weak self] in
            guard let self else { return }
            let names = await delegate?.pathBar(self, childDirectoriesOf: directory) ?? []
            guard isEditing, completionDirectory == directory else { return }
            completionChildren = names
            showCompletions()
        }
    }

    private func showCompletions() {
        guard isEditing, let editor = editField.currentEditor() else { return }
        isCompleting = true
        editor.complete(nil)
        isCompleting = false
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidEndEditing(_ obj: Notification) {
        // Losing first responder (a click on the table or the other pane) abandons the
        // edit and drops back to breadcrumbs — no commit, no focus grab. Return and Esc
        // reach endEditing through their own paths first, so isEditing is already false
        // by the time this fires for them and it's a no-op.
        endEditing(restoreFocus: false)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard isEditing, !isCompleting else { return }
        // Warm the completion cache for the directory being typed so Tab is instant,
        // without popping a list on every keystroke.
        let (directory, _) = completionContext(for: editField.stringValue)
        guard directory != completionDirectory else { return }
        completionDirectory = directory
        Task { [weak self] in
            guard let self else { return }
            let names = await delegate?.pathBar(self, childDirectoriesOf: directory) ?? []
            guard isEditing, completionDirectory == directory else { return }
            completionChildren = names
        }
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        completions words: [String],
        forPartialWordRange charRange: NSRange,
        indexOfSelectedItem index: UnsafeMutablePointer<Int>
    ) -> [String] {
        let partial = (textView.string as NSString).substring(with: charRange).lowercased()
        return completionChildren.filter { partial.isEmpty || $0.lowercased().hasPrefix(partial) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endEditing(restoreFocus: true)
            return true
        case #selector(NSResponder.insertTab(_:)):
            requestCompletion()
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            return true
        default:
            return false
        }
    }
}

// MARK: - Crumb row installation

extension PathBarView {
    /// A single breadcrumb: what to show, and where a click on it navigates. The target is a
    /// full `VFSPath` (backend + path) so a mixed-backend trail — an archive's local ancestors
    /// followed by its `archive:…` inner path — is expressible in one uniform crumb row.
    struct Crumb {
        let title: String
        let target: VFSPath
    }

    /// Build the clickable crumb row from `crumbs`, styling the last as the current location.
    /// Shared by the local path (`rebuildCrumbs`) and the archive trail (`archiveCrumbs`) so both
    /// render identically — same font, `›` separators, accent-on-current, and truncation. In the
    /// extension so the class body stays under SwiftLint's `type_body_length`.
    ///
    /// `leadingSymbol` marks the *kind* of location the trail is rooted in — the cloud glyph for a
    /// provider mount — carrying the sidebar row's own symbol onto the path bar exactly as
    /// `installVirtualLabel` does for the Trash and iCloud Drive. It is tinted like the leading
    /// crumbs it sits beside rather than like the current one, so it reads as part of the root
    /// rather than competing with the directory the pane is actually in.
    func installCrumbs(_ crumbs: [Crumb], leadingSymbol: String? = nil) {
        clearCrumbStack()
        crumbTargets = crumbs.map(\.target)
        if let leadingSymbol {
            let glyph = makeLocationGlyph(
                named: leadingSymbol,
                describedAs: crumbs.first?.title ?? "",
                tint: .secondaryLabelColor
            )
            crumbStack.addArrangedSubview(glyph)
            // `crumbStack` is spaced at 1 pt for the `›` separators, which would leave the glyph
            // touching the first crumb — the same reason the virtual label nests its own row.
            crumbStack.setCustomSpacing(5, after: glyph)
        }
        for (index, crumb) in crumbs.enumerated() {
            if index > 0 {
                crumbStack.addArrangedSubview(makeSeparator())
            }
            let isLast = index == crumbs.count - 1
            let button = makeCrumb(title: crumb.title, tag: index, isCurrent: isLast)
            // Right-click a crumb to copy the location it points at. The menu carries the crumb's
            // own path, so a mixed-backend trail (archive ancestors, then `archive:…`) copies the
            // right one per crumb.
            button.menu = crumbMenu(for: crumb.target)
            // The path bar must never widen the pane — only the user's divider sets pane
            // width (the panes' split items hold at priority 250). So every crumb resists
            // compression *below* 250: a long path truncates within the pane instead of
            // pushing the divider out. Leading crumbs yield first (lowest, graduated so the
            // leftmost/oldest goes first); the current directory (trailing) yields last so
            // it stays legible longest, but it still yields rather than force the pane wider.
            let resistance = isLast
                ? NSLayoutConstraint.Priority(240)
                : NSLayoutConstraint.Priority(Float(100 + min(index, 90)))
            button.setContentCompressionResistancePriority(resistance, for: .horizontal)
            crumbStack.addArrangedSubview(button)
        }
        appendTrailingAccessories()
    }

    /// Shared shell for a single non-clickable path-bar label (search results, Recents, the Trash):
    /// swap the crumb row for one SF Symbol plus a bold, truncating label, then the trailing
    /// accessories. Lives here beside `installCrumbs` — the other way to fill the row — because both
    /// reach into the private `crumbStack`, which `PathBarView+Location` cannot see from its own file.
    ///
    /// The glyph is the **same symbol the sidebar row that opens this location uses**, so the place
    /// you clicked and the place you landed carry one mark. It rides in a nested stack rather than
    /// going straight into `crumbStack`: that one is spaced at 1 pt for the `›` separators, which
    /// would leave the icon touching its text.
    func installVirtualLabel(_ text: String, symbolNamed symbolName: String) {
        clearCrumbStack()
        let color: NSColor = isActive ? .labelColor : .secondaryLabelColor

        let glyph = makeLocationGlyph(named: symbolName, describedAs: text, tint: color)

        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        // Like the crumb row, the label truncates within the pane rather than widening it
        // past the user's divider — resist below the split items' 250 holding priority.
        label.setContentCompressionResistancePriority(
            NSLayoutConstraint.Priority(240),
            for: .horizontal
        )

        let row = NSStackView(views: [glyph, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 5
        crumbStack.addArrangedSubview(row)
        appendTrailingAccessories()
    }

    func clearCrumbStack() {
        for view in crumbStack.arrangedSubviews {
            crumbStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        crumbTargets = []
    }

    /// Close the row: a greedy spacer that keeps the crumbs packed to the left, then the branch
    /// chip at the far end. Both go in on every rebuild — `clearCrumbStack` empties the stack, and
    /// the chip is a retained property being re-arranged, not a new one.
    func appendTrailingAccessories() {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        // The one view in the row that wants to be stretched, and the one that yields first when
        // the crumbs need the room back — lower on both counts than anything else here, so the
        // full-width row's slack collects between the crumbs and the chip and nowhere else.
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(
            NSLayoutConstraint.Priority(1),
            for: .horizontal
        )
        crumbStack.addArrangedSubview(spacer)
        crumbStack.addArrangedSubview(branchChip)
    }

    /// Show `branch` at the trailing end of the bar, or nothing when the location isn't in a
    /// repository. Driven by the pane's chrome refresh, so it must stay a cheap no-op when
    /// unchanged — which it is, in the chip.
    func setBranch(_ branch: GitBranch?) {
        branchChip.branch = branch
    }

    /// A right-click menu for a single crumb: copy the location it points at as text. Built per
    /// crumb so the path travels with the button — a background refresh that rebuilds the row can't
    /// leave the menu aimed at a stale location.
    private func crumbMenu(for target: VFSPath) -> NSMenu {
        let menu = NSMenu()
        let title = String(
            localized: "Copy Path",
            comment: "Path-bar crumb menu: copy the path as text."
        )
        let item = NSMenuItem(title: title, action: #selector(copyCrumbPath(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = target.path
        menu.addItem(item)
        return menu
    }

    @objc private func copyCrumbPath(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        PathClipboard.copy([path])
    }
}
