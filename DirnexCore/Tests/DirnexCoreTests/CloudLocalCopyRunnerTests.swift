import Foundation
import Testing

@testable import DirnexCore

/// ``CloudLocalCopyRunner``: what each action does with a folder, and where a refusal goes.
///
/// Split from `CloudLocalCopyTests` along the seam between deciding and running. The system call is
/// handed in, so every assertion here is about what the runner *asked* — the one thing a fake can
/// report honestly, since no provider can be a test dependency.
@Suite("Cloud local copy ▸ running")
struct CloudLocalCopyRunnerTests {
    private static func entry(
        _ path: String,
        kind: FileEntry.Kind = .file,
        dataless: Bool = false,
        backend: VFSBackendID = .local
    ) -> FileEntry {
        FileEntry(
            path: VFSPath(backend: backend, path: path),
            name: (path as NSString).lastPathComponent,
            kind: kind,
            byteSize: 1,
            modificationDate: Date(timeIntervalSince1970: 0),
            creationDate: Date(timeIntervalSince1970: 0),
            isHidden: false,
            permissions: 0o644,
            inode: 0,
            isDataless: dataless
        )
    }

    private static func error(_ domain: String, _ code: Int, over underlying: NSError? = nil) -> NSError {
        NSError(
            domain: domain,
            code: code,
            userInfo: underlying.map { [NSUnderlyingErrorKey: $0] } ?? [:]
        )
    }

    @Test("Remove Download asks once per item, a folder included, and never walks")
    func removeDoesNotWalk() {
        let tree = FakeCloudTree(["/c": [Self.entry("/c/inner.txt")]])
        var asked: [VFSPath] = []
        let report = CloudLocalCopyRunner.run(
            .removeDownload,
            on: [
                CloudLocalCopyTarget(path: .local("/a"), isDirectory: false, isDataless: false),
                CloudLocalCopyTarget(path: .local("/b"), isDirectory: false, isDataless: true),
                CloudLocalCopyTarget(path: .local("/c"), isDirectory: true, isDataless: false)
            ],
            using: tree
        ) { action, path in
            #expect(action == .removeDownload)
            asked.append(path)
        }
        // The placeholder has nothing to remove; the folder is one request because the system call
        // recurses by itself.
        #expect(asked == [.local("/a"), .local("/c")])
        #expect(report.accepted == 2)
        #expect(tree.listed.isEmpty)
    }

    @Test(
        "Download Now walks a folder and asks for every placeholder at every depth, and only those"
    )
    func downloadWalks() {
        let tree = FakeCloudTree([
            "/root": [
                Self.entry("/root/here.txt"),
                Self.entry("/root/away.txt", dataless: true),
                Self.entry("/root/link", kind: .symlink),
                Self.entry("/root/sub", kind: .directory)
            ],
            "/root/sub": [
                Self.entry("/root/sub/deep.raw", dataless: true),
                Self.entry("/root/sub/deeper", kind: .directory)
            ],
            "/root/sub/deeper": [Self.entry("/root/sub/deeper/deepest.mov", dataless: true)]
        ])
        var asked: [VFSPath] = []
        let report = CloudLocalCopyRunner.run(
            .download,
            on: [CloudLocalCopyTarget(path: .local("/root"), isDirectory: true, isDataless: false)],
            using: tree
        ) { _, path in asked.append(path) }

        #expect(
            Set(asked) == [
                .local("/root/away.txt"),
                .local("/root/sub/deep.raw"),
                .local("/root/sub/deeper/deepest.mov")
            ]
        )
        #expect(asked.count == 3)
        #expect(report.accepted == 3)
        #expect(!tree.listed.contains(.local("/root/link")))
    }

    @Test("a file already here is not asked about; a placeholder file target is")
    func downloadFileTargets() {
        var asked: [VFSPath] = []
        let report = CloudLocalCopyRunner.run(
            .download,
            on: [
                CloudLocalCopyTarget(path: .local("/here"), isDirectory: false, isDataless: false),
                CloudLocalCopyTarget(path: .local("/away"), isDirectory: false, isDataless: true)
            ],
            using: FakeCloudTree([:])
        ) { _, path in asked.append(path) }
        #expect(asked == [.local("/away")])
        #expect(report == CloudLocalCopyReport(action: .download, accepted: 1))
    }

    @Test("an item nothing manages is counted, a refusal is reported against its path")
    func refusalsSplit() {
        let targets = ["/plain", "/busy", "/pending"].map {
            CloudLocalCopyTarget(path: .local($0), isDirectory: false, isDataless: false)
        }
        let report = CloudLocalCopyRunner.run(
            .removeDownload,
            on: targets,
            using: FakeCloudTree([:])
        ) { _, path in
            switch path.path {
            case "/plain":
                throw Self.error(NSCocoaErrorDomain, 3328, over: Self.error(NSPOSIXErrorDomain, 45))
            case "/busy":
                throw Self.error(NSCocoaErrorDomain, 255, over: Self.error(NSPOSIXErrorDomain, 16))
            default:
                throw Self.error(
                    NSCocoaErrorDomain,
                    512,
                    over: Self.error("NSFileProviderErrorDomain", -2008)
                )
            }
        }
        #expect(report.accepted == 0)
        #expect(report.notCloudItems == 1)
        #expect(report.failures == [
            .init(path: .local("/busy"), refusal: .inUse),
            .init(path: .local("/pending"), refusal: .notYetUploaded)
        ])
    }

    @Test("a folder that cannot be listed is reported and its siblings are still walked")
    func unreadableFolder() {
        let tree = FakeCloudTree([
            "/root": [
                Self.entry("/root/locked", kind: .directory),
                Self.entry("/root/open", kind: .directory)
            ],
            "/root/open": [Self.entry("/root/open/away.txt", dataless: true)]
        ])
        var asked: [VFSPath] = []
        let report = CloudLocalCopyRunner.run(
            .download,
            on: [CloudLocalCopyTarget(path: .local("/root"), isDirectory: true, isDataless: false)],
            using: tree
        ) { _, path in asked.append(path) }
        #expect(asked == [.local("/root/open/away.txt")])
        #expect(report.failures == [.init(path: .local("/root/locked"), refusal: .folderUnreadable)])
    }

    @Test("stopping ends the run where it is and says so")
    func cancellation() {
        let tree = FakeCloudTree([
            "/root": (1...5).map { Self.entry("/root/f\($0)", dataless: true) }
        ])
        var asked = 0
        let report = CloudLocalCopyRunner.run(
            .download,
            on: [CloudLocalCopyTarget(path: .local("/root"), isDirectory: true, isDataless: false)],
            using: tree,
            isCancelled: { asked >= 2 },
            perform: { _, _ in asked += 1 }
        )
        #expect(asked == 2)
        #expect(report.accepted == 2)
        #expect(report.wasCancelled)
    }
}

/// A listing per folder, recording which folders were listed. Anything not in the table throws, which
/// is how a folder that cannot be listed is arranged.
private final class FakeCloudTree: VFSBackend, @unchecked Sendable {
    let id = VFSBackendID("fake-cloud")
    let capabilities: VFSCapabilities = [.read]
    private let listings: [String: [FileEntry]]
    private(set) var listed: [VFSPath] = []

    init(_ listings: [String: [FileEntry]]) {
        self.listings = listings
    }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] {
        listed.append(path)
        guard let entries = listings[path.path] else { throw VFSError.notFound(path) }
        return entries
    }

    func stat(at path: VFSPath) throws -> FileEntry {
        throw VFSError.notFound(path)
    }
}
