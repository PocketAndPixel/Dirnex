import Foundation
import Testing

@testable import DirnexCore

/// The reader against real files. iCloud cannot be a test dependency — no account, no network, no
/// provider on a CI box — so what is pinned here is everything that *is* true of an ordinary
/// filesystem: an ordinary file is not a cloud item, an ordinary directory is not a cloud directory
/// (the gate that keeps the scan off everyone else's folders), and a non-local path refuses to
/// answer rather than guessing. The cloud states themselves are pinned in `CloudSyncStatusTests`
/// from live probes.
@Suite("CloudSyncStorage")
struct CloudSyncStorageTests {
    @Test("an ordinary local file is not a cloud item and so has no status")
    func ordinaryFileIsNotACloudItem() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("plain.txt")
            try "hello".write(to: file, atomically: true, encoding: .utf8)

            let attributes = try CloudSyncStorage.attributes(at: .local(file.path))
            #expect(attributes.isUbiquitous == false)
            #expect(attributes.status == nil)
        }
    }

    @Test("an ordinary directory is not a cloud directory — the gate that skips the whole scan")
    func ordinaryDirectoryIsNotACloudDirectory() throws {
        try withTemporaryDirectory { directory in
            #expect(CloudSyncStorage.isCloudDirectory(.local(directory.path)) == false)
        }
    }

    @Test("a file that does not exist reports nothing rather than throwing")
    func missingFileIsQuiet() {
        // A row can vanish between the listing and the scan; that is a stale snapshot, not an error
        // worth propagating to a badge.
        let attributes = CloudSyncStorage.attributes(forPOSIXPath: "/nonexistent/nowhere.txt")
        #expect(attributes.status == nil)
    }

    @Test("a non-local path refuses to answer instead of claiming it is not a cloud item")
    func remotePathIsUnsupported() {
        let remote = VFSPath(backend: .archive(forArchiveAt: "/tmp/a.zip"), path: "/inner.txt")
        #expect(throws: VFSError.self) {
            try CloudSyncStorage.attributes(at: remote)
        }
        // The directory gate answers `false` for one, though: it is a "should I scan?" question, and
        // the answer for a volume with no provider is simply no.
        #expect(CloudSyncStorage.isCloudDirectory(remote) == false)
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CloudSyncStorageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}
