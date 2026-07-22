import AppKit
import Combine
import DirnexCore
import Foundation

/// The app's display language: which one is in force, which one the user picked, and the relaunch
/// that closes the gap between the two.
///
/// The mechanism is **`AppleLanguages` written into Dirnex's own defaults domain** — the same lever
/// System Settings ▸ General ▸ Language & Region ▸ Applications pulls. That choice is what makes the
/// translation complete rather than partial: AppKit's stock menu items ("Quit Dirnex", "Services"),
/// the open/save panels, and Sparkle's update dialogs are localized by *their* bundles against the
/// app's language, so they follow along. A homegrown "look strings up in a chosen bundle" scheme
/// would move only Dirnex's own strings and leave the rest in the system language — visibly
/// half-translated, permanently.
///
/// The cost is that a change lands at launch, not live, which is why this type exposes
/// ``needsRelaunch`` and ``relaunch()`` rather than pretending otherwise.
///
/// Deliberately not an `AppPreferences` toggle: every key there is a `Dirnex.pref.*` value the app
/// reads itself, whereas this one is read by the OS's bundle machinery before `main` runs.
@MainActor
final class LanguageSettings: ObservableObject {
    static let shared = LanguageSettings()

    /// The system-owned defaults key. Ours to write in *our* domain; never written globally.
    private static let appleLanguagesKey = "AppleLanguages"

    private let defaults: UserDefaults
    private let domainName: String

    /// The language the running process is actually displaying, sampled once at startup.
    ///
    /// Read from `Bundle.main.preferredLocalizations`, which is the OS's own answer for which
    /// `.lproj` won — so it accounts for what the bundle really contains, not for what we hoped
    /// resolution would pick.
    let activeLanguage: AppLanguage

    /// What the user has asked for. Writing it updates the defaults domain immediately; the UI
    /// catches up on the next launch.
    @Published var preference: LanguagePreference {
        didSet {
            guard preference != oldValue else { return }
            persist(preference)
        }
    }

    init(defaults: UserDefaults = .standard, domainName: String? = nil) {
        self.defaults = defaults
        self.domainName = domainName ?? Bundle.main.bundleIdentifier ?? "com.dirnex.Dirnex"
        activeLanguage = Self.activeLanguage(in: .main)
        preference = Self.storedPreference(in: defaults, domain: self.domainName)
    }

    /// The language the user's pick resolves to — what a relaunch would show.
    var resolvedLanguage: AppLanguage {
        AppLanguages.resolve(
            preference,
            systemPreferred: Self.systemPreferredLanguages(in: defaults)
        )
    }

    /// True when the pick and the running UI disagree, i.e. the relaunch button has something to do.
    var needsRelaunch: Bool {
        resolvedLanguage != activeLanguage
    }

    // MARK: - Reading

    private static func activeLanguage(in bundle: Bundle) -> AppLanguage {
        guard let code = bundle.preferredLocalizations.first else { return AppLanguages.english }
        return AppLanguages.language(for: code) ?? AppLanguages.bestMatch(forPreferred: [code])
    }

    /// The pin recorded in our own domain, or `.system` when there is none.
    ///
    /// Must read the domain dictionary rather than `object(forKey:)`: the standard defaults search
    /// falls through to the *global* domain, so an un-pinned app would read the system's language
    /// list back and mistake it for a pin the user set.
    private static func storedPreference(in defaults: UserDefaults, domain: String) -> LanguagePreference {
        guard let codes = defaults.persistentDomain(forName: domain)?[appleLanguagesKey] as? [String],
              let first = codes.first,
              let language = AppLanguages.language(for: first)
        else { return .system }
        return .explicit(language)
    }

    /// The system's ordered language preferences, read from the global domain.
    ///
    /// Not `Locale.preferredLanguages` and not `UserDefaults.standard.stringArray(forKey:)` — both
    /// already reflect our own override, so asking either what the *system* prefers hands back our
    /// own answer and "Follow system language" would resolve to whatever was last pinned.
    private static func systemPreferredLanguages(in defaults: UserDefaults) -> [String] {
        let global = defaults.persistentDomain(forName: UserDefaults.globalDomain)
        return global?[appleLanguagesKey] as? [String] ?? []
    }

    // MARK: - Writing

    private func persist(_ preference: LanguagePreference) {
        switch preference {
        case .system:
            defaults.removeObject(forKey: Self.appleLanguagesKey)
        case let .explicit(language):
            defaults.set([language.code], forKey: Self.appleLanguagesKey)
        }
    }

    // MARK: - Relaunch

    /// Quit and come back up in the chosen language.
    ///
    /// The replacement waits for *this* process to exit before opening the app again, rather than
    /// launching a second instance alongside it. That ordering is load-bearing: Dirnex writes its
    /// tabs and workspaces on the way down, and an instance that started earlier would restore the
    /// previous session and then have it overwritten by the one still shutting down.
    func relaunch() {
        defaults.synchronize()

        let bundlePath = Bundle.main.bundleURL.path
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = [
            "-c",
            // `kill -0` probes for liveness without signalling. Quote the path — an app installed
            // under a directory with a space is ordinary.
            "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.1; done; open \(shellQuoted(bundlePath))"
        ]

        do {
            try waiter.run()
        } catch {
            // Nothing actionable for the user here: the pick is already persisted, so quitting
            // normally and reopening gets them the same result. Don't block the quit on it.
            NSLog(
                "Dirnex: could not schedule relaunch (%@); the language applies on next launch.",
                error.localizedDescription
            )
            return
        }

        NSApp.terminate(nil)
    }

    private func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
