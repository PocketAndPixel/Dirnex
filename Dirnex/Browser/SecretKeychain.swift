import DirnexCore
import Foundation
import Security

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
enum SecretKeychain {
    /// Save (replacing any existing) the password for `location`. Failures are swallowed — a
    /// Keychain that won't persist shouldn't block an otherwise-good connection, since the live
    /// session keeps the password in memory regardless; the return value reports success for callers
    /// that want to surface it.
    @discardableResult
    static func store(password: String, for location: some KeychainAddressable) -> Bool {
        guard !location.hasNoStoredSecret else { return true }
        removePassword(for: location)
        var attributes = baseQuery(for: location)
        attributes[kSecValueData as String] = Data(password.utf8)
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    /// The stored password for `location`, or `nil` if none is filed (or the item can't be read).
    static func password(for location: some KeychainAddressable) -> String? {
        guard !location.hasNoStoredSecret else { return nil }
        var query = baseQuery(for: location)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
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
        removePassword(for: location)
        var attributes = baseQuery(for: location)
        attributes[kSecValueData as String] = passphrase.withUnsafeBytes { Data($0) }
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    /// The stored passphrase for `location`, or `nil` if none is filed.
    static func passphrase(for location: some KeychainAddressable) -> ArchivePassphrase? {
        var query = baseQuery(for: location)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, !data.isEmpty else { return nil }
        return ArchivePassphrase(bytes: data)
    }

    /// Remove any stored password for `location` (a no-op if none exists).
    static func removePassword(for location: some KeychainAddressable) {
        SecItemDelete(baseQuery(for: location) as CFDictionary)
    }

    private static func baseQuery(for location: some KeychainAddressable) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: type(of: location).keychainService,
            kSecAttrAccount as String: location.keychainAccount
        ]
    }
}
