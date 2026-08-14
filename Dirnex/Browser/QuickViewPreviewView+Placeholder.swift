import AppKit

/// The card a preview surface draws in place of a remote file whose bytes are not here
/// (PLAN.md §M21 Slice 10).
///
/// Quick View follows the cursor, and a remote fetch costs a billed request and somebody's
/// bandwidth — so the fetch is bounded rather than automatic-at-any-size, and this card is what the
/// bound looks like. A blank surface would be the natural thing to leave, and it is the wrong one:
/// blank reads as "this file is empty" or as the preview being broken, where the truth is a decision
/// Dirnex made on the user's behalf. So the card names the file, says how large it is, says which of
/// the three things is going on, and — where nothing is — carries the button that asks.
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
        card.onDownload = placeholderDownloadAction
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

/// The card itself: a glyph, the file's name, its size, what is happening, and the way to ask.
///
/// Centered rather than filling, and deliberately quiet — it is a statement about why there is
/// nothing here, not a thing to read.
@MainActor
final class QuickViewPlaceholderCard: NSView {
    /// What the Download button does, handed over by the surface on every show. `nil` hides the
    /// button outright: a control that does nothing is worse than no control, and a card drawn by a
    /// surface with nobody to ask on its behalf is exactly that.
    var onDownload: (() -> Void)?

    private let glyph = NSImageView()
    private let spinner = NSProgressIndicator()
    private let nameLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    /// Internal, not private: `QuickViewPreviewView.hitTest` has to exempt this one control from the
    /// surface's blanket "swallow the mouse", and Swift's `private` does not cross files.
    let downloadButton = NSButton()

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
        apply(placeholder.state, hasSize: placeholder.size != nil)
    }

    /// Put the card into `state`. Three things move: the glyph (or the spinner in its place), the
    /// sentence, and whether the button is offered.
    ///
    /// `hasSize` splits the waiting sentence in two, and both halves are true statements about
    /// *this* file rather than one hedge covering both: over the threshold is a fact about the size,
    /// and an unreported size is a fact about the server. `RemoteFetchPolicy` refuses each for its
    /// own reason, so the card says which.
    private func apply(_ state: RemotePreviewPlaceholder.State, hasSize: Bool) {
        let isDownloading = state == .downloading
        glyph.isHidden = isDownloading
        spinner.isHidden = !isDownloading
        if isDownloading {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
        glyph.image = Self.symbol(
            state == .failed ? "exclamationmark.triangle" : "arrow.down.circle"
        )
        hintLabel.stringValue = Self.hint(for: state, hasSize: hasSize)
        // An `NSProgressIndicator` that is merely *not drawn* still eats every click that lands on
        // it (docs/NOTES.md ▸ AppKit), which is exactly the trap this card would fall into: the
        // spinner sits directly above the button in the same stack. `isHidden` is the property that
        // takes a view out of hit-testing, and it is what both of these use.
        downloadButton.isHidden = isDownloading || onDownload == nil
    }

    private static func hint(
        for state: RemotePreviewPlaceholder.State,
        hasSize: Bool
    ) -> String {
        switch state {
        case .downloading:
            String(
                localized: "Downloading from the server…",
                comment: "Quick View placeholder hint while a remote file is being fetched."
            )
        case .failed:
            String(
                localized: "Dirnex couldn’t download this file.",
                comment: "Quick View placeholder hint after an automatic remote fetch failed."
            )
        case .awaitingRequest where hasSize:
            String(
                localized: "Files this large aren’t downloaded automatically.",
                comment: """
                Quick View placeholder hint for a remote file over the size Dirnex fetches on its \
                own as the cursor moves.
                """
            )
        case .awaitingRequest:
            String(
                localized: """
                Dirnex doesn’t download a file automatically without knowing how large it is.
                """,
                comment: """
                Quick View placeholder hint for a remote file whose size the server never reported.
                """
            )
        }
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 40, weight: .regular))
    }

    @objc private func download(_ sender: Any?) {
        onDownload?()
    }

    private func buildSubviews() {
        glyph.contentTintColor = .tertiaryLabelColor
        // An `NSImageView` defends its image's size at priority 750, which in a stack is enough to
        // push a container outward (docs/NOTES.md ▸ AppKit). It is a passenger here, not the thing
        // being sized.
        glyph.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        glyph.setContentHuggingPriority(.defaultLow, for: .horizontal)

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isIndeterminate = true
        spinner.isHidden = true

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

        downloadButton.bezelStyle = .rounded
        // The same key *and the same comment* as the confirmation sheet's button, deliberately:
        // `String(localized:comment:)` takes a `StaticString`, so a shared comment has to be
        // repeated verbatim, and two sites keying one string with different comments hand the
        // translator whichever one `xcstringstool` kept (docs/NOTES.md ▸ Localization).
        downloadButton.title = String(
            localized: "Download",
            comment: "Button that starts downloading a remote file."
        )
        downloadButton.target = self
        downloadButton.action = #selector(download)
        // The surface refuses first responder so the arrows keep driving the file list; a button
        // inside it that took focus under full keyboard access would undo that on one click.
        downloadButton.refusesFirstResponder = true

        layOut()
    }

    private func layOut() {
        let indicator = NSView()
        indicator.translatesAutoresizingMaskIntoConstraints = false
        for view in [glyph, spinner] {
            view.translatesAutoresizingMaskIntoConstraints = false
            indicator.addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: indicator.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: indicator.centerYAnchor)
            ])
        }
        // A fixed slot for whichever of the two is showing, so the name below does not jump by a
        // dozen points the moment a download starts — the card is on screen *because* nothing is
        // moving, and a layout that twitches reads as the preview flickering.
        NSLayoutConstraint.activate([
            indicator.heightAnchor.constraint(equalToConstant: 44),
            indicator.widthAnchor.constraint(equalToConstant: 44)
        ])

        let stack = NSStackView(views: [indicator, nameLabel, sizeLabel, hintLabel, downloadButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(12, after: indicator)
        stack.setCustomSpacing(14, after: sizeLabel)
        stack.setCustomSpacing(14, after: hintLabel)
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
