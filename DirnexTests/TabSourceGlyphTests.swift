import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// The glyph before a tab chip's label, naming where the tab's listing comes from — in the
/// sidebar's own vocabulary.
@MainActor
@Suite("A tab chip's source glyph", .serialized)
struct TabSourceGlyphTests {
    private static let vault = VaultLocation(
        imagePath: "/Users/u/SecDocs.sparsebundle",
        volumeName: "SecDocs"
    )
    private static let archive = VFSPath(
        backend: .archive(forArchiveAt: "/Users/u/pkg.zip"),
        path: "/inner"
    )
    private static let sftp = SFTPLocation(host: "mac", username: "u")
    private static let ftp = FTPLocation(host: "nas", username: "u")
    private static let bucket = S3Location(host: "h", bucket: "b", region: "r", accessKeyID: "k")
    private static let dav = WebDAVLocation(host: "nas", port: 5006, username: "u")

    private static func server(_ endpoint: ServerEndpoint) -> SidebarPlace {
        .server(ServerConnection(name: "server", endpoint: endpoint))
    }

    /// Each source beside the sidebar row that stands for that kind of place.
    private static let rows: [(LocationSource, SidebarPlace)] = [
        (.folder, .favorite(FavoriteEntry(path: .local("/Users/u/Dev")))),
        (.externalVolume, .volume(MountedVolume(
            name: "USB",
            path: .local("/Volumes/USB"),
            isRoot: false,
            isRemovable: true,
            isEjectable: true,
            isInternal: false,
            isReadOnly: false,
            totalCapacity: nil,
            availableCapacity: nil
        ))),
        (.networkVolume, server(.smb(SMBLocation(host: "nas", share: "media")))),
        (.vault, .vault(vault)),
        (.cloudStorage, .cloudMount(CloudStorageMount(
            directoryName: "Dropbox",
            providerID: "Dropbox",
            accountLabel: nil,
            name: "Dropbox",
            path: .local("/Users/u/Library/CloudStorage/Dropbox"),
            entryDirectory: .local("/Users/u/Library/CloudStorage/Dropbox")
        ))),
        (.iCloudDrive, .iCloudDrive(.local("/Users/u/Library/Mobile Documents/com~apple~CloudDocs"))),
        (.photos, .photos),
        (.archive, .favorite(FavoriteEntry(path: archive))),
        (.sftp, server(.sftp(location: sftp, authentication: .password))),
        (.ftp, server(.ftp(location: ftp, authentication: .password))),
        (.s3, server(.s3(bucket))),
        (.webdav, server(.webdav(location: dav))),
        (.trash, .trash),
        (.recents, .recents),
        (
            .search,
            .savedSearch(SavedSearch(name: "Invoices", query: FileQuery(nameContains: "invoice")))
        )
    ]

    @Test("every source wears the glyph of the sidebar row that stands for it")
    func sidebarVocabulary() {
        #expect(Set(Self.rows.map(\.0)) == Set(LocationSource.allCases))
        let unlocked: Set = [Self.vault.resolvedImagePath]
        for (source, row) in Self.rows {
            #expect(
                SidebarPlacePresentation.symbolName(for: source)
                    == SidebarPlacePresentation.symbolName(for: row, unlockedVaults: unlocked),
                "\(source)"
            )
        }
    }

    @Test("every glyph is a symbol this system draws")
    func symbolsExist() {
        for source in LocationSource.allCases {
            let name = SidebarPlacePresentation.symbolName(for: source)
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
        }
    }

    @Test("the strip draws each tab's source before its label")
    func strip() async throws {
        let windowed = windowedPane(at: .local("/tmp"))
        let pane = windowed.pane
        try await settleUntil { pane.tabs[0].hasLoaded }
        for path in [
            Self.archive,
            VFSPath(backend: .sftp(Self.sftp), path: "/srv"),
            VFSPath(backend: .trash, path: "/"),
            VFSPath(backend: .search, path: "/invoice")
        ] {
            pane.tabs.append(PanelTab(path: path))
        }
        pane.refreshTabBar()
        windowed.window.layoutIfNeeded()

        let expected: [LocationSource] = [.folder, .archive, .sftp, .trash, .search]
        let chips = pane.tabBar.chips
        #expect(chips.map(\.symbolName) == expected.map(SidebarPlacePresentation.symbolName(for:)))
        for chip in chips {
            #expect(!chip.iconFrame.isEmpty, "\(chip.title)")
            #expect(chip.iconFrame.maxX <= chip.labelFrame.minX, "\(chip.title)")
        }
    }

    @Test("a dragged chip carries its glyph, drawn in the chip's text color rather than black")
    func dragImage() throws {
        let bar = TabBarView()
        bar.isActivePane = true
        bar.setTabs([TabBarView.Item(title: "Downloads", symbolName: "folder")], activeIndex: 0)
        bar.frame = NSRect(x: 0, y: 0, width: 400, height: 24)
        bar.layoutSubtreeIfNeeded()
        let chip = bar.chips[0]
        let pixels = try drawn(chip.dragImage())

        let frame = chip.iconFrame.integral
        try #require(!frame.isEmpty)
        // The fill, from inside the chip just past its rounded corner; rows run top-down.
        let fill = pixels.rgba(x: 4, y: pixels.height / 2)
        var ink: [SIMD4<Double>] = []
        for x in Int(frame.minX)..<Int(frame.maxX) {
            for row in Int(frame.minY)..<Int(frame.maxY) {
                let pixel = pixels.rgba(x: x, y: pixels.height - 1 - row)
                if distance(pixel, fill) > 0.3 { ink.append(pixel) }
            }
        }
        #expect(ink.count > 10)
        // A template symbol drawn by hand comes out black whatever the chip's colors. The densest ink
        // is where the glyph covers a pixel fully, so that one is the color it was drawn in.
        let text = try #require(chip.colors.text.usingColorSpace(.deviceRGB))
        let wanted = SIMD4(
            Double(text.redComponent),
            Double(text.greenComponent),
            Double(text.blueComponent),
            1
        )
        let densest = try #require(ink.max { distance($0, fill) < distance($1, fill) })
        #expect(distance(densest, wanted) < 0.3, "\(densest) against \(wanted)")
    }

    private func distance(_ lhs: SIMD4<Double>, _ rhs: SIMD4<Double>) -> Double {
        (0..<4).reduce(0) { $0 + abs(lhs[$1] - rhs[$1]) }
    }

    /// `image` drawn at 1x into an 8-bit RGBA bitmap, the format `BitmapPixels` reads.
    private func drawn(_ image: NSImage) throws -> BitmapPixels {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(image.size.width),
            pixelsHigh: Int(image.size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return try BitmapPixels(rep)
    }
}
