import Foundation

/// The two exec-channel commands behind a remote owner and group (PLAN.md §M38 Slice 1).
///
/// **By name, over the exec channel, and not through `sftp`'s own `chown` and `chgrp`.** Those take
/// a number and nothing on an SFTP connection can supply one: `ls -ln` prints names on a current
/// server (docs/NOTES.md ▸ sftp / ssh). They also follow a symlink and change its target, measured,
/// where `-h` changes the link as Finder's Get Info does. `chown` here takes the same name a listing
/// printed, and resolves it on the machine whose name it is.
///
/// Measured on a real `sshd` (macOS), GNU coreutils and busybox.
///
/// `/usr/bin/env` for the reason the other exec commands have it: the channel runs the user's login
/// shell and sources their rc, so a shell function could shadow the binary.
public enum SSHOwnershipCommand {
    /// Who the account is. `LC_ALL=C` because GNU translates `id`'s labels.
    public static let identity = "/usr/bin/env LC_ALL=C id"

    /// Printed after a clean `chown`, since nothing else in the answer says it ran: the channel
    /// reports no status, and an `sftp`-only account answers with prose on stdout.
    static let successToken = "dirnex-chown-ok"

    /// Change an item's owner, its group, or both.
    ///
    /// `chown` rather than `chgrp` for a group alone, so one verb covers every combination. `--`
    /// goes **before** the owner operand: BSD's `chgrp -h admin -- path` takes `--` for a file,
    /// exits 1, and has already changed the link by then.
    ///
    /// `nil` when there is nothing to send, or when a name holds the `:` that separates the two
    /// halves and `chown` would read it as a different owner.
    public static func change(owner: String?, group: String?, of remotePath: String) -> String? {
        guard let operand = operand(owner: owner, group: group) else { return nil }
        return "/usr/bin/env chown -h -- \(SSHShellQuote.quote(operand)) "
            + "\(SSHShellQuote.quote(remotePath)) 2>&1 && /usr/bin/env echo \(successToken)"
    }

    private static func operand(owner: String?, group: String?) -> String? {
        guard owner != nil || group != nil,
              owner?.contains(":") != true, group?.contains(":") != true
        else { return nil }
        return (owner ?? "") + (group.map { ":\($0)" } ?? "")
    }

    /// What was refused, read from what a ``change(owner:group:of:)`` printed, or `nil` for success.
    ///
    /// The server's own sentence is kept where there is one, and it differs for every implementation
    /// (`illegal group name`, `invalid group`, `unknown group`), so nothing here reads it. Only the
    /// token at the end says the command ran, and only its last line can be `chown`'s, since an rc
    /// file may have written before it.
    ///
    /// Always a refusal of this item and never a latched fact about the account: Get Info offers
    /// these controls only once `id` has answered on this connection.
    public static func refusal(in output: String?) -> RemoteMetadataRefusal? {
        let last = output?.split(whereSeparator: \.isNewline).last.map(String.init)
        return last == successToken ? nil : .itemRefused(last ?? "")
    }
}
