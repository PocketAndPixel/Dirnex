import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// `SecretKeychain` reads and writes through ``SecretStoring``, so a test host runs on a dictionary
/// instead of the user's login Keychain.
///
/// Two things made that worth doing. Reading a real item raises **"Dirnex wants to use your
/// confidential information stored in com.dirnex.s3"** on every run — the item's ACL is keyed to the
/// binary that created it, and every rebuild is a new ad-hoc-signed one, so "Always Allow" lasts
/// exactly one build — and `SecItemCopyMatching` *blocks* until somebody clicks, so the suite waits
/// on a person. And the live S3 flows file a secret on every successful connect, keyed by the
/// account rather than by who wrote it, so a fixture naming an account the person also browses had
/// the run overwrite their own saved credential.
@Suite("Secret store")
struct SecretStoreTests {
    // MARK: - Which store this process is on

    /// **The load-bearing assertion in this file.** Everything else here is about a dictionary; this
    /// is what says the running host is actually using one. If XCTest ever stops setting the marker,
    /// this fails — where the alternative is the suite quietly going back to the user's Keychain and
    /// nobody noticing until a dialog appears.
    @Test("this test host is running on the in-memory store, not the login Keychain")
    func testHostUsesTheStandIn() {
        #expect(SecretKeychain.backing is InMemorySecretStore)
    }

    /// The direction that matters for the *user*: without the marker the real Keychain is chosen, so
    /// a false positive can't silently stop their passwords being saved. Pure, hence assertable
    /// without arranging a process.
    @Test("the stand-in needs both signals: the marker and a loaded XCTest")
    func storeChoiceNeedsBothSignals() {
        let marker = ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]
        #expect(SecretKeychain.usesInMemoryStore(marker, xctestLoaded: true))
        // No marker → the real Keychain, whatever else is loaded.
        #expect(!SecretKeychain.usesInMemoryStore([:], xctestLoaded: true))
        #expect(!SecretKeychain.usesInMemoryStore(["HOME": "/Users/someone"], xctestLoaded: true))
        // …and the marker alone is not enough, which is what protects someone who happens to have
        // that variable exported in the shell they launch the app from.
        #expect(!SecretKeychain.usesInMemoryStore(marker, xctestLoaded: false))
    }

    /// Both signals are really present here — otherwise the pair above is arithmetic about a
    /// condition that never holds, and `testHostUsesTheStandIn` is the only thing standing between
    /// the suite and the user's Keychain.
    @Test("this host actually carries both signals")
    func bothSignalsArePresent() {
        #expect(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil)
        #expect(NSClassFromString("XCTestCase") != nil)
    }

    // MARK: - The stand-in's own contract

    private static func account(_ keyID: String) -> S3Account {
        S3Account(
            host: "s3.eu-north-1.amazonaws.com",
            port: nil,
            region: "eu-north-1",
            accessKeyID: keyID,
            addressing: .virtualHost,
            usesTLS: true
        )
    }

    @Test("a secret round-trips, is replaced rather than duplicated, and can be removed")
    func roundTrips() {
        let store = InMemorySecretStore()
        #expect(store.secret(service: "s", account: "a") == nil)

        store.setSecret(Data("first".utf8), service: "s", account: "a")
        #expect(store.secret(service: "s", account: "a") == Data("first".utf8))

        // A write over an existing item replaces it — the contract `SecItemAdd`'s duplicate failure
        // forces on the real store, which is why `store` there is a delete-then-add.
        store.setSecret(Data("second".utf8), service: "s", account: "a")
        #expect(store.secret(service: "s", account: "a") == Data("second".utf8))

        store.setSecret(nil, service: "s", account: "a")
        #expect(store.secret(service: "s", account: "a") == nil)
    }

    @Test("the service and the account are both part of the key")
    func keyIsThePair() {
        let store = InMemorySecretStore()
        store.setSecret(Data("s3".utf8), service: "com.dirnex.s3", account: "a")
        store.setSecret(Data("ftp".utf8), service: "com.dirnex.ftp", account: "a")
        store.setSecret(Data("other".utf8), service: "com.dirnex.s3", account: "b")
        #expect(store.secret(service: "com.dirnex.s3", account: "a") == Data("s3".utf8))
        #expect(store.secret(service: "com.dirnex.ftp", account: "a") == Data("ftp".utf8))
        #expect(store.secret(service: "com.dirnex.s3", account: "b") == Data("other".utf8))
    }

    // MARK: - Through the generic layer

    /// What the live S3 suites actually depend on: a connect files the secret and entering a bucket
    /// reads it back. That is the same file-then-read whichever store is underneath, which is why
    /// they keep working without ever touching the Keychain.
    @Test("SecretKeychain files and reads a password back through whatever store is installed")
    func filesAndReadsBack() {
        let account = Self.account("AKIA-ROUNDTRIP")
        defer { SecretKeychain.removePassword(for: account) }

        #expect(SecretKeychain.password(for: account) == nil)
        SecretKeychain.store(password: "s3cret", for: account)
        #expect(SecretKeychain.password(for: account) == "s3cret")
        SecretKeychain.removePassword(for: account)
        #expect(SecretKeychain.password(for: account) == nil)
    }

    /// The narrowness control on the key: two accounts must not collapse onto one item just because
    /// the generic layer was rewritten underneath them.
    @Test("two accounts on one service keep separate secrets")
    func accountsStaySeparate() {
        let first = Self.account("AKIA-FIRST")
        let second = Self.account("AKIA-SECOND")
        defer {
            SecretKeychain.removePassword(for: first)
            SecretKeychain.removePassword(for: second)
        }
        SecretKeychain.store(password: "one", for: first)
        SecretKeychain.store(password: "two", for: second)
        #expect(SecretKeychain.password(for: first) == "one")
        #expect(SecretKeychain.password(for: second) == "two")
    }

    /// A location with nothing worth filing never reaches the store at all — the anonymous-FTP rule,
    /// which lives above the seam and had to survive the move.
    @Test("a location with no secret to file is skipped in both directions")
    func anonymousIsSkipped() {
        let anonymous = FTPLocation(host: "ftp.example.com", username: "anonymous")
        #expect(anonymous.hasNoStoredSecret)
        #expect(SecretKeychain.store(password: "ignored", for: anonymous))
        #expect(SecretKeychain.password(for: anonymous) == nil)
        // …and the store really was left alone, rather than the read merely being suppressed.
        #expect(
            SecretKeychain.backing.secret(
                service: FTPLocation.keychainService,
                account: anonymous.keychainAccount
            ) == nil
        )
    }

    /// A vault's passphrase takes the bytes path, never becoming a `String` on the way through.
    @Test("a passphrase round-trips as bytes")
    func passphraseRoundTrips() {
        let vault = Self.account("AKIA-PASSPHRASE")
        defer { SecretKeychain.removePassword(for: vault) }
        SecretKeychain.store(passphrase: ArchivePassphrase("öpen sésame"), for: vault)
        let read = try? #require(SecretKeychain.passphrase(for: vault))
        #expect(read?.withUnsafeBytes { Data($0) } == Data("öpen sésame".utf8))
    }

    /// An empty item reads back as *no* passphrase rather than as an empty one — the guard the
    /// original `passphrase(for:)` carried, preserved across the rewrite.
    @Test("an empty stored value is no passphrase at all")
    func emptyPassphraseIsNil() {
        let vault = Self.account("AKIA-EMPTY")
        defer { SecretKeychain.removePassword(for: vault) }
        SecretKeychain.backing.setSecret(
            Data(),
            service: S3Account.keychainService,
            account: vault.keychainAccount
        )
        #expect(SecretKeychain.passphrase(for: vault) == nil)
    }
}
