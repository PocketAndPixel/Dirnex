import Foundation

/// The three things a delimited file does not say about itself, guessed from a sample: which
/// delimiter it uses, whether its first row names the columns, and which columns hold numbers.
///
/// Every guess has to be right on the files that actually occur and harmless where it is wrong,
/// because a wrong one is visible (a header row shown as data, a column of prices left-aligned) and
/// a `1` away from the source.
extension DelimitedTable {
    /// How many records the delimiter detection reads, and how many bytes at most. Enough to see a
    /// file's shape; a 4 MB file is not scanned four times to pick a separator.
    static let detectionRecordLimit = 100
    static let detectionByteLimit = 64 * 1024
    /// How many data rows the header and number guesses look at.
    static let headerSampleRows = 50
    static let numericSampleRows = 200

    // MARK: - Delimiter

    /// The delimiter that splits the sample into the most consistent records.
    ///
    /// Each candidate scans the sample with quotes honored — which is the whole difference on a real
    /// export whose cells hold commas — and is scored by the field count most records share: first by
    /// how many records share it, then by how large it is. A candidate that leaves most records as a
    /// single field is no delimiter at all. Ties go to `hint`, then to the order of `Delimiter`.
    ///
    /// Semicolon files with decimal commas are the case worth knowing about: `1,5;2,5` splits
    /// consistently on both. The header row usually settles it — `Name;Price` has no comma — and
    /// without one the comma wins.
    static func detectDelimiter(
        in bytes: UnsafeBufferPointer<UInt8>,
        hint: Delimiter?
    ) -> Delimiter {
        let sampleLength = min(bytes.count, detectionByteLimit)
        let sample = UnsafeBufferPointer(rebasing: bytes[0..<sampleLength])
        let isCut = sampleLength < bytes.count
        var candidates = Delimiter.allCases
        if let hint {
            candidates.removeAll { $0 == hint }
            candidates.insert(hint, at: 0)
        }
        var best: (delimiter: Delimiter, shape: Shape)?
        for candidate in candidates {
            var scan = DelimitedTextScanner.scan(
                sample,
                delimiter: candidate.byte,
                recordLimit: detectionRecordLimit
            )
            if isCut, scan.endsMidRecord { scan.dropLastRecord() }
            guard let shape = commonShape(of: scan), shape.fields >= 2 else { continue }
            if let current = best?.shape,
               (shape.share, shape.fields) <= (current.share, current.fields) {
                continue
            }
            best = (candidate, shape)
        }
        return best?.delimiter ?? hint ?? .comma
    }

    /// The field count most records have, and the share of records that have it. A tie between two
    /// counts goes to the larger.
    private struct Shape {
        let fields: Int
        let share: Double
    }

    private static func commonShape(of scan: DelimitedTextScanner.Result) -> Shape? {
        guard scan.recordCount > 0 else { return nil }
        var frequencies: [Int: Int] = [:]
        for record in 0..<scan.recordCount {
            frequencies[scan.fieldCount(ofRecord: record), default: 0] += 1
        }
        guard let common = frequencies.max(by: { ($0.value, $0.key) < ($1.value, $1.key) }) else {
            return nil
        }
        return Shape(fields: common.key, share: Double(common.value) / Double(scan.recordCount))
    }

    // MARK: - Header row

    /// Whether the first record names the columns.
    ///
    /// Python's `csv.Sniffer.has_header` rule, which was checked against every CSV on this Mac: each
    /// column whose sampled values are all numbers, or all the same length, votes on whether the first
    /// row's cell is unlike them. A `timeStamp` over a column of epoch milliseconds votes header; a
    /// `wavs/clip_0001.wav` over a column of eighteen-character paths votes data.
    ///
    /// Where no column has an opinion — free text of varying length, like the dictionary dump in a
    /// real Dynamics export — Python answers "no header", and this answers the opposite, because most
    /// delimited files have one: a first row with no number in it and no repeated name is taken as
    /// names. A single record is data, since there is nothing for it to name.
    static func guessHeaderRow(recordCount: Int, fields: (Int) -> [String]) -> Bool {
        guard recordCount >= 2 else { return false }
        let first = fields(0)
        let sample = (1..<min(recordCount, headerSampleRows + 1)).map(fields)
        var votes = 0
        for (column, name) in first.enumerated() {
            let values = sample.compactMap { $0.indices.contains(column) ? $0[column] : nil }
                .filter { !$0.isEmpty }
            guard !values.isEmpty else { continue }
            if values.allSatisfy(looksNumeric) {
                votes += looksNumeric(name) ? -1 : 1
            } else if let length = values.first?.count, values.allSatisfy({ $0.count == length }) {
                votes += name.count == length ? -1 : 1
            }
        }
        if votes != 0 { return votes > 0 }
        let names = first.filter { !$0.isEmpty }
        return !first.contains(where: looksNumeric) && Set(names).count == names.count
    }

    // MARK: - Numbers

    /// For each column, whether every non-empty cell in the first data rows reads as a number. A
    /// column with no value in the sample is not numeric.
    static func guessNumericColumns(
        columnCount: Int,
        firstDataRecord: Int,
        recordCount: Int,
        fields: (Int) -> [String]
    ) -> [Bool] {
        var sawValue = [Bool](repeating: false, count: columnCount)
        var allNumeric = [Bool](repeating: true, count: columnCount)
        let end = min(recordCount, firstDataRecord + numericSampleRows)
        guard firstDataRecord < end else { return [Bool](repeating: false, count: columnCount) }
        for record in firstDataRecord..<end {
            for (column, value) in fields(record).enumerated() where !value.isEmpty {
                sawValue[column] = true
                if allNumeric[column], !looksNumeric(value) {
                    allNumeric[column] = false
                }
            }
        }
        return zip(sawValue, allNumeric).map { $0 && $1 }
    }

    /// Whether `value` reads as a number: an optional sign, digits grouped or separated by `.` or `,`
    /// (so `1,234.56`, `1.234,56` and `-.5` all count), an optional exponent, and an optional `%`.
    /// Surrounding spaces are ignored. A date (`2026-09-15`) and a version (`1.2.3a`) do not count —
    /// the first has a hyphen, the second a letter.
    static func looksNumeric(_ value: String) -> Bool {
        let units = Array(value.utf8)
        var index = 0
        var end = units.count
        while index < end, units[index] == 0x20 { index += 1 }
        while end > index, units[end - 1] == 0x20 { end -= 1 }
        if index < end, units[index] == 0x2B || units[index] == 0x2D { index += 1 }
        var digits = 0
        var lastWasSeparator = false
        while index < end {
            let unit = units[index]
            if unit >= 0x30, unit <= 0x39 {
                digits += 1
                lastWasSeparator = false
            } else if unit == 0x2E || unit == 0x2C {
                if lastWasSeparator { return false }
                lastWasSeparator = true
            } else {
                break
            }
            index += 1
        }
        guard digits > 0, !lastWasSeparator else { return false }
        if index < end, units[index] == 0x65 || units[index] == 0x45 {
            index += 1
            if index < end, units[index] == 0x2B || units[index] == 0x2D { index += 1 }
            let exponentStart = index
            while index < end, units[index] >= 0x30, units[index] <= 0x39 { index += 1 }
            guard index > exponentStart else { return false }
        }
        if index < end, units[index] == 0x25 { index += 1 }
        return index == end
    }
}
