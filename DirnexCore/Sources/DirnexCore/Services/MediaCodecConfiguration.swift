import Foundation

/// AAC's configuration as the system's decoder takes it (PLAN.md §M42 ▸ Slice 4).
enum AACConfiguration {
    /// The magic cookie for `config`, laid out as the system's own AAC encoder hands out its own (read
    /// 2026-11-20, 39 bytes for 48 kHz stereo): an `ES_Descriptor` holding a `DecoderConfigDescriptor`
    /// (MPEG-4 audio, an audio stream) around the `AudioSpecificConfig`, then an
    /// `SLConfigDescriptor`, each size in four bytes. An `esds` box's version and flags are not part
    /// of it. The buffer size and bit rates the encoder fills in are left zero, which no decoder reads.
    static func magicCookie(audioSpecificConfig config: Data) -> Data {
        ElementaryStreamDescriptor.make(objectType: 0x40, streamType: 0x15, specificInfo: config)
    }

    /// An `AudioSpecificConfig` for the codec IDs that name AAC's profile rather than carrying one
    /// (`A_AAC/MPEG2/LC`, `A_AAC/MPEG4/LC/SBR`), from the track's rate and channels. An SBR track is
    /// described as the plain AAC under it, which the decoder doubles on finding the SBR data, as it
    /// does for any implicitly signalled HE-AAC.
    static func audioSpecificConfig(codecID: String, sampleRate: Double, channels: Int) -> Data? {
        let objectType: UInt32
        switch codecID {
        case "A_AAC/MPEG2/MAIN", "A_AAC/MPEG4/MAIN": objectType = 1
        case "A_AAC/MPEG2/LC", "A_AAC/MPEG4/LC", "A_AAC/MPEG2/LC/SBR", "A_AAC/MPEG4/LC/SBR": objectType = 2
        case "A_AAC/MPEG2/SSR", "A_AAC/MPEG4/SSR": objectType = 3
        case "A_AAC/MPEG4/LTP": objectType = 4
        default: return nil
        }
        guard let rateIndex = rates.firstIndex(of: Int(sampleRate.rounded())), (1...7).contains(
            channels
        )
        else { return nil }
        let channelConfiguration = UInt32(channels == 8 ? 7 : channels)
        // 5 bits of object type, 4 of rate index, 4 of channel configuration, then three zero bits of
        // `GASpecificConfig`.
        let bits = objectType << 11 | UInt32(rateIndex) << 7 | channelConfiguration << 3
        return Data([UInt8(bits >> 8), UInt8(bits & 0xFF)])
    }

    private static let rates = [
        96000,
        88200,
        64000,
        48000,
        44100,
        32000,
        24000,
        22050,
        16000,
        12000,
        11025,
        8000,
        7350
    ]
}

/// FLAC's configuration as the system's decoder takes it.
enum FLACConfiguration {
    /// A whole `dfLa` box holding the stream's `STREAMINFO`, the layout the system's own FLAC encoder
    /// gives its magic cookie (read 2026-11-20: size, `dfLa`, version and flags, then the block marked
    /// last). Matroska's private data is the native stream's head: `fLaC`, then the metadata blocks.
    static func cookie(codecPrivate: Data?) -> Data? {
        guard let streamInfo = streamInfo(codecPrivate) else { return nil }
        var box = Data()
        let size = UInt32(16 + streamInfo.count)
        box.append(contentsOf: withUnsafeBytes(of: size.bigEndian, Array.init))
        box.append(contentsOf: Array("dfLa".utf8))
        box.append(contentsOf: [0, 0, 0, 0])
        box.append(contentsOf: [0x80, 0, 0, UInt8(streamInfo.count)])
        box.append(streamInfo)
        return box
    }

    /// The block size every frame uses, when `STREAMINFO`'s smallest and largest are the same.
    static func fixedBlockSize(codecPrivate: Data?) -> Int? {
        guard let info = streamInfo(codecPrivate) else { return nil }
        let bytes = [UInt8](info)
        let smallest = Int(bytes[0]) << 8 | Int(bytes[1])
        let largest = Int(bytes[2]) << 8 | Int(bytes[3])
        return smallest == largest && smallest > 0 ? smallest : nil
    }

    /// `STREAMINFO`'s 34 bytes, which the FLAC format puts first.
    private static func streamInfo(_ codecPrivate: Data?) -> Data? {
        guard let codecPrivate, codecPrivate.count >= 42 else { return nil }
        let bytes = [UInt8](codecPrivate.prefix(8))
        guard bytes[0..<4] == [0x66, 0x4C, 0x61, 0x43], bytes[4] & 0x7F == 0 else { return nil }
        let length = Int(bytes[5]) << 16 | Int(bytes[6]) << 8 | Int(bytes[7])
        guard length == 34 else { return nil }
        let start = codecPrivate.startIndex + 8
        return codecPrivate.subdata(in: start..<start + 34)
    }
}
