import Foundation
import Testing

@testable import DirnexCore

/// The locale pinned onto every `sftp` and `ssh` child.
///
/// Reported 2026-09-08 as files being **renamed** on upload: a `DSC_0697-Панорама.jpg` copied to a
/// server listed back as `DSC_0697-\320\237\320\260\320\275\320\276\321\200\320\260\320\274\320\260.jpg`.
/// Nothing was renamed — the server holds the right name, and `sftp`'s own `ls -la` escapes every
/// byte its locale calls unprintable. Measured against a real `sshd` (OpenSSH 10.3) the same file
/// lists verbatim under a UTF-8 `LC_CTYPE` and escaped under `C`, and a GUI-launched app has no
/// locale at all, so it always got `C`.
@Suite("Child process locale")
struct ChildProcessLocaleTests {
    @Test("the character type is pinned to UTF-8, which is the whole of the fix")
    func characterTypeIsPinned() {
        let pinned = ChildProcessLocale.pinningLocale([:])
        #expect(pinned["LC_CTYPE"] == "UTF-8")
    }

    @Test("LC_ALL is removed, because it overrides the pin rather than losing to it")
    func lcAllIsRemoved() {
        // Measured: `LC_ALL=C LC_CTYPE=UTF-8` escapes exactly as the bare `C` locale does, so a
        // build launched from a shell carrying one would defeat the pin entirely. Setting
        // `LC_CTYPE` without clearing this is the fix that looks complete and is not.
        let pinned = ChildProcessLocale.pinningLocale(["LC_ALL": "C"])
        #expect(pinned["LC_ALL"] == nil)
        #expect(pinned["LC_CTYPE"] == "UTF-8")
    }

    @Test("the time category is pinned to C, so removing LC_ALL cannot unpin the date column")
    func timeIsPinnedToC() {
        // `sftp` localizes character type alone today — measured, `LC_ALL=ru_RU.UTF-8` still prints
        // English month names — so this is not what fixes the names. It is here because *removing*
        // `LC_ALL` above is what would otherwise let `LANG` govern the category on a Russian Mac,
        // handing `ColumnarListing`'s `en_US_POSIX` formatters months they cannot read.
        let pinned = ChildProcessLocale.pinningLocale([
            "LANG": "ru_RU.UTF-8", "LC_ALL": "ru_RU.UTF-8"
        ])
        #expect(pinned["LC_TIME"] == "C")
    }

    @Test("everything else the child needs survives untouched")
    func therestOfTheEnvironmentSurvives() {
        // `ssh` needs `HOME` to find `known_hosts`, and the askpass wiring is layered on top of
        // this dictionary — a pin that rebuilt the environment instead of amending it would take
        // the password path's own keys with it.
        let pinned = ChildProcessLocale.pinningLocale([
            "HOME": "/Users/probe", "PATH": "/usr/bin", "LANG": "en_GB.UTF-8"
        ])
        #expect(pinned["HOME"] == "/Users/probe")
        #expect(pinned["PATH"] == "/usr/bin")
        #expect(pinned["LANG"] == "en_GB.UTF-8")
    }
}
