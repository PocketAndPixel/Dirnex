import Foundation
import Testing

@testable import DirnexCore

/// The rule that decides what a remote transfer must do to carry its source's metadata.
///
/// Every expectation here was measured against a real `sshd` and a real FTP server on 2026-08-28
/// (docs/NOTES.md ▸ sftp / ssh, ▸ curl) rather than read off a man page — `sftp(1)` says `-p`
/// preserves "full file permissions and access times", and it carries the modification time too
/// while dropping every special mode bit.
@Suite("Remote metadata carry")
struct RemoteMetadataCarryTests {
    private let ordinary: UInt16 = 0o644
    private let setuid: UInt16 = 0o4755
    private let setgid: UInt16 = 0o2755
    private let sticky: UInt16 = 0o1644
    private let mtime = Date(timeIntervalSince1970: 1_528_358_950)

    // MARK: - SFTP: `-p` carries the ordinary case whole

    @Test("an ordinary mode over SFTP rides -p alone and costs no extra round trip")
    func ordinaryModeUsesPreserveFlagOnly() {
        let plan = RemoteMetadataPlan.carrying(
            permissions: ordinary,
            modificationTime: mtime,
            capabilities: .sftp
        )
        #expect(plan.steps == [.preserveDuringTransfer])
        #expect(plan.followUp.isEmpty)
        #expect(plan.isComplete)
    }

    @Test("each special bit adds the corrective chmod -p cannot express")
    func specialBitsNeedACorrectiveChmod() {
        for mode in [setuid, setgid, sticky] {
            let plan = RemoteMetadataPlan.carrying(
                permissions: mode,
                modificationTime: mtime,
                capabilities: .sftp
            )
            #expect(plan.usesPreserveFlag)
            #expect(plan.followUp == [.setMode(POSIXPermissions(rawValue: mode))])
            // Carried, not lost — the explicit chmod is what makes this complete.
            #expect(plan.isComplete)
        }
    }

    @Test("an account that refuses chmod loses the special bits and says so")
    func withoutChmodTheSpecialBitsAreReportedDropped() {
        let plan = RemoteMetadataPlan.carrying(
            permissions: setuid,
            modificationTime: mtime,
            capabilities: [.preserveFlag]
        )
        #expect(plan.steps == [.preserveDuringTransfer])
        #expect(plan.dropped == [.specialModeBits])
        #expect(!plan.isComplete)
    }

    // MARK: - Absent is not dropped

    @Test("a source with no mode reports no loss — absence and loss are different facts")
    func nilModeIsNotALoss() {
        // S3 and FTP's DOS/IIS dialect report no mode at all. Folding that together with a mode
        // that *was* dropped would make every S3 copy claim a loss it did not suffer — the same
        // distinction `FileEntry.permissions` became optional for in M24 Slice 7.
        let plan = RemoteMetadataPlan.carrying(
            permissions: nil,
            modificationTime: nil,
            capabilities: []
        )
        #expect(plan.dropped.isEmpty)
        #expect(plan.isComplete)
        #expect(plan.steps.isEmpty)
    }

    @Test("an access time is reported dropped only when the source actually had one")
    func accessTimeIsOnlyDroppedWhenSupplied() {
        let withoutIt = RemoteMetadataPlan.carrying(
            permissions: ordinary,
            modificationTime: mtime,
            capabilities: .ftp
        )
        #expect(!withoutIt.dropped.contains(.accessTime))

        let withIt = RemoteMetadataPlan.carrying(
            permissions: ordinary,
            modificationTime: mtime,
            accessTime: mtime,
            capabilities: .ftp
        )
        #expect(withIt.dropped.contains(.accessTime))
    }

    // MARK: - FTP: no preserve flag, so every aspect is an explicit verb

    @Test("FTP carries mode and mtime as two explicit commands and never a preserve flag")
    func ftpUsesExplicitVerbs() {
        let plan = RemoteMetadataPlan.carrying(
            permissions: ordinary,
            modificationTime: mtime,
            capabilities: .ftp
        )
        #expect(!plan.usesPreserveFlag)
        #expect(plan.steps == [
            .setMode(POSIXPermissions(rawValue: ordinary)),
            .setModificationTime(mtime)
        ])
        #expect(plan.isComplete)
    }

    @Test("an FTP server offering neither extension drops both and names them")
    func ftpWithNoExtensionsDropsBoth() {
        let plan = RemoteMetadataPlan.carrying(
            permissions: ordinary,
            modificationTime: mtime,
            capabilities: []
        )
        #expect(plan.steps.isEmpty)
        #expect(plan.dropped == [.mode, .modificationTime])
    }

    @Test("a server offering SITE CHMOD but not MFMT carries the mode and loses only the time")
    func partialFTPCapabilitiesDegradePerAspect() {
        let plan = RemoteMetadataPlan.carrying(
            permissions: setuid,
            modificationTime: mtime,
            capabilities: [.changeMode]
        )
        #expect(plan.steps == [.setMode(POSIXPermissions(rawValue: setuid))])
        #expect(plan.dropped == [.modificationTime])
    }

    // MARK: - The batch lines

    @Test("-p is spelled on both transfer verbs and combines with -a in one flag run")
    func preserveFlagSpelling() {
        #expect(
            SFTPBatchCommand.download("/r/f", to: "/l/f", preserve: true) == "get -p \"/r/f\" \"/l/f\""
        )
        #expect(
            SFTPBatchCommand.upload("/l/f", to: "/r/f", preserve: true) == "put -p \"/l/f\" \"/r/f\""
        )
        #expect(
            SFTPBatchCommand.download("/r/f", to: "/l/f", resume: true, preserve: true)
                == "get -ap \"/r/f\" \"/l/f\""
        )
    }

    @Test("an unpreserved transfer is byte-identical to what it always sent")
    func plainTransfersAreUnchanged() {
        // The narrowness control: adding the flag must cost the ordinary path nothing.
        #expect(SFTPBatchCommand.download("/r/f", to: "/l/f") == "get \"/r/f\" \"/l/f\"")
        #expect(SFTPBatchCommand.upload("/l/f", to: "/r/f") == "put \"/l/f\" \"/r/f\"")
        #expect(
            SFTPBatchCommand.download("/r/f", to: "/l/f", resume: true) == "get -a \"/r/f\" \"/l/f\""
        )
    }

    @Test("chmod renders four octal digits for a special mode and three for an ordinary one")
    func chmodRendersOctal() {
        #expect(
            SFTPBatchCommand.changeMode("/r/f", to: POSIXPermissions(rawValue: setuid))
                == "chmod 4755 \"/r/f\""
        )
        #expect(
            SFTPBatchCommand.changeMode("/r/f", to: POSIXPermissions(rawValue: ordinary))
                == "chmod 644 \"/r/f\""
        )
    }

    @Test("-h acts on a symlink rather than its target, on all three attribute verbs")
    func symlinkFlagOnAttributeVerbs() {
        #expect(
            SFTPBatchCommand.changeMode(
                "/r/l",
                to: POSIXPermissions(rawValue: 0o700),
                onSymbolicLink: true
            )
                == "chmod -h 700 \"/r/l\""
        )
        #expect(
            SFTPBatchCommand.changeOwner("/r/l", to: 501, onSymbolicLink: true) == "chown -h 501 \"/r/l\""
        )
        #expect(
            SFTPBatchCommand.changeGroup("/r/l", to: 20, onSymbolicLink: true) == "chgrp -h 20 \"/r/l\""
        )
        // Without it, the target is what changes — measured both ways against a real server.
        #expect(SFTPBatchCommand.changeOwner("/r/l", to: 501) == "chown 501 \"/r/l\"")
    }

    @Test("MFMT's timestamp is UTC whatever zone the app is running in")
    func mfmtTimestampIsUTC() throws {
        // 1_528_358_950 is 2018-06-07 08:09:10 UTC. The probe that established this ran on a host at
        // +0300, so a formatter following the current zone would have written 11:09:10 and the
        // server would have stored a time three hours wrong — silently, and only for some users.
        #expect(FTPQuoteCommand.timestamp(mtime) == "20180607080910")
        #expect(
            try FTPQuoteCommand.setModificationTime("/f.txt", to: mtime) == "MFMT 20180607080910 /f.txt"
        )
    }

    @Test("SITE CHMOD carries the mode, special bits included")
    func siteChmodSpelling() throws {
        #expect(
            try FTPQuoteCommand.changeMode("/f.txt", to: POSIXPermissions(rawValue: 0o754)) == "SITE CHMOD 754 /f.txt"
        )
        #expect(
            try FTPQuoteCommand.changeMode("/f.txt", to: POSIXPermissions(rawValue: setuid)) == "SITE CHMOD 4755 /f.txt"
        )
    }

    @Test("both new FTP commands refuse a path that would inject a second command")
    func ftpCommandsRefuseUnsafePaths() {
        // FTP has no quoting at all, so this is a security boundary rather than formatting: the
        // rule the existing verbs already keep has to hold for the new ones too.
        #expect(throws: FTPQuoteCommand.UnsafePath.self) {
            try FTPQuoteCommand.changeMode(
                "/a\r\nDELE important.txt",
                to: POSIXPermissions(rawValue: ordinary)
            )
        }
        #expect(throws: FTPQuoteCommand.UnsafePath.self) {
            try FTPQuoteCommand.setModificationTime("/a\nDELE important.txt", to: mtime)
        }
    }
}
