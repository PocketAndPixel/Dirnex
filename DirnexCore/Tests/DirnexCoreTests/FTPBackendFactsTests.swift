import Foundation
import Testing

@testable import DirnexCore

/// `FTPBackend` timing its rows: `MLSD`'s exact UTC where the server answers it, `LIST` read on the
/// server's clock where it does not, and the per-connection memory of which one this server is.
@Suite("FTPBackend: exact times")
struct FTPBackendFactsTests {
    private let location = FTPLocation(host: "ftp.example.fr", username: "u", security: .explicit)

    private func backend(_ transport: FakeFTPTransport, zone: TimeZone? = nil) -> FTPBackend {
        FTPBackend(location: location, transport: transport, serverTimeZone: zone)
    }

    private func path(_ remote: String) -> VFSPath {
        VFSPath(backend: .ftp(location), path: remote)
    }

    private static let rows = """
    drwxr-xr-x   2 u g    0 Oct 19 17:47 AGENCE
    -rw-r--r--   1 u g 2936012 Oct 19 16:41 Agences_SYNERGIE_ATS.xml
    lrwxr-xr-x   1 u g    6 Oct 19 17:51 latest -> AGENCE
    """

    /// The followed link is reported as the folder it points at — pyftpdlib's behavior, measured.
    private static let facts = """
    modify=20261019154700;type=dir; AGENCE
    modify=20261019144137;type=file; Agences_SYNERGIE_ATS.xml
    modify=20261019154700;type=dir; latest
    """

    private func transport() -> FakeFTPTransport {
        let transport = FakeFTPTransport()
        transport.listings["/SYNERGIE"] = Self.rows
        transport.factsListings["/SYNERGIE"] = Self.facts
        return transport
    }

    @Test("a listing takes MLSD's exact time, to the second")
    func listingUsesFacts() throws {
        let entries = try backend(transport()).listDirectory(at: path("/SYNERGIE"))
        let file = try #require(entries.first { $0.name == "Agences_SYNERGIE_ATS.xml" })
        // 14:41:37 UTC — 16:41 in Paris, 17:41 in Kyiv, and the seconds LIST never had.
        #expect(file.modificationDate.timeIntervalSince1970 == 1_792_420_897)
        #expect(file.creationDate == file.modificationDate)
    }

    /// End to end, the safety rule: a link the server followed stays a link, so a recursive delete
    /// removes the link and never walks into the folder it names.
    @Test("a followed symlink stays a link with its own LIST stamp")
    func followedLinkStaysALink() throws {
        let timed = try backend(transport()).listDirectory(at: path("/SYNERGIE"))
        let plain = FTPListingParser.parse(Self.rows)
        let link = try #require(timed.first { $0.name == "latest" })
        #expect(link.kind == .symlink)
        #expect(link.symlinkDestination == "AGENCE")
        #expect(link.modificationDate == plain.first { $0.name == "latest" }?.modificationDate)
    }

    /// `RemoteFileRevision` compares a listing's date with a later `stat`'s for exact equality, so
    /// the two must come from the same source or every save over FTP reads as somebody else's edit.
    @Test("stat reads the same exact time the listing did")
    func statAgreesWithListing() throws {
        let sut = backend(transport())
        let listed = try #require(try sut.listDirectory(at: path("/SYNERGIE")).first {
            $0.name == "Agences_SYNERGIE_ATS.xml"
        })
        let stated = try sut.stat(at: path("/SYNERGIE/Agences_SYNERGIE_ATS.xml"))
        #expect(stated.modificationDate == listed.modificationDate)
    }

    @Test("without MLSD, LIST stamps are read on the server's clock")
    func listUsesServerZone() throws {
        let transport = transport()
        transport.refusesFacts = true
        let paris = try #require(TimeZone(identifier: "Europe/Paris"))
        let entries = try backend(transport, zone: paris).listDirectory(at: path("/SYNERGIE"))
        let file = try #require(entries.first { $0.name == "Agences_SYNERGIE_ATS.xml" })
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = paris
        #expect(calendar.component(.hour, from: file.modificationDate) == 16)
        #expect(calendar.component(.minute, from: file.modificationDate) == 41)
    }

    /// The point of the latch: a server without `MLSD` is asked once per connection, not beside
    /// every folder, and a fresh backend (a reconnect) asks again.
    @Test("a server without MLSD is asked once per connection")
    func refusalIsRemembered() throws {
        let transport = transport()
        transport.refusesFacts = true
        let sut = backend(transport)
        _ = try sut.listDirectory(at: path("/SYNERGIE"))
        _ = try sut.listDirectory(at: path("/SYNERGIE"))
        _ = try sut.stat(at: path("/SYNERGIE/AGENCE"))
        #expect(transport.singleListingAsks == [true, false, false])

        _ = try backend(transport).listDirectory(at: path("/SYNERGIE"))
        #expect(transport.singleListingAsks.last == true)
    }

    /// Facts that failed for any other reason say nothing about the next folder.
    @Test("an MLSD that merely failed is asked for again")
    func unavailableIsNotRemembered() throws {
        let transport = transport()
        transport.factsListings = [:]
        let sut = backend(transport)
        _ = try sut.listDirectory(at: path("/SYNERGIE"))
        _ = try sut.listDirectory(at: path("/SYNERGIE"))
        #expect(transport.singleListingAsks == [true, true])
    }

    /// A batch adds a section per folder, and after a refused login `curl` signs in again for every
    /// one of them — so a batch asks only once this connection has seen `MLSD` work.
    @Test("a batch asks for facts only after a single listing has seen them")
    func batchAsksOnlyOnceAnswered() throws {
        let transport = transport()
        transport.listings["/SYNERGIE/AGENCE"] = ""
        let sut = backend(transport)
        let folders = [path("/SYNERGIE"), path("/SYNERGIE/AGENCE")]

        _ = try sut.listDirectories(at: folders, isCancelled: { false })
        #expect(transport.batchListingAsks == [false])

        _ = try sut.listDirectory(at: path("/SYNERGIE"))
        let answers = try sut.listDirectories(at: folders, isCancelled: { false })
        #expect(transport.batchListingAsks == [false, true])
        let file = try #require(answers[0]?.first { $0.name == "Agences_SYNERGIE_ATS.xml" })
        #expect(file.modificationDate.timeIntervalSince1970 == 1_792_420_897)
    }

    @Test("the subtree walk times its rows the same way")
    func subtreeUsesFacts() throws {
        let transport = transport()
        transport.listings["/SYNERGIE/AGENCE"] = ""
        let sut = backend(transport)
        _ = try sut.listDirectory(at: path("/SYNERGIE"))

        let subtree = try #require(
            try sut.subtreeListing(at: path("/SYNERGIE"), isCancelled: { false })
        )
        #expect(transport.batchListingAsks.allSatisfy { $0 })
        let file = try #require(subtree.entries.first { $0.name == "Agences_SYNERGIE_ATS.xml" })
        #expect(file.modificationDate.timeIntervalSince1970 == 1_792_420_897)
        // The link is a row, never a branch: the walk did not descend into it.
        #expect(!transport.listedPaths.contains("/SYNERGIE/latest"))
    }
}
