import Accelerate
import Foundation

extension DTSCoreDecoder {
    /// A subframe's subband samples: for each channel 32 rows of `stride` values, four of prediction
    /// history and then the subframe's own.
    struct Subframe {
        var samples: [Float]
        let stride: Int
        var lfe: [Float] = []

        /// Where the row of `channel`'s `band` starts.
        func row(_ channel: Int, _ band: Int) -> Int { (channel * 32 + band) * stride }
    }

    /// What a subframe's audio data is read with: the frame's two headers and the subframe's side
    /// information.
    struct Syntax {
        let header: DTSCoreHeader
        let audio: DTSAudioHeader
        let info: DTSSideInfo
    }

    /// The subframe's high-frequency vectors, its LFE samples and its subsubframes (Table 5-29).
    func readSubframe(_ reader: inout DTSBitReader, _ syntax: Syntax) throws -> Subframe {
        let header = syntax.header, audio = syntax.audio, info = syntax.info
        let stride = 4 + info.subsubframes * 8
        var subframe = Subframe(
            samples: [Float](repeating: 0, count: audio.channels * 32 * stride),
            stride: stride
        )
        try subframe.samples.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            history.withUnsafeBufferPointer { history in
                for channel in 0..<audio.channels {
                    for band in 0..<32 {
                        (base + (channel * 32 + band) * stride).update(
                            from: history.baseAddress! + (channel * 32 + band) * 4,
                            count: 4
                        )
                    }
                }
            }
            for channel in 0..<audio.channels {
                for band in audio.vqStart[channel]..<audio.subbands[channel] {
                    let index = try reader.bits(10)
                    guard let vectors else { throw DTSError.unsupported(
                        "high-frequency vector quantization"
                    ) }
                    // D.10.2's samples are × 2^4, scaled by the subband's scale factor alone.
                    let gain = info.scales[channel][band] / 16
                    let row = base + (channel * 32 + band) * stride + 4
                    for slot in 0..<stride - 4 {
                        row[slot] = Float(vectors.highFrequency[index * 32 + slot]) * gain
                    }
                }
            }
        }
        subframe.lfe = try Self.readLFE(&reader, header: header, info: info)
        try subframe.samples.withUnsafeMutableBufferPointer { buffer in
            for subsubframe in 0..<info.subsubframes {
                try Self.readSubsubframe(
                    &reader,
                    subsubframe,
                    into: buffer.baseAddress!,
                    stride: stride,
                    syntax
                )
                if subsubframe == info.subsubframes - 1 || header.syncEverySubsubframe {
                    guard try reader.bits(16) == 0xFFFF else { throw DTSError.invalid("DSYNC") }
                }
            }
        }
        return subframe
    }

    /// The subframe's decimated LFE samples, scaled (§5.6).
    private static func readLFE(
        _ reader: inout DTSBitReader,
        header: DTSCoreHeader,
        info: DTSSideInfo
    ) throws -> [Float] {
        guard let factor = header.lfeInterpolation else { return [] }
        let count = (factor == 128 ? 2 : 4) * info.subsubframes
        var raw: [Int] = []
        for _ in 0..<count { raw.append(try reader.signed(8)) }
        let index = try reader.bits(8)
        guard index < 125 else { throw DTSError.invalid("LFE scale index \(index)") }
        // The LFE samples' quantizer step is 0.035.
        let gain = Float(DTSTables.scaleFactors7[index]) * 0.035
        return raw.map { Float($0) * gain }
    }

    /// Eight samples of each coded subband, scaled by its quantizer's step and its scale factor.
    private static func readSubsubframe(
        _ reader: inout DTSBitReader,
        _ subsubframe: Int,
        into base: UnsafeMutablePointer<Float>,
        stride: Int,
        _ syntax: Syntax
    ) throws {
        let header = syntax.header, audio = syntax.audio, info = syntax.info
        let steps = header.rateCode == 31 ? DTSTables.losslessStepSizes : DTSTables.lossyStepSizes
        for channel in 0..<audio.channels {
            for band in 0..<audio.vqStart[channel] {
                let bits = info.bits[channel][band]
                guard bits > 0 else { continue }
                let transient = info.transient[channel][band]
                let scale = transient == 0 || subsubframe < transient
                    ? info.scales[channel][band]
                    : info.scalesAfter[channel][band]
                let adjustment = bits <= 10 ? audio.adjustment[channel][bits - 1] : 1
                try readSamples(
                    &reader,
                    bits: bits,
                    select: bits <= 10 ? audio.select[channel][bits - 1] : 0,
                    gain: Float(steps[bits]) / 4_194_304 * scale * adjustment,
                    into: base + (channel * 32 + band) * stride + 4 + subsubframe * 8
                )
            }
        }
    }

    /// Block code lengths and levels for `ABITS` 1 to 7 (Annex D.6).
    private static let blockBits = [7, 10, 12, 13, 15, 17, 19]
    private static let blockLevels = [3, 5, 7, 9, 13, 17, 25]

    /// Eight quantization indexes of a quantizer `bits`, coded as `select` says (Table 5-26), each
    /// written to `destination` times `gain`.
    private static func readSamples(
        _ reader: inout DTSBitReader,
        bits: Int,
        select: Int,
        gain: Float,
        into destination: UnsafeMutablePointer<Float>
    ) throws {
        if bits <= 10, select < DTSAudioHeader.huffmanBooks(quantizer: bits - 1) {
            let book = DTSHuffmanBook.samples[bits - 1][select]
            for sample in 0..<8 { destination[sample] = Float(try book.decode(&reader)) * gain }
        } else if bits <= 7 {
            // Two codes of four samples each, the first sample the lowest digit (Annex C.3.2).
            let levels = blockLevels[bits - 1], offset = (levels - 1) / 2
            for block in 0..<2 {
                var code = try reader.bits(blockBits[bits - 1])
                for digit in 0..<4 {
                    destination[block * 4 + digit] = Float(code % levels - offset) * gain
                    code /= levels
                }
                guard code == 0 else { throw DTSError.invalid("block code") }
            }
        } else {
            for sample in 0..<8 { destination[sample] = Float(try reader.signed(bits - 3)) * gain }
        }
    }

    // MARK: - Reconstruction

    /// Undoes the prediction where it was on (Annex C.3.3), and keeps each subband's last four samples
    /// for the next subframe.
    mutating func predict(_ subframe: inout Subframe, audio: DTSAudioHeader, info: DTSSideInfo) {
        let stride = subframe.stride
        let vectors = vectors
        subframe.samples.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            history.withUnsafeMutableBufferPointer { history in
                for channel in 0..<audio.channels {
                    for band in 0..<audio.vqStart[channel] {
                        guard let index = info.prediction[channel][band], let vectors else { continue }
                        let c0 = Float(vectors.prediction[index * 4]) / 8192
                        let c1 = Float(vectors.prediction[index * 4 + 1]) / 8192
                        let c2 = Float(vectors.prediction[index * 4 + 2]) / 8192
                        let c3 = Float(vectors.prediction[index * 4 + 3]) / 8192
                        let row = base + (channel * 32 + band) * stride
                        var slot = 4
                        while slot < stride {
                            let previous = c0 * row[slot - 1] + c1 * row[slot - 2]
                            row[slot] += previous + c2 * row[slot - 3] + c3 * row[slot - 4]
                            slot += 1
                        }
                    }
                    for band in 0..<32 {
                        (history.baseAddress! + (channel * 32 + band) * 4).update(
                            from: base + (channel * 32 + band) * stride + stride - 4,
                            count: 4
                        )
                    }
                }
            }
        }
    }

    /// Joint intensity (Annex C.3.4), then sum and difference (C.3.5), on the subband samples.
    static func reconstruct(
        _ subframe: inout Subframe,
        header: DTSCoreHeader,
        audio: DTSAudioHeader,
        info: DTSSideInfo
    ) {
        let slots = vDSP_Length(subframe.stride - 4)
        let mode = header.audioMode
        let front = [5, 7, 9].contains(mode) ? 1 : 0
        var pairs: [(Int, Int)] = []
        if (header.frontSumDifference && mode >= 1) || mode == 3 { pairs.append((front, front + 1)) }
        if header.surroundSumDifference, mode == 8 || mode == 9 {
            pairs.append(mode == 8 ? (2, 3) : (3, 4))
        }
        let stride = subframe.stride
        func row(_ channel: Int, _ band: Int) -> Int { (channel * 32 + band) * stride }
        subframe.samples.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            for channel in 0..<audio.channels {
                guard let source = audio.jointSource[channel] else { continue }
                for band in audio.subbands[channel]..<max(
                    audio.subbands[channel],
                    audio.subbands[source]
                ) {
                    var scale = info.jointScales[channel][band]
                    let from = base + row(source, band) + 4, to = base + row(channel, band) + 4
                    vDSP_vsmul(from, 1, &scale, to, 1, slots)
                }
            }
            var sum = [Float](repeating: 0, count: Int(slots))
            for (left, right) in pairs {
                for band in 0..<32 {
                    let leftRow = base + row(left, band) + 4, rightRow = base + row(right, band) + 4
                    vDSP_vadd(leftRow, 1, rightRow, 1, &sum, 1, slots)
                    // vDSP_vsub(B, A, C) is C = A - B: right becomes left - right.
                    vDSP_vsub(rightRow, 1, leftRow, 1, rightRow, 1, slots)
                    leftRow.update(from: sum, count: Int(slots))
                }
            }
        }
    }
}
