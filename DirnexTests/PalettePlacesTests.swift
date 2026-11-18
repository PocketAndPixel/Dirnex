import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The ⌘K palette's places and workspaces (PLAN.md §M40 Slice 1): what each row is called and found
/// by, and the recents learning ids that are not the registry's. The ids and their resolution are the
/// core's (`PaletteDestinationTests`).
///
/// Language-agnostic, as `PaletteEnglishReachabilityTests` is: the test host runs in whatever
/// language Dirnex is pinned to on the machine running it.
@Suite("Palette places")
@MainActor
struct PalettePlacesTests {
    private let favorite = FavoriteEntry(name: "Projects", path: .local("/Users/oleg/Dev"))
    private let tag = FinderTag(name: "Red", color: .red)
    private let volume = MountedVolume(
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

    private var groups: [SidebarPlaceGroup] {
        SidebarPlaces.groups(from: SidebarPlaceSources(
            favorites: [favorite],
            volumes: [volume],
            tags: [tag]
        ))
    }

    private func workspace(_ name: String) -> Workspace {
        let pane = WorkspacePane(tabs: [WorkspaceTab(path: .local("/"))], activeTabIndex: 0)
        return Workspace(name: name, left: pane, right: pane)
    }

    private func rows() -> [Command] {
        PalettePlaces.commands(
            groups: groups,
            workspaces: [workspace("Work")],
            names: SidebarItemNames()
        )
    }

    @Test("a place's row is called what its sidebar row is called, under the core's id")
    func titlesComeFromTheSidebar() {
        let places = groups.flatMap(\.places)
        let placeRows = rows().filter { $0.category == .navigation }
        #expect(placeRows.map(\.id) == places.map(PaletteDestination.commandID(for:)))
        #expect(placeRows.map(\.title) == places.map {
            SidebarPlacePresentation.title(for: $0, names: SidebarItemNames())
        })
        // The pin's own name, not its folder's.
        #expect(placeRows.contains { $0.title == "Projects" })
    }

    @Test("a place is found by its section's name, in the user's language and in English")
    func sectionNameIsAKeyword() throws {
        let pin = try #require(
            rows().first { $0.id == PaletteDestination.commandID(for: .favorite(favorite)) }
        )
        #expect(pin.keywords.contains(SidebarSection.favorites.title))
        #expect(pin.keywords.contains(LocalizedCatalog.title(for: .favorites)))
        let disk = try #require(
            rows().first { $0.id == PaletteDestination.commandID(for: .volume(volume)) }
        )
        #expect(disk.keywords.contains(SidebarSection.volumes.title))
        #expect(!disk.keywords.contains(SidebarSection.favorites.title))
    }

    @Test("Recents and the Trash, which have no section, carry no keyword")
    func headerlessPlacesHaveNoKeywords() throws {
        for place in [SidebarPlace.recents, .trash] {
            let row = try #require(
                rows().first { $0.id == PaletteDestination.commandID(for: place) }
            )
            #expect(row.keywords.isEmpty)
        }
    }

    @Test("a workspace's row is its name, under Workspace, found by the word Workspace")
    func workspaceRow() throws {
        let row = try #require(rows().last)
        #expect(row.id == PaletteDestination.commandID(forWorkspaceNamed: "Work"))
        #expect(row.title == "Work")
        #expect(row.category == .workspace)
        #expect(row.keywords.contains("Workspace"))
        #expect(row.keywords.contains(CommandCategory.workspace.localizedTitle))
    }

    @Test("typing the start of a pin's name finds it in the palette's ranking")
    func aPinIsFoundByName() {
        let offered = LocalizedCatalog.all + rows()
        let top = CommandMatcher.search("projects", in: offered).first
        #expect(top?.command.id == PaletteDestination.commandID(for: .favorite(favorite)))
    }

    @Test("no destination's id is a registry command's or a script's")
    func idsStayApart() {
        let registry = Set(LocalizedCatalog.all.map(\.id))
        for row in rows() {
            #expect(!registry.contains(row.id))
            #expect(UserScript.name(fromCommandID: row.id) == nil)
        }
    }

    // MARK: - Recents

    @Test("the recents keep a place, a workspace and a script the palette offers")
    func recentsKeepWhatIsOffered() {
        let recents = CommandRecents(defaults: ScratchDefaults.fresh())
        let pin = PaletteDestination.commandID(for: .favorite(favorite))
        let work = PaletteDestination.commandID(forWorkspaceNamed: "Work")
        let script = "userScript.Hello"
        let offered: Set = ["file.copy", pin, work, script]
        recents.record("file.copy", among: offered)
        recents.record(pin, among: offered)
        recents.record(script, among: offered)
        recents.record(work, among: offered)
        #expect(recents.ids(among: offered) == [work, script, pin, "file.copy"])
    }

    @Test("a place no longer offered drops out of the recents")
    func recentsDropWhatHasGone() {
        let recents = CommandRecents(defaults: ScratchDefaults.fresh())
        let pin = PaletteDestination.commandID(for: .favorite(favorite))
        recents.record(pin, among: [pin, "file.copy"])
        recents.record("file.copy", among: [pin, "file.copy"])
        #expect(recents.ids(among: ["file.copy"]) == ["file.copy"])
        recents.record("file.move", among: ["file.copy", "file.move"])
        // Gone from the store too, so it no longer holds one of the twelve places.
        #expect(recents.ids(among: [pin, "file.copy", "file.move"]) == ["file.move", "file.copy"])
    }
}
