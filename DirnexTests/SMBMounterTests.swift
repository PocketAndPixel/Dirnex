import DirnexCore
import Foundation
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

/// The status mapping in `SMBMountError`. Assertions stay language-independent — the app test target
/// inherits the developer's own `AppleLanguages` pin (docs/NOTES.md), so they check the proper nouns
/// spliced into the message in every language (the host, the share, the account) and that a diagnosed
/// status no longer reads like the raw-number fallback, rather than exact English text.
@Suite("SMBMountError diagnosis")
struct SMBMountErrorTests {
    /// A status with no specific mapping, used as the "generic fallback" yardstick.
    private static let unmapped: Int32 = -9999

    /// A bare host, for the statuses whose sentence names nothing else.
    private static func at(_ host: String) -> SMBLocation { SMBLocation(host: host) }

    /// The status `NetFSMountURLSync` returns for a share that is not there **and** for one the
    /// account may not use — measured against a real server, which is the whole reason the sentence
    /// below has to carry both readings (see `SMBMountError`).
    private static let unavailable = Int32(ENOENT)

    @Test("‑6003 (no shares available) is diagnosed specifically and names the host")
    func noSharesAvailable() {
        let message = SMBMountError(status: -6003, location: Self.at("pcpc")).errorDescription
        let fallback = SMBMountError(status: Self.unmapped, location: Self.at("pcpc")).errorDescription
        // Reached the server, so the host is named — and it isn't the raw-number fallback.
        #expect(message?.contains("pcpc") == true)
        #expect(message != fallback)
    }

    @Test("the NetFS-layer no-shares code maps the same as the NetAuth one")
    func noSharesAvailNetFS() {
        let netAuth = SMBMountError(status: -6003, location: Self.at("h")).errorDescription
        let netFS = SMBMountError(status: -5998, location: Self.at("h")).errorDescription
        #expect(netFS == netAuth)
    }

    @Test("‑6004 (guest refused) is diagnosed specifically and names the host")
    func guestNotSupported() {
        let message = SMBMountError(status: -6004, location: Self.at("nas.local")).errorDescription
        let fallback = SMBMountError(status: Self.unmapped, location: Self.at("nas.local")).errorDescription
        #expect(message?.contains("nas.local") == true)
        #expect(message != fallback)
    }

    @Test("the generic fallback embeds the status, so two unknown codes read differently")
    func genericEmbedsStatus() {
        // The default branch interpolates `\(status)`, which `String(localized:)` renders with the
        // region's number formatting (a UA region shows "‑9 999", grouping separator and all — the
        // same reason the report read "error ‑6 003"), so assert the message *varies* with the code
        // rather than matching an exact digit string.
        let oneCode = SMBMountError(status: -9999, location: Self.at("h")).errorDescription
        let otherCode = SMBMountError(status: -8888, location: Self.at("h")).errorDescription
        #expect(oneCode != otherCode)
    }

    // MARK: - The one status that means two things

    /// The regression the reworded sentence exists for. A user whose account simply lacked access to
    /// a share was told "The share wasn’t found — check the share name", which named neither the
    /// account nor the possibility of a permission problem — and, in the picker flow, sent them to a
    /// Share field they had deliberately left blank. Asserting on the *account name* is what pins it
    /// language-independently: the old sentence named only the host, in every language.
    @Test("a share that will not mount names the share, the host and the account")
    func unavailableNamesTheAccount() {
        let location = SMBLocation(host: "nas", share: "Photos", username: "dirnex-test")
        let message = SMBMountError(status: Self.unavailable, location: location).errorDescription
        #expect(message?.contains("Photos") == true)
        #expect(message?.contains("nas") == true)
        #expect(message?.contains("dirnex-test") == true)
    }

    @Test("ENODEV is diagnosed as the same two-readings case as ENOENT")
    func noDeviceReadsTheSame() {
        let location = SMBLocation(host: "nas", share: "Photos", username: "dirnex-test")
        let enoent = SMBMountError(status: Int32(ENOENT), location: location).errorDescription
        let enodev = SMBMountError(status: Int32(ENODEV), location: location).errorDescription
        #expect(enodev == enoent)
    }

    /// The picker flow — a blank Share field, so macOS's own share picker chose the folder and never
    /// told us which. The folder therefore goes unnamed rather than named wrongly, while the account
    /// (the half we do know, and the half the user was missing) is still named.
    @Test("a folder chosen in the OS picker is left unnamed, and the account is still named")
    func pickedFolderIsNotNamed() {
        let picked = SMBLocation(host: "nas", username: "dirnex-test")
        let named = SMBLocation(host: "nas", share: "Photos", username: "dirnex-test")
        let message = SMBMountError(status: Self.unavailable, location: picked).errorDescription
        #expect(message?.contains("dirnex-test") == true)
        #expect(message?.contains("Photos") == false) // nothing to name, so nothing is invented
        #expect(message != SMBMountError(status: Self.unavailable, location: named).errorDescription)
    }

    /// A guest mount has no account to name, so it must not render an empty one — the sentence that
    /// would otherwise read «or “” may not have permission».
    @Test("a guest mount names no account and reads differently from an authenticated one")
    func guestNamesNoAccount() {
        let guest = SMBLocation(host: "nas", share: "Photos")
        let authenticated = SMBLocation(host: "nas", share: "Photos", username: "dirnex-test")
        let message = SMBMountError(status: Self.unavailable, location: guest).errorDescription
        #expect(message?.contains("“”") == false)
        #expect(message != SMBMountError(status: Self.unavailable, location: authenticated)
            .errorDescription)
    }

    @Test("the two-readings sentence is not the raw-number fallback")
    func unavailableIsDiagnosed() {
        let location = SMBLocation(host: "nas", share: "Photos", username: "dirnex-test")
        let message = SMBMountError(status: Self.unavailable, location: location).errorDescription
        let fallback = SMBMountError(status: Self.unmapped, location: location).errorDescription
        #expect(message != fallback)
    }
}
