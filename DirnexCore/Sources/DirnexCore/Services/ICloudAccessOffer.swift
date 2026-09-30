import Foundation

/// What one `ICloudDrive.appLibraries` scan proved about Dirnex's access to the app containers.
///
/// The three cases are deliberately not two: "nothing was refused" is not the same claim as "the
/// grant works". A Mac with no metadata cache at all reports no libraries and no refusal, and
/// reading that as proof of access would let a later loss go unnoticed — the very thing the offer
/// below exists to catch.
public enum ICloudAccessObservation: Sendable, Hashable, CaseIterable {
    /// Libraries came back, so the metadata cache *and* at least one container's `Documents` were
    /// readable. This is the only positive proof available, and it is proof of exactly the
    /// capability whose loss is worth rescuing.
    case readable
    /// A read was refused — the grant is missing.
    case denied
    /// Neither: nothing refused, and nothing found.
    case indeterminate
}

public extension ICloudLibraryScan {
    /// What this scan proves, for the offer policy below.
    var accessObservation: ICloudAccessObservation {
        if isRestricted { return .denied }
        return libraries.isEmpty ? .indeterminate : .readable
    }
}

/// Whether the merged iCloud listing should offer the Full Disk Access grant, and why.
///
/// The listing *works* without the grant — it shows the loose CloudDocs files — so the offer was
/// shipped as a one-shot latch: asking once is a rescue and asking every visit is a nag. That latch
/// cannot tell **"the user declined"** from **"it was working and has since broken"**, and those
/// want opposite answers. Silence is right for the first; for the second it leaves iCloud Drive
/// permanently short with no error, no log and a plausible-looking listing — the quiet wrong answer
/// the Trash prompt refuses to give.
///
/// A grant really can die under a user who did nothing wrong: Migration Assistant to a new Mac,
/// revoking it by hand, or a TCC record left over from a differently signed build at the same
/// bundle id, where the row stays switched on and the access does not (measured 2026-08-26 —
/// `tccd: Failed to match existing code requirement`). So the second latch records whether the
/// libraries have *ever* been read, and its loss is what buys a second ask.
public enum ICloudAccessOffer: Sendable, Hashable, CaseIterable {
    /// Say nothing: either there is nothing to offer, or the user has already declined an offer
    /// for access they have never had.
    case stayQuiet
    /// The first ask on this Mac.
    case offerFirstTime
    /// Access that used to work has gone. Worth interrupting for, because the listing is now
    /// missing rows the user has already seen it show.
    case offerAfterLoss

    /// Decide, from the scan's own observation and the two latches.
    ///
    /// `hasReadLibrariesBefore` is spent by an `.offerAfterLoss` rather than by a grant being
    /// restored: one loss earns one rescue, so declining it is respected, and a grant that comes
    /// back sets the latch again and re-arms the rescue for the next loss.
    public static func decide(
        observation: ICloudAccessObservation,
        hasOfferedBefore: Bool,
        hasReadLibrariesBefore: Bool
    ) -> ICloudAccessOffer {
        // Only a refusal is worth asking about. `.indeterminate` deliberately says nothing: a Mac
        // that has never run an iCloud-enabled app has no libraries to miss.
        guard observation == .denied else { return .stayQuiet }
        guard hasOfferedBefore else { return .offerFirstTime }
        return hasReadLibrariesBefore ? .offerAfterLoss : .stayQuiet
    }
}
