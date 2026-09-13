import Foundation
import Testing

@testable import DirnexCore

/// The pure rules of the Photos library's folder view (PLAN.md §M28): which path is which folder,
/// which month an asset lands in, and what each original is called.
@Suite("Photos layout")
struct PhotosLayoutTests {
    private let layout = PhotosLayout(timeZone: TimeZone(secondsFromGMT: 0) ?? .current)

    private func path(_ raw: String) -> VFSPath {
        VFSPath(backend: .photos, path: raw)
    }

    private func asset(_ identifier: String, _ iso: String?) -> PhotosAsset {
        PhotosAsset(identifier: identifier, captureDate: iso.map(PhotosProbeLibrary.date))
    }

    private func photo(_ name: String) -> [PhotosResource] {
        [PhotosResource(kind: .photo, originalFilename: name, byteSize: 1)]
    }

    @Test("paths address the root, a year, a month, Undated and one original")
    func locations() {
        let august = PhotosLayout.Folder.month(year: 2026, month: 8)
        #expect(layout.location(of: path("/")) == .root)
        #expect(layout.location(of: path("/2026")) == .folder(.year(2026)))
        #expect(layout.location(of: path("/2026/2026-08")) == .folder(august))
        #expect(
            layout.location(of: path("/2026/2026-08/IMG_0089.HEIC"))
                == .original(name: "IMG_0089.HEIC", in: august)
        )
        #expect(layout.location(of: path("/Undated")) == .folder(.undated))
        #expect(
            layout.location(of: path("/Undated/IMG_0001.JPG"))
                == .original(name: "IMG_0001.JPG", in: .undated)
        )
    }

    /// A path that reads back as a *different* folder than the one typed is a wrong answer rather
    /// than a missing one, so everything the layout never produces must address nothing.
    @Test(
        "a path the layout never produces addresses nothing",
        arguments: [
            "/26", "/20266", "/undated", "/Albums", "/2026/08", "/2026/2026-8", "/2026/2025-08",
            "/2026/2026-00", "/2026/2026-13", "/2026/IMG_0089.HEIC", "/2026/2026-08/a/b",
            "/Undated/a/b", "/0000",
        ]
    )
    func rejects(_ raw: String) {
        #expect(layout.location(of: path(raw)) == nil)
    }

    @Test("every folder's own path reads back as that folder")
    func roundTrip() {
        let folders: [PhotosLayout.Folder] = [
            .year(2026), .year(987), .month(year: 2026, month: 1), .month(year: 2026, month: 12),
            .undated
        ]
        for folder in folders {
            #expect(layout.location(of: layout.path(of: folder)) == .folder(folder))
        }
        #expect(layout.path(of: .month(year: 2026, month: 8)).path == "/2026/2026-08")
        #expect(layout.path(of: .year(987)).path == "/0987")
    }

    @Test("a month is cut in the layout's time zone, not in UTC")
    func timeZone() throws {
        let lateEvening = PhotosProbeLibrary.date("2026-08-31T22:30:00.000Z")
        let helsinki = try #require(TimeZone(identifier: "Europe/Helsinki"))
        #expect(layout.month(containing: lateEvening) == .month(year: 2026, month: 8))
        #expect(
            PhotosLayout(timeZone: helsinki).month(containing: lateEvening) == .month(
                year: 2026,
                month: 9
            )
        )
        #expect(layout.month(containing: nil) == .undated)
    }

    @Test("a folder's interval is the whole month and nothing of the next")
    func intervals() throws {
        let august = try #require(layout.interval(of: .month(year: 2026, month: 8)))
        #expect(august.start == PhotosProbeLibrary.date("2026-08-01T00:00:00.000Z"))
        #expect(august.end == PhotosProbeLibrary.date("2026-09-01T00:00:00.000Z"))
        #expect(layout.interval(of: .undated) == nil)
    }

    @Test("a folder takes exactly its own assets")
    func membership() {
        let assets = [
            asset("a", "2026-01-01T00:00:00.000Z"),
            asset("b", "2025-12-31T23:59:59.999Z"),
            asset("c", "2026-08-24T12:23:10.522Z"),
            asset("d", nil)
        ]
        #expect(layout.members(of: .year(2026), among: assets).map(\.identifier) == ["a", "c"])
        #expect(layout.members(of: .year(2025), among: assets).map(\.identifier) == ["b"])
        #expect(
            layout.members(of: .month(year: 2026, month: 8), among: assets).map(\.identifier) == [
                "c"
            ]
        )
        #expect(layout.members(of: .undated, among: assets).map(\.identifier) == ["d"])
    }

    @Test("a Live Photo is two rows, the photo before its movie")
    func livePhoto() {
        let item = PhotosProbeLibrary.livePhoto
        // Handed over movie-first, which is not an order the rows may keep.
        let rows = layout.rows(
            for: [item.asset],
            resources: [item.asset.identifier: item.resources.reversed()]
        )
        #expect(rows.map(\.name) == ["IMG_0089.HEIC", "IMG_0089.MOV"])
        #expect(rows.map(\.resource.kind) == [.photo, .pairedVideo])
        #expect(Set(rows.map(\.assetIdentifier)) == [item.asset.identifier])
    }

    @Test("an edit's render, its adjustments and the undocumented type-16 envelope are not rows")
    func editedPhoto() {
        let item = PhotosProbeLibrary.editedLater
        let rows = layout.rows(for: [item.asset], resources: [item.asset.identifier: item.resources])
        #expect(rows.map(\.name) == ["IMG_0043.HEIC"])
    }

    @Test("rows follow capture order across assets")
    func captureOrder() {
        let items = [PhotosProbeLibrary.longVideo, PhotosProbeLibrary.liveAugust]
        let resources = Dictionary(
            uniqueKeysWithValues: items.map { ($0.asset.identifier, $0.resources) }
        )
        let rows = layout.rows(for: items.map(\.asset), resources: resources)
        #expect(rows.map(\.name) == ["IMG_0222.HEIC", "IMG_0222.MOV", "IMG_0226.MOV"])
    }

    @Test("a colliding name is numbered in capture order, whatever its case")
    func collisions() {
        let assets = [
            asset("late", "2026-08-24T12:00:02.000Z"),
            asset("early", "2026-08-24T12:00:00.000Z"),
            asset("middle", "2026-08-24T12:00:01.000Z")
        ]
        let resources = [
            "early": photo("IMG_0001.JPG"),
            "middle": photo("img_0001.jpg"),
            "late": photo("IMG_0001.JPG")
        ]
        let rows = layout.rows(for: assets, resources: resources)
        #expect(rows.map(\.name) == ["IMG_0001.JPG", "img_0001 (2).jpg", "IMG_0001 (3).JPG"])
        #expect(rows.map(\.assetIdentifier) == ["early", "middle", "late"])
    }

    /// APFS compares names normalization-insensitively, so a precomposed and a decomposed "é" would
    /// land on one file when copied out — which makes them one name here too.
    @Test("names that differ only in Unicode normalization collide")
    func normalization() {
        let composed = "Caf\u{E9}.jpg"
        let decomposed = "Cafe\u{301}.jpg"
        let rows = layout.rows(
            for: [
                asset("first", "2026-08-24T12:00:00.000Z"),
                asset("second", "2026-08-24T12:00:01.000Z")
            ],
            resources: ["first": photo(composed), "second": photo(decomposed)]
        )
        #expect(rows.map(\.name) == [composed, "Cafe\u{301} (2).jpg"])
    }

    @Test(
        "a tie in capture time breaks on the identifier, so fetch order cannot change the numbering"
    )
    func tieBreak() {
        let same = "2026-08-24T12:00:00.000Z"
        let resources = ["A": photo("IMG_0001.JPG"), "B": photo("IMG_0001.JPG")]
        let forward = layout.rows(for: [asset("A", same), asset("B", same)], resources: resources)
        let backward = layout.rows(for: [asset("B", same), asset("A", same)], resources: resources)
        #expect(forward == backward)
        #expect(forward.map(\.assetIdentifier) == ["A", "B"])
    }

    @Test("an original name that is not a usable path component is made into one")
    func unusableNames() {
        let august = PhotosLayout.Folder.month(year: 2026, month: 8)
        let rows = layout.rows(
            for: [
                asset("slash", "2026-08-24T12:00:00.000Z"),
                asset("empty", "2026-08-24T12:00:01.000Z"),
                asset("dots", "2026-08-24T12:00:02.000Z")
            ],
            resources: ["slash": photo("a/b.jpg"), "empty": photo(""), "dots": photo("..")]
        )
        #expect(rows.map(\.name) == ["a:b.jpg", "Untitled", "_.."])
        #expect(
            layout.location(of: layout.path(of: august).appending("a:b.jpg"))
                == .original(name: "a:b.jpg", in: august)
        )
    }
}
