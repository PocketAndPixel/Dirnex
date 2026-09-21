import Foundation
import Testing

/// A Windows self-extractor, assembled in memory: a minimal PE image, a 7zSFX-style configuration
/// block, and a real archive appended after them.
///
/// **The stub is built from the PE layout and the payload is not.** The archive is
/// `plain-bsdtar.7z`, written by `bsdtar` from the same tree `plain-bsdtar.zip` holds, so what the
/// reader lists and extracts are real bytes from a producer that knows nothing of Dirnex. The stub
/// is only headers, and the parse that reads them was checked against real binaries before this
/// fixture existed: the reported 7zSFX installer, and signed and unsigned programs from the
/// Parallels and .NET SDK bundles (``DirnexCore/PortableExecutable``). A stub nobody else wrote is
/// what lets a test put the archive at an offset libarchive's own search misses — below `0x27000`
/// — and to break one header field at a time.
enum WindowsProgramFixture {
    /// Two sections, the second ending at `0x1600`, which is where anything appended begins.
    static let defaultSections: [(start: UInt32, size: UInt32)] = [(0x200, 0x1000), (0x1200, 0x400)]

    /// The configuration a 7zSFX module reads, the same shape as the reported installer's.
    static let configuration = """
    ;!@Install@!UTF-8!
    RunProgram="setup.exe"
    ;!@InstallEnd@!
    """

    /// A DOS header pointing at a PE header, a section table, and zeros up to the end of the last
    /// section.
    static func stub(
        sections: [(start: UInt32, size: UInt32)] = defaultSections,
        optionalHeaderLength: UInt16 = 224
    ) -> Data {
        var image = Data(count: 64)
        image[0] = 0x4D // M
        image[1] = 0x5A // Z
        image.replaceSubrange(0x3C..<0x40, with: littleEndian(UInt32(0x40)))

        image.append(contentsOf: [0x50, 0x45, 0, 0]) // PE\0\0
        image.append(littleEndian(UInt16(0x014C))) // i386
        image.append(littleEndian(UInt16(sections.count)))
        image.append(Data(count: 12)) // timestamp, symbol table, symbol count
        image.append(littleEndian(optionalHeaderLength))
        image.append(littleEndian(UInt16(0x0102))) // executable, 32-bit

        var optional = Data(count: Int(optionalHeaderLength))
        if optional.count >= 2 { optional.replaceSubrange(0..<2, with: littleEndian(UInt16(0x010B))) }
        image.append(optional)

        for (index, section) in sections.enumerated() {
            var header = Data(".sec\(index)".utf8.prefix(8))
            header.append(Data(count: 8 - header.count))
            header.append(littleEndian(section.size)) // virtual size
            header.append(littleEndian(section.start)) // virtual address
            header.append(littleEndian(section.size)) // size of raw data
            header.append(littleEndian(section.start)) // pointer to raw data
            header.append(Data(count: 16))
            image.append(header)
        }

        let end = sections.map { Int($0.start) + Int($0.size) }.max() ?? image.count
        if image.count < end { image.append(Data(count: end - image.count)) }
        return image
    }

    /// The committed `bsdtar` 7z.
    static func sevenZip() throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: "plain-bsdtar",
                withExtension: "7z",
                subdirectory: "Fixtures"
            ),
            "missing fixture plain-bsdtar.7z"
        )
        return try Data(contentsOf: url)
    }

    /// Stub, configuration, payload — the order a 7zSFX builder writes them in.
    static func selfExtractor(
        stub: Data = stub(),
        configuration: String = configuration,
        payload: Data
    ) -> Data {
        stub + Data(configuration.utf8) + payload
    }

    /// Write `data` to a fresh file under `directory` and answer its path.
    static func write(_ data: Data, named name: String, in directory: String) throws -> String {
        let path = (directory as NSString).appendingPathComponent(name)
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    static func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
