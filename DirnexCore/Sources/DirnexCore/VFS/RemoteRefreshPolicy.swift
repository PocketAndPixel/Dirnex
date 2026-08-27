import Foundation

/// How often a pane showing a **connected server** re-lists it on its own, so a file somebody else
/// added appears without anyone pressing a key (docs/LOCATION-SUPPORT.md ▸ "No live refresh on a
/// server").
///
/// A local directory needs none of this: FSEvents *tells* the pane, exactly and for free, which is
/// why the whole file is about the case where nothing tells anybody anything. No remote protocol
/// here has a change notification — SFTP has no `inotify`, FTP has no verb at all, and S3 has no
/// session to hold one open on — so the only way to learn that a folder moved is to ask again.
///
/// **Asking again is not free, and the two costs are different.** Over SFTP and FTP a listing is a
/// fresh connection: a TCP connect, a handshake and an authentication, measured at 68.5 ms apiece
/// on loopback and several round trips on a real link. Over S3 it is a **billed** `ListObjectsV2`
/// at 0.601–0.699 s (docs/NOTES.md ▸ curl for S3). Neither is a reason not to poll, and both are a
/// reason to be able to say what a poll costs.
///
/// ## Why a duty cycle rather than a table of intervals
///
/// The tempting design is one interval per backend. It cannot be right, because the quantity that
/// varies is not the *protocol* but the folder: an S3 listing pages at 1000 keys, so a
/// 50 000-object prefix is fifty requests and ~32 s of wall time where an ordinary folder is one
/// request and 0.65 s. A constant tuned for the second bills fifty times over for the first, and a
/// constant tuned for the first makes the ordinary case pointlessly stale. The same spread arrives
/// in tree mode, where one refresh re-lists every expanded folder.
///
/// So the interval is derived from **the refresh's own measured duration** — the quantity actually
/// in question — under a stated ceiling on how much of a pane's wall time may go on re-listing.
/// Nothing has to be known in advance, nothing needs a per-backend row, and a folder that is
/// expensive to list backs off by itself, on a slow link as much as on a large prefix. It is the
/// same move as ``RemoteFetchPolicy``'s size table refusing to guess and S3's progress ladder
/// measuring the transfer instead of modelling the link (docs/NOTES.md ▸ Testing).
///
/// ## The floor is the number, the duty cycle is the runaway guard
///
/// For everything a person actually browses the duty cycle is slack and the **floor** decides —
/// 0.65 s of listing against a 15 s floor is 4 %, well inside the ceiling — so the floor is the
/// number the user reasons about and the one Settings exposes. The ceiling only bites where it
/// should. That division is ``DirectorySizeBudget``'s, in its own words: the budget is not the
/// patience limit, it is what stops a runaway from billing indefinitely.
public enum RemoteRefreshPolicy {
    /// The most of a pane's wall time that may go on re-listing a server nobody asked to re-list.
    ///
    /// 5 % is chosen to be *obviously* small rather than optimised: at the measured S3 cost it is
    /// one request every 13 s for an ordinary folder, which the floor then relaxes to 15, and it
    /// holds a fifty-request prefix to one refresh every ~11 minutes. The property worth having is
    /// not the number but that it is a **ratio** — the more a folder costs, the less often it is
    /// asked, with no table to keep and no backend to name.
    public static let dutyCycle = 0.05

    /// The shortest gap between two refreshes until somebody changes it, in seconds.
    ///
    /// 15 s is a browsing number rather than a measurement: it is short enough that a colleague's
    /// upload appears while you are still looking at the folder, and long enough that a pane left
    /// open on a bucket over a working day costs a few hundred requests rather than tens of
    /// thousands. Expected to move, which is why it is named here and not written at the timer.
    public static let defaultFloor: TimeInterval = 15

    /// The band Settings offers, in seconds.
    ///
    /// **Zero is a real setting and the reason the range starts there** — "never talk to my server
    /// unless I ask" is the honest answer on a metered link or a bill somebody watches, and it is
    /// exactly the behaviour every remote pane had before this existed. The same argument, and the
    /// same shape, as ``RemoteFetchPolicy/previewLimitRange``.
    public static let floorRange: ClosedRange<TimeInterval> = 0...3600

    /// `seconds` brought inside ``floorRange``. One place, so a value typed into Settings, one
    /// restored from a defaults domain somebody hand-edited, and one carried over from an older
    /// build cannot disagree about what is allowed.
    public static func clampedFloor(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite else { return defaultFloor }
        return min(max(seconds, floorRange.lowerBound), floorRange.upperBound)
    }

    /// Whether a pane showing `backend` re-lists on a timer at all.
    ///
    /// Keyed on ``VFSBackendID/isRemoteConnection`` rather than on a list of cases, which is this
    /// project's most repeated bug — one question with several spellings, and a backend added later
    /// inheriting the wrong answer in silence. It is also precisely the right question: that
    /// property means *re-listable and not on this disk*, and re-listable is the whole precondition
    /// for a poll.
    ///
    /// Everything else is excluded for a reason of its own rather than by omission. A `.local`
    /// directory is told by FSEvents. An **archive** is a cached `bsdtar -tvf` of a file on this
    /// disk, and it already re-reads when that file changes identity (``ArchiveIdentity``), so
    /// polling it would spend a subprocess to learn what a `stat` already knows. A `.search`
    /// snapshot is the answer to a question somebody asked once, and re-running it silently is a
    /// different feature with a different cost.
    public static func polls(_ backend: VFSBackendID) -> Bool {
        backend.isRemoteConnection
    }

    /// Whether a pane should be asking its server for a fresh listing **right now**.
    ///
    /// Three inputs and no live reads of its own, which is the point: the app half is one
    /// expression gathering them (`PanelViewController.isRemoteRefreshWanted`), so every
    /// combination is reachable in a test. A rule that fetched its own `NSWindow` would have
    /// exactly one test case — the state a headless test host happens to be in — and its narrowness
    /// control would pass while proving nothing (docs/NOTES.md ▸ Testing).
    ///
    /// `isOnScreen` is the app's reading of `NSWindow.occlusionState`, which was probed on macOS 26
    /// to be the one property that goes false for **every** way a pane stops being read —
    /// miniaturized, app hidden, ordered out, and fully covered by another window — where
    /// `window.isVisible` stays true through the commonest of those. Whether the app is *frontmost*
    /// is deliberately not an input: a pane sitting beside the user's editor showing rows that are
    /// quietly out of date is precisely the thing being fixed, and it is still on screen.
    ///
    /// It answers the backend-and-floor half by asking ``interval(afterRefreshTaking:floor:backend:)``
    /// rather than restating it, so "this pane polls at all" has one definition and the two cannot
    /// drift into two spellings of one question.
    public static func shouldPoll(
        backend: VFSBackendID,
        floor: TimeInterval,
        isOnScreen: Bool
    ) -> Bool {
        guard isOnScreen else { return false }
        return interval(afterRefreshTaking: nil, floor: floor, backend: backend) != nil
    }

    /// How long to wait before re-listing again, given how long the refresh that just finished took
    /// and the user's floor — or `nil` when this pane must not poll at all.
    ///
    /// `nil` rather than a very large interval, so "off" is a state a caller cannot accidentally
    /// treat as "later": a timer that is never armed cannot fire, where a big number eventually
    /// does.
    ///
    /// A duration that is missing, negative or not finite falls back to the floor rather than
    /// refusing. Not measuring is not evidence of expense, and the floor is already the answer for
    /// every folder a person browses — treating an unknown as "back off" would make the first poll
    /// after any hiccup the *rarest* one, which is backwards.
    public static func interval(
        afterRefreshTaking duration: TimeInterval?,
        floor: TimeInterval,
        backend: VFSBackendID
    ) -> TimeInterval? {
        guard polls(backend) else { return nil }
        // Asked through `contactsServersUnasked` rather than by comparing to zero, so the poll and
        // session restore cannot drift into two readings of the one number Settings shows.
        guard contactsServersUnasked(floor: floor) else { return nil }
        let floor = clampedFloor(floor)
        guard let duration, duration.isFinite, duration > 0 else { return floor }
        return max(floor, duration / dutyCycle)
    }

    /// How long to wait **from now**: the interval, less however long it is since the last refresh
    /// of this same directory finished.
    ///
    /// The subtraction is what makes coming back to a pane feel right rather than arbitrary, and it
    /// is the half that is easy to lose. A window uncovered after twenty minutes is showing a
    /// listing that is certainly stale, and starting the clock afresh would make it wait out a
    /// whole interval before catching up; a window flicked away and back inside a second has just
    /// been refreshed, and asking again would spend a request on a gesture. One subtraction answers
    /// both, and it answers a lid closed and reopened for the same reason.
    ///
    /// It is here, and takes `finishedSecondsAgo` rather than reading a clock, because it shipped
    /// as a bug first: the app cleared its own timings whenever the poll stood down, so every
    /// stand-down silently turned the catch-up into "wait a fresh interval" — invisible at a 15 s
    /// floor and an hour of staleness at an hour's. Nothing headless could see it, since no test
    /// arms a timer; it took watching the running app. As a pure function of two numbers it has a
    /// negative control instead.
    ///
    /// `nil` elapsed is "no previous refresh of this directory" — a pane that has just arrived —
    /// and waits the full interval, which is the honest answer: it has just listed, as part of
    /// getting here.
    public static func delay(
        afterRefreshTaking duration: TimeInterval?,
        finishedSecondsAgo elapsed: TimeInterval?,
        floor: TimeInterval,
        backend: VFSBackendID
    ) -> TimeInterval? {
        guard let interval = interval(
            afterRefreshTaking: duration, floor: floor, backend: backend
        ) else { return nil }
        guard let elapsed, elapsed.isFinite, elapsed > 0 else { return interval }
        return max(0, interval - elapsed)
    }
}
