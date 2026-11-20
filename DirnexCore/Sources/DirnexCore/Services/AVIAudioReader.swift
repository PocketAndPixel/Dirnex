import Foundation

/// One AVI sound stream's packets, timed (PLAN.md §M42 ▸ Slice 5).
///
/// A stream stored a frame to a chunk (`dwSampleSize` 0, as variable-rate MP3 and AAC are) is timed
/// by its chunks: chunk *k* starts at tick `start + k`, empty chunks included, so a gap the muxer left
/// stays a gap. The AVI sample's AAC track has two empty chunks after its first, and FFmpeg times its
/// fourth frame at 64 ms, not 43. A stream stored at a constant rate is timed by its bytes: a frame
/// starts at the time of its first byte, however the chunks cut it.
struct AVIAudioReader: Sendable {
    let file: AVIFile
    let stream: AVIStream
    let entries: [AVIIndexEntry]
    let format: MediaSampleFormat.Audio
    private let packing: AVIAudioPacking
    /// The bytes before each chunk, for a stream timed by its bytes.
    private let bytesBefore: [Int64]
    private var splitter: AudioFrameSplitter?
    private var carry = Data()
    private var cursor = 0
    /// When the next frame of a stream timed by its chunks starts, while a frame runs over a chunk.
    private var nextSeconds = 0.0
    private var ready: [MediaPacket] = []
    private var head = 0
    /// Where the last seek wants playback to start: sound that ends before it is passed over.
    private var target: Int64?

    init?(file: AVIFile, stream: AVIStream, entries: [AVIIndexEntry], firstFrame: Data?) {
        guard case let .audio(format)? = stream.sampleFormat(firstFrame: firstFrame),
              let packing = stream.audioPacking(firstFrame: firstFrame)
        else { return nil }
        self.file = file
        self.stream = stream
        self.entries = entries
        self.format = format
        self.packing = packing
        if case let .framed(syntax) = packing { splitter = AudioFrameSplitter(syntax: syntax) }
        var total: Int64 = 0
        bytesBefore = entries.map { entry in
            defer { total += Int64(entry.size) }
            return total
        }
    }

    private var isTimedByBytes: Bool {
        if case .pcm = packing { return true }
        return stream.sampleSize > 0
    }

    /// When the byte at `position` of the stream plays, in seconds.
    private func seconds(atByte position: Int64) -> Double {
        let startSeconds = Double(stream.start) * (stream.tickSeconds ?? 0)
        if stream.sampleSize > 0, let tick = stream.tickSeconds {
            return startSeconds + Double(position) / Double(stream.sampleSize) * tick
        }
        if case let .pcm(bytesPerFrame) = packing, format.sampleRate > 0 {
            return startSeconds + Double(position) / Double(bytesPerFrame) / format.sampleRate
        }
        let perSecond = Double(stream.audio?.averageBytesPerSecond ?? 0)
        return perSecond > 0 ? startSeconds + Double(position) / perSecond : startSeconds
    }

    /// When chunk `index` starts, in seconds.
    func seconds(ofChunk index: Int) -> Double {
        if isTimedByBytes { return seconds(atByte: bytesBefore[index]) }
        return Double(Int64(stream.start) + Int64(index)) * (stream.tickSeconds ?? 0)
    }

    /// The next packet, or `nil` once the stream has no more.
    mutating func next() throws -> MediaPacket? {
        while head == ready.count {
            ready = []
            head = 0
            guard cursor < entries.count else { return nil }
            let index = cursor
            cursor += 1
            try read(index)
        }
        let packet = ready[head]
        head += 1
        return packet
    }

    /// Start again at the last chunk starting at or before `nanoseconds`.
    mutating func seek(to nanoseconds: Int64) {
        let wanted = Double(max(0, nanoseconds)) / 1_000_000_000
        var low = 0
        var high = entries.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if seconds(ofChunk: middle) <= wanted { low = middle } else { high = middle - 1 }
        }
        cursor = max(0, low)
        target = max(0, nanoseconds)
        splitter?.reset()
        carry = Data()
        ready = []
        head = 0
    }

    private mutating func read(_ index: Int) throws {
        let data = try file.read(entries[index])
        let chunkSeconds = seconds(ofChunk: index)
        switch packing {
        case .chunk:
            guard !data.isEmpty else { return }
            emit(data, seconds: chunkSeconds, frames: format.framesPerPacket)
        case let .pcm(bytesPerFrame):
            let position = bytesBefore[index] - Int64(carry.count)
            carry.append(data)
            let whole = carry.count / bytesPerFrame * bytesPerFrame
            guard whole > 0 else { return }
            emit(
                carry.prefix(whole),
                seconds: seconds(atByte: position),
                frames: whole / bytesPerFrame
            )
            carry = Data(carry.dropFirst(whole))
        case .framed:
            guard var splitter else { return }
            if splitter.isEmpty { nextSeconds = chunkSeconds }
            let frames = splitter.append(data)
            self.splitter = splitter
            for frame in frames {
                let header = frame.header
                let start = isTimedByBytes
                    ? seconds(atByte: bytesBefore[index] + Int64(frame.offset))
                    : nextSeconds
                emit(
                    frame.data.dropFirst(header.headerLength),
                    seconds: start,
                    frames: header.samples
                )
                nextSeconds = start + Double(header.samples) / Double(max(1, header.sampleRate))
            }
        }
    }

    private mutating func emit(_ data: Data, seconds: Double, frames: Int) {
        let time = Int64((seconds * 1_000_000_000).rounded())
        let duration = format.sampleRate > 0
            ? Int64((Double(frames) * 1_000_000_000 / format.sampleRate).rounded())
            : nil
        if let target, time + (duration ?? 0) <= target { return }
        ready.append(MediaPacket(
            track: UInt64(stream.number),
            time: time,
            duration: duration,
            data: Data(data),
            isKeyframe: true,
            frameCount: frames,
            isPreroll: false
        ))
    }
}

/// Hands out the packets of an AVI's picture and sound streams, each stream in its own order (PLAN.md
/// §M42 ▸ Slice 5).
///
/// Matroska's demuxer reads a cluster at a time and keeps one track's blocks waiting for the other's
/// renderer to ask. An AVI's index lists each stream's chunks on their own, so each stream reads from
/// its own place in the file and nothing waits.
public struct AVIDemuxer: Sendable {
    public let file: AVIFile
    private var pictures: [UInt64: AVIVideoReader] = [:]
    private var sounds: [UInt64: AVIAudioReader] = [:]

    /// A demuxer for `streams` of `file`, at their starts. A stream whose codec is not read here is
    /// left out, and gives no packets.
    public init(file: AVIFile, index: AVIIndex, streams: [AVIStream]) throws {
        self.file = file
        for stream in streams {
            let entries = index.entries(stream.number)
            let first = try entries.first { $0.size > 0 }.map(file.read)
            let number = UInt64(stream.number)
            switch stream.kind {
            case .video:
                pictures[number] = AVIVideoReader(
                    file: file,
                    stream: stream,
                    entries: entries,
                    firstFrame: first
                )
            case .audio:
                sounds[number] = AVIAudioReader(
                    file: file,
                    stream: stream,
                    entries: entries,
                    firstFrame: first
                )
            default:
                break
            }
        }
    }

    /// The next packet of `track`, or `nil` once the file has no more of it.
    public mutating func next(track: UInt64) throws -> MediaPacket? {
        if pictures[track] != nil { return try pictures[track]!.next() }
        if sounds[track] != nil { return try sounds[track]!.next() }
        return nil
    }

    /// Start every stream again at `nanoseconds`: a picture at the key frame before it, with the
    /// pictures between coming back as preroll, and a sound at the chunk holding it, with what ends
    /// before it passed over.
    public mutating func seek(to nanoseconds: Int64) {
        for number in pictures.keys {
            pictures[number]!.seek(to: nanoseconds)
        }
        for number in sounds.keys {
            sounds[number]!.seek(to: nanoseconds)
        }
    }
}
