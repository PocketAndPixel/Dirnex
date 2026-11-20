import Foundation

/// The header of one frame of compressed sound, found in a byte stream (PLAN.md §M42 ▸ Slice 5).
///
/// An AVI's sound chunks are slices of the stream, not frames: a constant-rate MP3 track is often cut
/// every so many bytes, wherever the cut falls, and a chunk can hold several frames. A sample buffer
/// holds whole frames, so the stream is cut again where each frame's header says it ends.
struct AudioFrameHeader: Equatable, Sendable {
    /// How the frames are found.
    enum Syntax: Equatable, Sendable {
        /// MPEG-1 and MPEG-2 audio, layers I to III (ISO/IEC 11172-3, 13818-3).
        case mpeg
        /// AC-3 (ATSC A/52), its syncframes alone: E-AC-3 is not read here.
        case ac3
        /// AAC behind ADTS headers (ISO/IEC 13818-7 §6.2), which the decoder does not want.
        case adts
    }

    /// The whole frame's length, its header included.
    let length: Int
    /// Bytes of header to take off before the decoder sees the frame: ADTS's alone.
    let headerLength: Int
    /// Sound frames (samples per channel) in it.
    let samples: Int
    let sampleRate: Int
    let channels: Int
    /// MPEG audio's layer, 1 to 3.
    var layer: Int?
    /// For ADTS, the configuration its header describes.
    var audioSpecificConfig: Data?

    /// The first header in `bytes` that the bytes bear out: the next header follows where it says it
    /// ends, or it ends exactly where the bytes do. A raw AAC frame holds a pattern that reads as an
    /// ADTS header often enough (seen 2026-11-20 in an AVI made from the 3GP sample's AAC: the first
    /// such pattern gave three-block "frames" and a wrong configuration), so one alone proves nothing.
    static func confirmed(in bytes: [UInt8], syntax: Syntax) -> (
        index: Int,
        header: AudioFrameHeader
    )? {
        for index in bytes.indices {
            guard let header = parse(bytes, at: index, syntax: syntax) else { continue }
            let end = index + header.length
            if end == bytes.count || parse(bytes, at: end, syntax: syntax) != nil {
                return (index, header)
            }
        }
        return nil
    }

    /// The header at `index` of `bytes`, or `nil` when none starts there.
    static func parse(_ bytes: [UInt8], at index: Int, syntax: Syntax) -> AudioFrameHeader? {
        guard index + 7 <= bytes.count else { return nil }
        let head = Array(bytes[index..<index + 7])
        return switch syntax {
        case .mpeg: mpeg(head)
        case .ac3: ac3(head)
        case .adts: adts(head)
        }
    }

    /// Kilobits per second by version, layer and index (MPEG-1's three layers, then MPEG-2 and 2.5's
    /// layer I and layers II and III).
    private static let mpegRates: [[Int]] = [
        [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448],
        [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],
        [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],
        [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256],
        [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
    ]

    private static func mpeg(_ head: [UInt8]) -> AudioFrameHeader? {
        guard head[0] == 0xFF, head[1] & 0xE0 == 0xE0 else { return nil }
        let version = Int(head[1] >> 3 & 3)
        let layer = 4 - Int(head[1] >> 1 & 3)
        let rateIndex = Int(head[2] >> 4)
        let frequencyIndex = Int(head[2] >> 2 & 3)
        guard version != 1, layer != 4, (1...14).contains(rateIndex), frequencyIndex != 3 else {
            return nil
        }
        let isVersion1 = version == 3
        let table = isVersion1 ? layer - 1 : (layer == 1 ? 3 : 4)
        let bitRate = mpegRates[table][rateIndex] * 1000
        let sampleRate = [44100, 48000, 32000][frequencyIndex] >> (
            isVersion1 ? 0 : version == 2 ? 1 : 2
        )
        let padding = Int(head[2] >> 1 & 1)
        let length: Int
        let samples: Int
        switch layer {
        case 1:
            length = (12 * bitRate / sampleRate + padding) * 4
            samples = 384
        case 2:
            length = 144 * bitRate / sampleRate + padding
            samples = 1152
        default:
            length = (isVersion1 ? 144 : 72) * bitRate / sampleRate + padding
            samples = isVersion1 ? 1152 : 576
        }
        var header = AudioFrameHeader(
            length: length,
            headerLength: 0,
            samples: samples,
            sampleRate: sampleRate,
            channels: head[3] >> 6 == 3 ? 1 : 2
        )
        header.layer = layer
        return header
    }

    private static let ac3Rates = [
        32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 576, 640
    ]

    /// A/52 §5.4.1: the frame's size in 16-bit words is its bit rate over its sample rate, times
    /// 96 000; at 44.1 kHz, where that does not come out even, an odd `frmsizecod` adds a word.
    private static func ac3(_ head: [UInt8]) -> AudioFrameHeader? {
        guard head[0] == 0x0B, head[1] == 0x77 else { return nil }
        let frequencyCode = Int(head[4] >> 6)
        let sizeCode = Int(head[4] & 0x3F)
        let streamID = Int(head[5] >> 3)
        guard frequencyCode != 3, sizeCode < 38, streamID <= 10 else { return nil }
        let sampleRate = [48000, 44100, 32000][frequencyCode]
        var words = ac3Rates[sizeCode / 2] * 96000 / sampleRate
        if frequencyCode == 1 { words += sizeCode & 1 }
        var bits = ForwardBitReader(Array(head[6...]))
        let mode = bits.read(3)
        if mode & 1 == 1, mode != 1 { _ = bits.read(2) }
        if mode & 4 == 4 { _ = bits.read(2) }
        if mode == 2 { _ = bits.read(2) }
        let lowFrequency = bits.read(1)
        return AudioFrameHeader(
            length: words * 2,
            headerLength: 0,
            samples: 1536,
            sampleRate: sampleRate,
            channels: [2, 1, 2, 3, 3, 4, 4, 5][mode] + lowFrequency
        )
    }

    private static let adtsRates = [
        96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350
    ]

    private static func adts(_ head: [UInt8]) -> AudioFrameHeader? {
        guard head[0] == 0xFF, head[1] & 0xF6 == 0xF0 else { return nil }
        let headerLength = head[1] & 1 == 1 ? 7 : 9
        let objectType = Int(head[2] >> 6) + 1
        let rateIndex = Int(head[2] >> 2 & 0xF)
        let channelConfiguration = Int(head[2] & 1) << 2 | Int(head[3] >> 6)
        let length = Int(head[3] & 3) << 11 | Int(head[4]) << 3 | Int(head[5] >> 5)
        guard rateIndex < adtsRates.count, length > headerLength else { return nil }
        let blocks = Int(head[6] & 3) + 1
        // 5 bits of object type, 4 of rate index, 4 of channel configuration, three zero bits.
        let config = UInt16(objectType) << 11 | UInt16(rateIndex) << 7 | UInt16(channelConfiguration) << 3
        var header = AudioFrameHeader(
            length: length,
            headerLength: headerLength,
            samples: 1024 * blocks,
            sampleRate: adtsRates[rateIndex],
            channels: channelConfiguration == 7 ? 8 : max(1, channelConfiguration)
        )
        header.audioSpecificConfig = Data([UInt8(config >> 8), UInt8(config & 0xFF)])
        return header
    }
}

/// Cuts a stream of compressed sound into frames, carrying a frame that runs past one chunk into the
/// next (PLAN.md §M42 ▸ Slice 5).
///
/// It finds a frame by its header and believes it when the next frame's header follows where the
/// first says it ends, or when the bytes end first: a byte pattern that looks like a header turns up
/// inside the data now and then. Bytes that start no frame are passed over, as a decoder would.
struct AudioFrameSplitter: Sendable {
    let syntax: AudioFrameHeader.Syntax
    private var pending: [UInt8] = []

    init(syntax: AudioFrameHeader.Syntax) {
        self.syntax = syntax
    }

    /// Whether no part of a frame is waiting for the next chunk.
    var isEmpty: Bool { pending.isEmpty }

    /// Forget what is waiting, as after a seek.
    mutating func reset() {
        pending = []
    }

    /// One frame, its header still on.
    struct Frame: Equatable {
        let data: Data
        let header: AudioFrameHeader
        /// Where it starts, counted from the first byte of the chunk that completed it: below zero for
        /// a frame begun in an earlier chunk.
        let offset: Int
    }

    /// The frames `data` completes.
    mutating func append(_ data: Data) -> [Frame] {
        let carried = pending.count
        pending.append(contentsOf: data)
        var frames: [Frame] = []
        var index = 0
        while index + 7 <= pending.count {
            guard let header = AudioFrameHeader.parse(pending, at: index, syntax: syntax) else {
                index += 1
                continue
            }
            let end = index + header.length
            guard end <= pending.count else { break }
            if end + 7 <= pending.count, AudioFrameHeader.parse(pending, at: end, syntax: syntax) == nil {
                index += 1
                continue
            }
            frames.append(
                Frame(data: Data(pending[index..<end]), header: header, offset: index - carried)
            )
            index = end
        }
        pending.removeFirst(min(index, pending.count))
        // A stream that never syncs keeps no more than a frame's worth of bytes waiting.
        if pending.count > 65536 { pending.removeFirst(pending.count - 7) }
        return frames
    }
}
