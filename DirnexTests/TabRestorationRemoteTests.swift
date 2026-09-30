import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A tab on a **connected server**, or inside a **browsed archive**, comes back after a relaunch —
/// docs/LOCATION-SUPPORT.md ▸ "Session restore and workspaces drop remote tabs", the first item on
/// that document's ranked list. Quit with four bucket tabs open and they used to be gone: the saved
/// connection survived in the sidebar and the *place* did not.
///
/// What is asserted here is the restore's own half — which tabs come back, and what each of them is
/// left holding. The connection is deliberately *not* opened by the restore (that is
/// `PaneReconnectTests`), so nothing in this suite touches a network, a Keychain or a window.
@Suite("Tab restoration: servers and archives")
@MainActor
struct TabRestorationRemoteTests {
    // MARK: - Fixtures

    private static let sftpLocation = SFTPLocation(host: "example.com", username: "oleg")
    /// Key-file auth on purpose: it is the endpoint that needs no secret, so the fixtures stay free
    /// of the Keychain everywhere the *secret* is not what is being tested.
    private static let sftpEndpoint = ServerEndpoint.sftp(
        location: sftpLocation,
        authentication: .key(identityFile: "/Users/oleg/.ssh/id_ed25519")
    )
    private static let bucket = S3Location(
        host: "s3.eu-central-1.amazonaws.com",
        bucket: "photos",
        region: "eu-central-1",
        accessKeyID: "AKIAEXAMPLE"
    )

    private static func restore(_ tabs: [PersistedTab]) -> [PanelTab] {
        PanelViewController.restoredTabs(from: PersistedPane(tabs: tabs, activeIndex: 0))
    }

    /// A real file to stand in for an archive — `canRestore` asks the filesystem whether the
    /// archive is still a *file*, and nothing mounts it, so its bytes never matter.
    private static func withArchiveFile(_ body: (String) throws -> Void) throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dirnex-restore-\(UUID().uuidString).zip")
        FileManager.default.createFile(atPath: url.path, contents: Data("PK".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url.path)
    }

    // MARK: - Servers

    @Test("a server tab comes back, holding the endpoint that will reconnect it")
    func serverTabIsRestored() {
        let path = VFSPath(backend: .sftp(Self.sftpLocation), path: "/var/log")
        let restored = Self.restore([
            PersistedTab(path: path, sort: .default, columns: nil, endpoint: Self.sftpEndpoint)
        ])
        #expect(restored.count == 1)
        #expect(restored.first?.panel.path == path)
        #expect(restored.first?.pendingConnection == Self.sftpEndpoint)
        // Not connected *by the restore*: a pane restoring five server tabs must contact nothing
        // until one of them is on screen.
        #expect(restored.first?.hasLoaded == false)
    }

    /// The four remote backends together, because the restore has to answer for whichever one a
    /// user left open — and because a rule spelled as a list of cases is this project's most
    /// repeated bug.
    @Test("every remote backend survives a relaunch")
    func everyRemoteBackendSurvives() {
        let ftpLocation = FTPLocation(host: "ftp.example.com", username: "oleg")
        let account = S3Account(
            host: "s3.eu-central-1.amazonaws.com",
            region: "eu-central-1",
            accessKeyID: "AKIAEXAMPLE"
        )
        let persisted = [
            PersistedTab(
                path: VFSPath(backend: .sftp(Self.sftpLocation), path: "/"),
                sort: .default, columns: nil, endpoint: Self.sftpEndpoint
            ),
            PersistedTab(
                path: VFSPath(backend: .ftp(ftpLocation), path: "/pub"),
                sort: .default, columns: nil,
                endpoint: .ftp(location: ftpLocation, authentication: .anonymous)
            ),
            PersistedTab(
                path: VFSPath(backend: .s3(Self.bucket), path: "/2026"),
                sort: .default, columns: nil, endpoint: .s3(Self.bucket)
            ),
            PersistedTab(
                path: VFSPath(backend: .s3Account(account), path: "/"),
                sort: .default, columns: nil, endpoint: .s3Account(account)
            )
        ]
        let restored = Self.restore(persisted)
        #expect(restored.count == 4)
        #expect(restored.allSatisfy { $0.pendingConnection != nil })
    }

    /// A session written before the endpoint was stored carries the descriptor and nothing else.
    /// Such a tab has nothing that could ever reconnect it, so it is dropped rather than brought
    /// back as a chip nobody can fill — which is exactly the behaviour that shipped before this,
    /// and is what keeps the fallback-tab tests meaning what they meant.
    @Test("a legacy server tab with no endpoint is still dropped")
    func legacyServerTabIsDropped() {
        let restored = Self.restore([
            PersistedTab(
                path: VFSPath(backend: .sftp(Self.sftpLocation), path: "/var/log"),
                sort: .default,
                columns: nil
            )
        ])
        #expect(restored.isEmpty)
    }

    /// The check that stops a hand-edited or half-migrated store from connecting to one server and
    /// listing a path belonging to another — a perfectly plausible listing under the wrong name.
    @Test("an endpoint that names a different server restores nothing")
    func mismatchedEndpointIsDropped() {
        let restored = Self.restore([
            PersistedTab(
                path: VFSPath(
                    backend: .sftp(SFTPLocation(host: "other.example.com", username: "oleg")),
                    path: "/var/log"
                ),
                sort: .default,
                columns: nil,
                endpoint: Self.sftpEndpoint
            )
        ])
        #expect(restored.isEmpty)
    }

    @Test("a server tab's endpoint survives the round trip through UserDefaults' JSON")
    func endpointRoundTrips() throws {
        let path = VFSPath(backend: .s3(Self.bucket), path: "/2026")
        let written = PersistedTab(
            path: path,
            sort: .default,
            columns: nil,
            endpoint: .s3(Self.bucket)
        )
        let data = try JSONEncoder().encode(PersistedPane(tabs: [written], activeIndex: 0))
        let read = try JSONDecoder().decode(PersistedPane.self, from: data)
        #expect(read.tabs.first?.serverEndpoint == .s3(Self.bucket))
        #expect(read.tabs.first?.vfsPath == path)
    }

    // MARK: - Archives

    @Test("an archive tab comes back, and needs no connection to do it")
    func archiveTabIsRestored() throws {
        try Self.withArchiveFile { archive in
            let inside = VFSPath(backend: .archive(forArchiveAt: archive), path: "/docs/api")
            let restored = Self.restore([
                PersistedTab(path: inside, sort: .default, columns: nil)
            ])
            #expect(restored.count == 1)
            #expect(restored.first?.panel.path == inside)
            #expect(restored.first?.pendingConnection == nil)
        }
    }

    /// The archive **file** is what is checked, never the tab's own path — a tab three folders into
    /// a zip has a path that exists nowhere on disk, so stat-ing the path would drop every archive
    /// tab but a root's, silently.
    @Test("an archive that is gone drops its tab; one that became a directory does too")
    func vanishedArchiveIsDropped() throws {
        let missing = VFSPath(
            backend: .archive(forArchiveAt: "/nowhere/\(UUID().uuidString).zip"),
            path: "/docs"
        )
        #expect(Self.restore([PersistedTab(path: missing, sort: .default, columns: nil)]).isEmpty)

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dirnex-restore-\(UUID().uuidString).zip")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let impostor = VFSPath(backend: .archive(forArchiveAt: directory.path), path: "/")
        #expect(Self.restore([PersistedTab(path: impostor, sort: .default, columns: nil)]).isEmpty)
    }

    // MARK: - What still must not come back

    @Test("the virtual listings stay out of session restore")
    func virtualListingsAreStillDropped() {
        let persisted = [VFSBackendID.search, .trash, .icloud].map {
            PersistedTab(path: VFSPath(backend: $0, path: "/"), sort: .default, columns: nil)
        }
        #expect(Self.restore(persisted).isEmpty)
    }

    @Test("a local tab whose directory is gone is still dropped")
    func vanishedLocalTabIsDropped() {
        let gone = VFSPath.local("/nowhere/\(UUID().uuidString)")
        #expect(Self.restore([PersistedTab(path: gone, sort: .default, columns: nil)]).isEmpty)
    }
}
