import DirnexCore
import Foundation

@testable import Dirnex

/// What the login Keychain held for the live fixture's account before any live S3 test ran, put
/// back as the test host exits.
///
/// The flows under test file a secret on every successful connect — that is what makes walking out
/// of a bucket work at all — so a run leaves live-looking credentials in whoever's Keychain ran it.
/// Both live suites used to clear that up by *deleting* the two items, on the stated assumption that
/// the fixture names a scratch endpoint nobody uses and the items are therefore the suite's own.
///
/// **That assumption is not the fixture's to keep, and when it breaks the suite logs the user out of
/// their own server.** The key is `accessKeyID@host:port/region[/bucket]`
/// (``S3Location/keychainAccount``) — a fact about the *account*, not about who filed it — so a
/// fixture pointing at an account the person also browses addresses the very item their saved
/// sidebar row depends on. Found 2026-08-20: clicking the saved Amazon row re-opened the prefilled
/// Connect sheet with the secret blank, on every build, because `xcodebuild test` had removed the
/// item behind it. Nothing logs, both suites stay green, and it reads as the app never having saved
/// the credential at all.
///
/// Capture-and-restore is right whichever the fixture names, which is why it replaces the delete
/// rather than sitting beside it: an item the suite *created* still goes away (there was nothing to
/// put back), and one it merely overwrote is returned to the value it had.
///
/// **Once for the process, not once per test — measured, because the obvious shape does not work.**
/// The first version captured in each suite instance's `init` and restored in its `deinit`, which is
/// where a per-test fixture belongs and is wrong here for a reason `.serialized` does not cover:
/// that trait orders a suite's own tests and says nothing about two *suites*, and these two run
/// concurrently against the one item. Run that way, an instance starting mid-flight captures the
/// secret a neighbour has already written and dutifully "restores" it at the end. Verified against a
/// sentinel value filed before the run: the bucket item came back and the account item came out
/// holding the fixture's secret.
enum S3LiveKeychainSnapshot {
    /// Read the two items the live suites write, and arrange for them to be put back. Call it from
    /// every live suite's `init`; only the first call does anything.
    ///
    /// A `static let`'s initializer runs exactly once however many tests race into it, which is the
    /// whole reason the capture is expressed as one — there is no window in which a second capture
    /// could read a value the flows have already replaced.
    static func arm() { _ = armed }

    private static let armed: Void = {
        guard let config = S3LiveEnvironment.current else { return }
        captured = Captured(
            account: SecretKeychain.password(for: config.account),
            bucket: SecretKeychain.password(for: config.account.bucketLocation(named: config.bucket))
        )
        // `atexit` rather than a teardown hook because the restore has to happen when nothing can
        // still be *using* the item: any earlier point is inside somebody's test. It fires in this
        // host (docs/NOTES.md ▸ AppKit records a handler running under `NSApplication.terminate:`),
        // and if it ever did not the run would leave the fixture's own secret filed — clutter, where
        // the version this replaced left the user with nothing.
        atexit { S3LiveKeychainSnapshot.restore() }
    }()

    private struct Captured {
        let account: String?
        let bucket: String?
    }

    /// Written once inside `armed`'s initializer and read once from the `atexit` handler, so the
    /// `once` that runs the former happens-before the latter and there is nothing to synchronize.
    nonisolated(unsafe) private static var captured: Captured?

    private static func restore() {
        guard let config = S3LiveEnvironment.current, let captured else { return }
        put(captured.account, for: config.account)
        put(captured.bucket, for: config.account.bucketLocation(named: config.bucket))
    }

    /// Restore one item, and **only if it actually changed**.
    ///
    /// The guard is not an optimization. `SecretKeychain.store` deletes before it adds, so writing a
    /// value back over itself is a delete-and-re-add of an item nothing touched — a step that can
    /// only lose it, on the exact item this type exists to protect.
    private static func put(_ secret: String?, for location: some KeychainAddressable) {
        guard SecretKeychain.password(for: location) != secret else { return }
        if let secret {
            SecretKeychain.store(password: secret, for: location)
        } else {
            SecretKeychain.removePassword(for: location)
        }
    }
}
