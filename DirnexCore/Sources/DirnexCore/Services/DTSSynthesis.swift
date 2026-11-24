import Accelerate
import Foundation

/// One channel's subband samples for the synthesis filter: 32 rows, one a subband, `stride` apart, each
/// holding `count` time slots.
struct DTSSubbandRows {
    let base: UnsafePointer<Float>
    let stride: Int
    let count: Int
}

/// The 32-band synthesis filter bank that turns one channel's subband samples back into sound
/// (ETSI TS 102 114 Annex C.3.6), carrying its history from one call to the next.
///
/// The arithmetic is Annex C's, done with vDSP: the app's Debug build compiles the core without
/// optimisation, where the same loops in Swift ran a 5.1 film at 1.6 times real time (measured
/// 2026-11-24), and the film's picture is decoding beside it.
struct DTSSynthesisFilter: Sendable {
    /// The cosine modulation as two 16 × 16 matrices, row `k` and column `i` (`raCosMod`).
    private static let sums: [Float] = (0..<256).map { index in
        let row = index / 16, column = index % 16
        return Float(cos(Double((2 * column + 1) * (2 * row + 1)) * .pi / 64))
    }

    private static let differences: [Float] = (0..<256).map { index in
        let row = index / 16, column = index % 16
        return Float(cos(Double(column * (2 * row + 1)) * .pi / 32))
    }

    /// The gains each half takes on its way into the history.
    private static let sumGains: [Float] = (0..<16).map { row in
        Float(0.25 / (2 * cos(Double(2 * row + 1) * .pi / 128)))
    }

    private static let differenceGains: [Float] = (0..<16).map { row in
        Float(-0.25 / (2 * sin(Double(2 * row + 1) * .pi / 128)))
    }

    /// Each filter with its second half of every 64 negated, so both halves accumulate by adding.
    private static let filters: [Bool: [Float]] = [
        true: signed(DTSTables.perfectFilter),
        false: signed(DTSTables.nonPerfectFilter)
    ]

    private static func signed(_ filter: [Float]) -> [Float] {
        filter.enumerated().map { $0.offset % 64 < 32 ? $0.element : -$0.element }
    }

    /// `raX`: the last 16 blocks of modulated samples, newest first.
    private var history = [Float](repeating: 0, count: 512)
    /// `raZ`: the output being accumulated, the second half for the next block.
    private var accumulator = [Float](repeating: 0, count: 64)

    mutating func reset() {
        history = [Float](repeating: 0, count: 512)
        accumulator = [Float](repeating: 0, count: 64)
    }

    /// Filters `rows`, writing 32 samples a time slot to `output`, each multiplied by `gain`.
    mutating func run(
        _ rows: DTSSubbandRows,
        perfect: Bool,
        gain: Float,
        output: UnsafeMutablePointer<Float>
    ) {
        let (sum, difference) = Self.modulate(rows)
        let coefficients = Self.filters[perfect]!
        let count = rows.count
        var scale = gain
        var scratch = [Float](repeating: 0, count: 32)
        let modulated = sum + difference
        history.withUnsafeMutableBufferPointer { history in
            accumulator.withUnsafeMutableBufferPointer { accumulator in
                modulated.withUnsafeBufferPointer { modulated in
                    coefficients.withUnsafeBufferPointer { coefficients in
                        let x = history.baseAddress!, total = accumulator.baseAddress!
                        let sums = modulated.baseAddress!, differences = sums + 16 * count
                        for slot in 0..<count {
                            vDSP_vmul(sums + slot, vDSP_Stride(count), Self.sumGains, 1, x, 1, 16)
                            vDSP_vmul(
                                differences + slot,
                                vDSP_Stride(count),
                                Self.differenceGains,
                                1,
                                x + 31,
                                -1,
                                16
                            )
                            Self.accumulate(
                                history: x,
                                output: total,
                                coefficients: coefficients.baseAddress!,
                                scratch: &scratch
                            )
                            vDSP_vsmul(total, 1, &scale, output + slot * 32, 1, 32)
                            // Age the history by a block, and move the second half of the output up.
                            memmove(x + 32, x, 480 * MemoryLayout<Float>.size)
                            memmove(total, total + 32, 32 * MemoryLayout<Float>.size)
                            memset(total + 32, 0, 32 * MemoryLayout<Float>.size)
                        }
                    }
                }
            }
        }
    }

    /// Annex C.3.6's first half for every slot at once: the sums of neighbouring subbands through the
    /// first modulation and the second, then `SUM` and `DIFF`, each 16 rows of `rows.count` slots.
    private static func modulate(_ rows: DTSSubbandRows) -> (sum: [Float], difference: [Float]) {
        let count = rows.count, slots = vDSP_Length(count)
        var pairs = [Float](repeating: 0, count: 16 * count)
        var shifted = [Float](repeating: 0, count: 16 * count)
        pairs.withUnsafeMutableBufferPointer { pairs in
            shifted.withUnsafeMutableBufferPointer { shifted in
                for band in 0..<16 {
                    let even = rows.base + 2 * band * rows.stride
                    vDSP_vadd(
                        even,
                        1,
                        even + rows.stride,
                        1,
                        pairs.baseAddress! + band * count,
                        1,
                        slots
                    )
                    if band == 0 {
                        shifted.baseAddress!.update(from: even, count: count)
                    } else {
                        vDSP_vadd(
                            even,
                            1,
                            even - rows.stride,
                            1,
                            shifted.baseAddress! + band * count,
                            1,
                            slots
                        )
                    }
                }
            }
        }
        var first = [Float](repeating: 0, count: 16 * count)
        var second = [Float](repeating: 0, count: 16 * count)
        vDSP_mmul(sums, 1, pairs, 1, &first, 1, 16, slots, 16)
        vDSP_mmul(differences, 1, shifted, 1, &second, 1, 16, slots, 16)
        var sum = [Float](repeating: 0, count: 16 * count)
        var difference = [Float](repeating: 0, count: 16 * count)
        vDSP_vadd(first, 1, second, 1, &sum, 1, vDSP_Length(16 * count))
        vDSP_vsub(second, 1, first, 1, &difference, 1, vDSP_Length(16 * count))
        return (sum, difference)
    }

    /// One block of the filter: for each of the eight taps, `raZ[i] += c[i + j] (raX[i + j] - raX[j + 31 - i])`
    /// and `raZ[32 + i] += c[32 + i + j] (-raX[i + j] - raX[j + 31 - i])`, the second's sign in the table.
    private static func accumulate(
        history x: UnsafeMutablePointer<Float>,
        output: UnsafeMutablePointer<Float>,
        coefficients: UnsafePointer<Float>,
        scratch: inout [Float]
    ) {
        scratch.withUnsafeMutableBufferPointer { scratch in
            let terms = scratch.baseAddress!
            for j in stride(from: 0, to: 512, by: 64) {
                let base = x + j
                // vDSP_vsub(B, A, C) is C = A - B; the mirrored run reads raX[j + 31] downwards.
                vDSP_vsub(base + 31, -1, base, 1, terms, 1, 32)
                vDSP_vma(coefficients + j, 1, terms, 1, output, 1, output, 1, 32)
                vDSP_vadd(base, 1, base + 31, -1, terms, 1, 32)
                vDSP_vma(coefficients + j + 32, 1, terms, 1, output + 32, 1, output + 32, 1, 32)
            }
        }
    }
}

/// The LFE channel's interpolation filter (Annex C.3.7): each decimated sample becomes 64 or 128.
struct DTSLFEInterpolator: Sendable {
    /// The last eight decimated samples, newest last.
    private var history = [Float](repeating: 0, count: 8)

    mutating func reset() {
        history = [Float](repeating: 0, count: 8)
    }

    /// Interpolates `samples` by `factor` (64 or 128) into `output`, each multiplied by `gain`:
    /// output `k` of a sample is the sum over taps `J` of `rLFE[n - J] · c[k + J · factor]`.
    mutating func run(
        _ samples: [Float],
        factor: Int,
        gain: Float,
        output: UnsafeMutablePointer<Float>
    ) {
        let coefficients = factor == 64 ? DTSTables.lfeFilter64 : DTSTables.lfeFilter128
        let taps = 512 / factor
        var offset = 0
        for sample in samples {
            history.removeFirst()
            history.append(sample)
            let target = output + offset
            target.update(repeating: 0, count: factor)
            for tap in 0..<taps {
                var weight = history[7 - tap] * gain
                coefficients.withUnsafeBufferPointer { coefficients in
                    vDSP_vsma(
                        coefficients.baseAddress! + tap * factor,
                        1,
                        &weight,
                        target,
                        1,
                        target,
                        1,
                        vDSP_Length(factor)
                    )
                }
            }
            offset += factor
        }
    }
}
