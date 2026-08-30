import Foundation
import Testing

@testable import DirnexCore

/// The shipping ``TrashPerformer`` (PLAN.md §M26 Slice 2).
///
/// The move itself runs for real, against a temp directory standing in for a Trash — `renamex_np`
/// is the thing under test and a fake cannot refuse a collision the way the filesystem does. What
/// is *not* exercised here is the provider domain itself, which no fixture can create: that half
/// was measured live against all five live domains and is recorded on the type.
@Suite("Provider-aware trash performer")
struct ProviderAwareTrashPerformerTests {
    private static func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dnx-m26-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private static func file(_ url: URL, _ contents: String) -> URL {
        FileManager.default.createFile(atPath: url.path, contents: Data(contents.utf8))
        return url
    }

    /// Answers however the test told it to, and records that it was asked.
    private final class SpyOrdinary: TrashPerformer, @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [URL] = []
        var urls: [URL] { lock.withLock { asked } }

        func moveToTrash(_ url: URL) throws -> URL? {
            lock.withLock { asked.append(url) }
            return url
        }
    }

    // MARK: - The move

    @Test("an item lands in the trash under its own name")
    func landsUnderItsOwnName() throws {
        let root = try Self.temporaryDirectory()
        let trash = root.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let source = Self.file(root.appendingPathComponent("report.pdf"), "a")

        let landed = try ProviderAwareTrashPerformer.moveIntoTrash(source, trashDirectory: trash)

        #expect(landed == trash.appendingPathComponent("report.pdf"))
        #expect(try String(contentsOf: landed, encoding: .utf8) == "a")
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    /// The reason the primitive is `renamex_np` and not `rename`: a plain rename replaces its
    /// destination silently, so the second delete of a same-named file would **destroy the copy the
    /// user had already thrown away**. The assertion that matters is the survivor's contents, not
    /// merely that two files exist.
    @Test("a name already in the trash is stamped, and the item already there is untouched")
    func aCollisionNeverOverwrites() throws {
        let root = try Self.temporaryDirectory()
        let trash = root.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        Self.file(trash.appendingPathComponent("report.pdf"), "already thrown away")
        let source = Self.file(root.appendingPathComponent("report.pdf"), "the new one")

        let landed = try ProviderAwareTrashPerformer.moveIntoTrash(source, trashDirectory: trash)

        #expect(landed.lastPathComponent != "report.pdf")
        #expect(landed.lastPathComponent.hasPrefix("report.pdf "))
        #expect(landed.pathExtension == "pdf")
        #expect(try String(contentsOf: landed, encoding: .utf8) == "the new one")
        let survivor = trash.appendingPathComponent("report.pdf")
        #expect(try String(contentsOf: survivor, encoding: .utf8) == "already thrown away")
    }

    /// Every candidate taken is a failure, not a silent overwrite. Reached here by freezing the
    /// clock so all eight stamped names are the same one — which is also the case the fresh-stamp
    /// loop exists to avoid in the first place.
    @Test("an item that cannot be placed reports the errno rather than overwriting")
    func exhaustedCandidatesThrow() throws {
        let root = try Self.temporaryDirectory()
        let trash = root.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let frozen = Date(timeIntervalSince1970: 1_788_206_645.017)
        let stamped = TrashLanding.collisionName(
            for: "report.pdf", stamp: TrashLanding.stamp(for: frozen)
        )
        Self.file(trash.appendingPathComponent("report.pdf"), "x")
        Self.file(trash.appendingPathComponent(stamped), "y")
        let source = Self.file(root.appendingPathComponent("report.pdf"), "the new one")

        #expect(throws: (any Error).self) {
            try ProviderAwareTrashPerformer.moveIntoTrash(
                source, trashDirectory: trash, now: { frozen }
            )
        }
        // The source is still there — a delete that could not place the item has not lost it.
        #expect(try String(contentsOf: source, encoding: .utf8) == "the new one")
    }

    /// A failure that is *not* a collision must surface immediately, carrying an errno the shared
    /// mapper can read, rather than spending eight attempts on a name that was never the problem.
    @Test("a missing trash directory fails as a mapped errno, not as a collision")
    func aMissingTrashDirectoryFails() throws {
        let root = try Self.temporaryDirectory()
        let source = Self.file(root.appendingPathComponent("report.pdf"), "a")
        let absent = root.appendingPathComponent("no-such-trash")

        let error = #expect(throws: NSError.self) {
            try ProviderAwareTrashPerformer.moveIntoTrash(source, trashDirectory: absent)
        }
        let underlying = try #require(
            error?.userInfo[NSUnderlyingErrorKey] as? NSError
        )
        #expect(underlying.domain == NSPOSIXErrorDomain)
        #expect(underlying.code == Int(ENOENT))
        // `LocalBackend` reads that errno back out rather than reporting a Cocoa code nobody can
        // look up — the ordering `mapCocoaError` already relies on.
        let mapped = LocalBackend.trashFailure(try #require(error), path: .local(source.path))
        #expect(mapped == .notFound(.local(source.path)))
    }

    // MARK: - Where it lands

    /// The verification half. Box and OneDrive both have the lookup name a `<mount>/.Trash` that is
    /// not there and never will be, so a candidate that is not already a directory is discarded —
    /// creating it would put a folder inside somebody's cloud account that then syncs.
    @Test("a trash directory that is named but absent is discarded for the fallback")
    func anAbsentCandidateFallsBack() throws {
        let root = try Self.temporaryDirectory()
        let present = root.appendingPathComponent("Present")
        try FileManager.default.createDirectory(at: present, withIntermediateDirectories: true)
        let absent = root.appendingPathComponent("Absent")
        let fallback = root.appendingPathComponent("Fallback")

        #expect(ProviderAwareTrashPerformer.trashDirectory(preferring: present, fallback: fallback)
            == present)
        #expect(ProviderAwareTrashPerformer.trashDirectory(preferring: absent, fallback: fallback)
            == fallback)
        #expect(ProviderAwareTrashPerformer.trashDirectory(preferring: nil, fallback: fallback)
            == fallback)
    }

    /// A *file* where a trash directory was named is not a trash directory — renaming into it would
    /// fail, and the fallback is a working answer.
    @Test("a candidate that is a file is discarded for the fallback")
    func aFileCandidateFallsBack() throws {
        let root = try Self.temporaryDirectory()
        let notADirectory = Self.file(root.appendingPathComponent(".Trash"), "")
        let fallback = root.appendingPathComponent("Fallback")

        #expect(ProviderAwareTrashPerformer
            .trashDirectory(preferring: notADirectory, fallback: fallback) == fallback)
    }

    // MARK: - Which route

    /// The distinction `try?` erases, and the reason the read is a `do`/`catch`.
    ///
    /// A real file whose ubiquity read **succeeds with the key absent** — every ordinary file, and
    /// every mirror-mode Google Drive file, whose `<mount>/My Drive` is a symlink out to `~/My
    /// Drive` — is authoritatively not in a domain, even though its *path* sits under a provider
    /// root. Flattening that into the same `nil` a failed read produces sends it down the provider
    /// route and takes Finder's Put Back away from it for no reason. Caught by SwiftLint rather than
    /// by a test, which is why there is now a test.
    @Test("a real file under a provider root whose ubiquity read answers nothing stays ordinary")
    func anAbsentUbiquityKeyIsAuthoritative() throws {
        let home = try Self.temporaryDirectory()
        let mount = home.appendingPathComponent("Library/CloudStorage/GoogleDrive-a@b.com/My Drive")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let source = Self.file(mount.appendingPathComponent("report.pdf"), "a")

        #expect(!ProviderAwareTrashPerformer.isProviderItem(source, home: home.path))
        // The control: had the read given no answer at all, that same path *would* route as a
        // provider item — so the assertion above is about the read, not about the path.
        #expect(TrashLanding.isProviderItem(
            isUbiquitous: nil, path: source.path, home: home.path
        ))
    }

    /// The narrowness control for the whole milestone: an ordinary local item must still go through
    /// `FileManager.trashItem`, or the fix quietly becomes "nothing in this app has Put Back any
    /// more" — a regression on the case that never had the bug.
    @Test("an ordinary local item is still handed to the platform's own trashItem")
    func anOrdinaryItemTakesTheOrdinaryRoute() throws {
        let root = try Self.temporaryDirectory()
        let source = Self.file(root.appendingPathComponent("report.pdf"), "a")
        let spy = SpyOrdinary()

        let landed = try ProviderAwareTrashPerformer(ordinary: spy).moveToTrash(source)

        #expect(spy.urls == [source])
        #expect(landed == source)
        // The performer did not move it itself.
        #expect(FileManager.default.fileExists(atPath: source.path))
    }
}
