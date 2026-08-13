import Foundation

/// Which remote protocol a saved server speaks — the sidebar picks an icon from it, and the
/// connect flow branches on it (SFTP and FTP each route through a `VFSBackend`; SMB rides the OS
/// mounter).
public enum ServerKind: String, Sendable, Codable, CaseIterable {
    case sftp
    case ftp
    case smb
    case s3
}

/// A saved server's coordinates and auth *method* — everything needed to reconnect, and nothing
/// secret. SFTP carries its `SFTPLocation` plus the chosen `SFTPAuthentication` (a key-file path or
/// the `.password` marker; the password itself stays in the Keychain). FTP carries its `FTPLocation`
/// — which includes the security mode, so plain FTP and FTPS to the same host stay distinct saved
/// servers — plus its `FTPAuthentication`, and the fingerprint the user trusted, if any. SMB carries
/// its `SMBLocation` (guest vs. authenticated is captured by whether `username` is set; any password
/// stays in the Keychain). Serializing an endpoint therefore never spills a credential.
public enum ServerEndpoint: Sendable, Hashable, Codable {
    case sftp(location: SFTPLocation, authentication: SFTPAuthentication)
    /// `trustedPublicKey` is the `FTPCertificate.publicKeyPin` the user accepted for this server, or
    /// `nil` when the certificate verified normally (or the connection is plain FTP). It is a public
    /// key digest, not a secret, so it belongs in the store rather than the Keychain — and storing
    /// it *here*, per saved server, is what makes trust a decision about one server rather than a
    /// global setting.
    case ftp(
        location: FTPLocation,
        authentication: FTPAuthentication,
        trustedPublicKey: String? = nil
    )
    case smb(SMBLocation)
    /// One bucket on one endpoint. There is no authentication *method* to carry beside it the way
    /// SFTP and FTP have: SigV4 is the only way in, and the access key id — which is an identifier,
    /// not a secret — already lives in the `S3Location`. The secret access key stays in the
    /// Keychain, filed under ``S3Location/keychainAccount``.
    case s3(S3Location)
    /// A whole S3 **account** — the same endpoint, region and key with no bucket named — browsed as
    /// a flat list of the buckets that key can see (PLAN.md §M21 Slice 9).
    ///
    /// A case of its own rather than an optional bucket on ``s3(_:)``, because the two are different
    /// *places* rather than one place with a field missing: they carry different backend ids, they
    /// are reached by different requests, and a saved server has to come back as the one it was
    /// saved as. An optional bucket would make every existing reader of a saved connection ask a
    /// question that has only ever had one answer.
    ///
    /// The secret access key is filed exactly as a bucket's is, under
    /// ``S3Account/keychainAccount`` — which is a bucket key's without the trailing `/<bucket>`, so
    /// an account and every bucket in it keep separate items.
    case s3Account(S3Account)
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
        case .ftp: return .ftp
        case .smb: return .smb
        // An account and a bucket are one protocol, so they wear one glyph and take one branch in
        // every switch that asks "which service is this". What differs between them is the *place*,
        // which is the endpoint's business and not the kind's.
        case .s3, .s3Account: return .s3
        }
    }

    /// A compact human-readable address for the sidebar subtitle / tooltip: the SFTP descriptor
    /// (`sftp://user@host:port`), the FTP descriptor (whose scheme names the security mode), the
    /// SMB URL (`smb://[user@]host[/share]`), or — for S3 — the *place*: `host (region)`, with the
    /// bucket in front when the connection names one.
    ///
    /// **S3 is the one that is not its descriptor**, and the difference is the access key id. The
    /// other three carry a user name the user typed and can read; an S3 descriptor leads with 20+
    /// characters of key that identify nothing to a person, and it was the first thing in the
    /// tooltip. The region rides along because it is not decorative — it is signed into every
    /// request's credential scope, and it is the `<LocationConstraint>` that decides where F7
    /// creates a bucket — and because it is what separates two saved connections to one endpoint.
    ///
    /// What the display form drops is recoverable where it is acted on rather than read: the key id
    /// is in the Edit sheet and in ``S3Account/connectionDescriptor`` (which errors use), and the
    /// addressing mode is the sheet's own checkbox. The **descriptor** is untouched and remains the
    /// identity — anything asserting round-trips or a re-addressing must read it, not this.
    public var address: String {
        switch endpoint {
        case let .sftp(location, _): return location.descriptor
        case let .ftp(location, _, _): return location.descriptor
        case let .smb(location): return location.url
        case let .s3(location):
            // The same `bucket — host` the path bar's root crumb draws, so a saved row and the pane
            // it opens name the place identically.
            return "\(location.bucket) — \(Self.s3Place(location.account))"
        case let .s3Account(account): return Self.s3Place(account)
        }
    }

    /// An S3 endpoint and its region, with the region omitted when there is none to state.
    ///
    /// The empty case is the point: a connection to a server whose regions are fiction carries no
    /// region at all (``S3Region``), and `host ()` would be the app inventing a fact — the same one
    /// the record deliberately does not keep.
    private static func s3Place(_ account: S3Account) -> String {
        guard S3Region.isStated(account.region) else { return account.displayEndpoint }
        return "\(account.displayEndpoint) (\(account.region))"
    }
}

/// What happened to an edit handed to ``ServerConnections/commitEdit(of:as:)``.
///
/// A refusal carries the name so the caller can say which one is taken — the user is looking at a
/// sheet with two names in play (the one they opened and the one they typed), so "that name is in
/// use" without the name is a sentence they have to guess at.
public enum ServerEditOutcome: Sendable, Equatable {
    case committed
    /// A *different* saved server already has this name; nothing was changed.
    case nameTaken(String)
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

    /// Replace the trusted certificate pin of the FTP connection named `name`, keeping everything
    /// else about it. Returns whether anything changed — the caller persists only then.
    ///
    /// This exists because a re-trusted certificate has to reach the *saved* server, or the next
    /// connect from the sidebar presents the old pin and the user is asked the same question again,
    /// forever. It is deliberately narrow: it will not create a record, will not touch a connection
    /// of another kind, and answers `false` when the pin already matches, so a caller that re-pins
    /// on every successful connect writes nothing on the ordinary path.
    @discardableResult
    public mutating func repinFTP(name: String, trustedPublicKey: String?) -> Bool {
        guard let index = connections.firstIndex(where: { $0.name == name }),
              case let .ftp(location, authentication, storedKey) = connections[index].endpoint,
              storedKey != trustedPublicKey else { return false }
        connections[index].endpoint = .ftp(
            location: location,
            authentication: authentication,
            trustedPublicKey: trustedPublicKey
        )
        return true
    }

    /// Replace the addressing mode of the S3 server named `name` — a bucket's or a whole account's —
    /// keeping everything else about it. Returns whether anything changed; the caller persists only
    /// then.
    ///
    /// The twin of ``repinFTP(name:trustedPublicKey:)``, and it exists for the same reason: a
    /// correction the connect flow worked out has to reach the *saved* server, or the next click on
    /// that sidebar row re-discovers it. What is corrected here is TLS-reachability — under
    /// virtual-host addressing the bucket is part of the host name, and a wildcard certificate is
    /// only one label deep, so an endpoint can be perfectly trustworthy and still unreachable that
    /// way. The connect retries path-style; this is where the answer is kept.
    ///
    /// Both S3 cases, because the correction is a fact about the **endpoint** rather than about one
    /// bucket: entering a bucket from a saved account is how it is usually discovered, and the record
    /// worth fixing is then the account's.
    ///
    /// Deliberately narrow, exactly as `repinFTP` is: it will not create a record, will not touch a
    /// connection of another kind, and answers `false` when the mode already matches — so a caller
    /// that calls it on every successful connect writes nothing on the ordinary path.
    @discardableResult
    public mutating func readdressS3(name: String, to addressing: S3Addressing) -> Bool {
        guard let index = connections.firstIndex(where: { $0.name == name }) else { return false }
        switch connections[index].endpoint {
        case let .s3(location) where location.addressing != addressing:
            connections[index].endpoint = .s3(location.addressed(addressing))
        case let .s3Account(account) where account.addressing != addressing:
            connections[index].endpoint = .s3Account(account.addressed(addressing))
        default:
            return false
        }
        return true
    }

    /// The name of the saved server that *is* `endpoint`, or `nil` when none is.
    ///
    /// The inverse of ``connection(named:)``, and needed because a **pane** knows its coordinates and
    /// not the name they were saved under: a correction discovered while browsing has to find the
    /// record to write it into. Identity is the name, so at most one connection can match.
    public func name(of endpoint: ServerEndpoint) -> String? {
        connections.first { $0.endpoint == endpoint }?.name
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

    /// Write an **edited** connection back over the one named `previousName`, name included.
    ///
    /// The sidebar's Edit… has no update path of its own — it re-opens the Connect sheet and the
    /// record is whatever the form reads back — so this is the one operation that means "this row,
    /// but different". Three rules, each of which is a way the obvious `remove` + ``save(_:)`` pair
    /// gets it wrong:
    ///
    /// - **In place.** `save` appends a name it has never seen, so a rename through remove-and-save
    ///   drops the row to the bottom of the sidebar — a reorder nobody asked for, from an edit that
    ///   may only have fixed a typo.
    /// - **A name already taken by a *different* record is refused**, exactly as ``rename(name:to:)``
    ///   refuses it. The pair would silently overwrite that record and then delete this one, so a
    ///   mistyped name costs the user a saved server they never touched.
    /// - **An unknown `previousName` appends**, so this is also the honest answer for "save what the
    ///   form holds" when the record has since been removed elsewhere.
    @discardableResult
    public mutating func commitEdit(
        of previousName: String,
        as connection: ServerConnection
    ) -> ServerEditOutcome {
        if connection.name != previousName,
           connections.contains(where: { $0.name == connection.name }) {
            return .nameTaken(connection.name)
        }
        if let index = connections.firstIndex(where: { $0.name == previousName }) {
            connections[index] = connection
        } else {
            connections.append(connection)
        }
        return .committed
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
    /// the *resulting* list (Array semantics, matching the saved-search/favorites reorder).
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
