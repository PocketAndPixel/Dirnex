import Foundation
import Testing

@testable import DirnexCore

/// One case from `Fixtures/bug-report-vectors.json`, the file both repos check (PLAN.md §M30).
struct BugReportVector: Sendable, CustomTestStringConvertible {
    let name: String
    let note: String
    /// `accepted`, or the name of the server's refusal.
    let expect: String
    let field: String?
    /// The body as JSON, or `nil` for a case given as raw bytes, which only the server can read.
    let body: Data?
    /// What the server keeps, for an accepted case.
    let report: Data?

    var testDescription: String {
        "\(name) → \(expect)"
    }

    /// The refusals a JSON body earns before its fields are judged. Dirnex's decoder throws for
    /// exactly these.
    var isRefusedWhileReading: Bool {
        ["malformed", "unsupportedVersion"].contains(expect)
    }
}

struct BugReportVectorFile: Sendable {
    let limits: [String: Int]
    let blankCharacters: [UInt32]
    let vectors: [BugReportVector]

    /// The fixture, or `nil` when it's missing. A missing file must fail ``fixtureIsComplete``
    /// rather than leave the parameterized tests with nothing to run, which would pass.
    ///
    /// Read with `JSONSerialization` because a body may be any JSON (an array, `null`, a number
    /// where a text belongs) and is handed to `JSONDecoder` again as bytes. Nothing is read from it
    /// with an `as?` cast that would bridge `true` to 1 (docs/NOTES.md ▸ License keys).
    static let shared: BugReportVectorFile? = {
        guard let url = Bundle.module.url(
            forResource: "bug-report-vectors",
            withExtension: "json",
            subdirectory: "Fixtures"
        ),
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let limits = object["limits"] as? [String: Int],
            let blank = object["blankCharacters"] as? [UInt32],
            let cases = object["vectors"] as? [[String: Any]]
        else {
            return nil
        }
        let json = { (value: Any?) in
            value.flatMap { try? JSONSerialization.data(
                withJSONObject: $0,
                options: .fragmentsAllowed
            ) }
        }
        let vectors = cases.compactMap { item -> BugReportVector? in
            guard let name = item["name"] as? String, let expect = item["expect"] as? String else {
                return nil
            }
            return BugReportVector(
                name: name,
                note: item["note"] as? String ?? "",
                expect: expect,
                field: item["field"] as? String,
                body: item.keys.contains("body") ? json(item["body"]) : nil,
                report: json(item["report"])
            )
        }
        guard vectors.count == cases.count else { return nil }
        return BugReportVectorFile(limits: limits, blankCharacters: blank, vectors: vectors)
    }()
}

/// The shared cases, written in the private repo next to the server's contract
/// (`web/src/bug-reports/`) and copied here unchanged. The server's own tests check the same file,
/// so a body Dirnex builds is one the server accepts, and a refusal Dirnex predicts is the one the
/// server would give.
@Suite("Bug report vectors")
struct BugReportVectorTests {
    private static var bodyVectors: [BugReportVector] {
        (BugReportVectorFile.shared?.vectors ?? []).filter { $0.body != nil }
    }

    @Test("the fixture is there, and every refusal Dirnex can predict has a case")
    func fixtureIsComplete() throws {
        let file = try #require(BugReportVectorFile.shared)
        #expect(file.vectors.count >= 40)
        let outcomes = Set(file.vectors.map(\.expect))
        let predictable: [BugReportProblem] = [.missingDescription, .tooLong(.steps), .invalidEmail]
        #expect(outcomes.isSuperset(of: ["accepted", "malformed", "unsupportedVersion"]))
        #expect(outcomes.isSuperset(of: predictable.map(\.name)))
    }

    @Test("the limits are the contract's")
    func limits() throws {
        let file = try #require(BugReportVectorFile.shared)
        #expect(file.limits == [
            "bodyBytes": BugReport.Limits.bodyBytes,
            "descriptionBytes": BugReport.Limits.descriptionBytes,
            "stepsBytes": BugReport.Limits.stepsBytes,
            "emailBytes": BugReport.Limits.emailBytes,
            "shortFieldBytes": BugReport.Limits.shortFieldBytes,
            "crashReportBytes": BugReport.Limits.crashReportBytes
        ])
    }

    @Test("the blank characters are the contract's")
    func blankCharacters() throws {
        let file = try #require(BugReportVectorFile.shared)
        #expect(Set(file.blankCharacters) == Set(BugReportText.blankScalars.map(\.value)))
        #expect(file.blankCharacters.count == BugReportText.blankScalars.count)
    }

    @Test("each case with a JSON body", arguments: bodyVectors)
    func vector(_ vector: BugReportVector) throws {
        let body = try #require(vector.body)
        if vector.isRefusedWhileReading {
            #expect(throws: DecodingError.self, "\(vector.note)") {
                try JSONDecoder().decode(BugReport.self, from: body)
            }
            return
        }
        let report = try JSONDecoder().decode(BugReport.self, from: body)
        #expect(report.problem?.name ?? "accepted" == vector.expect, "\(vector.note)")
        #expect(report.problem?.field?.rawValue == vector.field, "\(vector.note)")
        guard vector.expect == "accepted" else { return }

        // What the server keeps, and what Dirnex writes for the same report, read back.
        let keptBody = try #require(vector.report)
        let kept = try JSONDecoder().decode(BugReport.self, from: keptBody)
        #expect(report == kept)
        let written = try report.body()
        #expect(try JSONDecoder().decode(BugReport.self, from: written) == kept)
        #expect(try keys(of: written) == keys(of: keptBody))
    }

    @Test("negative control: a blank test built on Character.isWhitespace misjudges two cases")
    func characterWhitespaceDisagrees() throws {
        let judged = Self.bodyVectors.filter { ["accepted", "missingDescription"].contains($0.expect) }
        var misjudged: [String] = []
        for vector in judged {
            let body = try #require(vector.body)
            let report = try JSONDecoder().decode(BugReport.self, from: body)
            let blank = report.whatHappened.allSatisfy(\.isWhitespace)
            if blank != (vector.expect == "missingDescription") { misjudged.append(vector.name) }
        }
        // U+0085 counts as whitespace to Swift and not to JavaScript's trim; U+FEFF the other way.
        #expect(misjudged.sorted() == ["description-unicode-blank", "next-line-is-not-blank"])
    }

    @Test("negative control: looking for the @ among Characters misses it before a combining mark")
    func characterAtSignIsMissed() throws {
        let vector = try #require(
            Self.bodyVectors.first { $0.name == "email-at-before-a-combining-mark" }
        )
        let body = try #require(vector.body)
        let email = try #require(JSONDecoder().decode(BugReport.self, from: body).email)
        #expect(!email.contains(Character("@")))
        #expect(BugReportText.isEmailShaped(email))
    }

    private func keys(of body: Data) throws -> Set<String> {
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        return Set(object.keys)
    }
}
