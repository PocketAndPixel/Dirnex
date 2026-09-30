import Foundation
import Testing

@testable import DirnexCore

/// `ServerConnections.commitEdit(of:as:)` — the store half of the sidebar's Edit….
///
/// Its own suite because the operation is protocol-agnostic: it replaces one record with another
/// whole `ServerEndpoint`, so what is worth pinning is the *bookkeeping* (position, naming, an
/// endpoint that changed kind), not any one protocol's fields.
///
/// Every case here is a way the obvious `remove` + `save` pair gets it wrong, which is what the app
/// did until 2026-08-13 — and all three failures are quiet: the connection still works, so nothing
/// reports anything, and the damage is only visible in the sidebar afterwards.
@Suite("ServerConnection editing")
struct ServerConnectionEditTests {
    private func sftp(_ name: String, host: String = "example.com") -> ServerConnection {
        ServerConnection(
            name: name,
            endpoint: .sftp(
                location: SFTPLocation(host: host, username: "oleg"),
                authentication: .password
            )
        )
    }

    private func host(of connection: ServerConnection?) -> String? {
        guard case let .sftp(location, _)? = connection?.endpoint else { return nil }
        return location.host
    }

    @Test("an edit replaces the record it names, fields and all")
    func editReplacesTheRecord() {
        var list = ServerConnections(connections: [sftp("A"), sftp("B")])

        #expect(list.commitEdit(of: "B", as: sftp("B", host: "moved.example.com")) == .committed)
        #expect(list.connections.count == 2)
        #expect(host(of: list.connection(named: "B")) == "moved.example.com")
    }

    /// A rename has to keep the row where it was. `save` appends a name it has never seen, so
    /// remove-and-save drops the edited server to the bottom of the Servers section — a reorder
    /// nobody asked for, from an edit that may only have corrected a typo.
    @Test("a rename keeps the row's position")
    func renameKeepsPosition() {
        var list = ServerConnections(connections: [sftp("A"), sftp("B"), sftp("C")])

        #expect(list.commitEdit(of: "B", as: sftp("Middle")) == .committed)
        #expect(list.connections.map(\.name) == ["A", "Middle", "C"])
    }

    /// The expensive one: remove-and-save would overwrite the *other* record and then delete this
    /// one, so a mistyped name costs a saved server the user never touched. Refused whole — the
    /// caller reports it and the sheet stays open.
    @Test("renaming onto another record's name is refused, and changes nothing")
    func renameOntoAnotherNameIsRefused() {
        var list = ServerConnections(connections: [sftp("A"), sftp("B", host: "b.example.com")])
        let before = list

        let outcome = list.commitEdit(of: "A", as: sftp("B", host: "edited.example.com"))

        #expect(outcome == .nameTaken("B"))
        #expect(list == before)
    }

    /// The ordinary case must not trip that guard: an edit that keeps the name collides with
    /// *itself*, and a `contains` written without the rename check would refuse every edit that
    /// only changed a field.
    @Test("keeping the name is not a collision with itself")
    func keepingTheNameIsNotACollision() {
        var list = ServerConnections(connections: [sftp("A")])

        #expect(list.commitEdit(of: "A", as: sftp("A", host: "edited.example.com")) == .committed)
        #expect(host(of: list.connection(named: "A")) == "edited.example.com")
    }

    /// A record removed elsewhere while the sheet was open still leaves the user with an edit they
    /// asked to keep, so it lands rather than vanishing.
    @Test("an edit of a record that is gone appends it")
    func editOfAMissingRecordAppends() {
        var list = ServerConnections(connections: [sftp("A")])

        #expect(list.commitEdit(of: "Vanished", as: sftp("Restored")) == .committed)
        #expect(list.connections.map(\.name) == ["A", "Restored"])
    }

    /// An edit may change the *kind* of connection — an S3 bucket becomes the whole account when the
    /// bucket field is cleared, and that is the one edit that changes which backend the row opens.
    /// Nothing here may treat the endpoint as fixed.
    @Test("an edit may change the endpoint's kind")
    func editMayChangeKind() {
        let account = S3Account(
            host: "s3.lax.example.net",
            region: "us-east-1",
            accessKeyID: "AKIAEXAMPLE",
            addressing: .path
        )
        var list = ServerConnections(connections: [
            ServerConnection(name: "S3", endpoint: .s3(account.bucketLocation(named: "photos")))
        ])

        let outcome = list.commitEdit(
            of: "S3",
            as: ServerConnection(name: "S3", endpoint: .s3Account(account))
        )

        #expect(outcome == .committed)
        guard case .s3Account? = list.connection(named: "S3")?.endpoint else {
            Issue.record("the edited record is not an account")
            return
        }
    }
}
