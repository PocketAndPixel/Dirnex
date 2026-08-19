import Foundation
import Security

/// Where ``SecretKeychain`` actually puts the bytes: the login Keychain in the app, an in-memory
/// stand-in under tests.
///
/// The seam is deliberately *below* `SecretKeychain` rather than beside it. Everything worth keeping
/// in one place — which locations have no secret to file, that a vault's passphrase never becomes a
/// `String`, that a store is a delete-then-add — is generic over `KeychainAddressable` and stays
/// there; what varies is only where a `(service, account)` pair's bytes live. So a stand-in is a
/// dictionary rather than a second copy of that reasoning.
protocol SecretStoring: Sendable {
    func secret(service: String, account: String) -> Data?

    /// File `data`, replacing whatever was there, or remove the item when it is `nil`. Reports
    /// success for the callers that surface it.
    @discardableResult
    func setSecret(_ data: Data?, service: String, account: String) -> Bool
}

/// The real thing: a generic-password item in the user's login Keychain.
struct KeychainSecretStore: SecretStoring {
    func secret(service: String, account: String) -> Data? {
        var query = Self.baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    @discardableResult
    func setSecret(_ data: Data?, service: String, account: String) -> Bool {
        // Delete first either way: `SecItemAdd` fails on a duplicate, so "replace" is the only
        // spelling of a write this has ever had.
        SecItemDelete(Self.baseQuery(service: service, account: account) as CFDictionary)
        guard let data else { return true }
        var attributes = Self.baseQuery(service: service, account: account)
        attributes[kSecValueData as String] = data
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

/// The stand-in a test host runs on: the same contract, backed by a dictionary that dies with the
/// process.
///
/// It exists because reading a login-Keychain item raises **"Dirnex wants to use your confidential
/// information"** on every `xcodebuild test`, and answering it is not optional — a `SecItemCopyMatching`
/// blocks until somebody clicks, so the run sits there. The item's ACL is keyed to the *binary* that
/// created it and every rebuild is a new ad-hoc-signed binary, so "Always Allow" buys exactly one
/// run; that is the same signing fact that revokes Full Disk Access on a rebuild (docs/NOTES.md ▸
/// The Trash), arriving on the Keychain.
///
/// It also retires a hazard rather than merely a dialog. The live S3 suites drive flows that **file a
/// secret on every successful connect**, keyed by `accessKeyID@host:port/region` — a fact about the
/// account and not about who wrote it — so pointing the fixture at an account the person also browses
/// had the suite overwrite the very item their saved sidebar row depends on. That needed a
/// capture-and-restore around the whole run (`S3LiveKeychainSnapshot`, deleted with this); a store
/// the tests cannot reach needs nothing put back.
///
/// A lock rather than an actor because the contract is synchronous — `SecretKeychain` is called from
/// wherever a connection is being made — and because a dictionary behind `NSLock` is the whole
/// implementation.
final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Key: Data] = [:]

    private struct Key: Hashable {
        let service: String
        let account: String
    }

    func secret(service: String, account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return items[Key(service: service, account: account)]
    }

    @discardableResult
    func setSecret(_ data: Data?, service: String, account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        items[Key(service: service, account: account)] = data
        return true
    }
}
