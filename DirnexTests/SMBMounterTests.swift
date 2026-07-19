import DirnexCore
import Testing

@testable import Dirnex

/// The one correctness-sensitive transformation in `SMBMounter`: the URL handed to
/// `NetFSMountURLSync`. The username is supplied to NetFS as a *separate* argument, so it must never
/// also appear in this URL — embedding it in both is ambiguous (PLAN.md §M5 "SMB rides the OS
/// mounter"). The share and a non-default port do belong in the URL; the default port is elided
/// (matching Finder), so the mount targets exactly what the user typed. Everything else in the
/// mounter is non-hermetic NetFS / mount I/O and is exercised live, not here.
@Suite("SMBMounter mount URL")
struct SMBMounterTests {
    @Test("a guest share URL carries host and share, no user")
    func guestShare() {
        let location = SMBLocation(host: "nas.local", share: "Media")
        #expect(SMBMounter.mountURLString(for: location) == "smb://nas.local/Media")
    }

    @Test("the username is never embedded in the mount URL")
    func usernameStripped() {
        let location = SMBLocation(host: "nas.local", share: "Media", username: "oleg")
        // Passed separately to NetFS — so it stays out of the URL entirely.
        #expect(SMBMounter.mountURLString(for: location) == "smb://nas.local/Media")
    }

    @Test("a non-default port is included, the default (445) elided")
    func portHandling() {
        let custom = SMBLocation(host: "host", share: "share", port: 1445)
        #expect(SMBMounter.mountURLString(for: custom) == "smb://host:1445/share")

        let standard = SMBLocation(host: "host", share: "share", port: SMBLocation.defaultPort)
        #expect(SMBMounter.mountURLString(for: standard) == "smb://host/share")
    }

    @Test("a share-less location stops at the host")
    func shareless() {
        let location = SMBLocation(host: "host", username: "oleg")
        #expect(SMBMounter.mountURLString(for: location) == "smb://host")
    }
}
