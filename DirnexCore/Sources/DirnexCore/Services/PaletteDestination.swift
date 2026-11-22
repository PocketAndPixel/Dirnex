import Foundation

/// A place the sidebar offers, or a saved workspace, as a row of the ⌘K palette (PLAN.md §M40
/// Slice 1).
///
/// M20 left places out of the palette because "the palette is a registry of commands, and places are
/// live data". The probe found the second mechanism already built: user scripts are live data, ride
/// in the palette as ``Command``s, and are routed back by their id's prefix
/// (``UserScripts/paletteCommands``). This is the same shape for two more kinds of row, so the palette
/// keeps one list, one ranking and one recents store.
///
/// **An id is resolved again when it is picked**, against the stores as they are then, rather than
/// carrying the place it was built from. A favorite removed while the palette was open, or a saved
/// search renamed since it was last picked, then resolves to nothing instead of opening somewhere the
/// sidebar no longer offers. That is the rule the sidebar's menu follows with its `representedObject`,
/// read the other way round: the palette's recents outlive any one opening, so the id has to be the
/// identity, and the place has to come from the store.
///
/// What a pick *does* stays the app's: a place opens through the sidebar's own `activate(_:)` and a
/// workspace through `applyWorkspace`, so no gesture here can come to disagree with the row it names.
public enum PaletteDestination: Equatable, Sendable {
    case place(SidebarPlace)
    case workspace(Workspace)
}

public extension PaletteDestination {
    /// Where every place's id starts. No registry command uses it (`go.places` is the menu).
    static let placePrefix = "place."
    /// Where every saved workspace's id starts. Not `workspace.`, which the registry's own
    /// `workspace.save` and `workspace.list` use, so a workspace named "save" cannot collide.
    static let workspacePrefix = "openWorkspace."

    /// The id this destination answers to in the palette and in its recents.
    var commandID: String {
        switch self {
        case let .place(place): Self.commandID(for: place)
        case let .workspace(workspace): Self.commandID(forWorkspaceNamed: workspace.name)
        }
    }

    /// The palette group a destination is listed under: Go for a place, Workspace for a workspace,
    /// the menus each one's other faces live in.
    var category: CommandCategory {
        switch self {
        case .place: .navigation
        case .workspace: .workspace
        }
    }

    /// The palette row for this destination, under a title and keywords the app supplies, since both
    /// are words in the user's language and the core has none.
    func command(title: String, keywords: [String] = []) -> Command {
        Command(id: commandID, title: title, category: category, keywords: keywords)
    }

    /// Whether `id` names a destination rather than a registry command or a user script.
    static func isDestination(commandID id: String) -> Bool {
        id.hasPrefix(placePrefix) || id.hasPrefix(workspacePrefix)
    }

    /// The id of `place`, built from what makes it that place and nothing else.
    ///
    /// Each kind keys on the identity its own store already uses: a pin and a volume on their path, a
    /// cloud mount on its directory under `~/Library/CloudStorage` (its display name changes when a
    /// second account of the provider appears), a vault on its image, a saved search and a server on
    /// their names, and a tag on its name folded to lower case, since macOS identifies a tag without
    /// regard to case (``FinderTag``). The kind is part of the id, so a pin and a volume at one path
    /// stay two rows.
    static func commandID(for place: SidebarPlace) -> String {
        let key = switch place {
        case .recents: "recents"
        case .trash: "trash"
        case .photos: "photos"
        case .iCloudDrive: "iCloudDrive"
        case let .savedSearch(search): "search:" + search.name
        case let .favorite(entry): "favorite:" + entry.path.description
        case let .cloudMount(mount): "cloud:" + mount.directoryName
        case let .volume(volume): "volume:" + volume.path.description
        case let .vault(vault): "vault:" + VaultLocation.normalizedPath(vault.imagePath)
        case let .server(server): "server:" + server.name
        case let .tag(tag): "tag:" + tag.name.lowercased()
        }
        return placePrefix + key
    }

    /// The id of the workspace saved as `name`, which is its identity in ``Workspaces``.
    static func commandID(forWorkspaceNamed name: String) -> String {
        workspacePrefix + name
    }

    /// Every destination there is now: the places in the order the sidebar shows them, then the
    /// workspaces in the order they were saved. A place that two sections would both offer is listed
    /// once, at its first appearance.
    static func all(places groups: [SidebarPlaceGroup], workspaces: [Workspace]) -> [
        PaletteDestination
    ] {
        var seen = Set<String>()
        var result: [PaletteDestination] = []
        let candidates = groups.flatMap(\.places).map(PaletteDestination.place)
            + workspaces.map(PaletteDestination.workspace)
        for candidate in candidates where seen.insert(candidate.commandID).inserted {
            result.append(candidate)
        }
        return result
    }

    /// The destination `id` names in the stores as they are now, or `nil` when it has gone, or when
    /// `id` names no destination at all.
    static func resolve(
        _ id: String,
        places groups: [SidebarPlaceGroup],
        workspaces: [Workspace]
    ) -> PaletteDestination? {
        if id.hasPrefix(workspacePrefix) {
            let name = String(id.dropFirst(workspacePrefix.count))
            return workspaces.first { $0.name == name }.map(PaletteDestination.workspace)
        }
        guard id.hasPrefix(placePrefix) else { return nil }
        return groups.lazy.flatMap(\.places).first { commandID(for: $0) == id }.map(
            PaletteDestination.place
        )
    }

    /// Whether picking this may be written into the palette's recents.
    ///
    /// Not for a place whose folder is inside an unlocked vault, which includes the vault's own volume
    /// in Volumes: the recents are a memory the user did not ask for, and ``VaultPrivacy`` keeps vault
    /// paths out of every one of those (PLAN.md §6, M19's row). The vault's *row* is not covered,
    /// since its id carries the image's path, which is outside the vault and already a saved row of
    /// its own. A workspace is something the user named on purpose, as §M19 says of workspaces.
    func isRememberable(vaultMountPoints: [String]) -> Bool {
        guard case let .place(place) = self, let path = place.path, path.backend == .local else {
            return true
        }
        return !VaultPrivacy.isInside(path.path, mountPoints: vaultMountPoints)
    }
}
