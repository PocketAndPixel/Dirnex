import Darwin
import Foundation

/// What the Report a Bug dialog holds (PLAN.md §M30): the texts as typed, and a box for each fact
/// about this Mac. Every box is ticked by default except the crash report's.
///
/// ``report(system:licensed:crashReport:redaction:)`` is the one place a dialog's state becomes what
/// is sent, so the promise that nothing reaches the server that the user didn't type or tick is a
/// property of this type, and tested here.
public struct BugReportForm: Sendable, Hashable {
    public var whatHappened = ""
    public var steps = ""
    public var email = ""
    /// The Dirnex version and build, as one box.
    public var includesVersion = true
    public var includesMacOS = true
    public var includesMacModel = true
    public var includesLanguage = true
    /// Whether a license is present. Never the key.
    public var includesLicenseState = true
    /// Off by default: a crash report is long, and the user should choose to send it.
    public var includesCrashReport = false

    public init() {}

    /// The report this form sends. The texts lose the blanks around them, the home folder becomes
    /// `~` in everything but the email, and an unticked box leaves its field out entirely.
    /// `crashReport` was trimmed with the same redaction when it was read.
    public func report(
        system: BugReportSystemInfo,
        licensed: Bool,
        crashReport: TrimmedCrashReport?,
        redaction: BugReportRedaction
    ) -> BugReport {
        let typed = { (text: String) in BugReportText.nonBlank(BugReportText.trimmed(text)) }
        let crash = includesCrashReport ? crashReport : nil
        return BugReport(
            whatHappened: redaction.redacted(BugReportText.trimmed(whatHappened)),
            steps: typed(steps).map(redaction.redacted),
            email: typed(email),
            appVersion: includesVersion ? system.appVersion : nil,
            appBuild: includesVersion ? system.appBuild : nil,
            macOS: includesMacOS ? system.macOS : nil,
            macModel: includesMacModel ? system.macModel : nil,
            language: includesLanguage ? system.language : nil,
            licensed: includesLicenseState ? licensed : nil,
            crashReport: crash.flatMap { BugReportText.nonBlank($0.text) }
        )
    }
}

/// The facts about this Mac and this copy of Dirnex that a report can carry. Each is cut to the
/// contract's ``BugReport/Limits/shortFieldBytes`` and left `nil` when it can't be read.
public struct BugReportSystemInfo: Sendable, Hashable {
    public var appVersion: String?
    public var appBuild: String?
    public var macOS: String?
    public var macModel: String?
    public var language: String?

    public init(
        appVersion: String? = nil,
        appBuild: String? = nil,
        macOS: String? = nil,
        macModel: String? = nil,
        language: String? = nil
    ) {
        let short = { (text: String?) in
            BugReportText.nonBlank(text).map {
                BugReportText.prefix($0, maxBytes: BugReport.Limits.shortFieldBytes)
            }
        }
        self.appVersion = short(appVersion)
        self.appBuild = short(appBuild)
        self.macOS = short(macOS)
        self.macModel = short(macModel)
        self.language = short(language)
    }

    /// This Mac, and the copy of Dirnex `bundle` is. The language is the one the bundle is showing
    /// (`preferredLocalizations`), which is the one a screenshot in the report would be in.
    public static func current(bundle: Bundle = .main) -> BugReportSystemInfo {
        let info = bundle.infoDictionary ?? [:]
        return BugReportSystemInfo(
            appVersion: info["CFBundleShortVersionString"] as? String,
            appBuild: info["CFBundleVersion"] as? String,
            macOS: macOSVersion(
                ProcessInfo.processInfo.operatingSystemVersion,
                build: systemValue("kern.osversion")
            ),
            macModel: systemValue("hw.model"),
            language: bundle.preferredLocalizations.first
        )
    }

    /// `26.0.1 (25A362)`, as About This Mac writes it: no `.0` patch, and the build in brackets.
    static func macOSVersion(_ version: OperatingSystemVersion, build: String?) -> String {
        var text = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 { text += ".\(version.patchVersion)" }
        if let build, !build.isEmpty { text += " (\(build))" }
        return text
    }

    /// A text value from `sysctlbyname`, such as `hw.model`.
    static func systemValue(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(bytes: buffer.prefix { $0 != 0 }, encoding: .utf8)
    }
}
