import Foundation

/// The picture codecs this reader hands to the system's decoders (PLAN.md §M42 ▸ Slice 5).
public enum AVIVideoCodec: Equatable, Sendable {
    case h264
    case mpeg4
    case motionJPEG
    /// Anything else, which plays nowhere here: MS-MPEG-4 v3 (`DIV3`), WMV, Cinepak, uncompressed.
    case other

    /// The codec a compression code names. DivX and Xvid wrote MPEG-4 Part 2 under a dozen names.
    init(compression: String) {
        switch compression.uppercased() {
        case "H264", "X264", "AVC1", "DAVC", "VSSH": self = .h264
        case "XVID", "DIVX", "DX50", "FMP4", "MP4V", "MP4S", "M4S2", "3IV2", "DXGM", "BLZ0", "RMP4",
             "UMP4", "SMP4", "DM4V", "HDX4", "FVFW", "XVIX", "GEOX": self = .mpeg4
        case "MJPG", "AVRN", "AVDJ", "JPGL": self = .motionJPEG
        default: self = .other
        }
    }
}

/// How a sound stream's chunks become packets.
enum AVIAudioPacking: Equatable, Sendable {
    /// Uncompressed: any whole number of frames of `bytesPerFrame` makes a packet.
    case pcm(bytesPerFrame: Int)
    /// Compressed frames found by their headers, however the chunks cut them.
    case framed(AudioFrameHeader.Syntax)
    /// One frame to a chunk, with nothing to find it by: AAC without ADTS headers.
    case chunk
}

extension AVIStream {
    public var videoCodec: AVIVideoCodec {
        guard let video else { return .other }
        let codec = AVIVideoCodec(compression: video.compression)
        return codec == .other ? AVIVideoCodec(compression: handler) : codec
    }

    static let aacTags: Set<UInt16> = [0x00FF, 0x1600, 0x1601, 0x1610, 0x706D, 0x4143, 0xA106]

    /// What a decoder needs for this stream, or `nil` for a codec not handled here, or one whose
    /// configuration is nowhere: H.264 with no parameter sets in its format or its first frame.
    ///
    /// `firstFrame` is the stream's first chunk with data: an H.264 or MPEG-4 stream carries its
    /// configuration there more often than in its format, and a sound's first frame says which layer
    /// of MPEG audio it is, or that AAC comes behind ADTS headers.
    public func sampleFormat(firstFrame: Data?) -> MediaSampleFormat? {
        switch kind {
        case .video: videoFormat(firstFrame: firstFrame).map(MediaSampleFormat.video)
        case .audio: audioFormat(firstFrame: firstFrame).map(MediaSampleFormat.audio)
        default: nil
        }
    }

    private func videoFormat(firstFrame: Data?) -> MediaSampleFormat.Video? {
        guard let video else { return nil }
        func format(_ code: StaticString, _ atoms: [String: Data] = [:]) -> MediaSampleFormat.Video {
            .init(
                codec: MediaSampleFormat.code(code),
                width: video.width,
                height: video.height,
                atoms: atoms
            )
        }
        switch videoCodec {
        case .h264:
            return h264Record(firstFrame: firstFrame).map { format("avc1", ["avcC": $0]) }
        case .mpeg4:
            let configuration = MPEG4Visual.configuration(extraData)
                ?? firstFrame.flatMap(MPEG4Visual.configuration)
            return configuration.map { format("mp4v", ["esds": MPEG4Visual.esds(configuration: $0)]) }
        case .motionJPEG:
            return format("jpeg")
        case .other:
            return nil
        }
    }

    /// The `avcC` record: the format's own when it carries one (an `AVC1` stream's), saying four-byte
    /// lengths, else one made from the parameter sets in the format or the first frame.
    func h264Record(firstFrame: Data?) -> Data? {
        if extraData.first == 1, extraData.count > 7 {
            // Every frame goes to the decoder with four-byte lengths, whatever the stream used.
            var record = extraData
            record[record.startIndex + 4] |= 3
            return record
        }
        let units = H264NALUnits.annexB(extraData) + (firstFrame.map(H264NALUnits.annexB) ?? [])
        guard let sequence = units.first(where: { H264NALUnits.type($0) == 7 }),
              let picture = units.first(where: { H264NALUnits.type($0) == 8 })
        else { return nil }
        return H264Configuration.record(sequence: sequence, picture: picture)
    }

    private func audioFormat(firstFrame: Data?) -> MediaSampleFormat.Audio? {
        guard let audio, audio.channels > 0, audio.sampleRate > 0 else { return nil }
        let rate = Double(audio.sampleRate)
        func plain(_ code: StaticString, _ frames: Int) -> MediaSampleFormat.Audio {
            .init(
                formatID: MediaSampleFormat.code(code),
                sampleRate: rate,
                channels: audio.channels,
                framesPerPacket: frames
            )
        }
        let first = firstFrame.map { [UInt8]($0.prefix(4096)) } ?? []
        func header(_ syntax: AudioFrameHeader.Syntax) -> AudioFrameHeader? {
            AudioFrameHeader.confirmed(in: first, syntax: syntax)?.header
        }
        switch audio.formatTag {
        case 0x0001, 0x0003:
            return pcmFormat(audio)
        case 0x0050, 0x0055:
            let found = header(.mpeg)
            let layer = found?.layer ?? (audio.formatTag == 0x0055 ? 3 : 2)
            let frames = found?.samples ?? (
                layer == 1 ? 384 : layer == 2 || rate >= 32000 ? 1152 : 576
            )
            return plain(layer == 1 ? ".mp1" : layer == 2 ? ".mp2" : ".mp3", frames)
        case 0x2000:
            // E-AC-3 behind the AC-3 tag is not read: its frames would need its own splitting.
            guard first.isEmpty || header(.ac3) != nil else { return nil }
            return plain("ac-3", 1536)
        case 0x2001:
            return plain("dtsc", 512)
        case let tag where Self.aacTags.contains(tag):
            return aacFormat(rate: rate, channels: audio.channels, adts: header(.adts))
        default:
            return nil
        }
    }

    private func aacFormat(rate: Double, channels: Int, adts: AudioFrameHeader?) -> MediaSampleFormat.Audio? {
        // WAVE_FORMAT_MPEG_HEAAC puts a 12-byte HEAACWAVEINFO before the configuration.
        let stated = audio?.formatTag == 0x1610 ? Data(extraData.dropFirst(12)) : extraData
        let config = adts?.audioSpecificConfig
            ?? (stated.count >= 2 ? stated : nil)
            ?? AACConfiguration.audioSpecificConfig(
                codecID: "A_AAC/MPEG4/LC",
                sampleRate: rate,
                channels: channels
            )
        guard let config else { return nil }
        return .init(
            formatID: MediaSampleFormat.code("aac "),
            sampleRate: Double(adts?.sampleRate ?? Int(rate)),
            channels: adts?.channels ?? channels,
            framesPerPacket: 1024,
            magicCookie: AACConfiguration.magicCookie(audioSpecificConfig: config)
        )
    }

    private func pcmFormat(_ audio: Audio) -> MediaSampleFormat.Audio? {
        let isFloat = audio.formatTag == 0x0003
        let bits = audio.bitsPerSample
        guard isFloat ? [32, 64].contains(bits) : [8, 16, 24, 32].contains(bits) else { return nil }
        return .init(
            formatID: MediaSampleFormat.code("lpcm"),
            sampleRate: Double(audio.sampleRate),
            channels: audio.channels,
            framesPerPacket: 1,
            pcm: .init(bitsPerSample: bits, isFloat: isFloat, isBigEndian: false)
        )
    }

    /// How this sound's chunks become packets, given its first chunk with data.
    func audioPacking(firstFrame: Data?) -> AVIAudioPacking? {
        guard let audio else { return nil }
        let first = firstFrame.map { [UInt8]($0.prefix(4096)) } ?? []
        switch audio.formatTag {
        case 0x0001, 0x0003:
            let bytes = (audio.bitsPerSample + 7) / 8 * audio.channels
            return bytes > 0 ? .pcm(bytesPerFrame: bytes) : nil
        case 0x0050, 0x0055: return .framed(.mpeg)
        case 0x2000: return .framed(.ac3)
        case let tag where Self.aacTags.contains(tag):
            return AudioFrameHeader.confirmed(in: first, syntax: .adts) == nil ? .chunk : .framed(
                .adts
            )
        default: return nil
        }
    }

    /// Whether a picture chunk starting with `prefix` is one a decoder can start from, for an index
    /// made by walking the chunks, which says nothing of key frames: H.264 with an IDR slice or the
    /// parameter sets that come before one, MPEG-4 with an intra plane or the headers before one,
    /// and every Motion JPEG frame.
    func looksLikeKeyframe(_ prefix: Data) -> Bool {
        switch videoCodec {
        case .h264:
            return H264NALUnits.annexB(prefix).contains { [5, 7].contains(H264NALUnits.type($0)) }
        case .mpeg4:
            let bytes = [UInt8](prefix)
            return MPEG4Visual.startCodes(bytes).contains { start in
                let code = bytes[start + 3]
                return code == MPEG4Visual.groupStartCode || (0x20...0x2F).contains(code)
                    || code == MPEG4Visual.planeStartCode && start + 4 < bytes.count && bytes[
                        start + 4
                    ] >> 6 == 0
            }
        case .motionJPEG, .other:
            return true
        }
    }
}
