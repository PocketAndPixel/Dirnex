import Foundation
import Testing

@testable import DirnexCore

/// Asking for several ranges of one remote file at once — the *request* half
/// (docs/HISTORY.md ▸ After M19).
///
/// The S3 half's twin in shape, and its opposite in what a client can read back: over FTP a
/// section's reply code is a race and the exit code belongs to the whole run, so several flags the
/// S3 invocation carries have nothing to do here. What becomes of the pieces is the other half, in
/// `FTPSegmentedDownloadBackendTests`.
@Suite("FTP segmented download: the request")
struct FTPSegmentedDownloadTests {
    private static let location = FTPLocation(host: "ftp.example", username: "u")
    private static let mebibyte: Int64 = 1024 * 1024

    // MARK: - Which ranges are asked for

    /// FTP's ceiling is **four**, not eight, and its threshold twice S3's — because a segment is a
    /// login rather than a request, and because servers cap concurrent connections.
    @Test("FTP splits into at most four segments, above a higher threshold")
    func ftpLimitsAreItsOwn() throws {
        #expect(!SegmentedDownloadPlan.isWorthwhile(totalSize: 16 * Self.mebibyte, limits: .ftp))
        #expect(SegmentedDownloadPlan.isWorthwhile(totalSize: 16 * Self.mebibyte + 1, limits: .ftp))
        // The same size S3 would cut into eight.
        let plan = try #require(
            SegmentedDownloadPlan(totalSize: 100 * Self.mebibyte, limits: .ftp)
        )
        #expect(plan.segmentCount == 4)
        let s3 = try #require(SegmentedDownloadPlan(totalSize: 100 * Self.mebibyte, limits: .s3))
        #expect(s3.segmentCount == 8)
    }

    @Test("no segment is ever under FTP's floor, at any size")
    func segmentsClearTheFloor() throws {
        for megabytes in [17, 24, 33, 64, 100, 512, 4096] {
            let plan = try #require(
                SegmentedDownloadPlan(totalSize: Int64(megabytes) * Self.mebibyte, limits: .ftp)
            )
            #expect(plan.segmentSize >= SegmentedDownloadLimits.ftp.minimumSegmentSize)
            #expect(plan.segmentCount <= SegmentedDownloadLimits.ftp.maximumSegments)
        }
    }

    // MARK: - What curl is told

    @Test("the invocation runs the sections in parallel, immediately, with the meter off")
    func invocationFlags() {
        #expect(Self.invocation(segments: 4).arguments == [
            "-Z", "--parallel-immediate", "--parallel-max", "4", "-sS", "-K", "-"
        ])
    }

    @Test("each segment is its own section, with its own credential, range and file")
    func configurationSections() {
        let sections = Self.invocation(segments: 2).configuration.components(separatedBy: "next\n")
        #expect(sections.count == 2)
        for (index, section) in sections.enumerated() {
            #expect(section.contains("user = \"u:hunter2\""))
            #expect(section.contains("connect-timeout = 15"))
            #expect(section.contains("max-time = 3600"))
            #expect(section.contains("output = \"/tmp/seg\(index + 1)\""))
            #expect(section.contains("url = \"ftp://ftp.example:21/pub/clip.mov\""))
        }
        #expect(sections[0].contains("range = \"0-99\""))
        #expect(sections[1].contains("range = \"100-199\""))
    }

    /// Three flags the S3 twin carries and this deliberately does not, each measured against a real
    /// server rather than reasoned about: FTP writes no error document, so `--fail` has nothing to
    /// suppress; a section's reply code is a race, so a write-out would only invite somebody to read
    /// it; and a segment is a range into a file this code created, so there is never a partial.
    @Test("no --fail, no write-out and no resume — none of the three has anything to do here")
    func absentFlags() {
        let invocation = Self.invocation(segments: 4)
        #expect(!invocation.configuration.contains("fail"))
        #expect(!invocation.configuration.contains("write-out"))
        #expect(!invocation.configuration.contains("continue-at"))
        #expect(!invocation.arguments.contains("--continue-at"))
    }

    /// The security half has to be repeated per section, because `curl` reads one option set per
    /// transfer. A segmented download that quietly lost `--ssl-reqd` or a pin would be a downgrade
    /// nobody asked for, on the one path the user is not watching.
    @Test("every section carries the TLS requirement and the certificate pin")
    func everySectionCarriesItsSecurity() {
        let session = FTPSession(
            location: FTPLocation(host: "nas.local", username: "u", security: .explicit),
            trust: .pinned(publicKey: "AAAABBBB"),
            connectTimeout: 15,
            maxTime: 3600
        )
        let invocation = FTPProcessArguments.downloadSegments(
            session: session,
            remotePath: "/pub/clip.mov",
            segments: Self.segments(3),
            credentials: FTPConfigFile.credentials(for: session.location, password: "hunter2")
        )
        let sections = invocation.configuration.components(separatedBy: "next\n")
        #expect(sections.count == 3)
        for section in sections {
            #expect(section.contains("ssl-reqd"))
            #expect(section.contains("insecure"))
            #expect(section.contains("pinnedpubkey = \"sha256//AAAABBBB\""))
        }
    }

    /// The security assertion this project makes of every builder: the password travels on **stdin**
    /// and is nowhere any `ps` could read it.
    @Test("no password reaches argv")
    func noPasswordInArguments() {
        let invocation = Self.invocation(segments: 4)
        #expect(!invocation.arguments.contains { $0.contains("hunter2") })
        #expect(invocation.configuration.contains("hunter2"))
    }

    // MARK: - Helpers

    private static func segments(_ count: Int) -> [DownloadSegment] {
        (1...count).map {
            DownloadSegment(
                number: $0,
                localPath: "/tmp/seg\($0)",
                range: Int64($0 - 1) * 100..<Int64($0) * 100
            )
        }
    }

    private static func invocation(segments count: Int) -> FTPParallelInvocation {
        FTPProcessArguments.downloadSegments(
            session: FTPSession(location: location, connectTimeout: 15, maxTime: 3600),
            remotePath: "/pub/clip.mov",
            segments: segments(count),
            credentials: FTPConfigFile.credentials(for: location, password: "hunter2")
        )
    }
}
