import DirnexCore
import Foundation

/// Whether this build offers Report a Bug…, and where a report goes (PLAN.md §M30 "Hidden until the
/// endpoint exists").
///
/// The feature exists only in a build whose `Info.plist` carries `DirnexBugReportURL`, which the
/// release workflow writes once the store's server accepts reports. Every other build carries the
/// key empty, so it shows no trace of the feature: no menu item, no palette entry, no AppleScript
/// operation. A Debug build can be pointed at `Tooling/fake-bug-report-endpoint.py` with a launch
/// argument instead (``debugEndpointArgument``).
enum BugReportSwitch {
    static let infoPlistKey = "DirnexBugReportURL"

    /// `-DirnexDebugBugReportURL <url>`, Debug builds only. Plain `http` is allowed to this Mac.
    static let debugEndpointArgument = "DirnexDebugBugReportURL"

    /// Where reports go, or `nil` when this build has nowhere to send them.
    static let endpoint: URL? = endpoint(
        infoValue: Bundle.main.object(forInfoDictionaryKey: infoPlistKey),
        debugValue: debugEndpoint()
    )

    /// Whether this build shows Report a Bug….
    static var isOn: Bool { endpoint != nil }

    /// The rule, apart from the bundle it reads: a Debug build's argument wins, and only it may name
    /// plain `http` on this Mac. `Info.plist` must name an `https` address.
    static func endpoint(infoValue: Any?, debugValue: String?) -> URL? {
        BugReportEndpoint.url(fromInfoValue: debugValue, allowsLoopbackHTTP: true)
            ?? BugReportEndpoint.url(fromInfoValue: infoValue)
    }

    /// `commands` without Report a Bug… where this build has nowhere to send a report.
    static func available(_ commands: [Command], isOn: Bool = isOn) -> [Command] {
        isOn ? commands : commands.filter { !CommandCatalog.bugReportCommandIDs.contains($0.id) }
    }

    private static func debugEndpoint() -> String? {
        guard LicensingSwitch.isDebugBuild else { return nil }
        return UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[
            debugEndpointArgument
        ] as? String
    }
}

/// The registry as this build offers it: without the licensing commands where it shows nothing about
/// licenses (PLAN.md §M29), and without Report a Bug… where it has nowhere to send one (§M30). Every
/// place a command can appear reads it through here: the menu bar, the palette and Settings ▸
/// Shortcuts through `LocalizedCatalog`, and AppleScript and Shortcuts directly.
enum AvailableCommands {
    static var all: [Command] {
        BugReportSwitch.available(LicensingSwitch.available(CommandCatalog.all))
    }
}
