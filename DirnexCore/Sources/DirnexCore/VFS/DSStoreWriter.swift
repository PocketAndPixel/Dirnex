import Foundation

/// One record inside a `.DS_Store`, with its value kept **exactly as it appears in the file**.
///
/// ``DSStoreRecord`` is the reader's answer to "what does this say"; this is the format's own unit,
/// and it exists because writing the file means putting every *other* record back untouched. A
/// trash's database is Finder's — the put-back pairs it wrote for its own deletes, and in a folder
/// that is not a trash the window furniture (icon positions, view options, background pictures) —
/// so a record this build does not understand has to survive a rewrite byte for byte. Keeping the
/// encoded value rather than a parsed one is what makes that true by construction instead of by a
/// switch somebody has to keep complete.
public struct DSStoreEntry: Sendable, Equatable {
    /// The file the record describes, named as it appears in the directory.
    public let filename: String
    /// The four-character property id, e.g. `ptbL`.
    public let key: String
    /// The four-character value type, e.g. `ustr`.
    public let type: String
    /// The bytes that follow the type code, length prefix included for the variable-length types —
    /// so a writer can emit them without knowing what the type means.
    public let encodedValue: [UInt8]

    public init(filename: String, key: String, type: String, encodedValue: [UInt8]) {
        self.filename = filename
        self.key = key
        self.type = type
        self.encodedValue = encodedValue
    }

    /// A `ustr` record — the only type Dirnex authors, because `ptbL`/`ptbN` are both strings.
    public static func string(filename: String, key: String, value: String) -> DSStoreEntry {
        let units = Array(value.utf16)
        var encoded = DSStoreWriter.bigEndian(UInt32(units.count))
        for unit in units { encoded.append(UInt8(unit >> 8)); encoded.append(UInt8(unit & 0xFF)) }
        return DSStoreEntry(filename: filename, key: key, type: "ustr", encodedValue: encoded)
    }

    /// The text of a `ustr` record, or `nil` for every other type.
    public var stringValue: String? {
        guard type == "ustr", encodedValue.count >= 4 else { return nil }
        let count = Int(
            encodedValue[0..<4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        )
        guard encodedValue.count == 4 + count * 2 else { return nil }
        var units: [UInt16] = []
        units.reserveCapacity(count)
        for index in 0..<count {
            let position = 4 + index * 2
            units.append(UInt16(encodedValue[position]) << 8 | UInt16(encodedValue[position + 1]))
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// The order the B-tree is built in: by filename **case-insensitively**, then by property id.
    ///
    /// Not invented — validated against a real database: the 284 records in this Mac's own
    /// `~/.Trash/.DS_Store`, written by Finder and by `FileManager.trashItem` over months, are
    /// sorted by exactly this and have **zero** inversions under it. A B-tree that disagreed with
    /// the reader's comparator would still parse, and Finder's own lookup would walk into the wrong
    /// child and answer "no record" — the quiet direction, on the gesture this whole file exists
    /// for.
    public static func isOrderedBefore(_ lhs: DSStoreEntry, _ rhs: DSStoreEntry) -> Bool {
        let left = lhs.filename.lowercased()
        let right = rhs.filename.lowercased()
        if left != right { return left < right }
        return lhs.key < rhs.key
    }
}

/// Writes `.DS_Store` files — the other half of ``DSStoreReader``, and the only way to give an item
/// Dirnex trashed a **Put Back** in Finder (PLAN.md §M26 Slice 5).
///
/// `FileManager.trashItem` writes the `ptbL`/`ptbN` pair itself, so an ordinary delete has never
/// needed this. An item inside a File Provider domain — every Dropbox, OneDrive, Box, Drive and
/// iCloud file — is one `trashItem` refuses, so ``ProviderAwareTrashPerformer`` performs the move
/// with a `renamex_np` of its own; and a rename records nothing. Reported by a user 2026-08-31: a
/// file deleted from Dropbox in Dirnex offers no Put Back in Finder, while the same file deleted in
/// Finder does.
///
/// **Finder reads what this writes, immediately and in an already-open window** — probed
/// 2026-08-31 against the live `~/.Trash`: a Dropbox file renamed into the Trash showed no Put Back
/// (the reported bug), and with the pair written by this code the *same* context menu grew one and
/// restored the file to its Dropbox folder. The same again in Google Drive's `<mount>/.Trash`, from
/// a database created here from nothing. The strongest half is what Finder did next: it **rewrote
/// the file from our content**, all 284 of its own records intact, which is it accepting our output
/// as its own database rather than merely tolerating it.
///
/// The format is the buddy allocator and B-tree ``DSStoreReader`` documents, produced here by
/// bulk-loading rather than by insertion: the file is small, it is rewritten whole, and a
/// bulk-loaded tree has no split, merge or rebalance to get wrong.
public enum DSStoreWriter {
    /// The node size a fresh Finder database uses. Only a floor here — see ``pageSize(for:)``.
    static let defaultPageSize = 4096

    /// Serialize `entries` into a complete `.DS_Store`.
    ///
    /// - Returns: the file's bytes, or `nil` if the entries could not be laid out inside the
    ///   allocator's 2 GiB arena — unreachable for a trash database, and answered rather than
    ///   trapped because the caller's honest response to *any* failure here is to leave the file it
    ///   cannot rewrite alone.
    public static func data(for entries: [DSStoreEntry]) -> Data? {
        let blobs = entries.sorted(by: DSStoreEntry.isOrderedBefore).map(encode)
        let pageSize = pageSize(for: blobs)
        let levels = bulkLoad(blobs, pageSize: pageSize)
        let blocks = serialize(levels, records: blobs.count, pageSize: pageSize)
        return assemble(blocks)
    }

    // MARK: - Records

    static func bigEndian(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value >> 24 & 0xFF),
            UInt8(value >> 16 & 0xFF),
            UInt8(value >> 8 & 0xFF),
            UInt8(value & 0xFF)
        ]
    }

    private static func encode(_ entry: DSStoreEntry) -> [UInt8] {
        let units = Array(entry.filename.utf16)
        var out = bigEndian(UInt32(units.count))
        for unit in units { out.append(UInt8(unit >> 8)); out.append(UInt8(unit & 0xFF)) }
        out += Array(entry.key.utf8)
        out += Array(entry.type.utf8)
        out += entry.encodedValue
        return out
    }

    /// Big enough that every record fits in a node with room for the child pointer an internal node
    /// spends on it — which is what makes the bulk load below terminate, since a level that could
    /// not hold one record would never shrink. 4096 is Finder's own size and covers everything a
    /// trash holds; the block's size rides in its address word, so a larger node reads back fine.
    private static func pageSize(for blobs: [[UInt8]]) -> Int {
        let needed = (blobs.map(\.count).max() ?? 0) + 12
        var size = defaultPageSize
        while size < needed { size *= 2 }
        return size
    }

    // MARK: - The tree

    private struct Level {
        var nodes: [[[UInt8]]]
        var isInternal: Bool
    }

    /// Fill nodes in order, promoting the record that did not fit as the separator between them —
    /// the standard bottom-up load, and the reason no node is ever half empty.
    private static func pack(_ blobs: [[UInt8]], pageSize: Int) -> (
        nodes: [[[UInt8]]],
        separators: [[UInt8]]
    ) {
        var nodes: [[[UInt8]]] = []
        var separators: [[UInt8]] = []
        var current: [[UInt8]] = []
        var size = 8
        for blob in blobs {
            if !current.isEmpty, size + blob.count + 4 > pageSize {
                nodes.append(current)
                separators.append(blob)
                current = []
                size = 8
                continue
            }
            current.append(blob)
            size += blob.count + 4
        }
        nodes.append(current)
        return (nodes, separators)
    }

    private static func bulkLoad(_ blobs: [[UInt8]], pageSize: Int) -> [Level] {
        let (leaves, firstSeparators) = pack(blobs, pageSize: pageSize)
        var levels = [Level(nodes: leaves, isInternal: false)]
        var separators = firstSeparators
        while levels[levels.count - 1].nodes.count > 1 {
            let (parents, upper) = pack(separators, pageSize: pageSize)
            levels.append(Level(nodes: parents, isInternal: true))
            separators = upper
        }
        return levels
    }

    // MARK: - Blocks

    /// Number every node — 0 is the allocator's own info block and 1 the tree header, so the nodes
    /// start at 2 — then write each one out, resolving its children's numbers.
    private static func serialize(_ levels: [Level], records: Int, pageSize: Int) -> [Int: [UInt8]] {
        // 0 is the allocator's own info block and 1 the tree header, so the nodes start at 2. The
        // root is numbered first, which is what a reader meets first.
        var numbers: [[Int]] = Array(repeating: [], count: levels.count)
        var next = 2
        for level in stride(from: levels.count - 1, through: 0, by: -1) {
            numbers[level] = levels[level].nodes.indices.map { _ in
                defer { next += 1 }
                return next
            }
        }

        var blocks: [Int: [UInt8]] = [:]
        for level in levels.indices {
            for (index, node) in levels[level].nodes.enumerated() {
                blocks[numbers[level][index]] = levels[level].isInternal
                    ? internalNode(
                        node,
                        children: children(of: index, at: level, in: levels, numbers: numbers)
                    )
                    : leafNode(node)
            }
        }

        blocks[1] = bigEndian(UInt32(numbers[levels.count - 1][0]))
            + bigEndian(UInt32(levels.count - 1))
            + bigEndian(UInt32(records))
            + bigEndian(UInt32(levels.reduce(0) { $0 + $1.nodes.count }))
            + bigEndian(UInt32(pageSize))
        return blocks
    }

    /// Children are handed out in order, each parent taking one more than it holds records: the
    /// record between two children is the separator that was promoted out of the level below.
    private static func children(
        of index: Int,
        at level: Int,
        in levels: [Level],
        numbers: [[Int]]
    ) -> [Int] {
        var first = 0
        for earlier in 0..<index { first += levels[level].nodes[earlier].count + 1 }
        return (0...levels[level].nodes[index].count).map { numbers[level - 1][first + $0] }
    }

    private static func leafNode(_ node: [[UInt8]]) -> [UInt8] {
        var out = bigEndian(0) + bigEndian(UInt32(node.count))
        for blob in node { out += blob }
        return out
    }

    private static func internalNode(_ node: [[UInt8]], children: [Int]) -> [UInt8] {
        var out = bigEndian(UInt32(children[node.count])) + bigEndian(UInt32(node.count))
        for (position, blob) in node.enumerated() {
            out += bigEndian(UInt32(children[position]))
            out += blob
        }
        return out
    }

    // MARK: - The allocator

    /// The buddy allocator the format's block addresses describe: a block of 2^k lives at an offset
    /// that is a multiple of 2^k, and the free lists are what is left over. Seeded with the whole
    /// 2 GiB arena, from which the first 32 bytes are spent immediately — allocator offsets are
    /// counted from just past the file's leading word, so offset 0 *is* the header.
    private struct Buddy {
        var free: [[Int]] = Array(repeating: [], count: 32)

        init() {
            free[31] = [0]
            _ = allocate(32) // the file header; never handed out
        }

        mutating func allocate(_ bytes: Int) -> (offset: Int, size: Int)? {
            var wanted = 5
            while (1 << wanted) < bytes { wanted += 1 }
            var available = wanted
            while available < 32, free[available].isEmpty { available += 1 }
            guard available < 32 else { return nil }
            while available > wanted {
                let offset = free[available].removeFirst()
                available -= 1
                free[available] += [offset, offset + (1 << available)]
            }
            return (free[wanted].removeFirst(), 1 << wanted)
        }
    }

    private static func assemble(_ blocks: [Int: [UInt8]]) -> Data? {
        var buddy = Buddy()
        var addresses: [Int: (offset: Int, size: Int)] = [:]
        for number in blocks.keys.sorted() {
            guard let address = buddy.allocate(max(blocks[number]?.count ?? 0, 32)) else { return nil }
            addresses[number] = address
        }
        guard let (infoAddress, info) = placeInfoBlock(&addresses, blocks: blocks, buddy: buddy) else {
            return nil
        }

        let end = addresses.values.map { $0.offset + $0.size }.max() ?? 0
        var bytes = [UInt8](repeating: 0, count: end + 4)
        bytes.replaceSubrange(0..<4, with: bigEndian(1))
        bytes.replaceSubrange(4..<8, with: Array("Bud1".utf8))
        bytes.replaceSubrange(8..<12, with: bigEndian(UInt32(infoAddress.offset)))
        bytes.replaceSubrange(12..<16, with: bigEndian(UInt32(infoAddress.size)))
        bytes.replaceSubrange(16..<20, with: bigEndian(UInt32(infoAddress.offset)))
        for (number, blob) in blocks {
            guard let address = addresses[number] else { continue }
            bytes.replaceSubrange(address.offset + 4..<address.offset + 4 + blob.count, with: blob)
        }
        bytes.replaceSubrange(
            infoAddress.offset + 4..<infoAddress.offset + 4 + info.count,
            with: info
        )
        return Data(bytes)
    }

    /// The info block records the free lists, and allocating it changes them — so its content is
    /// built against the state that allocation produced, and retried if that content outgrew the
    /// block it was given. It converges on the first or second try; the loop is what makes that a
    /// fact rather than an assumption.
    private static func placeInfoBlock(
        _ addresses: inout [Int: (offset: Int, size: Int)],
        blocks: [Int: [UInt8]],
        buddy: Buddy
    ) -> ((offset: Int, size: Int), [UInt8])? {
        let count = blocks.count + 1
        var request = infoSize(blockCount: count, free: buddy.free)
        for _ in 0..<4 {
            var trial = buddy
            guard let address = trial.allocate(request) else { return nil }
            addresses[0] = address
            let info = infoBlock(blockCount: count, addresses: addresses, free: trial.free)
            if info.count <= address.size { return (address, info) }
            request = info.count
        }
        return nil
    }

    private static func padding(for blockCount: Int) -> Int {
        (256 - blockCount % 256) % 256
    }

    private static func infoSize(blockCount: Int, free: [[Int]]) -> Int {
        8 + (blockCount + padding(for: blockCount)) * 4 + 4 + 9 + 32 * 4
            + free.reduce(0) { $0 + $1.count } * 4
    }

    /// The block-address table, the one-entry name directory naming the tree header, and the free
    /// lists — the three things a reader needs to turn a block number into bytes.
    private static func infoBlock(
        blockCount: Int,
        addresses: [Int: (offset: Int, size: Int)],
        free: [[Int]]
    ) -> [UInt8] {
        var out = bigEndian(UInt32(blockCount)) + bigEndian(0)
        for number in 0..<blockCount {
            let address = addresses[number] ?? (offset: 0, size: 32)
            // The address word packs both halves: the low five bits are the size as a power of two.
            out += bigEndian(UInt32(address.offset | (address.size.trailingZeroBitCount)))
        }
        out += [UInt8](repeating: 0, count: padding(for: blockCount) * 4)
        out += bigEndian(1) + [4] + Array("DSDB".utf8) + bigEndian(1)
        for bucket in free {
            out += bigEndian(UInt32(bucket.count))
            for offset in bucket.sorted() { out += bigEndian(UInt32(offset)) }
        }
        return out
    }
}
