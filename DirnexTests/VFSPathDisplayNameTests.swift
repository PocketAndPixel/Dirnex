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

    @Test("a local path keeps its last component")
    func localPath() {
        #expect(VFSPath.local("/Users/oleg/Dev").displayName == "Dev")
    }
}
