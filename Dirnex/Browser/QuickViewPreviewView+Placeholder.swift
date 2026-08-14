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
        // Raised to the front *after* the stand-down, and this is what makes the card's buttons
        // clickable at all. Every backend is pinned into the same container, so the last one added
        // is on top — and `showQuickLook(nil)` leaves the `QLPreviewView` **visible** with no item,
        // which on a surface that has shown nothing else is built right here, one line above, i.e.
        // *after* the card. It renders out of process, so it is transparent and the card is drawn
        // perfectly; it also answers `hitTest` and then declines the event (docs/NOTES.md ▸ AppKit),
        // so the surface's blanket swallow took every press and Download was dead for the session.
        // That is exactly how the mode is reached — ⌃Q with the cursor already on a remote file —
        // and previewing any local file first hid it, since the card was then added on top.
        // Reported by a user 2026-08-14.
        //
        // A reorder, not a re-add: AppKit moves a view already in this superview rather than
        // removing it, so the pinning constraints and the frame survive (probed).
        content.addSubview(card, positioned: .above, relativeTo: nil)
        card.isHidden = false
        card.onDownload = placeholderActions?.download
        card.onStop = placeholderActions?.stop
        card.progressSource = placeholderActions?.progress
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
    /// What Stop does, on the same terms.
    var onStop: (() -> Void)?
    /// How many bytes have arrived, asked once every ``pollInterval`` while a download is running.
    ///
    /// A pull rather than a push, which is what keeps a chunk-by-chunk report from becoming a
    /// repaint of the whole preview — the shape `RemoteFetchPrompt.followProgress` already uses,
    /// and for the same reason.
    var progressSource: (() -> Int64?)?

    private let glyph = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    /// Internal, not private: `QuickViewPreviewView.hitTest` has to exempt these two controls from
    /// the surface's blanket "swallow the mouse", and Swift's `private` does not cross files.
    let downloadButton = NSButton()
    let stopButton = NSButton()

    /// The file's total, so the bar and its readout have something to divide by. `nil` for a server
    /// that reported no size, which is what makes the bar indeterminate.
    private var expectedBytes: Int64?
    /// Bumped by every `show`, so a poll armed for the previous row stands down rather than writing
    /// that row's byte count into the card now on screen. A counter rather than a `Timer`, for the
    /// same reason `headerFadeGeneration` is one: the timer's block would have to be `@Sendable`.
    private var pollGeneration = 0
    /// Often enough to look live, rare enough that a slow transfer costs a handful of reads a second.
    private static let pollInterval: Duration = .milliseconds(100)

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
        expectedBytes = placeholder.byteSize
        apply(placeholder.state)
    }

    /// Put the card into `state`: the glyph or the progress bar, the sentence, and which of the two
    /// buttons is offered.
    ///
    /// The *why* of a waiting card is decided by the pane and carried in the state, not worked out
    /// here from the size: only the pane knows the user's limit, and at a limit of zero every
    /// size-based sentence is false.
    private func apply(_ state: RemotePreviewPlaceholder.State) {
        let isDownloading = state == .downloading
        bar.isHidden = !isDownloading
        glyph.image = Self.symbol(
            state == .failed ? "exclamationmark.triangle" : "arrow.down.circle"
        )
        hintLabel.stringValue = Self.hint(for: state)
        // An `NSProgressIndicator` that is merely *not drawn* still eats every click that lands on
        // it (docs/NOTES.md ▸ AppKit), which is exactly the trap this card would fall into: the bar
        // sits in the same stack as the buttons. `isHidden` is the property that takes a view out of
        // hit-testing, and it is what all of these use.
        downloadButton.isHidden = isDownloading || onDownload == nil
        stopButton.isHidden = !isDownloading || onStop == nil
        // Always bumped, so a poll left over from the previous row stops whatever this state is.
        pollGeneration += 1
        guard isDownloading else {
            bar.stopAnimation(nil)
            return
        }
        startPolling(generation: pollGeneration)
    }

    /// Follow the byte counter until the download stops being the card's state.
    ///
    /// A determinate bar whenever the listing gave a size, which is the ordinary case — the fraction
    /// is then a fact, the same argument that makes `RemoteFetchPrompt`'s sheet determinate. The
    /// readout underneath is what a slow connection actually needs: a bar creeping across says
    /// "something is happening", and "42,1 MB of 260 MB" says whether it will be worth waiting for.
    private func startPolling(generation: Int) {
        bar.isIndeterminate = expectedBytes == nil
        bar.minValue = 0
        bar.maxValue = Double(max(expectedBytes ?? 1, 1))
        bar.doubleValue = 0
        if bar.isIndeterminate { bar.startAnimation(nil) }
        Task { [weak self] in
            while true {
                guard let self, pollGeneration == generation else { return }
                let moved = progressSource?()
                // `moved > 0`, not merely non-`nil`: `ByteCountFormatter` renders zero as
                // **"Zero KB"**, so a readout drawn before the first chunk says "Zero KB of 21
                // bytes" — two different units and a word where a number belongs. Until something
                // has actually arrived, "Downloading…" is both prettier and more accurate.
                if let moved, moved > 0, let total = expectedBytes {
                    bar.doubleValue = Double(moved)
                    hintLabel.stringValue = Self.downloadedHint(moved, of: total)
                }
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    private static func hint(for state: RemotePreviewPlaceholder.State) -> String {
        switch state {
        case let .awaitingRequest(reason):
            hint(for: reason)
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
        case .stopped:
            String(
                localized: "Download stopped.",
                comment: """
                Quick View placeholder hint after the user pressed Stop on a remote download.
                """
            )
        }
    }

    /// The three reasons nothing is being fetched, as three sentences. Each names the thing that
    /// actually decided — the size, the server, or the setting — because a hedge that covered all
    /// three would send the user looking in the wrong place.
    private static func hint(for reason: RemotePreviewPlaceholder.WaitReason) -> String {
        switch reason {
        case .tooLarge:
            String(
                localized: "Files this large aren’t downloaded automatically.",
                comment: """
                Quick View placeholder hint for a remote file over the size Dirnex fetches on its \
                own as the cursor moves.
                """
            )
        case .sizeUnknown:
            String(
                localized: """
                Dirnex doesn’t download a file automatically without knowing how large it is.
                """,
                comment: """
                Quick View placeholder hint for a remote file whose size the server never reported.
                """
            )
        case .automaticDownloadsOff:
            String(
                localized: "Automatic preview downloads are turned off in Settings.",
                comment: """
                Quick View placeholder hint when the Settings ▸ Panels download size is set to zero.
                """
            )
        }
    }

    /// The live readout under the bar. Both halves formatted the same way the file list formats a
    /// size, so "42,1 MB of 260 MB" reads against the number the row itself is showing.
    ///
    /// The same key the queue bar's own readout uses, deliberately — one English sentence meaning one
    /// thing, already translated — and therefore the same `comment` **verbatim**, since it takes a
    /// `StaticString` and two comments on one key hand the translator whichever `xcstringstool` kept.
    private static func downloadedHint(_ moved: Int64, of total: Int64) -> String {
        String(
            localized: """
            \(FileFormatting.byteString(moved)) of \(FileFormatting.byteString(total))
            """,
            comment: "Byte readout: %1$@ transferred of %2$@ total, both already formatted."
        )
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 40, weight: .regular))
    }

    @objc private func download(_ sender: Any?) {
        onDownload?()
    }

    @objc private func stop(_ sender: Any?) {
        onStop?()
    }

    private func buildSubviews() {
        glyph.contentTintColor = .tertiaryLabelColor
        // An `NSImageView` defends its image's size at priority 750, which in a stack is enough to
        // push a container outward (docs/NOTES.md ▸ AppKit). It is a passenger here, not the thing
        // being sized.
        glyph.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        glyph.setContentHuggingPriority(.defaultLow, for: .horizontal)

        bar.style = .bar
        bar.isIndeterminate = false
        bar.isHidden = true

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

        stopButton.bezelStyle = .rounded
        stopButton.title = String(
            localized: "Stop",
            comment: "Button that cancels the download."
        )
        stopButton.target = self
        stopButton.action = #selector(stop)
        stopButton.isHidden = true

        // The surface refuses first responder so the arrows keep driving the file list; a button
        // inside it that took focus under full keyboard access would undo that on one click.
        for button in [downloadButton, stopButton] { button.refusesFirstResponder = true }

        layOut()
    }

    private func layOut() {
        // A fixed square slot for the glyph, so nothing below it shifts as the card changes state —
        // the card is on screen *because* nothing is moving, and a layout that twitches reads as the
        // preview flickering. The glyph stays through the download rather than being swapped out:
        // "this file is coming down" is still what the arrow means.
        let indicator = NSView()
        indicator.translatesAutoresizingMaskIntoConstraints = false
        glyph.translatesAutoresizingMaskIntoConstraints = false
        indicator.addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: indicator.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: indicator.centerYAnchor),
            indicator.heightAnchor.constraint(equalToConstant: 44),
            indicator.widthAnchor.constraint(equalToConstant: 44)
        ])

        let stack = NSStackView(views: [
            indicator, nameLabel, sizeLabel, bar, hintLabel, downloadButton, stopButton
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(12, after: indicator)
        stack.setCustomSpacing(12, after: sizeLabel)
        stack.setCustomSpacing(14, after: hintLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // The bar spans the card's column rather than taking its own intrinsic width. It is an
        // arranged subview, so hiding it takes its row *and its spacing* out of the layout — which
        // is what lets the idle card look exactly as it did before progress existed.
        bar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
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
