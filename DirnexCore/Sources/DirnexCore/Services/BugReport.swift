import Foundation

/// A bug report, as Dirnex sends it to the store's server (PLAN.md §M30): the body of
/// `POST https://dirnex.app/api/bug-reports`.
///
/// The contract lives in the private repo (`web/src/bug-reports/contract.ts`), and both sides are
/// pinned by the same cases (`Fixtures/bug-report-vectors.json`, copied unchanged). Two of its rules
/// keep Swift and TypeScript from disagreeing quietly: every limit counts **UTF-8 bytes**, and
/// "blank" is a written-out list of characters (``BugReportText``).
///
/// Nothing here decides *what* goes in: that is ``BugReportForm``, which leaves out every box the
/// user unticked. A value of this type is what will be sent, and ``body()`` is the exact bytes.
public struct BugReport: Sendable, Hashable {
    public static let formatVersion = 1

    /// What went wrong, in the user's words. The only text that must be there. The contract calls
    /// it `description`.
    public var whatHappened: String
    public var steps: String?
    /// Where to reply.
    public var email: String?
    /// `CFBundleShortVersionString`, such as `1.4.0` or `1.4.0-beta.3`.
    public var appVersion: String?
    /// `CFBundleVersion`, such as `512`. A text, as the contract wants it.
    public var appBuild: String?
    /// Such as `26.0.1 (25A362)`.
    public var macOS: String?
    /// The model identifier, such as `Mac16,5`.
    public var macModel: String?
    /// The language Dirnex is showing, such as `de` or `zh-Hans`.
    public var language: String?
    /// Whether a license is present. Never the key.
    public var licensed: Bool?
    /// The newest Dirnex crash report, already trimmed (``CrashReportTrimmer``).
    public var crashReport: String?

    public init(
        whatHappened: String,
        steps: String? = nil,
        email: String? = nil,
        appVersion: String? = nil,
        appBuild: String? = nil,
        macOS: String? = nil,
        macModel: String? = nil,
        language: String? = nil,
        licensed: Bool? = nil,
        crashReport: String? = nil
    ) {
        self.whatHappened = whatHappened
        self.steps = steps
        self.email = email
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.macOS = macOS
        self.macModel = macModel
        self.language = language
        self.licensed = licensed
        self.crashReport = crashReport
    }

    /// The contract's limits, in UTF-8 bytes. A test compares them with the shared cases.
    public enum Limits {
        /// The whole body.
        public static let bodyBytes = 524_288
        public static let descriptionBytes = 20000
        public static let stepsBytes = 20000
        public static let emailBytes = 254
        /// `appVersion`, `appBuild`, `macOS`, `macModel` and `language`.
        public static let shortFieldBytes = 100
        public static let crashReportBytes = 262_144
    }
}

/// The body's fields, by the names the contract uses.
public enum BugReportField: String, Sendable, CaseIterable, CodingKey {
    case version = "v"
    case whatHappened = "description"
    case steps
    case email
    case appVersion
    case appBuild
    case macOS
    case macModel
    case language
    case licensed
    case crashReport

    /// The most UTF-8 bytes the field's text may hold, or `nil` for a field that isn't a text.
    public var byteLimit: Int? {
        switch self {
        case .whatHappened: BugReport.Limits.descriptionBytes
        case .steps: BugReport.Limits.stepsBytes
        case .email: BugReport.Limits.emailBytes
        case .appVersion, .appBuild, .macOS, .macModel, .language: BugReport.Limits.shortFieldBytes
        case .crashReport: BugReport.Limits.crashReportBytes
        case .version, .licensed: nil
        }
    }
}

/// Why the server would refuse a report, for the refusals a report built by Dirnex can reach. The
/// others (`tooLarge`, `malformed`, `unsupportedVersion`) are about bytes Dirnex never writes, and
/// ``BugReport/body()`` keeps the body under its limit.
public enum BugReportProblem: Hashable, Sendable {
    /// Nothing but blanks in the description.
    case missingDescription
    /// A text over its limit.
    case tooLong(BugReportField)
    /// An email that isn't shaped like one (``BugReportText/isEmailShaped(_:)``).
    case invalidEmail

    /// The name the server answers with.
    public var name: String {
        switch self {
        case .missingDescription: "missingDescription"
        case .tooLong: "tooLong"
        case .invalidEmail: "invalidEmail"
        }
    }

    public var field: BugReportField? {
        switch self {
        case .missingDescription: nil
        case let .tooLong(field): field
        case .invalidEmail: .email
        }
    }
}

public extension BugReport {
    /// The first thing the server would refuse, checked in the server's order, or `nil` when it
    /// would accept the report. Blank optional texts are skipped, as the body leaves them out.
    var problem: BugReportProblem? {
        if BugReportText.isBlank(whatHappened) { return .missingDescription }
        if whatHappened.utf8.count > Limits.descriptionBytes { return .tooLong(.whatHappened) }
        // `licensed` comes between the short fields and the crash report, and can't be wrong here.
        for (field, text) in optionalTexts + [(.crashReport, crashReport)] {
            guard let text = BugReportText.nonBlank(text), let limit = field.byteLimit else { continue }
            if text.utf8.count > limit { return .tooLong(field) }
            if field == .email, !BugReportText.isEmailShaped(text) { return .invalidEmail }
        }
        return nil
    }

    /// The exact bytes Dirnex sends, and shows under *Show What Will Be Sent*: pretty-printed JSON
    /// with the fields in the contract's order, so the crash report comes last. A blank optional
    /// text is left out.
    ///
    /// The typed texts always fit within ``Limits/bodyBytes`` (a test on each side proves it, even
    /// with every character escaped). Only the crash report can push the body over, so it is cut
    /// shorter until the body fits, and dropped if nothing of it would remain.
    func body() throws -> Data {
        var report = self
        var data = try report.encoded()
        while data.count > Limits.bodyBytes, let crashReport = report.crashReport {
            // Every byte cut from the crash report shrinks the body by at least one byte, and the
            // margin covers the escaped line breaks of the marker the cut adds.
            let keep = crashReport.utf8.count - (data.count - Limits.bodyBytes) - 64
            report.crashReport = keep > 0
                ? BugReportText.nonBlank(CrashReportTrimmer.cut(crashReport, toBytes: keep))
                : nil
            data = try report.encoded()
        }
        return data
    }

    /// `steps`, `email` and the short fields, in the order the server checks them.
    private var optionalTexts: [(BugReportField, String?)] {
        [
            (.steps, steps),
            (.email, email),
            (.appVersion, appVersion),
            (.appBuild, appBuild),
            (.macOS, macOS),
            (.macModel, macModel),
            (.language, language)
        ]
    }

    /// Writes the object by hand so the fields keep the contract's order: `JSONEncoder` without
    /// `.sortedKeys` promises no order, and sorted keys would put the crash report before the
    /// description. Each value is still encoded by `JSONEncoder`.
    private func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var members = try [
            (BugReportField.version, encoder.encode(Self.formatVersion)),
            (.whatHappened, encoder.encode(whatHappened))
        ]
        for (field, text) in optionalTexts {
            guard let text = BugReportText.nonBlank(text) else { continue }
            try members.append((field, encoder.encode(text)))
        }
        if let licensed { try members.append((.licensed, encoder.encode(licensed))) }
        if let crashReport = BugReportText.nonBlank(crashReport) {
            try members.append((.crashReport, encoder.encode(crashReport)))
        }
        let lines = members.map { Data("  \"\($0.0.rawValue)\": ".utf8) + $0.1 }
        return Data("{\n".utf8) + lines.joined(separator: Data(",\n".utf8)) + Data("\n}\n".utf8)
    }
}

/// Reads a body the way the server reads it, for the fields Dirnex knows: the shared cases decode
/// through this, so a key name or a type that drifts from the contract fails a test. It throws
/// wherever the server answers `malformed` or `unsupportedVersion` for a JSON body; the refusals
/// the server names after reading the fields are left to ``BugReport/problem``.
///
/// `v` must be 1, a field Dirnex doesn't know is ignored, a blank optional text counts as absent,
/// and `null` is refused rather than read as absent (`decodeIfPresent` would read it as absent).
extension BugReport: Decodable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: BugReportField.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.formatVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Bug report format \(version) is not 1."
            )
        }
        func value<T: Decodable>(_ type: T.Type, _ field: BugReportField) throws -> T? {
            container.contains(field) ? try container.decode(type, forKey: field) : nil
        }
        func text(_ field: BugReportField) throws -> String? {
            try BugReportText.nonBlank(value(String.self, field))
        }
        try self.init(
            whatHappened: value(String.self, .whatHappened) ?? "",
            steps: text(.steps),
            email: text(.email),
            appVersion: text(.appVersion),
            appBuild: text(.appBuild),
            macOS: text(.macOS),
            macModel: text(.macModel),
            language: text(.language),
            licensed: value(Bool.self, .licensed),
            crashReport: text(.crashReport)
        )
    }
}
