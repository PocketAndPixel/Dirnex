import Testing

@testable import DirnexCore

/// What Quick View's header says about a movie or a sound (PLAN.md §M42 ▸ Slice 2): its picture's size
/// and codecs, and where the player is in it.
@Suite("Media summary")
struct MediaSummaryTests {
    private static func code(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// The codes AVFoundation reported for the samples on 2026-11-19, and the film's.
    @Test("the codes AVFoundation reports have their codecs' names")
    func codecNames() {
        #expect(MediaCodecName.name(for: Self.code("avc1")) == "H.264")
        #expect(MediaCodecName.name(for: Self.code("mp4v")) == "MPEG-4")
        #expect(MediaCodecName.name(for: Self.code("mp1v")) == "MPEG-1")
        #expect(MediaCodecName.name(for: Self.code("mp2v")) == "MPEG-2")
        #expect(MediaCodecName.name(for: Self.code("aac ")) == "AAC")
        #expect(MediaCodecName.name(for: Self.code(".mp2")) == "MP2")
        #expect(MediaCodecName.name(for: Self.code("ac-3")) == "AC-3")
    }

    @Test("a code with no name is shown as itself, trimmed, or in hex")
    func unknownCodes() {
        #expect(MediaCodecName.name(for: Self.code("vp10")) == "vp10")
        #expect(MediaCodecName.name(for: Self.code("xyz ")) == "xyz")
        #expect(MediaCodecName.name(for: 0x0000_0001) == "0x00000001")
        #expect(MediaCodecName.name(for: Self.code("    ")) == "?")
    }

    @Test("the facts are the size, the video codecs and the sound's, in that order")
    func facts() {
        let movie = MediaSummary(
            duration: 53.76,
            pictureSize: .init(width: 2560, height: 1440),
            videoCodecs: ["H.264"],
            audioCodecs: ["AAC"]
        )
        #expect(movie.facts == "2560×1440 · H.264 · AAC")
        let silent = MediaSummary(
            pictureSize: .init(width: 1920, height: 1080),
            videoCodecs: ["H.264"]
        )
        #expect(silent.facts == "1920×1080 · H.264")
        #expect(MediaSummary(audioCodecs: ["MP3"]).facts == "MP3")
        #expect(MediaSummary().facts.isEmpty)
    }

    @Test("a codec is named once however many tracks carry it")
    func distinctCodecs() {
        let film = MediaSummary(
            pictureSize: .init(width: 1920, height: 800),
            videoCodecs: ["H.264"],
            audioCodecs: ["AC-3", "AC-3", "DTS", "AC-3", "DTS", ""]
        )
        #expect(film.facts == "1920×800 · H.264 · AC-3, DTS")
    }

    @Test("a picture with no area is left out")
    func emptyPicture() {
        let summary = MediaSummary(pictureSize: .init(width: 0, height: 0), audioCodecs: ["AAC"])
        #expect(summary.facts == "AAC")
    }

    @Test("a place reads m:ss, and h:mm:ss in anything an hour long")
    func timecode() {
        #expect(MediaTimecode.string(0, shapedBy: 53.76) == "0:00")
        #expect(MediaTimecode.string(42.9, shapedBy: 53.76) == "0:42")
        #expect(MediaTimecode.string(605, shapedBy: 900) == "10:05")
        #expect(MediaTimecode.string(42, shapedBy: 5720) == "0:00:42")
        #expect(MediaTimecode.string(5720, shapedBy: 5720) == "1:35:20")
        // With no length, the place shapes itself.
        #expect(MediaTimecode.string(3725, shapedBy: nil) == "1:02:05")
        #expect(MediaTimecode.string(65, shapedBy: nil) == "1:05")
    }

    @Test("a place that is not a place reads as the start")
    func badPlaces() {
        #expect(MediaTimecode.string(.nan, shapedBy: 60) == "0:00")
        #expect(MediaTimecode.string(-3, shapedBy: 60) == "0:00")
        #expect(MediaTimecode.string(.infinity, shapedBy: nil) == "0:00")
    }

    @Test("the readout pairs the place with the length, and reads the end as the length")
    func readout() {
        #expect(MediaTimecode.readout(at: 0, of: 53.76) == "0:00 / 0:53")
        #expect(MediaTimecode.readout(at: 53.76, of: 53.76) == "0:53 / 0:53")
        #expect(MediaTimecode.readout(at: 54.5, of: 53.76) == "0:53 / 0:53", "never past the end")
        #expect(MediaTimecode.readout(at: 42, of: 5720) == "0:00:42 / 1:35:20")
        for length in [nil, Double.nan, 0, -1] as [Double?] {
            #expect(MediaTimecode.readout(at: 42, of: length) == "0:42")
        }
    }
}
