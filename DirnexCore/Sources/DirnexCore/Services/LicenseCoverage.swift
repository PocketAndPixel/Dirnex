import Foundation

public extension LicenseKey {
    /// Whether this key covers a build released on `releaseDay` (PLAN.md §M29 "Coverage is by
    /// release date"): the release day is on or before ``until``, both as UTC days.
    ///
    /// A missing date never punishes a customer. An undated build or update counts as covered,
    /// so a release whose date failed to reach `Info.plist` or the appcast shows no reminder rather
    /// than one to someone who paid.
    func covers(releaseDay: LicenseDay?) -> Bool {
        guard let releaseDay else { return true }
        return releaseDay <= until
    }
}

/// Where this build stands with the key the user holds.
public enum LicenseStatus: Sendable, Equatable {
    /// No key.
    case unlicensed
    /// A key that covers this build. No reminder and no label.
    case licensed(LicenseKey)
    /// A key whose period ended before this build came out. It still covers the older versions,
    /// so it's kept, and a renewal replaces it.
    case lapsed(LicenseKey)
    /// A key that verifies, of a license on ``LicenseRevocations``. It counts for nothing, as no key
    /// does, and is kept, so that taking it off the list restores it (PLAN.md §M40).
    case revoked(LicenseKey)

    /// Where a build released on `buildReleaseDay` stands with `key`, a key that verified, as
    /// `revocations` reads it. A key whose renewal was taken back is judged by the day the license
    /// was put back to, so it is ``licensed(_:)`` or ``lapsed(_:)`` with that day as its end.
    public init(
        key: LicenseKey?,
        buildReleaseDay: LicenseDay?,
        revocations: LicenseRevocations = .thisBuild
    ) {
        guard let key else {
            self = .unlicensed
            return
        }
        switch revocations.applied(to: key) {
        case .failure:
            self = .revoked(key)
        case let .success(key):
            self = key.covers(releaseDay: buildReleaseDay) ? .licensed(key) : .lapsed(key)
        }
    }

    /// The key that counts: `nil` with no key, and with a revoked one, which counts for nothing.
    public var key: LicenseKey? {
        switch self {
        case .unlicensed, .revoked: nil
        case let .licensed(key), let .lapsed(key): key
        }
    }

    public var isCovered: Bool {
        if case .licensed = self { return true }
        return false
    }
}
