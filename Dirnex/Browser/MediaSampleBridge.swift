import AudioToolbox
import CoreMedia
import DirnexCore
import Foundation
import VideoToolbox

/// The core's `MediaSampleFormat` and `MediaPacket` in the terms Core Media takes them (PLAN.md §M42 ▸
/// Slice 4): format descriptions, sample buffers, and whether this Mac has a decoder at all.
///
/// The core says what a Matroska file holds in bytes; this is the one place those bytes become Core
/// Media objects, so the renderers that play a Matroska file see what an MP4's demuxer would hand them.
enum MediaSampleBridge {
    static func formatDescription(_ format: MediaSampleFormat) -> CMFormatDescription? {
        switch format {
        case let .video(video): videoDescription(video)
        case let .audio(audio): audioDescription(audio)
        }
    }

    /// A video description with the codec's configuration as sample description atoms, as an MP4's
    /// `stsd` would give it. VP9 and AV1 need their decoders registered first: on macOS they are
    /// "supplemental", and VideoToolbox does not offer them until asked.
    static func videoDescription(_ video: MediaSampleFormat.Video) -> CMVideoFormatDescription? {
        if video.codec == kCMVideoCodecType_VP9 || video.codec == kCMVideoCodecType_AV1 {
            VTRegisterSupplementalVideoDecoderIfAvailable(video.codec)
        }
        var extensions: [CFString: Any] = [:]
        if !video.atoms.isEmpty {
            extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = video.atoms
        }
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: nil,
            codecType: video.codec,
            width: Int32(clamping: video.width),
            height: Int32(clamping: video.height),
            extensions: extensions.isEmpty ? nil : extensions as CFDictionary,
            formatDescriptionOut: &description
        )
        return status == noErr ? description : nil
    }

    static func audioDescription(_ audio: MediaSampleFormat.Audio) -> CMAudioFormatDescription? {
        var basic = AudioStreamBasicDescription()
        basic.mSampleRate = audio.sampleRate
        basic.mFormatID = audio.formatID
        basic.mChannelsPerFrame = UInt32(clamping: audio.channels)
        basic.mFramesPerPacket = UInt32(clamping: audio.framesPerPacket)
        if let pcm = audio.pcm {
            let bytes = UInt32(clamping: pcm.bytesPerFrame(channels: audio.channels))
            var flags = pcm.isFloat ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger
            // Eight-bit PCM is unsigned, in Matroska as in WAV.
            if pcm.bitsPerSample == 8 { flags = 0 }
            if pcm.isBigEndian { flags |= kAudioFormatFlagIsBigEndian }
            basic.mFormatFlags = flags | kAudioFormatFlagIsPacked
            basic.mBitsPerChannel = UInt32(clamping: pcm.bitsPerSample)
            basic.mBytesPerFrame = bytes
            basic.mBytesPerPacket = bytes
        }
        // A layout is required of anything past stereo: AVFoundation raises on a six-channel format
        // without one (seen 2026-11-20 with E-AC-3 5.1).
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = layoutTag(channels: audio.channels)
        var description: CMAudioFormatDescription?
        let cookie = audio.magicCookie ?? Data()
        let status = cookie.withUnsafeBytes { raw in
            CMAudioFormatDescriptionCreate(
                allocator: nil,
                asbd: &basic,
                layoutSize: MemoryLayout<AudioChannelLayout>.size,
                layout: &layout,
                magicCookieSize: raw.count,
                magicCookie: raw.isEmpty ? nil : raw.baseAddress,
                extensions: nil,
                formatDescriptionOut: &description
            )
        }
        return status == noErr ? description : nil
    }

    /// The usual layout for `channels`, in the order the MPEG layouts name them.
    static func layoutTag(channels: Int) -> AudioChannelLayoutTag {
        switch channels {
        case 1: kAudioChannelLayoutTag_Mono
        case 2: kAudioChannelLayoutTag_Stereo
        case 3: kAudioChannelLayoutTag_MPEG_3_0_A
        case 4: kAudioChannelLayoutTag_Quadraphonic
        case 5: kAudioChannelLayoutTag_MPEG_5_0_A
        case 6: kAudioChannelLayoutTag_MPEG_5_1_A
        case 7: kAudioChannelLayoutTag_MPEG_6_1_A
        case 8: kAudioChannelLayoutTag_MPEG_7_1_A
        default: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(clamping: channels)
        }
    }

    /// Whether this Mac decodes `format`: a VideoToolbox session that opens for a picture, and for a
    /// sound a format AudioToolbox lists among those it decodes. Measured 2026-11-20 (P1): `vp08`
    /// fails the first with -12906, and `dtsc` is missing from the second.
    static func canDecode(_ format: MediaSampleFormat) -> Bool {
        guard let description = formatDescription(format) else { return false }
        switch format {
        case .video:
            var session: VTDecompressionSession?
            let status = VTDecompressionSessionCreate(
                allocator: nil,
                formatDescription: description,
                decoderSpecification: nil,
                imageBufferAttributes: nil,
                outputCallback: nil,
                decompressionSessionOut: &session
            )
            if let session { VTDecompressionSessionInvalidate(session) }
            return status == noErr
        case let .audio(audio):
            return audio.formatID == kAudioFormatLinearPCM || decodableAudioFormats.contains(
                audio.formatID
            )
        }
    }

    /// The audio formats AudioToolbox decodes on this Mac, asked once.
    static let decodableAudioFormats: Set<AudioFormatID> = {
        var size: UInt32 = 0
        guard AudioFormatGetPropertyInfo(kAudioFormatProperty_DecodeFormatIDs, 0, nil, &size) == noErr
        else { return [] }
        var identifiers = [AudioFormatID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioFormatID>.size
        )
        guard AudioFormatGetProperty(
            kAudioFormatProperty_DecodeFormatIDs,
            0,
            nil,
            &size,
            &identifiers
        ) == noErr
        else { return [] }
        return Set(identifiers)
    }()

    /// `packet` as a sample buffer of `description`: a compressed picture with its time and whether
    /// it starts a group of pictures, or a packet of sound with its frame count where packets differ.
    /// A picture before a seek's target is marked not to be shown, so the decoder sees it and the
    /// screen does not.
    static func sampleBuffer(
        _ packet: MediaPacket,
        description: CMFormatDescription,
        audio: MediaSampleFormat.Audio?
    ) -> CMSampleBuffer? {
        guard let block = blockBuffer(packet.data) else { return nil }
        let time = CMTime(value: packet.time, timescale: 1_000_000_000)
        guard let audio else { return pictureBuffer(
            packet,
            block: block,
            time: time,
            description: description
        ) }
        var sample: CMSampleBuffer?
        if let pcm = audio.pcm {
            let frames = packet.data.count / max(1, pcm.bytesPerFrame(channels: audio.channels))
            guard frames > 0, CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil,
                dataBuffer: block,
                formatDescription: description,
                sampleCount: frames,
                presentationTimeStamp: time,
                packetDescriptions: nil,
                sampleBufferOut: &sample
            ) == noErr else { return nil }
            return sample
        }
        var packetDescription = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: audio.framesPerPacket == 0 ? UInt32(
                clamping: packet.frameCount ?? 0
            ) : 0,
            mDataByteSize: UInt32(clamping: packet.data.count)
        )
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil,
            dataBuffer: block,
            formatDescription: description,
            sampleCount: 1,
            presentationTimeStamp: time,
            packetDescriptions: &packetDescription,
            sampleBufferOut: &sample
        ) == noErr else { return nil }
        return sample
    }

    private static func pictureBuffer(
        _ packet: MediaPacket,
        block: CMBlockBuffer,
        time: CMTime,
        description: CMFormatDescription
    ) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: packet.duration.map { CMTime(value: $0, timescale: 1_000_000_000) } ?? .invalid,
            presentationTimeStamp: time,
            decodeTimeStamp: .invalid
        )
        var size = packet.data.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: nil,
            dataBuffer: block,
            formatDescription: description,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let first = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0),
                to: CFMutableDictionary.self
            )
            if !packet.isKeyframe {
                CFDictionarySetValue(
                    first,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }
            if packet.isPreroll {
                CFDictionarySetValue(
                    first,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_DoNotDisplay).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }
        }
        return sample
    }

    /// `data` copied into a block buffer Core Media owns.
    private static func blockBuffer(_ data: Data) -> CMBlockBuffer? {
        guard !data.isEmpty else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        ) == noErr, let block else { return nil }
        let status = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }
        return status == noErr ? block : nil
    }
}
