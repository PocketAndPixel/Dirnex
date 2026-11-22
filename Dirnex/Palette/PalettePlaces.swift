import DirnexCore

/// The ⌘K palette's rows for every place the sidebar offers and every saved workspace (PLAN.md §M40
/// Slice 1).
///
/// The ids, the identity behind them and the vault rule are ``PaletteDestination``'s, in the core.
/// What is here is the words: a place is called what its sidebar row and its Go ▸ Places item call
/// it, through the one ``SidebarPlacePresentation``, so the three cannot come to disagree about a
/// name the user gave a Cloud row.
@MainActor
enum PalettePlaces {
    /// One row per destination, places first in the sidebar's order, then workspaces.
    ///
    /// A place's keywords are its section's name, so "fav" lists the pins and "vol" the disks. A
    /// workspace's are the word Workspace. Each in the user's language and in English, as
    /// `LocalizedCatalog` does for every command: a translation adds a way to find a row and never
    /// takes the English one away (`PaletteEnglishReachabilityTests`).
    static func commands(
        groups: [SidebarPlaceGroup],
        workspaces: [Workspace],
        names: SidebarItemNames = CloudPlaceNameStore.load()
    ) -> [Command] {
        var sections: [String: SidebarSection] = [:]
        for group in groups {
            guard let section = group.section else { continue }
            for place in group.places {
                let id = PaletteDestination.commandID(for: place)
                if sections[id] == nil { sections[id] = section }
            }
        }
        let workspaceWords = words(
            CommandCategory.workspace.localizedTitle,
            CommandCategory.workspace.title
        )
        return PaletteDestination.all(places: groups, workspaces: workspaces).map { destination in
            switch destination {
            case let .place(place):
                destination.command(
                    title: SidebarPlacePresentation.title(for: place, names: names),
                    keywords: sections[destination.commandID].map {
                        words(LocalizedCatalog.title(for: $0), $0.title)
                    } ?? []
                )
            case let .workspace(workspace):
                destination.command(title: workspace.name, keywords: workspaceWords)
            }
        }
    }

    /// `localized` and `english`, once each: the same word twice in an English build.
    private static func words(_ localized: String, _ english: String) -> [String] {
        localized == english ? [english] : [localized, english]
    }
}
