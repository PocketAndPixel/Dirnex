import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// What makes the sidebar's **Edit…** an edit rather than a one-off connect.
///
/// There is no "update" path and deliberately so: `editServer` re-opens the ordinary Connect sheet
/// prefilled from the record, every connect writes a record whenever the form carries a `saveName`,
/// and `ServerConnections.save` replaces an existing name *in place*. So the entire mechanism is one
/// line — `applyPrefill` putting the record's name into the "Save as" field — and if that line ever
/// stops running, Edit… silently degrades into "connect once and forget": the sheet behaves
/// identically, the connection works, and the change is simply gone at the next launch.
///
/// Pinned at the whole-form level because that is where the link lives. Each protocol's field set is
/// *handed* a `saveName` by `ConnectServerForm.readForm()` and can say nothing about where it came
/// from, so a per-protocol test proves the passing-through and not the prefill.
@Suite("Connect sheet save name")
@MainActor
struct ConnectServerSaveNameTests {
    /// SFTP with key authentication is the fixture for a reason that is not about SFTP: the claim
    /// under test is protocol-independent (one `saveName` field, read once, above the switch), and
    /// key auth is the only prefill that reads back a complete form **without a Keychain secret** —
    /// every other one resolves its password through `SecretKeychain`, so the test would either file
    /// a credential on the machine running it or read `nil` and refuse the form for the wrong reason.
    private func savedServer(named name: String) -> ServerConnection {
        ServerConnection(
            name: name,
            endpoint: .sftp(
                location: SFTPLocation(host: "example.com", port: 2222, username: "oleg"),
                authentication: .key(identityFile: "/Users/oleg/.ssh/id_ed25519")
            )
        )
    }

    @Test("editing a saved server carries its name back, so Connect updates that record")
    func editingKeepsTheSaveName() throws {
        let form = ConnectServerForm(prefill: savedServer(named: "S3 SH"))

        let read = try #require(form.readForm())
        #expect(read.saveName == "S3 SH")
    }

    /// The other half of the same field, and the reason it cannot simply be non-optional: `nil` is
    /// what every connect path reads as "do not write a record", so a connect nobody asked to save
    /// leaves the store alone. Whitespace has to reach the same answer — without the trim, a field
    /// holding a space saves a record the sidebar draws as blank, and since identity *is* the name,
    /// one that collides with the next such mistake rather than with anything the user could find.
    ///
    /// Driven through a prefill because the form's own fields are `private`: a sheet with an unnamed
    /// record fills every other row exactly as the empty sheet the user starts from would, once they
    /// have typed into it.
    @Test("an empty or whitespace name saves nothing", arguments: ["", "   "])
    func blankNameSavesNothing(name: String) throws {
        let form = ConnectServerForm(prefill: savedServer(named: name))

        #expect(try #require(form.readForm()).saveName == nil)
    }
}
