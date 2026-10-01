import DirnexCore
import Foundation

/// Whether this build shows anything about licenses, and whether it reminds (PLAN.md §M29 "lands
/// dormant", "Only official builds remind").
///
/// Licensing is off unless the release workflow built this copy with its licensing switch on, which
/// writes `DirnexLicensingEnabled = YES` into `Info.plist` (`scripts/build_app.sh`). Betas turn it on
/// first, and stable on the day the store opens. Anyone's own build from source leaves it empty, and
/// that's the promise the open source makes: building Dirnex yourself is free.
///
/// Debug builds show the licensing surfaces too, so they can be worked on: the License tab, the two
/// commands and the `dirnex://` link. They never *remind* unless asked to by a launch argument (see
/// ``debugDaysAhead``).
enum LicensingSwitch {
    static let infoPlistKey = "DirnexLicensingEnabled"

    /// The day this build was released, as the release workflow writes it (`YYYY-MM-DD`, UTC).
    static let releaseDateKey = "DirnexReleaseDate"

    static let isDebugBuild: Bool = {
        #if DEBUG
            true
        #else
            false
        #endif
    }()

    /// Whether `Info.plist` carries the switch, on.
    static let isSwitchedOn = switchIsOn(
        infoValue: Bundle.main.object(forInfoDictionaryKey: infoPlistKey)
    )

    /// Whether this build shows the License tab, the licensing commands and the link handler.
    static let isOn = isSwitchedOn || isDebugBuild

    /// Whether this build shows the reminder and the titlebar label: a release build with the switch
    /// on, or a Debug build launched with ``debugDaysAhead``. Never a Debug build otherwise, never
    /// the test host, and never anyone's own build.
    static let reminds = isDebugBuild ? debugDaysAhead != nil : isSwitchedOn

    /// The rule, apart from the bundle it reads: exactly the string `YES`, the value a build setting
    /// expands to. An empty value (every build the workflow didn't make) is off, and so is a typo.
    static func switchIsOn(infoValue: Any?) -> Bool {
        (infoValue as? String) == "YES"
    }

    /// This build's release day, or `nil` for an undated build (a Debug build, or one made outside the
    /// release workflow), which every key counts as covered. A Debug build takes ``debugBuildDate``
    /// in its place when launched with one.
    static let buildReleaseDay: LicenseDay? = debugBuildDate
        ?? (Bundle.main.object(forInfoDictionaryKey: releaseDateKey) as? String).flatMap(
            LicenseDay.init
        )

    /// `commands` without the licensing ones when this build shows nothing about licenses. Every place
    /// a command can appear reads the registry through here or through `LocalizedCatalog`, which does.
    static func available(_ commands: [Command], isOn: Bool = isOn) -> [Command] {
        isOn ? commands : commands.filter { !CommandCatalog.licensingCommandIDs.contains($0.id) }
    }

    // MARK: - Debug preview

    /// `-DirnexDebugLicenseDaysAhead <n>`, Debug builds only: remind as a release build would, with
    /// the clock moved `n` days ahead. `31` shows the reminder at launch. The record is kept in memory
    /// only, so a Debug run never touches the real one.
    static let debugDaysAhead: Int? = debugArgument("DirnexDebugLicenseDaysAhead").flatMap { Int($0) }

    /// `-DirnexDebugLicenseBuildDate <YYYY-MM-DD>`, Debug builds only: pretend this build came out on
    /// that day, so a key that ended before it shows the **Renew** reminder and label.
    static let debugBuildDate: LicenseDay? = debugArgument("DirnexDebugLicenseBuildDate").flatMap(
        LicenseDay.init
    )

    /// A launch argument's value, read only in a Debug build: a release build ignores these even if
    /// someone writes them into its preferences.
    private static func debugArgument(_ name: String) -> String? {
        guard isDebugBuild else { return nil }
        return UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[name] as? String
    }
}
