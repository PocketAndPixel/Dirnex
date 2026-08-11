import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// The keyboard and mouse faces of **Places** (PLAN.md §M20 Slice 3).
///
/// The claim the milestone rests on is *reachability*: with the sidebar collapsed, every place has
/// to stay one gesture away. So the tests here are about the routes existing in **every** mode —
/// which is exactly what no screenshot of one location can show, since the path bar renders six
/// different ways and five of them were only reachable by connecting, deleting or searching first.
@Suite("Places: the keyboard and the path bar")
@MainActor
struct PathBarPlacesTests {
    private func bar(_ path: VFSPath) -> PathBarView {
        let bar = PathBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 20))
        bar.setPath(path)
        return bar
    }

    /// The leading glyph, wherever the render path put it: bare in the crumb row, or nested in the
    /// virtual label's own row beside its text.
    private func leadingGlyph(_ bar: PathBarView) -> NSButton? {
        let first = bar.crumbStack.arrangedSubviews.first
        if let button = first as? NSButton { return button }
        return (first as? NSStackView)?.arrangedSubviews.first as? NSButton
    }

    private var archivePath: VFSPath {
        VFSPath(backend: .archive(forArchiveAt: "/Users/oleg/Downloads/pkg.zip"), path: "/inner")
    }

    private var sftpPath: VFSPath {
        VFSPath(
            backend: .sftp(SFTPLocation(host: "mac", username: "oleg")),
            path: "/Users/oleg/Dev"
        )
    }

    private var ftpPath: VFSPath {
        VFSPath(backend: FTPLocation(host: "nas", username: "oleg").backendID, path: "/share")
    }

    private var searchPath: VFSPath { VFSPath(backend: .search, path: "/report") }
    private var recentsPath: VFSPath {
        VFSPath(
            backend: .search,
            path: "/" + PanelViewController.ResultsPresentation.recentsIdentity
        )
    }

    // MARK: - The mouse face exists in every mode

    @Test("every location the path bar can draw carries the Places button")
    func everyModeHasTheButton() {
        // The six render paths `rebuildContents` dispatches to, named by what a user did to get
        // there. The two the sidebar used to be the only way back out of — the Trash and a results
        // listing — are the point: `installVirtualLabel` replaces the whole crumb row for those, so
        // a control on the root crumb would have been missing exactly there.
        let locations: [(String, VFSPath)] = [
            ("local", .local("/Users/oleg")),
            ("archive", archivePath),
            ("sftp", sftpPath),
            ("ftp", ftpPath),
            ("trash", VFSPath(backend: .trash, path: "/")),
            ("search results", searchPath),
            ("recents", recentsPath),
            ("iCloud Drive", ICloudLocation.mergedPath)
        ]
        for (name, path) in locations {
            let glyph = leadingGlyph(bar(path))
            #expect(glyph != nil, "\(name): no leading glyph")
            // Assert the selector by *name*: `#selector` would keep naming the right one even after
            // the view stopped implementing it, which is the state this exists to catch.
            #expect(glyph?.action == NSSelectorFromString("showPlaces:"), "\(name): wrong action")
            #expect(glyph?.image != nil, "\(name): no symbol")
            // Silent to VoiceOver without it, being a control with no title.
            #expect(glyph?.accessibilityLabel() == PathBarView.placesTitle, "\(name): no label")
            #expect(glyph?.toolTip == PathBarView.placesTitle, "\(name): no tooltip")
        }
    }

    @Test("the button reports intent to the pane rather than opening the menu itself")
    func theBarOnlyReportsIntent() {
        // Which pane a place opens in is the pane's business (`PathBarViewDelegate`'s contract, and
        // the reason `showPlaces` makes its pane active first — a click on the *inactive* pane's
        // glyph never moves first responder).
        final class Spy: NSObject, PathBarViewDelegate {
            var requests = 0
            func pathBar(_ bar: PathBarView, didActivate path: VFSPath) {}
            func pathBar(_ bar: PathBarView, didCommit rawText: String, resolved: VFSPath) {}
            func pathBarDidCancel(_ bar: PathBarView) {}
            func pathBarDidBeginEditing(_ bar: PathBarView) {}
            func pathBarDidRequestPlaces(_ bar: PathBarView) { requests += 1 }
            func pathBar(
                _ bar: PathBarView,
                childDirectoriesOf directory: VFSPath
            ) async -> [String] { [] }
        }
        let spy = Spy()
        let bar = bar(.local("/Users/oleg"))
        bar.delegate = spy
        leadingGlyph(bar)?.performClick(nil)
        #expect(spy.requests == 1)
    }

    // MARK: - One glyph vocabulary, not two

    @Test("the glyph is the one the sidebar row for the same location wears")
    func glyphsAgreeWithTheSidebar() {
        // A second spelling of these strings is a drift nothing would catch: the two surfaces would
        // simply stop matching, in the one place they are meant to say "the same place".
        #expect(
            PathBarView.rootSymbolName(for: sftpPath)
                == SidebarPlacePresentation.serverSymbolName(for: .sftp)
        )
        #expect(
            PathBarView.rootSymbolName(for: ftpPath)
                == SidebarPlacePresentation.serverSymbolName(for: .ftp)
        )
        // A local trail is rooted at the boot volume's crumb whatever disk the directory sits on,
        // so it wears that volume's own glyph.
        let bootVolume = MountedVolume(
            name: "Macintosh HD",
            path: .local("/"),
            isRoot: true,
            isRemovable: false,
            isEjectable: false,
            isInternal: true,
            isReadOnly: false,
            totalCapacity: nil,
            availableCapacity: nil
        )
        #expect(PathBarView.rootSymbolName(for: .local("/Users/oleg")) == bootVolume.symbolName)
    }

    // MARK: - The keyboard face

    /// Every item in the built main menu, flattened across submenus.
    private func allItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map(allItems) ?? []) }
    }

    @Test("⌘G is bound to the pane's popup, and the menu bar is what delivers it")
    func theShortcutIsDeliverable() throws {
        #expect(CommandBinding.selector(for: "go.places") == NSSelectorFromString("showPlaces:"))
        #expect(PanelViewController.instancesRespond(to: NSSelectorFromString("showPlaces:")))

        // The regression guard for the finding that shaped this slice: **an item carrying a submenu
        // never fires its own key equivalent** — measured, `performKeyEquivalent` returns false and
        // the action never runs, while the item still reports `isEnabled == true`. The menu bar is
        // the app's only dispatch path for a command shortcut, so ⌘G has to ride a plain item;
        // tidying the two Go entries into one submenu item would draw a shortcut that is dead.
        //
        // Asserted against the **built menu**, not against `commandItem(for:)` in isolation: the
        // item alone is well-formed whether or not the layout still contains it, which a negative
        // control showed — removing it from the Go menu left this passing.
        let items = allItems(MainMenuBuilder.build())
        let places = try #require(
            items.first { $0.action == NSSelectorFromString("showPlaces:") },
            "the menu bar carries no item that opens Places"
        )
        #expect(places.submenu == nil)
        #expect(places.keyEquivalent == "g")
        #expect(places.keyEquivalentModifierMask == .command)

        // And the browsable submenu is still there beside it — the face you read rather than
        // recall, and the one that must never be the shortcut's carrier.
        let submenu = try #require(
            items.first { $0.submenu?.delegate === PlacesMenu.shared },
            "the menu bar carries no Places submenu"
        )
        #expect(submenu.keyEquivalent.isEmpty)

        // Favorites rides the same dispatch path one section down, and the pair has to stay a pair:
        // the two chords are ⌘F and ⌘G precisely because neither is claimed by anything else in the
        // built menu. Asserted here rather than in the core, because the registry can hold a chord
        // the menu bar never delivers — which is the whole finding above.
        let favorites = try #require(
            items.first { $0.action == NSSelectorFromString("showFavorites:") },
            "the menu bar carries no item that opens Favorites"
        )
        #expect(favorites.submenu == nil)
        #expect(favorites.keyEquivalent == "f")
        #expect(favorites.keyEquivalentModifierMask == .command)

        // Nothing else in the menu bar answers either chord — a second claimant is what would make
        // one of them dead, and it is invisible from the registry side.
        let claimants = items.filter {
            $0.keyEquivalentModifierMask == .command && ["f", "g"].contains($0.keyEquivalent)
        }
        #expect(claimants.count == 2)
    }

    @Test("all three faces fill from one builder")
    func oneFunnel() {
        // `NSMenu.delegate` is weak and every menu is disposable, so a per-caller builder would be
        // a menu that empties itself — and, worse, three lists that could come to differ.
        #expect(PlacesMenu.shared === PlacesMenu.shared)
        let menu = PlacesMenu.shared.makeMenu()
        #expect(menu.delegate === PlacesMenu.shared)
    }
}
