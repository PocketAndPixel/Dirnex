import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// The FTP server's time zone surviving the Connect sheet.
///
/// The sheet is also the Edit… sheet, and it writes the record back from what it reads
/// (`PanelViewController+EditServer`), so a setting the picker cannot show is a setting the next edit
/// erases — the shape the certificate pin took for the whole life of FTPS (`ConnectServerFTPTrustTests`).
@Suite("Connect sheet FTP time zone")
@MainActor
struct ConnectServerFTPTimeZoneTests {
    private func fields() -> ConnectServerFTPFields {
        let fields = ConnectServerFTPFields()
        _ = fields.buildRows(in: NSGridView(views: [[NSGridCell.emptyContentView]]))
        fields.host.stringValue = "ftp.example.fr"
        fields.user.stringValue = "oleg"
        fields.password.stringValue = "hunter2"
        return fields
    }

    private let location = FTPLocation(host: "ftp.example.fr", port: 21, username: "oleg")

    private func zone(of form: ConnectServerPrompt.Form?) -> String?? {
        guard case let .ftp(_, _, _, zone)? = form?.endpoint else { return .none }
        return .some(zone)
    }

    @Test("a new connection reads its times on this Mac's clock")
    func defaultIsThisMac() {
        let fields = fields()
        #expect(fields.timeZoneControl.indexOfSelectedItem == 0)
        #expect(zone(of: fields.readForm(saveName: "Paris")) == .some(nil))
    }

    @Test("a saved zone is shown and read back, for a named and an anonymous login")
    func savedZoneRoundTrips() {
        let fields = fields()
        fields.apply(location: location, authentication: .password, serverTimeZone: "Europe/Paris")
        fields.password.stringValue = "hunter2"
        #expect(fields.timeZoneControl.titleOfSelectedItem?.hasPrefix("Europe/Paris (GMT") == true)
        #expect(zone(of: fields.readForm(saveName: "Paris")) == .some("Europe/Paris"))

        fields.anonymousCheckbox.performClick(nil)
        #expect(zone(of: fields.readForm(saveName: "Paris")) == .some("Europe/Paris"))
    }

    @Test("UTC is a choice of its own, right under the default")
    func utcIsOffered() {
        let fields = fields()
        fields.apply(location: location, authentication: .password, serverTimeZone: "UTC")
        fields.password.stringValue = "hunter2"
        #expect(fields.timeZoneControl.indexOfSelectedItem == 1)
        #expect(zone(of: fields.readForm(saveName: "Paris")) == .some("UTC"))
    }

    /// A record saved on another Mac, or under an alias a later macOS drops, must come back exactly
    /// as it was — not as "Same as this Mac", which an edit would then write over the user's setting.
    @Test("a zone this Mac does not list is kept, not reset to the default")
    func unknownZoneIsKept() {
        let fields = fields()
        fields.apply(
            location: location,
            authentication: .password,
            serverTimeZone: "Mars/Olympus_Mons"
        )
        fields.password.stringValue = "hunter2"
        #expect(fields.timeZoneControl.titleOfSelectedItem == "Mars/Olympus Mons")
        #expect(zone(of: fields.readForm(saveName: "Paris")) == .some("Mars/Olympus_Mons"))

        // Applying it again finds the item it added rather than adding a second.
        let count = fields.timeZoneControl.numberOfItems
        fields.apply(
            location: location,
            authentication: .password,
            serverTimeZone: "Mars/Olympus_Mons"
        )
        #expect(fields.timeZoneControl.numberOfItems == count)
    }

    @Test("prefilling a server with no zone clears one left from a previous prefill")
    func prefillClearsAStaleZone() {
        let fields = fields()
        fields.apply(location: location, authentication: .password, serverTimeZone: "Europe/Paris")
        fields.apply(location: location, authentication: .password, serverTimeZone: nil)
        fields.password.stringValue = "hunter2"
        #expect(zone(of: fields.readForm(saveName: "Paris")) == .some(nil))
    }

    /// The offset in each title is the one in force on the day, so a zone with summer time reads
    /// differently in July and January, and a half-hour zone keeps its minutes.
    @Test("an item's title carries the offset in force on the day")
    func offsetTitles() throws {
        let july = Date(timeIntervalSince1970: 1_783_000_000) // 2026-07-02
        let january = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01
        let paris = try #require(TimeZone(identifier: "Europe/Paris"))
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        let kolkata = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let utc = try #require(TimeZone(identifier: "UTC"))
        #expect(ConnectServerFTPFields.offset(of: paris, at: july) == "GMT+2")
        #expect(ConnectServerFTPFields.offset(of: paris, at: january) == "GMT+1")
        #expect(ConnectServerFTPFields.offset(of: newYork, at: january) == "GMT−5")
        #expect(ConnectServerFTPFields.offset(of: kolkata, at: july) == "GMT+5:30")
        #expect(ConnectServerFTPFields.offset(of: utc, at: july) == "GMT")
        #expect(
            ConnectServerFTPFields.timeZoneItem(identifier: "America/New_York", at: january).title
                == "America/New York (GMT−5)"
        )
    }
}
