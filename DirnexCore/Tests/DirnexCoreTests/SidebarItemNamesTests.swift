import Foundation
import Testing

@testable import DirnexCore

@Suite("Sidebar item names")
struct SidebarItemNamesTests {
    // MARK: - Identities

    /// The strings are persisted — the Cloud order has been stored under them since the section
    /// became draggable — so a drift would silently reset every arranged row and every chosen name.
    @Test("the Cloud identities are the spellings already on disk")
    func identitiesArePinned() {
        let mount = CloudStorageMount(
            directoryName: "GoogleDrive-some-one@gmail.com",
            providerID: "GoogleDrive",
            accountLabel: "some-one@gmail.com",
            name: "Google Drive",
            path: .local("/Users/u/Library/CloudStorage/GoogleDrive-some-one@gmail.com")
        )
        #expect(CloudPlaceIdentity.of(.iCloudDrive(.local("/any"))) == "icloud")
        #expect(CloudPlaceIdentity.of(.photos) == "photos")
        #expect(CloudPlaceIdentity.of(.cloudMount(mount)) == "mount:GoogleDrive-some-one@gmail.com")
    }

    @Test("a mount is keyed off its directory, not the label a second account changes")
    func mountIdentityIgnoresTheLabel() {
        let path = VFSPath.local("/Users/u/Library/CloudStorage/Dropbox-Home")
        let alone = CloudStorageMount(
            directoryName: "Dropbox-Home", providerID: "Dropbox", accountLabel: "Home",
            name: "Dropbox", path: path
        )
        let beside = CloudStorageMount(
            directoryName: "Dropbox-Home", providerID: "Dropbox", accountLabel: "Home",
            name: "Home — Dropbox", path: path
        )
        #expect(
            CloudPlaceIdentity.of(.cloudMount(alone)) == CloudPlaceIdentity.of(.cloudMount(beside))
        )
    }

    @Test("places outside the Cloud section have no identity")
    func otherPlacesHaveNone() {
        #expect(CloudPlaceIdentity.of(.recents) == nil)
        #expect(CloudPlaceIdentity.of(.trash) == nil)
        #expect(CloudPlaceIdentity.of(.favorite(FavoriteEntry(path: .local("/tmp")))) == nil)
    }

    // MARK: - Renaming

    @Test("a chosen name replaces the default")
    func renameStoresTheName() {
        var names = SidebarItemNames()
        let changed = names.rename("icloud", to: "Personal", defaultName: "iCloud Drive")
        #expect(changed)
        #expect(names.name(for: "icloud") == "Personal")
        #expect(names.title(for: "icloud", default: "iCloud Drive") == "Personal")
    }

    @Test("a row nobody renamed keeps its default")
    func untouchedRowKeepsDefault() {
        let names = SidebarItemNames(names: ["icloud": "Personal"])
        #expect(names.name(for: "photos") == nil)
        #expect(names.title(for: "photos", default: "Photos") == "Photos")
    }

    /// The default is not constant — it is translated, and a mount's gains its account when a second
    /// one appears — so pinning a copy of it would freeze the row at what it said that day.
    @Test("renaming back to the default forgets the entry rather than pinning the string")
    func renameToDefaultResets() {
        var names = SidebarItemNames(names: ["mount:Box-Box": "Work"])
        let forgot = names.rename("mount:Box-Box", to: "Box", defaultName: "Box")
        #expect(forgot)
        #expect(names.names.isEmpty)

        var untouched = SidebarItemNames()
        let pinned = untouched.rename("mount:Box-Box", to: "  Box ", defaultName: "Box")
        #expect(!pinned)
        #expect(untouched.names.isEmpty)
    }

    @Test("an emptied field means the original name again")
    func emptyNameResets() {
        var names = SidebarItemNames(names: ["photos": "Pictures"])
        let changed = names.rename("photos", to: " \n ", defaultName: "Photos")
        #expect(changed)
        #expect(names.name(for: "photos") == nil)
    }

    @Test("the same name again changes nothing")
    func sameNameIsNoChange() {
        var names = SidebarItemNames(names: ["photos": "Pictures"])
        let changed = names.rename("photos", to: "Pictures ", defaultName: "Photos")
        #expect(!changed)
    }

    @Test("reset reports whether there was a name to forget")
    func resetReportsChange() {
        var names = SidebarItemNames(names: ["photos": "Pictures"])
        let first = names.reset("photos")
        let second = names.reset("photos")
        #expect(first)
        #expect(!second)
    }

    // MARK: - Normalization

    @Test("surrounding whitespace is trimmed, inner spaces kept")
    func trimsWhitespace() {
        #expect(SidebarItemNames.normalized("  Work  Drive \t") == "Work  Drive")
    }

    @Test("a pasted line break or control character does not reach the row")
    func stripsControls() {
        #expect(SidebarItemNames.normalized("Work\nDrive") == "WorkDrive")
        #expect(SidebarItemNames.normalized("A\u{0007}B\u{2028}C\u{2029}D\u{0085}") == "ABCD")
    }

    @Test("names in any script and emoji survive")
    func keepsText() {
        #expect(SidebarItemNames.normalized("Робота 📁") == "Робота 📁")
        #expect(SidebarItemNames.normalized("仕事") == "仕事")
    }

    @Test("nothing but whitespace or controls is no name at all")
    func blankIsNil() {
        #expect(SidebarItemNames.normalized("") == nil)
        #expect(SidebarItemNames.normalized(" \n\u{0000} ") == nil)
    }

    // MARK: - Codable

    @Test("encodes as a bare object of identity to name")
    func encodesAsObject() throws {
        let names = SidebarItemNames(names: ["icloud": "Personal"])
        let json = try #require(String(bytes: try JSONEncoder().encode(names), encoding: .utf8))
        #expect(json == #"{"icloud":"Personal"}"#)
    }

    @Test("round-trips, sanitizing a hand-edited store")
    func decodeNormalizes() throws {
        let data = Data(#"{"icloud":" Personal ","photos":"  ","mount:Box-Box":"W\nork"}"#.utf8)
        let names = try JSONDecoder().decode(SidebarItemNames.self, from: data)
        #expect(names.names == ["icloud": "Personal", "mount:Box-Box": "Work"])
    }
}
