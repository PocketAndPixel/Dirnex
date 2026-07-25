import DirnexCore
import Foundation
import Security

/// Stores an FTP account's password in the login Keychain, keyed by the account's stable
/// `keychainAccount` under `FTPLocation.keychainService` — the FTP twin of `SFTPKeychain`, and
/// deliberately the same shape.
///
/// Two FTP-specific notes. The key includes the **security mode**, so the same account reached over
/// plain FTP and over FTPS keeps separate entries: they are separate trust decisions and may
/// genuinely hold different passwords. And an **anonymous** login stores nothing at all — its
/// password is a convention, not a secret, so there is nothing to file.
///
/// The value comes from the user typing into the Connect-to-Server dialog and is filed into the
/// user's own Keychain; Dirnex only moves it between the dialog, the Keychain, and the `curl`
/// process it spawns (on stdin — never in `argv`, never on disk).
enum FTPKeychain {
    /// Save (replacing any existing) the password for `location`. Failures are swallowed — a
    /// Keychain that won't persist shouldn't block an otherwise-good connection (the live session
    /// keeps the password in memory regardless); the return value reports success for callers that
    /// want to surface it.
    @discardableResult
    static func store(password: String, for location: FTPLocation) -> Bool {
        guard !location.isAnonymous else { return true }
        removePassword(for: location)
        var attributes = baseQuery(for: location)
        attributes[kSecValueData as String] = Data(password.utf8)
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    /// The stored password for `location`, or `nil` if none is filed (or the item can't be read).
    static func password(for location: FTPLocation) -> String? {
        guard !location.isAnonymous else { return nil }
        var query = baseQuery(for: location)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Remove any stored password for `location` (a no-op if none exists).
    static func removePassword(for location: FTPLocation) {
        SecItemDelete(baseQuery(for: location) as CFDictionary)
    }

    private static func baseQuery(for location: FTPLocation) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: FTPLocation.keychainService,
            kSecAttrAccount as String: location.keychainAccount
        ]
    }
}
