import DirnexCore
import Foundation
import Security

/// Stores an SFTP account's password in the login Keychain (PLAN.md §M5 "keychain-stored password
/// auth"), keyed by the account's stable `keychainAccount` under `SFTPLocation.keychainService`.
/// A generic-password item, so the password survives relaunches and a future saved-connection can
/// reconnect without re-prompting — the plaintext never touches Dirnex's own files.
///
/// The value comes from the user typing into the Connect-to-Server dialog and is filed into the
/// user's own Keychain; Dirnex only moves it between the dialog, the Keychain, and the `sftp`
/// process it spawns.
enum SFTPKeychain {
    /// Save (replacing any existing) the password for `location`. Failures are swallowed — a
    /// Keychain that won't persist shouldn't block an otherwise-good connection (the live session
    /// keeps the password in memory regardless); the return value reports success for callers that
    /// want to surface it.
    @discardableResult
    static func store(password: String, for location: SFTPLocation) -> Bool {
        removePassword(for: location)
        var attributes = baseQuery(for: location)
        attributes[kSecValueData as String] = Data(password.utf8)
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    /// The stored password for `location`, or `nil` if none is filed (or the item can't be read).
    static func password(for location: SFTPLocation) -> String? {
        var query = baseQuery(for: location)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Remove any stored password for `location` (a no-op if none exists).
    static func removePassword(for location: SFTPLocation) {
        SecItemDelete(baseQuery(for: location) as CFDictionary)
    }

    private static func baseQuery(for location: SFTPLocation) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SFTPLocation.keychainService,
            kSecAttrAccount as String: location.keychainAccount
        ]
    }
}
