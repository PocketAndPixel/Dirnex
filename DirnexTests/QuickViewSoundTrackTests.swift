import AppKit
import AVFoundation
import DirnexCore
import Testing

@testable import Dirnex

/// A movie's sound tracks in Quick View (PLAN.md §M42 ▸ Sound tracks): a file opens on its sound in the
/// app's language, the header lists every sound and plays the one picked, and ⌥⌘P steps to the next.
///
/// Each test sets the media view's language rather than reading the app's, since the test host takes
/// whatever language the developer pinned Dirnex to (docs/NOTES.md ▸ Localization ▸ Switching
/// languages); `appLanguage` pins where the default comes from.
@Suite("Quick View sound tracks")
@MainActor
struct QuickViewSoundTrackTests {
    private func surface(language: String?) -> QuickViewPreviewView {
        let view = QuickViewPreviewView(
            backingColor: .black,
            header: .pinned,
            findOptions: QuickViewFindOptionsStore.scratch()
        )
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        view.layoutSubtreeIfNeeded()
        view.ensureMediaView().soundLanguage = language
        return view
    }

    /// Show `url` and wait for the backend to say it is on screen. A minute, for the reason
    /// `QuickViewMediaTests.show` gives.
    private func show(_ url: URL, on view: QuickViewPreviewView) async throws -> QuickViewMediaView {
        view.show(url, style: .default)
        view.setCaption(QuickViewCaption(name: url.lastPathComponent, position: 1, count: 3))
        try await settleUntil(within: Self.budget) { !view.flipGate.isLoading }
        view.layoutSubtreeIfNeeded()
        return try #require(view.mediaView)
    }

    private static let budget = Duration.seconds(60)

    /// A Matroska film with an English AAC sound, the default, then a Russian Opus one, and with
    /// `dts` a Ukrainian DTS one after them with no frames, which cannot play.
    private func film(in tree: TempDirectory, seconds: Int = 1, dts: Bool = false) async throws -> URL {
        let url = tree.root.appendingPathComponent("film.mkv")
        var sounds = [
            MatroskaFixtures.Sound(codecID: "A_AAC", language: "eng", isDefault: true),
            MatroskaFixtures.Sound(codecID: "A_OPUS", language: "rus")
        ]
        if dts { sounds.append(MatroskaFixtures.Sound(codecID: "A_DTS", language: "ukr")) }
        try await MatroskaFixtures.writeFilm(to: url, seconds: seconds, sounds: sounds)
        return url
    }

    /// An MP4 of a Russian sound, the default, then an English one, as alternatives or not.
    private func sounds(in tree: TempDirectory, grouped: Bool) async throws -> URL {
        let url = tree.root.appendingPathComponent(grouped ? "grouped.mp4" : "together.mp4")
        try await QuickViewMediaFixtures.writeSounds(
            to: url,
            languages: ["rus", "eng"],
            grouped: grouped
        )
        return url
    }

    @Test("the language is the app's, as its bundle resolved it")
    func appLanguage() {
        #expect(QuickViewMediaView().soundLanguage == Bundle.main.preferredLocalizations.first)
    }

    // MARK: - The core's player

    @Test("a Matroska film opens on its sound in the app's language, and on its default without one")
    func matroskaLanguage() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try await film(in: tree)
        for (language, expected) in [("ru", UInt64(3)), ("en", 2), ("de", 2), (nil, 2)] {
            let media = try await show(url, on: surface(language: language))
            #expect(media.sampleBufferPlayer != nil)
            #expect(media.playingSound == expected, "in \(language ?? "no language")")
            #expect(media.canSwitchSound)
            media.stop()
        }
    }

    @Test("a pick plays the other sound from where the player is, and it goes on playing")
    func matroskaSwitch() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let view = surface(language: "en")
        let media = try await show(try film(in: tree, seconds: 60), on: view)
        let player = try #require(media.sampleBufferPlayer)
        media.togglePlayback()
        try await settleUntil(within: Self.budget) { player.currentSeconds > 0.3 }
        let before = player.currentSeconds
        media.selectSound(3)
        #expect(media.playingSound == 3)
        #expect(media.isPlaying)
        try await settleUntil(within: Self.budget) { player.currentSeconds > before + 0.5 }
        #expect(player.audioError == nil, "the sound renderer took Opus after AAC")
        #expect(view.headerView?.caption?.media?.playingSound == 3)
        media.selectSound(2)
        try await settleUntil(within: Self.budget) { player.currentSeconds > before + 1 }
        #expect(media.playingSound == 2 && player.audioError == nil)
        media.togglePlayback()
    }

    @Test("⌥⌘P steps through the sounds that play, past the one that cannot, and back to the first")
    func nextSound() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let view = surface(language: "en")
        let media = try await show(try film(in: tree, dts: true), on: view)
        #expect(media.sounds.map(\.id) == [2, 3, 4])
        #expect(media.sounds.map(\.isDecodable) == [true, true, false])
        view.selectNextMediaSound()
        #expect(media.playingSound == 3)
        view.selectNextMediaSound()
        #expect(media.playingSound == 2)
        #expect(
            CommandBinding.selector(for: "view.quickViewNextAudioTrack")
                == #selector(BrowserWindowController.nextQuickViewAudioTrack(_:))
        )
    }

    // MARK: - AVFoundation's player

    @Test("an MP4 whose sounds are alternatives opens on the app's language, and a pick switches it")
    func alternatives() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try await sounds(in: tree, grouped: true)
        for (language, expected) in [("en", UInt64(1)), ("ru", 0), ("de", 0)] {
            let media = try await show(url, on: surface(language: language))
            let item = try #require(media.player.currentItem)
            try await settleUntil(within: Self.budget) { item.status == .readyToPlay }
            #expect(media.playingSound == expected, "in \(language)")
            #expect(media.sounds.count == 2 && media.canSwitchSound)
            media.stop()
        }
        let view = surface(language: "en")
        let media = try await show(url, on: view)
        let item = try #require(media.player.currentItem)
        try await settleUntil(within: Self.budget) { item.status == .readyToPlay }
        media.selectSound(0)
        #expect(media.playingSound == 0)
        let group = try #require(media.audibleOptions?.group)
        #expect(
            item.currentMediaSelection.selectedMediaOption(in: group)?.extendedLanguageTag == "ru"
        )
        try await settleUntil(within: Self.budget) { view.headerView?.caption?.media?.playingSound == 0 }
        view.selectNextMediaSound()
        #expect(media.playingSound == 1)
    }

    /// Tracks in no alternate group are all enabled, and AVPlayer plays them together, as QuickTime
    /// Player does: a recording with a microphone on a track of its own is one of these.
    @Test("an MP4 whose sounds are not alternatives plays them together, with nothing to pick")
    func together() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let view = surface(language: "en")
        let media = try await show(try sounds(in: tree, grouped: false), on: view)
        #expect(media.sounds.isEmpty && !media.canSwitchSound && media.playingSound == nil)
        #expect(view.headerView?.caption?.media?.sounds.isEmpty == true)
        #expect(view.headerView?.soundButton.isHidden == true)
    }

    // MARK: - The header

    @Test(
        "the header lists every sound, checks the playing one, greys the one that cannot play, and plays a pick"
    )
    func headerMenu() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let view = surface(language: "en")
        let media = try await show(try film(in: tree, dts: true), on: view)
        let header = try #require(view.headerView)
        #expect(!header.soundButton.isHidden)
        let english = try #require(QuickViewSoundTrack.languageName("en"))
        #expect(header.soundButton.attributedTitle.string.hasPrefix(english))
        #expect(header.soundMenu.items.map(\.state) == [.on, .off, .off])
        #expect(header.soundMenu.items.map(\.isEnabled) == [true, true, false])
        #expect(header.soundMenu.items.map(\.title) == media.sounds.map(\.menuTitle))
        header.soundMenu.performActionForItem(at: 1)
        #expect(media.playingSound == 3)
        try await settleUntil(within: Self.budget) {
            header.soundMenu.items.map(\.state) == [.off, .on, .off]
        }
        let russian = try #require(QuickViewSoundTrack.languageName("ru"))
        #expect(header.soundButton.attributedTitle.string.hasPrefix(russian))
    }

    @Test(
        "a movie with one sound has no sound button, and the next file with several brings it back"
    )
    func headerHidden() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let single = tree.root.appendingPathComponent("single.mkv")
        try await MatroskaFixtures.writeMovie(to: single)
        let view = surface(language: "en")
        let media = try await show(single, on: view)
        let header = try #require(view.headerView)
        #expect(!media.canSwitchSound)
        #expect(header.soundButton.isHidden)
        _ = try await show(try film(in: tree), on: view)
        #expect(!header.soundButton.isHidden)
    }

    @Test(
        "each sound reads as its language, codec, channels and name, and a bibliographic code is named"
    )
    func lines() throws {
        let german = try #require(QuickViewSoundTrack.languageName("de"))
        let sound = QuickViewSoundTrack(
            id: 2,
            language: "ger",
            codec: "AC-3",
            channels: 6,
            name: "Kino",
            isDecodable: true
        )
        #expect(sound.line == "\(german) · AC-3 · 5.1 · Kino")
        #expect(sound.title == german)
        #expect(sound.menuTitle == sound.line)
        let unnamed = QuickViewSoundTrack(
            id: 3,
            language: nil,
            codec: "DTS",
            channels: nil,
            name: nil,
            isDecodable: false
        )
        #expect(unnamed.title == "DTS")
        #expect(unnamed.menuTitle != unnamed.line, "an undecodable track says so")
    }

    /// Foundation names a language as it goes mid-sentence, lower-case in Russian and French, and the
    /// Russian header read "русский ⌄" (seen live 2026-11-21).
    @Test("a language's name starts with a capital, and only its first word does")
    func capitals() {
        #expect(QuickViewSoundTrack.languageName("rus", in: Locale(identifier: "ru")) == "Русский")
        #expect(
            QuickViewSoundTrack.languageName("nob", in: Locale(identifier: "fr")) == "Norvégien bokmål"
        )
        #expect(QuickViewSoundTrack.languageName("eng", in: Locale(identifier: "en")) == "English")
        #expect(QuickViewSoundTrack.languageName("und", in: Locale(identifier: "ru")) == nil)
    }

    @Test("a pick made in AVKit's own menu reaches the header, though nothing plays")
    func pickedElsewhere() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let view = surface(language: "en")
        let media = try await show(try sounds(in: tree, grouped: true), on: view)
        let item = try #require(media.player.currentItem)
        try await settleUntil(within: Self.budget) { item.status == .readyToPlay }
        let options = try #require(media.audibleOptions)
        try await settleUntil(within: Self.budget) { view.headerView?.caption?.media?.playingSound == 1 }
        item.select(try #require(options.option(0)), in: options.group)
        try await settleUntil(within: Self.budget) { view.headerView?.caption?.media?.playingSound == 0 }
        #expect(!media.isPlaying)
    }
}
