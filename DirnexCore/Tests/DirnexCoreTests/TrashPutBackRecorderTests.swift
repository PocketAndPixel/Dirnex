import Foundation
import Testing

@testable import DirnexCore

/// Writing the put-back record for an item Dirnex trashed itself (PLAN.md §M26 Slice 5).
///
/// Real files in a real directory, like ``ProviderAwareTrashPerformerTests``: the subject is a
/// database on disk that another process reads, so a fake store would only prove this code agrees
/// with itself. The oracle for *what* is written is ``TrashPutBack/origins(inDSStore:ofTrashAt:)``
/// — the reader that predates this by eighteen milestones and is itself pinned against a `.DS_Store`
/// macOS wrote.
@Suite("Trash put-back recorder")
struct TrashPutBackRecorderTests {
    private static func temporaryTrash() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dnx-m26s5-\(UUID().uuidString)")
            .appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func origins(in trash: URL) throws -> [String: TrashOrigin] {
        let data = try Data(contentsOf: trash.appendingPathComponent(TrashPutBack.storeName))
        return try TrashPutBack.origins(inDSStore: data, ofTrashAt: .local(trash.path))
    }

    private func fixture() throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: "volume-trash",
                withExtension: "dsstore",
                subdirectory: "Fixtures"
            )
        )
        return try Data(contentsOf: url)
    }

    // MARK: - Writing

    /// The state every File Provider trash is in until something is deleted into it: no database at
    /// all. Probed live 2026-08-31 — one created here gave Google Drive's `<mount>/.Trash` a working
    /// Put Back in Finder.
    @Test("a trash with no database gets one")
    func createsAStore() throws {
        let trash = try Self.temporaryTrash()
        let origin = TrashOrigin(directory: .local("/Users/oleg/Documents"), name: "report.pdf")

        #expect(
            TrashPutBackRecorder.record(
                origin,
                forItemAt: trash.appendingPathComponent("report.pdf")
            )
        )

        let recorded = try Self.origins(in: trash)["report.pdf"]
        #expect(recorded?.directory == .local("/Users/oleg/Documents"))
        #expect(recorded?.name == "report.pdf")
    }

    /// The name in the trash and the name to restore under are two different strings whenever a
    /// collision stamped the newcomer, and only `ptbN` still knows the second — restoring under the
    /// trash's name would quietly rename the user's file.
    @Test("a stamped landing name still records the name to restore under")
    func recordsTheOriginalName() throws {
        let trash = try Self.temporaryTrash()
        let origin = TrashOrigin(directory: .local("/Users/oleg/Documents"), name: "report.pdf")

        TrashPutBackRecorder.record(
            origin,
            forItemAt: trash.appendingPathComponent("report.pdf 01-14-42-179.pdf")
        )

        let recorded = try Self.origins(in: trash)["report.pdf 01-14-42-179.pdf"]
        #expect(recorded?.name == "report.pdf")
        #expect(recorded?.destination == .local("/Users/oleg/Documents/report.pdf"))
    }

    @Test("a second item is added beside the first, not instead of it")
    func keepsEarlierRecords() throws {
        let trash = try Self.temporaryTrash()
        let documents = VFSPath.local("/Users/oleg/Documents")

        TrashPutBackRecorder.record(
            TrashOrigin(directory: documents, name: "first.txt"),
            forItemAt: trash.appendingPathComponent("first.txt")
        )
        TrashPutBackRecorder.record(
            TrashOrigin(directory: .local("/Users/oleg/Downloads"), name: "second.txt"),
            forItemAt: trash.appendingPathComponent("second.txt")
        )

        let recorded = try Self.origins(in: trash)
        #expect(recorded["first.txt"]?.directory == documents)
        #expect(recorded["second.txt"]?.directory == .local("/Users/oleg/Downloads"))
    }

    /// The file being rewritten is **Finder's**, holding the put-back records for everything Finder
    /// and `trashItem` ever put there — 142 of them in this Mac's own `~/.Trash`. Losing one item's
    /// Put Back is the bug this slice fixes; losing everybody else's would be a worse one.
    @Test("records the trash already held are all still there afterwards")
    func preservesFindersOwnRecords() throws {
        let trash = try Self.temporaryTrash()
        let store = trash.appendingPathComponent(TrashPutBack.storeName)
        try fixture().write(to: store)
        let before = try DSStoreReader.entries(in: Data(contentsOf: store))

        TrashPutBackRecorder.record(
            TrashOrigin(directory: .local("/Users/oleg/Documents"), name: "new.txt"),
            forItemAt: trash.appendingPathComponent("new.txt")
        )

        let after = try DSStoreReader.entries(in: Data(contentsOf: store))
        #expect(before.allSatisfy { after.contains($0) })
        #expect(after.count == before.count + 2)
    }

    /// A name reused after an earlier item left the Trash must not end up carrying two locations:
    /// which one a reader takes would be undefined, and one of them is wrong.
    @Test("re-using a name replaces its record rather than doubling it")
    func replacesAStaleRecord() throws {
        let trash = try Self.temporaryTrash()
        let landed = trash.appendingPathComponent("notes.txt")

        TrashPutBackRecorder.record(
            TrashOrigin(directory: .local("/Users/oleg/Documents"), name: "notes.txt"),
            forItemAt: landed
        )
        TrashPutBackRecorder.record(
            TrashOrigin(directory: .local("/Users/oleg/Desktop"), name: "notes.txt"),
            forItemAt: landed
        )

        let entries = try DSStoreReader.entries(
            in: Data(contentsOf: trash.appendingPathComponent(TrashPutBack.storeName))
        )
        #expect(entries.count == 2)
        #expect(try Self.origins(in: trash)["notes.txt"]?.directory == .local("/Users/oleg/Desktop"))
    }

    // MARK: - Giving up

    /// A database this build cannot parse is one it must not replace: whatever is in there belongs
    /// to Finder, and an overwrite would throw away every record it holds to add one.
    @Test("a database that cannot be read is left exactly as it was")
    func refusesToOverwriteAnUnreadableStore() throws {
        let trash = try Self.temporaryTrash()
        let store = trash.appendingPathComponent(TrashPutBack.storeName)
        let garbage = Data("Bud1 but not really, and certainly not a B-tree".utf8)
        try garbage.write(to: store)

        let wrote = TrashPutBackRecorder.record(
            TrashOrigin(directory: .local("/Users/oleg/Documents"), name: "x.txt"),
            forItemAt: trash.appendingPathComponent("x.txt")
        )

        #expect(!wrote)
        #expect(try Data(contentsOf: store) == garbage)
    }

    @Test("an origin that cannot be expressed for this trash writes nothing")
    func refusesAnUnrecordableOrigin() throws {
        let trash = try Self.temporaryTrash()

        let wrote = TrashPutBackRecorder.record(
            TrashOrigin(
                directory: VFSPath(
                    backend: .sftp(SFTPLocation(host: "h", username: "u")),
                    path: "/x"
                ),
                name: "x.txt"
            ),
            forItemAt: trash.appendingPathComponent("x.txt")
        )

        #expect(!wrote)
        #expect(
            !FileManager.default.fileExists(
                atPath: trash.appendingPathComponent(TrashPutBack.storeName).path
            )
        )
    }

    /// The hazard no unit of this could otherwise see, and the expensive one: `~/.Trash` is behind
    /// Full Disk Access, so a build without that grant is **refused** the read — and a refusal read
    /// as "no database yet" would replace every put-back record Finder has written there with the
    /// one row this came to add. Only a genuinely absent file may count as absent.
    @Test("a database that cannot be read at all is not mistaken for one that is not there")
    func refusesWhenTheStoreCannotBeRead() throws {
        let trash = try Self.temporaryTrash()
        let store = trash.appendingPathComponent(TrashPutBack.storeName)
        try fixture().write(to: store)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: store.path)
        defer { try? FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: store.path
        ) }

        let wrote = TrashPutBackRecorder.record(
            TrashOrigin(directory: .local("/Users/oleg/Documents"), name: "x.txt"),
            forItemAt: trash.appendingPathComponent("x.txt")
        )

        #expect(!wrote)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.path)
        #expect(try Data(contentsOf: store) == fixture())
    }
}
