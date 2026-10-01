import Foundation
import Testing

@testable import DirnexCore

/// The text rules a bug report shares with the server (PLAN.md §M30), and the refusals Dirnex
/// predicts from them. The shared cases are ``BugReportVectorTests``.
@Suite("Bug report text")
struct BugReportTextTests {
    // MARK: - Problems, in the server's order

    @Test("a blank description comes before a bad email")
    func firstProblemWins() {
        #expect(BugReport(whatHappened: " \u{2028}", email: "jane").problem == .missingDescription)
        #expect(BugReport(whatHappened: "It froze.", email: "jane").problem == .invalidEmail)
    }

    @Test("each limit is checked in bytes")
    func limitsInBytes() {
        let half = BugReport.Limits.descriptionBytes / 2
        #expect(BugReport(whatHappened: String(repeating: "é", count: half)).problem == nil)
        #expect(
            BugReport(whatHappened: String(repeating: "é", count: half) + "a").problem == .tooLong(
                .whatHappened
            )
        )
        #expect(
            BugReport(whatHappened: "x", language: String(repeating: "é", count: 51)).problem == .tooLong(
                .language
            )
        )
        let crash = String(repeating: "a", count: BugReport.Limits.crashReportBytes + 1)
        #expect(BugReport(whatHappened: "x", crashReport: crash).problem == .tooLong(.crashReport))
    }

    @Test("a problem names the server's refusal and field")
    func problemNames() {
        #expect(BugReportProblem.missingDescription.name == "missingDescription")
        #expect(BugReportProblem.missingDescription.field == nil)
        #expect(BugReportProblem.tooLong(.whatHappened).field?.rawValue == "description")
        #expect(BugReportProblem.invalidEmail.field == .email)
    }

    // MARK: - Text rules

    @Test("trimming removes the blank list at both ends, and nothing else")
    func trimming() {
        #expect(BugReportText.trimmed(" \u{FEFF}x y\u{3000}\n") == "x y")
        #expect(BugReportText.trimmed("\u{85}x\u{200B}") == "\u{85}x\u{200B}")
        #expect(BugReportText.trimmed(" \t ").isEmpty)
        #expect(BugReportText.isBlank(""))
        #expect(!BugReportText.isBlank("\u{200B}"))
    }

    @Test("a prefix is cut between characters")
    func prefixKeepsCharactersWhole() {
        #expect(BugReportText.prefix("abc", maxBytes: 3) == "abc")
        #expect(BugReportText.prefix("abc", maxBytes: 0).isEmpty)
        // `e` + U+0301 is one character of 3 bytes: cutting after the `e` would drop the accent.
        #expect(BugReportText.prefix("ae\u{301}", maxBytes: 2) == "a")
        #expect(BugReportText.prefix("ae\u{301}", maxBytes: 4) == "ae\u{301}")
        // A family emoji is 18 bytes and one character.
        #expect(BugReportText.prefix("a👨‍👩‍👧", maxBytes: 10) == "a")
        #expect(BugReportText.prefix("éé", maxBytes: 3) == "é")
    }

    @Test("an email has one @, a dot in the domain, and no spaces")
    func emailShape() {
        for good in ["jane@example.com", "j@b.c", "jürgen@exämple.de", "a.b+c@sub.example.co.uk"] {
            #expect(BugReportText.isEmailShaped(good), "\(good)")
        }
        let bad = [
            "",
            "jane",
            "@example.com",
            "jane@",
            "jane@example",
            "jane@.com",
            "jane@example.",
            "a@b@c.d",
            "jane doe@example.com",
            "jane@example.com\n",
            "jane@exam\u{7F}ple.com"
        ]
        for text in bad {
            #expect(!BugReportText.isEmailShaped(text), "\(text)")
        }
    }
}
