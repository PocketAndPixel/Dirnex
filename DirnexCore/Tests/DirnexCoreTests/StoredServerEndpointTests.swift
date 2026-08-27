import Foundation
import Testing

@testable import DirnexCore

/// The tolerance that keeps one unreadable endpoint from emptying a whole session.
///
/// A pane's tabs and a workspace's panes are arrays inside one JSON blob, so a `Codable` enum that
/// *throws* on an unknown case does not lose one tab — it loses every tab beside it. That is the
/// same trap `PersistedTab.viewMode` avoided by storing a raw string (docs/NOTES.md), arriving on a
/// value that cannot be a raw string.
@Suite("StoredServerEndpoint")
struct StoredServerEndpointTests {
    private static let endpoint = ServerEndpoint.sftp(
        location: SFTPLocation(host: "example.com", username: "oleg"),
        authentication: .password
    )

    @Test("an endpoint round-trips unchanged")
    func roundTrip() throws {
        let data = try JSONEncoder().encode(StoredServerEndpoint(Self.endpoint))
        let read = try JSONDecoder().decode(StoredServerEndpoint.self, from: data)
        #expect(read.endpoint == Self.endpoint)
    }

    /// The case this exists for: a shape written by a build that knows a protocol this one does
    /// not. It has to come back as "nothing to reconnect" — never as a throw.
    @Test("an endpoint this build cannot read decodes to nothing rather than throwing")
    func unknownShapeDegrades() throws {
        let future = Data(#"{"quic":{"_0":{"host":"example.com"}}}"#.utf8)
        let read = try JSONDecoder().decode(StoredServerEndpoint.self, from: future)
        #expect(read.endpoint == nil)
    }

    /// The claim that actually matters, made against the array it protects: one unreadable element
    /// must not take its neighbours with it.
    @Test("an unreadable endpoint costs its own tab's connection and no neighbour's")
    func oneBadElementKeepsTheRest() throws {
        struct Tab: Codable { var name: String; var endpoint: StoredServerEndpoint? }
        let stored = try JSONEncoder().encode([
            Tab(name: "one", endpoint: StoredServerEndpoint(Self.endpoint)),
            Tab(name: "two", endpoint: nil)
        ])
        // Substitute a case this build has never heard of for the first tab's, leaving the JSON
        // otherwise byte-identical — which is what a newer build's session actually looks like.
        var text = try #require(String(data: stored, encoding: .utf8))
        let sftp = try #require(text.range(of: #""sftp":"#))
        text.replaceSubrange(sftp, with: #""quic":"#)

        let tabs = try JSONDecoder().decode([Tab].self, from: Data(text.utf8))
        #expect(tabs.count == 2)
        #expect(tabs[0].endpoint?.endpoint == nil)
        #expect(tabs[1].endpoint == nil)
    }

    /// Re-saving a session that held one has to produce something that decodes — the encode is
    /// reached only on that path, so nothing else would ever exercise it.
    @Test("re-encoding an unreadable endpoint stays valid and stays nothing")
    func reEncodingDegradedValue() throws {
        let degraded = try JSONDecoder().decode(
            StoredServerEndpoint.self,
            from: Data(#"{"quic":{}}"#.utf8)
        )
        let data = try JSONEncoder().encode(degraded)
        #expect(String(data: data, encoding: .utf8) == "null")
        #expect(try JSONDecoder().decode(StoredServerEndpoint.self, from: data).endpoint == nil)
    }

    /// A local tab writes no field at all rather than a null, so the common case adds nothing to
    /// the JSON — and so a `nil` read back can only mean "stored, and unreadable".
    @Test("a workspace tab with no endpoint writes no endpoint field")
    func localWorkspaceTabWritesNothing() throws {
        let tab = WorkspaceTab(path: .local("/Users/oleg"))
        let text = try #require(String(data: try JSONEncoder().encode(tab), encoding: .utf8))
        #expect(!text.contains("endpoint"))
        #expect(tab.serverEndpoint == nil)
    }

    @Test("a workspace tab carries its endpoint across a save and a load")
    func workspaceTabRoundTrip() throws {
        let tab = WorkspaceTab(
            path: VFSPath(
                backend: .sftp(SFTPLocation(host: "example.com", username: "oleg")),
                path: "/var/log"
            ),
            endpoint: Self.endpoint
        )
        let data = try JSONEncoder().encode(tab)
        let read = try JSONDecoder().decode(WorkspaceTab.self, from: data)
        #expect(read == tab)
        #expect(read.serverEndpoint == Self.endpoint)
    }

    /// A workspace saved before the endpoint existed still opens — the tab comes back, without a
    /// connection to re-establish, rather than taking the workspace down with it.
    ///
    /// The fixture is derived by *removing* the field from a current encode rather than written out
    /// by hand: `VFSPath` and `FileSort` are `RawRepresentable` inside, so a hand-spelled legacy
    /// blob is really a second, drifting copy of their encodings — and a first attempt at one here
    /// failed on that rather than on the claim.
    @Test("a workspace tab saved before endpoints existed still decodes")
    func legacyWorkspaceDecodes() throws {
        let path = VFSPath(
            backend: .sftp(SFTPLocation(host: "example.com", username: "oleg")),
            path: "/var/log"
        )
        let current = try JSONEncoder().encode(WorkspaceTab(path: path, endpoint: Self.endpoint))
        var fields = try #require(
            try JSONSerialization.jsonObject(with: current) as? [String: Any]
        )
        #expect(
            fields["endpoint"] != nil,
            "the field must be there for removing it to mean anything"
        )
        fields["endpoint"] = nil

        let legacy = try JSONSerialization.data(withJSONObject: fields)
        let read = try JSONDecoder().decode(WorkspaceTab.self, from: legacy)
        #expect(read.path == path)
        #expect(read.serverEndpoint == nil)
    }
}
