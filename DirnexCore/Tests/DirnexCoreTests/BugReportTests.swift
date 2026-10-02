import Foundation
import Testing

@testable import DirnexCore

/// The report a Report a Bug dialog sends (PLAN.md §M30): what goes in, how it's written, and the
/// text rules it shares with the server. The shared cases are ``BugReportVectorTests``.
@Suite("Bug report")
struct BugReportTests {
    static let home = BugReportRedaction(homePath: "/Users/jane")
    static let system = BugReportSystemInfo(
        appVersion: "1.4.0-beta.3",
        appBuild: "512",
        macOS: "26.0.1 (25A362)",
        macModel: "Mac16,5",
        language: "de"
    )

    private func makeForm(_ whatHappened: String = "The pane stops updating.") -> BugReportForm {
        var form = BugReportForm()
        form.whatHappened = whatHappened
        return form
    }

    private func fields(of body: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    /// Whether any value in `body` names the home folder, in either spelling a report can hold.
    ///
    /// It reads the values, not the body's text: in the body a crash report's `\/Users\/jane` is
    /// escaped once more, to `\\/Users\\/jane`, which a search of the text for either spelling
    /// misses. The negative control below found that.
    private func leaksHome(_ body: Data) throws -> Bool {
        try fields(of: body).values.contains { value in
            guard let text = value as? String else { return false }
            return text.contains("/Users/jane") || text.contains(#"\/Users\/jane"#)
        }
    }

    // MARK: - What goes in

    @Test("every box is ticked by default, except the crash report's")
    func defaults() {
        let form = BugReportForm()
        #expect(form.includesVersion && form.includesMacOS && form.includesMacModel)
        #expect(form.includesLanguage && form.includesLicenseState)
        #expect(!form.includesCrashReport)
    }

    @Test("ticked boxes carry their facts, and the crash report stays out until its box is ticked")
    func tickedBoxes() {
        let report = makeForm().report(
            system: Self.system,
            licensed: true,
            crashReport: TrimmedCrashReport("Crash", redaction: Self.home),
            redaction: Self.home
        )
        #expect(report == BugReport(
            whatHappened: "The pane stops updating.",
            appVersion: "1.4.0-beta.3",
            appBuild: "512",
            macOS: "26.0.1 (25A362)",
            macModel: "Mac16,5",
            language: "de",
            licensed: true
        ))
    }

    @Test(
        "with every box unticked and nothing optional typed, the body holds only v and the description"
    )
    func nothingTicked() throws {
        var form = makeForm()
        form.includesVersion = false
        form.includesMacOS = false
        form.includesMacModel = false
        form.includesLanguage = false
        form.includesLicenseState = false
        form.steps = " \n "
        form.email = "\t"
        let report = form.report(
            system: Self.system,
            licensed: true,
            crashReport: TrimmedCrashReport("Crash", redaction: Self.home),
            redaction: Self.home
        )
        #expect(try Set(fields(of: report.body()).keys) == ["v", "description"])
    }

    @Test("each box leaves out only its own field")
    func eachBox() throws {
        let boxes: [(WritableKeyPath<BugReportForm, Bool>, Set<String>)] = [
            (\.includesVersion, ["appVersion", "appBuild"]),
            (\.includesMacOS, ["macOS"]),
            (\.includesMacModel, ["macModel"]),
            (\.includesLanguage, ["language"]),
            (\.includesLicenseState, ["licensed"])
        ]
        let everything = try Set(fields(of: makeForm().report(
            system: Self.system, licensed: false, crashReport: nil, redaction: Self.home
        ).body()).keys)
        for (box, keys) in boxes {
            var form = makeForm()
            form[keyPath: box] = false
            let report = form.report(
                system: Self.system,
                licensed: false,
                crashReport: nil,
                redaction: Self.home
            )
            #expect(try Set(fields(of: report.body()).keys) == everything.subtracting(keys))
        }
    }

    @Test("typed texts lose the blanks around them, and a blank one is left out")
    func typedTexts() {
        var form = makeForm(" \u{3000}It froze.\n\n")
        form.steps = "\n1. Press F5.\n"
        form.email = "  jane@example.com \u{FEFF}"
        let report = form.report(
            system: Self.system,
            licensed: false,
            crashReport: nil,
            redaction: Self.home
        )
        #expect(report.whatHappened == "It froze.")
        #expect(report.steps == "1. Press F5.")
        #expect(report.email == "jane@example.com")
        #expect(report.problem == nil)
    }

    @Test("the home folder becomes ~ in the description, the steps and the crash report")
    func homeIsShortened() throws {
        var form = makeForm("Copying /Users/jane/Movies/Holiday fails.")
        form.steps = "Press F5 on /Users/jane/Movies."
        form.includesCrashReport = true
        let crash = #"{"procPath":"\/Users\/jane\/Applications\/Dirnex.app"}"#
        let report = form.report(
            system: Self.system,
            licensed: false,
            crashReport: TrimmedCrashReport(crash, redaction: Self.home),
            redaction: Self.home
        )
        #expect(report.whatHappened == "Copying ~/Movies/Holiday fails.")
        #expect(report.steps == "Press F5 on ~/Movies.")
        #expect(report.crashReport == #"{"procPath":"~\/Applications\/Dirnex.app"}"#)
        #expect(try !leaksHome(report.body()))
    }

    @Test("negative control: a redaction that leaves the home path in is caught")
    func homeLeakIsCaught() throws {
        var form = makeForm("Copying /Users/jane/Movies fails.")
        form.includesCrashReport = true
        let crash = #"{"procPath":"\/Users\/jane\/Applications\/Dirnex.app"}"#
        let none = BugReportRedaction(homePath: "")
        #expect(
            try leaksHome(
                form.report(system: Self.system, licensed: false, crashReport: nil, redaction: none).body(
                )
            )
        )
        form.whatHappened = "It crashed."
        #expect(
            try leaksHome(
                form.report(
                    system: Self.system,
                    licensed: false,
                    crashReport: TrimmedCrashReport(crash, redaction: none),
                    redaction: none
                ).body()
            )
        )
    }

    @Test("the crash report is trimmed on the way in")
    func crashReportIsTrimmed() {
        var form = makeForm()
        form.includesCrashReport = true
        let crash = #""crashReporterKey" : "E32068AD-5162-02F0-4CAE-9F6BE9F35E9C""#
        let report = form.report(
            system: Self.system,
            licensed: false,
            crashReport: TrimmedCrashReport(crash, redaction: Self.home),
            redaction: Self.home
        )
        #expect(report.crashReport == #""crashReporterKey" : """#)

        let none = form.report(
            system: Self.system,
            licensed: false,
            crashReport: nil,
            redaction: Self.home
        )
        #expect(none.crashReport == nil)
    }

    // MARK: - How it's written

    @Test("the body is pretty JSON in the contract's order, with slashes as they are")
    func bodyFormat() throws {
        let report = BugReport(
            whatHappened: "Crashed on ~/Movies.",
            email: "jane@example.com",
            licensed: false,
            crashReport: "{}"
        )
        let expected = """
        {
          "v": 1,
          "description": "Crashed on ~/Movies.",
          "email": "jane@example.com",
          "licensed": false,
          "crashReport": "{}"
        }

        """
        #expect(try String(bytes: report.body(), encoding: .utf8) == expected)
    }

    @Test("a blank optional text is left out of the body")
    func blankTextsAreLeftOut() throws {
        let report = BugReport(whatHappened: "It froze.", steps: " ", email: "", crashReport: "\n")
        #expect(try Set(fields(of: report.body()).keys) == ["v", "description"])
    }

    @Test("the typed texts at their limits fit, even when JSON escapes every character")
    func typedTextsAlwaysFit() throws {
        let escaped = String(repeating: "\u{01}", count: BugReport.Limits.descriptionBytes)
        let report = BugReport(
            whatHappened: escaped,
            steps: escaped,
            email: String(repeating: "a", count: 250) + "@b.c",
            appVersion: String(repeating: "\"", count: 100),
            licensed: true
        )
        #expect(report.problem == nil)
        let body = try report.body()
        #expect(body.count > 2 * 6 * BugReport.Limits.descriptionBytes)
        #expect(body.count <= BugReport.Limits.bodyBytes)
        #expect(try JSONDecoder().decode(BugReport.self, from: body) == report)
    }

    @Test("a crash report that escapes into a body over the limit is cut until it fits")
    func crashReportIsCutToFit() throws {
        // At its own limit, but every quote is written as two bytes in the body.
        let quotes = String(repeating: "\"", count: BugReport.Limits.crashReportBytes)
        let report = BugReport(whatHappened: "It crashed.", crashReport: quotes)
        #expect(report.problem == nil)

        let body = try report.body()
        #expect(body.count <= BugReport.Limits.bodyBytes)
        let sent = try #require(JSONDecoder().decode(BugReport.self, from: body).crashReport)
        #expect(sent.hasSuffix(CrashReportTrimmer.cutMarker))
        #expect(sent.utf8.count < quotes.utf8.count)
        #expect(sent.dropLast(CrashReportTrimmer.cutMarker.count).allSatisfy { $0 == "\"" })
    }
}
