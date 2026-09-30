import Foundation

/// The locale every subprocess Dirnex spawns is run under.
///
/// **A subprocess's output format is part of its environment, not just of its arguments**, and a
/// LaunchServices-launched app has no locale at all: `launchctl getenv` answers empty for `LANG`,
/// `LC_ALL` and `LC_CTYPE` (measured), so a Dirnex started from the Dock hands every child the `C`
/// locale — while a build run from a shell inherits the terminal's UTF-8 and behaves perfectly.
/// That split is why this reached users and never developers, and it is the same
/// shell-vs-LaunchServices asymmetry docs/NOTES.md records for TCC.
///
/// Two tools render a file name through `vis(3)` and therefore escape every byte the locale calls
/// unprintable. Measured 2026-09-08/09 against a real `sshd` (OpenSSH 10.3) and libarchive 3.7.4:
///
/// | | under `C` | under a UTF-8 `LC_CTYPE` |
/// |---|---|---|
/// | `sftp`'s batch `ls -la` | `DSC_0697-\320\237….jpg` | `DSC_0697-Панорама.jpg` |
/// | `bsdtar -tf` / `-tvf` | `./\320\237….txt` | `./Панорама.txt` |
///
/// Neither is a display problem. The pane draws the escaped name and every verb builds its path
/// from it — over SFTP ``SFTPCommands/quote(_:)`` then doubles each backslash, so the server is
/// asked for a file literally called `DSC_0697-\320\237…` and answers **not found** for a row in
/// front of the user.
///
/// **`bsdtar` is worse, because it also *writes*.** Packed under `C`, a zip carries the right UTF-8
/// bytes with its **UTF-8 flag (general-purpose bit 11) CLEAR** — so every conforming reader
/// (Windows Explorer, Info-ZIP, Python's `zipfile`) decodes the name as CP437 and shows
/// `╨ƒ╨░╨╜╨╛╤Ç╨░╨╝╨░.txt`. Under a UTF-8 `LC_CTYPE` the flag is SET and the same readers show
/// `Панорама.txt`. That is an archive somebody sends to a colleague, so it outlives the session.
///
/// Not every child needs this, and the two that do not are worth naming so nobody adds them: `git`
/// is already exact because it is asked for **`-z`**, which turns off `core.quotePath` quoting
/// entirely (measured — raw UTF-8 with no locale set, where the same command without `-z` answers
/// `"\320\237…"`), and `curl` never escapes anything. The rule to carry is that a tool with a
/// *raw-output flag* should be given it, and this exists for the ones that have none.
public enum ChildProcessLocale {
    /// This process's environment with the locale pinned — what a spawn site assigns to a child.
    public static func inherited() -> [String: String] {
        pinningLocale(ProcessInfo.processInfo.environment)
    }

    /// `environment` with the two locale categories that decide how a child renders text pinned.
    ///
    /// Only `LC_CTYPE` is load-bearing: measured, `sftp` calls `setlocale` for character type alone,
    /// so even `LC_ALL=ru_RU.UTF-8` leaves its date column's month names English. The other two
    /// lines are what make that measurement safe to rely on:
    ///
    /// - **`LC_ALL` is removed rather than set**, because it overrides every category — measured,
    ///   `LC_ALL=C LC_CTYPE=UTF-8` escapes exactly as the bare `C` locale does, so a build launched
    ///   from a shell carrying one would defeat the pin entirely.
    /// - **`LC_TIME` is then pinned to `C`** precisely because removing `LC_ALL` is what could
    ///   unpin it: if a later `sftp` or `bsdtar` ever localized time as well, the category would
    ///   fall through to the user's `LANG` and a Russian Mac would hand ``ColumnarListing`` month
    ///   names its `en_US_POSIX` formatters cannot read. It costs nothing and keeps this change
    ///   neutral in a dimension it would otherwise have moved.
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
