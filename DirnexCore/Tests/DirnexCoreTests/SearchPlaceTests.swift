import Foundation
import Testing

@testable import DirnexCore

@Suite("SearchPlace")
struct SearchPlaceTests {
    private static let home = VFSPath.local("/Users/me")
    private static let documents = VFSPath.local("/Users/me/Documents")
    private static let server = VFSBackendID.ftp(FTPLocation(host: "nas", username: "me"))
    private static let archive = VFSBackendID.archive(forArchiveAt: "/Users/me/pack.zip")

    // MARK: - Forward: the scope a search runs with

    @Test("a local search runs in its folder, or everywhere with no scope at all")
    func localScope() {
        #expect(SearchPlace(folder: Self.documents, everything: false).scope == Self.documents)
        #expect(SearchPlace(folder: Self.documents, everything: true).scope == nil)
    }

    @Test("a walk's everything is the connection's own root, never an everywhere")
    func walkScope() {
        for backend in [Self.server, Self.archive] {
            let folder = VFSPath(backend: backend, path: "/photos/2026")
            #expect(SearchPlace(folder: folder, everything: false).scope == folder)
            #expect(
                SearchPlace(folder: folder, everything: true).scope
                    == VFSPath(backend: backend, path: "/")
            )
        }
    }

    /// An unsearchable folder never runs, and `nil` would be Spotlight's everywhere — the widening
    /// `SearchRoute.forSavedSearch` exists to refuse.
    @Test("an unsearchable folder never widens into everywhere")
    func unavailableNeverWidens() {
        let results = VFSPath(backend: .search, path: "/Results")
        #expect(SearchPlace(folder: results, everything: true).scope == results)
    }

    // MARK: - Backward: what a results tab's search ran in

    @Test("a This Folder search reopens on its folder")
    func recoversFolder() {
        let place = SearchPlace(scope: Self.documents, origin: Self.documents, home: Self.home)
        #expect(place == SearchPlace(folder: Self.documents, everything: false))
    }

    @Test("an everywhere search reopens on the folder it was started in")
    func recoversEverywhereWithOrigin() {
        let place = SearchPlace(scope: nil, origin: Self.documents, home: Self.home)
        #expect(place == SearchPlace(folder: Self.documents, everything: true))
    }

    /// A saved search's or a tag's search was never started in a folder, so This Folder points
    /// where ⌥F7 points on a pane with no folder of its own.
    @Test("an everywhere search with no origin reopens on Home")
    func everywhereWithoutOriginFallsBackHome() {
        let place = SearchPlace(scope: nil, origin: nil, home: Self.home)
        #expect(place == SearchPlace(folder: Self.home, everything: true))
    }

    @Test("a walk over the whole connection reopens on the folder it was started in")
    func recoversWalkEverything() {
        let root = VFSPath(backend: Self.server, path: "/")
        let started = VFSPath(backend: Self.server, path: "/photos/2026")
        #expect(
            SearchPlace(scope: root, origin: started, home: Self.home)
                == SearchPlace(folder: started, everything: true)
        )
        // A saved search stored at the root has no origin, and the root is both of its options.
        #expect(
            SearchPlace(scope: root, origin: nil, home: Self.home)
                == SearchPlace(folder: root, everything: true)
        )
    }

    /// The narrowness control on the walk branch: a root is only "everything" on a walk. A local
    /// search scoped to `/` searched the boot volume's folder, which is a folder like any other.
    @Test("a local search scoped to the root is a This Folder search")
    func localRootIsAFolder() {
        let root = VFSPath.local("/")
        #expect(
            SearchPlace(scope: root, origin: root, home: Self.home)
                == SearchPlace(folder: root, everything: false)
        )
    }

    @Test("an origin from somewhere the search could not have started is ignored")
    func foreignOriginIsIgnored() {
        let remote = VFSPath(backend: Self.server, path: "/photos")
        #expect(SearchPlace(scope: nil, origin: remote, home: Self.home).folder == Self.home)
        let archiveRoot = VFSPath(backend: Self.archive, path: "/")
        #expect(
            SearchPlace(scope: archiveRoot, origin: Self.documents, home: Self.home).folder
                == archiveRoot
        )
    }

    /// The two directions are one definition: whatever ⌥F7 runs, an edit of its tab reopens on.
    /// The one place where the round trip is not literal is a walk started *at* the root with This
    /// Folder — there both options search the same thing, so it is the scope that must survive.
    @Test("every search a dialog can run reopens on what it ran")
    func roundTrips() {
        let folders = [
            Self.documents,
            .local("/"),
            VFSPath(backend: Self.server, path: "/photos/2026"),
            VFSPath(backend: Self.server, path: "/"),
            VFSPath(backend: Self.archive, path: "/docs"),
            VFSPath(backend: Self.archive, path: "/")
        ]
        for folder in folders {
            for everything in [false, true] {
                let ran = SearchPlace(folder: folder, everything: everything)
                let reopened = SearchPlace(scope: ran.scope, origin: folder, home: Self.home)
                #expect(reopened.scope == ran.scope, "\(folder) everything: \(everything)")
                #expect(reopened.folder == folder, "\(folder) everything: \(everything)")
                if !(ran.route == .walk && folder.isRoot) {
                    #expect(reopened == ran, "\(folder) everything: \(everything)")
                }
            }
        }
    }

    // MARK: - What the dialog asks about

    /// The trap the type exists for. A results tab's own path is `search:/…`, which answers the
    /// listing set, so a dialog built from it would hide Content and Tags and the edited search
    /// would drop them. The first line is the negative control: it is what goes wrong without this.
    @Test("an edited local search keeps content and tags, whatever the results tab is")
    func editedLocalSearchAnswersEverything() {
        #expect(SearchFields.answerable(by: .search) == .listed)

        for scope in [nil, Self.documents] {
            let place = SearchPlace(scope: scope, origin: Self.documents, home: Self.home)
            #expect(place.fields == .indexed, "\(String(describing: scope))")
            #expect(place.route == .spotlight, "\(String(describing: scope))")
        }
    }

    @Test("an edited walk asks only what a listing carries")
    func editedWalkAnswersListing() {
        let place = SearchPlace(
            scope: VFSPath(backend: Self.server, path: "/"),
            origin: VFSPath(backend: Self.server, path: "/photos"),
            home: Self.home
        )
        #expect(place.fields == .listed)
        #expect(place.route == .walk)
    }
}
