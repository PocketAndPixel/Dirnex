import AVFoundation
import DirnexCore

/// What a file the core reads needs before it plays (PLAN.md §M42 ▸ Slices 4 and 5): the picture and
/// the sound to play, their Core Media formats, a demuxer at the file's start, and every sound track
/// for the header's menu and tooltip, with the formats of those that decode and a way to read the
/// picture with another of them (▸ Sound tracks). Made off the main actor, since it reads the file: a
/// Matroska file's head and, for VP9, its first cluster; an AVI's headers, its index and each stream's
/// first chunk.
///
/// `@unchecked Sendable` for its format descriptions, which Core Media never changes once made.
struct SampleBufferPreparation: @unchecked Sendable {
    struct Track {
        let number: UInt64
        let description: CMFormatDescription
        /// The sound's format, for its sample buffers; `nil` for the picture.
        let audio: MediaSampleFormat.Audio?
    }

    let video: Track?
    /// The sound the file opens on, the first in the app's language (`MediaSoundChoice`).
    let audio: Track?
    /// Every sound this Mac decodes, by number, for a switch to another.
    let audioTracks: [UInt64: Track]
    let sounds: [QuickViewSoundTrack]
    /// The length the file states, or `nil`.
    let statedDuration: Double?
    /// A demuxer at the file's start, which the feed takes over.
    let demuxer: any MediaDemuxing
    /// A demuxer at the file's start reading the picture and the sound numbered as given, for a switch
    /// of sound; `nil` when it cannot be made.
    let makeDemuxer: @Sendable (UInt64) -> (any MediaDemuxing)?

    /// `file` ready to play, with the sound in `language` where it has one that decodes, or `nil` when
    /// it holds nothing this Mac decodes, which the card then says.
    static func prepare(_ file: MatroskaFile, language: String?) -> SampleBufferPreparation? {
        var formats: [UInt64: MediaSampleFormat] = [:]
        for track in file.tracks where track.isEnabled && (
            track.kind == .video || track.kind == .audio
        ) {
            let key = track.codecID == "V_VP9" ? try? file.firstKeyframe(track: track.number) : nil
            formats[track.number] = track.sampleFormat(firstFrame: key)
        }
        let dtsTracks = Set(formats.compactMap { $0.value.isDTS ? $0.key : nil })
        let firstFrames = dtsTracks.isEmpty ? [:] : (try? file.firstKeyframes(tracks: dtsTracks)) ?? [
            :
        ]
        let decoded = decodingDTS(&formats) { firstFrames[$0] }
        let plan = MatroskaPlaybackPlan(tracks: file.tracks, language: language) { track in
            track.frameEncoding.isReadable
                && formats[track.number].map(MediaSampleBridge.canDecode) == true
        }
        guard plan.isPlayable else { return nil }
        let audioTracks = decodableSounds(plan.audioTracks.map { ($0.track.number, $0.isDecodable) }) {
            formats[$0]
        }
        let picture = plan.video
        return SampleBufferPreparation(
            video: picture.flatMap { track($0.number, formats[$0.number]) },
            audio: plan.audio.flatMap { audioTracks[$0.number] },
            audioTracks: audioTracks,
            sounds: sounds(plan),
            statedDuration: file.info.durationSeconds,
            demuxer: decoding(
                MatroskaDemuxer(file: file, tracks: [picture, plan.audio].compactMap(\.self)),
                decoded
            ),
            makeDemuxer: { number in
                decoding(
                    MatroskaDemuxer(
                        file: file,
                        tracks: [picture, file.track(number: number)].compactMap(\.self)
                    ),
                    decoded
                )
            }
        )
    }

    /// `file` ready to play, or `nil` when it holds nothing this Mac decodes or its index cannot be
    /// read (PLAN.md §M42 ▸ Slice 5). Reads the index, which for a file with none means walking every
    /// chunk, and each picture and sound stream's first chunk, which carries an H.264 or MPEG-4
    /// stream's configuration and says how a sound's frames are packed.
    static func prepare(_ file: AVIFile, language: String?) -> SampleBufferPreparation? {
        guard let index = try? file.index() else { return nil }
        var formats: [Int: MediaSampleFormat] = [:]
        var firstChunks: [UInt64: Data] = [:]
        for stream in file.streams where stream.isEnabled && (
            stream.kind == .video || stream.kind == .audio
        ) {
            let first = try? index.entries(stream.number).first { $0.size > 0 }.map(file.read)
            formats[stream.number] = stream.sampleFormat(firstFrame: first)
            firstChunks[UInt64(stream.number)] = first
        }
        var numbered = Dictionary(uniqueKeysWithValues: formats.map { (UInt64($0.key), $0.value) })
        let decoded = decodingDTS(&numbered) { firstChunks[$0] }
        formats = Dictionary(uniqueKeysWithValues: numbered.map { (Int($0.key), $0.value) })
        let plan = AVIPlaybackPlan(tracks: file.streams, language: language) { stream in
            formats[stream.number].map(MediaSampleBridge.canDecode) == true
        }
        let picture = plan.video
        guard plan.isPlayable,
              let base = try? AVIDemuxer(
                  file: file,
                  index: index,
                  streams: [picture, plan.audio].compactMap(\.self)
              )
        else { return nil }
        let demuxer = decoding(base, decoded)
        let audioTracks = decodableSounds(
            plan.audioTracks.map { (UInt64($0.track.number), $0.isDecodable) }
        ) { formats[Int($0)] }
        return SampleBufferPreparation(
            video: picture.flatMap { track(UInt64($0.number), formats[$0.number]) },
            audio: plan.audio.flatMap { audioTracks[UInt64($0.number)] },
            audioTracks: audioTracks,
            sounds: sounds(plan),
            statedDuration: file.durationSeconds,
            demuxer: demuxer,
            makeDemuxer: { number in
                let sound = file.streams.first { UInt64($0.number) == number }
                return (try? AVIDemuxer(
                    file: file,
                    index: index,
                    streams: [picture, sound].compactMap(\.self)
                )).map { decoding($0, decoded) }
            }
        )
    }

    /// DTS, which no Mac decodes (PLAN.md §M42 ▸ DTS): each DTS track's format in `formats` becomes the
    /// PCM the core decodes it to, read from its first frame (`firstFrame`), or `nil` where that frame is
    /// not one the core plays, which leaves the track undecodable as before. Returns the decoded formats
    /// by track, for `decoding(_:_:)`.
    static func decodingDTS(
        _ formats: inout [UInt64: MediaSampleFormat],
        firstFrame: (UInt64) -> Data?
    ) -> [UInt64: MediaSampleFormat.Audio] {
        var decoded: [UInt64: MediaSampleFormat.Audio] = [:]
        for (number, format) in formats where format.isDTS {
            let pcm = firstFrame(number).flatMap(MediaSampleFormat.Audio.decodedDTS(firstFrame:))
            decoded[number] = pcm
            formats[number] = pcm.map(MediaSampleFormat.audio)
        }
        return decoded
    }

    /// `demuxer` with the DTS tracks in `decoded` handed over as PCM.
    static func decoding(
        _ demuxer: any MediaDemuxing,
        _ decoded: [UInt64: MediaSampleFormat.Audio]
    ) -> any MediaDemuxing {
        decoded.isEmpty ? demuxer : DTSDecodingDemuxer(demuxer, decoding: decoded)
    }

    /// The tracks among `sounds` that decode, by number, each with its format, which a switch hands the
    /// sound renderer.
    private static func decodableSounds(
        _ sounds: [(number: UInt64, isDecodable: Bool)],
        format: (UInt64) -> MediaSampleFormat?
    ) -> [UInt64: Track] {
        var tracks: [UInt64: Track] = [:]
        for sound in sounds where sound.isDecodable && tracks[sound.number] == nil {
            tracks[sound.number] = track(sound.number, format(sound.number))
        }
        return tracks
    }

    /// The plan's sound tracks as the menu and the tooltip name them, by language, codec, channels and
    /// name.
    static func sounds(_ plan: MatroskaPlaybackPlan) -> [QuickViewSoundTrack] {
        plan.audioTracks.map { entry in
            QuickViewSoundTrack(
                id: entry.track.number,
                language: entry.track.language,
                codec: MediaCodecName.name(
                    matroskaCodecID: entry.track.codecID,
                    codecPrivate: entry.track.codecPrivate
                ),
                channels: entry.track.audio.map { Int(clamping: $0.channels) },
                name: entry.track.name,
                isDecodable: entry.isDecodable,
                isDefault: entry.track.isDefault,
                isSecondarySound: entry.track.isSecondarySound
            )
        }
    }

    /// An AVI's sound streams as the tooltip names them: no language, which AVI does not record, and
    /// the name from `strn` when the writer gave one.
    static func sounds(_ plan: AVIPlaybackPlan) -> [QuickViewSoundTrack] {
        plan.audioTracks.map { entry in
            QuickViewSoundTrack(
                id: UInt64(entry.track.number),
                language: nil,
                codec: MediaCodecName.name(windowsAudioTag: entry.track.audio?.formatTag ?? 0),
                channels: entry.track.audio?.channels,
                name: entry.track.name,
                isDecodable: entry.isDecodable,
                isSecondarySound: entry.track.isSecondarySound
            )
        }
    }

    private static func track(_ number: UInt64, _ format: MediaSampleFormat?) -> Track? {
        guard let format, let description = MediaSampleBridge.formatDescription(format) else { return nil }
        if case let .audio(audio) = format {
            return Track(number: number, description: description, audio: audio)
        }
        return Track(number: number, description: description, audio: nil)
    }
}
