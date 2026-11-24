import Foundation

extension MediaSampleFormat.Audio {
    /// Whether this is DTS, which no Mac decodes (`kAudioFormatProperty_DecodeFormatIDs` lists no
    /// `dtsc`, measured again on macOS 27.2.1) and the core does (`DTSCoreDecoder`).
    public var isDTS: Bool { formatID == MediaSampleFormat.code("dtsc") }

    /// What DTS whose first frame is `firstFrame` decodes to through `DTSDecodingDemuxer`: 32-bit float
    /// PCM at the frame's rate, its channels interleaved in the order its layout names. `nil` when the
    /// frame is not one the decoder plays.
    ///
    /// The bytes may also be the start of a stream cut anywhere, as an AVI's first sound chunk is: the
    /// first header the next one bears out is read.
    public static func decodedDTS(firstFrame: Data) -> MediaSampleFormat.Audio? {
        var header = DTSCoreHeader(firstFrame)
        if header == nil, let found = AudioFrameHeader.confirmed(
            in: [UInt8](firstFrame.prefix(16384)),
            syntax: .dts
        ) {
            header = DTSCoreHeader(firstFrame.dropFirst(found.index))
        }
        guard let header, header.encoderVersion <= 7, let layout = header.layout else { return nil }
        return MediaSampleFormat.Audio(
            formatID: MediaSampleFormat.code("lpcm"),
            sampleRate: Double(header.sampleRate),
            channels: layout.channels,
            framesPerPacket: 1,
            pcm: .init(bitsPerSample: 32, isFloat: true, isBigEndian: false),
            channelLayoutTag: layout.tag
        )
    }
}

extension MediaSampleFormat {
    /// Whether this is a DTS sound (`MediaSampleFormat.Audio.isDTS`).
    public var isDTS: Bool {
        if case let .audio(audio) = self { return audio.isDTS }
        return false
    }
}

/// A demuxer whose DTS tracks come out decoded: each packet of one is the frame's sound as 32-bit float
/// PCM in the format `MediaSampleFormat.Audio.decodedDTS` gives, and every other track passes through.
/// So a player that hands PCM to the system plays DTS as it plays any other sound.
///
/// The packets are timed by their samples (`MediaSampleClock`), not by the container: the film's frames
/// are 10.667 ms and mkvmerge stamps each block of eight in whole milliseconds, so the stamps the frames
/// get fell 333 or 666 µs before or after where the frame ahead ended at 252 of 1 999 joins (measured
/// 2026-11-24), and PCM handed over that way played with a click at each, heard live.
///
/// A seek resets the decoders, whose prediction and filters then need two frames to settle: measured
/// 2026-11-24 over the film, a fresh decoder's first frame came out at 2 to 5 dB against one that had
/// decoded from the start, its second at about 20, its third at 40 to 84. The player seeks 100 ms before
/// where it plays from (`SampleBufferFeed.displayLead`), which is nine frames of 512 at 48 kHz.
public struct DTSDecodingDemuxer: MediaDemuxing {
    private var base: any MediaDemuxing
    private let formats: [UInt64: MediaSampleFormat.Audio]
    private var decoders: [UInt64: DTSCoreDecoder]
    private var clocks: [UInt64: MediaSampleClock] = [:]

    /// `base` with the tracks in `formats` decoded, each to the format given (`decodedDTS`).
    public init(_ base: any MediaDemuxing, decoding formats: [UInt64: MediaSampleFormat.Audio]) {
        self.base = base
        self.formats = formats
        decoders = formats.mapValues { _ in DTSCoreDecoder() }
    }

    public mutating func next(track: UInt64) throws -> MediaPacket? {
        guard let packet = try base.next(track: track) else { return nil }
        guard let format = formats[track] else { return packet }
        var samples: [Float]?
        if let frame = try? decoders[track]?.decode(packet.data),
           frame.layout.channels == format.channels, Double(frame.header.sampleRate) == format.sampleRate {
            samples = frame.samples
        }
        if samples == nil {
            // A frame that does not decode plays as silence of its length, so the sound keeps its place.
            decoders[track]?.reset()
            let frames = DTSCoreHeader(packet.data)?.samples ?? packet.duration.map {
                Int((Double($0) * format.sampleRate / 1_000_000_000).rounded())
            } ?? 512
            samples = [Float](repeating: 0, count: frames * format.channels)
        }
        let pcm = samples ?? []
        let frames = pcm.count / max(1, format.channels)
        var clock = clocks[track] ?? MediaSampleClock(sampleRate: format.sampleRate)
        let (time, duration) = clock.place(frames: frames, statedTime: packet.time)
        clocks[track] = clock
        return MediaPacket(
            track: packet.track,
            time: time,
            duration: duration,
            data: pcm.withUnsafeBytes { Data($0) },
            isKeyframe: true,
            frameCount: frames,
            isPreroll: packet.isPreroll
        )
    }

    public mutating func seek(to nanoseconds: Int64, keyTrack: UInt64?) throws {
        try base.seek(to: nanoseconds, keyTrack: keyTrack)
        for track in decoders.keys { decoders[track]?.reset() }
        clocks = [:]
    }
}

/// Times a run of sound by its samples: each packet starts where the one before ended, to the
/// nanosecond, as long as the time the container states for it is within half a packet of there. A
/// container's clock is coarser than a sample (Matroska's is a millisecond here), and PCM whose times
/// disagree with its length is padded or cut at each join. A stated time further off is a real gap or a
/// jump, and the clock starts again from it.
public struct MediaSampleClock: Equatable, Sendable {
    public let sampleRate: Double
    /// Where the run started, and how many samples it has held since.
    private var anchor: Int64?
    private var samples = 0

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    /// The time and duration of the next `frames` samples, whose container says they start at
    /// `statedTime`.
    public mutating func place(frames: Int, statedTime: Int64) -> (time: Int64, duration: Int64) {
        let length = nanoseconds(frames)
        if let anchor {
            let expected = anchor + nanoseconds(samples)
            if abs(statedTime - expected) * 2 <= length {
                samples += frames
                return (expected, anchor + nanoseconds(samples) - expected)
            }
        }
        anchor = statedTime
        samples = frames
        return (statedTime, length)
    }

    private func nanoseconds(_ count: Int) -> Int64 {
        Int64((Double(count) * 1_000_000_000 / sampleRate).rounded())
    }
}
