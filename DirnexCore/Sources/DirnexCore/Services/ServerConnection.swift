import Foundation

/// Which remote protocol a saved server speaks — the sidebar picks an icon from it, and the
/// connect flow branches on it (SFTP routes through a `VFSBackend`; SMB rides the OS mounter).
public enum ServerKind: String, Sendable, Codable, CaseIterable {
    case sftp
    case smb
}

/// A saved server's coordinates and auth *method* — everything needed to reconnect, and nothing
/// secret. SFTP carries its `SFTPLocation` plus the chosen `SFTPAuthentication` (a key-file path or
/// the `.password` marker; the password itself stays in the Keychain). SMB carries its `SMBLocation`
/// (guest vs. authenticated is captured by whether `username` is set; any password stays in the
/// Keychain). Serializing an endpoint therefore never spills a credential.
public enum ServerEndpoint: Sendable, Hashable, Codable {
    case sftp(location: SFTPLocation, authentication: SFTPAuthentication)
    case smb(SMBLocation)
}

/// A named, re-connectable remote server — the model behind the sidebar's **Servers** section
/// (PLAN.md §M5 "one place that keeps every saved remote — SFTP and SMB alike"). It unifies the two
/// protocols the app speaks so a single list, store, and sidebar section cover both, rather than a
/// separate SMB-only model.
///
/// Identity is the name, so a server is saved once per name (re-saving under an existing name
/// updates it in place), matching `SavedSearch` and `Workspace`. It holds no secret — only the
/// coordinates and auth method (see `ServerEndpoint`) — so it is safe to persist as plain JSON.
public struct ServerConnection: Sendable, Hashable, Identifiable, Codable {
    /// The user-facing label shown in the sidebar and the connect prompt — and the connection's
    /// identity: at most one saved server per name.
    public var name: String
    /// Where and how to connect, without the secret.
    public var endpoint: ServerEndpoint

    public init(name: String, endpoint: ServerEndpoint) {
        self.name = name
        self.endpoint = endpoint
    }

    public var id: String { name }

    /// Which protocol this server speaks — drives the sidebar icon and the connect branch.
    public var kind: ServerKind {
        switch endpoint {
        case .sftp: return .sftp
        case .smb: return .smb
        }
    }

    /// A compact human-readable address for the sidebar subtitle / tooltip: the SFTP descriptor
    /// (`sftp://user@host:port`) or the SMB URL (`smb://[user@]host[/share]`).
    public var address: String {
        switch endpoint {
        case let .sftp(location, _): return location.descriptor
        case let .smb(location): return location.url
        }
    }
}

/// An ordered, name-de-duplicated collection of saved servers — the model behind the sidebar's
/// Servers section and its right-click management. A pure value type with no persistence or AppKit:
/// the app owns the `UserDefaults` store and the sidebar UI, this owns the ordering and naming rules
/// so they stay unit-testable headless (matching `SavedSearches` and `Workspaces`).
public struct ServerConnections: Sendable, Equatable, Codable {
    /// The saved servers in user order — the order the sidebar presents.
    public private(set) var connections: [ServerConnection]

    public init(connections: [ServerConnection] = []) {
        // Collapse duplicate names on the way in (a hand-edited or legacy store), keeping the
        // first occurrence so a name maps to a single connection.
        var seen = Set<String>()
        self.connections = connections.filter { seen.insert($0.name).inserted }
    }

    /// Whether a connection named `name` exists — drives the connect prompt's replace confirmation.
    public func contains(name: String) -> Bool {
        connections.contains { $0.name == name }
    }

    /// The connection named `name`, or `nil` — the sidebar looks one up by name so a mid-open store
    /// change can't act on the wrong (index-shifted) connection.
    public func connection(named name: String) -> ServerConnection? {
        connections.first { $0.name == name }
    }

    /// Save `connection`: overwrite an existing one with the same name *in place* (keeping its
    /// position), else append. Returns whether it replaced an existing connection — the app only
    /// asks the user to confirm a replacement.
    @discardableResult
    public mutating func save(_ connection: ServerConnection) -> Bool {
        if let index = connections.firstIndex(where: { $0.name == connection.name }) {
            connections[index] = connection
            return true
        }
        connections.append(connection)
        return false
    }

    /// Delete the connection named `name`, if present. Returns whether one was removed.
    @discardableResult
    public mutating func remove(name: String) -> Bool {
        guard let index = connections.firstIndex(where: { $0.name == name }) else { return false }
        connections.remove(at: index)
        return true
    }

    /// Delete the connection at `index`; out-of-range is ignored.
    public mutating func remove(at index: Int) {
        guard connections.indices.contains(index) else { return }
        connections.remove(at: index)
    }

    /// Rename the connection named `name` to `newName` — the sidebar's inline rename. Rejected
    /// (returns `false`, leaving the list unchanged) when `newName` is empty or already names a
    /// *different* connection, so a rename can never collapse two entries into one. Renaming to the
    /// same name is a no-op success.
    @discardableResult
    public mutating func rename(name: String, to newName: String) -> Bool {
        guard let index = connections.firstIndex(where: { $0.name == name }) else { return false }
        guard !newName.isEmpty else { return false }
        guard !connections.contains(where: { $0.name == newName }) || newName == name else {
            return false
        }
        connections[index].name = newName
        return true
    }

    /// Reorder: pull the connection out of `source` and reinsert it so it lands at `destination` in
    /// the *resulting* list (Array semantics, matching the saved-search/hotlist reorder).
    public mutating func move(from source: Int, to destination: Int) {
        guard connections.indices.contains(source) else { return }
        let connection = connections.remove(at: source)
        connections.insert(connection, at: min(max(destination, 0), connections.count))
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case connections
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Route decoding through the de-duplicating initializer so a legacy/corrupt store is
        // sanitized on the way back in.
        self.init(connections: try container.decode([ServerConnection].self, forKey: .connections))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(connections, forKey: .connections)
    }
}
