import Accelerate
import Foundation

/// A frame of DTS decoded to samples.
public struct DTSDecodedFrame: Equatable, Sendable {
    public let header: DTSCoreHeader
    public let layout: DTSChannelLayout
    /// Interleaved in the layout's order, at a full scale of 1.
    public let samples: [Float]

    public var frames: Int { samples.count / max(1, layout.channels) }
}

/// The two vector code books of ETSI TS 102 114 Annex D.10, which no edition of the specification
/// prints ("Due to its extensive size, this table is not included here").
public struct DTSVectorTables: Sendable {
    /// 4 096 vectors of four ADPCM prediction coefficients, each × 2^13 (D.10.1).
    public let prediction: [Int16]
    /// 1 024 vectors of 32 high-frequency subband samples, each × 2^4 (D.10.2).
    public let highFrequency: [Int8]

    public init?(prediction: [Int16], highFrequency: [Int8]) {
        guard prediction.count == 4096 * 4, highFrequency.count == 1024 * 32 else { return nil }
        self.prediction = prediction
        self.highFrequency = highFrequency
    }

    /// The code books the core carries, from FFmpeg's copy of them
    /// (`scripts/generate_dts_vector_tables.py`), decoded on first use.
    public static let standard: DTSVectorTables = {
        let prediction = Data(base64Encoded: predictionData, options: .ignoreUnknownCharacters) ?? Data(
        )
        let high = Data(base64Encoded: highFrequencyData, options: .ignoreUnknownCharacters) ?? Data(
        )
        let coefficients = stride(from: 0, to: prediction.count - 1, by: 2).map { index in
            Int16(bitPattern: UInt16(prediction[index]) | UInt16(prediction[index + 1]) << 8)
        }
        let samples = high.map { Int8(bitPattern: $0) }
        guard let tables = DTSVectorTables(prediction: coefficients, highFrequency: samples) else {
            preconditionFailure("the generated DTS vector tables do not decode")
        }
        return tables
    }()
}

/// A decoder for the core of DTS Coherent Acoustics (ETSI TS 102 114 §5): up to five primary
/// channels and an LFE channel at up to 48 kHz, which every DTS stream carries, DTS-HD's included.
/// What extensions follow the core (6.1 channels, 96 kHz, DTS-HD's lossless data) are passed over,
/// which is what the core is built for: a player without them plays the core.
///
/// A decoder keeps each channel's filter and prediction history, so frames go through it in order;
/// after a seek, `reset()` starts it afresh.
public struct DTSCoreDecoder: Sendable {
    /// What brings the synthesis filter's output to a full scale of 1. Measured 2026-11-24 against
    /// libavcodec's DTS encoder, whose input level a decode has to give back: read in units of 24-bit
    /// PCM, the filter of Annex C.3.6 gave each tone back 128 √2 below its level (181.02, measured).
    static let outputGain = Float(2.0.squareRoot() / 65536)
    /// The LFE's interpolation filter (C.3.7) is in units of 24-bit PCM as it stands, which
    /// libavcodec's decode of the film's LFE matched to 0.2 %.
    static let lfeGain: Float = 1.0 / 8_388_608

    let vectors: DTSVectorTables?
    /// Each channel's subbands' last four samples, for the prediction: 5 channels × 32 subbands × 4.
    var history = [Float](repeating: 0, count: 5 * 32 * 4)
    private var filters = Array(repeating: DTSSynthesisFilter(), count: 5)
    private var lfe = DTSLFEInterpolator()
    private var layout: DTSChannelLayout?

    /// A decoder using `vectors` for the frames that need them; without, such a frame fails.
    public init(vectors: DTSVectorTables? = .standard) {
        self.vectors = vectors
    }

    public mutating func reset() {
        history = [Float](repeating: 0, count: 5 * 32 * 4)
        for index in filters.indices { filters[index].reset() }
        lfe.reset()
    }

    /// Decodes the core of the frame at the start of `data`.
    public mutating func decode(_ data: Data) throws -> DTSDecodedFrame {
        guard let frame = DTSCoreFrame(data) else { throw DTSError.notDTS }
        var reader = DTSBitReader(frame.bytes)
        let header = try DTSCoreHeader.read(&reader)
        // Table 5-16: a decoder shall mute a revision later than the one it knows.
        guard header.encoderVersion <= 7 else {
            throw DTSError.unsupported("encoder revision \(header.encoderVersion)")
        }
        guard let channels = header.primaryChannels, let layout = header.layout else {
            throw DTSError.unsupported("audio mode \(header.audioMode)")
        }
        let audio = try DTSAudioHeader.read(&reader, header: header, channels: channels)
        if layout != self.layout {
            reset()
            self.layout = layout
        }
        if !header.continuesPrediction {
            history = [Float](repeating: 0, count: 5 * 32 * 4)
        }
        let total = header.samples
        var planar = [Float](repeating: 0, count: channels * total)
        var lfeSamples = [Float](repeating: 0, count: total)
        var position = 0
        for _ in 0..<audio.subframes {
            let info = try DTSSideInfo.read(&reader, header: header, audio: audio)
            if vectors == nil, info.prediction.contains(where: { $0.contains { $0 != nil } }) {
                throw DTSError.unsupported("ADPCM prediction")
            }
            let slots = info.subsubframes * 8
            guard position + slots * 32 <= total else {
                throw DTSError.invalid("subframes longer than the frame's \(header.blocks) blocks")
            }
            var subframe = try readSubframe(
                &reader,
                Syntax(header: header, audio: audio, info: info)
            )
            predict(&subframe, audio: audio, info: info)
            Self.reconstruct(&subframe, header: header, audio: audio, info: info)
            planar.withUnsafeMutableBufferPointer { output in
                subframe.samples.withUnsafeBufferPointer { samples in
                    for channel in 0..<channels {
                        filters[channel].run(
                            DTSSubbandRows(
                                base: samples.baseAddress! + subframe.row(channel, 0) + 4,
                                stride: subframe.stride,
                                count: slots
                            ),
                            perfect: header.perfectReconstruction,
                            gain: Self.outputGain,
                            output: output.baseAddress! + channel * total + position
                        )
                    }
                }
            }
            if let factor = header.lfeInterpolation {
                lfeSamples.withUnsafeMutableBufferPointer { output in
                    lfe.run(
                        subframe.lfe,
                        factor: factor,
                        gain: Self.lfeGain,
                        output: output.baseAddress! + position
                    )
                }
            }
            position += slots * 32
        }
        let samples = Self.interleave(
            planar,
            total: total,
            lfe: lfeSamples,
            layout: layout,
            count: position
        )
        return DTSDecodedFrame(header: header, layout: layout, samples: samples)
    }

    /// The channels, each `total` long in `planar`, as `count` interleaved frames in the layout's order.
    private static func interleave(
        _ planar: [Float],
        total: Int,
        lfe: [Float],
        layout: DTSChannelLayout,
        count: Int
    ) -> [Float] {
        var samples = [Float](repeating: 0, count: count * layout.channels)
        var zero: Float = 0
        samples.withUnsafeMutableBufferPointer { samples in
            for (output, source) in layout.sources.enumerated() {
                let channel = source.map { Array(planar[$0 * total..<$0 * total + count]) } ?? lfe
                vDSP_vsadd(
                    channel,
                    1,
                    &zero,
                    samples.baseAddress! + output,
                    vDSP_Stride(layout.channels),
                    vDSP_Length(count)
                )
            }
        }
        return samples
    }
}
