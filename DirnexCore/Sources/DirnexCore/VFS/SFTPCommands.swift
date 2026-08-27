import Foundation

/// What `sftp` and `ssh` are actually told: the batch lines one `sftp -b -` session reads, and the
/// process arguments both tools are spawned with.
///
/// Split out of `SFTPTransport.swift` when that file reached SwiftLint's `file_length` — by concept,
/// along the seam the protocol already implies: above, what a transport *promises*; here, the exact
/// bytes handed to a command line. Pure and tested for the reason `S3ProcessArguments` and
/// `FTPProcessArguments` are — the security-sensitive assembly, above all that **no secret reaches
/// `argv`**, is verifiable without spawning anything.
/// Builds the `sftp` batch commands the transport feeds on stdin. Pure and tested so the escaping —
/// the one place a remote path with spaces or quotes could break the command — is verified without
/// a server. `sftp`'s batch parser splits on whitespace but honors double quotes and backslash
/// escapes, so a path is wrapped in quotes with `\` and `"` escaped.
public enum SFTPBatchCommand {
    /// The batch line that lists (or stats) `remotePath`: `ls -la "…"`.
    public static func list(_ remotePath: String) -> String {
        "ls -la \(quote(remotePath))"
    }

    /// The batch line that creates a remote directory: `mkdir "…"`.
    public static func makeDirectory(_ remotePath: String) -> String {
        "mkdir \(quote(remotePath))"
    }

    /// The batch line that renames/moves a remote item: `rename "src" "dst"`.
    public static func rename(_ source: String, to destination: String) -> String {
        "rename \(quote(source)) \(quote(destination))"
    }

    /// The batch line that removes a remote file or symlink: `rm "…"`.
    public static func removeFile(_ remotePath: String) -> String {
        "rm \(quote(remotePath))"
    }

    /// The batch line that removes an empty remote directory: `rmdir "…"`.
    public static func removeDirectory(_ remotePath: String) -> String {
        "rmdir \(quote(remotePath))"
    }

    /// The batch line that creates a remote symbolic link: `ln -s "target" "link"` (`sftp`'s `ln`
    /// takes the existing target first, the new link path second, like `ln(1)`).
    public static func createSymbolicLink(_ remotePath: String, target: String) -> String {
        "ln -s \(quote(target)) \(quote(remotePath))"
    }

    /// The batch line that downloads a remote file to a local path: `get "remote" "local"`, or
    /// `get -a "remote" "local"` to **resume** — `sftp` seeks to the local file's current length and
    /// fetches only the remainder, instead of restarting from zero.
    ///
    /// `preserve` adds **`-p`**, which was measured against a real server rather than read off
    /// `sftp(1)`: it carries the low nine permission bits and *both* timestamps exactly — the man
    /// page promises only "permissions and access times", and the modification time comes too — and
    /// it silently drops set-uid, set-gid and the sticky bit. Those need ``changeMode(_:to:)``
    /// after the fact, which is why a caller asks ``RemoteMetadataPlan`` what a transfer needs
    /// rather than reaching for this flag directly.
    public static func download(
        _ remotePath: String,
        to localPath: String,
        resume: Bool = false,
        preserve: Bool = false
    ) -> String {
        "get \(flags(resume: resume, preserve: preserve))\(quote(remotePath)) \(quote(localPath))"
    }

    /// The batch line that uploads a local file to a remote path: `put "local" "remote"`, or
    /// `put -a "local" "remote"` to **resume** — `sftp` seeks past the remote file's current length
    /// and sends only the remainder.
    ///
    /// `preserve` adds **`-p`**, with exactly the reach and the blind spot
    /// ``download(_:to:resume:preserve:)`` documents — measured in this direction too.
    public static func upload(
        _ localPath: String,
        to remotePath: String,
        resume: Bool = false,
        preserve: Bool = false
    ) -> String {
        "put \(flags(resume: resume, preserve: preserve))\(quote(localPath)) \(quote(remotePath))"
    }

    /// The batch line that sets a remote item's mode: `chmod 4755 "…"`.
    ///
    /// The **only** route to the three special bits, which `-p` drops in both directions even though
    /// the server puts them on the wire — measured, `chmod 4755` really does produce `-rwsr-xr-x`.
    /// The mode is rendered as up to four octal digits, which is what `sftp`'s parser reads.
    ///
    /// `onSymbolicLink` sends **`-h`**, acting on a link rather than its target. Verified both ways:
    /// with `-h` the link's own mode changed and its target was untouched, and without it the target
    /// changed and the link was untouched.
    public static func changeMode(
        _ remotePath: String,
        to permissions: POSIXPermissions,
        onSymbolicLink: Bool = false
    ) -> String {
        "chmod \(onSymbolicLink ? "-h " : "")\(String(permissions.rawValue, radix: 8)) \(quote(remotePath))"
    }

    /// The batch line that sets a remote item's owner: `chown 501 "…"`.
    ///
    /// Refused for an unprivileged account changing an owner it does not already have — exit 1 and
    /// `remote setstat "…": Permission denied`, which is the ordinary answer rather than a
    /// misconfiguration, so a caller must expect it rather than treat it as a broken connection.
    public static func changeOwner(
        _ remotePath: String,
        to ownerID: UInt32,
        onSymbolicLink: Bool = false
    ) -> String {
        "chown \(onSymbolicLink ? "-h " : "")\(ownerID) \(quote(remotePath))"
    }

    /// The batch line that sets a remote item's group: `chgrp 20 "…"`.
    ///
    /// Succeeds where the account belongs to the target group and is refused otherwise, exactly as
    /// the local `chgrp` is (docs/NOTES.md ▸ ACLs and file attributes).
    public static func changeGroup(
        _ remotePath: String,
        to groupID: UInt32,
        onSymbolicLink: Bool = false
    ) -> String {
        "chgrp \(onSymbolicLink ? "-h " : "")\(groupID) \(quote(remotePath))"
    }

    /// The `-a`/`-p` flag run shared by `get` and `put`, with its trailing space, so the two verbs
    /// cannot disagree about spelling or order.
    private static func flags(resume: Bool, preserve: Bool) -> String {
        let letters = (resume ? "a" : "") + (preserve ? "p" : "")
        return letters.isEmpty ? "" : "-\(letters) "
    }

    /// The batch line that prints the remote working directory (`pwd`), used to discover the home
    /// directory to land in on connect.
    public static let printWorkingDirectory = "pwd"

    static func quote(_ path: String) -> String {
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

/// How the CLI-driven transport authenticates against a server. Carries no secret for `.password`:
/// the password is resolved from the Keychain by the app and fed to `sftp` out-of-band via an
/// `SSH_ASKPASS` helper (never on the command line, never in this value, never on disk), so an auth
/// *method* is safe to describe and thread around like an `SFTPLocation`.
public enum SFTPAuthentication: Sendable, Hashable, Codable {
    /// Public-key auth with the private key at `identityFile` — `sftp`'s native non-interactive path.
    case key(identityFile: String)
    /// Password auth; the password is supplied out-of-band, never held here.
    case password
}

/// Builds the `sftp` process arguments (after the executable path) for a one-command session. Pure
/// and tested so the security-sensitive flag assembly — which auth methods are offered, and crucially
/// whether the interactive password prompt is enabled — is verified without spawning `sftp`, the
/// same reason `SFTPBatchCommand` is pure.
///
/// The two modes differ fundamentally, verified live against OpenSSH 10:
/// - **Key auth uses `-b -`**: quiet, fail-fast batch semantics (no `sftp>` echo, a non-zero exit on
///   a failed command). `-b` also forces `-oBatchMode=yes` onto `ssh`, which is what makes key auth
///   fully non-interactive. This is the shipped, verified browse/transfer path — left untouched.
/// - **Password auth cannot use `-b`**: it forces `BatchMode=yes`, which disables the password prompt
///   entirely (`ssh` would report "no more authentication methods"). So password auth runs `sftp`
///   *interactively* over a piped stdin — the prompt is answered out-of-band by `SSH_ASKPASS` — which
///   means stdout carries `sftp>` echo lines (`SFTPListingParser` skips them) and a failed command
///   exits zero (so the transport must scan stderr with `detect(stderr:)`, not just the exit code).
///   Only the `password` method is offered: `keyboard-interactive` stalls for a minute on a *wrong*
///   password when `SSH_ASKPASS` auto-answers it (macOS PAM), which would hang the pane on a typo;
///   and `PubkeyAuthentication=no` stops a machine's stray authorized key from bypassing the choice.
public enum SFTPProcessArguments {
    public static func batch(
        location: SFTPLocation,
        authentication: SFTPAuthentication,
        connectTimeout: Int
    ) -> [String] {
        arguments(
            location: location,
            authentication: authentication,
            connectTimeout: connectTimeout,
            portFlag: "-P",
            batchFile: true
        )
    }

    /// The `ssh` arguments for one **exec** channel — the search shortcut's route (PLAN.md §M22
    /// Slice 4) — with `command` as the trailing operand the server's shell will run.
    ///
    /// Two things differ from ``batch(location:authentication:connectTimeout:)`` and nothing else
    /// does, which is the point: the same host key policy, the same timeout, the same offered
    /// authentication methods, so the exec channel cannot become a second security posture that
    /// drifts from the browsing one.
    ///
    /// - `ssh` spells the port **`-p`** where `sftp` spells it `-P`. Getting that backwards is a
    ///   *usage* error, which exits 1 having printed help — it cost this milestone's own benchmark
    ///   a wrong answer before the assertion that now guards it (docs/NOTES.md ▸ sftp / ssh).
    /// - There is no `-b -`, because there is no batch file: the command *is* an argument. Key auth
    ///   therefore has to ask for `BatchMode=yes` explicitly, which `-b` used to imply for it.
    public static func exec(
        location: SFTPLocation,
        authentication: SFTPAuthentication,
        connectTimeout: Int,
        command: String
    ) -> [String] {
        arguments(
            location: location,
            authentication: authentication,
            connectTimeout: connectTimeout,
            portFlag: "-p",
            batchFile: false
        ) + [command]
    }

    private static func arguments(
        location: SFTPLocation,
        authentication: SFTPAuthentication,
        connectTimeout: Int,
        portFlag: String,
        batchFile: Bool
    ) -> [String] {
        let common = [
            "-o", "ConnectTimeout=\(connectTimeout)",
            // Trust-on-first-use: a fresh host is added to known_hosts, a *changed* key still fails.
            "-o", "StrictHostKeyChecking=accept-new",
            portFlag, String(location.port)
        ]
        let target = "\(location.username)@\(location.host)"
        switch authentication {
        case let .key(identityFile):
            return ["-i", identityFile, "-o", "BatchMode=yes"] + common
                + (batchFile ? ["-b", "-"] : []) + [target]
        case .password:
            // No `-b`: it would disable the prompt. Interactive over piped stdin; `SSH_ASKPASS`
            // answers the prompt (wired by the transport's environment).
            return [
                "-o", "PreferredAuthentications=password",
                "-o", "PubkeyAuthentication=no",
                // One attempt, so a wrong password fails fast instead of re-prompting three times.
                "-o", "NumberOfPasswordPrompts=1"
            ] + common + [target]
        }
    }
}
