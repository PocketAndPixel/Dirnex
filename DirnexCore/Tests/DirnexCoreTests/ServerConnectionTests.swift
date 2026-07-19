import Foundation
import Testing

@testable import DirnexCore

@Suite("ServerConnection")
struct ServerConnectionTests {
    private func sftp(_ name: String, host: String = "example.com") -> ServerConnection {
        ServerConnection(
            name: name,
            endpoint: .sftp(
                location: SFTPLocation(host: host, username: "oleg"),
                authentication: .key(identityFile: "/Users/oleg/.ssh/id_ed25519")
            )
        )
    }

    private func smb(_ name: String, host: String = "nas.local") -> ServerConnection {
        ServerConnection(
            name: name,
            endpoint: .smb(SMBLocation(host: host, share: "media", username: "oleg"))
        )
    }

    // MARK: - ServerConnection value

    @Test("identity is the name")
    func identityIsName() {
        #expect(sftp("Work Server").id == "Work Server")
    }

    @Test("kind reflects the endpoint protocol")
    func kindFromEndpoint() {
        #expect(sftp("s").kind == .sftp)
        #expect(smb("s").kind == .smb)
    }

    @Test("address renders the SFTP descriptor and the SMB URL")
    func addressRendering() {
        #expect(sftp("s", host: "h").address == "sftp://oleg@h:22")
        #expect(smb("s", host: "nas").address == "smb://oleg@nas/media")
    }

    @Test("an SFTP connection round-trips through Codable with its location and auth method")
    func sftpCodableRoundTrip() throws {
        let original = ServerConnection(
            name: "Prod",
            endpoint: .sftp(
                location: SFTPLocation(host: "10.0.0.5", port: 2222, username: "svc"),
                authentication: .password
            )
        )
        let decoded = try JSONDecoder().decode(
            ServerConnection.self,
            from: try JSONEncoder().encode(original)
        )
        #expect(decoded == original)
        if case let .sftp(location, authentication) = decoded.endpoint {
            #expect(location.port == 2222)
            #expect(authentication == .password)
        } else {
            Issue.record("expected an SFTP endpoint")
        }
    }

    @Test("an SMB connection round-trips through Codable with its share and user")
    func smbCodableRoundTrip() throws {
        let original = ServerConnection(
            name: "NAS",
            endpoint: .smb(SMBLocation(host: "nas.local", share: "backup", username: "oleg"))
        )
        let decoded = try JSONDecoder().decode(
            ServerConnection.self,
            from: try JSONEncoder().encode(original)
        )
        #expect(decoded == original)
        if case let .smb(location) = decoded.endpoint {
            #expect(location.share == "backup")
            #expect(location.username == "oleg")
        } else {
            Issue.record("expected an SMB endpoint")
        }
    }

    @Test("a guest SMB endpoint carries no username and no secret")
    func guestSMBEndpoint() {
        let guest = ServerConnection(
            name: "Public",
            endpoint: .smb(SMBLocation(host: "nas.local", share: "public"))
        )
        if case let .smb(location) = guest.endpoint {
            #expect(location.username == nil)
        } else {
            Issue.record("expected an SMB endpoint")
        }
    }

    // MARK: - Collection

    @Test("a fresh collection is empty")
    func startsEmpty() {
        #expect(ServerConnections().connections.isEmpty)
    }

    @Test("save appends a new name and reports it did not replace")
    func saveAppends() {
        var list = ServerConnections()
        // The Testing `#expect` macro captures its argument immutably, so a `mutating` call must
        // be hoisted into a `let` first (same gotcha as SavedSearchTests).
        let replacedA = list.save(sftp("A"))
        #expect(replacedA == false)
        let replacedB = list.save(smb("B"))
        #expect(replacedB == false)
        #expect(list.connections.map(\.name) == ["A", "B"])
    }

    @Test("save overwrites an existing name in place, keeping its position")
    func saveReplacesInPlace() {
        var list = ServerConnections(connections: [sftp("A"), sftp("B"), sftp("C")])
        let replaced = list.save(smb("B")) // same name, different protocol/coordinates
        #expect(replaced)
        #expect(list.connections.map(\.name) == ["A", "B", "C"])
        #expect(list.connection(named: "B")?.kind == .smb)
    }

    @Test("the initializer collapses duplicate names, keeping the first")
    func dedupOnInit() {
        let list = ServerConnections(connections: [
            sftp("Dup", host: "first"),
            smb("Dup"),
            sftp("Other")
        ])
        #expect(list.connections.map(\.name) == ["Dup", "Other"])
        #expect(list.connection(named: "Dup")?.kind == .sftp)
        #expect(list.connection(named: "Dup")?.address == "sftp://oleg@first:22")
    }

    @Test("contains and lookup by name")
    func containsAndLookup() {
        let list = ServerConnections(connections: [sftp("A")])
        #expect(list.contains(name: "A"))
        #expect(!list.contains(name: "B"))
        #expect(list.connection(named: "A")?.name == "A")
        #expect(list.connection(named: "B") == nil)
    }

    @Test("remove by name reports whether one was removed")
    func removeByName() {
        var list = ServerConnections(connections: [sftp("A"), smb("B")])
        let removed = list.remove(name: "A")
        #expect(removed)
        let removedAgain = list.remove(name: "A")
        #expect(!removedAgain)
        #expect(list.connections.map(\.name) == ["B"])
    }

    @Test("remove at index ignores out-of-range")
    func removeAtIndex() {
        var list = ServerConnections(connections: [sftp("A"), smb("B")])
        list.remove(at: 5)
        #expect(list.connections.count == 2)
        list.remove(at: 0)
        #expect(list.connections.map(\.name) == ["B"])
    }

    @Test("rename rejects an empty name and a collision with a different entry")
    func renameRules() {
        var list = ServerConnections(connections: [sftp("A"), smb("B")])
        let emptyRejected = list.rename(name: "A", to: "")
        #expect(!emptyRejected)
        let collisionRejected = list.rename(name: "A", to: "B")
        #expect(!collisionRejected)
        #expect(list.connections.map(\.name) == ["A", "B"])
        let sameName = list.rename(name: "A", to: "A")
        #expect(sameName)
        let renamed = list.rename(name: "A", to: "A2")
        #expect(renamed)
        #expect(list.connections.map(\.name) == ["A2", "B"])
    }

    @Test("move reorders with array semantics")
    func moveReorders() {
        var list = ServerConnections(connections: [sftp("A"), sftp("B"), sftp("C")])
        list.move(from: 0, to: 2)
        #expect(list.connections.map(\.name) == ["B", "C", "A"])
    }

    @Test("the whole collection round-trips through Codable, sanitizing on decode")
    func collectionCodableRoundTrip() throws {
        let list = ServerConnections(connections: [sftp("A"), smb("B")])
        let decoded = try JSONDecoder().decode(
            ServerConnections.self,
            from: try JSONEncoder().encode(list)
        )
        #expect(decoded == list)
    }
}
