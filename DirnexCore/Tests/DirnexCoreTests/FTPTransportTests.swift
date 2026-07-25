import Foundation
import Testing

@testable import DirnexCore

/// Every exit code asserted here was **observed live** on 2026-07-25 against a real FTP/FTPS server
/// by provoking the failure, not read off a man page. The stderr strings are `curl`'s own wording
/// from those runs.
///
/// The classification keys off the **exit code**, not the text, which is the one place FTP is
/// easier than SFTP: `SFTPTransportError.classify` greps English prose and would mis-read a
/// localized OpenSSH, while an exit code says the same thing in every language.
@Suite("FTPTransportError")
struct FTPTransportErrorTests {
    @Test("a missing directory is notFound (exit 9, observed on a LIST of a path that isn't there)")
    func missingDirectoryIsNotFound() {
        let error = FTPTransportError.classify(
            exitCode: 9,
            stderr: "curl: (9) Server denied you to change to the given directory"
        )
        #expect(error == .notFound)
    }

    @Test("a missing file is notFound (exit 78, observed on a download)")
    func missingFileIsNotFound() {
        let error = FTPTransportError.classify(
            exitCode: 78,
            stderr: "curl: (78) The file does not exist"
        )
        #expect(error == .notFound)
    }

    @Test("a wrong password is loginDenied (exit 67, observed)")
    func wrongPasswordIsLoginDenied() {
        let error = FTPTransportError.classify(exitCode: 67, stderr: "curl: (67) Access denied: 530")
        #expect(error == .loginDenied)
    }

    @Test("a server refusing anonymous is loginDenied too (exit 67, observed)")
    func refusedAnonymousIsLoginDenied() {
        let error = FTPTransportError.classify(exitCode: 67, stderr: "curl: (67) Access denied: 530")
        #expect(error == .loginDenied)
    }

    /// Observed by attempting `RMD` on a directory that still had files in it.
    @Test("a failed quote command is read through its FTP reply code (exit 21, observed)")
    func failedQuoteCommandUsesReplyCode() {
        #expect(FTPTransportError.classify(
            exitCode: 21, stderr: "curl: (21) QUOT command failed with 550"
        ) == .notFound)
        #expect(FTPTransportError.classify(
            exitCode: 21, stderr: "curl: (21) QUOT command failed with 530"
        ) == .loginDenied)
        #expect(FTPTransportError.classify(
            exitCode: 21, stderr: "curl: (21) QUOT command failed with 553"
        ) == .permissionDenied)
    }

    /// FTP's own vocabulary is the limit: 550 is "file unavailable", used by servers for both a
    /// missing path and a forbidden one. It reads as `notFound` because that is what a browse
    /// recovers from — and because sending the user to check permissions on a path that simply
    /// isn't there wastes their time.
    @Test("550 is documented as ambiguous and resolves to notFound")
    func ambiguous550ResolvesToNotFound() {
        #expect(FTPTransportError.classify(exitCode: 21, stderr: "... 550 ...") == .notFound)
    }

    @Test(
        "an untrusted certificate is its own case (exit 60, observed against a self-signed server)"
    )
    func untrustedCertificateIsItsOwnCase() {
        let error = FTPTransportError.classify(
            exitCode: 60,
            stderr: "curl: (60) SSL certificate problem: unable to get local issuer certificate"
        )
        #expect(error == .certificateUntrusted)
    }

    /// Observed by pinning a deliberately wrong key: `curl` aborts *before any data moves*, which is
    /// what makes pinning a real control rather than a report.
    @Test("a pinned key that no longer matches is certificateChanged (exit 90, observed)")
    func changedKeyIsCertificateChanged() {
        let error = FTPTransportError.classify(
            exitCode: 90,
            stderr: "curl: (90) SSL: public key does not match pinned public key"
        )
        #expect(error == .certificateChanged)
    }

    @Test("an unreachable host and a timeout are distinguished (exits 6/7 and 28, observed)")
    func unreachableAndTimeout() {
        #expect(
            FTPTransportError.classify(exitCode: 6, stderr: "Could not resolve host") == .unreachable
        )
        #expect(FTPTransportError.classify(
            exitCode: 7, stderr: "curl: (28) Failed to connect to 192.168.1.50 port 990"
        ) == .unreachable)
        #expect(FTPTransportError.classify(
            exitCode: 28,
            stderr: "curl: (28) Failed to connect to 192.168.1.50 port 990 after 7804 ms"
        ) == .timedOut)
    }

    @Test("an unrecognized failure carries curl's own text verbatim")
    func unknownFailureCarriesText() {
        let error = FTPTransportError.classify(exitCode: 55, stderr: "  curl: (55) Send failure  \n")
        #expect(error == .failure("curl: (55) Send failure"))
    }

    /// The core has no business authoring a sentence it cannot translate (PLAN.md §M12 Slice 11), so
    /// an empty stderr stays empty and the app supplies the localized stand-in.
    @Test("an empty stderr yields an empty failure rather than an invented sentence")
    func emptyStderrStaysEmpty() {
        #expect(FTPTransportError.classify(exitCode: 55, stderr: "   \n ") == .failure(""))
    }

    @Test("the reply-code scan reads the FTP code and is not fooled by an IP address")
    func replyCodeScanning() {
        #expect(FTPTransportError.ftpReplyCode(in: "QUOT command failed with 550") == 550)
        // `192` and `168` are octets, not reply codes — restricting to 4xx/5xx is what excludes
        // them, and taking the last match is what survives a message carrying both.
        #expect(FTPTransportError.ftpReplyCode(in: "connect to 192.168.1.50 port 50000") == nil)
        #expect(FTPTransportError.ftpReplyCode(in: "192.168.1.50 said 550") == 550)
        #expect(FTPTransportError.ftpReplyCode(in: "no codes here") == nil)
    }

    /// The failure this narrowing prevents: a message naming the server's address before its reply
    /// code must still classify on the code.
    @Test("a message containing both an address and a reply code classifies on the code")
    func addressDoesNotShadowReplyCode() {
        #expect(FTPTransportError.classify(
            exitCode: 21, stderr: "curl: (21) 192.168.1.50 QUOT command failed with 530"
        ) == .loginDenied)
    }
}
