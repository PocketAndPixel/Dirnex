import Foundation

extension MediaCodecName {
    /// What a Video for Windows compression code names (`XVID`, `H264`), or the code itself.
    public static func name(windowsVideoCode code: String) -> String {
        // BI_RGB is a code of four zero bytes; `DIB ` says the same.
        if code.unicodeScalars.allSatisfy({ $0.value == 0 }) || code == "DIB " { return "Uncompressed" }
        return windowsVideoNames[code.uppercased()] ?? code.trimmingCharacters(in: .whitespaces)
    }

    /// What a `WAVEFORMATEX` format tag names, or the tag in hexadecimal.
    public static func name(windowsAudioTag tag: UInt16) -> String {
        windowsAudioNames[tag] ?? String(format: "0x%04X", tag)
    }
}

extension MediaSummary {
    /// What Quick View's header and card say of an AVI, from its own headers, since AVFoundation
    /// reports nothing about a file it refuses (PLAN.md §M42 ▸ Slice 5): its length, its first
    /// picture's size, and its streams' codecs.
    ///
    /// A layer of MPEG audio is named from the tag, which says only MPEG-1 audio (0x0050) or MP3.
    public init(avi file: AVIFile) {
        self.init(duration: file.durationSeconds)
        for stream in file.streams where stream.isEnabled {
            if let video = stream.video {
                videoCodecs.append(MediaCodecName.name(windowsVideoCode: video.compression))
                if pictureSize == nil, video.width > 0, video.height > 0 {
                    pictureSize = PictureSize(width: video.width, height: video.height)
                }
            } else if let audio = stream.audio {
                audioCodecs.append(MediaCodecName.name(windowsAudioTag: audio.formatTag))
            }
        }
    }
}
