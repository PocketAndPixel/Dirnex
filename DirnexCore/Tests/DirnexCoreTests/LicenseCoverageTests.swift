import Foundation
import Testing

@testable import DirnexCore

@Suite("License coverage")
struct LicenseCoverageTests {
    private static func day(_ text: String) -> LicenseDay {
        guard let day = LicenseDay(text) else { fatalError("bad fixture day \(text)") }
        return day
    }

    private static func key(until: String) -> LicenseKey {
        LicenseKey(
            text: "dnx1.test",
            id: "TESTID",
            licensee: "Jane",
            issued: day("2026-09-29"),
            until: day(until)
        )
    }

    /// A release day, the key's `until`, and whether the key covers that release.
    private struct Row {
        let release: String?
        let until: String
        let covered: Bool
    }

    /// The boundary rows are the point: released *on* the end day is covered, the day after is not.
    private static let table: [Row] = [
        Row(release: "2027-03-11", until: "2027-03-12", covered: true),
        Row(release: "2027-03-12", until: "2027-03-12", covered: true),
        Row(release: "2027-03-13", until: "2027-03-12", covered: false),
        Row(release: "2028-01-01", until: "2027-12-31", covered: false),
        Row(release: "2026-09-29", until: "2027-09-29", covered: true),
        Row(release: nil, until: "2020-01-01", covered: true)
    ]

    @Test("a key covers every release up to and including its end day")
    func coverage() {
        for row in Self.table {
            let covered = Self.key(until: row.until).covers(releaseDay: row.release.map(Self.day))
            #expect(covered == row.covered, "\(row)")
        }
    }

    @Test("negative control: a check that is off by one day disagrees with the table")
    func offByOneIsCaught() {
        let offByOne: (LicenseDay?, LicenseDay) -> Bool = { release, until in
            guard let release else { return true }
            return release < until
        }
        let disagreements = Self.table.filter { row in
            offByOne(row.release.map(Self.day), Self.day(row.until)) != row.covered
        }
        #expect(disagreements.count == 1)
    }

    @Test("status: no key, a key that covers this build, and one whose period ended before it")
    func status() {
        let key = Self.key(until: "2027-03-12")
        #expect(LicenseStatus(key: nil, buildReleaseDay: Self.day("2027-01-01")) == .unlicensed)
        #expect(LicenseStatus(key: key, buildReleaseDay: Self.day("2027-03-12")) == .licensed(key))
        #expect(LicenseStatus(key: key, buildReleaseDay: Self.day("2027-03-13")) == .lapsed(key))
        #expect(LicenseStatus(key: key, buildReleaseDay: nil) == .licensed(key))
        #expect(LicenseStatus.lapsed(key).key == key)
        #expect(!LicenseStatus.lapsed(key).isCovered)
        #expect(!LicenseStatus.unlicensed.isCovered)
    }

    // MARK: - The notice before an update

    private func notice(
        key: LicenseKey?,
        current: String?,
        update: String?
    ) -> UpdateCoverageNotice? {
        UpdateCoverageNotice.notice(
            key: key,
            currentReleaseDay: current.map(Self.day),
            updateVersion: "1.4.0",
            updateReleaseDay: update.map(Self.day)
        )
    }

    @Test("the notice appears when an update would start the reminder, and names the end day")
    func noticeWhenTheUpdateIsNotCovered() {
        let key = Self.key(until: "2027-03-12")
        let notice = notice(key: key, current: "2027-02-01", update: "2027-03-13")
        #expect(notice == UpdateCoverageNotice(until: Self.day("2027-03-12"), version: "1.4.0"))
    }

    @Test("no notice when the update changes nothing about the reminder")
    func noNoticeOtherwise() {
        let key = Self.key(until: "2027-03-12")
        // Covered, on the boundary, and undated.
        #expect(notice(key: key, current: "2027-02-01", update: "2027-03-12") == nil)
        #expect(notice(key: key, current: "2027-02-01", update: nil) == nil)
        // No key: the reminder is there either way.
        #expect(notice(key: nil, current: "2027-02-01", update: "2027-04-01") == nil)
        // The running build is already past the key's end, so it already reminds.
        #expect(notice(key: key, current: "2027-03-20", update: "2027-04-01") == nil)
    }

    @Test("an undated running build counts as covered, so an uncovered update still gets the notice")
    func undatedCurrentBuild() {
        let key = Self.key(until: "2027-03-12")
        #expect(notice(key: key, current: nil, update: "2027-04-01") != nil)
    }
}
