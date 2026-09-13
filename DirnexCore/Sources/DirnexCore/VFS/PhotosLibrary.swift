import Foundation

public extension VFSBackendID {
    /// The system Photos library, browsed as folders of originals (PLAN.md §M28).
    ///
    /// A constant rather than a descriptor with coordinates in it, because there is only ever one:
    /// PhotoKit reaches the **system** library and no other, so there is no account, host or path to
    /// tell two of them apart.
    static let photos = VFSBackendID("photos")

    /// Whether this id addresses the Photos library.
    var isPhotos: Bool { self == .photos }
}

/// One asset as the library's cheap fetch describes it — an identity and a capture date, and no name.
///
/// Nameless on purpose. Everything about an asset except its file name comes out of one PhotoKit
/// fetch (a year of them in 0.88 ms, measured 2026-09-13), while the name needs a second read per
/// asset (``PhotosLibraryTransport/resources(ofAssets:)``). A type that carried the name would make
/// every caller pay for it, including the root and year listings, which only need dates.
public struct PhotosAsset: Sendable, Hashable {
    /// PhotoKit's `localIdentifier`, e.g. `0D2C4C49-84F5-4E98-A5BB-211550FCD57E/L0/001`.
    public let identifier: String
    /// When it was captured, or `nil` for the rare asset Photos holds no date for.
    public let captureDate: Date?

    public init(identifier: String, captureDate: Date?) {
        self.identifier = identifier
        self.captureDate = captureDate
    }
}

/// What one of an asset's resources is.
public enum PhotosResourceKind: Sendable, Hashable {
    /// The original of a still image.
    case photo
    /// The original of a video.
    case video
    /// The original of an audio-only asset.
    case audio
    /// The second original of a pair shot together — the RAW beside a JPEG.
    case alternatePhoto
    /// A Live Photo's movie: `IMG_0089.MOV` beside `IMG_0089.HEIC`.
    case pairedVideo
    /// Anything PhotoKit reports that is **not** an original: an edit's `FullSizeRender.heic`, its
    /// `Adjustments.plist`, and the undocumented raw type 16 (`IMG_0043O.aae`) the probe found on
    /// every edited photo. The raw value is kept so a later reader can tell them apart.
    case derived(rawValue: Int)

    /// Whether a row is drawn for it — M28's "originals are rows".
    ///
    /// Spelled as the list of originals rather than the list of derived kinds, because the derived
    /// list is not closed: type 16 is documented nowhere, and an exclusion list would have let it
    /// through as a row named `IMG_0043O.aae`.
    public var isOriginal: Bool {
        if case .derived = self { return false }
        return true
    }

    /// Where it sits among one asset's rows: the asset's own original first, then its alternate, then
    /// a Live Photo's movie — so the photograph somebody took is listed before its companions.
    var rank: Int {
        switch self {
        case .photo, .video, .audio: 0
        case .alternatePhoto: 1
        case .pairedVideo: 2
        case .derived: 3
        }
    }
}

/// One resource of one asset, as the expensive read describes it.
public struct PhotosResource: Sendable, Hashable {
    public let kind: PhotosResourceKind
    /// The name the file had when it entered the library — `IMG_0089.HEIC`, `camphoto_1254324197.jpg`.
    public let originalFilename: String
    /// Its size in bytes, or `nil` when the library did not say.
    public let byteSize: Int64?

    public init(kind: PhotosResourceKind, originalFilename: String, byteSize: Int64?) {
        self.kind = kind
        self.originalFilename = originalFilename
        self.byteSize = byteSize
    }
}

/// An album or a folder a person made in Photos (PLAN.md §M28 Slice 3).
///
/// Nothing else is one. The smart albums Photos makes (Favorites, Videos, …) are views over the
/// library rather than places, a smart album a *person* makes is not exposed by PhotoKit at all, and
/// shared albums are left out as the Library view leaves them out (docs/NOTES.md ▸ iCloud Photos).
public struct PhotosCollection: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// Holds photos, and nothing else.
        case album
        /// Holds albums and other folders, and never a photo.
        case folder
    }

    /// PhotoKit's `localIdentifier`: `…/L0/040` for an album, `…/L0/020` for a folder.
    public let identifier: String
    public let kind: Kind
    /// The title as the person typed it — a `/` included, since Photos stores one verbatim.
    public let title: String
    /// The oldest and newest capture among an album's visible photos, as the library reports them.
    /// `nil` for a folder, and for an album with nothing in it.
    public let oldestCapture: Date?
    public let newestCapture: Date?

    public init(
        identifier: String,
        kind: Kind,
        title: String,
        oldestCapture: Date? = nil,
        newestCapture: Date? = nil
    ) {
        self.identifier = identifier
        self.kind = kind
        self.title = title
        self.oldestCapture = oldestCapture
        self.newestCapture = newestCapture
    }
}

/// Why the library would not answer, in the shapes a caller does something different about.
public enum PhotosLibraryError: Error, Sendable, Equatable {
    /// Photos access has not been granted, or has been refused.
    case notAuthorized
    /// The asset or the resource is no longer in the library.
    case itemGone
    /// Anything else, carrying PhotoKit's code for diagnostics.
    case failed(code: Int)
}

/// The non-hermetic boundary beneath a ``PhotosBackend``: what the app's PhotoKit adapter answers
/// (PLAN.md §M28) — four verbs for the library by date, and two for its albums.
///
/// PhotoKit is I/O against a system daemon behind a privacy grant, so it lives in the app for the
/// reason a subprocess does, and the core tests the rules above it against a fake. Every method is
/// synchronous and may block, exactly like the other transports.
public protocol PhotosLibraryTransport: Sendable {
    /// The assets whose capture date falls in `interval` — every asset when it is `nil` — with **no
    /// names**.
    ///
    /// The library as the Photos app's own Library shows it: hidden assets excluded, a burst
    /// represented by its pick, shared albums and the Shared Library left out. An implementation may
    /// return an asset just outside `interval` (the backend re-checks membership in its own
    /// calendar), but must not leave one inside it out.
    func assets(capturedIn interval: DateInterval?) throws -> [PhotosAsset]

    /// Every resource of each asset, keyed by identifier.
    ///
    /// The expensive verb: ~1.1 ms an asset and serialized behind the daemon (measured 2026-09-13,
    /// no faster at 4 or 8 concurrent), so a caller asks for one folder's assets at a time. An
    /// identifier the library no longer knows is simply absent from the answer.
    func resources(ofAssets identifiers: [String]) throws -> [String: [PhotosResource]]

    /// The albums and folders directly inside the folder `identifier` — the library's top level when
    /// it is `nil` — in the order the Photos sidebar lists them.
    ///
    /// The order matters: it decides which of two same-titled siblings keeps the plain name. One
    /// fetch, about a millisecond a level (0.5–1.4 ms, measured 2026-09-13). A folder the library no
    /// longer knows throws ``PhotosLibraryError/itemGone``.
    func collections(inFolder identifier: String?) throws -> [PhotosCollection]

    /// The assets of the album `identifier`, with no names, under the same rules as
    /// ``assets(capturedIn:)`` — so a hidden photo is no more in an album than in the library.
    ///
    /// ~1 ms whatever the album holds; the names are the expensive part, as ever. An album the
    /// library no longer knows throws ``PhotosLibraryError/itemGone``.
    func assets(inAlbum identifier: String) throws -> [PhotosAsset]

    /// An opaque value that changes whenever the library does, or `nil` when none can be had.
    ///
    /// Cheap enough to ask before every cached answer is trusted (0.17 ms, measured). `nil` means
    /// nothing can be trusted, not that nothing changed.
    func changeToken() -> Data?

    /// Write one resource's bytes to `localPath`, which must not exist yet, downloading an original
    /// that is only in iCloud.
    ///
    /// `progress` receives byte deltas. `isCancelled` is polled during the transfer; a cancelled
    /// export throws `CancellationError` and leaves nothing at `localPath`.
    func export(
        _ resource: PhotosResource,
        ofAsset identifier: String,
        toLocalPath localPath: String,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws
}
