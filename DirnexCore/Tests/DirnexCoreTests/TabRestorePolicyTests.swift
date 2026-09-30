import Foundation
import Testing

@testable import DirnexCore

/// Which persisted tabs can come back, and what each of them needs first
/// (docs/LOCATION-SUPPORT.md ▸ "Session restore and workspaces drop remote tabs").
///
/// The rule that used to stand — restore exactly what lists with no preparation — is the one being
/// replaced, so most of what is asserted here is the *shape of the preparation*: a `stat` for a
/// directory, a `stat` on a different path for an archive, a registration for a server. The
/// interesting cases are the refusals, because every one of them is a way a restored tab could come
/// back pointing somewhere it should not.
@Suite("Tab restore requirements")
struct TabRestorePolicyTests {
    private static let sftpLocation = SFTPLocation(host: "example.com", username: "oleg")
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

    // MARK: - What each kind needs

    @Test("a local tab needs its directory and nothing else")
    func localNeedsTheDirectory() {
        let requirement = TabRestorePolicy.requirement(
            for: .local("/Users/oleg/Documents"),
            endpoint: nil
        )
        #expect(requirement == .directoryOnDisk)
    }

    /// The archive **file** is the thing to check, not the tab's own path: a tab sitting three
    /// folders into a zip has a path (`/docs/api`) that exists nowhere on disk, so a restore that
    /// stat'ed the path would drop every archive tab but the root's — and one that stat'ed nothing
    /// would mount an archive that has since been deleted.
    @Test("an archive tab names the file to check, not the location inside it")
    func archiveNamesTheFile() {
        let inside = VFSPath(
            backend: .archive(forArchiveAt: "/Users/oleg/pkg.zip"),
            path: "/docs/api"
        )
        #expect(
            TabRestorePolicy.requirement(for: inside, endpoint: nil)
                == .archiveOnDisk(path: "/Users/oleg/pkg.zip")
        )
    }

    @Test("a connected account needs its endpoint registered first")
    func remoteNeedsAConnection() {
        let path = VFSPath(backend: .sftp(Self.sftpLocation), path: "/var/log")
        #expect(
            TabRestorePolicy.requirement(for: path, endpoint: Self.sftpEndpoint)
                == .connection(Self.sftpEndpoint)
        )
    }

    /// All four remote backends, so the answer comes from `isRemoteConnection` rather than from a
    /// list of cases somebody has to remember to extend — this project's most repeated bug, and the
    /// property's own doc comment says so.
    @Test("every remote backend is restorable through its own endpoint")
    func everyRemoteBackend() {
        let ftpLocation = FTPLocation(host: "ftp.example.com", username: "oleg")
        let account = S3Account(
            host: "s3.eu-central-1.amazonaws.com",
            region: "eu-central-1",
            accessKeyID: "AKIAEXAMPLE"
        )
        let pairs: [(VFSPath, ServerEndpoint)] = [
            (VFSPath(backend: .sftp(Self.sftpLocation), path: "/"), Self.sftpEndpoint),
            (
                VFSPath(backend: .ftp(ftpLocation), path: "/pub"),
                .ftp(location: ftpLocation, authentication: .anonymous)
            ),
            (VFSPath(backend: .s3(Self.bucket), path: "/2026"), .s3(Self.bucket)),
            (VFSPath(backend: .s3Account(account), path: "/"), .s3Account(account))
        ]
        for (path, endpoint) in pairs {
            #expect(
                TabRestorePolicy.requirement(for: path, endpoint: endpoint)
                    == .connection(endpoint),
                "\(path.backend)"
            )
        }
    }

    // MARK: - Refusals

    /// The check that makes weighing the pair worthwhile at all. A path and an endpoint are two
    /// fields of hand-editable JSON, so nothing but comparing them stops a restore from connecting
    /// to one server and then listing a path that belongs to another — which would draw a perfectly
    /// plausible listing under the wrong name.
    @Test("an endpoint that is not this path's backend restores nothing")
    func mismatchedEndpointIsRefused() {
        let elsewhere = VFSPath(
            backend: .sftp(SFTPLocation(host: "other.example.com", username: "oleg")),
            path: "/var/log"
        )
        #expect(TabRestorePolicy.requirement(for: elsewhere, endpoint: Self.sftpEndpoint) == nil)
    }

    /// Reachable rather than hypothetical: a session written before the endpoint was stored carries
    /// the descriptor and nothing else, and such a tab has nothing that could ever reconnect it.
    @Test("a remote tab with no endpoint is dropped rather than restored dead")
    func remoteWithoutAnEndpointIsRefused() {
        let path = VFSPath(backend: .sftp(Self.sftpLocation), path: "/var/log")
        #expect(TabRestorePolicy.requirement(for: path, endpoint: nil) == nil)
    }

    /// SMB is the endpoint with no backend of its own — the share is mounted into `/Volumes`, so a
    /// pane on it is `.local` — and an SMB endpoint stored against a remote path can therefore only
    /// be a mistake.
    @Test("an SMB endpoint never satisfies a remote path")
    func smbIsNeverAConnection() {
        let path = VFSPath(backend: .sftp(Self.sftpLocation), path: "/")
        let smb = ServerEndpoint.smb(SMBLocation(host: "nas.local", share: "media", username: "o"))
        #expect(smb.backendID == nil)
        #expect(TabRestorePolicy.requirement(for: path, endpoint: smb) == nil)
    }

    @Test("the virtual listings stay out of session restore")
    func virtualListingsAreRefused() {
        for backend in [VFSBackendID.search, .trash, .icloud] {
            #expect(
                TabRestorePolicy.requirement(
                    for: VFSPath(backend: backend, path: "/"),
                    endpoint: nil
                ) == nil,
                "\(backend)"
            )
        }
    }

    // MARK: - Connecting unasked

    /// Settings ▸ Panels promises in writing that 0 means "never contact a server unasked", and
    /// relaunching onto a restored tab is unasked however true it is that the tab was left open.
    @Test("a zero refresh floor withholds the connection a relaunch would open by itself")
    func zeroFloorWithholdsTheUnaskedConnect() {
        #expect(!RemoteRefreshPolicy.contactsServersUnasked(floor: 0))
        #expect(RemoteRefreshPolicy.contactsServersUnasked(floor: 15))
        #expect(RemoteRefreshPolicy.contactsServersUnasked(floor: RemoteRefreshPolicy.defaultFloor))
    }

    /// A hand-edited or garbage floor is clamped before it is read, so it cannot answer "yes" by
    /// being nonsense — the same clamp the timer applies, asked through the same funnel.
    @Test("an out-of-band floor is clamped before the promise is read")
    func floorIsClampedFirst() {
        #expect(!RemoteRefreshPolicy.contactsServersUnasked(floor: -30))
        #expect(RemoteRefreshPolicy.contactsServersUnasked(floor: .infinity))
    }
}
