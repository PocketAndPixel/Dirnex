import Foundation

/// The tables of DTS Coherent Acoustics' core (ETSI TS 102 114 Annex D), generated from the
/// specification by `scripts/generate_dts_tables.py` into `DTSHuffmanTables.swift`,
/// `DTSHuffmanTables129.swift`, `DTSFilterTables.swift` and `DTSQuantizerTables.swift`.
enum DTSTables {}

/// One of Annex D.5's Huffman code books, as a binary tree walked a bit at a time.
struct DTSHuffmanBook: Sendable {
    /// Two entries a node, for a 0 bit and a 1 bit: above 0 the next node, below 0 a leaf
    /// (`-entry - 1` indexes `levels`), and 0 a code the book does not hold.
    private let tree: [Int32]
    private let levels: [Int32]

    /// The book from its (level, length, code) triples.
    init(triples: [Int32]) {
        var tree: [Int32] = [0, 0]
        var levels: [Int32] = []
        for start in stride(from: 0, to: triples.count, by: 3) {
            let level = triples[start], length = Int(triples[start + 1]), code = Int(
                triples[start + 2]
            )
            var node = 0
            for bit in (0..<length).reversed() {
                let slot = node * 2 + ((code >> bit) & 1)
                if bit == 0 {
                    levels.append(level)
                    tree[slot] = -Int32(levels.count)
                } else {
                    if tree[slot] <= 0 {
                        tree[slot] = Int32(tree.count / 2)
                        tree += [0, 0]
                    }
                    node = Int(tree[slot])
                }
            }
        }
        self.tree = tree
        self.levels = levels
    }

    func decode(_ reader: inout DTSBitReader) throws -> Int {
        var node = 0
        while true {
            let entry = tree[node * 2 + (try reader.bit())]
            if entry < 0 { return Int(levels[Int(-entry - 1)]) }
            guard entry > 0 else { throw DTSError.invalid("a code no Huffman book holds") }
            node = Int(entry)
        }
    }

    /// Every book by its name in Annex D.5 (`A3`, `SB129`), built once.
    static let books: [String: DTSHuffmanBook] = DTSTables.huffman.merging(DTSTables.huffman129) { first, _ in first }
        .mapValues(DTSHuffmanBook.init(triples:))

    /// The books in the order a 3-bit selector names them, for each use.
    static let transientModes = ["A4", "B4", "C4", "D4"].map { books[$0]! }
    static let scaleFactors = ["SA129", "SB129", "SC129", "SD129", "SE129"].map { books[$0]! }
    static let bitAllocations = ["A12", "B12", "C12", "D12", "E12"].map { books[$0]! }

    /// The books for the samples of each quantizer `ABITS` 1 to 10, by `SEL` (Table 5-26).
    static let samples: [[DTSHuffmanBook]] = [3, 5, 7, 9, 13, 17, 25, 33, 65, 129].map { levels in
        ["A", "B", "C", "D", "E", "F", "G"].compactMap { books["\($0)\(levels)"] }
    }
}
