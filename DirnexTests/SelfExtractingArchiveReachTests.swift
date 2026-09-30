import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A Windows self-extractor browsed as an archive, through the app's own mount, extractor, gates and
/// writer (``DirnexCore/SelfExtractingArchive``).
///
/// Reported 2026-09-21: a 7zSFX installer renamed to `.zip` — Total Commander opens it, Dirnex said
/// "Couldn’t read the archive". `bsdtar` refuses it because libarchive looks for an appended 7z only
/// from `0x27000`, and these modules' archives start below that; the in-process reader opens it
/// through a window instead. The half of the claim that is new *risk* rather than new reach is the
/// read-only rule: a rewrite repacks the archive alone, so writing into one would put a bare
/// archive where the program was — and with a `.zip` name, `bsdtar -a` would even make it a zip.
@Suite("Self-extracting archives")
struct SelfExtractingArchiveReachTests {
    // MARK: - Reading

    @Test("a 7z self-extractor named .zip lists through the pane's own mount")
    func sevenZipSelfExtractorLists() throws {
        let fixture = try Fixture(payload: .sevenZip)
        defer { fixture.cleanup() }
        let composite = CompositeBackend(local: LocalBackend())

        let names = try composite.listDirectory(at: fixture.root).map(\.name).sorted()

        #expect(names == ["docs", "one.txt"])
        #expect(composite.mountedArchiveIsSelfExtracting(forArchiveAt: fixture.archive))
    }

    @Test("a member extracts through the route F5, ⏎ and the preview share, with its bytes")
    func sevenZipSelfExtractorExtracts() throws {
        let fixture = try Fixture(payload: .sevenZip)
        defer { fixture.cleanup() }

        let extraction = try ArchiveExtractor.extract(
            innerPaths: ["/docs/deep.txt"], fromArchiveAt: fixture.archive
        )
        defer { try? FileManager.default.removeItem(at: extraction.directory) }

        #expect(try String(contentsOfFile: extraction.extractedPaths[0], encoding: .utf8) == "deep")
    }

    /// Narrowness: a zip behind a stub always listed through `bsdtar`, and still does — only its
    /// write gates change.
    @Test("a zip self-extractor keeps listing, and is recorded as one")
    func zipSelfExtractorLists() throws {
        let fixture = try Fixture(payload: .zip)
        defer { fixture.cleanup() }
        let composite = CompositeBackend(local: LocalBackend())

        let names = try composite.listDirectory(at: fixture.root).map(\.name).sorted()

        #expect(names == ["docs", "one.txt"])
        #expect(composite.mountedArchiveIsSelfExtracting(forArchiveAt: fixture.archive))
    }

    // MARK: - Read-only

    @MainActor
    @Test("every write gate refuses a self-extractor", arguments: SelfExtractingPayload.allCases)
    func writeGatesRefuse(_ payload: SelfExtractingPayload) throws {
        let fixture = try Fixture(payload: payload)
        defer { fixture.cleanup() }
        let pane = try mountedPane(at: fixture)
        let member = try #require(
            try pane.backend.listDirectory(at: fixture.root).first { $0.name == "one.txt" }
        )

        #expect(!pane.isWritableArchive)
        #expect(!pane.isWritableArchiveMember(member))
        #expect(pane.renameRoute(for: member.path) == .unavailable)
    }

    /// The control that keeps "a self-extractor is read-only" from being "an archive is read-only".
    @MainActor
    @Test("an ordinary archive stays writable")
    func ordinaryArchiveStaysWritable() throws {
        let fixture = try Fixture(payload: .zip, withStub: false)
        defer { fixture.cleanup() }
        let pane = try mountedPane(at: fixture)
        let member = try #require(
            try pane.backend.listDirectory(at: fixture.root).first { $0.name == "one.txt" }
        )

        #expect(pane.isWritableArchive)
        #expect(pane.isWritableArchiveMember(member))
        #expect(
            pane.renameRoute(for: member.path) == .archiveMember(archiveOnDiskPath: fixture.archive)
        )
    }

    @Test(
        "the writer refuses a self-extractor and leaves every byte of it",
        arguments: SelfExtractingPayload.allCases
    )
    func writerRefuses(_ payload: SelfExtractingPayload) throws {
        let fixture = try Fixture(payload: payload)
        defer { fixture.cleanup() }
        let before = try Data(contentsOf: URL(fileURLWithPath: fixture.archive))

        #expect(
            throws: VFSError.unsupported(
                .selfExtractingArchiveReadOnly(
                    archive: (fixture.archive as NSString).lastPathComponent
                )
            )
        ) {
            try ArchiveWriter.rename(
                innerPath: "/one.txt", to: "renamed.txt",
                inArchiveAt: fixture.archive, undo: fixture.undo
            )
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.archive)) == before)
    }

    // MARK: - Fixture

    @MainActor
    private func mountedPane(at fixture: Fixture) throws -> PanelViewController {
        let pane = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: fixture.root,
            restorationKey: nil
        )
        pane.host = StubPanelHost()
        // The gates peek at the mount rather than reading the file, so mount it the way entering
        // the archive would.
        _ = try pane.backend.listDirectory(at: fixture.root)
        return pane
    }

    struct Fixture {
        let directory: URL
        /// Named `.zip` whatever it holds, the way the reported installer was.
        let archive: String
        let undo: ArchiveUndoStorage.Request

        var root: VFSPath { VFSPath(backend: .archive(forArchiveAt: archive), path: "/") }

        init(payload: SelfExtractingPayload, withStub: Bool = true) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("SelfExtracting-\(UUID().uuidString)")
            let source = directory.appendingPathComponent("source", isDirectory: true)
            let docs = source.appendingPathComponent("docs", isDirectory: true)
            try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
            try "first".write(
                to: source.appendingPathComponent("one.txt"),
                atomically: true,
                encoding: .utf8
            )
            try "deep".write(
                to: docs.appendingPathComponent("deep.txt"),
                atomically: true,
                encoding: .utf8
            )

            let packed = directory.appendingPathComponent(
                payload == .sevenZip ? "payload.7z" : "payload.zip"
            )
            try Self.bsdtar([
                "-c", "-f", packed.path, "--format", payload == .sevenZip ? "7zip" : "zip",
                "-C", source.path, "one.txt", "docs"
            ])

            archive = directory.appendingPathComponent("installer-Win10.zip").path
            var file = Data()
            if withStub {
                file = Self.programStub() + Data(";!@Install@!UTF-8!\n;!@InstallEnd@!".utf8)
            }
            try (file + Data(contentsOf: packed)).write(to: URL(fileURLWithPath: archive))
            undo = ArchiveUndoStorage.Request(
                store: ArchiveUndoStore(
                    root: directory.appendingPathComponent("undo-store", isDirectory: true)
                ),
                live: []
            )
        }

        func cleanup() { try? FileManager.default.removeItem(at: directory) }

        /// A minimal PE image — a DOS header pointing at a PE header with one 4 KB section — far
        /// smaller than the `0x27000` where libarchive starts looking for an appended 7z.
        static func programStub() -> Data {
            func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
                withUnsafeBytes(of: value.littleEndian) { Data($0) }
            }
            var image = Data(count: 64)
            image[0] = 0x4D
            image[1] = 0x5A
            image.replaceSubrange(0x3C..<0x40, with: littleEndian(UInt32(0x40)))
            image.append(contentsOf: [0x50, 0x45, 0, 0])
            image.append(littleEndian(UInt16(0x014C)) + littleEndian(UInt16(1)) + Data(count: 12))
            image.append(littleEndian(UInt16(224)) + littleEndian(UInt16(0x0102)) + Data(count: 224))
            image.append(Data(".text".utf8) + Data(count: 3))
            image.append(littleEndian(UInt32(0x1000)) + littleEndian(UInt32(0x1000)))
            image.append(
                littleEndian(UInt32(0x1000)) + littleEndian(UInt32(0x200)) + Data(count: 16)
            )
            image.append(Data(count: 0x1200 - image.count))
            return image
        }

        private static func bsdtar(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0, "bsdtar \(arguments) failed")
        }
    }
}

/// What a self-extractor fixture carries after its stub.
enum SelfExtractingPayload: CaseIterable, CustomTestStringConvertible {
    case sevenZip, zip

    var testDescription: String { self == .sevenZip ? "7z" : "zip" }
}
