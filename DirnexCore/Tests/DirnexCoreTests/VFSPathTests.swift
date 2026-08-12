import Foundation
import Testing

@testable import DirnexCore

@Suite("VFSPath")
struct VFSPathTests {
    // MARK: - Normalization

    @Test("normalizes duplicate and trailing slashes")
    func normalizes() {
        #expect(VFSPath.local("/Users//oleg/").path == "/Users/oleg")
        #expect(VFSPath.local("Users/oleg").path == "/Users/oleg")
        #expect(VFSPath.local("/").path == "/")
        #expect(VFSPath.local("").path == "/")
    }

    @Test("root and lastComponent")
    func rootAndLast() {
        #expect(VFSPath.local("/").isRoot)
        #expect(VFSPath.local("/").lastComponent == "/")
        #expect(!VFSPath.local("/Users/oleg").isRoot)
        #expect(VFSPath.local("/Users/oleg").lastComponent == "oleg")
    }

    @Test("parent walks up to the root then stops")
    func parent() {
        #expect(VFSPath.local("/Users/oleg").parent == .local("/Users"))
        #expect(VFSPath.local("/Users").parent == .local("/"))
        #expect(VFSPath.local("/").parent == nil)
    }

    // MARK: - Breadcrumbs

    @Test("ancestorsFromRoot lists every crumb from root to self")
    func ancestorsFromRoot() {
        #expect(VFSPath.local("/Users/oleg/Dev").ancestorsFromRoot == [
            .local("/"),
            .local("/Users"),
            .local("/Users/oleg"),
            .local("/Users/oleg/Dev")
        ])
    }

    @Test("ancestorsFromRoot at the root is just the root")
    func ancestorsAtRoot() {
        #expect(VFSPath.local("/").ancestorsFromRoot == [.local("/")])
    }

    // MARK: - child(towards:)

    @Test("child(towards:) steps one level down toward a descendant")
    func childTowardsDescendant() {
        let deep = VFSPath.local("/Users/oleg/Dev")
        #expect(VFSPath.local("/Users").child(towards: deep) == .local("/Users/oleg"))
        #expect(VFSPath.local("/").child(towards: deep) == .local("/Users"))
        // The immediate parent's child toward the descendant is the descendant itself.
        #expect(VFSPath.local("/Users/oleg").child(towards: deep) == deep)
    }

    @Test("child(towards:) returns nil when not an ancestor")
    func childTowardsUnrelated() {
        let deep = VFSPath.local("/Users/oleg/Dev")
        // Self is the descendant: no step remains.
        #expect(deep.child(towards: deep) == nil)
        // A sibling branch is not on the way.
        #expect(VFSPath.local("/Applications").child(towards: deep) == nil)
        // Different backend never matches.
        #expect(VFSPath(backend: VFSBackendID("zip"), path: "/Users").child(towards: deep) == nil)
    }

    // MARK: - isSelfOrDescendant(of:)

    @Test("isSelfOrDescendant(of:) matches the mount point itself and everything beneath it")
    func selfOrDescendantWithinVolume() {
        let mount = VFSPath.local("/Volumes/Temp")
        // The pane parked at the mount point itself must be recovered.
        #expect(mount.isSelfOrDescendant(of: mount))
        // Anything nested inside the ejected volume, at any depth, must be recovered.
        #expect(VFSPath.local("/Volumes/Temp/sub").isSelfOrDescendant(of: mount))
        #expect(VFSPath.local("/Volumes/Temp/a/b/c").isSelfOrDescendant(of: mount))
    }

    @Test("isSelfOrDescendant(of:) leaves paths outside the mount point alone")
    func selfOrDescendantOutsideVolume() {
        let mount = VFSPath.local("/Volumes/Temp")
        // The parent /Volumes is alongside the mount, not under it — keep it.
        #expect(!VFSPath.local("/Volumes").isSelfOrDescendant(of: mount))
        // A sibling volume whose name merely shares a prefix must not match.
        #expect(!VFSPath.local("/Volumes/Temp2").isSelfOrDescendant(of: mount))
        // An unrelated branch, and a different backend, never match.
        #expect(!VFSPath.local("/Users/oleg").isSelfOrDescendant(of: mount))
        #expect(!VFSPath(backend: VFSBackendID("zip"), path: "/Volumes/Temp/x")
            .isSelfOrDescendant(of: mount))
    }

    // MARK: - Remote predicates

    /// The predicate five app sites used to spell out by naming backends, which is how a freshly
    /// connected FTP server's path bar came to read "Results for /" (docs/NOTES.md ▸ AppKit).
    @Test("every connected remote account answers isRemoteConnection")
    func remoteConnectionCoversEveryRemote() {
        let sftp = SFTPLocation(host: "example.com", username: "oleg").backendID
        let ftp = FTPLocation(host: "nas.local", username: "oleg", security: .explicit).backendID
        let s3 = S3Location(
            host: "s3.eu-central-1.amazonaws.com",
            bucket: "photos",
            region: "eu-central-1",
            accessKeyID: "AKIAEXAMPLE"
        ).backendID
        for remote in [sftp, ftp, s3] {
            #expect(remote.isRemoteConnection)
        }
    }

    /// The other half, and the one that matters: a *virtual* listing must never be mistaken for a
    /// remote one — it is not re-listable, so a back/forward trail and a post-operation refresh are
    /// both wrong there.
    @Test("nothing local or virtual answers isRemoteConnection")
    func remoteConnectionExcludesLocalAndVirtual() {
        let virtual: [VFSBackendID] = [
            .local, .search, .trash, .icloud, .archive(forArchiveAt: "/Users/oleg/pkg.zip")
        ]
        for id in virtual {
            #expect(!id.isRemoteConnection)
            #expect(!id.acceptsUploads)
        }
    }

    /// S3 is re-listable and, until M21's write half lands, not a destination — so the two
    /// predicates deliberately disagree about exactly one backend. Asserted rather than left
    /// implicit, because collapsing them into one is the tempting simplification and it would let
    /// F5 start a job that fails inside the queue.
    @Test("S3 is a remote you can browse and not yet one you can copy into")
    func s3IsReadableNotWritable() {
        let s3 = S3Location(
            host: "s3.eu-central-1.amazonaws.com",
            bucket: "photos",
            region: "eu-central-1",
            accessKeyID: "AKIAEXAMPLE"
        ).backendID
        #expect(s3.isRemoteConnection)
        #expect(!s3.acceptsUploads)
        #expect(SFTPLocation(host: "example.com", username: "oleg").backendID.acceptsUploads)
        #expect(FTPLocation(host: "nas.local", username: "o", security: .explicit)
            .backendID.acceptsUploads)
    }
}
