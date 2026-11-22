import Foundation

/// What a movie or a sound holds, as Quick View's header and its card say it (PLAN.md §M42 ▸ Slice 2):
/// its length, its picture's size and its codecs.
///
/// Filled in by the app from what AVFoundation reports, or from the container's own bytes where
/// AVFoundation reports nothing. Every part is optional, since a sound has no picture, a stream may
/// have no length yet, and a refused file may say nothing but its container.
public struct MediaSummary: Equatable, Sendable {
    /// A picture's size in pixels, as it is shown: a portrait movie recorded sideways is taller than
    /// it is wide here.
    public struct PictureSize: Equatable, Sendable {
        public let width: Int
        public let height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    /// The length in seconds, or `nil` while it is not known.
    public var duration: Double?
    public var pictureSize: PictureSize?
    /// Codec names in track order, one per track (`MediaCodecName`).
    public var videoCodecs: [String]
    public var audioCodecs: [String]

    public init(
        duration: Double? = nil,
        pictureSize: PictureSize? = nil,
        videoCodecs: [String] = [],
        audioCodecs: [String] = []
    ) {
        self.duration = duration
        self.pictureSize = pictureSize
        self.videoCodecs = videoCodecs
        self.audioCodecs = audioCodecs
    }

    /// "2560×1440 · H.264 · AAC": the picture's size, then the video codecs, then the sound's, each
    /// part left out when it is not known.
    ///
    /// A codec is named once however many tracks carry it, so a film with five AC-3 tracks and four DTS
    /// ones reads "AC-3, DTS". Which track is which language is the player's business, not the
    /// header's.
    public var facts: String {
        var parts: [String] = []
        if let pictureSize, pictureSize.width > 0, pictureSize.height > 0 {
            parts.append("\(pictureSize.width)×\(pictureSize.height)")
        }
        for codecs in [videoCodecs, audioCodecs] {
            let named = Self.distinct(codecs)
            if !named.isEmpty { parts.append(named.joined(separator: ", ")) }
        }
        return parts.joined(separator: " · ")
    }

    private static func distinct(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// A place in a movie or a sound, written as a clock (PLAN.md §M42 ▸ Slice 2).
///
/// Its shape follows the *length*, not the place: in a film over an hour every place has hours, so
/// "0:00:42 / 1:35:20" keeps its width from the first second to the last rather than jumping as
/// playback passes an hour. Both are rounded down, so the place at the very end reads the same as the
/// length it has reached.
public enum MediaTimecode {
    /// `seconds` as `m:ss`, or as `h:mm:ss` when `length` — or, with no length known, the place
    /// itself — is an hour or more. A place that is not finite or is negative reads as the start.
    public static func string(_ seconds: Double, shapedBy length: Double?) -> String {
        let whole = wholeSeconds(seconds)
        let shape = length.map(wholeSeconds) ?? whole
        let hours = whole / 3600
        let minutes = whole / 60 % 60
        let rest = whole % 60
        if shape >= 3600 {
            return "\(hours):\(twoDigits(minutes)):\(twoDigits(rest))"
        }
        return "\(whole / 60):\(twoDigits(rest))"
    }

    /// "0:42 / 1:35:20", or the place alone while the length is not known.
    public static func readout(at seconds: Double, of length: Double?) -> String {
        guard let length, length.isFinite, length > 0 else {
            return string(seconds, shapedBy: nil)
        }
        return "\(string(min(seconds, length), shapedBy: length)) / \(string(length, shapedBy: length))"
    }

    private static func wholeSeconds(_ seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(seconds.rounded(.down))
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
