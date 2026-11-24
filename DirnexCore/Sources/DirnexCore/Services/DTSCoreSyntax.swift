import Foundation

/// A core frame's primary audio coding header (ETSI TS 102 114 §5.4.3): per channel, how many
/// subbands are coded and how, and which code books the subframes use.
struct DTSAudioHeader {
    var subframes: Int
    var channels: Int
    /// `nSUBS`: subbands coded in each channel; those above are silent unless joint coded.
    var subbands: [Int]
    /// `nVQSUB`: the first subband coded by high-frequency VQ, at most `subbands`.
    var vqStart: [Int]
    /// `JOINX - 1`: the channel each one copies its upper subbands from, or `nil`.
    var jointSource: [Int?]
    var transientBook: [Int]
    var scaleBook: [Int]
    var bitBook: [Int]
    /// `SEL`: for each channel, the code book of each quantizer `ABITS` 1 to 10.
    var select: [[Int]]
    /// The scale factor adjustment for each channel and quantizer, 1 unless Huffman coded.
    var adjustment: [[Float]]

    static let adjustments: [Float] = [1, 1.125, 1.25, 1.4375]

    static func read(_ reader: inout DTSBitReader, header: DTSCoreHeader, channels: Int) throws -> DTSAudioHeader {
        let subframes = try reader.bits(4) + 1
        let count = try reader.bits(3) + 1
        guard count == channels else {
            throw DTSError.invalid("\(count) primary channels for audio mode \(header.audioMode)")
        }
        var subbands: [Int] = []
        for _ in 0..<count {
            let value = try reader.bits(5) + 2
            guard value <= 32 else { throw DTSError.invalid("\(value) subbands") }
            subbands.append(value)
        }
        var vqStart: [Int] = []
        for channel in 0..<count { vqStart.append(min(subbands[channel], try reader.bits(5) + 1)) }
        var jointSource: [Int?] = []
        for channel in 0..<count {
            let index = try reader.bits(3)
            guard index == 0 || (index <= count && index - 1 != channel) else {
                throw DTSError.invalid("joint intensity source \(index)")
            }
            jointSource.append(index == 0 ? nil : index - 1)
        }
        var transientBook: [Int] = [], scaleBook: [Int] = [], bitBook: [Int] = []
        for _ in 0..<count { transientBook.append(try reader.bits(2)) }
        for _ in 0..<count { scaleBook.append(try reader.bits(3)) }
        for _ in 0..<count { bitBook.append(try reader.bits(3)) }
        guard !scaleBook.contains(7), !bitBook.contains(7) else { throw DTSError.invalid(
            "code book 7"
        ) }

        // SEL for ABITS 1 (one bit), 2 to 5 (two), 6 to 10 (three), quantizer by quantizer.
        var select = Array(repeating: Array(repeating: 0, count: 10), count: count)
        for quantizer in 0..<10 {
            let width = quantizer == 0 ? 1 : quantizer < 5 ? 2 : 3
            for channel in 0..<count { select[channel][quantizer] = try reader.bits(width) }
        }
        // ADJ wherever SEL names a Huffman book.
        var adjustment = Array(repeating: Array(repeating: Float(1), count: 10), count: count)
        for quantizer in 0..<10 {
            for channel in 0..<count where select[channel][quantizer] < huffmanBooks(
                quantizer: quantizer
            ) {
                adjustment[channel][quantizer] = adjustments[try reader.bits(2)]
            }
        }
        if header.hasCRC { _ = try reader.bits(16) }
        return DTSAudioHeader(
            subframes: subframes,
            channels: count,
            subbands: subbands,
            vqStart: vqStart,
            jointSource: jointSource,
            transientBook: transientBook,
            scaleBook: scaleBook,
            bitBook: bitBook,
            select: select,
            adjustment: adjustment
        )
    }

    /// How many of the `SEL` values for `quantizer` (`ABITS - 1`) name Huffman books; the next one
    /// names a block code (to `ABITS` 7) or no further coding.
    static func huffmanBooks(quantizer: Int) -> Int {
        quantizer == 0 ? 1 : quantizer < 5 ? 3 : 7
    }
}

/// One subframe's side information (§5.5.1).
struct DTSSideInfo {
    var subsubframes: Int
    /// `PVQ` where `PMODE` is 1, else `nil`.
    var prediction: [[Int?]]
    /// `ABITS`, for the subbands below `vqStart`.
    var bits: [[Int]]
    /// `TMODE`: the subsubframe each subband's second scale factor starts at, 0 for none.
    var transient: [[Int]]
    /// The scale factors before and after a transient, as linear gains.
    var scales: [[Float]]
    var scalesAfter: [[Float]]
    /// Joint intensity scale factors, by subband.
    var jointScales: [[Float]]

    static func read(_ reader: inout DTSBitReader, header: DTSCoreHeader, audio: DTSAudioHeader) throws -> DTSSideInfo {
        let channels = audio.channels
        let subsubframes = try reader.bits(2) + 1
        _ = try reader.bits(3) // PSC, which only a termination frame sets
        var info = DTSSideInfo(
            subsubframes: subsubframes,
            prediction: Array(repeating: Array(repeating: nil, count: 32), count: channels),
            bits: Array(repeating: Array(repeating: 0, count: 32), count: channels),
            transient: Array(repeating: Array(repeating: 0, count: 32), count: channels),
            scales: Array(repeating: Array(repeating: 0, count: 32), count: channels),
            scalesAfter: Array(repeating: Array(repeating: 0, count: 32), count: channels),
            jointScales: Array(repeating: Array(repeating: 0, count: 32), count: channels)
        )
        var predicted = Array(repeating: Array(repeating: false, count: 32), count: channels)
        for channel in 0..<channels {
            for band in 0..<audio.subbands[channel] { predicted[channel][band] = try reader.bit() == 1 }
        }
        for channel in 0..<channels {
            for band in 0..<audio.subbands[channel] where predicted[channel][band] {
                info.prediction[channel][band] = try reader.bits(12)
            }
        }
        for channel in 0..<channels {
            let book = audio.bitBook[channel]
            for band in 0..<audio.vqStart[channel] {
                let value = book < 5
                    ? try DTSHuffmanBook.bitAllocations[book].decode(&reader)
                    : try reader.bits(book - 1)
                guard value <= 26 else { throw DTSError.invalid("ABITS \(value)") }
                info.bits[channel][band] = value
            }
        }
        if subsubframes > 1 {
            for channel in 0..<channels {
                let book = DTSHuffmanBook.transientModes[audio.transientBook[channel]]
                for band in 0..<audio.vqStart[channel] where info.bits[channel][band] > 0 {
                    info.transient[channel][band] = try book.decode(&reader)
                }
            }
        }
        for channel in 0..<channels {
            try info.readScales(&reader, channel: channel, audio: audio)
        }
        try info.readJointScales(&reader, audio: audio)
        if header.hasDynamicRange { _ = try reader.bits(8) }
        if header.hasCRC { _ = try reader.bits(16) }
        return info
    }

    private mutating func readScales(
        _ reader: inout DTSBitReader,
        channel: Int,
        audio: DTSAudioHeader
    ) throws {
        let book = audio.scaleBook[channel]
        let table = book == 6 ? DTSTables.scaleFactors7 : DTSTables.scaleFactors6
        let valid = book == 6 ? 125 : 63
        var index = 0
        func next() throws -> Float {
            // Huffman books code each index as the difference from the one before.
            if book < 5 {
                index += try DTSHuffmanBook.scaleFactors[book].decode(&reader)
            } else {
                index = try reader.bits(book + 1)
            }
            guard index >= 0, index < valid else { throw DTSError.invalid(
                "scale factor index \(index)"
            ) }
            return Float(table[index])
        }
        for band in 0..<audio.vqStart[channel] where bits[channel][band] > 0 {
            scales[channel][band] = try next()
            if transient[channel][band] > 0 { scalesAfter[channel][band] = try next() }
        }
        for band in audio.vqStart[channel]..<audio.subbands[channel] {
            scales[channel][band] = try next()
        }
    }

    private mutating func readJointScales(_ reader: inout DTSBitReader, audio: DTSAudioHeader) throws {
        var books = Array(repeating: 0, count: audio.channels)
        for channel in 0..<audio.channels where audio.jointSource[channel] != nil {
            books[channel] = try reader.bits(3)
            guard books[channel] != 7 else { throw DTSError.invalid("joint code book 7") }
        }
        for channel in 0..<audio.channels {
            guard let source = audio.jointSource[channel] else { continue }
            let book = books[channel]
            for band in audio.subbands[channel]..<max(
                audio.subbands[channel],
                audio.subbands[source]
            ) {
                // The absolute index, even where a Huffman book codes it, biased by 64.
                let index = 64 + (book < 5
                    ? try DTSHuffmanBook.scaleFactors[book].decode(&reader)
                    : try reader.bits(book + 1))
                guard index >= 0, index < DTSTables.jointScales.count else {
                    throw DTSError.invalid("joint scale index \(index)")
                }
                jointScales[channel][band] = DTSTables.jointScales[index]
            }
        }
    }
}
