import Combine
import DirnexCore
import Foundation

/// The license key this Mac holds (PLAN.md §M29 "Holding a key").
///
/// The key is kept in preferences, not the Keychain. It isn't a secret: it's signed, not hidden, and
/// a Keychain read raises a password prompt on a build signed differently from the one that saved it
/// (CLAUDE.md). What's stored is only the text. It's checked again at every launch, so a key edited
/// in the defaults domain, or one a Debug build accepted with the test key, simply doesn't count in
/// a build that wouldn't accept it.
///
/// A key that checks out but doesn't cover this build is still kept, since it covers the older
/// versions. A renewal replaces it. So is a key whose license this build's list revoked (PLAN.md
/// §M40 "Revoked keys"): it counts for nothing, and a build whose list no longer names it counts it
/// again. A key pasted or opened from a link while its license is revoked is refused, though, and
/// replaces nothing.
@MainActor
final class LicenseStore: ObservableObject {
    static let shared = LicenseStore()

    /// Posted when the key changes, for the AppKit side (the titlebar label, in Slice 4). SwiftUI
    /// observes `heldKey` directly.
    static let didChange = Notification.Name("Dirnex.licenseDidChange")

    /// The verifiers a key is checked against, in order: production, and in a Debug build also the
    /// test key, so the whole flow can be tried without the production private key.
    static var buildVerifiers: [LicenseVerifier] {
        LicensingSwitch.isDebugBuild ? [.production, .test] : [.production]
    }

    private let defaults: UserDefaults
    private let verifiers: [LicenseVerifier]
    private let revocations: LicenseRevocations
    let buildReleaseDay: LicenseDay?

    /// The key this Mac holds, checked against the signature: `nil` when there's none, or when the
    /// stored text no longer checks out in this build. A revoked key is held too, so that Settings ▸
    /// License can say so; ``key`` is the one that counts.
    @Published private(set) var heldKey: LicenseKey?

    init(
        defaults: UserDefaults = .standard,
        verifiers: [LicenseVerifier] = LicenseStore.buildVerifiers,
        revocations: LicenseRevocations = .thisBuild,
        buildReleaseDay: LicenseDay? = LicensingSwitch.buildReleaseDay
    ) {
        self.defaults = defaults
        self.verifiers = verifiers
        self.revocations = revocations
        self.buildReleaseDay = buildReleaseDay
        let stored = defaults.string(forKey: AppPreferences.Keys.licenseKey)
        heldKey = stored.flatMap { try? Self.verify($0, with: verifiers).get() }
    }

    /// Where this build stands with the key held.
    var status: LicenseStatus {
        LicenseStatus(key: heldKey, buildReleaseDay: buildReleaseDay, revocations: revocations)
    }

    /// The key that counts: `nil` with none, and with a revoked one. A key whose renewal was taken back
    /// ends on the day the license was put back to.
    var key: LicenseKey? {
        status.key
    }

    /// Checks `pasted` without keeping it: the first verifier that accepts it wins, and otherwise the
    /// production verifier's reason is the one reported. Only a key that verified is looked up on the
    /// revoked list, so a forged key is refused for its signature whatever id it names.
    func check(_ pasted: String) -> Result<LicenseKey, LicenseRefusal> {
        applyingRevocations(to: Self.verify(pasted, with: verifiers))
    }

    /// Checks `pasted` and, if it's a key that counts, keeps it in place of any key held before.
    @discardableResult
    func activate(_ pasted: String) -> Result<LicenseKey, LicenseRefusal> {
        let verified = Self.verify(pasted, with: verifiers)
        let result = applyingRevocations(to: verified)
        if case .success = result, case let .success(newKey) = verified {
            defaults.set(newKey.text, forKey: AppPreferences.Keys.licenseKey)
            setHeldKey(newKey)
        }
        return result
    }

    /// Forgets the key. The email still has it.
    func remove() {
        defaults.removeObject(forKey: AppPreferences.Keys.licenseKey)
        setHeldKey(nil)
    }

    private func setHeldKey(_ newKey: LicenseKey?) {
        guard newKey != heldKey else { return }
        heldKey = newKey
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func applyingRevocations(
        to verified: Result<LicenseKey, LicenseKeyError>
    ) -> Result<LicenseKey, LicenseRefusal> {
        verified.mapError(LicenseRefusal.invalid).flatMap(revocations.applied(to:))
    }

    private static func verify(
        _ pasted: String,
        with verifiers: [LicenseVerifier]
    ) -> Result<LicenseKey, LicenseKeyError> {
        var first: Result<LicenseKey, LicenseKeyError>?
        for verifier in verifiers {
            let result = verifier.check(pasted)
            if case .success = result { return result }
            first = first ?? result
        }
        return first ?? .failure(.badSignature)
    }
}
