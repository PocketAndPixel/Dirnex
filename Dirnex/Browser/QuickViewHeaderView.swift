import AppKit
import DirnexCore

/// What a Quick View says about the file it is showing (PLAN.md §M11): the name, and where it sits
/// in the pane's list. In the two full modes the list is behind the preview, and arrowing through
/// files you cannot see is flying blind — this is the readout that replaces the row you would
/// otherwise be looking at. Pane mode took the same header on 2026-10-14, for the style it names:
/// there the list is beside the preview, but nothing else says that `1` / `2` would do anything.
struct QuickViewCaption: Equatable {
    let name: String
    /// The cursor's 1-based position among the pane's visible *entries*, and how many there are.
    /// `..` is not counted: it is not a file the preview flips through, so counting it would
    /// promise one more than ← / → can reach.
    let position: Int
    let count: Int
    /// The render style this file is being shown in, or `nil` when it has only one honest
    /// rendering — which is most files. Set by the window controller, since the style is app-wide
    /// and the pane that builds the caption does not know it (PLAN.md §M16).
    var style: QuickViewRenderStyle?
    /// Which family that style belongs to, which is what names the rendered one — "Page" or "Table".
    /// Only meaningful alongside `style`.
    var styleKind = QuickViewDualStyleKind.page
    /// Whether the page on screen was rendered with scripts refused — the shipped default, and the
    /// one thing about a rendered page that is invisible in the page itself: a report that needs
    /// its scripts simply shows less, with nothing to say why. Only meaningful alongside `style`,
    /// and only in `.rendered`, where scripts would otherwise have run.
    var javaScriptDisabled = false
    /// Whether a slideshow is stepping through the pane (PLAN.md §M39 ▸ Slice 16), which the header
    /// says beside the position so a picture that changes on its own does not look like a fault. Set
    /// by the window, which runs the show.
    var isSlideshowRunning = false
    /// Where the player is in a movie or a sound, and what the file holds (PLAN.md §M42 ▸ Slice 2), or
    /// `nil` for every other file. Set by the surface, which owns the player.
    var media: QuickViewMediaReadout?

    /// "3 of 42" — the position half of the header, rendered beside the name.
    var positionText: String {
        String(
            localized: "\(position) of \(count)",
            comment: "Quick View header position readout: %1$lld is the cursor's place, %2$lld the count."
        )
    }
}

/// What the header says about a movie or a sound (PLAN.md §M42 ▸ Slice 2). AVKit's own controls fade
/// while the pointer is away from the player, so in a session at the keyboard this is the only thing on
/// screen that says whether the file is playing and where it has got to.
struct QuickViewMediaReadout: Equatable {
    let isPlaying: Bool
    /// "0:42 / 1:35:20" (`MediaTimecode.readout`).
    let time: String
    /// "2560×1440 · H.264 · AAC" (`MediaSummary.facts`), empty while nothing is known.
    let facts: String
}

/// The name-and-position strip a Quick View draws across its top, with the × that closes the preview
/// after the name. A vibrant bar rather than a flat one because it sits over arbitrary content — a
/// white page in full window, a photo bled to the edges in full screen — where any fixed color is
/// wrong against half of it.
@MainActor
final class QuickViewHeaderView: NSVisualEffectView {
    static let height: CGFloat = 30

    private let nameLabel = NSTextField(labelWithString: "")
    private let positionLabel = NSTextField(labelWithString: "")
    /// "▶ Slideshow" just before the position while a show runs, nothing otherwise; a click stops the
    /// show, as ⇧⌘S does (PLAN.md §M39 ▸ Slice 16). Internal, for the tests.
    let slideshowButton = NSButton()
    /// What a click on `slideshowButton` does. Set by whoever owns the surface, like `onClose`.
    var onStopSlideshow: (() -> Void)?
    /// Keeps the close button clear of `slideshowButton`, and is active only while the mark is shown:
    /// a hidden view still takes part in layout, and would cut a long name short for nothing.
    private var closeClearsSlideshow: NSLayoutConstraint?
    /// "▶ 0:42 / 1:35:20" at the leading edge, where a page's styles go, over a movie or a sound; a
    /// click plays or pauses as ⌘P does. Internal, for the tests.
    let playbackButton = NSButton()
    /// "2560×1440 · H.264 · AAC" before the position over a movie or a sound. Internal, for the tests.
    let factsLabel = NSTextField(labelWithString: "")
    /// What a click on `playbackButton` does. Set by the surface, which owns the player.
    var onTogglePlayback: (() -> Void)?
    /// The constraints that keep the name and the close button clear of the two, active only while
    /// each is shown, for the reason `closeClearsSlideshow` is.
    var mediaConstraints = QuickViewHeaderMediaConstraints()
    /// "1 Source · 2 Page" for a file that offers both, nothing for every other file. The only place
    /// the two keys announce themselves, so it names *both* and dims the one you are not in rather
    /// than naming only the alternative — which reads as a label for what you are looking at.
    /// Each style is a button since 2026-10-20, so a hand on the trackpad picks one as its digit does.
    private let styleStrip = NSStackView()
    /// One per style, in `QuickViewRenderStyle.allCases` order. Internal, for the tests.
    let styleButtons = QuickViewRenderStyle.allCases.map { style in
        QuickViewHeaderView.makeStyleButton(for: style)
    }

    /// The "(no JavaScript)" after the two styles; see `noJavaScriptMark`.
    private let noJavaScriptLabel = NSTextField(
        labelWithString: "  \(QuickViewHeaderView.noJavaScriptMark)"
    )
    /// What a click on a style does. Set by whoever owns the surface, like `onClose`, since the
    /// preference it writes belongs to the window rather than to the strip.
    var onPickStyle: ((QuickViewRenderStyle) -> Void)?
    /// Closes Quick View, for a hand on the trackpad: every other way out is a key (Esc, or the
    /// mode's own ⌃Q / ⌃⇧Q / ⌃⌥Q). It sits right after the name, and stays when the cursor lands on
    /// `..` and the name goes blank: there is still a preview to close. Internal, for the tests.
    let closeButton = NSButton()
    /// What `closeButton` does. Set by whoever owns the surface, since the header cannot tell which
    /// of the three sizes it is in or what turns that one off.
    var onClose: (() -> Void)?

    /// The file being previewed, or `nil` when there is nothing under the cursor — which blanks
    /// the strip rather than hiding it, so the preview underneath doesn't jump.
    var caption: QuickViewCaption? {
        didSet {
            guard caption != oldValue else { return }
            // As the pane's row draws it: a control character would push the name onto a second
            // line the strip has no room for.
            nameLabel.stringValue = caption.map { FileNameDisplay.visible($0.name) } ?? ""
            positionLabel.stringValue = caption?.positionText ?? ""
            let showsSlideshow = caption?.isSlideshowRunning == true
            slideshowButton.isHidden = !showsSlideshow
            closeClearsSlideshow?.isActive = showsSlideshow
            showStyles(of: caption)
            showMedia(of: caption)
        }
    }

    init(material: NSVisualEffectView.Material) {
        super.init(frame: .zero)
        self.material = material
        blendingMode = .withinWindow
        // `.active` rather than `.followsWindowActiveState`: in full screen the window may not be
        // key while the user is looking at a photo, and a strip that goes flat then reads as a bug.
        state = .active
        translatesAutoresizingMaskIntoConstraints = false
        buildStyleStrip()
        buildLabels()
        buildCloseButton()
        buildSlideshowButton()
        buildMediaReadout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildLabels() {
        nameLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        // Middle truncation, like the path bar: the extension is what says which *kind* of file
        // this is, and a tail-truncated name throws exactly that away.
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.alignment = .center
        positionLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        positionLabel.textColor = .secondaryLabelColor
        for label in [nameLabel, positionLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        // The name yields first: it is the one label that can be arbitrarily long, and the
        // position readout is short, fixed-width and useless when clipped.
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            nameLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            styleStrip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            styleStrip.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: styleStrip.trailingAnchor,
                constant: 12
            ),
            positionLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            positionLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    /// The × after the name. The name stays centered, where it always was, and the button hangs off
    /// its end rather than the two being centered as a pair. So it is the button rather than the name
    /// that keeps clear of the position readout, and a long name gives way to both.
    private func buildCloseButton() {
        let title = String(
            localized: "Close Quick View",
            comment: "Quick View header: tooltip and accessibility label of the close (×) button."
        )
        let symbol = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: title)
        closeButton.image = symbol?.withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = title
        // A click must not take focus: the arrow keys keep driving the file list under the preview.
        closeButton.refusesFirstResponder = true
        closeButton.target = self
        closeButton.action = #selector(closeClicked(_:))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.widthAnchor.constraint(equalToConstant: Self.closeButtonSize),
            closeButton.heightAnchor.constraint(equalToConstant: Self.closeButtonSize),
            closeButton.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 2),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(
                lessThanOrEqualTo: positionLabel.leadingAnchor,
                constant: -12
            )
        ])
    }

    /// Wider than the 12 pt glyph, so a trackpad click that lands just beside it still counts.
    private static let closeButtonSize: CGFloat = 20

    @objc private func closeClicked(_ sender: NSButton) {
        onClose?()
    }

    /// "▶ Slideshow", in the position's size and color with the play glyph ahead of it, hidden until
    /// a caption says a show is running. A borderless button so a hand on the trackpad can stop the
    /// show, which otherwise only a key does. The position stays where it always was, at the edge.
    private func buildSlideshowButton() {
        let label = String(
            localized: "Slideshow",
            comment: "Quick View header: shown beside the position while a slideshow runs."
        )
        let stop = String(
            localized: "Stop Slideshow",
            comment: "Quick View header: tooltip and accessibility label of the running slideshow's mark."
        )
        slideshowButton.attributedTitle = NSAttributedString(
            string: label,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        slideshowButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .regular))
        slideshowButton.imagePosition = .imageLeading
        slideshowButton.imageHugsTitle = true
        slideshowButton.contentTintColor = .secondaryLabelColor
        slideshowButton.isBordered = false
        slideshowButton.toolTip = stop
        slideshowButton.setAccessibilityLabel(stop)
        // A click must not take focus: the arrow keys keep driving the file list under the preview.
        slideshowButton.refusesFirstResponder = true
        slideshowButton.target = self
        slideshowButton.action = #selector(slideshowClicked(_:))
        slideshowButton.isHidden = true
        slideshowButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(slideshowButton)
        NSLayoutConstraint.activate([
            slideshowButton.trailingAnchor.constraint(
                equalTo: positionLabel.leadingAnchor,
                constant: -10
            ),
            slideshowButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        closeClearsSlideshow = closeButton.trailingAnchor.constraint(
            lessThanOrEqualTo: slideshowButton.leadingAnchor,
            constant: -12
        )
    }

    @objc private func slideshowClicked(_ sender: NSButton) {
        onStopSlideshow?()
    }

    /// Keep the buttons out of reach while a floating header is faded out. A view at zero alpha is
    /// still hit-tested (docs/NOTES.md ▸ Views, layout and hit testing), so without this a click on
    /// the top of a full-screen photograph, where nothing can be seen, would close the preview or
    /// switch its style. The strip itself takes the click, as it did before it had buttons.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard hit != nil, alphaValue == 0 else { return hit }
        return self
    }

    /// The mark itself, keyed by its English text like every other app literal.
    static let noJavaScriptMark = String(
        localized: "(no JavaScript)",
        comment: "Quick View header mark: the rendered page was drawn with scripts refused."
    )
}

// MARK: - The styles

extension QuickViewHeaderView {
    /// The strip's one font, the system's small size, which every label in the header shares.
    private static let styleFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

    /// "1 Source · 2 Page", each style a button and the dot between them plain text, ahead of the
    /// "(no JavaScript)" mark. Spacing 0, so the pieces sit as the one label they replaced drew them.
    private func buildStyleStrip() {
        styleStrip.orientation = .horizontal
        styleStrip.alignment = .firstBaseline
        styleStrip.spacing = 0
        // A file with one rendering hides every piece, and the strip goes to nothing rather than
        // keeping room the centered name could use.
        styleStrip.detachesHiddenViews = true
        for button in styleButtons {
            if !styleStrip.arrangedSubviews.isEmpty {
                styleStrip.addArrangedSubview(Self.stripLabel(" · ", color: .tertiaryLabelColor))
            }
            button.target = self
            button.action = #selector(styleClicked(_:))
            styleStrip.addArrangedSubview(button)
        }
        noJavaScriptLabel.font = Self.styleFont
        noJavaScriptLabel.textColor = .tertiaryLabelColor
        styleStrip.addArrangedSubview(noJavaScriptLabel)
        styleStrip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(styleStrip)
    }

    /// The button for `style`, named by its raw value so a click can say which one it was.
    private static func makeStyleButton(for style: QuickViewRenderStyle) -> NSButton {
        let button = QuickViewStyleButton()
        button.identifier = NSUserInterfaceItemIdentifier(style.rawValue)
        button.isBordered = false
        // A click must not take focus: the arrow keys keep driving the file list under the preview.
        button.refusesFirstResponder = true
        return button
    }

    private static func stripLabel(_ text: String, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = styleFont
        label.textColor = color
        return label
    }

    /// The current style in full strength and the other dimmed — one glance says both what you are
    /// looking at and which key or click changes it. Hidden for a file with a single rendering, so
    /// the strip says nothing where the keys would do nothing.
    ///
    /// A page rendered with scripts refused carries "(no JavaScript)" after the two styles. Written
    /// as a lowercase parenthetical rather than as a third `· item` on purpose: the two styles are
    /// a list of things a key selects, and a note that reads like a third one invites the user to
    /// look for the digit that picks it. It appears only in `.rendered` — in source mode no script
    /// would have run either way, so the mark would be true and meaningless.
    private func showStyles(of caption: QuickViewCaption?) {
        let style = caption?.style
        let kind = caption?.styleKind ?? .page
        for view in styleStrip.arrangedSubviews {
            view.isHidden = style == nil
        }
        for (candidate, button) in zip(QuickViewRenderStyle.allCases, styleButtons) {
            button.attributedTitle = NSAttributedString(
                string: "\(candidate.digit) \(candidate.headerLabel(for: kind))",
                attributes: [
                    .font: Self.styleFont,
                    .foregroundColor: candidate == style ? NSColor.labelColor : .secondaryLabelColor
                ]
            )
        }
        noJavaScriptLabel.isHidden = style != .rendered || caption?.javaScriptDisabled != true
    }

    /// Hand the clicked style to the surface's owner, which writes it exactly as its digit would.
    /// The style already on screen is handed over too: the preference ignores a value it already
    /// holds, so the click is simply a no-op there rather than a rule of the strip's own.
    @objc private func styleClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let style = QuickViewRenderStyle(rawValue: raw)
        else { return }
        onPickStyle?(style)
    }
}

/// A borderless text button that lays out on its title like a label. The cell pads the title by
/// about 2 pt a side where a label's insets cancel its own padding, so a plain button pushed each
/// style that far right of where the one label drew it, and the dots apart. Measured 2026-10-20:
/// with these insets the title lands within half a point of the label's, and the padding stays
/// clickable beside the text — the close button's reasoning, for a trackpad click just off a word.
private final class QuickViewStyleButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
    }
}

// MARK: - A movie or a sound

/// The header constraints that come and go with the media readout.
struct QuickViewHeaderMediaConstraints {
    var nameClearsPlayback: NSLayoutConstraint?
    var factsBesidePosition: NSLayoutConstraint?
    var factsBesideSlideshow: NSLayoutConstraint?
    var closeClearsFacts: NSLayoutConstraint?
}

extension QuickViewHeaderView {
    /// The play state and place at the leading edge, and the facts before the position.
    ///
    /// **The facts give way first** when the strip is short of room, then the name: the name is what
    /// the header is for (it stands in for the row a full-size preview covers), and the facts stay
    /// whole in the tooltip. The readout does not give way, since a clipped clock says nothing.
    private func buildMediaReadout() {
        let title = LocalizedCatalog.command(for: "view.quickViewPlayPause")?.title
        playbackButton.isBordered = false
        playbackButton.imagePosition = .imageLeading
        playbackButton.imageHugsTitle = true
        playbackButton.contentTintColor = .secondaryLabelColor
        playbackButton.toolTip = title
        // A click must not take focus: the arrow keys keep driving the file list under the preview.
        playbackButton.refusesFirstResponder = true
        playbackButton.target = self
        playbackButton.action = #selector(playbackClicked(_:))
        playbackButton.isHidden = true
        factsLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        factsLabel.textColor = .secondaryLabelColor
        factsLabel.lineBreakMode = .byTruncatingTail
        factsLabel.isHidden = true
        factsLabel.setContentCompressionResistancePriority(
            NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.defaultLow.rawValue - 1),
            for: .horizontal
        )
        for view in [playbackButton, factsLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            playbackButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            playbackButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            factsLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        mediaConstraints = QuickViewHeaderMediaConstraints(
            nameClearsPlayback: nameLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: playbackButton.trailingAnchor,
                constant: 12
            ),
            factsBesidePosition: factsLabel.trailingAnchor.constraint(
                equalTo: positionLabel.leadingAnchor,
                constant: -10
            ),
            factsBesideSlideshow: factsLabel.trailingAnchor.constraint(
                equalTo: slideshowButton.leadingAnchor,
                constant: -10
            ),
            closeClearsFacts: closeButton.trailingAnchor.constraint(
                lessThanOrEqualTo: factsLabel.leadingAnchor,
                constant: -12
            )
        )
    }

    /// Draw the readout for `caption`, or put it away when the caption is not a movie's or a sound's.
    private func showMedia(of caption: QuickViewCaption?) {
        let media = caption?.media
        playbackButton.isHidden = media == nil
        mediaConstraints.nameClearsPlayback?.isActive = media != nil
        if let media {
            playbackButton.image = NSImage(
                systemSymbolName: media.isPlaying ? "play.fill" : "pause.fill",
                accessibilityDescription: nil
            )?.withSymbolConfiguration(.init(pointSize: 8, weight: .regular))
            playbackButton.attributedTitle = NSAttributedString(
                string: media.time,
                attributes: [
                    // Tabular digits, so the readout keeps its width as the seconds tick over.
                    .font: NSFont.monospacedDigitSystemFont(
                        ofSize: NSFont.smallSystemFontSize,
                        weight: .regular
                    ),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
        }
        let facts = media?.facts ?? ""
        factsLabel.stringValue = facts
        factsLabel.toolTip = facts.isEmpty ? nil : facts
        factsLabel.isHidden = facts.isEmpty
        let besideSlideshow = !facts.isEmpty && caption?.isSlideshowRunning == true
        mediaConstraints.factsBesideSlideshow?.isActive = besideSlideshow
        mediaConstraints.factsBesidePosition?.isActive = !facts.isEmpty && !besideSlideshow
        mediaConstraints.closeClearsFacts?.isActive = !facts.isEmpty
    }

    @objc private func playbackClicked(_ sender: NSButton) {
        onTogglePlayback?()
    }
}
