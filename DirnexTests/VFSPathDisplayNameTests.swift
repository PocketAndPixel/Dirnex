import DirnexCore
import Testing
@testable import Dirnex

/// `VFSPath.displayName` is what a sentence calls a location — the load-failure sheet's title above
/// all. The case that matters is a backend *root*, where `lastComponent` is a bare `"/"` that names
/// nothing: a corrupt archive's alert read «Can't open "/"» over a body naming the file correctly.
@Suite("VFSPath display name")
struct VFSPathDisplayNameTests {
    private func archive(_ onDisk: String) -> VFSBackendID { .archive(forArchiveAt: onDisk) }

    @Test("an archive's root is named by the archive file, not by “/”")
    func archiveRoot() {
        let path = VFSPath(backend: archive("/Users/oleg/Downloads/broken.zip"), path: "/")

        #expect(path.displayName == "broken.zip")
    }

    @Test("a nested mount's root is named by the extracted member — the inner archive's own name")
    func nestedArchiveRoot() {
        // A nested archive is browsed as its temp extraction, whose file name is the member's.
        let path = VFSPath(backend: archive("/var/folders/T/dirnex-x/inner.tar.gz"), path: "/")

        #expect(path.displayName == "inner.tar.gz")
    }

    @Test("inside an archive the entry's own name is already right")
    func insideArchive() {
        let path = VFSPath(backend: archive("/Users/oleg/pkg.zip"), path: "/folder/sub")

        #expect(path.displayName == "sub")
    }

    @Test("an SFTP root is named by the account, matching the path bar's root crumb")
    func sftpRoot() {
        let location = SFTPLocation(host: "example.com", port: 2222, username: "oleg")
        let path = VFSPath(backend: .sftp(location), path: "/")

        #expect(path.displayName == "oleg@example.com")
    }

    /// The case that was missing, and the one live run showed it twice over: a bucket root drew a
    /// bare `"/"` on the tab chip directly above a crumb reading `probe — 127.0.0.1`, and F7 offered
    /// «Create a folder in "/"». A bucket is named by itself rather than by the key that reaches it,
    /// with the endpoint alongside, since two providers can hold a bucket of the same name.
    @Test("an S3 root is named by the bucket and its endpoint")
    func s3Root() {
        let path = VFSPath(backend: .s3(Self.bucket), path: "/")

        #expect(path.displayName == "probe — 127.0.0.1")
    }

    @Test("inside a bucket the key's own last component is already right")
    func insideBucket() {
        let path = VFSPath(backend: .s3(Self.bucket), path: "/docs/api")

        #expect(path.displayName == "api")
    }

    /// `displayName` answers only at a root, while the path bar needs the same title at every depth
    /// — which is why the title has one definition and both read it. Pinning the deep case is what
    /// says the two cannot drift back apart.
    @Test("the root title is the same string at every depth, which is what the crumb needs")
    func rootTitleAtDepth() {
        let root = VFSPath(backend: .s3(Self.bucket), path: "/")
        let deep = VFSPath(backend: .s3(Self.bucket), path: "/docs/api")

        #expect(deep.backendRootTitle == root.backendRootTitle)
        #expect(deep.backendRootTitle == "probe — 127.0.0.1")
    }

    /// The same gap one level up, and the next backend to arrive with a root of its own: an account
    /// pane's path is `/` and nothing else, so this title is the *entire* crumb trail and the whole
    /// tab chip. It is the endpoint alone — a key id is characters the user never typed, and it read
    /// as noise where the one thing on screen should say where the pane is standing. Two accounts on
    /// one endpoint are told apart in the sidebar, which carries the user's own names and the full
    /// descriptor as a subtitle.
    @Test("an S3 account root is named by its endpoint alone, with no key id")
    func s3AccountRoot() {
        let path = VFSPath(backend: .s3Account(Self.bucket.account), path: "/")

        #expect(path.displayName == "127.0.0.1")
        #expect(!path.displayName.contains("AKIAPROBEKEYEXAMPLE"))
    }

    /// And it is not the bucket's title, which is what would happen if the two shared a branch: an
    /// account pane would then name whichever bucket the descriptor happened to parse as.
    @Test("an account and a bucket on one endpoint name themselves differently")
    func accountAndBucketNamesDiffer() {
        let bucket = VFSPath(backend: .s3(Self.bucket), path: "/")
        let account = VFSPath(backend: .s3Account(Self.bucket.account), path: "/")

        #expect(bucket.displayName != account.displayName)
    }

    @Test("a local path keeps its last component, and has no root title of its own")
    func localPath() {
        #expect(VFSPath.local("/Users/oleg/Dev").displayName == "Dev")
        #expect(VFSPath.local("/").backendRootTitle == nil)
    }

    private static let bucket = S3Location(
        host: "127.0.0.1",
        port: 9599,
        bucket: "probe",
        region: "us-east-1",
        accessKeyID: "AKIAPROBEKEYEXAMPLE",
        addressing: .path,
        usesTLS: false
    )
}
