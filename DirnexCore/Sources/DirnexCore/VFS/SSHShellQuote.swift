import Foundation

/// POSIX single-quoting: the only thing standing between a remote path and the server's shell.
///
/// Inside single quotes every character is literal, including `$`, backtick, `;`, newline and `*` —
/// so the sole escape needed is for the quote itself, closed and re-opened around a backslashed one
/// (`'\''`). Verified against a real server: a path built as `…/tree'; touch CANARY; echo '` created
/// no canary and was reported by `find` as one missing path, and a directory genuinely named
/// ``it's $a `b` ;x.txt`` came back byte-for-byte.
///
/// **This is not formatting.** A remote path can arrive from a listing the *server* produced, so a
/// name a stranger chose reaches a shell here — the same reasoning that makes FTP refuse a name
/// carrying CR or LF (docs/NOTES.md ▸ curl). It lives in one place because two commands now send
/// paths over an exec channel — the subtree search and a download's ranges — and a second spelling
/// of this rule is how one of them would come to have a weaker one.
enum SSHShellQuote {
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
