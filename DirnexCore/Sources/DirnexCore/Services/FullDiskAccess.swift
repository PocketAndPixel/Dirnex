import Foundation

/// Whether the app can read the parts of the disk macOS keeps behind TCC (PLAN.md §M7 "Full Disk
/// Access onboarding flow (detect, explain, deep-link to System Settings)").
///
/// A file manager without the grant still browses the home directory perfectly well, but bumps
/// into a permission wall the moment it reaches another user's folder, `~/Library/Mail`, a Time
/// Machine backup, or anywhere else the system considers sensitive. The onboarding exists to catch
/// that wall early and walk the user to the single switch that removes it, rather than let them
/// meet it as a bare "you don't have permission" alert with no idea what to do about it.
///
/// The split is the same core-decides-meaning / app-does-I/O one `CloudSyncStatus` draws against
/// the ubiquity attributes: this enum and its classifier are pure and testable, while the app
/// (`FullDiskAccessChecker`) does the actual sentinel reads and hands their outcomes back here.
public enum FullDiskAccessStatus: Sendable, Hashable, CaseIterable {
    /// A TCC-protected sentinel read succeeded — the grant is in place.
    case granted
    /// A sentinel read came back with a permission error — the grant is missing.
    case denied
    /// Neither was proven: every sentinel was missing, or failed for a reason that isn't permission
    /// (a sentinel on a volume that isn't mounted, say). The app treats this like `.denied` when
    /// deciding whether to *offer* onboarding, but it is named apart so a transient read failure is
    /// never announced to the user as a definite "you have no access."
    case unknown

    /// Whether this status means the app has the access — the one question the browser asks before
    /// deciding whether to prompt at all.
    public var isGranted: Bool { self == .granted }
}

/// The result of trying to read one TCC-protected sentinel file. The app produces one of these per
/// path from a real filesystem read; `FullDiskAccess.status(reading:)` folds them into a verdict.
public enum SentinelReadOutcome: Sendable, Hashable, CaseIterable {
    /// The read succeeded — only possible with the grant, since every sentinel is TCC-protected.
    case readable
    /// The read failed with a permission error (`EPERM`/`EACCES`, or Cocoa's
    /// `NSFileReadNoPermissionError`) — the signal that the grant is missing.
    case permissionDenied
    /// The path wasn't there. Says nothing about the grant: an account that never launched Mail has
    /// no `~/Library/Mail`, so a missing sentinel is not a denied one.
    case missing
    /// The read failed for some other reason. Also says nothing about the grant.
    case otherFailure
}

/// The pure half of the Full Disk Access check: which files to probe, how to read a failed read's
/// error, how to fold the outcomes into a verdict, and where in System Settings to send the user.
///
/// Everything here is testable without a real grant or a real disk — the app injects the reads.
public enum FullDiskAccess {
    /// The home-relative sentinel paths the app probes, most-reliably-present first.
    ///
    /// `Library/Application Support/com.apple.TCC/TCC.db` is the gold standard, and the reason the
    /// list is ordered: TCC creates it on **every** account, so it is always present, and it is
    /// readable **only** with Full Disk Access. That makes a successful read positive proof of the
    /// grant and a permission error positive proof of its absence — with none of the "but the user
    /// never ran that app" ambiguity the Mail / Safari / Messages folders carry, since a user who
    /// never opened Mail simply has no `~/Library/Mail` and the probe there reads `.missing`, not
    /// `.permissionDenied`. Those three are only fallbacks for the (theoretical) account where the
    /// TCC database can't be reached for some reason that isn't permission.
    ///
    /// Probed live on macOS 26.5.2: reading TCC.db from a process without the grant returns `EPERM`
    /// (errno 1), which Foundation surfaces as `NSFileReadNoPermissionError`.
    public static let sentinelPaths: [String] = [
        "Library/Application Support/com.apple.TCC/TCC.db",
        "Library/Mail",
        "Library/Safari",
        "Library/Messages"
    ]

    /// The System Settings deep link that opens Privacy & Security ▸ Full Disk Access directly, with
    /// that pane already selected.
    ///
    /// The `Privacy_AllFilesAccess` anchor is the stable one across the System Settings rewrite
    /// (Ventura) all the way through macOS 26, and it is pinned by a test because a single typo would
    /// silently drop the user on the top of Privacy & Security with nothing selected — a much worse
    /// failure than a build error, because it still looks like it worked.
    public static let systemSettingsURLString =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFilesAccess"

    /// Fold the per-sentinel reads into one verdict, reading each sentinel through the supplied
    /// closure — the seam the app fills with a real filesystem read and a test fills with a canned
    /// outcome.
    ///
    /// The precedence and the short-circuit are both deliberate. A single `.readable` settles it
    /// immediately: we read a protected file, so the grant is on, and there is no point reading the
    /// rest (the app never touches `~/Library/Mail` when TCC.db already answered). Failing any
    /// readable, one `.permissionDenied` anywhere means the grant is off. With neither — every
    /// sentinel missing or failing for a non-permission reason — the honest answer is `.unknown`
    /// rather than a `.denied` we can't actually stand behind.
    public static func status(reading read: (String) -> SentinelReadOutcome) -> FullDiskAccessStatus {
        var sawDenied = false
        for path in sentinelPaths {
            switch read(path) {
            case .readable: return .granted
            case .permissionDenied: sawDenied = true
            case .missing, .otherFailure: break
            }
        }
        return sawDenied ? .denied : .unknown
    }

    /// Classify a read error by its `(domain, code)` into the outcome it represents — the same "the
    /// core names what the system's raw codes mean" move `CloudTransferError.init(domain:code:)`
    /// makes for the sync badge.
    ///
    /// A denied `Data(contentsOf:)` or `FileManager` read arrives as Cocoa
    /// `NSFileReadNoPermissionError`; a raw POSIX failure (e.g. from `open(2)`) as
    /// `NSPOSIXErrorDomain` with `EPERM`/`EACCES`. Anything else — a code in some other domain, or an
    /// unrecognised code — is `.otherFailure`, which the fold above reads as "tells us nothing."
    public static func outcome(domain: String, code: Int) -> SentinelReadOutcome {
        switch domain {
        case NSCocoaErrorDomain:
            switch CocoaError.Code(rawValue: code) {
            case .fileReadNoPermission, .fileWriteNoPermission: return .permissionDenied
            case .fileNoSuchFile, .fileReadNoSuchFile: return .missing
            default: return .otherFailure
            }
        case NSPOSIXErrorDomain:
            switch Int32(code) {
            case EPERM, EACCES: return .permissionDenied
            case ENOENT: return .missing
            default: return .otherFailure
            }
        default:
            return .otherFailure
        }
    }
}
