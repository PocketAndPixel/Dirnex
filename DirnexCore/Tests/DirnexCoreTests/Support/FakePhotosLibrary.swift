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

    private(set) var intervalsAsked: [DateInterval?] = []
    private(set) var resourceRequests: [[String]] = []
    private(set) var exports: [Export] = []

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
}
