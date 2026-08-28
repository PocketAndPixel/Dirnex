import Foundation
import Testing

@testable import DirnexCore

/// Keeping a metadata step's refusal from being read as the transfer's failure (PLAN.md §M25
/// Slice 2).
///
/// Every line here is OpenSSH's own, read out of `/usr/bin/sftp` and reproduced against a real
/// `sshd` on 2026-08-28. The bug they guard against is measured rather than imagined: a `chmod`
/// refused after a `put` whose bytes had already landed made
/// ``SFTPTransportError/detect(stderr:)`` answer `.permissionDenied` for a file that is perfectly
/// fine — a successful copy reported as a failure.
@Suite("SFTP metadata stderr")
struct SFTPMetadataStderrTests {
    @Test("a successful run separates nothing, so the classifier sees exactly what it always saw")
    func successIsUntouched() {
        // Measured: a successful `put` plus an allowed-to-fail `chmod` prints **0 bytes** of stderr.
        let split = SFTPMetadataStderr.separate(stderr: "")
        #expect(split.isEmpty)
        #expect(split.remainder.isEmpty)
    }

    @Test("a remote setstat refusal is pulled out and the transfer's own error is left behind")
    func remoteRefusalIsSeparated() {
        let stderr = """
        Connected to 127.0.0.1.
        remote setstat "/srv/x.txt": Permission denied
        """
        let split = SFTPMetadataStderr.separate(stderr: stderr)
        #expect(split.lines == ["remote setstat \"/srv/x.txt\": Permission denied"])
        #expect(split.remainder == "Connected to 127.0.0.1.")
    }

    @Test("the local family is separated too — get -p fails on this side, not the server's")
    func localRefusalsAreSeparated() {
        // `local chmod` / `local set times` are what a download's own `-p` prints when this machine
        // refuses the attributes. They carry "Permission denied" like any other line, so leaving
        // them in would make a completed download classify as denied.
        for line in [
            "local chmod \"/tmp/x\": Permission denied",
            "local set times \"/tmp/x\": Operation not permitted",
            "local set times on \"/tmp/x\": Operation not permitted",
            "local chmod directory \"/tmp/d\": Permission denied"
        ] {
            let split = SFTPMetadataStderr.separate(stderr: line)
            #expect(split.lines == [line], "\(line) should read as a metadata refusal")
            #expect(split.remainder.isEmpty)
        }
    }

    @Test("the transfer's own failure survives the split and still classifies")
    func transferFailureSurvives() {
        let stderr = """
        remote setstat "/srv/x.txt": Permission denied
        Couldn't get handle: No such file
        """
        let split = SFTPMetadataStderr.separate(stderr: stderr)
        // The half that matters: what is left must still be the failure the caller has to report.
        #expect(SFTPTransportError.detect(stderr: split.remainder) == .notFound)
        // And without the split, the metadata line alone would have said the same thing about a
        // transfer that had succeeded — which is the bug.
        #expect(
            SFTPTransportError.detect(stderr: "remote setstat \"/srv/x.txt\": Permission denied")
                == .permissionDenied
        )
    }

    @Test("a host-key warning is not a metadata refusal")
    func unrelatedLinesAreKept() {
        let stderr = "Warning: Permanently added '[127.0.0.1]:2299' (ED25519) to the list of known hosts."
        let split = SFTPMetadataStderr.separate(stderr: stderr)
        #expect(split.isEmpty)
        #expect(split.remainder == stderr)
    }
}

/// The batch lines the carry actually sends.
@Suite("SFTP metadata batch lines")
struct SFTPMetadataBatchTests {
    @Test("a follow-up step is marked allowed to fail, or a refusal fails the whole transfer")
    func followUpIsAllowedToFail() {
        let lines = SFTPBatchCommand.metadataFollowUp(
            [.setMode(POSIXPermissions(rawValue: 0o4755))],
            on: "/srv/x.txt"
        )
        // Measured against a real `sshd`: without the `-`, a batch aborts on the first failed
        // command and exits 1 — with the bytes already landed.
        #expect(lines == ["-chmod 4755 \"/srv/x.txt\""])
    }

    @Test("a transfer and its follow-up are one batch, so they ride one connection")
    func transferAndFollowUpShareAConnection() {
        let batch = SFTPBatchCommand.batch(
            [SFTPBatchCommand.upload("/tmp/x", to: "/srv/x.txt", preserve: true)]
                + SFTPBatchCommand.metadataFollowUp(
                    [.setMode(POSIXPermissions(rawValue: 0o4755))],
                    on: "/srv/x.txt"
                )
        )
        // A second invocation would be a fresh TCP connect, key exchange and authentication —
        // measured at 71 ms on loopback, a real round trip over a network.
        #expect(batch == """
        put -p "/tmp/x" "/srv/x.txt"
        -chmod 4755 "/srv/x.txt"
        """)
    }

    @Test("a step SFTP cannot spell is skipped rather than approximated")
    func unspellableStepIsSkipped() {
        // The batch language has no verb that sets a time, which is why
        // `RemoteMetadataCapabilities.sftp` omits it and the plan counts it dropped instead.
        let lines = SFTPBatchCommand.metadataFollowUp(
            [.setModificationTime(Date(timeIntervalSince1970: 1_528_358_950))],
            on: "/srv/x.txt"
        )
        #expect(lines.isEmpty)
    }
}

/// The FTP commands the carry sends, in their own invocation.
@Suite("FTP metadata commands")
struct FTPMetadataCommandTests {
    @Test("a mode and a time become SITE CHMOD and MFMT, in order")
    func stepsBecomeCommands() throws {
        let commands = try FTPQuoteCommand.metadataSteps(
            [
                .setMode(POSIXPermissions(rawValue: 0o754)),
                .setModificationTime(Date(timeIntervalSince1970: 1_528_358_950))
            ],
            on: "/pub/x.txt"
        )
        // The timestamp is UTC to the second (RFC 3659), round-tripped live against a server on a
        // host whose own offset is +0300 — so a zone error could not have hidden.
        #expect(commands == ["SITE CHMOD 754 /pub/x.txt", "MFMT 20180607080910 /pub/x.txt"])
    }

    @Test("the preserve flag has no FTP spelling and is skipped")
    func preserveFlagIsSkipped() throws {
        let commands = try FTPQuoteCommand.metadataSteps([.preserveDuringTransfer], on: "/pub/x.txt")
        #expect(commands.isEmpty)
    }
}
