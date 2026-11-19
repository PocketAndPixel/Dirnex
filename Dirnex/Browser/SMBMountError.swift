import DirnexCore
import Foundation

/// A failed SMB mount, mapped from the NetFS/`errno` status into a human-readable reason.
///
/// `NetFSMountURLSync` returns a *positive* value for an `errno` and a *negative* value for an
/// OSStatus (documented in `<NetFS/NetFS.h>`). The negative NetAuth codes below aren't exported by
/// the NetFS module, so they're spelled out here with their symbolic names, exactly as that header
/// lists them.
struct SMBMountError: LocalizedError {
    /// No share was available to mount — the server was reached and authenticated, but named no
    /// share (blank Share field). `<NetAuth/NetAuthErrors.h>`.
    static let kNetAuthErrorNoSharesAvailable: Int32 = -6003
    /// The server refused a guest / anonymous mount. `<NetAuth/NetAuthErrors.h>`.
    static let kNetAuthErrorGuestNotSupported: Int32 = -6004
    /// The NetFS-layer spelling of "no shares available". `<NetFS/NetFS.h>`.
    static let eNetFSNoSharesAvail: Int32 = -5998
    /// The mount was canceled (Carbon `userCanceledErr`), the negative-OSStatus twin of `ECANCELED`.
    static let userCanceledErr: Int32 = -128
    /// The account may not sign in now: disabled, locked out, or a guest on a server with guest
    /// access off. `ENETFSACCOUNTRESTRICTED` in `<NetFS/NetFS.h>`; the NAS answered it to a guest
    /// session on 2026-11-04 although its server info said guests were supported.
    static let eNetFSAccountRestricted: Int32 = -5999

    let status: Int32
    /// Where the mount was aimed. The host is named in every sentence below; the share and the
    /// account are named only by `shareUnavailable`, the one status that cannot diagnose itself.
    let location: SMBLocation
    /// What the server's share list said about the share, when it was asked after an `ENOENT`
    /// (PLAN.md §M35). `.unknown` keeps the sentence that names both readings.
    var absence: SMBShareAbsence = .unknown

    private var host: String { location.host }

    var errorDescription: String? {
        switch status {
        case Int32(EAUTH), Int32(EACCES), Int32(EPERM):
            return String(
                localized: """
                Authentication failed. Check the username and password, or try a guest connection.
                """,
                comment: "SMB mount failure: the server rejected the credentials."
            )
        // A reachable, authenticated server that offered no share to mount comes back as a *negative*
        // OSStatus (from <NetFS/NetFS.h> and <NetAuth/NetAuthErrors.h>), not an errno — almost always
        // because the Share field was left blank, so there was nothing to open. A blank Share field
        // lists the server's shares now (PLAN.md §M35), which answers an empty list rather than this,
        // so it is kept for a server that answers a mount this way.
        case Self.kNetAuthErrorNoSharesAvailable, // -6003
             Self.eNetFSNoSharesAvail: // -5998
            return String(
                localized: """
                Connected to “\(host)”, but couldn’t find a shared folder to open. Enter the name of a \
                folder shared on that computer in the Share field.
                """,
                comment: "SMB mount failure: authenticated but no share to mount; %@ is the host name."
            )
        case Self.kNetAuthErrorGuestNotSupported: // -6004
            return String(
                localized: "“\(host)” doesn’t allow guest access. Enter a username and password.",
                comment: "SMB mount failure: the server refused a guest mount; %@ is the host name."
            )
        case Self.eNetFSAccountRestricted: // -5999
            guard let username = location.username else {
                return String(
                    localized: "“\(host)” doesn’t allow guest access. Enter a username and password.",
                    comment: "SMB mount failure: the server refused a guest mount; %@ is the host name."
                )
            }
            return String(
                localized: """
                “\(username)” can’t sign in to “\(host)” right now. The account may be disabled, or \
                locked after too many failed attempts.
                """,
                comment: """
                SMB connect failure: the server refused the account itself, not its password; \
                %1$@ is the account name, %2$@ the host name.
                """
            )
        // A share the account may not use and a share that isn’t there are the *same* status.
        // Measured 2026-09-04 against a real Synology: `NetFSMountURLSync` answers ENOENT for a share
        // the server refuses this account (`Photos`, `Movies`) and for one that does not exist
        // (`NoSuchShareXYZ`) alike, while a share the account may use mounts (status 0) and the same
        // refused share mounts for another account — so the code carries no permission signal at all
        // (docs/NOTES.md ▸ SMB, "a denied share and a missing share are one status"). The sentence
        // therefore has to carry both readings: "check the share name" alone sent a user whose account
        // simply lacked access hunting for a typo, and in the picker flow it named a Share field they
        // had deliberately left blank.
        case Int32(ENOENT), Int32(ENODEV):
            if let share = location.share, let sentence = Self.shareAbsent(
                share: share,
                host: host,
                username: location.username,
                absence: absence
            ) {
                return sentence
            }
            return Self.shareUnavailable(
                share: location.share,
                host: host,
                username: location.username
            )
        case Int32(EHOSTDOWN), Int32(EHOSTUNREACH), Int32(ETIMEDOUT), Int32(ECONNREFUSED):
            return String(
                localized: "Couldn’t reach “\(host)”. Check the address and that the server is online.",
                comment: "SMB mount failure: the host did not answer; %@ is the host name."
            )
        case Int32(ECANCELED), Self.userCanceledErr: // -128
            return String(
                localized: "The connection was canceled.",
                comment: "SMB mount failure: the user canceled the mount."
            )
        default:
            return String(
                localized: "Couldn’t mount the share (error \(status)).",
                comment: "SMB mount failure with no specific diagnosis; %lld is the errno."
            )
        }
    }

    /// The sentence for a share the server's list has spoken about, or `nil` when it has not and the
    /// status has to carry both readings (``shareUnavailable(share:host:username:)``).
    ///
    /// A listed share that will not mount is one this account may not use, and says so plainly. One
    /// that is not listed is one the server *doesn't offer* this account, which stays true on a server
    /// that hides from an account the shares it refuses, where "doesn't exist" would not.
    private static func shareAbsent(
        share: String,
        host: String,
        username: String?,
        absence: SMBShareAbsence
    ) -> String? {
        switch (absence, username) {
        case (.unknown, _):
            return nil
        case let (.notPermitted, username?):
            return String(
                localized: "“\(username)” doesn’t have permission to use “\(share)” on “\(host)”.",
                comment: """
                SMB mount failure: the server lists the shared folder to this account and refuses it; \
                %1$@ is the account name, %2$@ the share name, %3$@ the host name.
                """
            )
        case (.notPermitted, nil):
            return String(
                localized: "A guest connection doesn’t have permission to use “\(share)” on “\(host)”.",
                comment: """
                SMB guest mount failure: the server lists the shared folder and refuses it to guests; \
                %1$@ is the share name, %2$@ the host name.
                """
            )
        case let (.notOffered, username?):
            return String(
                localized: "“\(host)” doesn’t offer a shared folder named “\(share)” to “\(username)”.",
                comment: """
                SMB mount failure: the server's list of shared folders for this account has no such \
                name; %1$@ is the host name, %2$@ the share name, %3$@ the account name.
                """
            )
        case (.notOffered, nil):
            return String(
                localized: "“\(host)” doesn’t offer a shared folder named “\(share)” to guests.",
                comment: """
                SMB guest mount failure: the server's list of shared folders has no such name; \
                %1$@ is the host name, %2$@ the share name.
                """
            )
        }
    }

    /// The sentence for the one status that means two different things — the share is not there, or
    /// this account may not use it (see the `ENOENT` case above).
    ///
    /// Four whole sentences rather than one with an interpolated fragment: a fragment spliced into a
    /// localized sentence has to be pre-inflected to survive the case system of half the shipped
    /// languages (docs/NOTES.md ▸ Localization). Used when the server's list could not be had after
    /// the refusal (``shareAbsent(share:host:username:absence:)`` otherwise). The two sentences with
    /// no share were for macOS's own share picker, which never said what was picked; nothing mounts
    /// without a share since Dirnex lists a server itself (PLAN.md §M35), and they stay for a status
    /// that arrives without one.
    private static func shareUnavailable(share: String?, host: String, username: String?) -> String {
        switch (share, username) {
        case let (share?, username?):
            return String(
                localized: """
                Couldn’t open “\(share)” on “\(host)”. That shared folder may not exist, or \
                “\(username)” may not have permission to use it.
                """,
                comment: """
                SMB mount failure; %1$@ is the share name, %2$@ the host name, %3$@ the account name.
                """
            )
        case let (share?, nil):
            return String(
                localized: """
                Couldn’t open “\(share)” on “\(host)”. That shared folder may not exist, or a guest \
                connection may not have permission to use it.
                """,
                comment: "SMB guest mount failure; %1$@ is the share name, %2$@ the host name."
            )
        case let (nil, username?):
            return String(
                localized: """
                The shared folder couldn’t be opened on “\(host)”. It may not exist, or “\(username)” \
                may not have permission to use it.
                """,
                comment: """
                SMB mount failure, folder chosen in macOS’s share picker so its name is unknown; \
                %1$@ is the host name, %2$@ the account name.
                """
            )
        case (nil, nil):
            return String(
                localized: """
                The shared folder couldn’t be opened on “\(host)”. It may not exist, or a guest \
                connection may not have permission to use it.
                """,
                comment: """
                SMB guest mount failure, folder chosen in macOS’s share picker; %@ is the host name.
                """
            )
        }
    }
}
