import Foundation

/// The locale the `sftp` and `ssh` children are run under.
///
/// `sftp`'s own `ls -la` — the bytes ``SFTPListingParser`` reads — renders each name through
/// `vis(3)`, so **every byte the client's locale calls unprintable comes back as a `\nnn` octal
/// escape**. Measured 2026-09-08 against a real `sshd` (OpenSSH 10.3), one file, two environments:
///
///     C locale        DSC_0697-\320\237\320\260\320\275\320\276\321\200\320\260\320\274\320\260.jpg
///     UTF-8 LC_CTYPE  DSC_0697-Панорама.jpg
///
/// That is not a display problem. The pane draws the escaped name and every verb builds its path
/// from it, where ``SFTPCommands/quote(_:)`` doubles each backslash — so the server is asked for a
/// file literally called `DSC_0697-\320\237…` and answers **not found** for a row sitting in front
/// of the user. Download, rename, delete and stat all fail on it; only the name is wrong, so the
/// file itself is intact and nothing has been renamed.
///
/// It reached users rather than developers because of *how the app is launched*: `launchd` sets no
/// `LANG`, `LC_ALL` or `LC_CTYPE` (measured — `launchctl getenv` answers empty for all three), so a
/// LaunchServices-launched Dirnex hands `sftp` the `C` locale, while a build run from a shell
/// inherits the terminal's UTF-8 and lists perfectly. Same shell-vs-LaunchServices split
/// docs/NOTES.md records for TCC, arriving on a locale.
///
/// The **exec channel is deliberately untouched by the bug and still pinned here**: `ls -ldn` runs
/// on the *server*, whose `ls` writes raw bytes into a pipe, so search, sync and the sizer showed
/// the right names the whole time while the ordinary listing did not — which is what a user sees as
/// the app contradicting itself. Pinning every child keeps one rule rather than two.
public enum SFTPChildEnvironment {
    /// `environment` with the two locale categories that decide how `sftp` reads back to us pinned.
    ///
    /// Only `LC_CTYPE` is load-bearing: measured, `sftp` calls `setlocale` for character type alone,
    /// so even `LC_ALL=ru_RU.UTF-8` leaves the date column's month names English. The other two
    /// lines are what make that measurement safe to rely on:
    ///
    /// - **`LC_ALL` is removed rather than set**, because it overrides every category — measured,
    ///   `LC_ALL=C LC_CTYPE=UTF-8` escapes exactly as the bare `C` locale does, so a build launched
    ///   from a shell carrying one would defeat the pin entirely.
    /// - **`LC_TIME` is then pinned to `C`** precisely because removing `LC_ALL` is what could
    ///   unpin it: if a later OpenSSH ever localized time as well, the category would fall through
    ///   to the user's `LANG` and a Russian Mac would hand ``ColumnarListing`` month names its
    ///   `en_US_POSIX` formatters cannot read. It costs nothing and keeps this change neutral in a
    ///   dimension it would otherwise have moved.
    ///
    /// `UTF-8` is macOS's own spelling of a locale that is nothing but a character set — what
    /// Terminal.app writes for "Set locale environment variables on startup" — so it needs no
    /// region and cannot drag one in.
    ///
    /// What this does **not** do is un-escape a name after the fact, and that is a decision rather
    /// than an omission: `sftp` leaves a literal backslash unescaped (measured — `back\slash.txt`
    /// lists verbatim, not doubled), so `\320\237` in a name is genuinely ambiguous and an
    /// un-escaper would silently rename a file that really is called that. What escaping survives
    /// this pin is a name that is *not valid UTF-8* — a Latin-1 name on a Linux server — which no
    /// amount of un-escaping could turn into a `String` that addresses it either.
    public static func pinningLocale(_ environment: [String: String]) -> [String: String] {
        var pinned = environment
        pinned.removeValue(forKey: "LC_ALL")
        pinned["LC_CTYPE"] = "UTF-8"
        pinned["LC_TIME"] = "C"
        return pinned
    }
}
