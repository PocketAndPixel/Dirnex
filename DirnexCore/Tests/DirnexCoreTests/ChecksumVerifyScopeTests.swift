import Foundation
import Testing

@testable import DirnexCore

/// Which files a verification will look at, worked out before a byte is read (PLAN.md §M24
/// Slice 4).
///
/// This was private to `ChecksumVerifyRun` while the only caller was the loop about to run it.
/// Verifying a manifest that is not on this disk is two-phase, so the *gesture* has to work out the
/// same set in order to weigh and confirm it — and the claims below are the ones both halves rest
/// on. The walk is driven through a listing closure over literal entries: no temp tree, no backend,
/// and a remote root, which is the case the whole slice exists for.
@Suite("Checksum verify scope")
struct ChecksumVerifyScopeTests {
    private let store = FakeRemoteStore([
        "/data/a.bin": "alpha\n",
        "/data/b.bin": "beta contents\n",
        "/data/extra.bin": "not in the manifest\n",
        "/data/.DS_Store": "noise\n",
        "/data/files.sha256": "",
        "/data/sub/deep.bin": "deep\n",
        "/data/unmentioned/x.bin": "never walked\n"
    ])

    private func resolve(_ manifest: String) throws -> ChecksumVerifyScope {
        try ChecksumVerifyScope.resolve(
            manifestAt: store.path("/data/files.sha256"),
            contents: Data(manifest.utf8),
            list: { (try? store.listDirectory(at: $0)) ?? [] }
        )
    }

    /// The two digests are `shasum -a 256` over the same bytes — never this engine's own output, so
    /// the fixture cannot merely agree with the thing it is checking.
    private static let alpha = "b6a98d9ce9a2d9149288fa3df42d377c3e42737afdcdaf714e33c0a100b51060"
    private static let beta = "1e6f53bf8c3e3704ca99c5e692d8745b54ed7ec0d83064484a5fb1ce6c7355a8"

    // MARK: - What gets hashed

    /// The set a remote verification has to bring down, and the reason the type is public: only
    /// what the manifest **claims** and the walk **found**.
    @Test("the claimed set is what the manifest names and the walk found, under the remote names")
    func claimsWhatTheManifestNames() throws {
        let scope = try resolve("\(Self.alpha)  a.bin\n\(Self.beta)  b.bin\n")

        #expect(scope.claimed.map(\.name) == ["a.bin", "b.bin"])
        #expect(scope.claimed.map(\.entry.path) == [
            store.path("/data/a.bin"), store.path("/data/b.bin")
        ])
    }

    /// A name in the manifest with no file beside it is `missing`, not something to fetch — and a
    /// gesture that tried to fetch it would report a transfer failure for a file that is simply
    /// absent.
    @Test("a name with no file behind it is not something to fetch")
    func absentNamesAreNotClaimed() throws {
        let scope = try resolve("\(Self.alpha)  a.bin\n\(Self.beta)  gone.bin\n")
        #expect(scope.claimed.map(\.name) == ["a.bin"])
    }

    // MARK: - What the verdict compares against

    /// The siblings are what make an `extra` verdict mean anything; the manifest itself and an
    /// unnamed dotfile are not extras, they are noise on the one row guaranteed to appear.
    @Test("the listing carries siblings but drops the manifest and unnamed hidden files")
    func listingIsTheComparableSet() throws {
        let scope = try resolve("\(Self.alpha)  a.bin\n")

        #expect(scope.listing.contains("extra.bin"))
        #expect(!scope.listing.contains("files.sha256"))
        #expect(!scope.listing.contains(".DS_Store"))
    }

    /// A manifest describing a tree has its extras in that tree; one that never mentions a subtree
    /// must not have it walked, or a one-line manifest reports every file under it.
    @Test("only subtrees the manifest mentions are walked")
    func descendsOnlyWhereNamed() throws {
        let scope = try resolve("\(Self.alpha)  sub/deep.bin\n")

        #expect(scope.claimed.map(\.name) == ["sub/deep.bin"])
        #expect(!scope.listing.contains { $0.hasPrefix("unmentioned/") })
    }

    // MARK: - Refusing

    /// The job's own failure, distinct from any path's — and the reason a gesture can report it
    /// without having queued anything.
    @Test("a file with no checksum lines throws rather than resolving to nothing")
    func unreadableManifestThrows() {
        #expect(throws: ChecksumError.manifestUnreadable) {
            _ = try resolve("this is just prose\nand so is this\n")
        }
    }

    @Test("a manifest mixing digest widths throws with both algorithms named")
    func mixedAlgorithmsThrow() {
        #expect(throws: ChecksumError.self) {
            _ = try resolve("\(Self.alpha)  a.bin\nd41d8cd98f00b204e9800998ecf8427e  b.bin\n")
        }
    }

    /// The manifest names its own algorithm, and nothing may override it: a caller that could
    /// would verify a SHA-256 file as MD5 and report every line as a mismatch.
    @Test("the algorithm comes out of the manifest")
    func algorithmComesFromTheManifest() throws {
        let scope = try resolve("\(Self.alpha)  a.bin\n")
        #expect(scope.manifest.algorithm == .sha256)
    }
}
