import Testing
@testable import DirnexCore

/// The rule that separates "the user declined" from "it worked and has since broken"
/// (docs/NOTES.md ▸ iCloud Drive). The shipped latch answered `stayQuiet` to both, which left a
/// broken grant showing a silently short iCloud Drive forever.
@Suite("iCloud Full Disk Access offer")
struct ICloudAccessOfferTests {
    // MARK: - What a scan proves

    @Test("libraries coming back prove the containers were readable")
    func readableObservation() {
        let scan = ICloudLibraryScan(
            libraries: [
                ICloudAppLibrary(
                    containerID: "com~apple~Pages",
                    bundleID: "com.apple.Pages",
                    name: "Pages",
                    documents: .local("/tmp/Pages/Documents")
                )
            ],
            isRestricted: false
        )
        #expect(scan.accessObservation == .readable)
    }

    @Test("a refusal is denial")
    func deniedObservation() {
        let scan = ICloudLibraryScan(libraries: [], isRestricted: true)
        #expect(scan.accessObservation == .denied)
    }

    /// The case that must not be folded into `.readable`: nothing was refused, and nothing was
    /// found. Reading it as proof of access would arm a rescue for a capability never observed.
    @Test("no libraries and no refusal proves nothing")
    func indeterminateObservation() {
        let scan = ICloudLibraryScan(libraries: [], isRestricted: false)
        #expect(scan.accessObservation == .indeterminate)
    }

    // MARK: - The decision

    @Test("a first refusal is offered")
    func firstRefusalOffers() {
        let offer = ICloudAccessOffer.decide(
            observation: .denied,
            hasOfferedBefore: false,
            hasReadLibrariesBefore: false
        )
        #expect(offer == .offerFirstTime)
    }

    /// The half the shipped code had right, and the reason the latch exists at all.
    @Test("a user who declined an offer for access they never had is not asked again")
    func declinedIsNotNagged() {
        let offer = ICloudAccessOffer.decide(
            observation: .denied,
            hasOfferedBefore: true,
            hasReadLibrariesBefore: false
        )
        #expect(offer == .stayQuiet)
    }

    /// The bug this rule was written for: the libraries were readable at some point, and are not
    /// now, so the listing is missing rows the user has already seen.
    @Test("access that used to work and has gone earns a second ask")
    func lossIsRescued() {
        let offer = ICloudAccessOffer.decide(
            observation: .denied,
            hasOfferedBefore: true,
            hasReadLibrariesBefore: true
        )
        #expect(offer == .offerAfterLoss)
    }

    /// Narrowness in the direction that matters most: a working grant must never raise a sheet,
    /// whatever the latches say. Both latch combinations are checked, since the guard runs first.
    @Test("a working grant is never interrupted", arguments: [true, false])
    func grantedIsSilent(hasRead: Bool) {
        for hasOffered in [true, false] {
            let offer = ICloudAccessOffer.decide(
                observation: .readable,
                hasOfferedBefore: hasOffered,
                hasReadLibrariesBefore: hasRead
            )
            #expect(offer == .stayQuiet)
        }
    }

    /// A Mac that simply has no iCloud-enabled apps is not a Mac with a broken grant.
    @Test("an indeterminate scan is never offered")
    func indeterminateIsSilent() {
        for hasOffered in [true, false] {
            for hasRead in [true, false] {
                let offer = ICloudAccessOffer.decide(
                    observation: .indeterminate,
                    hasOfferedBefore: hasOffered,
                    hasReadLibrariesBefore: hasRead
                )
                #expect(offer == .stayQuiet)
            }
        }
    }
}
