import Foundation
import Testing

@testable import DirnexCore

@Suite("LicenseDay")
struct LicenseDayTests {
    @Test("parses only real days, written exactly YYYY-MM-DD, from the year 2000")
    func parsing() {
        for text in ["2026-09-29", "2028-02-29", "2000-01-01", "9999-12-31"] {
            #expect(LicenseDay(text)?.description == text)
        }
        for text in [
            "2027-02-29", "2027-02-30", "2026-04-31", "2026-13-01", "2026-00-10", "2026-09-00",
            "2026-9-29", "1999-12-31", "2026-09-29T00:00:00Z", " 2026-09-29", "2026/09/29",
            "２０２６-09-29", "+2026-09-2", ""
        ] {
            #expect(LicenseDay(text) == nil, "\(text)")
        }
    }

    @Test("orders by year, then month, then day")
    func ordering() throws {
        let days = try ["2026-12-31", "2027-01-01", "2027-01-02", "2027-02-01", "2028-01-01"]
            .map { try #require(LicenseDay($0)) }
        #expect(days == days.sorted())
        #expect(try #require(LicenseDay("2027-01-01")) == LicenseDay(year: 2027, month: 1, day: 1))
    }

    @Test("a moment belongs to its UTC day unless another zone is asked for")
    func fromDate() throws {
        // 2027-03-12 23:30 UTC is already 13 March in Kyiv and still 12 March in California.
        let moment = Date(timeIntervalSince1970: 1_804_894_200)
        #expect(LicenseDay(moment).description == "2027-03-12")
        let kyiv = try #require(TimeZone(identifier: "Europe/Kyiv"))
        let california = try #require(TimeZone(identifier: "America/Los_Angeles"))
        #expect(LicenseDay(moment, in: kyiv).description == "2027-03-13")
        #expect(LicenseDay(moment, in: california).description == "2027-03-12")
        #expect(LicenseDay(moment.addingTimeInterval(1800)).description == "2027-03-13")
    }

    @Test("shown in any time zone, a day prints as itself")
    func displayDoesNotShift() throws {
        let day = try #require(LicenseDay("2027-03-12"))
        for identifier in [
            "Pacific/Kiritimati",
            "Europe/Kyiv",
            "UTC",
            "America/Los_Angeles",
            "Pacific/Pago_Pago"
        ] {
            let zone = try #require(TimeZone(identifier: identifier))
            #expect(LicenseDay(day.date(in: zone), in: zone) == day, "\(identifier)")
        }
    }

    @Test("negative control: midnight UTC shown in California is the day before")
    func midnightShifts() throws {
        // What `date(in:)` avoids: the naive Date for the day, printed where the user is.
        let midnightUTC = try #require(LicenseDay("2027-03-12")).date(in: .gmt).addingTimeInterval(
            -12 * 3600
        )
        let california = try #require(TimeZone(identifier: "America/Los_Angeles"))
        #expect(LicenseDay(midnightUTC, in: california).description == "2027-03-11")
    }
}
