import Foundation
import Testing

@testable import DirnexCore

/// The space an SFTP server has left, as `sftp`'s `df` reports it (PLAN.md §M38's SFTP follow-up).
/// Every transcript here was captured on 2026-11-11 by feeding ``SFTPDiskFree``'s own batches to this
/// Mac's `sftp` (OpenSSH 10.3) with standard error folded into standard output, as the app's transport
/// runs them. `login-*` is the first session (``SFTPDiskFree/loginBatch``) and `folders-*` the second
/// (``SFTPDiskFree/folderBatch(_:)``), from:
///
/// - the throwaway macOS `sshd`, its start folder pinned to a scratch folder holding `notes.txt` and
///   `Documents` (`internal-sftp -d`), by key and interactively, the shape the password route runs;
/// - the same with `-P statvfs,fstatvfs`, the extension withheld;
/// - an Alpine container (OpenSSH 10.3p1): `root`, whose home holds only `.ssh`, on the ext4-backed
///   overlay; an account chrooted to a 64 MiB `tmpfs`; and two chroots shaped like DSM's SFTP root,
///   made only of bind-mounted folders, both on one 48 MiB volume (`junction-one-volume`) or one on it
///   and one on a 32 MiB volume (`junction-two-volumes`);
/// - the NAS, DSM's SFTP as `dirnex-test` over the password route (`*-synology`), whose login directory
///   `/` holds only the shares, on an 8 GB filesystem of its own, with every share on the data volume;
/// - and two sessions that never got as far: a key the server does not know, and a closed port.
///
/// `folders-linux-proc` asks `/proc` by path, since no folder of a login directory is a
/// pseudo-filesystem here.
enum SFTPFixtures {
    static func text(_ name: String) throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures/SFTP")
        )
        return try String(contentsOf: url, encoding: .utf8)
    }
}

@Suite("SFTP disk free")
struct SFTPDiskFreeTests {
    private static let mebibyte: Int64 = 1024 * 1024
    /// The overlay the container's `/`, `/root` and both chroots' roots sit on.
    private static let overlay = ServerSpace(
        availableBytes: 11_542_176 * 1024,
        totalBytes: 61_202_244 * 1024
    )

    private func login(_ name: String) throws -> SFTPDiskFree.LoginAnswer {
        try SFTPDiskFree.login(in: SFTPFixtures.text(name))
    }

    private func folders(_ name: String, _ asked: [String]) throws -> [ServerSpace?] {
        try SFTPDiskFree.folders(in: SFTPFixtures.text(name), asked: asked)
    }

    /// The macOS capture with its numbers line replaced, for the values no server here could be made
    /// to send.
    private func macOSAnswer(withNumbers numbers: String) throws -> String {
        let text = try SFTPFixtures.text("login-macos-apfs")
        let real = "  1948455240   1416937588    531517652    531517652          72%"
        #expect(text.contains(real))
        return text.replacingOccurrences(of: real, with: numbers)
    }

    // MARK: - The questions

    @Test(
        "the first session asks df with no path, lists, and ends on pwd; the second asks each folder"
    )
    func batches() {
        #expect(SFTPDiskFree.loginBatch == "-df\n-ls -la\npwd")
        #expect(SFTPDiskFree.folderBatch(["home", "media"]) == "-df \"home\"\n-df \"media\"")
        #expect(SFTPBatchCommand.diskFree(of: "say \"hi\"") == "-df \"say \\\"hi\\\"\"")
    }

    // MARK: - The first session

    @Test(
        "an ordinary login directory answers its filesystem, by key and interactively, and asks no more"
    )
    func macOS() throws {
        let apfs = ServerSpace(availableBytes: 531_517_652 * 1024, totalBytes: 1_948_455_240 * 1024)
        // `notes.txt` beside `Documents` makes it a directory files are written to.
        #expect(try login("login-macos-apfs") == SFTPDiskFree.LoginAnswer(space: apfs, folders: []))
        #expect(
            try SFTPFixtures.text("login-macos-apfs-interactive").hasPrefix(
                "Connected to 127.0.0.1."
            )
        )
        #expect(try login("login-macos-apfs-interactive").space == ServerSpace(
            availableBytes: 531_517_648 * 1024, totalBytes: 1_948_455_240 * 1024
        ))
        #expect(try login("login-macos-apfs-interactive").folders.isEmpty)
    }

    @Test("on ext4 the space is what an account may write, not the reserve only root may use")
    func ext4Reserve() throws {
        let text = try SFTPFixtures.text("login-linux-root")
        #expect(text.contains("    61202244     46518744     11542176     14683500          76%"))
        #expect(try login("login-linux-root").space == Self.overlay)
    }

    @Test("an empty login directory, a chroot on a 64 MiB tmpfs, answers 64 MiB of 64 MiB")
    func chroot() throws {
        let tmpfs = ServerSpace(availableBytes: 64 * Self.mebibyte, totalBytes: 64 * Self.mebibyte)
        #expect(
            try login("login-linux-chroot-tmpfs") == SFTPDiskFree.LoginAnswer(
                space: tmpfs,
                folders: []
            )
        )
    }

    @Test("a login directory holding only folders asks them next, by name")
    func onlyFolders() throws {
        #expect(try login("login-linux-root").folders == [".ssh"])
        #expect(try login("login-junction-one-volume").folders == ["home", "media"])
    }

    @Test("the folders are asked only when the listing finished, at most eight, sorted")
    func folderList() throws {
        let text = try SFTPFixtures.text("login-junction-one-volume")
        let cut = try #require(text.range(of: "sftp> pwd"))
        #expect(try SFTPDiskFree.login(in: String(text[..<cut.lowerBound])).folders.isEmpty)

        let row = "drwxrwxrwx    ? 0        0              40 Nov 11 02:22 "
        let many = (1...10).reversed().map { row + "share\($0)\n" }.joined()
        let wide = text.replacingOccurrences(of: row + "media\n", with: row + "media\n" + many)
        let asked = try SFTPDiskFree.login(in: wide).folders
        #expect(
            asked == ["home", "media", "share1", "share10", "share2", "share3", "share4", "share5"]
        )
    }

    @Test("a filesystem of size zero has nothing to say, which is not a full disk")
    func pseudoFilesystem() throws {
        #expect(try SFTPFixtures.text("folders-linux-proc").contains("ERR"))
        #expect(try folders("folders-linux-proc", ["/proc"]) == [nil])
    }

    @Test("a full disk is zero bytes left of its total, which is a space to show")
    func full() throws {
        let text = try macOSAnswer(
            withNumbers: "  1948455240   1948455240            0            0         100%"
        )
        #expect(try SFTPDiskFree.login(in: text).space == ServerSpace(
            availableBytes: 0, totalBytes: 1_948_455_240 * 1024
        ))
    }

    @Test("a filesystem too wide for its column still splits, and one past Int64 is no answer")
    func wideColumns() throws {
        // 2 EiB in KiB is 2^51, sixteen digits, past `%12llu`'s width; the separating spaces stay.
        let wide = try macOSAnswer(
            withNumbers: "2251799813685248 1 2251799813685247 2251799813685247 0%"
        )
        #expect(try SFTPDiskFree.login(in: wide).space == ServerSpace(
            availableBytes: 2_251_799_813_685_247 * 1024, totalBytes: 2_251_799_813_685_248 * 1024
        ))
        let tooBig = try macOSAnswer(
            withNumbers: "9007199254740992 0 9007199254740992 9007199254740992 0%"
        )
        #expect(throws: SFTPTransportError.self) { try SFTPDiskFree.login(in: tooBig) }
    }

    @Test("a numbers line that is not four whole numbers is no answer")
    func malformed() throws {
        for numbers in [
            "  1948455240   1417895304    530559936          72%",
            "  1.8TB 1.3TB 507GB 507GB 72%"
        ] {
            let text = try macOSAnswer(withNumbers: numbers)
            #expect(throws: SFTPTransportError.self) { try SFTPDiskFree.login(in: text) }
        }
    }

    @Test("a table in the listing is not the login directory's, since a name can print any line")
    func forgedTable() throws {
        // `df` printed nothing (its path gone), and a name with newlines in it printed a table.
        let text = try SFTPFixtures.text("login-macos-apfs")
        let table = try #require(text.range(of: "        Size"))
        let listEcho = try #require(text.range(of: "sftp> -ls -la\n"))
        let forged = String(text[..<table.lowerBound]) + String(text[listEcho.lowerBound...])
            .replacingOccurrences(
                of: "notes.txt\n",
                with: "notes.txt\n" + text[table.lowerBound..<listEcho.lowerBound]
            )
        #expect(throws: SFTPTransportError.self) { try SFTPDiskFree.login(in: forged) }
    }

    // MARK: - Refusals

    @Test("a server without the extension cannot say, on either route, which is not a failure")
    func withheld() throws {
        for name in ["login-withheld", "login-withheld-interactive"] {
            #expect(try SFTPFixtures.text(name).contains("extension\r\nsftp> -ls -la\n"))
            #expect(throws: ServerSpaceUnsupported()) { try login(name) }
        }
    }

    @Test("a session that never got as far as df is no answer, and not a server that cannot say")
    func noAnswer() throws {
        #expect(throws: SFTPTransportError.permissionDenied) { try login("login-refused") }
        #expect {
            try login("login-connection-refused")
        } throws: { error in
            guard case let .failure(text)? = error as? SFTPTransportError else { return false }
            return text.contains("Connection refused")
        }
        // A `df` whose path is gone prints nothing at all, so its block is empty.
        #expect(throws: SFTPTransportError.self) {
            try SFTPDiskFree.login(
                in: "sftp> -df\nsftp> -ls -la\nsftp> pwd\nRemote working directory: /\n"
            )
        }
    }

    // MARK: - The second session, and the choice

    @Test("a folder on the login directory's own filesystem keeps the login directory's answer")
    func folderSharesLogin() throws {
        let answers = try folders("folders-linux-root", [".ssh"])
        #expect(answers == [Self.overlay])
        #expect(SFTPDiskFree.choose(login: Self.overlay, folders: answers) == Self.overlay)
    }

    @Test("a root of mount points answers the volume its folders are on, as DSM's SFTP root needs")
    func junctionOneVolume() throws {
        let volume = ServerSpace(availableBytes: 48 * Self.mebibyte, totalBytes: 48 * Self.mebibyte)
        let first = try login("login-junction-one-volume")
        #expect(first.space == Self.overlay)
        let answers = try folders("folders-junction-one-volume", first.folders)
        #expect(answers == [volume, volume])
        #expect(SFTPDiskFree.choose(login: first.space, folders: answers) == volume)
    }

    @Test("folders spread over two volumes answer none, since no one number is the server's")
    func junctionTwoVolumes() throws {
        let first = try login("login-junction-two-volumes")
        let answers = try folders("folders-junction-two-volumes", first.folders)
        #expect(answers == [
            ServerSpace(availableBytes: 48 * Self.mebibyte, totalBytes: 48 * Self.mebibyte),
            ServerSpace(availableBytes: 32 * Self.mebibyte, totalBytes: 32 * Self.mebibyte)
        ])
        #expect(SFTPDiskFree.choose(login: first.space, folders: answers) == nil)
    }

    @Test("the NAS answers its shares' volume, not the small filesystem its SFTP root is on")
    func synology() throws {
        let text = try SFTPFixtures.text("login-synology")
        #expect(
            text.hasPrefix(
                "** WARNING: connection is not using a post-quantum key exchange algorithm.\r\n"
            )
        )
        let first = try login("login-synology")
        #expect(
            first.space == ServerSpace(
                availableBytes: 6_506_708 * 1024,
                totalBytes: 8_028_096 * 1024
            )
        )
        // DSM lists its root with no `.` and `..`, and with real link counts.
        #expect(first.folders == ["home", "media", "share"])
        let volume = ServerSpace(
            availableBytes: 10_844_742_188 * 1024,
            totalBytes: 14_989_737_984 * 1024
        )
        let answers = try folders("folders-synology", first.folders)
        #expect(answers == [volume, volume, volume])
        #expect(SFTPDiskFree.choose(login: first.space, folders: answers) == volume)
    }

    @Test("a mounted folder beside an ordinary one keeps the login directory's answer, not none")
    func mountBesideOrdinaryFolder() throws {
        // `.ssh` on the overlay and a 48 MiB volume mounted beside it: the login directory is a place
        // files go, and one folder on another disk does not make it a root of mount points.
        let volume = try folders("folders-junction-one-volume", ["home", "media"])[0]
        let ordinary = try folders("folders-linux-root", [".ssh"])[0]
        #expect(
            SFTPDiskFree.choose(login: Self.overlay, folders: [volume, ordinary]) == Self.overlay
        )
    }

    @Test(
        "a folder that printed nothing is left out; a second session that reached none is no answer"
    )
    func missingFolders() throws {
        let text = try SFTPFixtures.text("folders-junction-one-volume")
        let mediaEcho = try #require(text.range(of: "sftp> -df \"media\"\n"))
        let mediaGone = String(text[..<mediaEcho.upperBound])
        let volume = ServerSpace(availableBytes: 48 * Self.mebibyte, totalBytes: 48 * Self.mebibyte)
        #expect(try SFTPDiskFree.folders(in: mediaGone, asked: ["home", "media"]) == [volume, nil])
        #expect(SFTPDiskFree.choose(login: Self.overlay, folders: [nil, nil]) == Self.overlay)
        #expect(throws: SFTPTransportError.self) {
            try SFTPDiskFree.folders(
                in: SFTPFixtures.text("login-connection-refused"),
                asked: ["home"]
            )
        }
    }

    @Test(
        "the same filesystem asked a moment apart is one; another size, or space far apart, is not"
    )
    func sameFilesystem() {
        let total: Int64 = 1_000_000
        let space = ServerSpace(availableBytes: 500_000, totalBytes: total)
        #expect(space.isSameFilesystem(as: ServerSpace(availableBytes: 509_000, totalBytes: total)))
        #expect(!space.isSameFilesystem(as: ServerSpace(availableBytes: 520_000, totalBytes: total)))
        #expect(
            !space.isSameFilesystem(as: ServerSpace(availableBytes: 500_000, totalBytes: total + 1))
        )
        #expect(!space.isSameFilesystem(as: ServerSpace(availableBytes: 500_000)))
    }
}
