import Foundation
import Testing

@testable import DirnexCore

@Suite("BSDFileFlags")
struct BSDFileFlagsTests {
    /// The raw values must equal the real C constants — the whole point is that this word came out of
    /// a `stat` and goes back into a `chflags`.
    @Test("named bits match the Darwin constants")
    func matchesDarwin() {
        #expect(BSDFileFlags.userImmutable.rawValue == UInt32(UF_IMMUTABLE))
        #expect(BSDFileFlags.hidden.rawValue == UInt32(UF_HIDDEN))
        #expect(BSDFileFlags.userAppend.rawValue == UInt32(UF_APPEND))
        #expect(BSDFileFlags.noDump.rawValue == UInt32(UF_NODUMP))
        #expect(BSDFileFlags.systemImmutable.rawValue == UInt32(SF_IMMUTABLE))
        #expect(BSDFileFlags.systemAppend.rawValue == UInt32(SF_APPEND))
        #expect(BSDFileFlags.archived.rawValue == UInt32(SF_ARCHIVED))
        #expect(BSDFileFlags.dataless.rawValue == UInt32(SF_DATALESS))
    }

    /// The load-bearing split: low 16 bits owner-settable, high 16 bits super-user only.
    @Test("the super-user mask is the high 16 bits, and only SF_* flags fall in it")
    func superUserMask() {
        #expect(BSDFileFlags.superUserMask.rawValue == 0xFFFF_0000)
        // UF_* are all outside it.
        for uf in [BSDFileFlags.userImmutable, .hidden, .userAppend, .noDump, .opaque] {
            #expect(uf.superUserBits.isEmpty)
        }
        // SF_* are all inside it.
        for sf in [BSDFileFlags.systemImmutable, .systemAppend, .archived, .dataless] {
            #expect(sf.superUserBits == sf)
        }
    }

    @Test("Locked is the owner immutable bit")
    func locked() {
        #expect(BSDFileFlags.userImmutable.isLocked)
        #expect(!BSDFileFlags.hidden.isLocked)
        #expect(BSDFileFlags([.userImmutable, .hidden]).isLocked)
    }

    @Test("either immutable bit blocks modification")
    func blocksModification() {
        #expect(BSDFileFlags.userImmutable.blocksModification)
        #expect(BSDFileFlags.systemImmutable.blocksModification)
        #expect(BSDFileFlags([.hidden, .archived]).blocksModification == false)
        #expect(BSDFileFlags([]).blocksModification == false)
    }
}
