import Foundation

@testable import DirnexCore

/// A fake ``PhotosLibraryTransport`` over a fixed set of assets, recording what it was asked.
///
/// The records are what several tests are about: the expensive verb is `resources(ofAssets:)`, so a
/// cache that did not hold shows up as a second request for the same month, and a listing that read
/// names it did not need shows up as any request at all.
final class FakePhotosLibrary: PhotosLibraryTransport, @unchecked Sendable {
    struct Stored: Sendable {
        let asset: PhotosAsset
        let resources: [PhotosResource]
    }

    struct Export: Equatable {
        let identifier: String
        let resource: PhotosResource
        let localPath: String
    }

    var stored: [Stored]
    var token: Data? = Data("7012".utf8)
    var failure: PhotosLibraryError?
    var exportFailure: (any Error)?
    /// The bytes an export writes, keyed by original file name; a name with none writes an empty file.
    var bytes: [String: Data] = [:]

    /// Each folder's children in sidebar order, keyed by the folder's identifier — `nil` for the top.
    var levels: [String?: [PhotosCollection]] = [:]
    /// Each album's members, by asset identifier.
    var albumMembers: [String: [String]] = [:]

    private(set) var intervalsAsked: [DateInterval?] = []
    private(set) var resourceRequests: [[String]] = []
    private(set) var exports: [Export] = []
    private(set) var levelRequests: [String?] = []
    private(set) var albumRequests: [String] = []

    init(_ stored: [Stored]) {
        self.stored = stored
    }

    /// Answer every asset whatever interval was asked for — a transport that fetches wide, which the
    /// backend has to survive because the calendar deciding membership is its own.
    var answersWide = false

    func assets(capturedIn interval: DateInterval?) throws -> [PhotosAsset] {
        intervalsAsked.append(interval)
        if let failure { throw failure }
        return stored.map(\.asset).filter { asset in
            guard let interval, !answersWide else { return true }
            guard let date = asset.captureDate else { return false }
            return interval.contains(date)
        }
    }

    func resources(ofAssets identifiers: [String]) throws -> [String: [PhotosResource]] {
        resourceRequests.append(identifiers)
        if let failure { throw failure }
        var answer: [String: [PhotosResource]] = [:]
        for item in stored where identifiers.contains(item.asset.identifier) {
            answer[item.asset.identifier] = item.resources
        }
        return answer
    }

    func collections(inFolder identifier: String?) throws -> [PhotosCollection] {
        levelRequests.append(identifier)
        if let failure { throw failure }
        if let identifier, !levels.values.joined().contains(where: {
            $0.identifier == identifier && $0.kind == .folder
        }) {
            throw PhotosLibraryError.itemGone
        }
        return levels[identifier] ?? []
    }

    func assets(inAlbum identifier: String) throws -> [PhotosAsset] {
        albumRequests.append(identifier)
        if let failure { throw failure }
        guard let members = albumMembers[identifier] else { throw PhotosLibraryError.itemGone }
        return members.compactMap { member in stored.first { $0.asset.identifier == member }?.asset }
    }

    /// Put `albums` and `folders` into the library, the way ``PhotosProbeLibrary/albums`` describes
    /// them, with each album's dates the capture range of its members — which is what PhotoKit
    /// reported for every album the probe read.
    func install(_ level: [PhotosProbeLibrary.Node], inFolder parent: String? = nil) {
        levels[parent] = level.map { node in
            switch node {
            case let .album(identifier, title, members):
                albumMembers[identifier] = members.map(\.asset.identifier)
                let dates = members.compactMap(\.asset.captureDate)
                return PhotosCollection(
                    identifier: identifier,
                    kind: .album,
                    title: title,
                    oldestCapture: dates.min(),
                    newestCapture: dates.max()
                )
            case let .folder(identifier, title, children):
                install(children, inFolder: identifier)
                return PhotosCollection(identifier: identifier, kind: .folder, title: title)
            }
        }
    }

    func changeToken() -> Data? {
        token
    }

    func export(
        _ resource: PhotosResource,
        ofAsset identifier: String,
        toLocalPath localPath: String,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        if isCancelled() { throw CancellationError() }
        if let exportFailure { throw exportFailure }
        exports.append(Export(identifier: identifier, resource: resource, localPath: localPath))
        let data = bytes[resource.originalFilename] ?? Data()
        guard FileManager.default.createFile(atPath: localPath, contents: data) else {
            throw PhotosLibraryError.failed(code: -1)
        }
        progress(Int64(data.count))
    }
}

/// Assets from the probe library as PhotoKit described them on 2026-09-13 (docs/NOTES.md ▸ iCloud
/// Photos): real identifiers, names, sizes and capture dates — including the three resources an edit
/// adds that are not originals, and the undocumented raw type 16 among them.
enum PhotosProbeLibrary {
    static func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: iso) else { fatalError(
            "unreadable fixture date \(iso)"
        ) }
        return date
    }

    static let editedEarlier = FakePhotosLibrary.Stored(
        asset: PhotosAsset(
            identifier: "BE447348-0557-4515-9D69-CA7218BEEDE3/L0/001",
            captureDate: date("2022-07-24T10:03:29.557Z")
        ),
        resources: [
            PhotosResource(kind: .photo, originalFilename: "IMG_0042.HEIC", byteSize: 3_231_901),
            PhotosResource(
                kind: .derived(rawValue: 7),
                originalFilename: "Adjustments.plist",
                byteSize: 1122
            ),
            PhotosResource(
                kind: .derived(rawValue: 16),
                originalFilename: "IMG_0042O.aae",
                byteSize: 1062
            ),
            PhotosResource(
                kind: .derived(rawValue: 5),
                originalFilename: "FullSizeRender.heic",
                byteSize: 572_317
            )
        ]
    )

    static let editedLater = FakePhotosLibrary.Stored(
        asset: PhotosAsset(
            identifier: "B463853D-0DB4-4559-9881-1DFE7E0B5CAC/L0/001",
            captureDate: date("2022-07-24T10:03:33.625Z")
        ),
        resources: [
            PhotosResource(kind: .photo, originalFilename: "IMG_0043.HEIC", byteSize: 3_262_238),
            PhotosResource(
                kind: .derived(rawValue: 7),
                originalFilename: "Adjustments.plist",
                byteSize: 1122
            ),
            PhotosResource(
                kind: .derived(rawValue: 16),
                originalFilename: "IMG_0043O.aae",
                byteSize: 1062
            ),
            PhotosResource(
                kind: .derived(rawValue: 5),
                originalFilename: "FullSizeRender.heic",
                byteSize: 656_374
            )
        ]
    )

    static let livePhoto = FakePhotosLibrary.Stored(
        asset: PhotosAsset(
            identifier: "0D2C4C49-84F5-4E98-A5BB-211550FCD57E/L0/001",
            captureDate: date("2023-04-30T14:04:12.274Z")
        ),
        resources: [
            PhotosResource(kind: .photo, originalFilename: "IMG_0089.HEIC", byteSize: 1_467_349),
            PhotosResource(kind: .pairedVideo, originalFilename: "IMG_0089.MOV", byteSize: 4_820_568)
        ]
    )

    static let jpeg = FakePhotosLibrary.Stored(
        asset: PhotosAsset(
            identifier: "A7C1E501-B055-4A42-B117-7ED5363067E4/L0/001",
            captureDate: date("2024-10-13T12:34:32.418Z")
        ),
        resources: [
            PhotosResource(
                kind: .photo,
                originalFilename: "camphoto_1254324197.jpg",
                byteSize: 6_570_955
            )
        ]
    )

    static let liveAugust = FakePhotosLibrary.Stored(
        asset: PhotosAsset(
            identifier: "4BEF6B5C-D01C-49F8-BF09-82CD595C4064/L0/001",
            captureDate: date("2026-08-24T12:23:10.522Z")
        ),
        resources: [
            PhotosResource(kind: .photo, originalFilename: "IMG_0222.HEIC", byteSize: 1_782_448),
            PhotosResource(kind: .pairedVideo, originalFilename: "IMG_0222.MOV", byteSize: 8_303_889)
        ]
    )

    static let longVideo = FakePhotosLibrary.Stored(
        asset: PhotosAsset(
            identifier: "091C1B8C-2BEF-44E5-8361-B63B399396CC/L0/001",
            captureDate: date("2026-08-24T13:54:18.000Z")
        ),
        resources: [
            PhotosResource(kind: .video, originalFilename: "IMG_0226.MOV", byteSize: 2_663_801_226)
        ]
    )

    static var all: [FakePhotosLibrary.Stored] {
        [editedEarlier, editedLater, livePhoto, jpeg, liveAugust, longVideo]
    }

    /// An album or a folder in ``albums``.
    indirect enum Node {
        case album(identifier: String, title: String, members: [FakePhotosLibrary.Stored])
        case folder(identifier: String, title: String, children: [Node])
    }

    /// The albums and folders the probe library held once a fixture had been made in Photos on
    /// 2026-09-13 (docs/NOTES.md ▸ iCloud Photos): the real identifiers and titles, the nesting, and
    /// the top level in the order PhotoKit returned it — the Photos sidebar's, newest first, which is
    /// why the empty album `Trips` made last stands ahead of the folder `Trips`. `Nature` holds its real
    /// members; the other albums held photos this fake does not carry, so they hold ones it does, with
    /// the one photo that sat in both `Lisbon`s still shared.
    static var albums: [Node] {
        [
            .album(
                identifier: "CDC3A82B-47C4-412E-9933-67EE5F1546B7/L0/040",
                title: "Trips",
                members: []
            ),
            .album(
                identifier: "B222BDF6-354E-47C9-81EA-B4F1764A1A2E/L0/040",
                title: "Rainbow",
                members: []
            ),
            .album(
                identifier: "E5A802C5-B326-4AAA-86A2-B821E7B80B45/L0/040",
                title: "Empty",
                members: []
            ),
            .album(
                identifier: "0026901F-DC06-49F0-857A-198DD9714C46/L0/040",
                title: "Lisbon",
                members: [jpeg, livePhoto]
            ),
            .folder(
                identifier: "795A9045-9D8D-4090-B94F-A03D9AA47B6E/L0/020",
                title: "Trips",
                children: [
                    .folder(
                        identifier: "E74E444A-6CE3-44F2-8C99-9DB4CE7D2457/L0/020",
                        title: "2025",
                        children: [
                            .album(
                                identifier: "0830E290-1636-4C88-AFD7-3777C4F50025/L0/040",
                                title: "Summer/Beach",
                                members: [longVideo]
                            )
                        ]
                    ),
                    .album(
                        identifier: "41F65BBC-4F30-417B-A373-5126916C3115/L0/040",
                        title: "Lisbon",
                        members: [livePhoto, liveAugust]
                    )
                ]
            ),
            .album(
                identifier: "2A8783B7-5A37-40EE-A48B-5870950158D2/L0/040",
                title: "Rainbow",
                members: [liveAugust]
            ),
            .album(
                identifier: "4173237A-16DA-4109-BAE5-3F76301E921E/L0/040",
                title: "Nature",
                members: [editedEarlier, editedLater]
            )
        ]
    }
}
