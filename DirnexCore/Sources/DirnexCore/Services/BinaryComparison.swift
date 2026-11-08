import Foundation

/// How two local files differ byte for byte, at the same offset (PLAN.md §M37 Slice 1).
///
/// **No alignment, by decision.** An inserted byte makes everything after it read as changed, which
/// is what `cmp` says too, and the window says so in words (``largestDenseStretch(minimumLength:)``).
/// What that buys is a comparison with no size limit: a scan of two 1 GiB files measured 0.37 s from
/// the page cache, and it needs a fixed amount of memory, so it answers for a file no text window
/// could hold.
///
/// Like `ByteComparator`, it refuses an evicted cloud placeholder rather than reading through one,
/// since a read would block on the download. Bringing the bytes down is the gesture's job
/// (PLAN.md §6 ▸ M24's row).
public struct BinaryComparison: Sendable, Equatable {
    public let leftByteSize: Int64
    public let rightByteSize: Int64
    /// Where the two sides differ within the length they share. While a scan runs, only as far as
    /// ``scannedByteCount``.
    public let differences: BinaryDifferenceList
    /// How far the scan has got into the length the two sides share.
    public let scannedByteCount: Int64
    /// The scan could not read as far as the files' sizes said: one of them shrank under it, so the
    /// part past ``scannedByteCount`` was not compared.
    public let endedEarly: Bool

    public init(
        leftByteSize: Int64,
        rightByteSize: Int64,
        differences: BinaryDifferenceList,
        scannedByteCount: Int64,
        endedEarly: Bool = false
    ) {
        self.leftByteSize = leftByteSize
        self.rightByteSize = rightByteSize
        self.differences = differences
        self.scannedByteCount = scannedByteCount
        self.endedEarly = endedEarly
    }

    /// The length both files have, which is all that can be compared byte for byte.
    public var commonByteCount: Int64 {
        min(leftByteSize, rightByteSize)
    }

    /// The bytes only the longer file has, or `nil` for two files of one size.
    public var tail: Range<Int64>? {
        leftByteSize == rightByteSize ? nil : commonByteCount..<max(leftByteSize, rightByteSize)
    }

    /// Which file ``tail`` is in, or `nil` for two files of one size.
    public var longerSide: ComparisonPaneText.Side? {
        guard leftByteSize != rightByteSize else { return nil }
        return leftByteSize > rightByteSize ? .left : .right
    }

    /// How much of the length the two sides share has been compared, as a whole percentage. Through
    /// `Double`, since the product of a very large size and 100 would not fit an `Int64`.
    public var percentScanned: Int {
        guard scannedByteCount < commonByteCount else { return 100 }
        return Int(Double(scannedByteCount) / Double(commonByteCount) * 100)
    }

    /// Whether the scan has covered everything the two sides share.
    public var isFinished: Bool {
        endedEarly || scannedByteCount >= commonByteCount
    }

    /// Whether the two files hold the same bytes. Only a finished scan can say so.
    public var isIdentical: Bool {
        isFinished && !endedEarly && tail == nil && differences.stretches.isEmpty
    }

    /// Every place to step to, in order: each stretch, and last the bytes only one side has.
    public var changes: [Range<Int64>] {
        let shared = differences.stretches.map(\.range)
        return tail.map { shared + [$0] } ?? shared
    }

    /// The rows of the byte view each change covers, in the order of ``changes``.
    public var changeRows: [Range<Int>] {
        changes.map { change in
            let first = BinaryHexLayout.row(containing: change.lowerBound)
            let last = BinaryHexLayout.row(containing: change.upperBound - 1)
            return Int(first)..<Int(last + 1)
        }
    }

    // MARK: - Moving between changes

    /// The first change that starts past `offset`, or `nil` past the last one. Pass `-1` for the
    /// first change of all.
    public func change(after offset: Int64) -> Range<Int64>? {
        let all = changes
        let index = Self.firstIndex(in: all) { $0.lowerBound > offset }
        return index < all.count ? all[index] : nil
    }

    /// The last change that starts before `offset`, or `nil` before the first one.
    public func change(before offset: Int64) -> Range<Int64>? {
        let all = changes
        let index = Self.firstIndex(in: all) { $0.lowerBound >= offset }
        return index > 0 ? all[index - 1] : nil
    }

    /// The position of the change holding `offset` among all of them, for "difference 3 of 12".
    public func changeIndex(containing offset: Int64) -> Int? {
        let all = changes
        let index = Self.firstIndex(in: all) { $0.upperBound > offset }
        return index < all.count && all[index].contains(offset) ? index : nil
    }

    /// The first index whose element satisfies `isPast`, which is false up to it and true after.
    private static func firstIndex(
        in ranges: [Range<Int64>],
        where isPast: (Range<Int64>) -> Bool
    ) -> Int {
        var low = 0
        var high = ranges.count
        while low < high {
            let middle = (low + high) / 2
            if isPast(ranges[middle]) {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return low
    }

    // MARK: - What an insertion looks like

    /// The longest stretch of at least `minimumLength` bytes in which at least half the bytes differ,
    /// or `nil` when there is none.
    ///
    /// That is the shape bytes inserted or removed leave behind: two unrelated runs of bytes agree
    /// by chance, one byte in 256, so the stretch runs on and nearly all of it differs. A whole
    /// section rewritten looks the same, so the window words this as a possibility.
    public func largestDenseStretch(
        minimumLength: Int64 = 64 * 1024
    ) -> BinaryDifferenceList.Stretch? {
        differences.stretches
            .filter { $0.range.count >= minimumLength && $0.differingByteCount * 2 >= $0.range.count }
            .max { $0.range.count < $1.range.count }
    }
}

// MARK: - Scanning

extension BinaryComparison {
    /// The read size of a scan: large enough that a file of gigabytes costs few system calls, small
    /// enough that Stop answers within a few milliseconds.
    public static let defaultChunkSize = 1024 * 1024

    /// How often a running scan reports, in bytes read from each side.
    public static let reportInterval: Int64 = 256 * 1024 * 1024

    /// Compare two local files from the start. Blocking; call it off the main thread.
    ///
    /// - Parameter report: called every ``reportInterval`` bytes with what the scan has found so
    ///   far, so a window can open before the end of a file of gigabytes. Not called at the end,
    ///   since the result is the last word.
    /// - Throws: what `ByteComparator` throws. `VFSError.unsupported` for a path that is not local
    ///   or not a regular file, or an evicted placeholder without `allowDataless`, `VFSError` for a
    ///   read failure, and `CancellationError` when `isCancelled` fires.
    public static func scan(
        _ left: VFSPath,
        _ right: VFSPath,
        chunkSize: Int = defaultChunkSize,
        allowDataless: Bool = false,
        report: (BinaryComparison) -> Void = { _ in },
        isCancelled: () -> Bool = { false }
    ) throws -> BinaryComparison {
        guard left.backend == .local, right.backend == .local else {
            throw VFSError.unsupported(.contentComparisonNeedsLocalFiles)
        }
        return try scan(
            ByteComparator.subject(left),
            ByteComparator.subject(right),
            chunkSize: chunkSize,
            allowDataless: allowDataless,
            reportEvery: reportInterval,
            report: report,
            isCancelled: isCancelled
        )
    }

    /// Compare a pair already open, from the sizes it was opened at: the window's own pair, so the
    /// rows on screen and the scan behind them are looking at the same two files.
    public static func scan(
        _ pair: BinaryFilePair,
        allowDataless: Bool = false,
        report: (BinaryComparison) -> Void = { _ in },
        isCancelled: () -> Bool = { false }
    ) throws -> BinaryComparison {
        try run(
            pair.leftSubject,
            pair.rightSubject,
            open: { pair },
            chunkSize: defaultChunkSize,
            allowDataless: allowDataless,
            reportEvery: reportInterval,
            report: report,
            isCancelled: isCancelled
        )
    }

    // Every knob spelled out, as in `ByteComparator`, rather than a second set of defaults.
    // swiftlint:disable:next function_parameter_count
    static func scan(
        _ left: ComparisonSubject,
        _ right: ComparisonSubject,
        chunkSize: Int,
        allowDataless: Bool,
        reportEvery: Int64,
        report: (BinaryComparison) -> Void,
        isCancelled: () -> Bool
    ) throws -> BinaryComparison {
        try run(
            left,
            right,
            open: { try BinaryFilePair(left: left.path, right: right.path) },
            chunkSize: chunkSize,
            allowDataless: allowDataless,
            reportEvery: reportEvery,
            report: report,
            isCancelled: isCancelled
        )
    }

    // swiftlint:disable:next function_parameter_count
    private static func run(
        _ left: ComparisonSubject,
        _ right: ComparisonSubject,
        open: () throws -> BinaryFilePair,
        chunkSize: Int,
        allowDataless: Bool,
        reportEvery: Int64,
        report: (BinaryComparison) -> Void,
        isCancelled: () -> Bool
    ) throws -> BinaryComparison {
        precondition(chunkSize > 0, "a scan has to read something")
        try ByteComparator.requireRegularFiles(left, right)
        let common = min(left.byteSize, right.byteSize)
        var state = ScanState(leftByteSize: left.byteSize, rightByteSize: right.byteSize)
        // Nothing to read means nothing to download either: the sizes alone answer, as they do for
        // `ByteComparator`, and refusing would abort a question that costs nothing.
        guard common > 0 else { return state.result(endedEarly: false) }
        try ByteComparator.requireDownloaded(left, right, allowDataless: allowDataless)

        let pair = try open()
        let leftBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { leftBuffer.deallocate() }
        let rightBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { rightBuffer.deallocate() }

        var nextReport = reportEvery
        while state.scanned < common {
            if isCancelled() { throw CancellationError() }
            let wanted = Int(min(Int64(chunkSize), common - state.scanned))
            let count = try pair.read(wanted, at: state.scanned, into: leftBuffer, rightBuffer)
            guard count > 0 else { return state.result(endedEarly: true) }
            state.list.consume(
                UnsafeRawBufferPointer(rebasing: leftBuffer[..<count]),
                UnsafeRawBufferPointer(rebasing: rightBuffer[..<count]),
                at: state.scanned
            )
            state.scanned += Int64(count)
            if state.scanned >= nextReport, state.scanned < common {
                report(state.result(endedEarly: false))
                nextReport += reportEvery
            }
            guard count == wanted else { return state.result(endedEarly: true) }
        }
        return state.result(endedEarly: false)
    }

    private struct ScanState {
        let leftByteSize: Int64
        let rightByteSize: Int64
        var list = BinaryDifferenceList()
        var scanned: Int64 = 0

        func result(endedEarly: Bool) -> BinaryComparison {
            BinaryComparison(
                leftByteSize: leftByteSize,
                rightByteSize: rightByteSize,
                differences: list,
                scannedByteCount: scanned,
                endedEarly: endedEarly
            )
        }
    }
}
