import Foundation

/// A Windows program with an archive appended to it — a self-extracting archive, or SFX.
///
/// An SFX builder writes a small unpacker, then (for the common 7-Zip SFX modules) a few lines of
/// configuration, then an ordinary archive, into one file. Total Commander opens one with
/// Ctrl+PgDn whatever it is called, and people routinely rename an installer to `.zip` to get it
/// past a mail filter — which is how one reached Dirnex as `…-Win10.zip` and failed with
/// "Couldn’t read the archive" (reported 2026-09-21).
///
/// **A zip appended to a program already works; a 7z appended to a small one does not, and the
/// reason is a fixed search window in libarchive.** Measured against libarchive 3.7.4: `bsdtar -tvf`
/// lists a zip SFX perfectly (the zip reader works back from the end of the file), and lists a 7z SFX
/// whose archive starts at `0x28000` — but not one whose archive starts at `0x1EC47`, because the 7z
/// reader looks for its signature inside a PE only between `0x27000` and `0x60000`. The 7zSFX
/// modules installers are built with are around 120 KB, so their archives always start below that
/// window. The archive itself is fine: cut the 126 KB stub off the reported file and `bsdtar` lists
/// it at once.
///
/// **`bsdtar` cannot be handed the archive in place.** A 7z has to be seekable (piped in, `bsdtar`
/// answers "A file descriptor(0) is not seekable"), and a descriptor already positioned at the
/// archive does not help, because libarchive seeks it to absolute offsets and reads the stub
/// ("Unexpected Property ID"). So an archive found here is read in-process, through
/// ``EncryptedArchiveReader``, with a window that starts where it does — measured on the reported
/// file, 3 reads to list six entries and a member byte-identical to `bsdtar`'s own extraction of the
/// cut-out archive.
///
/// Only a 7z is looked for, because it is the one format with this gap. Anything else appended — a
/// zip, or the code-signing certificate every signed program carries — reads as
/// ``sevenZipOffset`` `nil`, and a file that is not a program at all reads as `nil` after one small
/// read of its first bytes.
public struct SelfExtractingArchive: Sendable, Equatable {
    /// The first byte past the program's own image: the end of its last section, where everything a
    /// builder appends begins (the PE "overlay").
    public let imageEnd: Int64

    /// Where an appended 7z archive begins, when one is there and its start header verifies.
    public let sevenZipOffset: Int64?

    public init(imageEnd: Int64, sevenZipOffset: Int64?) {
        self.imageEnd = imageEnd
        self.sevenZipOffset = sevenZipOffset
    }

    /// How far past the program's image the 7z signature is looked for.
    ///
    /// The 7zSFX modules put their configuration there — 71 bytes on the reported file — and
    /// 7-Zip's own modules append the archive directly, so a megabyte is generous. It bounds the
    /// only read here that is more than a few hundred bytes.
    public static let scanLimit = 1 << 20

    /// Inspect the file at `path`, or `nil` when it is not a Windows program with something appended.
    ///
    /// **This reads the file, so it belongs where the file's bytes are about to be read anyway** — a
    /// mount, an extraction, a rewrite — and never in a menu validator. A file that is not a program
    /// costs one `pread` of 64 bytes.
    public static func inspect(fileAt path: String) -> SelfExtractingArchive? {
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return nil }
        return inspect(fileSize: Int64(status.st_size)) { offset, length in
            var data = Data(count: length)
            let got = data.withUnsafeMutableBytes { bytes in
                pread(descriptor, bytes.baseAddress, length, off_t(offset))
            }
            return got < 0 ? nil : data.prefix(got)
        }
    }

    /// The decision, over any source of bytes — which is what lets it be tested against a program
    /// built in memory rather than one somebody has to ship.
    ///
    /// - Parameter read: The bytes at an offset, up to a length; fewer at the end of the file, `nil`
    ///   on a read error.
    static func inspect(
        fileSize: Int64,
        read: (_ offset: Int64, _ length: Int) -> Data?
    ) -> SelfExtractingArchive? {
        guard let imageEnd = PortableExecutable.imageEnd(fileSize: fileSize, read: read),
              imageEnd < fileSize else { return nil }
        let length = Int(min(Int64(scanLimit + SevenZipStartHeader.length), fileSize - imageEnd))
        guard let appended = read(imageEnd, length) else {
            return SelfExtractingArchive(imageEnd: imageEnd, sevenZipOffset: nil)
        }
        let found = SevenZipStartHeader.firstOffset(in: appended, at: imageEnd, fileSize: fileSize)
        return SelfExtractingArchive(imageEnd: imageEnd, sevenZipOffset: found)
    }
}

/// The two facts about a Windows program's layout this needs: that it is one, and where its image
/// ends. Everything else in the headers is the loader's business.
///
/// Checked against real binaries before it was written: the reported installer's image ends at
/// 125 952 with 4.28 MB appended, signed programs from the Parallels and .NET SDK bundles end
/// exactly where their certificate table begins (12 200 and 10 184 bytes appended), and an unsigned
/// one ends at its own size.
enum PortableExecutable {
    /// The DOS header, whose last field says where the PE header is.
    static let dosHeaderLength = 64
    static let peHeaderPointerOffset = 0x3C
    /// `PE\0\0` and the 20-byte COFF header after it.
    static let coffHeaderLength = 24
    static let sectionHeaderLength = 40
    /// The PE specification's own ceiling, and a bound on a hostile file's section count.
    static let maximumSections = 96

    /// Where the image ends, or `nil` when the bytes are not a well-formed PE.
    static func imageEnd(fileSize: Int64, read: (Int64, Int) -> Data?) -> Int64? {
        guard let dos = read(0, dosHeaderLength), dos.count == dosHeaderLength,
              dos.starts(with: [0x4D, 0x5A]), // MZ
              let peOffset = dos.littleEndian(UInt32.self, at: peHeaderPointerOffset),
              Int64(peOffset) + Int64(coffHeaderLength) <= fileSize,
              let coff = read(Int64(peOffset), coffHeaderLength), coff.count == coffHeaderLength,
              coff.starts(with: [0x50, 0x45, 0, 0]), // PE\0\0
              let sections = coff.littleEndian(UInt16.self, at: 6),
              (1...maximumSections).contains(Int(sections)),
              let optionalHeaderLength = coff.littleEndian(UInt16.self, at: 20)
        else { return nil }

        let tableOffset = Int64(peOffset) + Int64(coffHeaderLength) + Int64(optionalHeaderLength)
        let tableLength = Int(sections) * sectionHeaderLength
        guard let table = read(tableOffset, tableLength), table.count == tableLength else {
            return nil
        }
        var end: Int64 = 0
        for index in 0..<Int(sections) {
            let header = index * sectionHeaderLength
            guard let size = table.littleEndian(UInt32.self, at: header + 16),
                  let start = table.littleEndian(UInt32.self, at: header + 20) else { return nil }
            // A section with no bytes in the file (uninitialized data) says nothing about its end.
            guard size > 0 else { continue }
            end = max(end, Int64(start) + Int64(size))
        }
        // An image that claims to run past the file is a truncated program, not one with a payload.
        return end > 0 && end <= fileSize ? end : nil
    }
}

/// The 32 bytes a 7z archive opens with: its signature, then a start header whose CRC covers the
/// location and size of the header that lists the entries.
///
/// The CRC is what makes a scan safe. Six bytes of signature turn up by chance in compressed data
/// often enough to matter; a signature followed by 20 bytes whose CRC-32 matches the four before
/// them, and which point at a header that fits inside the file, does not. It is the same test
/// libarchive's own SFX search applies (`check_7zip_header_in_memory`), plus the bound.
enum SevenZipStartHeader {
    static let signature: [UInt8] = [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]
    static let length = 32

    /// The file offset of the first verified start header in `bytes`, which were read from
    /// `baseOffset`.
    static func firstOffset(in bytes: Data, at baseOffset: Int64, fileSize: Int64) -> Int64? {
        let data = Data(bytes) // zero-based, whatever slice the caller handed over
        var searchStart = 0
        while searchStart < data.count,
              let hit = data.range(of: Data(signature), in: searchStart..<data.count) {
            let offset = baseOffset + Int64(hit.lowerBound)
            if hit.lowerBound + length <= data.count,
               verifies(
                   data.subdata(in: hit.lowerBound..<hit.lowerBound + length),
                   at: offset,
                   fileSize: fileSize
               ) {
                return offset
            }
            searchStart = hit.lowerBound + 1
        }
        return nil
    }

    /// Whether the 32 bytes at `offset` are a start header that belongs to an archive ending inside
    /// the file.
    static func verifies(_ header: Data, at offset: Int64, fileSize: Int64) -> Bool {
        guard header.count == length,
              let storedCRC = header.littleEndian(UInt32.self, at: 8),
              CRC32.checksum(of: header.subdata(in: 12..<32)) == storedCRC,
              let nextHeaderOffset = header.littleEndian(UInt64.self, at: 12),
              let nextHeaderSize = header.littleEndian(UInt64.self, at: 20),
              // An archive with no header lists nothing; libarchive refuses it too.
              nextHeaderSize > 0,
              let relative = Int64(exactly: nextHeaderOffset),
              let size = Int64(exactly: nextHeaderSize)
        else { return false }
        let (afterStart, overflowA) = offset.addingReportingOverflow(Int64(length))
        let (headerStart, overflowB) = afterStart.addingReportingOverflow(relative)
        let (end, overflowC) = headerStart.addingReportingOverflow(size)
        return !overflowA && !overflowB && !overflowC && end <= fileSize
    }
}

extension Data {
    /// A little-endian integer at `offset` from the start of this value, or `nil` past its end.
    func littleEndian<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T? {
        let size = MemoryLayout<T>.size
        guard offset >= 0, offset + size <= count else { return nil }
        return withUnsafeBytes { raw in
            T(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: T.self))
        }
    }
}
