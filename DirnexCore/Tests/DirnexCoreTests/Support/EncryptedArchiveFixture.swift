import Foundation
import Testing

@testable import DirnexCore

/// The committed archives and the scratch directory the `EncryptedArchiveReader` suites share.
///
/// Shared rather than duplicated because the suites are one subject seen from two sides — what a
/// full extraction produces (`EncryptedArchiveReaderTests`) and what a *filtered* one leaves in the
/// archive (`EncryptedArchiveReaderMemberFilterTests`) — and Swift's `private` does not cross files,
/// so the alternative is two copies of "where the fixtures live" drifting apart.
///
/// The archives were written by **`bsdtar`**, not by `EncryptedArchiveWriter`, which is the whole
/// point of committing them: a reader checked against our own writer proves the two agree, and a
/// shared misunderstanding of the format produces exactly that agreement.
///
///     bsdtar -c -f encrypted-aes256-bsdtar.zip --format zip \
///            --options zip:encryption=aes256 --passphrase 'dirnex-test-passphrase' \
///            -C <staging> notes link.txt
///
/// holding `notes/hello.txt` (18 bytes), `notes/nested/deep.txt` (11 bytes), the two directories,
/// and `link.txt` → `notes/hello.txt`.
enum EncryptedArchiveFixture {
    static let passphrase = "dirnex-test-passphrase"

    static func archive(_ name: String) throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "zip", subdirectory: "Fixtures"),
            "missing fixture \(name).zip"
        )
        return url.path
    }

    static func scratchDirectory() throws -> String {
        let path = NSTemporaryDirectory() + "dirnex-reader-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    static func remove(_ path: String) { try? FileManager.default.removeItem(atPath: path) }

    static func contents(of path: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
    }

    /// `lstat` rather than `FileManager.fileExists`, which follows a symlink — and one of the
    /// fixture's five entries is a symlink whose target is a *sibling* the filter may have left in
    /// the archive. Asked the other way, "did we place `link.txt`" would answer no for a link that
    /// was placed perfectly.
    static func exists(_ path: String) -> Bool {
        var status = stat()
        return lstat(path, &status) == 0
    }
}
