import Foundation
import Testing

@testable import DirnexCore

/// The plists here came out of a **real `hdiutil`**, driving a real encrypted APFS sparsebundle
/// created and attached for the purpose, not from a hand-written imitation — the same standard the
/// `.DS_Store` and `bsdtar` fixtures are held to. `hdiutil-info.plist` is filtered to the one probe
/// image, because the raw output lists every image attached on the machine that captured it.
@Suite("Vault")
struct VaultTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "plist", subdirectory: "Fixtures"),
            "missing fixture \(name).plist"
        )
        return try Data(contentsOf: url)
    }

    // MARK: - Arguments

    @Test("no argument list can carry the passphrase")
    func passphraseIsNeverAnArgument() {
        // The property the whole design rests on, asserted rather than trusted to review. Every
        // builder is covered, and each uses `-stdinpass`, which is what makes it true.
        let commands = [
            DiskImageArguments.create(
                atPath: "/tmp/v.sparsebundle", volumeName: "Vault", kind: .sparseBundle,
                megabytes: 512
            ),
            DiskImageArguments.attach(atPath: "/tmp/v.sparsebundle", showingInFinder: false),
            DiskImageArguments.detach(mountPoint: "/Volumes/Vault"),
            DiskImageArguments.info()
        ]
        for command in commands {
            #expect(!command.contains { $0.lowercased().contains("passw") })
            #expect(!command.contains("-passphrase"))
        }
        #expect(DiskImageArguments.create(
            atPath: "/tmp/v.sparsebundle", volumeName: "Vault", kind: .sparseBundle, megabytes: 512
        ).contains("-stdinpass"))
        #expect(
            DiskImageArguments.attach(atPath: "/tmp/v.sparsebundle", showingInFinder: true)
                .contains("-stdinpass")
        )
    }

    @Test("the bytes written to hdiutil's stdin are the passphrase and nothing else")
    func passphraseBytesCarryNoTerminator() {
        // `hdiutil -stdinpass` takes that pipe verbatim to EOF — probed: an image created with a
        // trailing newline refuses to attach without one. So a NUL or a newline riding along is not
        // a tidiness question, it is a vault that stops opening to the phrase its owner typed.
        let passphrase = ArchivePassphrase("hunter2")
        let bytes = passphrase.withUnsafeBytes { Array($0) }
        #expect(bytes == Array("hunter2".utf8))
        #expect(!bytes.contains(0))
        #expect(!bytes.contains(UInt8(ascii: "\n")))

        // A passphrase that genuinely ends in a newline keeps it: the rule is "exactly the bytes",
        // not "strip trailing whitespace", which would be a second way to lock someone out.
        let awkward = ArchivePassphrase("two lines\n")
        #expect(awkward.withUnsafeBytes { Array($0) } == Array("two lines\n".utf8))

        #expect(ArchivePassphrase("").withUnsafeBytes(\.count) == 0)
        // Multi-byte UTF-8 counts bytes, not characters — what the pipe carries.
        #expect(ArchivePassphrase("пароль").withUnsafeBytes(\.count) == 12)
    }

    @Test("create asks for AES-256, an APFS sparsebundle, and machine-readable progress")
    func createArguments() {
        let argv = DiskImageArguments.create(
            atPath: "/vaults/Personal.sparsebundle",
            volumeName: "Personal", kind: .sparseBundle, megabytes: 10240
        )
        #expect(argv.first == "create")
        #expect(argv.contains("-encryption"))
        #expect(argv.contains("AES-256"))
        #expect(argv.contains("SPARSEBUNDLE"))
        #expect(argv.contains("10240m"))
        #expect(argv.contains("APFS"))
        #expect(argv.contains("-puppetstrings"))
        #expect(argv.last == "/vaults/Personal.sparsebundle")
    }

    @Test("an unlocked vault stays out of every other app's sidebar when it is told to")
    func attachIsNoBrowse() {
        // Whether it is told to is the app's **Show unlocked vaults in Finder** preference; what
        // that answer *does* is here, and in `VaultVisibilityTests` for the other direction.
        let argv = DiskImageArguments.attach(
            atPath: "/vaults/Personal.sparsebundle",
            showingInFinder: false
        )
        #expect(argv.contains("-nobrowse"))
        #expect(argv.contains("-plist"))
    }

    @Test("the vault's file name gains the right extension exactly once")
    func vaultPath() {
        #expect(
            DiskImageArguments.vaultPath(inDirectory: "/v", named: "Personal", kind: .sparseBundle)
                == "/v/Personal.sparsebundle"
        )
        #expect(DiskImageArguments.vaultPath(
            inDirectory: "/v", named: "Personal.sparsebundle", kind: .sparseBundle
        ) == "/v/Personal.sparsebundle")
        #expect(DiskImageArguments.vaultPath(inDirectory: "/v", named: "Personal", kind: .fixed)
            == "/v/Personal.dmg")
        #expect(DiskImageArguments.vaultPath(inDirectory: "/v", named: "  ", kind: .sparseBundle)
            == "/v/Vault.sparsebundle")
    }

    @Test("a vault image is recognized by suffix, case-insensitively, and nothing else is")
    func imageNames() {
        // The one spelling of "this could be a vault image", asked by the Unlock command and by the
        // pane's Enter. The negatives are the ones that matter: Enter routes a *saved* vault to the
        // unlock funnel and everything else to the ordinary directory walk, so a false positive here
        // would send a plain folder somewhere it has no business going.
        #expect(DiskImageArguments.Kind.isImageName("SecDocs.sparsebundle"))
        #expect(DiskImageArguments.Kind.isImageName("Personal.dmg"))
        #expect(DiskImageArguments.Kind.isImageName("SHOUTING.DMG"))
        #expect(DiskImageArguments.Kind.isImageName("Mixed.SparseBundle"))
        #expect(!DiskImageArguments.Kind.isImageName("Documents"))
        #expect(!DiskImageArguments.Kind.isImageName("notes.dmg.txt"))
        // A `.sparseimage` is a disk image and is *not* a shape Dirnex creates, so it is not one of
        // the two suffixes — asserted so widening `Kind` is a deliberate edit rather than a surprise.
        #expect(!DiskImageArguments.Kind.isImageName("old.sparseimage"))
        for kind in DiskImageArguments.Kind.allCases {
            #expect(DiskImageArguments.Kind.isImageName("Vault.\(kind.pathExtension)"))
        }
    }

    // MARK: - Reading hdiutil's answers

    @Test("the mount point is found among the several entities an attach reports")
    func mountPointFromAttach() throws {
        let mounted = try #require(
            DiskImageMount.mountPoint(fromAttachPlist: try fixture("hdiutil-attach"))
        )
        #expect(mounted.mountPoint == "/Volumes/ProbeVault")
        // The real capture listed three entities and only the third carried a mount point; taking
        // the first would have returned the GUID partition scheme and no mount point at all.
        #expect(mounted.deviceEntry?.hasPrefix("/dev/disk") == true)
    }

    @Test("hdiutil info names the image, its mount point, and that it is encrypted")
    func attachedImagesFromInfo() throws {
        let images = DiskImageMount.attachedImages(fromInfoPlist: try fixture("hdiutil-info"))
        let image = try #require(images.first)
        #expect(image.imagePath.hasSuffix("v.sparsebundle"))
        #expect(image.isEncrypted)
        #expect(image.mountPoint == "/Volumes/ProbeVault")
    }

    @Test("a vault reached through a symlinked path is recognized as the mounted one")
    func mountedMatchResolvesSymlinks() throws {
        let images = DiskImageMount.attachedImages(fromInfoPlist: try fixture("hdiutil-info"))
        // `hdiutil` answers with the resolved path (`/private/tmp/…`) while a user — and Dirnex's
        // own path bar — says `/tmp/…`. `/tmp` is a symlink on every Mac, so a string comparison
        // reports a mounted vault as locked and Unlock appears to do nothing.
        #expect(DiskImageMount.isMounted(imageAtPath: "/tmp/vaultprobe/v.sparsebundle", in: images)
            == "/Volumes/ProbeVault")
        #expect(DiskImageMount.isMounted(
            imageAtPath: "/private/tmp/vaultprobe/v.sparsebundle", in: images
        ) == "/Volumes/ProbeVault")
        #expect(DiskImageMount.isMounted(imageAtPath: "/tmp/other.sparsebundle", in: images) == nil)
    }

    @Test("malformed output yields nothing rather than a wrong answer")
    func garbageInput() {
        #expect(DiskImageMount.mountPoint(fromAttachPlist: Data("not a plist".utf8)) == nil)
        #expect(DiskImageMount.attachedImages(fromInfoPlist: Data()).isEmpty)
    }

    // MARK: - Progress

    @Test("-1 is a sentinel, not a percentage")
    func progressSentinel() {
        // It brackets a real run at both ends. Read literally it drives the bar to −1 % at the
        // start and back to −1 % at the very end, which reads as failure at the moment of success.
        #expect(DiskImageProgress.parse("PERCENT:-1.000000") == .indeterminate)
        #expect(DiskImageProgress.parse("PERCENT:0.000000") == .fraction(0))
    }

    @Test("a real captured transcript yields a monotonic run of fractions")
    func progressTranscript() throws {
        // Exactly the lines a 200 MB create produced, in order — repeats included.
        let output = """
        PERCENT:-1.000000
        PERCENT:-1.000000
        PERCENT:0.000000
        PERCENT:25.897619
        PERCENT:49.376678
        PERCENT:91.117226
        PERCENT:91.117226
        PERCENT:-1.000000
        created: /tmp/vaultprobe/v.sparsebundle
        """
        let fractions = output.split(whereSeparator: \.isNewline).compactMap { line -> Double? in
            guard case let .fraction(value) = DiskImageProgress.parse(String(line)) else { return nil }
            return value
        }
        #expect(fractions.count == 5)
        #expect(fractions.first == 0)
        let sorted = zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 }
        #expect(sorted, "a bar driven from these must never move backwards")
        // Compared with a tolerance: 91.117226 / 100 is 0.9111722600000001 in binary floating point,
        // and pinning the exact literal tests the arithmetic rather than the parser.
        let last = try #require(fractions.last)
        #expect(abs(last - 0.91117226) < 1e-9)
    }

    @Test("anything that is not a percentage is kept, not silently dropped")
    func progressOtherLines() {
        #expect(DiskImageProgress.parse("created: /tmp/v.sparsebundle")
            == .other("created: /tmp/v.sparsebundle"))
        #expect(DiskImageProgress.parse("PERCENT:not-a-number") == .other("PERCENT:not-a-number"))
    }

    // MARK: - Errors

    @Test("a wrong passphrase is told apart from a missing file, though both exit 1")
    func attachFailureClassification() {
        // Both were provoked against the real tool; the exit code is identical and only the message
        // separates them.
        #expect(VaultError.fromAttachFailure(
            exitCode: 1, stderr: "hdiutil: attach failed - Authentication error", name: "V"
        ) == .incorrectPassphrase)
        #expect(VaultError.fromAttachFailure(
            exitCode: 1, stderr: "hdiutil: attach failed - No such file or directory", name: "V"
        ) == .imageUnreadable(name: "V"))
        #expect(VaultError.fromAttachFailure(
            exitCode: 1, stderr: "hdiutil: attach failed - something new", name: "V"
        ) == .couldNotUnlock)
    }

    @Test("locking an already-locked vault is success")
    func detachIdempotence() {
        // Probed: the second detach exits 1 and says "No such file or directory". The user's intent
        // is already satisfied, so reporting an error would make a second Lock — or a Lock after
        // ejecting in Finder — look broken.
        #expect(VaultError.fromDetachFailure(
            exitCode: 1, stderr: "hdiutil: detach failed - No such file or directory", name: "V"
        ) == nil)
        #expect(VaultError.fromDetachFailure(exitCode: 0, stderr: "", name: "V") == nil)
        #expect(VaultError.fromDetachFailure(
            exitCode: 1, stderr: "hdiutil: detach failed - Resource busy", name: "V"
        ) == .volumeInUse(name: "V"))
    }

    @Test("every error carries a distinct key and a sentence with matching placeholders")
    func errorVocabulary() {
        let keys = VaultError.allCases.map(\.key)
        #expect(Set(keys).count == keys.count)
        for error in VaultError.allCases {
            #expect(!error.sentence.isEmpty)
            #expect(error.englishFormat.components(separatedBy: "%@").count - 1
                == error.arguments.count)
        }
    }

    // MARK: - Identity

    @Test("path normalization does not depend on whether the file is there")
    func normalizationIsExistenceIndependent() {
        // The property Foundation does not have. Probed on macOS 26: both
        // `URL.resolvingSymlinksInPath()` and `NSString.standardizingPath` fold `/private/tmp` to
        // `/tmp` for a path that exists and leave it alone for one that does not — so a vault's
        // Keychain key would change the moment it was moved or deleted, which is exactly when its
        // stored passphrase has to be findable in order to be cleaned up.
        let absent = "/private/tmp/definitely-not-here-\(UUID().uuidString)/v.sparsebundle"
        #expect(!FileManager.default.fileExists(atPath: absent))
        #expect(VaultLocation.normalizedPath(absent).hasPrefix("/tmp/"))

        #expect(VaultLocation.normalizedPath("/private/var/x") == "/var/x")
        #expect(VaultLocation.normalizedPath("/private/etc/hosts") == "/etc/hosts")
        // Only the three firmlink prefixes fold; nothing else is rewritten.
        #expect(VaultLocation.normalizedPath("/private/other/x") == "/private/other/x")
        #expect(
            VaultLocation.normalizedPath("/Users/oleg/v.sparsebundle") == "/Users/oleg/v.sparsebundle"
        )
    }

    @Test("a vault is keyed in the Keychain by its resolved path, so one vault is one item")
    func keychainAccountIsResolved() {
        let viaSymlink = VaultLocation(
            imagePath: "/tmp/Personal.sparsebundle",
            volumeName: "Personal"
        )
        let viaReal = VaultLocation(
            imagePath: "/private/tmp/Personal.sparsebundle", volumeName: "Personal"
        )
        #expect(viaSymlink.keychainAccount == viaReal.keychainAccount)
        #expect(viaSymlink.fileName == "Personal.sparsebundle")
        #expect(VaultLocation.keychainService != SFTPLocation.keychainService)
    }
}
