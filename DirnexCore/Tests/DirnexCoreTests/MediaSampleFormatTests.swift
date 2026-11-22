import Foundation
import Testing

@testable import DirnexCore

/// What a decoder is told about a Matroska track (PLAN.md §M42 ▸ Slice 4).
///
/// The cookies are held to bytes the system's own encoders wrote on this Mac (2026-11-20): AAC's
/// magic cookie for 48 kHz stereo and FLAC's `dfLa` box, copied here from the encoders' output, since
/// what the decoder accepts is what the encoder hands out.
@Suite("Media sample formats")
struct MediaSampleFormatTests {
    private func track(
        _ codec: String,
        kind: UInt64 = 2,
        _ configure: (inout MatroskaTrack) -> Void = { _ in }
    )
        -> MatroskaTrack {
        var track = MatroskaTrack()
        track.number = 1
        track.kind = .init(kind)
        track.codecID = codec
        configure(&track)
        return track
    }

    private func audio(_ track: MatroskaTrack) throws -> MediaSampleFormat.Audio {
        guard case let .audio(audio)? = track.sampleFormat() else {
            Issue.record("no audio format for \(track.codecID)")
            throw CancellationError()
        }
        return audio
    }

    private func video(_ track: MatroskaTrack, firstFrame: Data? = nil) throws -> MediaSampleFormat.Video {
        guard case let .video(video)? = track.sampleFormat(firstFrame: firstFrame) else {
            Issue.record("no video format for \(track.codecID)")
            throw CancellationError()
        }
        return video
    }

    @Test("H.264, HEVC and AV1 carry the track's private data as their configuration atom")
    func configuredVideo() throws {
        let record = Data([1, 2, 3, 4])
        for (codec, code, atom) in [
            ("V_MPEG4/ISO/AVC", "avc1", "avcC"), ("V_MPEGH/ISO/HEVC", "hvc1", "hvcC"),
            ("V_AV1", "av01", "av1C")
        ] {
            let format = try video(track(codec, kind: 1) {
                $0.codecPrivate = record
                $0.video = .init(pixelWidth: 1920, pixelHeight: 1080)
            })
            #expect(MediaCodecName.fourCharacterText(format.codec) == code)
            #expect(format.atoms == [atom: record])
            #expect(format.width == 1920 && format.height == 1080)
            #expect(track(codec, kind: 1).sampleFormat() == nil, "\(codec) without its record")
        }
    }

    @Test("the film's H.264 track hands over its avcC as the file wrote it")
    func filmVideo() throws {
        let file = try MatroskaFile(source: SparseCaptureSource(fixture: "film.mkv"))
        let picture = try #require(file.track(number: 1))
        let format = try video(picture)
        #expect(format.atoms["avcC"] == picture.codecPrivate)
        #expect(format.atoms["avcC"]?.prefix(2) == Data([0x01, 0x64]), "version 1, High profile")
        #expect(format.width == 1816 && format.height == 1080)
    }

    @Test("VP9 takes its vpcC from the first key frame, and VP8 is described with none")
    func vp9() throws {
        let file = try MatroskaFile(source: SparseCaptureSource(fixture: "libwebm-opus.webm"))
        let picture = try #require(file.track(number: 1))
        let key = try #require(try file.firstKeyframe(track: 1))
        let format = try video(picture, firstFrame: key)
        #expect(MediaCodecName.fourCharacterText(format.codec) == "vp09")
        let record = try #require(format.atoms["vpcC"])
        #expect(record.count == 12)
        #expect(record.prefix(4) == Data([1, 0, 0, 0]), "version 1, no flags")
        #expect(record[4] == 0, "profile 0")
        #expect(record[5] == 50, "1920×1200 is past level 4's 2 228 224 pixels")
        #expect(record[6] == 8 << 4, "8 bits, 4:2:0, limited range")
        #expect(picture.sampleFormat() == nil, "no key frame, no configuration")
        let vp8 = try video(track("V_VP8", kind: 1))
        #expect(MediaCodecName.fourCharacterText(vp8.codec) == "vp08")
        #expect(vp8.atoms.isEmpty)
    }

    @Test("the fixed-size audio codecs and their frames per packet")
    func plainAudio() throws {
        struct Case {
            let codec: String
            let rate: Double
            let code: String
            let frames: Int
        }
        let cases = [
            Case(codec: "A_AC3", rate: 48000, code: "ac-3", frames: 1536),
            Case(codec: "A_EAC3", rate: 48000, code: "ec-3", frames: 1536),
            Case(codec: "A_DTS", rate: 48000, code: "dtsc", frames: 512),
            Case(codec: "A_MPEG/L3", rate: 44100, code: ".mp3", frames: 1152),
            Case(codec: "A_MPEG/L3", rate: 22050, code: ".mp3", frames: 576),
            Case(codec: "A_MPEG/L2", rate: 48000, code: ".mp2", frames: 1152),
            Case(codec: "A_MPEG/L1", rate: 48000, code: ".mp1", frames: 384)
        ]
        for item in cases {
            let format = try audio(
                track(item.codec) { $0.audio = .init(samplingFrequency: item.rate, channels: 6) }
            )
            #expect(MediaCodecName.fourCharacterText(format.formatID) == item.code)
            #expect(format.framesPerPacket == item.frames, "\(item.codec) at \(item.rate)")
            #expect(format.channels == 6 && format.sampleRate == item.rate)
            #expect(format.magicCookie == nil)
        }
        let ac3 = try audio(track("A_AC3") { $0.audio = .init(samplingFrequency: 48000) })
        #expect(ac3.packetDuration == 32_000_000)
        #expect(track("A_TRUEHD").sampleFormat() == nil)
        #expect(track("S_TEXT/UTF8", kind: 0x11).sampleFormat() == nil)
    }

    @Test("AAC's private data goes into a cookie laid out as the system encoder's own")
    func aacCookie() throws {
        let format = try audio(track("A_AAC") {
            $0.codecPrivate = Data([0x11, 0x90])
            $0.audio = .init(samplingFrequency: 48000, channels: 2)
        })
        // The encoder's cookie with its buffer size and bit rates (001800 0001f400 0001f400) zeroed.
        let encoder = "038080802200000004808080144015000000000000000000000005808080021190068080800102"
        #expect(format.magicCookie.map(hex) == encoder)
        #expect(MediaCodecName.fourCharacterText(format.formatID) == "aac ")
        #expect(format.framesPerPacket == 1024)
    }

    @Test("the old AAC IDs that name a profile get an AudioSpecificConfig made for them")
    func aacFromCodecID() throws {
        let sbr = try audio(
            track("A_AAC/MPEG4/LC/SBR") { $0.audio = .init(samplingFrequency: 24000, channels: 2) }
        )
        // Object type 2, rate index 6 (24 kHz), two channels.
        #expect(sbr.magicCookie.map { hex($0.suffix(8).prefix(2)) } == "1310")
        let main = AACConfiguration.audioSpecificConfig(
            codecID: "A_AAC/MPEG2/MAIN",
            sampleRate: 44100,
            channels: 1
        )
        #expect(main.map(hex) == "0a08")
        #expect(
            AACConfiguration.audioSpecificConfig(
                codecID: "A_AAC/MPEG4/LC",
                sampleRate: 12345,
                channels: 2
            ) == nil
        )
        #expect(track("A_AAC") { $0.audio = .init(samplingFrequency: 48000) }.sampleFormat() == nil)
    }

    @Test("FLAC's STREAMINFO goes into a dfLa box laid out as the system encoder's own")
    func flacCookie() throws {
        // The encoder's STREAMINFO: 4096-frame blocks, 48 kHz, two channels, 16 bits.
        let streamInfo = "100010000000000000000bb802f00000000000000000000000000000000000000000"
        let codecPrivate = Data(Array("fLaC".utf8)) + Data([0x00, 0x00, 0x00, 0x22]) + bytes(
            streamInfo
        )
            + Data([0x84, 0x00, 0x00, 0x02, 0xAA, 0xBB])
        let format = try audio(track("A_FLAC") {
            $0.codecPrivate = codecPrivate
            $0.audio = .init(samplingFrequency: 48000, channels: 2)
        })
        #expect(format.magicCookie.map(hex) == "0000003264664c610000000080000022" + streamInfo)
        #expect(format.framesPerPacket == 4096)
        #expect(track("A_FLAC") { $0.codecPrivate = Data("fLaC".utf8) }.sampleFormat() == nil)
    }

    @Test("Opus decodes at 48 kHz with OpusHead as its cookie, and Vorbis with its laced headers")
    func opusAndVorbis() throws {
        let file = try MatroskaFile(source: SparseCaptureSource(fixture: "libwebm-opus.webm"))
        let opus = try audio(try #require(file.track(number: 2)))
        #expect(opus.sampleRate == 48000 && opus.framesPerPacket == 0)
        #expect(opus.magicCookie?.prefix(8) == Data("OpusHead".utf8))

        let headers = try fixture("prism-vorbis", "private")
        let vorbis = try audio(track("A_VORBIS") {
            $0.codecPrivate = headers
            $0.audio = .init(samplingFrequency: 48000, channels: 2)
        })
        #expect(
            vorbis.magicCookie == headers,
            "the decoder's cookie is Matroska's lacing, as AudioFile reads an Ogg's"
        )
        #expect(vorbis.framesPerPacket == 0)
        #expect(
            track("A_VORBIS") { $0.codecPrivate = Data([2, 1, 1, 0, 0, 0]) }.sampleFormat() == nil
        )
    }

    @Test("PCM keeps its byte order, its depth and whether it is float")
    func pcm() throws {
        let little = try audio(
            track("A_PCM/INT/LIT") { $0.audio = .init(channels: 2, bitDepth: 24) }
        )
        #expect(little.pcm == .init(bitsPerSample: 24, isFloat: false, isBigEndian: false))
        #expect(little.pcm?.bytesPerFrame(channels: 2) == 6)
        let big = try audio(track("A_PCM/INT/BIG") { $0.audio = .init(bitDepth: 16) })
        #expect(big.pcm?.isBigEndian == true)
        let float = try audio(track("A_PCM/FLOAT/IEEE") { $0.audio = .init(bitDepth: 32) })
        #expect(float.pcm?.isFloat == true)
        #expect(track("A_PCM/FLOAT/IEEE") { $0.audio = .init(bitDepth: 16) }.sampleFormat() == nil)
        #expect(track("A_PCM/INT/LIT") { $0.audio = .init(bitDepth: 12) }.sampleFormat() == nil)
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func bytes(_ hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    private func fixture(_ name: String, _ ext: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: ext,
                subdirectory: "Fixtures/Matroska"
            )
        )
        return try Data(contentsOf: url)
    }
}
