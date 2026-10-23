import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A saved server picked with ⌘ opens its new tab when the connection lands, so a connect that
/// fails or is cancelled leaves no tab behind (docs/HISTORY.md, 2026-10-14).
///
/// Every connect ends in its own navigation, so the claim has two halves and each is pinned where
/// it is decided: the attempt a row or the sheet builds carries the flag, and the landing every
/// attempt ends in opens the tab. What connects in between dials a server, so it was verified in
/// the running app. The retries in between copy the request whole, and S3's run beneath the call
/// that lands, so none of them has a flag to drop.
@Suite("A server opens its new tab when it connects")
@MainActor
struct ServerConnectNewTabTests {
    private static let bucket = S3Location(
        host: "s3.eu-west-1.amazonaws.com",
        bucket: "photos",
        region: "eu-west-1",
        accessKeyID: "AKIAEXAMPLE"
    )

    /// One saved server per protocol, each authenticated, so each needs a secret to connect.
    private static let needingSecret = [
        ServerConnection(
            name: "Box",
            endpoint: .sftp(
                location: SFTPLocation(host: "box.example", username: "u"),
                authentication: .password
            )
        ),
        ServerConnection(
            name: "NAS",
            endpoint: .ftp(
                location: FTPLocation(host: "nas.example", username: "u"),
                authentication: .password
            )
        ),
        ServerConnection(name: "Photos", endpoint: .s3(bucket)),
        ServerConnection(name: "AWS", endpoint: .s3Account(bucket.account)),
        ServerConnection(
            name: "DAV",
            endpoint: .webdav(location: WebDAVLocation(host: "dav.example", username: "u"))
        ),
        ServerConnection(
            name: "Share",
            endpoint: .smb(SMBLocation(host: "share.example", share: "media", username: "u"))
        )
    ]

    /// The four that need no secret: a key file, the anonymous login, a public WebDAV share and a
    /// guest share.
    private static let needingNone = [
        ServerConnection(
            name: "Keyed",
            endpoint: .sftp(
                location: SFTPLocation(host: "box.example", username: "u"),
                authentication: .key(identityFile: "/Users/u/.ssh/id_ed25519")
            )
        ),
        ServerConnection(
            name: "Mirror",
            endpoint: .ftp(
                location: FTPLocation(
                    host: "ftp.example",
                    username: FTPLocation.anonymousUsername,
                    security: .plain
                ),
                authentication: .anonymous
            )
        ),
        ServerConnection(
            name: "Public",
            endpoint: .webdav(location: WebDAVLocation(host: "dav.example", username: ""))
        ),
        ServerConnection(name: "Guest", endpoint: .smb(SMBLocation(host: "share.example")))
    ]

    // MARK: - The attempt

    @Test("every saved server's attempt carries ⌘'s new tab, and only when asked")
    func savedServerCarriesTheFlag() throws {
        for server in Self.needingSecret + Self.needingNone {
            let asked = try #require(
                PanelViewController.connectRequest(for: server, secret: "pw", inNewTab: true),
                "\(server.name)"
            )
            #expect(asked.inNewTab, "\(server.name)")
            // Each endpoint reaches its own protocol's connect, which is where the flag is read.
            #expect(asked.kind == server.kind, "\(server.name)")

            let plain = try #require(
                PanelViewController.connectRequest(for: server, secret: "pw", inNewTab: false)
            )
            #expect(!plain.inNewTab, "\(server.name)")
        }
    }

    /// The fallback is half of the claim: a row with no saved secret opens the prompt instead of
    /// connecting, and the flag travels there through `editServer`.
    @Test("a saved server whose secret is missing falls back to the prompt")
    func missingSecretFallsBack() {
        for server in Self.needingSecret {
            #expect(
                PanelViewController.connectRequest(for: server, secret: nil, inNewTab: true) == nil,
                "\(server.name)"
            )
        }
    }

    @Test("a saved server that needs no secret connects without one")
    func noSecretNeeded() throws {
        for server in Self.needingNone {
            let request = try #require(
                PanelViewController.connectRequest(for: server, secret: nil, inNewTab: true),
                "\(server.name)"
            )
            #expect(request.inNewTab, "\(server.name)")
        }
    }

    /// A guest share has no user to file a secret under, so one that happens to be at hand is not
    /// passed to the mounter.
    @Test("a guest share is handed no secret")
    func guestShareGetsNoSecret() throws {
        let guest = try #require(Self.needingNone.last)
        let request = PanelViewController.connectRequest(for: guest, secret: "pw", inNewTab: false)
        guard case let .smb(mount)? = request else {
            Issue.record("a share connected as \(String(describing: request))")
            return
        }
        #expect(mount.password == nil)
    }

    /// The sheet a missing secret falls back to builds its attempt from the form, so the flag has to
    /// survive that builder as well as the row's.
    @Test("the sheet's attempt carries the flag it was opened with")
    func formCarriesTheFlag() {
        for server in Self.needingSecret + Self.needingNone {
            let form = ConnectServerPrompt.Form(
                endpoint: server.endpoint,
                password: "pw",
                saveName: server.name
            )
            let asked = PanelViewController.connectRequest(for: form, inNewTab: true)
            #expect(asked.inNewTab, "\(server.name)")
            #expect(asked.kind == server.kind, "\(server.name)")
            #expect(!PanelViewController.connectRequest(for: form, inNewTab: false).inNewTab)
        }
    }

    // MARK: - The landing

    /// A folder holding `a`, `b` and `c`, for a landing to list.
    private static func destination() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerConnectNewTabTests-\(UUID().uuidString)")
        for name in ["a", "b", "c"] {
            try FileManager.default.createDirectory(
                at: url.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }
        return url
    }

    /// A pane standing on a folder it never lists. The view is not loaded, as in
    /// `FrecencyVisitReachTests`: nothing here reads the table, and an unloaded pane still lists,
    /// opens a tab and places its cursor.
    private static func pane() -> PanelViewController {
        PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: start,
            restorationKey: nil
        )
    }

    private static let start = VFSPath.local(NSTemporaryDirectory())

    @Test("a connection asked for in a new tab lands there, and the tab it came from stays")
    func newTabLanding() async throws {
        let destination = try Self.destination()
        defer { try? FileManager.default.removeItem(at: destination) }
        let pane = Self.pane()
        let target = VFSPath.local(destination.path)

        pane.navigate(to: target, inNewTab: true)
        #expect(pane.tabs.count == 2)
        #expect(pane.activeTabIndex == 1)

        try await settleUntil { pane.panel.displayedEntries.count == 3 }
        #expect(pane.panel.path == target)
        #expect(pane.tabs[0].panel.path == Self.start)
    }

    /// The S3 account's walk upwards is the one landing with a row to return to, and it reaches the
    /// pane through the same funnel as a ⌘-click, so the funnel has to pass the row on.
    @Test("a connection landing in place puts the cursor on the row it was asked to")
    func inPlaceLandingKeepsFocus() async throws {
        let destination = try Self.destination()
        defer { try? FileManager.default.removeItem(at: destination) }
        let pane = Self.pane()
        let target = VFSPath.local(destination.path)
        // Not the first row, which is where the cursor lands when nothing asks otherwise.
        let row = VFSPath.local(destination.appendingPathComponent("c").path)

        pane.navigate(to: target, focus: row, inNewTab: false)
        #expect(pane.tabs.count == 1)

        try await settleUntil { pane.panel.displayedEntries.count == 3 }
        #expect(pane.panel.currentEntry?.path == row)
    }
}

private extension PanelViewController.ServerConnectRequest {
    var inNewTab: Bool {
        switch self {
        case let .sftp(request): request.inNewTab
        case let .ftp(request): request.inNewTab
        case let .s3(request): request.inNewTab
        case let .s3Account(request): request.inNewTab
        case let .webdav(request): request.inNewTab
        case let .smb(request): request.inNewTab
        }
    }

    var kind: ServerKind {
        switch self {
        case .sftp: .sftp
        case .ftp: .ftp
        case .s3, .s3Account: .s3
        case .webdav: .webdav
        case .smb: .smb
        }
    }
}
