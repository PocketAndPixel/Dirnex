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
/// versions. A renewal replaces it.
@MainActor
final class LicenseStore: ObservableObject {
    static let shared = LicenseStore()

    /// Posted when the key changes, for the AppKit side (the titlebar label, in Slice 4). SwiftUI
    /// observes `key` directly.
    static let didChange = Notification.Name("Dirnex.licenseDidChange")

    /// The verifiers a key is checked against, in order: production, and in a Debug build also the
    /// test key, so the whole flow can be tried without the production private key.
    static var buildVerifiers: [LicenseVerifier] {
        LicensingSwitch.isDebugBuild ? [.production, .test] : [.production]
    }

    private let defaults: UserDefaults
    private let verifiers: [LicenseVerifier]
    let buildReleaseDay: LicenseDay?

    /// The key this Mac holds, checked. `nil` when there's none, or when the stored text no longer
    /// checks out in this build.
    @Published private(set) var key: LicenseKey?

    init(
        defaults: UserDefaults = .standard,
        verifiers: [LicenseVerifier] = LicenseStore.buildVerifiers,
        buildReleaseDay: LicenseDay? = LicensingSwitch.buildReleaseDay
    ) {
        self.defaults = defaults
        self.verifiers = verifiers
        self.buildReleaseDay = buildReleaseDay
        let stored = defaults.string(forKey: AppPreferences.Keys.licenseKey)
        key = stored.flatMap { try? Self.check($0, with: verifiers).get() }
    }

    /// Where this build stands with the key held.
    var status: LicenseStatus {
        LicenseStatus(key: key, buildReleaseDay: buildReleaseDay)
    }

    /// Checks `pasted` without keeping it: the first verifier that accepts it wins, and otherwise the
    /// production verifier's reason is the one reported.
    func check(_ pasted: String) -> Result<LicenseKey, LicenseKeyError> {
        Self.check(pasted, with: verifiers)
    }

    /// Checks `pasted` and, if it's a key, keeps it in place of any key held before.
    @discardableResult
    func activate(_ pasted: String) -> Result<LicenseKey, LicenseKeyError> {
        let result = check(pasted)
        if case let .success(newKey) = result {
            defaults.set(newKey.text, forKey: AppPreferences.Keys.licenseKey)
            setKey(newKey)
        }
        return result
    }

    /// Forgets the key. The email still has it.
    func remove() {
        defaults.removeObject(forKey: AppPreferences.Keys.licenseKey)
        setKey(nil)
    }

    private func setKey(_ newKey: LicenseKey?) {
        guard newKey != key else { return }
        key = newKey
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private static func check(
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
