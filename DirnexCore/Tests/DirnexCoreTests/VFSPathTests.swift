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

    /// With M21's write half landed, S3 answers both — it is browsable *and* a destination.
    ///
    /// The two predicates stay separate all the same, which is what this pins: they answer
    /// different questions, and S3 spent a milestone being the backend that distinguished them.
    /// Collapsing them now that every backend agrees is the tempting simplification, and it would
    /// put the next read-only backend straight back into failing *inside the queue* rather than
    /// saying up front that the other panel cannot receive files.
    @Test("every remote connection is now also a destination, by two separate questions")
    func s3IsReadableAndWritable() {
        let s3 = S3Location(
            host: "s3.eu-central-1.amazonaws.com",
            bucket: "photos",
            region: "eu-central-1",
            accessKeyID: "AKIAEXAMPLE"
        ).backendID
        #expect(s3.isRemoteConnection)
        #expect(s3.acceptsUploads)
        #expect(SFTPLocation(host: "example.com", username: "oleg").backendID.acceptsUploads)
        #expect(FTPLocation(host: "nas.local", username: "o", security: .explicit)
            .backendID.acceptsUploads)
    }

    /// `receivesFiles` — the union M23 needed, and the one place it differs from `.write`.
    ///
    /// It exists so ⌘V, a drop and F5 ask one question instead of three spelling `local || upload`
    /// by hand. The **S3 account** is the whole reason it is not the same as being writable: F7
    /// there creates a *bucket*, so every capability-shaped gate says yes while a pasted file has
    /// nowhere to go — and without this the paste is enabled and fails inside the queue instead of
    /// the menu item being gray.
    @Test("a file can land on this disk and on any account that takes uploads")
    func receivesFilesWhereBytesCanLand() {
        #expect(VFSBackendID.local.receivesFiles)
        #expect(SFTPLocation(host: "example.com", username: "oleg").backendID.receivesFiles)
        #expect(FTPLocation(host: "nas.local", username: "o", security: .explicit)
            .backendID.receivesFiles)
        let bucket = S3Location(
            host: "s3.eu-central-1.amazonaws.com",
            bucket: "photos",
            region: "eu-central-1",
            accessKeyID: "AKIAEXAMPLE"
        )
        #expect(bucket.backendID.receivesFiles)
        // The account holding that same bucket: browsable, writable, and not a destination.
        #expect(!VFSBackendID.s3Account(bucket.account).receivesFiles)
    }

    @Test("nothing virtual receives files — a results listing has no directory of its own")
    func virtualListingsReceiveNothing() {
        let virtual: [VFSBackendID] = [
            .search, .trash, .icloud, .archive(forArchiveAt: "/Users/oleg/pkg.zip")
        ]
        for id in virtual {
            #expect(!id.receivesFiles, "\(id) must not be a transfer destination")
        }
    }
}
