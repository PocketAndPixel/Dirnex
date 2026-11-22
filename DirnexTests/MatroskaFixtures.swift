import AVFoundation
import Foundation

/// Matroska files for Quick View's player tests (PLAN.md §M42 ▸ Slice 4), made of packets the system's
/// own encoders wrote: H.264 from the movie fixture, AAC and Opus from AudioToolbox. Nothing binary is
/// checked in, and the bytes the player decodes are bytes a real encoder produced.
enum MatroskaFixtures {
    /// One encoded packet: its bytes, its time in milliseconds, and whether a picture starts there.
    struct Packet {
        let data: Data
        let milliseconds: Int
        var isKeyframe = true
    }

    /// A track to write: its Matroska codec ID, its private data, and its packets.
    struct Track {
        let number: UInt64
        let isVideo: Bool
        let codecID: String
        let codecPrivate: Data?
        let packets: [Packet]
        var width = 64
        var height = 64
        var sampleRate = 48000.0
        var channels = 2
        /// Written only when set; Matroska reads a track with none as English.
        var language: String?
        /// Written only when off, as mkvmerge leaves it out when on.
        var isDefault = true
    }

    /// An H.264 Matroska file `seconds` long with ten frames, and, when `sound` is set, a sound of
    /// AAC silence beside it, so a test that plays it is not heard.
    nonisolated static func writeMovie(to url: URL, seconds: Int = 1, sound: Bool = true) async throws {
        let mp4 = url.deletingPathExtension().appendingPathExtension("source.mp4")
        defer { try? FileManager.default.removeItem(at: mp4) }
        try await QuickViewMediaFixtures.writeMovie(to: mp4, seconds: seconds)
        var tracks = [try await h264Track(from: mp4)]
        if sound {
            let aac = try encode(kAudioFormatMPEG4AAC, seconds: Double(seconds), amplitude: 0)
            tracks.append(Track(
                number: 2,
                isVideo: false,
                codecID: "A_AAC",
                codecPrivate: try audioSpecificConfig(fromCookie: aac.cookie),
                packets: aac.packets
            ))
        }
        try write(tracks, duration: Double(seconds), to: url)
    }

    /// The H.264 track of the MP4 at `url`, as AVFoundation reads it without decoding: length-prefixed
    /// pictures and the `avcC` record its format description carries.
    nonisolated static func h264Track(from url: URL) async throws -> Track {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first.orThrow()
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        var packets: [Packet] = []
        var record: Data?
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            if record == nil, let description = CMSampleBufferGetFormatDescription(sample) {
                let atoms = CMFormatDescriptionGetExtension(
                    description,
                    extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
                ) as? [String: Any]
                record = atoms?["avcC"] as? Data
            }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(
                block,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &pointer
            )
            let data = Data(bytes: try pointer.orThrow(), count: length)
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sample,
                createIfNecessary: false
            )
                as? [[CFString: Any]]
            let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            packets.append(
                Packet(data: data, milliseconds: Int((time * 1000).rounded()), isKeyframe: !notSync)
            )
        }
        return Track(
            number: 1,
            isVideo: true,
            codecID: "V_MPEG4/ISO/AVC",
            codecPrivate: try record.orThrow(),
            packets: packets
        )
    }

    /// What an encoder wrote: its packets and its magic cookie.
    struct Encoded {
        let packets: [Packet]
        let cookie: Data
    }

    /// A 440 Hz tone of `amplitude`, `seconds` long at 48 kHz stereo, encoded by AudioToolbox into
    /// `format`, with the encoder's magic cookie.
    nonisolated static func encode(
        _ format: AudioFormatID,
        seconds: Double,
        amplitude: Float,
        framesPerPacket: UInt32 = 0
    ) throws -> Encoded {
        let pcm = try AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2).orThrow()
        var description = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: format,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: framesPerPacket,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        let compressed = try AVAudioFormat(streamDescription: &description).orThrow()
        let converter = try AVAudioConverter(from: pcm, to: compressed).orThrow()
        let total = AVAudioFrameCount(seconds * 48000)
        let source = try AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: total).orThrow()
        source.frameLength = total
        for channel in 0..<2 {
            let samples = try source.floatChannelData.orThrow()[channel]
            for index in 0..<Int(total) {
                samples[index] = amplitude * sin(2 * .pi * 440 * Float(index) / 48000)
            }
        }
        var handedOver = false
        var packets: [Packet] = []
        var frames = 0
        let perPacket = Int(compressed.streamDescription.pointee.mFramesPerPacket)
        while true {
            let out = AVAudioCompressedBuffer(
                format: compressed,
                packetCapacity: 8,
                maximumPacketSize: max(converter.maximumOutputPacketSize, 1)
            )
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, state in
                if handedOver {
                    state.pointee = .endOfStream
                    return nil
                }
                handedOver = true
                state.pointee = .haveData
                return source
            }
            if let error { throw error }
            let descriptions = out.packetDescriptions
            for index in 0..<Int(out.packetCount) {
                guard let packet = descriptions?[index] else { continue }
                let start = Int(packet.mStartOffset)
                let bytes = Data(bytes: out.data + start, count: Int(packet.mDataByteSize))
                packets.append(Packet(data: bytes, milliseconds: frames * 1000 / 48000))
                frames += perPacket
            }
            if status == .endOfStream || status == .error || out.packetCount == 0 { break }
        }
        return Encoded(packets: packets, cookie: try converter.magicCookie.orThrow())
    }

    /// The `AudioSpecificConfig` inside an AAC encoder's cookie: the bytes of its descriptor tagged 5.
    nonisolated static func audioSpecificConfig(fromCookie cookie: Data) throws -> Data {
        let bytes = [UInt8](cookie)
        var index = 0
        while index < bytes.count {
            let tag = bytes[index]
            index += 1
            var size = 0
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                size = size << 7 | Int(byte & 0x7F)
                if byte & 0x80 == 0 { break }
            }
            switch tag {
            case 0x05: return Data(bytes[index..<min(bytes.count, index + size)])
            // An ES_Descriptor's ID and flags, then a DecoderConfigDescriptor's fixed 13 bytes, come
            // before the descriptors nested in them.
            case 0x03: index += 3
            case 0x04: index += 13
            default: index += size
            }
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    // MARK: - Writing EBML

    /// A Matroska file of `tracks`, their packets interleaved by time into one cluster a second.
    nonisolated static func write(
        _ tracks: [Track],
        duration: Double,
        docType: String = "matroska",
        to url: URL
    ) throws {
        let header = element(0x1A45DFA3, [
            uint(0x4286, 1), uint(0x42F7, 1), uint(0x42F2, 4), uint(0x42F3, 8),
            element(0x4282, Array(docType.utf8)), uint(0x4287, 4), uint(0x4285, 2)
        ].flatMap(\.self))
        let info = element(0x1549A966, uint(0x2AD7B1, 1_000_000) + float(0x4489, duration * 1000))
        let entries = tracks.map { track -> [UInt8] in
            var body = uint(0xD7, track.number) + uint(0x73C5, track.number) + uint(
                0x83,
                track.isVideo ? 1 : 2
            )
            body += element(0x86, Array(track.codecID.utf8))
            if let language = track.language { body += element(0x22B59C, Array(language.utf8)) }
            if !track.isDefault { body += uint(0x88, 0) }
            if let codecPrivate = track.codecPrivate { body += element(0x63A2, [UInt8](codecPrivate)) }
            if track.isVideo {
                body += element(
                    0xE0,
                    uint(0xB0, UInt64(track.width)) + uint(0xBA, UInt64(track.height))
                )
            } else {
                body += element(
                    0xE1,
                    float(0xB5, track.sampleRate) + uint(0x9F, UInt64(track.channels))
                )
            }
            return element(0xAE, body)
        }
        let all = tracks.flatMap { track in track.packets.map { (track.number, $0) } }
            .sorted { $0.1.milliseconds < $1.1.milliseconds }
        var clusters: [UInt8] = []
        for second in 0...Int(duration.rounded(.up)) {
            let inCluster = all.filter { $0.1.milliseconds / 1000 == second }
            guard !inCluster.isEmpty else { continue }
            var body = uint(0xE7, UInt64(second * 1000))
            for (track, packet) in inCluster {
                let relative = Int16(packet.milliseconds - second * 1000)
                var block = variableInteger(track)
                block += [
                    UInt8(truncatingIfNeeded: relative >> 8),
                    UInt8(truncatingIfNeeded: relative)
                ]
                block.append(packet.isKeyframe ? 0x80 : 0)
                body += element(0xA3, block + [UInt8](packet.data))
            }
            clusters += element(0x1F43B675, body)
        }
        let segment = element(
            0x18538067,
            info + element(0x1654AE6B, entries.flatMap(\.self)) + clusters
        )
        try Data(header + segment).write(to: url)
    }

    nonisolated private static func element(_ id: UInt32, _ body: [UInt8]) -> [UInt8] {
        let idLength = max(1, (32 - id.leadingZeroBitCount + 7) / 8)
        let idBytes = (0..<idLength).map { UInt8(
            truncatingIfNeeded: id >> (8 * UInt32(idLength - 1 - $0))
        ) }
        return idBytes + variableInteger(UInt64(body.count)) + body
    }

    nonisolated private static func uint(_ id: UInt32, _ value: UInt64) -> [UInt8] {
        element(id, (0..<8).map { UInt8(truncatingIfNeeded: value >> (56 - 8 * UInt64($0))) })
    }

    nonisolated private static func float(_ id: UInt32, _ value: Double) -> [UInt8] {
        let bits = value.bitPattern
        return element(id, (0..<8).map { UInt8(truncatingIfNeeded: bits >> (56 - 8 * UInt64($0))) })
    }

    nonisolated private static func variableInteger(_ value: UInt64) -> [UInt8] {
        let length = (1...8).first { value < (UInt64(1) << (7 * UInt64($0))) - 1 } ?? 8
        let marked = value | (UInt64(1) << (7 * UInt64(length)))
        return (0..<length).map { UInt8(truncatingIfNeeded: marked >> (8 * UInt64(length - 1 - $0))) }
    }
}

private extension Optional {
    nonisolated func orThrow() throws -> Wrapped {
        guard let self else { throw CocoaError(.fileReadUnknown) }
        return self
    }
}
