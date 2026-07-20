import Foundation
import Testing

@testable import DirnexCore

@Suite("Sidebar sections")
struct SidebarSectionsTests {
    private func json(_ collapse: SidebarSectionCollapse) throws -> String {
        try #require(String(bytes: try JSONEncoder().encode(collapse), encoding: .utf8))
    }

    // MARK: - Section identity

    @Test("allCases is the sidebar's render order")
    func caseOrderIsRenderOrder() {
        // Not decoration: the app builds its rows in this order, and a case inserted alphabetically
        // would move a whole section on screen without anything else looking wrong.
        #expect(SidebarSection.allCases == [.searches, .favorites, .volumes, .servers, .tags])
    }

    @Test("every section has a distinct title and a distinct identifier")
    func titlesAndIdentifiersAreUnique() {
        let titles = Set(SidebarSection.allCases.map(\.title))
        let identifiers = Set(SidebarSection.allCases.map(\.rawValue))
        #expect(titles.count == SidebarSection.allCases.count)
        #expect(identifiers.count == SidebarSection.allCases.count)
    }

    // MARK: - Collapse state

    @Test("everything starts expanded")
    func defaultIsExpanded() {
        let collapse = SidebarSectionCollapse()
        let allExpanded = SidebarSection.allCases.allSatisfy { !collapse.isCollapsed($0) }
        #expect(allExpanded)
        #expect(collapse.sections.isEmpty)
    }

    @Test("toggle returns the new state and touches only its own section")
    func toggleFlipsOneSection() {
        var collapse = SidebarSectionCollapse()

        #expect(collapse.toggle(.volumes) == true)
        #expect(collapse.isCollapsed(.volumes))
        #expect(!collapse.isCollapsed(.favorites))

        #expect(collapse.toggle(.volumes) == false)
        #expect(!collapse.isCollapsed(.volumes))
    }

    @Test("setCollapsed reports whether it changed anything")
    func setCollapsedReportsChange() {
        var collapse = SidebarSectionCollapse(collapsed: [.favorites])
        // The drop path leans on this: expanding an already-expanded section must not trigger a
        // save and a rebuild in the middle of a drag.
        #expect(collapse.setCollapsed(false, for: .favorites) == true)
        #expect(collapse.setCollapsed(false, for: .favorites) == false)
        #expect(collapse.setCollapsed(true, for: .favorites) == true)
    }

    // MARK: - Persistence

    @Test("a collapse set survives a JSON round trip")
    func codableRoundTrip() throws {
        let original = SidebarSectionCollapse(collapsed: [.searches, .tags])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SidebarSectionCollapse.self, from: data)
        #expect(decoded == original)
        #expect(decoded.sections == [.searches, .tags])
    }

    @Test("encodes as a sorted array of names, so a no-op save rewrites the same bytes")
    func encodesAsSortedNames() throws {
        let collapse = SidebarSectionCollapse(collapsed: [.tags, .favorites, .searches])
        #expect(try json(collapse) == #"["favorites","searches","tags"]"#)
    }

    @Test("an unknown section name is carried through instead of failing the decode")
    func unknownSectionSurvives() throws {
        // The failure this prevents: a build that doesn't know "recents" decoding a file written by
        // one that does. A `Set<SidebarSection>` would throw here, and a throwing decode resets
        // every section — so one unknown name would unfold the user's whole sidebar.
        let stored = Data(#"["recents","tags"]"#.utf8)
        let decoded = try JSONDecoder().decode(SidebarSectionCollapse.self, from: stored)

        #expect(decoded.isCollapsed(.tags))
        #expect(decoded.sections == [.tags]) // "recents" is unknown, so there is nothing to render

        // And it is still there after this build saves its own change.
        var mutated = decoded
        mutated.setCollapsed(true, for: .volumes)
        #expect(try json(mutated) == #"["recents","tags","volumes"]"#)
    }
}
