import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// What lets an encrypted archive be opened once and then browsed (PLAN.md §M19).
///
/// The gestures themselves cannot be driven headlessly — the prompt is an `NSAlert` sheet — so what
/// is pinned here is the state the prompt writes and the state the passive paths read: the store's
/// per-archive isolation, and the extraction reuse that is the whole reason previewing a second
/// member of an encrypted archive is affordable. Both are built against a **real** AES-256 archive
/// written by `EncryptedArchiveWriter`, so the passphrase travels the same route it does in the app.
@MainActor
@Suite("Encrypted archive session")
struct ArchivePassphraseSessionTests {
    // MARK: - The store

    @Test("a passphrase is remembered for its own archive and no other")
    func storeKeysByArchive() {
        let store = ArchivePassphraseStore()
        #expect(store.passphrase(forArchiveAt: "/tmp/a.zip") == nil)

        store.remember(ArchivePassphrase("secret"), forArchiveAt: "/tmp/a.zip")
        #expect(store.passphrase(forArchiveAt: "/tmp/a.zip") != nil)
        // The archive next to it is a different secret, and an unlocked neighbour must not vouch
        // for it — otherwise one passphrase would silently unlock a folder full of archives.
        #expect(store.passphrase(forArchiveAt: "/tmp/b.zip") == nil)
    }

    // MARK: - The preview cache

    @Test("an encrypted member extracts with the passphrase and is cached")
    func encryptedMemberExtracts() async throws {
        let archive = try Fixture()
        let cache = ArchivePreviewCache()
        let member = ArchiveMember(archivePath: archive.path, innerPath: "one.txt")

        #expect(cache.cachedURL(for: member) == nil)
        let url = try await cache.extractedURL(for: member, passphrase: Fixture.passphrase)
        #expect(try String(contentsOf: url, encoding: .utf8) == "first")
        // Cached synchronously afterwards — this is what the preview surfaces read.
        #expect(cache.cachedURL(for: member) == url)
    }

    @Test("without a passphrase an encrypted member is refused, not handed to bsdtar")
    func encryptedMemberNeedsPassphrase() async throws {
        let archive = try Fixture()
        let cache = ArchivePreviewCache()
        let member = ArchiveMember(archivePath: archive.path, innerPath: "one.txt")

        // `passphraseRequired` rather than a hang: `bsdtar` re-prompts forever on a closed stdin
        // (docs/NOTES.md), so the guard being *this* error is the thing worth pinning.
        await #expect(throws: EncryptedArchiveError.passphraseRequired) {
            _ = try await cache.extractedURL(for: member)
        }
        #expect(cache.cachedURL(for: member) == nil)
    }

    @Test("a wrong passphrase reports itself as wrong, which is what drives the retry")
    func wrongPassphraseIsDistinguishable() async throws {
        let archive = try Fixture()
        let cache = ArchivePreviewCache()
        let member = ArchiveMember(archivePath: archive.path, innerPath: "one.txt")

        // `withArchivePassphrase` re-raises the prompt on exactly this case and reports every other
        // error, so a damaged archive degrading into "wrong passphrase" would loop the user forever.
        await #expect(throws: EncryptedArchiveError.incorrectPassphrase) {
            _ = try await cache.extractedURL(
                for: member, passphrase: ArchivePassphrase("not-it")
            )
        }
    }

    @Test("a second member of an encrypted archive reuses the first extraction")
    func secondMemberReusesTheExtraction() async throws {
        let archive = try Fixture()
        let cache = ArchivePreviewCache()
        let first = ArchiveMember(archivePath: archive.path, innerPath: "one.txt")
        let second = ArchiveMember(archivePath: archive.path, innerPath: "two.txt")

        let firstURL = try await cache.extractedURL(for: first, passphrase: Fixture.passphrase)
        let secondURL = try await cache.extractedURL(for: second, passphrase: Fixture.passphrase)

        #expect(try String(contentsOf: secondURL, encoding: .utf8) == "second")
        // Each extraction gets its own UUID directory, so a shared parent is the observable proof
        // that the archive was decrypted once rather than once per member — which is what keeps
        // arrowing through a large encrypted archive from re-decrypting it on every keystroke.
        #expect(firstURL.deletingLastPathComponent() == secondURL.deletingLastPathComponent())
    }

    @Test("the reuse is per archive — a second archive is extracted on its own")
    func reuseDoesNotCrossArchives() async throws {
        let one = try Fixture()
        let other = try Fixture()
        let cache = ArchivePreviewCache()

        let fromOne = try await cache.extractedURL(
            for: ArchiveMember(archivePath: one.path, innerPath: "one.txt"),
            passphrase: Fixture.passphrase
        )
        let fromOther = try await cache.extractedURL(
            for: ArchiveMember(archivePath: other.path, innerPath: "one.txt"),
            passphrase: Fixture.passphrase
        )
        #expect(fromOne.deletingLastPathComponent() != fromOther.deletingLastPathComponent())
    }

    /// A real AES-256 zip holding two named members, written by the app's own writer so the
    /// passphrase takes the route it takes in production. Removed with the test's temp directory.
    private struct Fixture {
        static let passphrase = ArchivePassphrase("correct horse")

        let directory: URL
        let path: String

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("DirnexArchiveSessionTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let source = directory.appendingPathComponent("source", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try "first".write(
                to: source.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8
            )
            try "second".write(
                to: source.appendingPathComponent("two.txt"), atomically: true, encoding: .utf8
            )

            path = directory.appendingPathComponent("fixture.zip").path
            try EncryptedArchiveWriter.write(
                items: try ArchiveSourceEnumerator.items(
                    inDirectory: source.path, names: ["one.txt", "two.txt"]
                ),
                toArchiveAt: path,
                encryption: .aes256,
                passphrase: Self.passphrase
            )
        }
    }
}
