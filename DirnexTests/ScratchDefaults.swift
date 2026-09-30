import Foundation

/// A defaults domain that belongs to one test, emptied before the test gets it.
///
/// The name is fixed per test and never contains a UUID. `removePersistentDomain(forName:)` empties
/// a domain but leaves its plist in `~/Library/Preferences`, so a suite named with a fresh UUID
/// leaves a file behind on every run, cleanup or not. By 2026-09-13 the app tests had left 19,046
/// of them (docs/NOTES.md ▸ Testing). A fixed name costs one file per test, however many runs.
///
/// Emptying on the way in rather than on the way out means a run that crashed or was killed before
/// its cleanup cannot hand the next run a domain that already holds values. The name comes from the
/// calling test's file and function, so tests Swift Testing runs in parallel get separate domains.
/// The one exception is two suites in one file with a test of the same name, which would share. A
/// test that needs a second empty domain, or that hits that exception, passes a `variant`.
///
/// For a pane's persisted tabs use ``TabStateScratch`` instead, which is cleared once per test host
/// because a pane can write after its test has returned.
enum ScratchDefaults {
    static func fresh(
        _ variant: String? = nil,
        file: String = #fileID,
        function: String = #function
    ) -> UserDefaults {
        let name = suiteName(variant, file: file, function: function)
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// `com.dirnex.tests.<file>.<function>[.<variant>]`, from `#fileID`
    /// (`DirnexTests/RowDensityTests.swift`) and `#function` (`preferenceRoundTrips()`).
    static func suiteName(_ variant: String?, file: String, function: String) -> String {
        let fileStem = (file.split(separator: "/").last.map(String.init) ?? file)
            .replacingOccurrences(of: ".swift", with: "")
        let functionStem = function.split(separator: "(").first.map(String.init) ?? function
        return (["com.dirnex.tests", fileStem, functionStem] + [variant].compactMap { $0 })
            .joined(separator: ".")
    }
}
