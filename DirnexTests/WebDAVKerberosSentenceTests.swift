import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The two refusals Negotiate added to a WebDAV connect (PLAN.md §M38 Slice 6): a named account on a
/// server that takes only the Mac's ticket, and a ticket the server would not take. Each asks the
/// user for something different from a wrong password, so each is its own sentence.
@Suite("WebDAV connect: the Kerberos sentences")
struct WebDAVKerberosSentenceTests {
    private static let keys = [
        "This server signs in only with Kerberos, using this Mac’s ticket. Leave the user name and "
            + "password empty to connect with it.",
        "This server signs in with Kerberos and didn’t accept this Mac’s ticket. Get a ticket in "
            + "Ticket Viewer, and connect by the server’s name rather than its address."
    ]

    /// Read in whatever language the test host runs, so compared with each other rather than with
    /// English text.
    @Test("each Kerberos refusal is its own sentence, apart from the password ones")
    @MainActor
    func ownSentences() {
        let detail = PanelViewController.webDAVConnectFailureDetail
        let kerberosOnly = detail(WebDAVConnectError.kerberosOnly)
        let ticketRefused = detail(WebDAVConnectError.kerberosTicketRefused)
        let others = [
            detail(WebDAVConnectError.credentialsRequired),
            detail(WebDAVConnectError.credentialsRefused),
            detail(WebDAVConnectError.unsupportedAuthentication(schemes: ["negotiate"]))
        ]
        #expect(kerberosOnly != ticketRefused)
        #expect(!others.contains(kerberosOnly) && !others.contains(ticketRefused))
        #expect(kerberosOnly.contains("Kerberos") && ticketRefused.contains("Kerberos"))
    }

    @Test("both are translated in every shipped language, Kerberos kept as a name")
    func translated() throws {
        for language in LocalizedBundles.translated {
            let bundle = try LocalizedBundles.bundle(for: language)
            for key in Self.keys {
                let value = LocalizedBundles.translation(key, in: bundle)
                #expect(value != nil && value != key, "\(language.code): \(key.prefix(40))")
                #expect(value?.contains("Kerberos") == true, "\(language.code)")
            }
        }
    }
}
