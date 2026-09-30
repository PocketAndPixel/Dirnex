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

    // MARK: - The prose that shares this stream

    /// Real captures from a throttled local FTP server, 2026-08-16 — the run that measured what
    /// letting the meter through costs the *error* text, since `curl` writes both here.
    ///
    /// Worth noting what these show about `curl` itself: the table is printed for **every** `-S`
    /// transfer, even one that never connects, so on a transfer invocation there is always a meter
    /// row and the header is always identifiable as the thing before it.
    private enum Capture {
        /// An 8 MB upload that succeeded: nothing but the table.
        static let success = """
          % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                         Dload  Upload   Total   Spent    Left  Speed
        \r  0     0    0     0    0     0      0      0 --:--:-- --:--:-- --:--:--     0\r\
        100 8192k    0     0  100 8192k      0  1362k  0:00:06  0:00:06 --:--:--  682k

        """

        /// An upload into a directory that is not there: `curl` exit 9.
        static let refused = """
          % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                         Dload  Upload   Total   Spent    Left  Speed
        \r  0     0    0     0    0     0      0      0 --:--:-- --:--:-- --:--:--     0\r\
          0     0    0     0    0     0      0      0 --:--:-- --:--:-- --:--:--     0
        curl: (9) Server denied you to change to the given directory

        """

        /// A wrong password: `curl` exit 67, and the reply code the classifier reads.
        static let loginDenied = """
          % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                         Dload  Upload   Total   Spent    Left  Speed
        \r  0     0    0     0    0     0      0      0 --:--:--  0:00:03 --:--:--     0
        curl: (67) Access denied: 530

        """
    }

    @Test("a transfer that only ran leaves no prose behind")
    func successHasNoProse() {
        #expect(CurlProgressMeter.prose(in: Capture.success).isEmpty)
    }

    @Test("the table is dropped and curl's own sentence is kept, whole")
    func keepsTheDiagnosisAndDropsTheTable() {
        #expect(
            CurlProgressMeter.prose(in: Capture.refused)
                == "curl: (9) Server denied you to change to the given directory"
        )
        // 61 bytes rather than the 378 the raw stream carries — and `.failure` hands this on as the
        // server's own words, so it should not be a table whatever eventually reads it.
        #expect(CurlProgressMeter.prose(in: Capture.refused).count < 70)
    }

    @Test("the reply code the classifier reads survives the meter sharing its stream")
    func replyCodeSurvives() {
        let prose = CurlProgressMeter.prose(in: Capture.loginDenied)
        #expect(prose == "curl: (67) Access denied: 530")
        #expect(FTPTransportError.ftpReplyCode(in: prose) == 530)
        #expect(FTPTransportError.classify(exitCode: 67, stderr: prose) == .loginDenied)
    }

    /// The narrow case where letting the table reach the classifier would actually change an answer,
    /// pinned because the live control for it came out **inert**: every failure provoked against a
    /// real server classified identically either way, since a transfer that fails has usually not
    /// moved enough for its meter to print anything but zeros.
    ///
    /// The mechanism is arithmetic rather than luck. `classify` reads the *last* three-digit
    /// 4xx/5xx token, and a meter's speed column is three digits and a unit — so a transfer moving
    /// at **553k** when the server refuses it puts `553` after `curl`'s own reply-code-less message,
    /// where it reads as FTP's "file name not allowed" and turns a missing path into a permission
    /// failure. Nothing in the shipped code notices; the user is simply sent to check the wrong
    /// thing.
    @Test("a transfer speed cannot be read as an FTP reply code")
    func aSpeedIsNotAReplyCode() {
        let midTransferFailure = """
          % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                         Dload  Upload   Total   Spent    Left  Speed
        \r  6 8192k    0     0    6  553k      0   553k  0:00:14  0:00:01  0:00:13  553k
        curl: (9) Server denied you to change to the given directory

        """
        #expect(FTPTransportError.ftpReplyCode(in: midTransferFailure) == 553, "the raw stream")
        #expect(
            FTPTransportError.classify(exitCode: 9, stderr: midTransferFailure) == .permissionDenied,
            "which is the wrong answer, from a number that is a transfer speed"
        )

        let prose = CurlProgressMeter.prose(in: midTransferFailure)
        #expect(FTPTransportError.ftpReplyCode(in: prose) == nil)
        #expect(FTPTransportError.classify(exitCode: 9, stderr: prose) == .notFound)
    }

    /// The case the header rule exists for, and the common one: every FTP invocation that is *not* a
    /// transfer runs with `-sS`, so its stderr is prose with no meter row anywhere. A rule that
    /// dropped "the first two lines", or everything before the first row unconditionally, would eat
    /// the whole message here.
    @Test("a stream with no meter in it is prose from beginning to end")
    func keepsEverythingWhenNothingMetered() {
        #expect(
            CurlProgressMeter.prose(in: "curl: (78) The file does not exist\n")
                == "curl: (78) The file does not exist"
        )
        let multiline = "Warning: something happened\ncurl: (9) Server denied you\n"
        let expected = "Warning: something happened\ncurl: (9) Server denied you"
        #expect(CurlProgressMeter.prose(in: multiline) == expected)
    }

    @Test("an unterminated last line is still part of the diagnosis")
    func keepsTheUnterminatedTail() {
        // `curl`'s final line need not end in a newline, and it is the one that says what went wrong.
        #expect(
            CurlProgressMeter.prose(in: "curl: (7) Couldn't connect") == "curl: (7) Couldn't connect"
        )
        // A *partial meter row* is excluded by the same test that excludes a complete one, so a
        // prose read mid-transfer does not pick up half a table row.
        var meter = CurlProgressMeter()
        meter.consume(Self.header + "\r 42 27.6M    0     0   42 11.6M\r  4")
        #expect(meter.prose.isEmpty)
    }
}
