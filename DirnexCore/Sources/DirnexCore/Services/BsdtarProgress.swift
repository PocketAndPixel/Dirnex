import Foundation

/// What `bsdtar` says about itself when it is asked, and the reading that makes a plain pack's bar
/// determinate (PLAN.md §4 ▸ *Smaller than a milestone*).
///
/// **`bsdtar` prints no progress and no flag turns one on.** What it has is **SIGINFO**: signalled,
/// it writes two lines to stderr, carries on, and leaves its exit status untouched. Measured
/// 2026-08-30 against libarchive 3.7.4 over 229 MB, with stderr on a real **pipe** rather than a
/// terminal — which is the half worth stating, because it is exactly where `sftp`'s meter fails
/// (docs/NOTES.md ▸ sftp / ssh: OpenSSH draws its meter only for a foreground process group on a
/// controlling terminal, so a spawned process can never read one). Two signals mid-run and the pack
/// still exited 0.
///
///     In: 3 files, 42894848 bytes; Out: 32440320 bytes, compression 24%
///     Current: file11.dat (15990784/20000000 bytes)
///
/// **The number to read is `In:` bytes — what has been *read*, not what has been written.** That is
/// the quantity a walk can measure before the pack starts, which is what a determinate bar needs
/// (`PackRunner` already keys the encrypted path's bar on the same total). The output size cannot
/// serve: it depends on a compression ratio nobody knows until the end, so a bar keyed on it would
/// be a fraction of a denominator that is still being discovered.
public struct BsdtarProgressSample: Sendable, Equatable {
    /// Files fully read so far. `bsdtar` counts the ones it has finished, so the file named by
    /// ``currentItem`` is not among them.
    public let filesRead: Int
    /// Bytes read from the sources so far — the bar's numerator.
    public let bytesRead: Int64
    /// Bytes written to the archive so far. Reported because it is free and because a status line
    /// may want it; never a bar's numerator, for the reason in the type comment.
    public let bytesWritten: Int64
    /// The member being read, when the sample carried a `Current:` line. Absent rather than empty
    /// when it did not: the two lines are printed together in every sample measured, but a reader
    /// that assumes it must be there would drop an otherwise perfectly good byte count.
    public let currentItem: String?

    public init(filesRead: Int, bytesRead: Int64, bytesWritten: Int64, currentItem: String?) {
        self.filesRead = filesRead
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
        self.currentItem = currentItem
    }
}

/// Reads `bsdtar`'s SIGINFO answers out of whatever has arrived on its stderr.
///
/// Pure, so it is the half of the pack that `DirnexCore` owns: spawning the process, signalling it
/// and draining the pipe are the app's (PLAN.md §2 — non-hermetic subprocess I/O lives in the app,
/// the parse of its output lives here behind an injected transport).
///
/// **Everything that is not one of the two lines is ignored, deliberately.** `bsdtar` writes real
/// warnings to that same stream — an unreadable file, a name too long for the format — and the app
/// has always discarded them (`ArchivePacker` sends stderr to `/dev/null` today) because a genuine
/// failure shows up as a non-zero exit. Reading progress off the stream must not change that
/// bargain: a warning is not a sample, and a sample is not an error.
public enum BsdtarProgress {
    /// The most recent complete sample in `stderr`, or `nil` if none has arrived yet.
    ///
    /// **The last *complete* line only.** A pipe read can split anywhere, so the tail of the buffer
    /// is routinely half a line — parsing it would report a byte count an order of magnitude wrong
    /// for one update, which on a bar reads as a stall and then a jump. A line counts as complete
    /// when a newline follows it.
    public static func latestSample(in stderr: String) -> BsdtarProgressSample? {
        let lines = completeLines(of: stderr)
        guard let index = lines.lastIndex(where: { $0.hasPrefix("In: ") }),
              let totals = totals(in: lines[index]) else { return nil }
        // The `Current:` line follows its own `In:` line, so it is only this sample's if it is the
        // very next one — a later `In:` with no `Current:` after it must not inherit an older name.
        let next = lines.index(after: index)
        let current = next < lines.endIndex ? currentItem(in: lines[next]) : nil
        return BsdtarProgressSample(
            filesRead: totals.files,
            bytesRead: totals.read,
            bytesWritten: totals.written,
            currentItem: current
        )
    }

    /// `In: 3 files, 42894848 bytes; Out: 32440320 bytes, compression 24%`
    ///
    /// Read positionally off the numbers rather than by matching the words around them, so a
    /// libarchive that reworded the line still yields a byte count as long as the shape holds. The
    /// trailing percentage is deliberately not read: it is derived from the two numbers already
    /// taken, and it is the one field that would need a locale.
    private static func totals(in line: Substring) -> Totals? {
        let numbers = integers(in: line)
        guard numbers.count >= 3 else { return nil }
        return Totals(files: Int(numbers[0]), read: numbers[1], written: numbers[2])
    }

    /// The three counts one `In:` line carries.
    private struct Totals {
        let files: Int
        let read: Int64
        let written: Int64
    }

    /// `Current: file11.dat (15990784/20000000 bytes)`
    ///
    /// The name is everything between the prefix and the last `(`, because a member name may
    /// contain spaces, parentheses and very nearly anything else — the same reason the SFTP listing
    /// parser frames a symlink target by its byte length rather than by the first separator it sees.
    /// A line with no size in parentheses still yields the name.
    private static func currentItem(in line: Substring) -> String? {
        guard line.hasPrefix("Current: ") else { return nil }
        var name = String(line.dropFirst("Current: ".count))
        if let open = name.lastIndex(of: "("), name.hasSuffix(")") {
            name = String(name[name.startIndex..<open])
        }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// Every run of digits in `line`, in order, as `Int64`.
    private static func integers(in line: Substring) -> [Int64] {
        line.split(whereSeparator: { !$0.isASCII || !$0.isNumber })
            .compactMap { Int64($0) }
    }

    /// The lines of `text` that are known to have ended — everything before the final newline.
    private static func completeLines(of text: String) -> [Substring] {
        guard let end = text.lastIndex(where: \.isNewline) else { return [] }
        return text[text.startIndex..<end].split(whereSeparator: \.isNewline)
    }
}
