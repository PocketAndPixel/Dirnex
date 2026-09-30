import DirnexCore
import Foundation

/// Mints a zip whose entry names are stored in **CP866** with the zip's UTF-8 flag (general-purpose
/// bit 11) **clear** — what Windows tools wrote for years, and the one shape of archive nothing on
/// this Mac can name for itself (PLAN.md §M27).
///
/// It cannot be produced the obvious way, and that is worth stating because the obvious way is what
/// anyone would try first: APFS refuses a file name that is not valid UTF-8 (`EILSEQ`, measured), so
/// there is no file on this disk whose name is those bytes for a packer to read. What there *is* is
/// the zip's own header. Nothing in the format checksums a name, so a member packed under an ASCII
/// placeholder of the **same byte length** can have its name bytes rewritten in place afterwards —
/// in the local header and in the central directory — with no offset moving and no CRC to repair.
///
/// **The name bytes are written by hand and the container is not**, which is the split
/// docs/NOTES.md asks for: what these fixtures are aimed at is the *reader*, so the bytes it reads
/// are minted here rather than produced by anything that also reads them, while the archive around
/// them — including AES-256 encryption, which nothing else on this Mac can write — comes through the
/// type's own writer, as scaffolding should.
///
/// The other suites carry a 218-byte hand-minted blob instead, and they should: a constant is a
/// better oracle than a builder for the case it covers. This exists for the three cases a constant
/// cannot reach — an archive that is encrypted *and* legacy, one holding a nested archive under a
/// code-page name, and one whose members a test needs to choose. `LegacyNameZipFixtureTests` is what
/// makes it trustworthy, by asserting it reproduces that blob's properties exactly.
enum LegacyNameZip {
    /// One member: the name somebody typed, and the bytes behind it.
    struct Member {
        /// The **real** name — `Панорама.txt`, not its CP866 bytes. An all-ASCII name is stored as
        /// itself and never patched, which is what lets a fixture carry a readable row beside an
        /// unreadable one.
        let name: String
        let contents: Data

        static func text(_ name: String, _ contents: String) -> Member {
            Member(name: name, contents: Data(contents.utf8))
        }
    }

    enum FixtureError: Error {
        /// The name has no CP866 spelling, so this builder cannot express it.
        case notRepresentableInCP866(String)
        /// The patch found the wrong number of headers — a fixture that silently kept its
        /// placeholder would make every test built on it pass for the wrong reason.
        case patchDidNotApply(name: String, local: Int, central: Int)
    }

    /// CP866, spelled through CoreFoundation because Foundation's `String.Encoding` has no case for
    /// it. Deliberately *not* the same mechanism libarchive uses to read these names back: the
    /// fixture is written by one decoder and read by another, which is what stops a builder and a
    /// reader agreeing with each other about something neither has right.
    static let cp866 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.dosRussian.rawValue)
    ))

    /// Write `members` to `path`, storing every non-ASCII name as its CP866 bytes with the UTF-8
    /// flag clear.
    ///
    /// - Parameters:
    ///   - encryption: `.aes256` produces an archive that is encrypted *and* legacy, which is the
    ///     combination no other fixture in this repo can be.
    ///   - passphrase: Required when `encryption` is not `.none`, exactly as the writer requires.
    static func write(
        _ members: [Member],
        to path: String,
        encryption: ArchiveEncryption = .none,
        passphrase: ArchivePassphrase? = nil
    ) throws {
        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("legacy_name_zip_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        // What each member is called on disk while the archive is being packed, and what its name
        // has to become afterwards. An ASCII member needs neither.
        var onDiskNames: [String] = []
        var patches: [Patch] = []
        for (index, member) in members.enumerated() {
            let onDiskName: String
            if member.name.allSatisfy(\.isASCII) {
                onDiskName = member.name
            } else {
                guard let encoded = member.name.data(using: cp866) else {
                    throw FixtureError.notRepresentableInCP866(member.name)
                }
                onDiskName = placeholder(index: index, byteLength: encoded.count)
                patches.append(
                    Patch(placeholder: onDiskName, raw: [UInt8](encoded), name: member.name)
                )
            }
            try member.contents.write(to: staging.appendingPathComponent(onDiskName))
            onDiskNames.append(onDiskName)
        }

        try EncryptedArchiveWriter.write(
            items: try ArchiveSourceEnumerator.items(
                inDirectory: staging.path, names: onDiskNames
            ),
            toArchiveAt: path,
            encryption: encryption,
            passphrase: passphrase
        )

        var bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        for patch in patches {
            let applied = rewriteName(
                in: &bytes, from: patch.placeholder, to: patch.raw
            )
            guard applied == (local: 1, central: 1) else {
                throw FixtureError.patchDidNotApply(
                    name: patch.name, local: applied.local, central: applied.central
                )
            }
        }
        try Data(bytes).write(to: URL(fileURLWithPath: path))
    }

    /// One member's name, waiting to be written over the placeholder it was packed under. A named
    /// value rather than a tuple, which SwiftLint caps at two members.
    private struct Patch {
        let placeholder: String
        let raw: [UInt8]
        let name: String
    }

    /// An ASCII name of exactly `byteLength` bytes, unique to `index` so two members of the same
    /// length cannot be patched into each other.
    private static func placeholder(index: Int, byteLength: Int) -> String {
        let tag = "\(index)"
        return tag + String(repeating: "A", count: max(0, byteLength - tag.count))
    }

    /// Replace every stored occurrence of `placeholder` with `raw` and clear general-purpose bit 11,
    /// returning how many headers of each kind were touched.
    ///
    /// The flag is cleared rather than assumed clear, and measured 2026-09-09 it is already clear
    /// here: libarchive sets bit 11 only for a name that *needs* UTF-8, and every placeholder is
    /// ASCII. Doing it anyway is what keeps this builder honest about what it claims to produce
    /// rather than about what one writer happens to do today — and the fixture's own test asserts
    /// the finished archive, not this line.
    private static func rewriteName(
        in bytes: inout [UInt8], from placeholder: String, to raw: [UInt8]
    ) -> (local: Int, central: Int) {
        let localSignature: [UInt8] = [0x50, 0x4B, 0x03, 0x04] // "PK\u{03}\u{04}"
        let centralSignature: [UInt8] = [0x50, 0x4B, 0x01, 0x02] // "PK\u{01}\u{02}"
        var local = 0
        var central = 0
        var index = 0
        while index + 4 <= bytes.count {
            let signature = Array(bytes[index..<index + 4])
            let isCentral = signature == centralSignature
            guard isCentral || signature == localSignature else {
                index += 1
                continue
            }
            // A central-directory header is 46 bytes with its name length at +28; a local one is 30
            // with its name length at +26. The flags sit at +8 and +6 respectively.
            let headerLength = isCentral ? 46 : 30
            let nameLengthOffset = index + (isCentral ? 28 : 26)
            guard nameLengthOffset + 2 <= bytes.count else { break }
            let nameLength = Int(bytes[nameLengthOffset])
                | (Int(bytes[nameLengthOffset + 1]) << 8)
            let nameStart = index + headerLength
            guard nameStart + nameLength <= bytes.count else { break }
            if String(bytes: bytes[nameStart..<nameStart + nameLength], encoding: .utf8)
                == placeholder, nameLength == raw.count {
                for (offset, byte) in raw.enumerated() { bytes[nameStart + offset] = byte }
                bytes[index + (isCentral ? 8 : 6) + 1] &= ~0x08 // general-purpose bit 11
                if isCentral { central += 1 } else { local += 1 }
            }
            index += 4
        }
        return (local, central)
    }
}
