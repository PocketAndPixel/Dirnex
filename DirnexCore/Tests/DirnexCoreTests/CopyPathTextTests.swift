import Foundation
import Testing

@testable import DirnexCore

@Suite("CopyPathText")
struct CopyPathTextTests {
    private func archive(_ onDisk: String) -> VFSBackendID { .archive(forArchiveAt: onDisk) }

    @Test("a local path is copied as it is")
    func localPath() {
        #expect(CopyPathText.text(for: .local("/Users/oleg/Downloads")) == "/Users/oleg/Downloads")
        #expect(CopyPathText.text(for: .local("/")) == "/")
    }

    /// The reported case: right-clicking the archive's own crumb copied `/`.
    @Test("an archive's root is the archive file itself")
    func archiveRoot() {
        let zip = "/Users/oleg/Downloads/mvpn/openvpn-install.exe.zip"
        let root = VFSPath(backend: archive(zip), path: "/")

        #expect(CopyPathText.text(for: root) == zip)
    }

    @Test("a member is the archive file followed by its path inside it")
    func archiveMember() {
        let zip = "/Users/oleg/Downloads/pkg.zip"

        #expect(
            CopyPathText.text(for: VFSPath(backend: archive(zip), path: "/setup.exe"))
                == "/Users/oleg/Downloads/pkg.zip/setup.exe"
        )
        #expect(
            CopyPathText.text(for: VFSPath(backend: archive(zip), path: "/docs/readme.txt"))
                == "/Users/oleg/Downloads/pkg.zip/docs/readme.txt"
        )
    }

    /// The inner archive is browsed from a temp extraction; the text must follow the chain the user
    /// walked rather than name the extraction.
    @Test("a nested archive is written through its enclosing member, never its temp copy")
    func nestedArchive() {
        let outer = "/Users/oleg/Downloads/outer.zip"
        let mount = "/private/tmp/DirnexExtract/A/inner.zip"
        let ancestry = [VFSPath(backend: archive(outer), path: "/sub/inner.zip")]

        let member = VFSPath(backend: archive(mount), path: "/notes/a.txt")
        #expect(
            CopyPathText.text(for: member, archiveAncestry: ancestry)
                == "/Users/oleg/Downloads/outer.zip/sub/inner.zip/notes/a.txt"
        )
        let innerRoot = VFSPath(backend: archive(mount), path: "/")
        #expect(
            CopyPathText.text(for: innerRoot, archiveAncestry: ancestry)
                == "/Users/oleg/Downloads/outer.zip/sub/inner.zip"
        )
    }

    /// A path-bar crumb in an *outer* frame is handed the innermost mount's chain. Taking the whole
    /// chain regardless would write the inner archive's members into a path in the outer one.
    @Test("an outer frame's location takes only the part of the chain above it")
    func outerFrameOfADeeperChain() {
        let outer = "/a/b/outer.zip"
        let middle = "/private/tmp/mid.zip"
        let inner = "/private/tmp/inner.zip"
        let ancestry = [
            VFSPath(backend: archive(outer), path: "/sub/mid.zip"),
            VFSPath(backend: archive(middle), path: "/deep/inner.zip")
        ]

        #expect(
            CopyPathText.text(
                for: VFSPath(backend: archive(outer), path: "/sub"),
                archiveAncestry: ancestry
            )
                == "/a/b/outer.zip/sub"
        )
        #expect(
            CopyPathText.text(
                for: VFSPath(backend: archive(middle), path: "/deep"),
                archiveAncestry: ancestry
            )
                == "/a/b/outer.zip/sub/mid.zip/deep"
        )
        #expect(
            CopyPathText.text(
                for: VFSPath(backend: archive(inner), path: "/x/y"),
                archiveAncestry: ancestry
            )
                == "/a/b/outer.zip/sub/mid.zip/deep/inner.zip/x/y"
        )
    }

    /// A remote archive's first link is where it lives on the server — a container, not an enclosing
    /// archive — so it is written the way that server's own row is, and only once.
    @Test("an archive fetched from a server is rooted at its server path")
    func remoteArchive() {
        let origin = VFSPath(
            backend: .sftp(SFTPLocation(host: "example.com", username: "oleg")),
            path: "/srv/backup.zip"
        )
        let mount = "/tmp/DirnexRemote/aaa/backup.zip"
        let nested = "/tmp/extract/bbb/inner.zip"
        let ancestry = [origin, VFSPath(backend: archive(mount), path: "/docs/inner.zip")]

        #expect(
            CopyPathText.text(
                for: VFSPath(backend: archive(mount), path: "/docs"),
                archiveAncestry: [origin]
            )
                == "/srv/backup.zip/docs"
        )
        #expect(
            CopyPathText.text(
                for: VFSPath(backend: archive(nested), path: "/notes"),
                archiveAncestry: ancestry
            )
                == "/srv/backup.zip/docs/inner.zip/notes"
        )
        // The server's own row is unchanged by any of this.
        #expect(CopyPathText.text(for: origin) == "/srv/backup.zip")
    }
}
