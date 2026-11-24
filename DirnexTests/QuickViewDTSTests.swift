import AppKit
import AVFoundation
import CoreMedia
import DirnexCore
import Testing

@testable import Dirnex

/// DTS in Quick View (PLAN.md §M42 ▸ DTS): no Mac decodes it, so the core does, and the player hands
/// the system PCM. The sound is the core's own fixture, test tones libavcodec's DTS encoder wrote in 5.1
/// with prediction (`DTSCoreDecoderTests`), read from where it lies, as `ZstdArchiveTests` reads its own.
@Suite("Quick View DTS")
@MainActor
struct QuickViewDTSTests {
    private static let budget = Duration.seconds(60)

    /// The core's 5.1 fixture's frames, two frames 10.667 ms apart, repeated to fill `seconds`.
    nonisolated static func dtsPackets(seconds: Int) throws -> [MatroskaFixtures.Packet] {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "DirnexCore/Tests/DirnexCoreTests/Fixtures/DTS/lavc-51-adpcm.dts")
        let stream = try Data(contentsOf: url)
        var frames: [Data] = []
        var offset = stream.startIndex
        while offset < stream.endIndex, let header = DTSCoreHeader(stream[offset...]) {
            frames.append(stream[offset..<offset + header.frameSize])
            offset += header.frameSize
        }
        let count = seconds * 48000 / 512
        return (0..<count).map { index in
            MatroskaFixtures.Packet(
                data: frames[index % frames.count],
                milliseconds: Int((Double(index) * 512 / 48).rounded())
            )
        }
    }

    /// An H.264 film with `sounds` beside it, numbered from 2: "dts" is the fixture's DTS, "aac" silence
    /// AudioToolbox encoded.
    private func film(in tree: TempDirectory, seconds: Int, sounds: [String]) async throws -> URL {
        let url = tree.root.appendingPathComponent("film.mkv")
        let mp4 = tree.root.appendingPathComponent("film.source.mp4")
        try await QuickViewMediaFixtures.writeMovie(to: mp4, seconds: seconds)
        var tracks = [try await MatroskaFixtures.h264Track(from: mp4)]
        for (offset, sound) in sounds.enumerated() {
            let number = UInt64(2 + offset)
            if sound == "dts" {
                var track = MatroskaFixtures.Track(
                    number: number,
                    isVideo: false,
                    codecID: "A_DTS",
                    codecPrivate: nil,
                    packets: try Self.dtsPackets(seconds: seconds)
                )
                track.channels = 6
                track.language = "eng"
                tracks.append(track)
            } else {
                let aac = try MatroskaFixtures.encode(
                    kAudioFormatMPEG4AAC,
                    seconds: Double(seconds),
                    amplitude: 0
                )
                var track = MatroskaFixtures.Track(
                    number: number,
                    isVideo: false,
                    codecID: "A_AAC",
                    codecPrivate: try MatroskaFixtures.audioSpecificConfig(fromCookie: aac.cookie),
                    packets: aac.packets
                )
                track.language = "rus"
                tracks.append(track)
            }
        }
        try MatroskaFixtures.write(tracks, duration: Double(seconds), to: url)
        return url
    }

    private func surface() -> QuickViewPreviewView {
        let view = QuickViewPreviewView(
            backingColor: .black,
            header: .pinned,
            findOptions: QuickViewFindOptionsStore.scratch()
        )
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func show(_ url: URL, on view: QuickViewPreviewView) async throws -> QuickViewMediaView {
        view.show(url, style: .default)
        view.setCaption(QuickViewCaption(name: url.lastPathComponent, position: 1, count: 3))
        try await settleUntil(within: Self.budget) { !view.flipGate.isLoading }
        view.layoutSubtreeIfNeeded()
        return try #require(view.mediaView)
    }

    @Test("a film whose sound is DTS plays it: the core decodes, the system takes the PCM")
    func plays() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let view = surface()
        let media = try await show(try film(in: tree, seconds: 60, sounds: ["dts"]), on: view)
        let player = try #require(media.sampleBufferPlayer, "the core's player, not the card")
        let sound = try #require(player.preparation.audio)
        #expect(sound.number == 2)
        let audio = try #require(sound.audio)
        #expect(
            audio.formatID == kAudioFormatLinearPCM && audio.channels == 6 && audio.pcm?.isFloat == true
        )
        #expect(view.headerView?.caption?.media?.facts == "64×64 · H.264 · DTS")
        media.togglePlayback()
        try await settleUntil(within: Self.budget) { player.currentSeconds > 0.5 }
        #expect(player.audioError == nil, "the sound renderer took the decoded DTS")
        media.togglePlayback()
    }

    @Test("beside AAC, the DTS track is in the menu as one that plays, and a pick plays it")
    func switchesToDTS() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let view = surface()
        let media = try await show(try film(in: tree, seconds: 60, sounds: ["aac", "dts"]), on: view)
        let player = try #require(media.sampleBufferPlayer)
        #expect(media.sounds.map(\.isDecodable) == [true, true])
        #expect(media.sounds.last?.codec == "DTS")
        media.togglePlayback()
        try await settleUntil(within: Self.budget) { player.currentSeconds > 0.3 }
        let before = player.currentSeconds
        media.selectSound(3)
        try await settleUntil(within: Self.budget) { player.currentSeconds > before + 0.5 }
        #expect(media.playingSound == 3)
        #expect(player.audioError == nil, "the renderer took PCM after AAC")
        media.togglePlayback()
    }

    @Test(
        "the layouts the core names by number are Core Audio's, and the bridge hands the system the right one"
    )
    func layoutTags() throws {
        // By audio mode: the layout without the LFE, then with it.
        let expected: [Int: [AudioChannelLayoutTag]] = [
            0: [kAudioChannelLayoutTag_Mono, kAudioChannelLayoutTag_DVD_4],
            2: [kAudioChannelLayoutTag_Stereo, kAudioChannelLayoutTag_DVD_4],
            5: [kAudioChannelLayoutTag_MPEG_3_0_A, kAudioChannelLayoutTag_DVD_10],
            6: [kAudioChannelLayoutTag_ITU_2_1, kAudioChannelLayoutTag_DVD_5],
            7: [kAudioChannelLayoutTag_MPEG_4_0_A, kAudioChannelLayoutTag_DVD_11],
            8: [kAudioChannelLayoutTag_Quadraphonic, kAudioChannelLayoutTag_DVD_6],
            9: [kAudioChannelLayoutTag_MPEG_5_0_A, kAudioChannelLayoutTag_MPEG_5_1_A]
        ]
        for (mode, tags) in expected {
            #expect(DTSChannelLayout(audioMode: mode, hasLFE: false)?.tag == tags[0], "mode \(mode)")
            #expect(
                DTSChannelLayout(audioMode: mode, hasLFE: true)?.tag == tags[1],
                "mode \(mode) and LFE"
            )
        }
        let frame = try #require(try Self.dtsPackets(seconds: 1).first?.data)
        let format = try #require(MediaSampleFormat.Audio.decodedDTS(firstFrame: frame))
        let description = try #require(MediaSampleBridge.audioDescription(format))
        var size = 0
        let layout = try #require(
            CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &size)
        )
        #expect(layout.pointee.mChannelLayoutTag == kAudioChannelLayoutTag_MPEG_5_1_A)
        #expect(MediaSampleBridge.canDecode(.audio(format)))
        // Where the order is not the usual one for the count, the tag is what says so: L R LFE Ls Rs
        // against the five channels' usual L R C Ls Rs.
        var quad = format
        quad.channels = 5
        quad.channelLayoutTag = try #require(DTSChannelLayout(audioMode: 8, hasLFE: true)).tag
        let quadDescription = try #require(MediaSampleBridge.audioDescription(quad))
        let quadLayout = try #require(
            CMAudioFormatDescriptionGetChannelLayout(quadDescription, sizeOut: &size)
        )
        #expect(quadLayout.pointee.mChannelLayoutTag == kAudioChannelLayoutTag_DVD_6)
    }
}
