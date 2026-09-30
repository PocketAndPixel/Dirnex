import DirnexCore
import Foundation

/// Stores a secret in the login Keychain for anything that has a stable address — every server
/// protocol Dirnex connects with (PLAN.md §M5 "keychain-stored password auth", extended to FTP and
/// SMB) and, since M19, a vault's passphrase.
///
/// A generic-password item keyed by the location's own `keychainService`/`keychainAccount`
/// (`KeychainAddressable`), so the secret survives relaunches and a saved connection reconnects —
/// or re-mounts, or unlocks — without re-prompting. The plaintext never touches Dirnex's own files:
/// it comes from the user typing into a dialog and goes to the user's own Keychain, and Dirnex only
/// moves it between the dialog, the Keychain, and the thing that needs it (`sftp`'s, `curl`'s and
/// `hdiutil`'s stdin — never `argv`, never disk — or the NetFS mount).
///
/// This was three files, one per protocol, differing only in the location type. The Keychain call is
/// the same call whatever is being filed; what differs per kind is the *key*, which is why that half
/// lives on the location in the core and this half is generic over it. The type was named
/// `ServerKeychain` until a vault — which is not a server — needed the identical call.
///
/// The Security-framework calls themselves sit one layer down, behind ``SecretStoring``, so a test
/// host can run on a dictionary instead of the user's login Keychain — see ``InMemorySecretStore``
/// for what that is worth beyond skipping a dialog.
enum SecretKeychain {
    /// Save (replacing any existing) the password for `location`. Failures are swallowed — a
    /// Keychain that won't persist shouldn't block an otherwise-good connection, since the live
    /// session keeps the password in memory regardless; the return value reports success for callers
    /// that want to surface it.
    @discardableResult
    static func store(password: String, for location: some KeychainAddressable) -> Bool {
        guard !location.hasNoStoredSecret else { return true }
        return set(Data(password.utf8), for: location)
    }

    /// The stored password for `location`, or `nil` if none is filed (or the item can't be read).
    static func password(for location: some KeychainAddressable) -> String? {
        guard !location.hasNoStoredSecret, let data = secret(for: location) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Save a vault's passphrase without it ever being a `String`.
    ///
    /// The `String` overload above is right for a server password, which arrives as one from a text
    /// field and is handed to `sftp`/`curl` as one. A vault's is an ``ArchivePassphrase`` from the
    /// moment it leaves the field, and putting it back into the value world to file it would undo
    /// exactly what that type is for — so the bytes go straight from its buffer into the Keychain
    /// item, and come back the same way in ``passphrase(for:)``.
    @discardableResult
    static func store(
        passphrase: ArchivePassphrase,
        for location: some KeychainAddressable
    ) -> Bool {
        set(passphrase.withUnsafeBytes { Data($0) }, for: location)
    }

    /// The stored passphrase for `location`, or `nil` if none is filed.
    static func passphrase(for location: some KeychainAddressable) -> ArchivePassphrase? {
        guard let data = secret(for: location), !data.isEmpty else { return nil }
        return ArchivePassphrase(bytes: data)
    }

    /// Remove any stored password for `location` (a no-op if none exists).
    static func removePassword(for location: some KeychainAddressable) {
        set(nil, for: location)
    }

    // MARK: - The store underneath

    /// Where the bytes go. Resolved **once**, as a `static let`, which is what makes it both
    /// race-free and impossible for a test to forget to arrange.
    ///
    /// A test host gets ``InMemorySecretStore`` — see that type for why reading the real Keychain
    /// from a rebuilt binary stops a run dead, and for the user's own credential it used to
    /// overwrite. Everything else gets the login Keychain.
    static let backing: any SecretStoring =
        usesInMemoryStore(ProcessInfo.processInfo.environment)
            ? InMemorySecretStore()
            : KeychainSecretStore()

    /// Whether this process is a test host: XCTest sets that key in the runner it injects, **and**
    /// its framework is loaded.
    ///
    /// Two signals rather than one because the two ways of being wrong cost wildly different things.
    /// A false *negative* brings the dialog back — loud, and `SecretStoreTests` fails on it the same
    /// run. A false *positive* would put the shipping app on a dictionary, so a user's passwords
    /// would stop being saved with nothing on screen to say so; requiring the framework to actually
    /// be present rules that out even for someone who happens to have the variable exported in the
    /// shell they launch from.
    ///
    /// Both inputs are parameters so both directions are assertable without arranging a process.
    static func usesInMemoryStore(
        _ environment: [String: String],
        xctestLoaded: Bool = NSClassFromString("XCTestCase") != nil
    ) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil && xctestLoaded
    }

    private static func secret(for location: some KeychainAddressable) -> Data? {
        backing.secret(
            service: type(of: location).keychainService,
            account: location.keychainAccount
        )
    }

    @discardableResult
    private static func set(_ data: Data?, for location: some KeychainAddressable) -> Bool {
        backing.setSecret(
            data,
            service: type(of: location).keychainService,
            account: location.keychainAccount
        )
    }
}
