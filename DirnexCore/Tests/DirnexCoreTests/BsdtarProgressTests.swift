import Foundation
import Testing

@testable import DirnexCore

/// Reading `bsdtar`'s SIGINFO answer (PLAN.md §4 ▸ *Smaller than a milestone*).
///
/// **Every fixture below is bytes a real `bsdtar` produced**, captured 2026-08-30 from libarchive
/// 3.7.4 packing 229 MB with its stderr on a pipe. Hand-written samples would prove the parser
/// agrees with what the parser's author imagined the tool prints, which is the failure this project
/// has paid for before (docs/NOTES.md ▸ Working rhythm).
@Suite("BsdtarProgress")
struct BsdtarProgressTests {
    /// One signal's answer, exactly as it arrived.
    private static let sample = """
    In: 3 files, 42894848 bytes; Out: 32440320 bytes, compression 24%
    Current: file11.dat (2883584/20000000 bytes)

    """

    /// Two signals, as they arrive on one accumulating buffer.
    private static let twoSamples = """
    In: 3 files, 42894848 bytes; Out: 32440320 bytes, compression 24%
    Current: file11.dat (2883584/20000000 bytes)
    In: 3 files, 56002048 bytes; Out: 42393600 bytes, compression 24%
    Current: file11.dat (15990784/20000000 bytes)

    """

    @Test("reads the bytes read, the bytes written and the file count")
    func readsARealSample() throws {
        let sample = try #require(BsdtarProgress.latestSample(in: Self.sample))
        #expect(sample.filesRead == 3)
        #expect(sample.bytesRead == 42_894_848)
        #expect(sample.bytesWritten == 32_440_320)
        #expect(sample.currentItem == "file11.dat")
    }

    @Test("takes the newest sample, not the first")
    func takesTheNewest() throws {
        let sample = try #require(BsdtarProgress.latestSample(in: Self.twoSamples))
        #expect(sample.bytesRead == 56_002_048)
        #expect(sample.currentItem == "file11.dat")
    }

    /// The numerator is what `bsdtar` **read**, never what it wrote: the output size is a fraction
    /// of a compression ratio nobody knows until the end, so a bar keyed on it has no denominator.
    @Test("the numerator is the input side")
    func readsTheInputSide() throws {
        let sample = try #require(BsdtarProgress.latestSample(in: Self.sample))
        #expect(sample.bytesRead > sample.bytesWritten)
    }

    /// A pipe read splits wherever it happens to split. Parsing a half-arrived line would report a
    /// byte count wrong by an order of magnitude for one update, which on a bar is a stall and then
    /// a jump.
    @Test("ignores a line that has not finished arriving")
    func ignoresAPartialLine() throws {
        let partial = Self.sample + "In: 4 files, 7"
        let sample = try #require(BsdtarProgress.latestSample(in: partial))
        #expect(sample.bytesRead == 42_894_848)
    }

    @Test("no sample yet is nil, not zero")
    func noSampleIsNil() {
        #expect(BsdtarProgress.latestSample(in: "") == nil)
        #expect(BsdtarProgress.latestSample(in: "In: 3 files, 42894848 bytes; Out:") == nil)
    }

    /// `bsdtar` writes real warnings to the same stream, and the app has always discarded them
    /// because a genuine failure shows up as a non-zero exit. Reading progress off that stream must
    /// not change the bargain.
    @Test("a warning is not a sample")
    func warningsAreNotSamples() throws {
        let noisy = """
        bsdtar: Removing leading '/' from member names
        bsdtar: could not read file: Permission denied

        """
        #expect(BsdtarProgress.latestSample(in: noisy) == nil)

        let mixed = "bsdtar: Removing leading '/' from member names\n" + Self.sample
        let sample = try #require(BsdtarProgress.latestSample(in: mixed))
        #expect(sample.bytesRead == 42_894_848)
    }

    /// A `Current:` line belongs to the `In:` line above it. A later sample with none of its own
    /// must not inherit the previous file's name, or the status line names a file that finished.
    @Test("the current item does not outlive its own sample")
    func currentItemDoesNotCarryOver() throws {
        let text = """
        In: 3 files, 42894848 bytes; Out: 32440320 bytes, compression 24%
        Current: file11.dat (2883584/20000000 bytes)
        In: 12 files, 240000000 bytes; Out: 181799435 bytes, compression 24%

        """
        let sample = try #require(BsdtarProgress.latestSample(in: text))
        #expect(sample.bytesRead == 240_000_000)
        #expect(sample.currentItem == nil)
    }

    /// A member name may contain spaces and parentheses; only the trailing `(read/total bytes)` is
    /// the tool's. Same shape as framing a symlink target by its byte length rather than by the
    /// first separator that appears (docs/NOTES.md ▸ sftp / ssh).
    @Test("a name with its own parentheses survives")
    func awkwardName() throws {
        let text = """
        In: 1 files, 10 bytes; Out: 20 bytes, compression 0%
        Current: my report (final) (2/10 bytes)

        """
        let sample = try #require(BsdtarProgress.latestSample(in: text))
        #expect(sample.currentItem == "my report (final)")
    }
}
