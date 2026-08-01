import Foundation
import Testing

@testable import DirnexCore

/// Parse and serialize against **real** `acl_to_text` output — a file's ACL (a group deny, then two
/// user entries: deny before allow) and a directory's (two entries carrying inheritance flags),
/// captured live so the fixtures prove the reader agrees with the OS, not with the test's own idea of
/// the format. The one thing that makes the format non-trivial — `acl_to_text` wrapping long lines
/// with a trailing `\` — is baked into both fixtures.
@Suite("AccessControlList")
struct AccessControlListTests {
    private func fixture(_ name: String) throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures")
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Parsing real captures

    @Test("parses a real file ACL, in order, deny before allow")
    func parsesFileACL() throws {
        let acl = try AccessControlList.parse(fixture("acl-file"))
        #expect(acl.entries.count == 3)

        let everyone = acl.entries[0]
        #expect(everyone.subject.kind == .group)
        #expect(everyone.subject.name == "everyone")
        #expect(everyone.subject.numericID == 12)
        #expect(everyone.disposition == .deny)
        #expect(everyone.rights == [.delete])

        #expect(acl.entries[1].disposition == .deny)
        #expect(acl.entries[1].subject.name == "oleg")
        #expect(acl.entries[1].rights == [.write, .delete])

        let allow = acl.entries[2]
        #expect(allow.disposition == .allow)
        #expect(allow.rights == [.read, .write, .append, .readAttributes, .writeAttributes])
    }

    @Test("parses a real directory ACL with inheritance flags")
    func parsesDirectoryACL() throws {
        let acl = try AccessControlList.parse(fixture("acl-directory"))
        #expect(acl.entries.count == 2)

        let staff = acl.entries[0]
        #expect(staff.subject.kind == .group && staff.subject.name == "staff")
        #expect(staff.disposition == .allow)
        #expect(staff.inheritance == [.fileInherit, .onlyInherit])
        #expect(staff.rights == [.read])

        let oleg = acl.entries[1]
        #expect(oleg.inheritance == [.fileInherit, .directoryInherit])
        #expect(oleg.rights == [.read, .write, .execute, .append])
        #expect(!oleg.isInherited)
    }

    // MARK: - Round-trip

    @Test("a real ACL round-trips through serialize and re-parse unchanged")
    func roundTrip() throws {
        for name in ["acl-file", "acl-directory"] {
            let parsed = try AccessControlList.parse(fixture(name))
            let reparsed = try AccessControlList.parse(parsed.canonicalText())
            #expect(reparsed == parsed, "round-trip differs for \(name)")
        }
    }

    @Test("serialized text is header-first, one line per entry")
    func serializedShape() throws {
        let acl = try AccessControlList.parse(fixture("acl-file"))
        let lines = acl.canonicalText().split(whereSeparator: \.isNewline).map(String.init)
        #expect(lines.first == "!#acl 1")
        #expect(lines.count == 4) // header + 3 entries, unwrapped
        #expect(lines.dropFirst().allSatisfy { $0.hasPrefix("user:") || $0.hasPrefix("group:") })
    }

    // MARK: - Edge cases

    @Test("an empty or header-only ACL parses to no entries")
    func emptyACL() throws {
        #expect(try AccessControlList.parse("").isEmpty)
        #expect(try AccessControlList.parse("!#acl 1\n").isEmpty)
    }

    /// All thirteen canonical right tokens (the spellings `acl_to_text` actually emits) parse, and
    /// `delete_child` — the one directory-only token — is among them.
    @Test("every canonical right token parses")
    func allRightTokens() throws {
        let tokens = ACLRight.directoryRights.map(\.rawValue).joined(separator: ",")
        let line = "user:GUID:oleg:501:allow:\(tokens)"
        let acl = try AccessControlList.parse("!#acl 1\n\(line)")
        #expect(acl.entries[0].rights == Set(ACLRight.directoryRights))
        #expect(acl.entries[0].rights.contains(.deleteChild))
    }

    /// A right or flag this build does not model must survive a round-trip, or writing the ACL back
    /// would silently strip it — unacceptable for security metadata.
    @Test("unknown tokens are preserved verbatim")
    func unknownTokensPreserved() throws {
        let line = "user:GUID:oleg:501:allow,some_future_flag:read,future_right"
        let acl = try AccessControlList.parse("!#acl 1\n\(line)")
        let entry = acl.entries[0]
        #expect(entry.rights == [.read])
        #expect(entry.unrecognizedRights == ["future_right"])
        #expect(entry.unrecognizedFlags == ["some_future_flag"])
        // And they come back out in the serialized form.
        let serialized = acl.canonicalText()
        #expect(serialized.contains("future_right"))
        #expect(serialized.contains("some_future_flag"))
        #expect(try AccessControlList.parse(serialized) == acl)
    }

    @Test("a malformed entry line throws rather than being silently skipped")
    func malformedThrows() {
        #expect(throws: ACLError.self) {
            try AccessControlList.parse("!#acl 1\nnonsense-without-fields")
        }
    }

    // MARK: - The two shapes the OS writes that the strict reading rejected

    /// **Captured from a real file** (2026-07-31): `acl_to_text` omits the rights field *entirely*
    /// for a rights-less entry rather than writing it empty, so the line has five fields, not six.
    /// `ls -le` shows it as `0: group:staff allow`.
    ///
    /// The strict six-field reading threw here, and because `AttributesSnapshot` degrades a failed
    /// ACL read to an empty list, the panel reported **"No access control list"** for a file that
    /// has one — a wrong answer in the quiet direction, on the tab whose whole job is to say what
    /// the ACL is.
    @Test("a rights-less entry, as acl_to_text writes it, parses")
    func rightsLessEntryParses() throws {
        let real = "!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF00000014:staff:20:allow\n"
        let acl = try AccessControlList.parse(real)
        #expect(acl.entries.count == 1)
        let entry = acl.entries[0]
        #expect(entry.subject.name == "staff")
        #expect(entry.disposition == .allow)
        #expect(entry.rights.isEmpty)
        // And it is exactly the entry the editor must refuse to create: it decides nothing.
        #expect(!entry.isMeaningful)
    }

    /// **Captured from a real file**: an entry whose GUID answers to no account comes back with an
    /// empty name *and* an empty id — the kernel re-derives both from the GUID and empties them when
    /// nothing answers, even when the writer supplied them. `ls -le` shows the bare GUID.
    @Test("an entry naming a deleted account parses, keeping the GUID as its identity")
    func unresolvedSubjectParses() throws {
        let real = "!#acl 1\nuser:FFFFEEEE-DDDD-CCCC-BBBB-AAAA00007A69:::allow:read\n"
        let acl = try AccessControlList.parse(real)
        let subject = try #require(acl.entries.first?.subject)
        #expect(subject.guid == "FFFFEEEE-DDDD-CCCC-BBBB-AAAA00007A69")
        #expect(subject.numericID == nil)
        #expect(!subject.isResolved)
        // What the panel shows is what `ls -le` shows.
        #expect(subject.displayName == "FFFFEEEE-DDDD-CCCC-BBBB-AAAA00007A69")
    }

    /// Both shapes must survive an edit to a *neighbouring* entry untouched, which is the case that
    /// actually reaches a user: the editor writes the whole list back, so a lossy round-trip here
    /// would rewrite an entry nobody selected.
    @Test("both awkward shapes round-trip through serialize and re-parse")
    func awkwardShapesRoundTrip() throws {
        let real = """
        !#acl 1
        group:ABCDEFAB-CDEF-ABCD-EFAB-CDEF00000014:staff:20:allow
        user:FFFFEEEE-DDDD-CCCC-BBBB-AAAA00007A69:::allow:read

        """
        let acl = try AccessControlList.parse(real)
        #expect(try AccessControlList.parse(acl.canonicalText()) == acl)
        // Six fields on the way out, with the unresolved subject's name and id written empty —
        // probed to be what `acl_from_text` accepts back.
        let lines = acl.canonicalText().split(whereSeparator: \.isNewline).map(String.init)
        #expect(lines[2] == "user:FFFFEEEE-DDDD-CCCC-BBBB-AAAA00007A69:::allow:read")
    }

    /// An id that is present but not a number is still a malformed line — absence and garbage are
    /// distinguished rather than both falling through to `nil`.
    @Test("a non-numeric id still throws")
    func nonNumericIDThrows() {
        #expect(throws: ACLError.self) {
            try AccessControlList.parse("!#acl 1\nuser:GUID:oleg:not-a-number:allow:read")
        }
    }

    // MARK: - Reordering

    @Test("moving an entry reorders the list and leaves the entries themselves alone")
    func movingReorders() throws {
        let acl = try AccessControlList.parse(fixture("acl-file"))
        let moved = acl.moving(from: 0, to: 2)
        #expect(moved.entries.count == 3)
        #expect(moved.entries[2] == acl.entries[0])
        #expect(moved.entries[0] == acl.entries[1])
        #expect(Set(moved.entries) == Set(acl.entries))
    }

    @Test("an out-of-range move changes nothing")
    func movingOutOfRange() throws {
        let acl = try AccessControlList.parse(fixture("acl-file"))
        #expect(acl.moving(from: 0, to: 9) == acl)
        #expect(acl.moving(from: -1, to: 0) == acl)
        #expect(AccessControlList().moving(from: 0, to: 0).isEmpty)
    }

    @Test("the applicable-rights count matches the panel's 12 / 13")
    func applicableCounts() {
        #expect(ACLRight.applicable(to: .file).count == 12)
        #expect(ACLRight.applicable(to: .directory).count == 13)
        #expect(ACLRight.applicable(to: .symlink).count == 12) // link's own ACL, file-shaped
    }
}
