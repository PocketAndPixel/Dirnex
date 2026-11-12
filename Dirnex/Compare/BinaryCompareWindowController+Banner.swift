import AppKit
import DirnexCore

/// What the byte view says in words (PLAN.md §M37 Slice 2): why the files are shown this way, how far
/// the scan has got, and what no row can say at a glance.
extension BinaryCompareWindowController {
    func showBanner() {
        banner.stringValue = bannerSentences().joined(separator: " ")
    }

    /// The banner's sentences, in the order they are read: why, what, and anything that went wrong.
    func bannerSentences() -> [String] {
        var sentences = [Self.reasonText(reason)]
        sentences += comparison.map(findings(of:)) ?? []
        if let scanFailure {
            sentences.append(String(
                localized: "The comparison stopped: \(VFSErrorText.sentence(for: scanFailure))",
                comment: "Byte comparison window, when the scan fails; %@ says why."
            ))
        }
        if let readFailure {
            sentences.append(String(
                localized: "Part of these files couldn’t be read: \(VFSErrorText.sentence(for: readFailure))",
                comment: "Byte comparison window, when bytes on screen can't be read; %@ says why."
            ))
        }
        return sentences
    }

    static func reasonText(_ reason: BinaryCompareReason) -> String {
        switch reason {
        case let .notText(name):
            String(
                localized: "“\(name)” isn’t a text file, so these files are compared byte by byte.",
                comment: "Byte comparison window: why it opened; %@ is a file name."
            )
        case let .undecodable(name):
            String(
                localized: """
                “\(name)” isn’t text in any encoding Dirnex can read, so these files are compared byte by byte.
                """,
                comment: "Byte comparison window: why it opened; %@ is a file name."
            )
        case .tooLarge:
            String(
                localized: "These files are too large to compare as text, so they are compared byte by byte.",
                comment: "Byte comparison window: why it opened."
            )
        }
    }

    private func findings(of answer: BinaryComparison) -> [String] {
        guard answer.isFinished else {
            return [String(
                localized: "Compared \(answer.percentScanned)% so far.",
                comment: "Byte comparison window, while the scan runs; %lld is a percentage."
            )]
        }
        if answer.isIdentical {
            return [String(
                localized: "The two files hold the same bytes.",
                comment: "Byte comparison window: nothing differs."
            )]
        }
        var sentences: [String] = []
        if answer.differences.differingByteCount > 0 {
            let differing = Self.exact(answer.differences.differingByteCount)
            let compared = Self.exact(answer.commonByteCount)
            sentences.append(String(
                localized: "Bytes that differ: \(differing) of \(compared).",
                comment: "Byte comparison window; the first %@ is how many differ, the second how many were compared."
            ))
        }
        if let tail = answer.tail, let side = answer.longerSide {
            let name = side == .left ? left.name : right.name
            let size = FileFormatting.byteString(Int64(tail.count))
            sentences.append(String(
                localized: "“\(name)” is longer: only it has the last \(size).",
                comment: "Byte comparison window; the first %@ is a file name, the second a byte size."
            ))
        }
        if let dense = answer.largestDenseStretch() {
            let start = BinaryHexLayout.offsetText(dense.range.lowerBound, digits: offsetDigits)
            let end = BinaryHexLayout.offsetText(dense.range.upperBound, digits: offsetDigits)
            sentences.append(String(
                localized: """
                From \(start) to \(end) nearly every byte differs. If bytes were inserted or removed there, \
                everything after them reads as changed.
                """,
                comment: "Byte comparison window; the two %@ are hexadecimal byte offsets."
            ))
        }
        if answer.endedEarly {
            sentences.append(String(
                localized: "One of the files got shorter during the comparison, so the rest wasn’t compared.",
                comment: "Byte comparison window, when a file shrinks while being compared."
            ))
        }
        return sentences
    }

    /// A count of bytes in full, grouped the way this Mac groups digits.
    private static func exact(_ count: Int64) -> String {
        count.formatted(.number)
    }
}
