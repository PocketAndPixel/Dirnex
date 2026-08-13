import Foundation
import Testing

@testable import DirnexCore

/// The S3 half of the saved-server model: one bucket, and — since §M21 Slice 9 — a whole account.
///
/// Its own suite because `ServerConnectionTests` reached SwiftLint's `type_body_length` when the
/// account arrived, and because this is the concept boundary anyway: everything here is about two
/// endpoints that address the same service at different depths and must never be read as each
/// other. The two helpers from that suite are repeated rather than shared, so a legacy-store case
/// here states its own fixture instead of depending on one written for another suite's purpose.
@Suite("ServerConnection with S3")
struct ServerConnectionS3Tests {
    private func sftp(_ name: String) -> ServerConnection {
        ServerConnection(
            name: name,
            endpoint: .sftp(
                location: SFTPLocation(host: "example.com", username: "oleg"),
                authentication: .key(identityFile: "/Users/oleg/.ssh/id_ed25519")
            )
        )
    }

    private func smb(_ name: String) -> ServerConnection {
        ServerConnection(
            name: name,
            endpoint: .smb(SMBLocation(host: "nas.local", share: "media", username: "oleg"))
        )
    }

    // MARK: - One bucket

    private func s3(_ name: String) -> ServerConnection {
        ServerConnection(
            name: name,
            endpoint: .s3(S3Location(
                host: "s3.eu-central-1.amazonaws.com",
                bucket: "photos",
                region: "eu-central-1",
                accessKeyID: "AKIAEXAMPLE"
            ))
        )
    }

    @Test("a saved bucket reports its kind and its descriptor")
    func s3EndpointRendering() {
        #expect(s3("Photos").kind == .s3)
        #expect(s3("Photos").address
            == "s3://AKIAEXAMPLE@s3.eu-central-1.amazonaws.com:443/eu-central-1/photos")
    }

    /// A saved bucket carries the access key id and *nothing* that unlocks it. Asserted over the
    /// encoded JSON rather than over the value, because the claim is about what reaches the disk:
    /// `Dirnex.servers` is plain `UserDefaults`, and the secret lives in the Keychain.
    @Test("a saved bucket serializes no secret")
    func s3StoresNoSecret() throws {
        let data = try JSONEncoder().encode(ServerConnections(connections: [s3("Photos")]))
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("AKIAEXAMPLE"))
        #expect(!json.lowercased().contains("secret"))
    }

    /// Adding a case to a `Codable` enum is a migration whether or not it looks like one. A store
    /// written before S3 existed must still decode — the shape a `try?`-loaded store fails in is
    /// the whole list coming back empty, i.e. every saved server silently gone.
    @Test("a store written before S3 existed still decodes")
    func legacyStoreDecodes() throws {
        let legacy = try JSONEncoder().encode(ServerConnections(connections: [sftp("A"), smb("B")]))
        let decoded = try JSONDecoder().decode(ServerConnections.self, from: legacy)
        #expect(decoded.connections.count == 2)
        #expect(decoded.connection(named: "A")?.kind == .sftp)
    }

    // MARK: - S3 accounts

    private func s3Account(_ name: String) -> ServerConnection {
        ServerConnection(
            name: name,
            endpoint: .s3Account(S3Account(
                host: "s3.eu-central-1.amazonaws.com",
                region: "eu-central-1",
                accessKeyID: "AKIAEXAMPLE"
            ))
        )
    }

    /// One protocol, so one glyph and one branch — but two *places*, which is what the descriptor
    /// has to keep apart. The `s3a://` scheme is what does it, and asserting both here is what
    /// stops a saved account and a saved bucket from ever being read as each other.
    @Test("a saved account is the same kind as a bucket and a different address")
    func s3AccountRendering() {
        #expect(s3Account("Amazon").kind == .s3)
        #expect(s3Account("Amazon").address
            == "s3a://AKIAEXAMPLE@s3.eu-central-1.amazonaws.com:443/eu-central-1")
        #expect(s3Account("Amazon").address != s3("Amazon").address)
    }

    @Test("a saved account serializes no secret")
    func s3AccountStoresNoSecret() throws {
        let data = try JSONEncoder().encode(ServerConnections(connections: [s3Account("Amazon")]))
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("AKIAEXAMPLE"))
        #expect(!json.lowercased().contains("secret"))
    }

    /// The same migration claim the S3 case made one slice earlier, re-made because the answer is
    /// not inherited: a store written before *accounts* existed carries buckets, and a `try?`-loaded
    /// store that fails to decode comes back empty rather than short.
    @Test("a store written before accounts existed still decodes")
    func storeWithoutAccountsDecodes() throws {
        let legacy = try JSONEncoder().encode(
            ServerConnections(connections: [sftp("A"), s3("B")])
        )
        let decoded = try JSONDecoder().decode(ServerConnections.self, from: legacy)
        #expect(decoded.connections.count == 2)
        #expect(decoded.connection(named: "B")?.kind == .s3)
    }

    // MARK: - Correcting the addressing mode

    /// The descriptor is the assertion, because it spells all six fields *and* the mode: a correction
    /// that dropped the port or the region would still be a valid saved server, pointing somewhere
    /// else.
    @Test("correcting a saved bucket changes the mode and keeps everything else")
    func readdressBucket() {
        var list = ServerConnections(connections: [s3("Photos")])
        let changed = list.readdressS3(name: "Photos", to: .path)
        #expect(changed)
        #expect(list.connection(named: "Photos")?.address
            == "s3p://AKIAEXAMPLE@s3.eu-central-1.amazonaws.com:443/eu-central-1/photos")
    }

    /// The account case is the one the pane gesture reaches: a bucket entered from a saved account
    /// discovers the correction, and the account is the record that has to keep it, or every other
    /// bucket anyone enters from that row re-discovers the same failure.
    @Test("correcting a saved account changes the mode and keeps everything else")
    func readdressAccount() {
        var list = ServerConnections(connections: [s3Account("Amazon")])
        let changed = list.readdressS3(name: "Amazon", to: .path)
        #expect(changed)
        #expect(list.connection(named: "Amazon")?.address
            == "s3ap://AKIAEXAMPLE@s3.eu-central-1.amazonaws.com:443/eu-central-1")
    }

    /// Answering `false` when there is nothing to do is what lets the app call this after *every*
    /// successful connect from a saved record rather than only after a corrected one — the shape
    /// `repinFTP` established. Without it the ordinary path would rewrite the store and post a
    /// change notification on each connect.
    @Test("correcting to the mode already stored changes nothing")
    func readdressUnchanged() {
        var list = ServerConnections(connections: [s3("Photos"), s3Account("Amazon")])
        let before = list
        let bucketChanged = list.readdressS3(name: "Photos", to: .virtualHost)
        let accountChanged = list.readdressS3(name: "Amazon", to: .virtualHost)
        #expect(!bucketChanged)
        #expect(!accountChanged)
        #expect(list == before)
    }

    /// Narrowness, both halves: a name that is not S3 must be left alone rather than rebuilt as an S3
    /// record, and a name that is not in the store must not be *created* as one. The second is what
    /// keeps a correction from resurrecting a server the user has deleted mid-connect.
    @Test("correcting refuses another kind and refuses to invent a record")
    func readdressRefusesElsewhere() {
        var list = ServerConnections(connections: [sftp("Shell"), smb("NAS")])
        let otherKindChanged = list.readdressS3(name: "Shell", to: .path)
        let missingChanged = list.readdressS3(name: "Nothing", to: .path)
        #expect(!otherKindChanged)
        #expect(!missingChanged)
        #expect(list.connections.count == 2)
        #expect(list.connection(named: "Shell")?.kind == .sftp)
    }

    /// The reverse lookup a pane needs: it holds the account's coordinates — recovered from its
    /// backend id — and not the name they were saved under. Asserted with a *rebuilt* value rather
    /// than the stored one, since that is the round trip the caller actually performs.
    @Test("a saved server can be found by the endpoint it is")
    func nameOfEndpoint() {
        let list = ServerConnections(connections: [sftp("Shell"), s3Account("Amazon")])
        let account = S3Account(
            host: "s3.eu-central-1.amazonaws.com",
            region: "eu-central-1",
            accessKeyID: "AKIAEXAMPLE"
        )
        #expect(list.name(of: .s3Account(account)) == "Amazon")
        // The same endpoint one addressing mode over is a *different* saved server, which is what
        // stops a corrected record being found again and re-corrected on the next connect.
        #expect(list.name(of: .s3Account(account.addressed(.path))) == nil)
        #expect(list.name(of: .s3Account(account.addressed(.virtualHost))) == "Amazon")
    }

    /// Both S3 endpoints round-trip *as themselves*. The failure this rules out is the quiet one:
    /// an account decoded as its `us-east-1` bucket, or a bucket decoded as the account above it,
    /// would connect to somewhere real and wrong.
    @Test("an account and a bucket each round-trip as themselves")
    func s3EndpointsRoundTrip() throws {
        let list = ServerConnections(connections: [s3("Bucket"), s3Account("Account")])
        let decoded = try JSONDecoder().decode(
            ServerConnections.self,
            from: try JSONEncoder().encode(list)
        )
        #expect(decoded == list)
        guard case .s3Account = decoded.connection(named: "Account")?.endpoint else {
            Issue.record("the account came back as something else")
            return
        }
        guard case .s3 = decoded.connection(named: "Bucket")?.endpoint else {
            Issue.record("the bucket came back as something else")
            return
        }
    }
}
