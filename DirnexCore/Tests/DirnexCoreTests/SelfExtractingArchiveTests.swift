import Foundation
import Testing

@testable import DirnexCore

/// Finding the 7z a Windows self-extractor carries, and reading it in place.
///
/// The reported file was a 7zSFX installer renamed to `.zip`: `bsdtar` refused it as an
/// unrecognized format because libarchive looks for an appended 7z only between `0x27000` and
/// `0x60000`, and that module's archive starts at `0x1EC47`. Every fixture here puts its archive
/// below that window, which is what makes the reader tests evidence about the window rather than
/// about libarchive's own search.
@Suite("SelfExtractingArchive")
struct SelfExtractingArchiveTests {
    private typealias Fixture = WindowsProgramFixture

    /// libarchive's own search for an appended 7z starts here (`SFX_MIN_ADDR`).
    private static let libarchiveSearchStart = 0x27000

    private func inspect(_ data: Data) -> SelfExtractingArchive? {
        SelfExtractingArchive.inspect(fileSize: Int64(data.count)) { offset, length in
            let start = Int(offset)
            guard start <= data.count else { return nil }
            return data.subdata(in: start..<min(start + length, data.count))
        }
    }

    // MARK: - Finding the archive

    @Test("a 7z behind a stub and its configuration is found where it starts")
    func findsTheArchiveAfterTheConfiguration() throws {
        let stub = Fixture.stub()
        let file = Fixture.selfExtractor(stub: stub, payload: try Fixture.sevenZip())
        let found = try #require(inspect(file))

        #expect(found.imageEnd == Int64(stub.count))
        #expect(found.sevenZipOffset == Int64(stub.count + Fixture.configuration.utf8.count))
        // The shape the report was about: an archive libarchive's own search starts after.
        #expect(stub.count + Fixture.configuration.utf8.count < Self.libarchiveSearchStart)
    }

    @Test("a 7z appended directly at the end of the image is found there")
    func findsTheArchiveAtTheImageEnd() throws {
        let stub = Fixture.stub()
        let found = try #require(
            inspect(
                Fixture.selfExtractor(stub: stub, configuration: "", payload: try Fixture.sevenZip())
            )
        )
        #expect(found.sevenZipOffset == Int64(stub.count))
    }

    @Test("a zip appended to a program is a program with no 7z, left to libarchive")
    func zipPayloadIsNotASevenZip() throws {
        let zip = try Data(
            contentsOf: URL(fileURLWithPath: EncryptedArchiveFixture.archive("plain-bsdtar"))
        )
        let stub = Fixture.stub()
        let found = try #require(
            inspect(Fixture.selfExtractor(stub: stub, configuration: "", payload: zip))
        )

        #expect(found.imageEnd == Int64(stub.count))
        #expect(found.sevenZipOffset == nil)
    }

    @Test("an archive that is not a program is not one — whichever format it is")
    func plainArchivesAreNotPrograms() throws {
        #expect(inspect(try Fixture.sevenZip()) == nil)
        let zip = try Data(
            contentsOf: URL(fileURLWithPath: EncryptedArchiveFixture.archive("plain-bsdtar"))
        )
        #expect(inspect(zip) == nil)
    }

    @Test("a program with nothing appended is not a self-extractor")
    func bareProgramIsNotOne() {
        #expect(inspect(Fixture.stub()) == nil)
    }

    // MARK: - Verifying it

    @Test("a signature whose start header fails its CRC is stepped over, and the real one found")
    func decoySignatureIsSteppedOver() throws {
        // A header only the CRC can reject: the signature, then a next header at offset 0 of size 1
        // — inside the file, so the bound passes it — under a checksum that does not match. Garbage
        // after the signature is not enough, measured: its fields point past the end of any file and
        // the bound rejects them first, so the test passed with the CRC check deleted.
        var decoy = Data(SevenZipStartHeader.signature) + Data([0, 4])
        decoy.append(Fixture.littleEndian(UInt32(0xDEAD_BEEF)))
        decoy.append(Fixture.littleEndian(UInt64(0)))
        decoy.append(Fixture.littleEndian(UInt64(1)))
        decoy.append(Fixture.littleEndian(UInt32(0)))
        let stub = Fixture.stub()
        let payload = try Fixture.sevenZip()
        let file = stub + decoy + payload
        let found = try #require(inspect(file))

        #expect(found.sevenZipOffset == Int64(stub.count + decoy.count))
    }

    @Test("an archive whose start header fails its CRC is not reported at all")
    func corruptStartHeaderIsRefused() throws {
        var payload = try Fixture.sevenZip()
        payload[8] ^= 0xFF // the stored CRC
        let found = try #require(inspect(Fixture.selfExtractor(payload: payload)))
        #expect(found.sevenZipOffset == nil)
    }

    @Test("a start header pointing past the end of the file — a truncated download — is refused")
    func truncatedArchiveIsRefused() throws {
        let payload = try Fixture.sevenZip()
        let file = Fixture.selfExtractor(payload: payload.prefix(payload.count - 1))
        let found = try #require(inspect(file))
        #expect(found.sevenZipOffset == nil)
    }

    @Test("an archive further past the image than the scan reaches is not looked for")
    func scanIsBounded() throws {
        let padding = String(repeating: " ", count: SelfExtractingArchive.scanLimit + 1)
        let found = try #require(
            inspect(Fixture.selfExtractor(configuration: padding, payload: try Fixture.sevenZip()))
        )
        #expect(found.sevenZipOffset == nil)
    }

    // MARK: - Malformed programs

    @Test(
        "a malformed program answers nil rather than trapping",
        arguments: MalformedProgram.allCases
    )
    func malformedProgram(_ shape: MalformedProgram) throws {
        let file = shape.bytes(appending: try Fixture.sevenZip())
        #expect(inspect(file) == nil)
    }

    enum MalformedProgram: CaseIterable, CustomTestStringConvertible {
        case peHeaderPastTheEnd, missingPESignature, noSections, tooManySections
        case truncatedSectionTable, imageRunsPastTheFile

        var testDescription: String { "\(self)" }

        func bytes(appending payload: Data) -> Data {
            var stub = WindowsProgramFixture.stub()
            switch self {
            case .peHeaderPastTheEnd:
                stub.replaceSubrange(
                    0x3C..<0x40,
                    with: WindowsProgramFixture.littleEndian(UInt32.max)
                )
            case .missingPESignature:
                stub[0x40] = 0x4E
            case .noSections:
                stub.replaceSubrange(
                    0x46..<0x48,
                    with: WindowsProgramFixture.littleEndian(UInt16(0))
                )
            case .tooManySections:
                stub.replaceSubrange(
                    0x46..<0x48,
                    with: WindowsProgramFixture.littleEndian(UInt16(97))
                )
            case .truncatedSectionTable:
                return stub.prefix(0x40 + 24 + 224 + 20)
            case .imageRunsPastTheFile:
                // The second section's size of raw data, grown past anything the file holds —
                // what a program cut short in transfer looks like.
                let sizeOfRawData = 0x40 + 24 + 224 + 40 + 16
                stub.replaceSubrange(
                    sizeOfRawData..<sizeOfRawData + 4,
                    with: WindowsProgramFixture.littleEndian(UInt32(0x7FFF_0000))
                )
            }
            return stub + payload
        }
    }

    // MARK: - Reading it in place

    /// The self-extractor on disk, in its own scratch directory, named the way the report's was.
    private func selfExtractorOnDisk() throws -> (path: String, directory: String) {
        let directory = try EncryptedArchiveFixture.scratchDirectory()
        let file = Fixture.selfExtractor(payload: try Fixture.sevenZip())
        return (try Fixture.write(file, named: "installer-Win10.zip", in: directory), directory)
    }

    @Test("the reader lists a self-extractor's 7z through the window")
    func readerListsThroughTheWindow() throws {
        let (path, directory) = try selfExtractorOnDisk()
        defer { EncryptedArchiveFixture.remove(directory) }

        let inspection = try EncryptedArchiveReader.inspect(archiveAt: path)
        #expect(inspection.entries.map(\.archivePath).sorted() == [
            "link.txt", "notes/", "notes/hello.txt", "notes/nested/", "notes/nested/deep.txt"
        ])
        #expect(!inspection.needsPassphrase)
        #expect(try !EncryptedArchiveReader.holdsEncryptedEntries(archiveAt: path))
    }

    @Test("the reader extracts one member of a self-extractor, and only that one")
    func readerExtractsThroughTheWindow() throws {
        let (path, directory) = try selfExtractorOnDisk()
        defer { EncryptedArchiveFixture.remove(directory) }
        let destination = (directory as NSString).appendingPathComponent("out")
        try FileManager.default.createDirectory(
            atPath: destination,
            withIntermediateDirectories: true
        )

        let report = try EncryptedArchiveReader.extract(
            archiveAt: path, into: destination, passphrase: nil,
            members: .members(["notes/nested/deep.txt"])
        )

        #expect(report.refused.isEmpty)
        #expect(try EncryptedArchiveFixture.contents(of: destination + "/notes/nested/deep.txt")
            == "deep bytes\n")
        #expect(!EncryptedArchiveFixture.exists(destination + "/notes/hello.txt"))
    }

    /// The negative control: the same bytes with the program's `MZ` broken are not a program, so
    /// they are opened by name — and libarchive cannot find the archive in them. That is what says
    /// the listing above came through the window rather than through libarchive's own search.
    @Test("without the window, the same bytes are unreadable")
    func withoutTheWindowTheArchiveIsUnreadable() throws {
        let directory = try EncryptedArchiveFixture.scratchDirectory()
        defer { EncryptedArchiveFixture.remove(directory) }
        var file = Fixture.selfExtractor(payload: try Fixture.sevenZip())
        file[0] = 0x58 // "XZ", not "MZ"
        let path = try Fixture.write(file, named: "not-a-program.zip", in: directory)

        #expect(SelfExtractingArchive.inspect(fileAt: path) == nil)
        #expect(throws: EncryptedArchiveError.archiveUnreadable) {
            try EncryptedArchiveReader.inspect(archiveAt: path)
        }
    }

    @Test("the file inspection agrees with the in-memory one")
    func fileInspection() throws {
        let (path, directory) = try selfExtractorOnDisk()
        defer { EncryptedArchiveFixture.remove(directory) }
        let file = try Data(contentsOf: URL(fileURLWithPath: path))

        #expect(SelfExtractingArchive.inspect(fileAt: path) == inspect(file))
        #expect(SelfExtractingArchive.inspect(fileAt: path)?.sevenZipOffset != nil)
    }
}
