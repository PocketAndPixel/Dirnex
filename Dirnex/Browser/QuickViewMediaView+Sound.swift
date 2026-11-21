import AppKit
import AVFoundation
import DirnexCore

/// The sound tracks of the movie on screen (PLAN.md §M42 ▸ Sound tracks): which one plays, the header's
/// menu of them, and ⌥⌘P stepping to the next.
///
/// A film carries several sounds where most MP4s carry one, and it opens on the first in the app's
/// language (`MediaSoundChoice`), else on the file's own default. The core's player picks it as it
/// prepares a Matroska or AVI file; for AVFoundation's this picks among the file's alternatives
/// (`QuickViewAudibleOptions`). A pick in the menu holds for the file on screen only: the next file
/// opens in the app's language again (Oleg, 2026-11-21).
extension QuickViewMediaView {
    /// The file's sounds, for the header's menu and the facts' tooltip; empty for one with a single
    /// sound AVFoundation plays, or with sounds it plays together.
    var sounds: [QuickViewSoundTrack] {
        sampleBufferPlayer?.sounds ?? audibleOptions?.sounds ?? []
    }

    /// The `id` of the sound playing, or `nil` with no choice of sound.
    var playingSound: UInt64? {
        if let sampleBufferPlayer { return sampleBufferPlayer.playingSound }
        guard let audibleOptions, let item = player.currentItem else { return nil }
        return audibleOptions.id(
            of: item.currentMediaSelection.selectedMediaOption(in: audibleOptions.group)
        )
    }

    /// Whether another sound can be played in place of this one, which is what the header's menu and
    /// ⌥⌘P need: more than one sound decodes.
    var canSwitchSound: Bool {
        if let sampleBufferPlayer { return sampleBufferPlayer.canSwitchSound }
        return (audibleOptions?.sounds.count { $0.isDecodable } ?? 0) > 1
    }

    /// Play the sound `id` from where the player is, playing on or paused as it was. Nothing for the
    /// one playing, or for one this Mac cannot decode.
    func selectSound(_ id: UInt64) {
        if let sampleBufferPlayer {
            sampleBufferPlayer.selectSound(id)
            return
        }
        guard let audibleOptions, let item = player.currentItem,
              let option = audibleOptions.option(id), option.isPlayable
        else { return }
        item.select(option, in: audibleOptions.group)
        onReadoutChange?()
    }

    /// ⌥⌘P: the next sound that decodes, after the last the first again.
    func selectNextSound() {
        let playable = sounds.filter(\.isDecodable)
        guard canSwitchSound, !playable.isEmpty else { return }
        let next = playable.firstIndex { $0.id == playingSound }.map { playable[
            ($0 + 1) % playable.count
        ] }
        selectSound((next ?? playable[0]).id)
    }

    /// Select on `item` the sound the app's language prefers among `audibleOptions`, before it is put
    /// up.
    ///
    /// Left alone, AVPlayer picks by the system's languages rather than the app's: probed 2026-11-21, a
    /// file whose default was Russian played English, the first of this Mac's languages. A selection
    /// made here holds over that pick (`alternatives` in `QuickViewSoundTrackTests` passes for Russian
    /// with `appliesMediaSelectionCriteriaAutomatically` on, on that same Mac).
    func applyPreferredSound(to item: AVPlayerItem) {
        guard let audibleOptions,
              let choice = MediaSoundChoice.preferred(
                  audibleOptions.sounds.filter(\.isDecodable),
                  language: soundLanguage
              ),
              let option = audibleOptions.option(choice.id)
        else { return }
        item.select(option, in: audibleOptions.group)
    }

    /// Tell the header when `item`'s sound changes by any hand, or stop telling it with `nil`. AVKit
    /// draws its own menu of sounds for a file of alternatives, and a pick there while paused would
    /// leave the header naming the old one until playback next moved.
    ///
    /// Selector-based and scoped to the one item, as every observer in the app is: the system drops a
    /// selector observer with its object, where a block's token would need a `deinit` that cannot
    /// touch it, and `object: nil` would wake every surface's player for any item's change.
    func observeSoundChanges(of item: AVPlayerItem?) {
        let center = NotificationCenter.default
        center.removeObserver(
            self,
            name: AVPlayerItem.mediaSelectionDidChangeNotification,
            object: nil
        )
        guard let item else { return }
        center.addObserver(
            self,
            selector: #selector(soundDidChange(_:)),
            name: AVPlayerItem.mediaSelectionDidChangeNotification,
            object: item
        )
    }

    /// On whatever thread AVFoundation posts from, so the header is told on the main one.
    @objc nonisolated private func soundDidChange(_: Notification) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onReadoutChange?() }
        }
    }

    /// `readout` with the file's sounds: the menu's list and the one playing, and the facts' tooltip
    /// naming every one, which one plays and which this Mac cannot decode. The film on this Mac has four
    /// DTS tracks among nine, so a silent track left unnamed would read as a broken player.
    func withSounds(_ readout: QuickViewMediaReadout) -> QuickViewMediaReadout {
        var readout = readout
        let sounds = sounds
        let playing = playingSound
        let lines = QuickViewSoundTrack.tooltipLines(sounds, playing: playing)
        if !lines.isEmpty {
            readout.detail = ([readout.facts] + lines).filter { !$0.isEmpty }.joined(separator: "\n")
        }
        if canSwitchSound {
            readout.sounds = sounds
            readout.playingSound = playing
        }
        return readout
    }
}
