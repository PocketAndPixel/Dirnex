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

/// The negative-OSStatus mapping in `SMBMountError`. Assertions stay language-independent — the app
/// test target inherits the developer's own `AppleLanguages` pin (docs/NOTES.md), so they check the
/// host name (a proper noun spliced into the message in every language) and that a diagnosed status
/// no longer reads like the raw-number fallback, rather than exact English text.
@Suite("SMBMountError diagnosis")
struct SMBMountErrorTests {
    /// A status with no specific mapping, used as the "generic fallback" yardstick.
    private static let unmapped: Int32 = -9999

    @Test("‑6003 (no shares available) is diagnosed specifically and names the host")
    func noSharesAvailable() {
        let message = SMBMountError(status: -6003, host: "pcpc").errorDescription
        let fallback = SMBMountError(status: Self.unmapped, host: "pcpc").errorDescription
        // Reached the server, so the host is named — and it isn't the raw-number fallback.
        #expect(message?.contains("pcpc") == true)
        #expect(message != fallback)
    }

    @Test("the NetFS-layer no-shares code maps the same as the NetAuth one")
    func noSharesAvailNetFS() {
        let netAuth = SMBMountError(status: -6003, host: "h").errorDescription
        let netFS = SMBMountError(status: -5998, host: "h").errorDescription
        #expect(netFS == netAuth)
    }

    @Test("‑6004 (guest refused) is diagnosed specifically and names the host")
    func guestNotSupported() {
        let message = SMBMountError(status: -6004, host: "nas.local").errorDescription
        let fallback = SMBMountError(status: Self.unmapped, host: "nas.local").errorDescription
        #expect(message?.contains("nas.local") == true)
        #expect(message != fallback)
    }

    @Test("the generic fallback embeds the status, so two unknown codes read differently")
    func genericEmbedsStatus() {
        // The default branch interpolates `\(status)`, which `String(localized:)` renders with the
        // region's number formatting (a UA region shows "‑9 999", grouping separator and all — the
        // same reason the report read "error ‑6 003"), so assert the message *varies* with the code
        // rather than matching an exact digit string.
        let oneCode = SMBMountError(status: -9999, host: "h").errorDescription
        let otherCode = SMBMountError(status: -8888, host: "h").errorDescription
        #expect(oneCode != otherCode)
    }
}
