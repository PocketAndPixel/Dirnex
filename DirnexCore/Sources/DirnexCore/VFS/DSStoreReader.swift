import Foundation

/// One string-valued property inside a `.DS_Store` file: which file it describes, which property,
/// and the string.
///
/// Only string (`ustr`) properties are surfaced, because the one thing Dirnex needs out of this
/// format is the Trash's put-back pair (`ptbL`/`ptbN`, see `TrashPutBack`). Every other property in
/// there is Finder's window furniture — icon positions, view options, background pictures.
public struct DSStoreRecord: Sendable, Equatable {
    /// The file the record describes, named as it appears in the directory.
    public let filename: String
    /// The four-character property id, e.g. `ptbL`.
    public let key: String
    public let value: String

    public init(filename: String, key: String, value: String) {
        self.filename = filename
        self.key = key
        self.value = value
    }
}

public enum DSStoreError: Error, Sendable, Equatable {
    /// The bytes don't start with the `Bud1` allocator header — not a `.DS_Store` at all.
    case notADSStore
    /// The structure ran off the end of the file, pointed at itself, or otherwise didn't add up.
    case malformed
    /// A property whose value length this reader can't compute, so it can't find the next record
    /// either. Recorded rather than skipped: guessing a length would silently mis-read everything
    /// after it, and a wrong put-back path is worse than a missing one.
    case unsupportedValueType(String)
}

/// Reads `.DS_Store` files — Finder's per-directory sidecar database.
///
/// Needed because **put-back has no API**. Probed 2026-07-21: a trashed file carries only
/// `com.apple.provenance` as an xattr, `mdls` knows nothing about where it came from, and every
/// plausible `URLResourceKey` spelling (`NSURLTrashOriginalPathKey` and friends) returns an empty
/// dictionary. Finder keeps the original location in the trash folder's own `.DS_Store`, and that
/// is the only place it exists — so restoring an item to where it came from means reading this
/// format.
///
/// The file is a "buddy allocator" holding a B-tree, both documented only by reverse engineering:
///
/// - a 36-byte header (`0x00000001`, `Bud1`, then the offset/size of the allocator's info block);
/// - the info block: a table of block addresses, each packing an offset and a power-of-two size
///   into one word, followed by a small name → block-number directory. `DSDB` is the one that
///   matters, and it names the B-tree's header block;
/// - the block `DSDB` names, whose first word is the root node's block number;
/// - nodes, each a count of records plus (for an internal node) the child block numbers between
///   them. A record is a UTF-16 filename, a four-character property id, a four-character type, and
///   a value whose length depends on that type.
///
/// **Every block offset in the file is 4 bytes short** — the allocator numbers from just after the
/// leading alignment word — which is the one detail that turns a working parse into garbage.
///
/// Read-only, deliberately. Finder does not delete a record when an item leaves the Trash (the real
/// `~/.Trash/.DS_Store` on the probe machine still listed files removed weeks earlier), so put-back
/// data going stale is the format's normal condition rather than something a writer would fix.
public enum DSStoreReader {
    /// Every string-valued record in the file, in tree order.
    ///
    /// Throws rather than returning what it managed to read: a truncated answer here would read as
    /// "this item has no put-back record", which is indistinguishable from the truth and would send
    /// a restore to the wrong place — or nowhere — with no way to tell.
    public static func stringRecords(in data: Data) throws -> [DSStoreRecord] {
        let bytes = [UInt8](data)
        var header = ByteCursor(bytes: bytes)
        guard try header.uint32() == 1, try header.fourCharacterCode() == "Bud1" else {
            throw DSStoreError.notADSStore
        }
        let infoOffset = Int(try header.uint32())
        let infoSize = Int(try header.uint32())

        let allocator = try Allocator(bytes: bytes, offset: infoOffset, size: infoSize)
        guard let headerBlock = allocator.directories["DSDB"] else { throw DSStoreError.malformed }
        var treeHeader = try allocator.cursor(forBlock: headerBlock)
        let rootNode = try treeHeader.uint32()

        var records: [DSStoreRecord] = []
        var visited: Set<UInt32> = []
        try walk(node: rootNode, allocator: allocator, visited: &visited, into: &records)
        return records
    }

    /// Walk one B-tree node, depth-first and left-to-right so records come back in tree order.
    ///
    /// A leaf node is `next == 0` followed by its records; an internal node interleaves child block
    /// numbers with the records that separate them, and carries its rightmost child in `next`.
    /// `visited` is a cycle guard: the block table is just numbers in a file, and a corrupt one
    /// pointing at an ancestor would otherwise recurse until the stack ran out.
    private static func walk(
        node: UInt32,
        allocator: Allocator,
        visited: inout Set<UInt32>,
        into records: inout [DSStoreRecord]
    ) throws {
        guard visited.insert(node).inserted else { throw DSStoreError.malformed }
        var cursor = try allocator.cursor(forBlock: node)
        let next = try cursor.uint32()
        let count = try cursor.uint32()
        for _ in 0..<count {
            if next != 0 {
                let child = try cursor.uint32()
                try walk(node: child, allocator: allocator, visited: &visited, into: &records)
            }
            if let record = try readRecord(&cursor) { records.append(record) }
        }
        if next != 0 {
            try walk(node: next, allocator: allocator, visited: &visited, into: &records)
        }
    }

    /// One record, returning `nil` for the non-string properties (whose values are stepped over so
    /// the cursor still lands on the next record).
    private static func readRecord(_ cursor: inout ByteCursor) throws -> DSStoreRecord? {
        let filename = try cursor.utf16String(codeUnits: Int(try cursor.uint32()))
        let key = try cursor.fourCharacterCode()
        let type = try cursor.fourCharacterCode()
        switch type {
        case "bool":
            try cursor.skip(1)
        case "long", "shor", "type":
            try cursor.skip(4)
        case "comp", "dutc":
            try cursor.skip(8)
        case "blob":
            try cursor.skip(Int(try cursor.uint32()))
        case "ustr":
            let value = try cursor.utf16String(codeUnits: Int(try cursor.uint32()))
            return DSStoreRecord(filename: filename, key: key, value: value)
        default:
            throw DSStoreError.unsupportedValueType(type)
        }
        return nil
    }

    /// The block table and name directory from the allocator's info block — everything needed to
    /// turn a block *number* into a range of bytes.
    private struct Allocator {
        private let bytes: [UInt8]
        private let addresses: [UInt32]
        let directories: [String: UInt32]

        init(bytes: [UInt8], offset: Int, size: Int) throws {
            self.bytes = bytes
            var cursor = try ByteCursor(bytes: bytes, blockAt: offset, size: size)
            let blockCount = Int(try cursor.uint32())
            try cursor.skip(4) // unknown, always zero on every file probed
            addresses = try (0..<blockCount).map { _ in try cursor.uint32() }
            // The table is written in pages of 256 entries and zero-padded to fill the last one.
            try cursor.skip(((256 - blockCount % 256) % 256) * 4)

            var directories: [String: UInt32] = [:]
            for _ in 0..<Int(try cursor.uint32()) {
                let name = try cursor.asciiString(count: Int(try cursor.uint8()))
                directories[name] = try cursor.uint32()
            }
            self.directories = directories
            // The free lists follow, and are of no interest to a reader.
        }

        /// A cursor over the bytes of one numbered block. The address word packs both halves: the
        /// low five bits are the block's size as a power of two, the rest is its offset.
        func cursor(forBlock number: UInt32) throws -> ByteCursor {
            guard Int(number) < addresses.count else { throw DSStoreError.malformed }
            let address = addresses[Int(number)]
            return try ByteCursor(
                bytes: bytes,
                blockAt: Int(address & ~0x1F),
                size: 1 << Int(address & 0x1F)
            )
        }
    }
}

/// A bounds-checked, big-endian read head over a byte array. Every accessor throws rather than
/// trapping, because the bytes come from a file any process may have written.
private struct ByteCursor {
    private let bytes: [UInt8]
    private var offset: Int
    private let limit: Int

    init(bytes: [UInt8]) {
        self.bytes = bytes
        offset = 0
        limit = bytes.count
    }

    /// A cursor over the block at `offset`, **shifted by the allocator's 4-byte bias**: block
    /// offsets are counted from just past the file's leading alignment word, so every one of them
    /// is 4 bytes short of a file position.
    init(bytes: [UInt8], blockAt offset: Int, size: Int) throws {
        let start = offset + 4
        guard start >= 0, size >= 0, start + size <= bytes.count else { throw DSStoreError.malformed }
        self.bytes = bytes
        self.offset = start
        limit = start + size
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, offset + count <= limit else { throw DSStoreError.malformed }
        offset += count
    }

    mutating func uint8() throws -> UInt8 {
        guard offset < limit else { throw DSStoreError.malformed }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func uint32() throws -> UInt32 {
        guard offset + 4 <= limit else { throw DSStoreError.malformed }
        defer { offset += 4 }
        return bytes[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    mutating func fourCharacterCode() throws -> String {
        try asciiString(count: 4)
    }

    mutating func asciiString(count: Int) throws -> String {
        guard count >= 0, offset + count <= limit else { throw DSStoreError.malformed }
        guard let text = String(bytes: bytes[offset..<offset + count], encoding: .utf8) else {
            throw DSStoreError.malformed
        }
        offset += count
        return text
    }

    /// A UTF-16 **big-endian** string of `codeUnits` units — the format's only text encoding.
    mutating func utf16String(codeUnits: Int) throws -> String {
        guard codeUnits >= 0, offset + codeUnits * 2 <= limit else { throw DSStoreError.malformed }
        defer { offset += codeUnits * 2 }
        var units: [UInt16] = []
        units.reserveCapacity(codeUnits)
        for index in 0..<codeUnits {
            let position = offset + index * 2
            units.append(UInt16(bytes[position]) << 8 | UInt16(bytes[position + 1]))
        }
        return String(decoding: units, as: UTF16.self)
    }
}
