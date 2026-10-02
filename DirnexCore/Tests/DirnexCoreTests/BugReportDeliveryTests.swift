import Foundation
import Testing

@testable import DirnexCore

/// Getting a report to Oleg (PLAN.md §M30): where it may go, the request that carries it, what the
/// server's answer means, and the email that stands in when there is no answer.
@Suite("Bug report delivery")
struct BugReportDeliveryTests {
    // MARK: - The Help commands

    @Test("the Help category holds Report a Bug…, the website and the release notes")
    func helpCommands() {
        let help = CommandCatalog.all.filter { $0.category == .help }
        #expect(help.map(\.id) == ["help.reportBug", "help.website", "help.releaseNotes"])
        #expect(CommandCatalog.bugReportCommandIDs == ["help.reportBug"])
        #expect(help.allSatisfy { $0.shortcut == nil })
        #expect(LocalizationKey.commandCategory(.help) == "commandCategory.help.title")
    }

    // MARK: - Where it goes

    @Test("an https address is accepted, with the blanks around it removed")
    func httpsEndpoint() {
        let url = BugReportEndpoint.url(fromInfoValue: " https://dirnex.app/api/bug-reports\n")
        #expect(url?.absoluteString == "https://dirnex.app/api/bug-reports")
    }

    @Test("an empty or unusable value is no address, so the feature stays hidden")
    func noEndpoint() {
        let values: [Any?] = [
            nil, "", "  ", "$(DIRNEX_BUG_REPORT_URL)", "dirnex.app/api/bug-reports",
            "http://dirnex.app/api/bug-reports", "ftp://dirnex.app/x", "https://", "https:///x",
            "https://jane:secret@dirnex.app/api/bug-reports", true, NSNumber(value: 1),
            URL(string: "https://dirnex.app")!
        ]
        for value in values {
            #expect(
                BugReportEndpoint.url(fromInfoValue: value) == nil,
                "\(String(describing: value))"
            )
        }
    }

    @Test("plain http reaches only this Mac, and only when allowed")
    func loopbackHTTP() {
        let local = "http://127.0.0.1:9555/api/bug-reports"
        #expect(BugReportEndpoint.url(fromInfoValue: local) == nil)
        #expect(BugReportEndpoint.url(fromInfoValue: local, allowsLoopbackHTTP: true) != nil)
        #expect(
            BugReportEndpoint.url(fromInfoValue: "http://localhost:9555/x", allowsLoopbackHTTP: true) != nil
        )
        #expect(
            BugReportEndpoint.url(fromInfoValue: "http://[::1]:9555/x", allowsLoopbackHTTP: true) != nil
        )
        #expect(
            BugReportEndpoint.url(fromInfoValue: "http://dirnex.app/x", allowsLoopbackHTTP: true) == nil
        )
        #expect(
            BugReportEndpoint.url(fromInfoValue: "http://127.0.0.2/x", allowsLoopbackHTTP: true) == nil
        )
    }

    // MARK: - The request

    @Test("the request is a POST of the exact body, with headers that name nothing about this Mac")
    func request() throws {
        let body = try BugReport(whatHappened: "It froze.").body()
        let endpoint = try #require(URL(string: "https://dirnex.app/api/bug-reports"))
        let request = BugReportRequest.make(to: endpoint, body: body)
        #expect(request.httpMethod == "POST")
        #expect(request.url == endpoint)
        #expect(request.httpBody == body)
        #expect(request.timeoutInterval == BugReportRequest.timeout)
        #expect(!request.httpShouldHandleCookies)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Dirnex")
        #expect(request.value(forHTTPHeaderField: "Accept-Language") == "*")
        #expect(
            request.value(forHTTPHeaderField: "Content-Type") == "application/json; charset=utf-8"
        )
    }

    // MARK: - The answer

    @Test("each answer the contract has", arguments: [
        (201, #"{"id":"7K2Q"}"#, BugReportOutcome.sent(reference: "7K2Q")),
        (201, "", .sent(reference: nil)),
        (201, #"{"id":" "}"#, .sent(reference: nil)),
        (200, "{}", .sent(reference: nil)),
        (400, #"{"error":"tooLong","field":"steps"}"#, .refused("tooLong")),
        (413, #"{"error":"tooLarge"}"#, .refused("tooLarge")),
        (400, "<html>Bad Request</html>", .serverProblem(status: 400)),
        (429, #"{"error":"rateLimited"}"#, .rateLimited),
        (429, "", .rateLimited),
        (500, "", .serverProblem(status: 500)),
        (404, "Not Found", .serverProblem(status: 404)),
        (302, "", .serverProblem(status: 302))
    ])
    func outcome(status: Int, body: String, expected: BugReportOutcome) {
        let outcome = BugReportOutcome(status: status, body: Data(body.utf8))
        #expect(outcome == expected)
        #expect(outcome.isSent == (200..<300).contains(status))
    }

    // MARK: - Email Instead

    private struct Mail {
        let to: String
        let subject: String
        let body: String
    }

    private func decoded(_ url: URL) throws -> Mail {
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = components.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value ?? "" }
        return Mail(to: components.path, subject: value("subject"), body: value("body"))
    }

    @Test("the mail carries the same body, with &, = and + intact")
    func mailCarriesTheBody() throws {
        let report = BugReport(
            whatHappened: "a & b = c + d?\nNext line: 100% ☃",
            email: "jane@example.com"
        )
        let link = try BugReportMail.link(
            for: report,
            subject: "Dirnex bug report",
            crashReportLeftOut: "-"
        )
        #expect(!link.leavesOutCrashReport)
        let mail = try decoded(link.url)
        #expect(link.url.scheme == "mailto")
        #expect(mail.to == BugReportMail.address)
        #expect(mail.subject == "Dirnex bug report")
        let body = try #require(String(bytes: report.body(), encoding: .utf8))
        #expect(mail.body == body.replacingOccurrences(of: "\n", with: "\r\n"))
        #expect(!link.url.absoluteString.contains("+"))
    }

    @Test("a crash report too long for a link is left out, and the mail says so")
    func longCrashReportIsLeftOut() throws {
        let crash = String(repeating: "x", count: BugReportMail.maximumURLLength)
        let report = BugReport(whatHappened: "It crashed.", crashReport: crash)
        let link = try BugReportMail.link(
            for: report,
            subject: "S",
            crashReportLeftOut: "No crash report."
        )
        #expect(link.leavesOutCrashReport)
        #expect(link.url.absoluteString.count < BugReportMail.maximumURLLength)
        let mail = try decoded(link.url)
        #expect(mail.body.hasPrefix("No crash report.\r\n\r\n{"))
        #expect(mail.body.contains("It crashed."))
        #expect(!mail.body.contains("crashReport"))

        let short = BugReport(whatHappened: "It crashed.", crashReport: "short")
        let kept = try BugReportMail.link(
            for: short,
            subject: "S",
            crashReportLeftOut: "No crash report."
        )
        #expect(!kept.leavesOutCrashReport)
        #expect(try decoded(kept.url).body.contains("short"))
    }
}
