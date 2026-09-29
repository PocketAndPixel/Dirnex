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

    public init(key: LicenseKey?, buildReleaseDay: LicenseDay?) {
        guard let key else {
            self = .unlicensed
            return
        }
        self = key.covers(releaseDay: buildReleaseDay) ? .licensed(key) : .lapsed(key)
    }

    public var key: LicenseKey? {
        switch self {
        case .unlicensed: nil
        case let .licensed(key), let .lapsed(key): key
        }
    }

    public var isCovered: Bool {
        if case .licensed = self { return true }
        return false
    }
}
