import Foundation

/// A saved server connection that can name itself to the login Keychain.
///
/// The three remote locations — `SFTPLocation`, `FTPLocation`, `SMBLocation` — each already carried
/// a `keychainService` and a `keychainAccount`; this is the shape they had in common, named so the
/// app can file all three through one store instead of three near-identical copies of `SecItemAdd`.
///
/// The core deliberately holds only the *addressing*. Nothing here touches Security.framework or
/// sees a password: the Keychain call is non-hermetic I/O and lives in the app (PLAN.md §2), while
/// the keys it files under are pure values worth testing.
public protocol KeychainAddressable {
    /// The generic-password item's service — one per protocol, so the three never collide.
    static var keychainService: String { get }

    /// This connection's stable account key within that service. Unique per account, and stable
    /// across launches, so reconnecting later finds the password saved the first time.
    var keychainAccount: String { get }

    /// Whether this connection has no secret worth filing, so the store should skip it entirely.
    ///
    /// True only for FTP's anonymous login, whose password is a convention rather than a secret. A
    /// guest SMB mount has no `username` and never reaches the store at all, which is why it is not
    /// expressed here.
    var hasNoStoredSecret: Bool { get }
}

public extension KeychainAddressable {
    /// Most connections hold a real secret; only FTP's anonymous login overrides this.
    var hasNoStoredSecret: Bool { false }
}

extension SFTPLocation: KeychainAddressable {}

extension SMBLocation: KeychainAddressable {}

extension FTPLocation: KeychainAddressable {
    public var hasNoStoredSecret: Bool { isAnonymous }
}

/// S3's secret access key is filed like any other password. The *access key id* is not secret and
/// stays in the location itself — it is half of the account key here, which is what keeps one id
/// reaching several buckets from collapsing onto one Keychain item (``S3Location/keychainAccount``).
extension S3Location: KeychainAddressable {}

/// An S3 **account** files the same secret under the same service, keyed by
/// ``S3Account/keychainAccount`` — a bucket key's without the trailing `/<bucket>`.
///
/// The shared service is deliberate rather than incidental: it is one credential for one endpoint,
/// so a user clearing "the S3 passwords" in Keychain Access sees one group. What keeps the items
/// distinct is the account key's shape, which is why the two are defined next to each other.
extension S3Account: KeychainAddressable {
    public static var keychainService: String { S3Location.keychainService }
}
