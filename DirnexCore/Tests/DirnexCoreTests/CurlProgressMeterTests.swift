import Testing
@testable import DirnexCore

/// The meter parser, pinned against bytes a real `curl` produced.
///
/// The fixture is not invented: it is the head and tail of the stderr of one 29 MB upload to the
/// live endpoint, captured 2026-08-14 while measuring why an S3 copy reports nothing for its whole
/// duration. Every separator in it is the one `curl` actually wrote — which is the point, since a
/// parser written against a newline-separated guess would pass a hand-typed fixture and report
/// nothing at all against the real stream.
@Suite("curl progress meter")
struct CurlProgressMeterTests {
    /// The two header lines `curl` opens with, `\n`-separated, and then `\r` before the first row.
    private static let header = """
          % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                         Dload  Upload   Total   Spent    Left  Speed

    """

    /// Real rows from that capture, in order.
    private static let rows = [
        "  0     0    0     0    0     0      0      0 --:--:-- --:--:-- --:--:--     0",
        "  0 27.6M    0     0    0 65098      0  69944  0:06:54 --:--:--  0:06:54 69922",
        "  1 27.6M    0     0    1  447k      0   228k  0:02:03  0:00:01  0:02:02  228k",
        "  2 27.6M    0     0    2  831k      0   278k  0:01:41  0:00:02  0:01:39  278k",
        " 86 27.6M    0     0   86 23.9M      0   336k  0:01:24  0:01:12  0:00:12  104k",
        "100 27.6M    0     0  100 27.6M      0   285k  0:01:39  0:01:39 --:--:--  356k"
    ]

    /// The whole stream as `curl` laid it out: headers, `\r`-joined rows, then the write-out fields
    /// on their own `\n`-separated lines.
    private static var wholeStream: String {
        header + rows.joined(separator: "\r") + "\ns3-status=200\ns3-up=29000000\n"
    }

    @Test("the leading integer of each row is the percentage, in a real capture")
    func readsRealCapture() {
        var meter = CurlProgressMeter()
        meter.consume(Self.wholeStream)
        #expect(meter.percentComplete == 100)
    }

    @Test("rows are separated by carriage returns, so a newline-only reader sees nothing")
    func rowsAreCarriageReturnSeparated() {
        // Joined by `\r`, the final row has nothing terminating it yet — so the answer is the
        // second-to-last row, which is the holding rule doing its job on the real capture rather
        // than on a hand-made partial.
        let midTransfer = Self.header + Self.rows.joined(separator: "\r")
        var meter = CurlProgressMeter()
        meter.consume(midTransfer)
        #expect(meter.percentComplete == 86, "the last row is not terminated until the next \\r")

        var newlinesOnly = CurlProgressMeter()
        newlinesOnly.consume(Self.header + Self.rows[0] + "\n")
        #expect(newlinesOnly.percentComplete == 0)
    }

    @Test("the headers, curl's own prose and the write-out fields are all ignored")
    func ignoresEverythingThatIsNotAMeterRow() {
        var meter = CurlProgressMeter()
        meter.consume(Self.header)
        #expect(meter.percentComplete == nil, "no row has arrived yet")

        meter.consume("curl: (6) Could not resolve host: example.invalid\n")
        meter.consume("s3-status=200\ns3-up=29000000\ns3-etag=\"abc\"\n")
        #expect(meter.percentComplete == nil)
    }

    @Test("a row split across chunks is held until it is terminated")
    func holdsPartialRows() {
        var meter = CurlProgressMeter()
        meter.consume(Self.header + "\r 4")
        // ` 4` alone would read as 4 % — and is really the head of ` 42 …`.
        #expect(meter.percentComplete == nil)
        meter.consume("2 27.6M    0     0   42 11.6M")
        #expect(meter.percentComplete == nil)
        meter.consume("\r")
        #expect(meter.percentComplete == 42)
    }

    @Test("the percentage never goes backwards")
    func isMonotonic() {
        var meter = CurlProgressMeter()
        meter.consume(" 42 27.6M    0     0   42 11.6M\r")
        meter.consume("  7 27.6M    0     0    7  1.9M\r")
        #expect(meter.percentComplete == 42)
    }

    @Test("bytes are the caller's exact total scaled by the percentage")
    func scalesTheCallersTotal() {
        var meter = CurlProgressMeter()
        #expect(meter.bytesTransferred(ofTotal: 29_000_000) == nil, "nothing has been read yet")

        meter.consume("  0     0    0     0    0     0\r")
        #expect(meter.bytesTransferred(ofTotal: 29_000_000) == 0)

        meter.consume(" 50 27.6M    0     0   50 13.8M\r")
        let half: Int64 = 14_500_000
        #expect(meter.bytesTransferred(ofTotal: 29_000_000) == half)

        meter.consume("100 27.6M    0     0  100 27.6M\r")
        let whole: Int64 = 29_000_000
        #expect(meter.bytesTransferred(ofTotal: 29_000_000) == whole)
    }

    @Test("a size the caller does not know yields no estimate")
    func refusesToScaleAnUnknownTotal() {
        var meter = CurlProgressMeter()
        meter.consume(" 50 27.6M\r")
        #expect(meter.bytesTransferred(ofTotal: 0) == nil)
    }

    @Test("a number that is not a percentage is not a row")
    func rejectsOutOfRangeLeadingNumbers() {
        var meter = CurlProgressMeter()
        // The shape a `Content-Length`-ish line or a stray byte count would have.
        meter.consume("29000000 bytes written\r")
        #expect(meter.percentComplete == nil)
    }
}
