import AVFoundation
import CoreVideo
import Foundation

/// Files for Quick View's player tests (PLAN.md §M42), written by the system's own encoders so nothing
/// binary is checked in, and small enough to make in a test's time.
enum QuickViewMediaFixtures {
    /// A one-second H.264 movie, 64 × 64 at ten frames a second, each frame a different grey so a
    /// decoder has something to decode.
    nonisolated static func writeMovie(to url: URL) async throws {
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
            let time = CMTime(value: CMTimeValue(frame), timescale: 10)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 10, timescale: 10))
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
