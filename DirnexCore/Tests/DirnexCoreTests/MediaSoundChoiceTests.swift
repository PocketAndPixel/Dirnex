import Foundation
import Testing

@testable import DirnexCore

/// Which sound a file opens on (PLAN.md §M42 ▸ Sound tracks): the first in the app's language, and the
/// file's own choice otherwise.
@Suite("Sound track choice")
struct MediaSoundChoiceTests {
    // MARK: - Languages

    @Test("a language reads the same however a file spells it")
    func spellings() {
        #expect(MediaLanguage.primary("rus") == "ru")
        #expect(MediaLanguage.primary("ru") == "ru")
        #expect(MediaLanguage.primary("ru-RU") == "ru")
        #expect(MediaLanguage.primary("RUS") == "ru")
        #expect(MediaLanguage.primary("en_US") == "en")
        #expect(MediaLanguage.primary("pt-BR") == "pt")
        #expect(MediaLanguage.primary("zh-Hant") == "zh")
        #expect(MediaLanguage.primary("ukr") == "uk")
        #expect(MediaLanguage.primary("deu") == "de")
    }

    @Test("ISO 639-2's bibliographic codes, which mkvmerge writes, read as their terminology twins")
    func bibliographic() {
        #expect(MediaLanguage.primary("ger") == "de")
        #expect(MediaLanguage.primary("fre") == "fr")
        #expect(MediaLanguage.primary("chi") == "zh")
        #expect(MediaLanguage.primary("dut") == "nl")
        #expect(MediaLanguage.primary("cze") == "cs")
        #expect(MediaLanguage.bibliographic.count == 20)
        for (code, twin) in MediaLanguage.bibliographic {
            #expect(MediaLanguage.primary(code) == MediaLanguage.primary(twin), "\(code)")
            #expect(MediaLanguage.primary(code)?.count == 2, "\(code) has an ISO 639-1 code")
        }
    }

    @Test("a code that names no language matches nothing, not even itself")
    func unknown() {
        for code in ["und", "mul", "zxx", "mis", "", "-"] {
            #expect(MediaLanguage.primary(code) == nil, "\(code)")
            #expect(!MediaLanguage.matches(code, code), "\(code)")
        }
        #expect(MediaLanguage.primary(nil) == nil)
        #expect(!MediaLanguage.matches(nil, "en"))
        #expect(!MediaLanguage.matches("eng", nil))
    }

    @Test("the app's languages each match a track marked in any spelling of theirs")
    func appLanguages() {
        let tracks = [
            "en": "eng", "de": "ger", "es": "spa", "fr": "fre", "it": "ita", "ja": "jpn",
            "ko": "kor",
            "nl": "dut", "pl": "pol", "pt-BR": "por", "ru": "rus", "uk": "ukr", "zh-Hans": "chi",
            "zh-Hant": "zho"
        ]
        for language in AppLanguages.all.map(\.code) {
            let track = tracks[language]
            #expect(MediaLanguage.matches(track, language), "\(language) and \(track ?? "nothing")")
            #expect(!MediaLanguage.matches("hun", language), "\(language)")
        }
        #expect(tracks.count == AppLanguages.all.count)
    }

    // MARK: - The rule

    private struct Sound: MediaSoundCandidate, Equatable {
        let id: Int
        let soundLanguage: String?
        var isDefault = false
        var isSecondarySound = false
    }

    @Test(
        "the app's language wins over the file's default, and the default wins within the language"
    )
    func languageFirst() {
        let sounds = [
            Sound(id: 1, soundLanguage: "rus", isDefault: true),
            Sound(id: 2, soundLanguage: "rus"),
            Sound(id: 3, soundLanguage: "eng"),
            Sound(id: 4, soundLanguage: "eng", isDefault: true)
        ]
        #expect(MediaSoundChoice.preferred(sounds, language: "en")?.id == 4)
        #expect(MediaSoundChoice.preferred(sounds, language: "ru")?.id == 1)
        #expect(MediaSoundChoice.preferred(Array(sounds.prefix(3)), language: "en")?.id == 3)
    }

    @Test("with nothing in the language, the default plays, else the first")
    func fallback() {
        let sounds = [
            Sound(id: 1, soundLanguage: "rus"),
            Sound(id: 2, soundLanguage: "ukr", isDefault: true)
        ]
        #expect(MediaSoundChoice.preferred(sounds, language: "de")?.id == 2)
        #expect(MediaSoundChoice.preferred(sounds, language: nil)?.id == 2)
        #expect(MediaSoundChoice.preferred(Array(sounds.prefix(1)), language: "de")?.id == 1)
        #expect(MediaSoundChoice.preferred([Sound](), language: "en") == nil)
    }

    @Test("a commentary in the language is passed over, and still plays when it is all there is")
    func commentary() {
        let sounds = [
            Sound(id: 1, soundLanguage: "rus", isDefault: true),
            Sound(id: 2, soundLanguage: "eng", isSecondarySound: true)
        ]
        #expect(MediaSoundChoice.preferred(sounds, language: "en")?.id == 1)
        #expect(MediaSoundChoice.preferred(Array(sounds.suffix(1)), language: "en")?.id == 2)
        #expect(MediaSoundChoice.namesCommentary("AC3 2.0 Commentary"))
        #expect(MediaSoundChoice.namesCommentary("director's COMMENTARY"))
        #expect(!MediaSoundChoice.namesCommentary("DTS 5.1 Original"))
        #expect(!MediaSoundChoice.namesCommentary(nil))
    }

    // MARK: - Real files

    /// Every codec but DTS and VP8, as on this Mac.
    private func decodes(_ track: MatroskaTrack) -> Bool {
        !["A_DTS", "V_VP8"].contains(track.codecID)
    }

    /// The film's English tracks are the DTS original, out of reach, and a commentary, so an English
    /// Dirnex plays the file's default, as before; a Ukrainian one finds its dub at track 8.
    @Test("the film opens on its Russian dub in English and Russian, and on track 8 in Ukrainian")
    func film() throws {
        let file = try MatroskaFile(source: SparseCaptureSource(fixture: "film.mkv"))
        let plan = { (language: String) in
            MatroskaPlaybackPlan(tracks: file.tracks, language: language, canDecode: decodes)
        }
        #expect(plan("en").audio?.number == 2)
        #expect(plan("ru").audio?.number == 2)
        #expect(plan("uk").audio?.number == 8)
        #expect(plan("de").audio?.number == 2)
        #expect(file.track(number: 10)?.isSecondarySound == true, "\"AC3 2.0 Commentary\"")
        #expect(file.track(number: 9)?.isSecondarySound == false)
    }

    private func sound(
        _ number: UInt64,
        _ language: String,
        _ codec: String = "A_AC3",
        isDefault: Bool = false
    ) -> MatroskaTrack {
        var track = MatroskaTrack()
        track.number = number
        track.kind = .audio
        track.codecID = codec
        track.language = language
        track.isDefault = isDefault
        return track
    }

    /// The three series on Oleg's Mac, by their first episodes' tracks: the languages spelled `rus` in
    /// one and `ru` in another, the English track last, the Russian one the default.
    @Test("each series opens in English in an English Dirnex and on its default in a Russian one")
    func series() {
        let thrones = [
            sound(2, "rus", isDefault: true), sound(3, "rus"), sound(4, "rus"), sound(5, "eng")
        ]
        let silo = [sound(2, "ru", "A_EAC3", isDefault: true), sound(3, "en", "A_EAC3")]
        let boys = [sound(2, "rus", isDefault: true), sound(3, "rus"), sound(4, "eng", "A_EAC3")]
        for (tracks, english) in [(thrones, 5), (silo, 3), (boys, 4)] {
            let picks = ["en", "ru"].map {
                MatroskaPlaybackPlan(tracks: tracks, language: $0, canDecode: decodes).audio?.number
            }
            #expect(picks == [UInt64(english), 2])
        }
    }

    @Test("Matroska's commentary and audio description flags are read, and each passes a track over")
    func flags() throws {
        let file = try MatroskaFile(source: MKV.file([
            MKV.tracks([
                MKV.track(1, type: 2, codec: "A_AC3", [EBMLWriter.uint(0x55AF, 1)]),
                MKV.track(2, type: 2, codec: "A_AC3", [EBMLWriter.uint(0x55AC, 1)]),
                MKV.track(3, type: 2, codec: "A_AC3", [EBMLWriter.uint(0x88, 0)])
            ])
        ]))
        #expect(file.tracks.map(\.isCommentary) == [true, false, false])
        #expect(file.tracks.map(\.isVisualImpaired) == [false, true, false])
        let plan = MatroskaPlaybackPlan(tracks: file.tracks, language: "en", canDecode: decodes)
        #expect(
            plan.audio?.number == 3,
            "the one plain English track, though the others are default"
        )
    }

    @Test("an AVI names no language, so its first sound plays, unless its name says commentary")
    func avi() {
        var stream = AVIStream()
        stream.kind = .audio
        #expect(!stream.isSecondarySound && stream.soundLanguage == nil)
        stream.name = "Commentary"
        #expect(stream.isSecondarySound)
    }

    // MARK: - The command

    @Test("Next Audio Track is a conflict-free View command on ⌥⌘P, beside Play/Pause")
    func command() throws {
        let ids = CommandCatalog.all.map(\.id)
        let command = try #require(
            CommandCatalog.all.first { $0.id == "view.quickViewNextAudioTrack" }
        )
        #expect(command.category == .view)
        #expect(command.shortcut == CommandShortcut(key: "p", modifiers: [.command, .option]))
        #expect(KeyBindings().conflicts(for: command.id).isEmpty)
        let playPause = try #require(ids.firstIndex(of: "view.quickViewPlayPause"))
        #expect(ids.firstIndex(of: command.id) == playPause + 1)
    }
}
