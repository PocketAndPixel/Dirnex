import DirnexCore
import Foundation
import Security

/// Stores an SMB share's password in the login Keychain, keyed by the share's stable
/// `keychainAccount` under `SMBLocation.keychainService` — the SMB analogue of `SFTPKeychain`, so a
/// saved server reconnects (re-mounts) later without re-prompting. A guest mount has no secret and
/// never touches this. The plaintext comes from the Connect-to-Server dialog and is filed into the
/// user's own Keychain; Dirnex only moves it between the dialog, the Keychain, and the NetFS mount.
enum SMBKeychain {
    /// Save (replacing any existing) the password for `location`. Failures are swallowed — a
    /// Keychain that won't persist shouldn't block an otherwise-good mount; the return value reports
    /// success for callers that want to surface it.
    @discardableResult
    static func store(password: String, for location: SMBLocation) -> Bool {
        removePassword(for: location)
        var attributes = baseQuery(for: location)
        attributes[kSecValueData as String] = Data(password.utf8)
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    /// The stored password for `location`, or `nil` if none is filed (or the item can't be read).
    static func password(for location: SMBLocation) -> String? {
        var query = baseQuery(for: location)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Remove any stored password for `location` (a no-op if none exists).
    static func removePassword(for location: SMBLocation) {
        SecItemDelete(baseQuery(for: location) as CFDictionary)
    }

    private static func baseQuery(for location: SMBLocation) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SMBLocation.keychainService,
            kSecAttrAccount as String: location.keychainAccount
        ]
    }
}
