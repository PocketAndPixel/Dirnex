import DirnexCore
import Foundation

/// Whether this build shows anything about licenses (PLAN.md §M29 "lands dormant").
///
/// Licensing is off unless the release workflow built this copy with its licensing switch on, which
/// writes `DirnexLicensingEnabled` into `Info.plist` (Slice 4). Betas turn it on first, and stable on
/// the day the store opens. Anyone's own build from source leaves it off, and that's the promise the
/// open source makes: building Dirnex yourself is free.
///
/// Debug builds show the licensing surfaces too, so they can be worked on: the License tab, the two
/// commands and the `dirnex://` link. They never *remind*; that takes the switch itself (Slice 4).
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

    /// Whether this build shows the License tab, the licensing commands and the link handler.
    static let isOn = isOn(
        infoValue: Bundle.main.object(forInfoDictionaryKey: infoPlistKey),
        isDebugBuild: isDebugBuild
    )

    /// The rule, apart from the bundle it reads. A Boolean `true` turns it on, which is what
    /// `PlistBuddy`'s `bool true` writes; a string such as "YES" does not, so a typo leaves it off.
    static func isOn(infoValue: Any?, isDebugBuild: Bool) -> Bool {
        isDebugBuild || (infoValue as? Bool) == true
    }

    /// This build's release day, or `nil` for an undated build (a Debug build, or one made outside the
    /// release workflow), which every key counts as covered.
    static let buildReleaseDay: LicenseDay? = (
        Bundle.main.object(forInfoDictionaryKey: releaseDateKey) as? String
    )
    .flatMap(LicenseDay.init)

    /// `commands` without the licensing ones when this build shows nothing about licenses. Every place
    /// a command can appear reads the registry through here or through `LocalizedCatalog`, which does.
    static func available(_ commands: [Command], isOn: Bool = isOn) -> [Command] {
        isOn ? commands : commands.filter { !CommandCatalog.licensingCommandIDs.contains($0.id) }
    }
}
