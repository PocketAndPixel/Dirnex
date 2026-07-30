import Foundation
import Testing

@testable import DirnexCore

@Suite("POSIXPermissions")
struct POSIXPermissionsTests {
    @Test("masks off the file-type bits on the way in")
    func masksTypeBits() {
        // A full st_mode for a regular file, 0644.
        let mode: UInt16 = 0o100_644
        #expect(POSIXPermissions(rawValue: mode).rawValue == 0o644)
    }

    @Test("reads the nine rwx bits by class and access")
    func readsBits() {
        let perm = POSIXPermissions(rawValue: 0o754)
        #expect(perm[.owner, .read] && perm[.owner, .write] && perm[.owner, .execute])
        #expect(perm[.group, .read] && !perm[.group, .write] && perm[.group, .execute])
        #expect(perm[.other, .read] && !perm[.other, .write] && !perm[.other, .execute])
    }

    @Test("setting a bit changes only that bit")
    func setsBits() {
        var perm = POSIXPermissions(rawValue: 0o644)
        perm[.group, .write] = true
        #expect(perm.rawValue == 0o664)
        perm[.owner, .write] = false
        #expect(perm.rawValue == 0o464)
    }

    @Test("special bits round-trip independently of the rwx bits")
    func specialBits() {
        var perm = POSIXPermissions(rawValue: 0o755)
        perm.setUserID = true
        #expect(perm.rawValue == 0o4755)
        perm.setGroupID = true
        #expect(perm.rawValue == 0o6755)
        perm.sticky = true
        #expect(perm.rawValue == 0o7755)
        perm.setUserID = false
        #expect(perm.rawValue == 0o3755)
        #expect(perm[.owner, .read]) // rwx untouched by the special-bit edits
    }

    @Test("octal string is three digits, or four when a special bit is set")
    func octalString() {
        #expect(POSIXPermissions(rawValue: 0o644).octalString == "644")
        #expect(POSIXPermissions(rawValue: 0o600).octalString == "600")
        #expect(POSIXPermissions(rawValue: 0o4755).octalString == "4755")
        #expect(POSIXPermissions(rawValue: 0o1777).octalString == "1777")
    }

    /// Matches `ls(1)`: the special bits overlay the execute column as `s`/`t` (or `S`/`T` when the
    /// execute bit under them is off).
    @Test("symbolic string follows ls, special bits included")
    func symbolicString() {
        #expect(POSIXPermissions(rawValue: 0o644).symbolicString == "rw-r--r--")
        #expect(POSIXPermissions(rawValue: 0o755).symbolicString == "rwxr-xr-x")
        #expect(POSIXPermissions(rawValue: 0o4755).symbolicString == "rwsr-xr-x")
        #expect(POSIXPermissions(rawValue: 0o4644).symbolicString == "rwSr--r--")
        #expect(POSIXPermissions(rawValue: 0o1777).symbolicString == "rwxrwxrwt")
        #expect(POSIXPermissions(rawValue: 0o1776).symbolicString == "rwxrwxrwT")
        #expect(POSIXPermissions(rawValue: 0o2755).symbolicString == "rwxr-sr-x")
    }
}
