import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// What the pane asks before Open in Terminal runs on an SFTP folder (PLAN.md §M38 Slice 3).
///
/// The core suites pin what `ssh` is told. These pin the seam only the app has: which connection's
/// account, dial and password reach it, and when the command is on offer at all.
@Suite("Open in Terminal ▸ SFTP")
@MainActor
struct OpenInTerminalSFTPTests {
    private let location = SFTPLocation(host: "127.0.0.1", port: 2200, username: "me")
    private var folder: VFSPath { VFSPath(backend: .sftp(location), path: "/srv/www") }

    private func connected(
        _ authentication: SFTPAuthentication,
        password: String? = nil
    ) -> CompositeBackend {
        let composite = CompositeBackend(local: LocalBackend())
        composite.connectSFTP(location: location, authentication: authentication, password: password)
        return composite
    }

    /// A pane that has never been shown, so nothing lists anything.
    private func pane(on backend: CompositeBackend, at path: VFSPath) -> PanelViewController {
        let here = VFSPath.local(NSTemporaryDirectory())
        let pane = PanelViewController(
            backend: backend,
            restoration: nil,
            defaultPath: here,
            restorationKey: nil
        )
        pane.panel = Panel(path: path)
        return pane
    }

    @Test("a key account's session names the key and carries no secret")
    func keyAccount() throws {
        let found = try #require(
            connected(.key(identityFile: "/keys/id")).terminalSession(at: folder)
        )
        #expect(found.secret == nil)
        #expect(found.session.location == location)
        #expect(found.session.authentication == .key(identityFile: "/keys/id"))
        #expect(found.session.directory == "/srv/www")
    }

    @Test("a password account's secret comes from the live connection")
    func passwordAccount() throws {
        let found = try #require(connected(.password, password: "pw").terminalSession(at: folder))
        #expect(found.secret == "pw")
        #expect(found.session.authentication == .password)
    }

    @Test("a folder nothing is connected to has no session")
    func noConnectionNoSession() {
        #expect(CompositeBackend(local: LocalBackend()).terminalSession(at: folder) == nil)
    }

    @Test("a local folder has no ssh session")
    func localHasNoSession() {
        let composite = connected(.password, password: "pw")
        #expect(composite.terminalSession(at: .local("/tmp")) == nil)
    }

    @Test("the session dials what the connection dials")
    func sessionDialsTheConnectionsHost() {
        let transport = SFTPProcessTransport(
            location: location,
            authentication: .key(identityFile: "/keys/id"),
            connectTimeout: 7
        )
        let session = transport.terminalSession(in: "/srv/www")
        #expect(session.dial == transport.dialer.dialed)
        #expect(session.connectTimeout == 7)
    }

    @Test("the command is on offer for a connected SFTP folder and a local one")
    func onOffer() {
        let composite = connected(.key(identityFile: "/keys/id"))
        #expect(pane(on: composite, at: folder).canOpenInTerminal)
        #expect(pane(on: composite, at: .local("/tmp")).canOpenInTerminal)
    }

    @Test("the command is not on offer where there is nothing to open it on")
    func notOnOffer() {
        let connected = connected(.key(identityFile: "/keys/id"))
        let stranger = CompositeBackend(local: LocalBackend())
        #expect(!pane(on: stranger, at: folder).canOpenInTerminal)
        #expect(!pane(
            on: connected,
            at: VFSPath(backend: VFSBackendID("archive:/tmp/a.zip"), path: "/")
        ).canOpenInTerminal)
        #expect(!pane(
            on: connected,
            at: VFSPath(backend: .ftp(FTPLocation(host: "h", username: "u")), path: "/")
        ).canOpenInTerminal)
    }

    @Test("the refusal names the account")
    func refusalNamesTheAccount() {
        #expect(OpenInTerminalSFTPTests.alertTitle(for: location).contains("me@127.0.0.1"))
    }

    private static func alertTitle(for account: SFTPLocation) -> String {
        PanelViewController.noShellAlert(for: account).messageText
    }
}
