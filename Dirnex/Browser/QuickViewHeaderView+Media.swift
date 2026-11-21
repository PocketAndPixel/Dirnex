import AppKit
import DirnexCore

// MARK: - A movie or a sound

/// The header constraints that come and go with the media readout.
struct QuickViewHeaderMediaConstraints {
    var nameClearsPlayback: NSLayoutConstraint?
    var nameClearsSound: NSLayoutConstraint?
    var factsBesidePosition: NSLayoutConstraint?
    var factsBesideSlideshow: NSLayoutConstraint?
    var closeClearsFacts: NSLayoutConstraint?
}

extension QuickViewHeaderView {
    /// The play state and place at the leading edge, the sound after them, and the facts before the
    /// position.
    ///
    /// **The facts give way first** when the strip is short of room, then the sound, then the name: the
    /// name is what the header is for (it stands in for the row a full-size preview covers), the facts
    /// stay whole in the tooltip, and the sound's menu says what the button no longer can. The readout
    /// does not give way, since a clipped clock says nothing.
    func buildMediaReadout() {
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
            QuickViewHeaderPriority.facts,
            for: .horizontal
        )
        buildSoundButton()
        for view in [playbackButton, soundButton, factsLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            playbackButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            playbackButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            soundButton.leadingAnchor.constraint(
                equalTo: playbackButton.trailingAnchor,
                constant: 10
            ),
            soundButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            factsLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        mediaConstraints = QuickViewHeaderMediaConstraints(
            nameClearsPlayback: nameLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: playbackButton.trailingAnchor,
                constant: 12
            ),
            nameClearsSound: nameLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: soundButton.trailingAnchor,
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
    func showMedia(of caption: QuickViewCaption?) {
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
        factsLabel.toolTip = facts.isEmpty ? nil : media?.detail ?? facts
        factsLabel.isHidden = facts.isEmpty
        let besideSlideshow = !facts.isEmpty && caption?.isSlideshowRunning == true
        mediaConstraints.factsBesideSlideshow?.isActive = besideSlideshow
        mediaConstraints.factsBesidePosition?.isActive = !facts.isEmpty && !besideSlideshow
        mediaConstraints.closeClearsFacts?.isActive = !facts.isEmpty
        showSounds(of: media)
    }

    @objc private func playbackClicked(_ sender: NSButton) {
        onTogglePlayback?()
    }
}

// MARK: - The sound tracks

extension QuickViewHeaderView {
    /// The language of the sound playing, after the readout, opening a menu of every sound
    /// (PLAN.md §M42 ▸ Sound tracks). Styled as the readout is, borderless and secondary, since it is
    /// one more thing about the player rather than a control of the window's.
    private func buildSoundButton() {
        soundButton.isBordered = false
        soundButton.imagePosition = .imageLeading
        soundButton.imageHugsTitle = true
        soundButton.contentTintColor = .secondaryLabelColor
        soundButton.image = NSImage(
            systemSymbolName: "speaker.wave.2.fill",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 9, weight: .regular))
        soundButton.setAccessibilityLabel(String(
            localized: "Audio Track",
            comment: "Accessibility label of the Quick View header button that lists a movie's sound tracks."
        ))
        // As the readout's: a click must not take focus from the file list under the preview.
        soundButton.refusesFirstResponder = true
        soundButton.target = self
        soundButton.action = #selector(soundClicked(_:))
        soundButton.lineBreakMode = .byTruncatingTail
        soundButton.setContentCompressionResistancePriority(
            QuickViewHeaderPriority.sound,
            for: .horizontal
        )
        soundButton.isHidden = true
        soundMenu.autoenablesItems = false
    }

    /// Show the button for `media`'s sounds when there is a choice of them, and build its menu when they
    /// or the one playing have changed.
    private func showSounds(of media: QuickViewMediaReadout?) {
        let sounds = media?.sounds ?? []
        soundButton.isHidden = sounds.isEmpty
        mediaConstraints.nameClearsSound?.isActive = !sounds.isEmpty
        let playing = media?.playingSound
        guard sounds != shownSounds.sounds || playing != shownSounds.playing else { return }
        shownSounds = (sounds, playing)
        soundMenu.removeAllItems()
        for sound in sounds {
            let item = NSMenuItem(
                title: sound.menuTitle,
                action: #selector(soundPicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = Int(clamping: sound.id)
            item.isEnabled = sound.isDecodable
            item.state = sound.id == playing ? .on : .off
            soundMenu.addItem(item)
        }
        let current = sounds.first { $0.id == playing }
        soundButton.attributedTitle = Self.soundTitle(current?.title ?? "")
        soundButton.toolTip = current?.line
    }

    /// "English ⌄" in the readout's font and color, the chevron saying a click opens a list.
    private static func soundTitle(_ language: String) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let title = NSMutableAttributedString(
            string: language + " ",
            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        )
        if let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 7, weight: .semibold)) {
            let attachment = NSTextAttachment()
            attachment.image = chevron
            title.append(NSAttributedString(attachment: attachment))
        }
        return title
    }

    @objc private func soundClicked(_ sender: NSButton) {
        soundMenu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: sender.isFlipped ? sender.bounds.maxY + 4 : -4),
            in: sender
        )
    }

    @objc private func soundPicked(_ sender: NSMenuItem) {
        onPickSound?(UInt64(sender.tag))
    }
}
