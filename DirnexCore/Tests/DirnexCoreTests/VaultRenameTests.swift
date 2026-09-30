import Foundation
import Testing

@testable import DirnexCore

/// Renaming a vault's volume — the `diskutil` argv and the rules a volume name has to clear.
///
/// Split out of `VaultTests`, which had reached SwiftLint's `type_body_length`, along a seam that is
/// a real one: everything here is about the **volume** rather than the image, and it is the one part
/// of a vault that `hdiutil` does not own.
///
/// Every expectation below was provoked against the real `diskutil` on macOS 26, driving a real
/// mounted sparsebundle, before any of it was written down — including the acceptances, which are
/// what stop Dirnex from inventing a rule the file system does not have.
@Suite("Vault rename")
struct VaultRenameTests {
    @Test("a rename names the mount point, and the new name is positional")
    func renameArguments() {
        #expect(DiskVolumeArguments.rename(mountPoint: "/Volumes/Personal", to: "Work")
            == ["rename", "/Volumes/Personal", "Work"])
        // Probed: `diskutil` takes a leading-dash name as the name, not as a flag — a volume really
        // was renamed to `-force`. Nothing is escaped here because nothing goes through a shell.
        #expect(DiskVolumeArguments.rename(mountPoint: "/Volumes/V", to: "-force").last == "-force")
    }

    @Test("the volume-name limit is counted in UTF-8 bytes, not characters")
    func volumeNameLength() {
        // The measured boundary, and the reason it is worth a test: 255 ASCII characters pass and
        // 256 fail, while 127 Cyrillic characters (254 bytes) pass and 128 (256 bytes) fail. A
        // character count would admit a Russian name the file system then refuses — the shape of
        // localization bug where the English case is the one that behaves.
        #expect(VolumeName.isValid(String(repeating: "x", count: 255)))
        #expect(!VolumeName.isValid(String(repeating: "x", count: 256)))
        let cyrillic127 = String(repeating: "я", count: 127)
        #expect(cyrillic127.utf8.count == 254)
        #expect(VolumeName.isValid(cyrillic127))
        #expect(!VolumeName.isValid(String(repeating: "я", count: 128)))
    }

    @Test("the names a volume cannot have")
    func volumeNameRefusals() {
        // Empty, `.` and `..` are the file system's own refusals — all three provoked against the
        // real `diskutil`, each exiting 1.
        #expect(!VolumeName.isValid(""))
        #expect(!VolumeName.isValid("."))
        #expect(!VolumeName.isValid(".."))
        // Control characters are ours. `diskutil` *accepts* these and mounts the result, giving a
        // volume whose path cannot be typed or read back in an alert.
        #expect(!VolumeName.isValid("a\nb"))
        #expect(!VolumeName.isValid("a\tb"))
    }

    @Test("what a volume may legitimately be called is not narrowed")
    func volumeNameAcceptances() {
        // Each of these was accepted by the real tool, so refusing them here would be Dirnex
        // inventing a rule. A `/` is legal and appears in the path as `:` (`/Volumes/a:b`).
        #expect(VolumeName.isValid("Work"))
        #expect(VolumeName.isValid("a/b"))
        #expect(VolumeName.isValid("a:b"))
        #expect(VolumeName.isValid("Vault 🔒"))
        #expect(VolumeName.isValid("-force"))
        #expect(VolumeName.isValid("Личное"))
    }

    @Test("surrounding whitespace is trimmed rather than refused")
    func volumeNameNormalization() {
        // `diskutil` keeps it verbatim — probed, `"  Padded  "` really does mount at
        // `/Volumes/  Padded  ` — and the create path already trims, so a vault must not be
        // renamable to something it could never have been called.
        #expect(VolumeName.normalized("  Padded  ") == "Padded")
        #expect(VolumeName.normalized("Work\n") == "Work")
        #expect(VolumeName.normalized("   ").isEmpty)
        // Interior spacing is the user's own.
        #expect(VolumeName.normalized("My Vault") == "My Vault")
    }
}
