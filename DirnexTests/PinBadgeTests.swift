import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// A pinned folder marked with where it lives: which mark, which pins get one, and that the folder
/// under the mark is the same folder its unmarked neighbours draw.
@MainActor
@Suite("A pinned folder's badge")
struct PinBadgeTests {
    private static let vault = VaultLocation(
        imagePath: "/Users/u/Taxes.sparsebundle",
        volumeName: "Taxes"
    )

    /// Hand-made, so no test reads this Mac's mounts or the developer's own vaults.
    private static func context(unlocked: Bool = false) -> PinBadgeContext {
        PinBadgeContext(
            mounts: [
                MountTableEntry(mountPoint: "/", isLocal: true),
                MountTableEntry(mountPoint: "/Volumes/NAS", isLocal: false)
            ] + (unlocked ? [MountTableEntry(mountPoint: "/Volumes/Taxes", isLocal: true)] : []),
            vaultMountPoints: unlocked ? ["/Volumes/Taxes"] : [],
            vaultVolumeNames: [vault.volumeName]
        )
    }

    private static func badge(_ entry: FavoriteEntry, unlocked: Bool = false) -> String? {
        SidebarPlacePresentation.badgeSymbolName(
            for: .favorite(entry),
            in: context(unlocked: unlocked)
        )
    }

    // MARK: - The vocabulary

    @Test("every mark is the glyph its kind of place wears elsewhere, or that glyph filled")
    func vocabulary() throws {
        for source in LocationSource.allCases where source != .folder && source != .archive {
            let mark = try #require(
                SidebarPlacePresentation.badgeSymbolName(for: source, isUnlockedVault: true),
                "\(source)"
            )
            let own = SidebarPlacePresentation.symbolName(for: source)
            #expect(mark == own || mark == own + ".fill", "\(source): \(mark)")
            #expect(NSImage(systemSymbolName: mark, accessibilityDescription: nil) != nil, "\(mark)")
        }
    }

    @Test("WebDAV keeps its server row's outline globe, which SFTP's network glyph is not")
    func webDAVGlobe() {
        let dav = SidebarPlacePresentation.badgeSymbolName(for: .webdav, isUnlockedVault: false)
        #expect(dav == SidebarPlacePresentation.serverSymbolName(for: .webdav))
        #expect(dav == "globe")
        #expect(dav != SidebarPlacePresentation.badgeSymbolName(for: .sftp, isUnlockedVault: false))
    }

    @Test("a vault's mark is its row's padlock, open or shut")
    func vaultPadlock() {
        let pin = FavoriteEntry(path: .local("/Volumes/Taxes/2026"))
        #expect(Self.badge(pin) == SidebarPlacePresentation.vaultSymbolName(isUnlocked: false))
        #expect(
            Self.badge(pin, unlocked: true) == SidebarPlacePresentation.vaultSymbolName(
                isUnlocked: true
            )
        )
    }

    // MARK: - Which pins carry one

    @Test("a folder on this Mac's own disk, a standard folder and an archive's folder carry none")
    func unmarked() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(Self.badge(FavoriteEntry(path: .local("/Users/u/Projects"))) == nil)
        #expect(Self.badge(FavoriteEntry(path: .local(home + "/Downloads"))) == nil)
        let archive = VFSPath(backend: .archive(forArchiveAt: "/Users/u/a.zip"), path: "/src")
        #expect(Self.badge(FavoriteEntry(path: archive)) == nil)
    }

    @Test("a folder on a server is a plain folder marked with its protocol")
    func remote() {
        let sftp = SFTPLocation(host: "mac", username: "u")
        let pin = FavoriteEntry(path: VFSPath(backend: .sftp(sftp), path: "/srv"))
        #expect(SidebarPlacePresentation.symbolName(for: .favorite(pin)) == "folder")
        #expect(Self.badge(pin) == SidebarPlacePresentation.serverSymbolName(for: .sftp))
    }

    @Test("a pin on a share that is not mounted still says it is on the network")
    func unmountedShare() {
        let share = SMBLocation(host: "nas", username: "u").share(named: "media")
        let pin = FavoriteEntry(path: .local("/Volumes/media/TV"), endpoint: .smb(share))
        #expect(Self.badge(pin) == "externaldrive.connected.to.line.below.fill")
    }

    @Test("only a pinned folder is ever marked")
    func otherPlaces() {
        #expect(SidebarPlacePresentation.badgeSymbolName(for: .trash, in: Self.context()) == nil)
        #expect(
            SidebarPlacePresentation.badgeSymbolName(for: .vault(Self.vault), in: Self.context()) == nil
        )
    }

    // MARK: - Go ▸ Places

    @Test("Go ▸ Places marks a pin as its sidebar row does, and an unmarked build draws the folder")
    func placesMenu() throws {
        let sftp = SFTPLocation(host: "mac", username: "u")
        let pin = FavoriteEntry(path: VFSPath(backend: .sftp(sftp), path: "/srv"))
        let groups = [SidebarPlaceGroup(section: .favorites, places: [.favorite(pin)])]
        func image(pins: PinBadgeContext?) throws -> NSImage {
            let menu = NSMenu()
            PlacesMenu().build(menu, groups: groups, pins: pins)
            let section = try #require(menu.items.first?.submenu)
            return try #require(section.items.first { !$0.isAlternate }?.image)
        }
        let size = try image(pins: nil).size
        let box = NSSize(width: max(size.width, size.height), height: max(size.width, size.height))
        let plain = try Self.alpha(
            BadgedGlyph.image(symbol: "folder", pointSize: 14, badge: nil),
            fittedIn: box
        )
        let marked = try Self.alpha(image(pins: Self.context()), fittedIn: box)
        let unmarked = try Self.alpha(image(pins: nil), fittedIn: box)
        #expect(unmarked == plain)
        #expect(marked != plain)
        let expected = try Self.alpha(
            BadgedGlyph.image(symbol: "folder", pointSize: 14, badge: "network"),
            fittedIn: box
        )
        #expect(marked == expected)
    }

    // MARK: - The drawing

    @Test("the marked glyph is one template image the size of the box it is shown in")
    func template() {
        let box = NSSize(width: SidebarCellView.iconSide, height: SidebarCellView.iconSide)
        let image = BadgedGlyph.image(
            symbol: "folder",
            pointSize: 15,
            badge: "shippingbox.fill",
            canvas: box
        )
        #expect(image.isTemplate)
        #expect(image.size == box)
        let plain = BadgedGlyph.image(symbol: "folder", pointSize: 15, badge: nil, canvas: box)
        #expect(plain.size != box, "an unmarked glyph keeps its own size, as it always has")
    }

    /// The image view scales a 21 pt-wide folder into its 18 pt box, so a marked folder drawn any
    /// other way would sit at a different size or offset from the unmarked ones around it.
    @Test(
        "away from the corner, a marked folder is pixel for pixel the folder an unmarked row draws"
    )
    func folderLinesUp() throws {
        let box = NSSize(width: SidebarCellView.iconSide, height: SidebarCellView.iconSide)
        let marked = try Self.alpha(
            BadgedGlyph.image(
                symbol: "folder",
                pointSize: 15,
                badge: "shippingbox.fill",
                canvas: box
            ),
            fittedIn: box
        )
        let plain = try Self.alpha(
            BadgedGlyph.image(symbol: "folder", pointSize: 15, badge: nil),
            fittedIn: box
        )
        let side = Int(box.width * 2)
        // The mark's box is 13 pt of the 18, so it reaches past the middle. The top 4 pt and the
        // left 4 pt are out of its reach, halo and all, and hold the folder's tab and its left edge.
        let band = 8
        var differences = (clear: 0, corner: 0), folderInk = 0
        for row in 0..<side {
            for column in 0..<side {
                let index = row * side + column
                // Rows run top-down in the bitmap.
                let outsideTheMark = row < band || column < band
                if outsideTheMark, plain[index] > 0 { folderInk += 1 }
                guard marked[index] != plain[index] else { continue }
                if outsideTheMark { differences.clear += 1 }
                if row >= side - band, column >= side - band { differences.corner += 1 }
            }
        }
        #expect(folderInk > 0, "the bands compared hold some of the folder")
        #expect(differences.clear == 0)
        #expect(differences.corner > 0, "the mark is drawn, and cut out of the folder")
    }

    /// `image` drawn as the sidebar's image view would draw it in a `box`, at 2x: the alpha of every
    /// pixel, top row first.
    private static func alpha(_ image: NSImage, fittedIn box: NSSize) throws -> [UInt8] {
        let side = Int(box.width * 2)
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side,
            pixelsHigh: side,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: side * 4,
            bitsPerPixel: 32
        ))
        rep.size = box
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: BadgedGlyph.fitted(image.size, in: NSRect(origin: .zero, size: box)))
        NSGraphicsContext.restoreGraphicsState()
        let data = try #require(rep.bitmapData)
        return (0..<side * side).map { data[$0 * 4 + 3] }
    }
}
