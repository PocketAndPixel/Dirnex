import Foundation

@testable import Dirnex

/// A find-options store that belongs to the test, not to whoever ran it.
///
/// `QuickViewFindOptionsStore.standard` is `UserDefaults.standard`, which in the app test target is
/// the developer's own `com.dirnex.Dirnex` (docs/NOTES.md ▸ Testing) — and this store is *read* on the
/// way in, so a preview built on it would start with whatever options the person running the tests
/// had left on in the real app. `QuickViewPreviewView` therefore takes one as a required argument and
/// every fixture here hands over one of these.
///
/// The domain name is fixed, never a UUID, for the reason ``ScratchDefaults`` gives. A fixture that
/// does not thread its caller's `#fileID`/`#function` through names *itself*, so every test behind it
/// shares one domain — harmless while none of them writes, and the reason to thread them through the
/// moment one does.
extension QuickViewFindOptionsStore {
    @MainActor
    static func scratch(
        file: String = #fileID,
        function: String = #function
    ) -> QuickViewFindOptionsStore {
        QuickViewFindOptionsStore(
            defaults: ScratchDefaults.fresh("findOptions", file: file, function: function)
        )
    }
}
