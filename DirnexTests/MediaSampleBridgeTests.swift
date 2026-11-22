import AVFoundation
import DirnexCore
import Testing
import VideoToolbox

@testable import Dirnex

/// The core's sample formats as the system's decoders take them (PLAN.md §M42 ▸ Slice 4): packets the
/// system's own encoders wrote go through the core's configuration and `MediaSampleBridge`, and come
/// out of AudioToolbox and VideoToolbox as what went in. A tone loud enough that a decoder producing
/// silence fails, and every picture counted.
///
/// AudioToolbox also decodes AAC handed the bare `AudioSpecificConfig` as its cookie (a negative
/// control on 2026-11-20 passed), so the encoder-shaped cookie is pinned by the core's byte test, not
/// here.
@Suite("Media sample bridge")
@MainActor
struct MediaSampleBridgeTests {
    @Test("AAC from the system's encoder decodes through the core's cookie to the tone it was")
    func aacDecodes() throws {
        let encoded = try MatroskaFixtures.encode(kAudioFormatMPEG4AAC, seconds: 0.5, amplitude: 0.5)
        var track = MatroskaTrack()
        track.kind = .audio
        track.codecID = "A_AAC"
        track.codecPrivate = try MatroskaFixtures.audioSpecificConfig(fromCookie: encoded.cookie)
        track.audio = MatroskaTrack.Audio(samplingFrequency: 48000, channels: 2)
        let format = try #require(track.sampleFormat())
        #expect(MediaSampleBridge.canDecode(format))
        let peak = try decodedPeak(format, encoded.packets.map(\.data), frames: nil)
        #expect(abs(peak - 0.5) < 0.05, "peak \(peak)")
    }

    @Test("Opus packets of varying length decode with their counts and OpusHead as the cookie")
    func opusDecodes() throws {
        var packets: [Data] = []
        for framesPerPacket in [UInt32(960), 480, 1920] {
            packets += try MatroskaFixtures.encode(
                kAudioFormatOpus,
                seconds: 0.3,
                amplitude: 0.5,
                framesPerPacket: framesPerPacket
            ).packets.map(\.data)
        }
        // OpusHead: version 1, two channels, no pre-skip, 48 kHz, no gain, mapping family 0.
        let head = Data("OpusHead".utf8) + Data([1, 2, 0, 0, 0x80, 0xBB, 0, 0, 0, 0, 0])
        var track = MatroskaTrack()
        track.kind = .audio
        track.codecID = "A_OPUS"
        track.codecPrivate = head
        track.audio = MatroskaTrack.Audio(samplingFrequency: 48000, channels: 2)
        let format = try #require(track.sampleFormat())
        let counts = packets.map { OpusPacket.frames($0) ?? 0 }
        #expect(Set(counts) == [480, 960, 1920])
        let peak = try decodedPeak(format, packets, frames: counts)
        #expect(abs(peak - 0.5) < 0.1, "peak \(peak)")
    }

    @Test("H.264 decodes through the core's avcC, and VP8 is refused before a frame is read")
    func pictures() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let mp4 = tree.root.appendingPathComponent("clip.mp4")
        try await QuickViewMediaFixtures.writeMovie(to: mp4)
        let h264 = try await MatroskaFixtures.h264Track(from: mp4)
        var track = MatroskaTrack()
        track.kind = .video
        track.codecID = h264.codecID
        track.codecPrivate = h264.codecPrivate
        var video = MatroskaTrack.Video()
        video.pixelWidth = 64
        video.pixelHeight = 64
        track.video = video
        let format = try #require(track.sampleFormat())
        #expect(MediaSampleBridge.canDecode(format))
        let description = try #require(MediaSampleBridge.formatDescription(format))
        var session: VTDecompressionSession?
        #expect(VTDecompressionSessionCreate(
            allocator: nil,
            formatDescription: description,
            decoderSpecification: nil,
            imageBufferAttributes: nil,
            outputCallback: nil,
            decompressionSessionOut: &session
        ) == noErr)
        let decoder = try #require(session)
        defer { VTDecompressionSessionInvalidate(decoder) }
        var decoded = 0
        for (index, packet) in h264.packets.enumerated() {
            let media = MediaPacket(
                track: 1,
                time: Int64(packet.milliseconds) * 1_000_000,
                duration: 100_000_000,
                data: packet.data,
                isKeyframe: packet.isKeyframe,
                frameCount: nil,
                isPreroll: false
            )
            let sample = try #require(
                MediaSampleBridge.sampleBuffer(media, description: description, audio: nil)
            )
            let status = VTDecompressionSessionDecodeFrame(
                decoder,
                sampleBuffer: sample,
                flags: [],
                infoFlagsOut: nil
            ) { status, _, image, _, _ in
                if status == noErr, image != nil { decoded += 1 }
            }
            #expect(status == noErr, "frame \(index)")
        }
        VTDecompressionSessionWaitForAsynchronousFrames(decoder)
        #expect(decoded == h264.packets.count)

        var vp8 = track
        vp8.codecID = "V_VP8"
        #expect(!MediaSampleBridge.canDecode(try #require(vp8.sampleFormat())))
    }

    /// The loudest sample of `packets` decoded as `format` by AudioToolbox, through the format
    /// description the bridge makes, with `frames` as each packet's count where packets differ.
    private func decodedPeak(_ format: MediaSampleFormat, _ packets: [Data], frames: [Int]?) throws -> Float {
        let description = try #require(MediaSampleBridge.formatDescription(format))
        let input = AVAudioFormat(cmAudioFormatDescription: description)
        let output = try #require(
            AVAudioFormat(standardFormatWithSampleRate: input.sampleRate, channels: 2)
        )
        let converter = try #require(AVAudioConverter(from: input, to: output))
        let largest = packets.map(\.count).max() ?? 1
        var next = 0
        var peak: Float = 0
        while next < packets.count {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 8192))
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error) { _, state in
                guard next < packets.count else {
                    state.pointee = .endOfStream
                    return nil
                }
                let packet = packets[next]
                let compressed = AVAudioCompressedBuffer(
                    format: input,
                    packetCapacity: 1,
                    maximumPacketSize: largest
                )
                packet.copyBytes(
                    to: compressed.data.assumingMemoryBound(to: UInt8.self),
                    count: packet.count
                )
                compressed.byteLength = UInt32(packet.count)
                compressed.packetCount = 1
                compressed.packetDescriptions?[0] = AudioStreamPacketDescription(
                    mStartOffset: 0,
                    mVariableFramesInPacket: UInt32(frames?[next] ?? 0),
                    mDataByteSize: UInt32(packet.count)
                )
                next += 1
                state.pointee = .haveData
                return compressed
            }
            #expect(error == nil)
            if let channel = buffer.floatChannelData?[0] {
                for index in 0..<Int(buffer.frameLength) { peak = max(peak, abs(channel[index])) }
            }
            if status == .error || status == .endOfStream { break }
        }
        return peak
    }
}
