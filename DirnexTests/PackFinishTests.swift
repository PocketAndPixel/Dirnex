import DirnexCore
import Testing

@testable import Dirnex

/// Which finished jobs report as a pack (2026-11-18).
///
/// Both pack kinds now go through `presentPackOutcome` *and* on to the failure alert and the sweep of
/// their staged sources. The encrypted one used to stop after its outcome, so a refused upload, a
/// failed walk or a file where a typed folder would go said nothing at all, since its runner reports
/// those as `failures` with no outcome. The window's finish loop has no test harness, so the rule is
/// a function, as `reportsToItsGesture` is, and pinned here.
@Suite("A finished pack")
struct PackFinishTests {
    @Test("both pack kinds report as a pack, and nothing else does")
    func bothPacksAndNothingElse() {
        let archive = VFSPath.local("/tmp/out.zip")
        #expect(BrowserWindowController.isPack(
            .pack(PackJob(sources: [], archive: archive, encryption: .none, passphrase: nil))
        ))
        #expect(BrowserWindowController.isPack(
            .plainPack(PlainPackJob(sources: [], archive: archive, format: .zip))
        ))
        #expect(!BrowserWindowController.isPack(.copy))
        #expect(!BrowserWindowController.isPack(.move))
        #expect(!BrowserWindowController.isPack(.materialize))
        #expect(!BrowserWindowController.isPack(.writeBack(WriteBackJob(items: []))))
    }
}
