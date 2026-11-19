import AVFoundation
import CoreVideo
import Foundation

/// Files for Quick View's player tests (PLAN.md §M42), written by the system's own encoders so nothing
/// binary is checked in, and small enough to make in a test's time.
enum QuickViewMediaFixtures {
    /// An H.264 movie `seconds` long, 64 × 64 in ten frames, each frame a different grey so a decoder
    /// has something to decode. One second unless a test needs playback to outlast a slow poll: under
    /// a full run the main actor has been seen to wait past ten seconds for its turn.
    nonisolated static func writeMovie(to url: URL, seconds: Int = 1) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 64,
                AVVideoHeightKey: 64
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            let buffer = try pixelBuffer(grey: UInt8(40 + frame * 20))
            let time = CMTime(value: CMTimeValue(frame * seconds), timescale: 10)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(10 * seconds), timescale: 10))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }

    /// A one-second mono WAV of silence.
    nonisolated static func writeSound(to url: URL) throws {
        let format = try AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)
            .orThrow()
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100).orThrow()
        buffer.frameLength = 44100
        try file.write(from: buffer)
    }

    /// The first bytes of a Matroska file: an EBML header naming the `matroska` doc type and the start
    /// of a segment, which is a file AVFoundation refuses (PLAN.md §M42 ▸ P0).
    static let matroskaHeader = Data([
        0x1A, 0x45, 0xDF, 0xA3, 0xA3, // EBML, 35 bytes
        0x42, 0x86, 0x81, 0x01, // EBMLVersion 1
        0x42, 0xF7, 0x81, 0x01, // EBMLReadVersion 1
        0x42, 0xF2, 0x81, 0x04, // EBMLMaxIDLength 4
        0x42, 0xF3, 0x81, 0x08, // EBMLMaxSizeLength 8
        0x42, 0x82, 0x88, 0x6D, 0x61, 0x74, 0x72, 0x6F, 0x73, 0x6B, 0x61, // DocType "matroska"
        0x42, 0x87, 0x81, 0x04, // DocTypeVersion 4
        0x42, 0x85, 0x81, 0x02, // DocTypeReadVersion 2
        // Segment, of unknown size.
        0x18, 0x53, 0x80, 0x67, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
    ])

    /// `matroskaHeader` with the head of a film after it: an `Info` and the `Tracks` of an H.264
    /// picture, an AC-3 and a DTS sound and a subtitle, in the shape the film in `~/Movies` has
    /// (PLAN.md §M42 ▸ Slice 3). No cluster follows, which the card does not need.
    static let matroskaHead = matroskaHeader + Data([
        // Info: TimestampScale 1 000 000, Duration 5 723 872 ticks as a four-byte float.
        0x15, 0x49, 0xA9, 0x66, 0x8E, 0x2A, 0xD7, 0xB1, 0x83, 0x0F, 0x42, 0x40,
        0x44, 0x89, 0x84, 0x4A, 0xAE, 0xAD, 0xC0,
        // Tracks.
        0x16, 0x54, 0xAE, 0x6B, 0xD6,
        // 1: video, V_MPEG4/ISO/AVC, 1816 × 1080.
        0xAE, 0xA1, 0xD7, 0x81, 0x01, 0x83, 0x81, 0x01, 0x86, 0x8F,
        0x56, 0x5F, 0x4D, 0x50, 0x45, 0x47, 0x34, 0x2F, 0x49, 0x53, 0x4F, 0x2F, 0x41, 0x56, 0x43,
        0xE0, 0x88, 0xB0, 0x82, 0x07, 0x18, 0xBA, 0x82, 0x04, 0x38,
        // 2: audio, A_AC3.
        0xAE, 0x8D, 0xD7, 0x81, 0x02, 0x83, 0x81, 0x02, 0x86, 0x85, 0x41, 0x5F, 0x41, 0x43, 0x33,
        // 3: audio, A_DTS.
        0xAE, 0x8D, 0xD7, 0x81, 0x03, 0x83, 0x81, 0x02, 0x86, 0x85, 0x41, 0x5F, 0x44, 0x54, 0x53,
        // 4: subtitles, S_TEXT/UTF8.
        0xAE, 0x93, 0xD7, 0x81, 0x04, 0x83, 0x81, 0x11, 0x86, 0x8B,
        0x53, 0x5F, 0x54, 0x45, 0x58, 0x54, 0x2F, 0x55, 0x54, 0x46, 0x38
    ])

    private nonisolated static func pixelBuffer(grey: UInt8) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &made)
        let buffer = try made.orThrow()
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try CVPixelBufferGetBaseAddress(buffer).orThrow()
        memset(base, Int32(grey), CVPixelBufferGetBytesPerRow(buffer) * 64)
        return buffer
    }
}

private extension Optional {
    nonisolated func orThrow() throws -> Wrapped {
        guard let self else { throw CocoaError(.fileWriteUnknown) }
        return self
    }
}
