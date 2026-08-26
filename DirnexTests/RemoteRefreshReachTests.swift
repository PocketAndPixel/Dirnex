import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The app half of the server poll (docs/LOCATION-SUPPORT.md ▸ "No live refresh on a server").
///
/// *Whether* and *how often* a pane polls is `RemoteRefreshPolicy`'s, tested in the core against
/// every combination. What is left here is what only the app can answer: that a pane with nowhere
/// to be seen asks nothing, that the preference the user owns reaches the policy unmangled, and
/// that the two wake sources disagree about exactly one thing.
///
/// **Every pane here is headless — the view is never loaded**, which is not a shortcut but the
/// claim: reading `viewIfLoaded` rather than `view` is what stops "is anybody looking" from
/// building the pane and listing a server inside the test host. A window is deliberately *not*
/// introduced, on the evidence recorded in docs/NOTES.md ▸ Design lessons: hosting a live pane in a
/// window makes it do real pane work here and destabilised `PanelPassiveRefreshTests` over 17 runs.
/// So the armed-timer path is verified live, in the running app, and said so rather than faked.
private enum Remote {
    static let sftp = VFSBackendID.sftp(
        SFTPLocation(host: "example.com", port: 22, username: "oleg")
    )
    static let ftp = VFSBackendID.ftp(FTPLocation(host: "example.com", username: "oleg"))
    static let s3 = VFSBackendID.s3(
        S3Location(
            host: "127.0.0.1",
            port: 9599,
            bucket: "probe",
            region: "us-east-1",
            accessKeyID: "AKIAPROBEKEYEXAMPLE",
            addressing: .path,
            usesTLS: false
        )
    )

    /// Remote-generic by design: writing this against S3 alone would be the one-rule-several-
    /// spellings finding this project keeps re-deriving.
    static let all = [sftp, ftp, s3]
}

@MainActor
@Suite("Remote refresh reaches the pane")
struct RemoteRefreshReachTests {
    /// The one defaults key these three tests are about.
    private let floorKey = "Dirnex.pref.remoteRefreshFloor"

    /// A scratch domain with that one key cleared.
    ///
    /// **Not `removePersistentDomain`**, which is a synchronous round trip to `cfprefsd`: this suite
    /// is `@MainActor`, so a blocking body here holds the one actor nearly every headless suite
    /// needs to be resumed on — and the app suite already contains one that measures whether
    /// anything repainted inside a two-second window (docs/NOTES.md ▸ Testing). Clearing the single
    /// key the tests read is the same isolation for a fraction of the cost.
    private static func cleanDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "RemoteRefreshReachTests")!
        defaults.removeObject(forKey: "Dirnex.pref.remoteRefreshFloor")
        return defaults
    }

    private static func pane(at path: VFSPath) -> PanelViewController {
        PanelViewController(
            backend: LocalBackend(),
            restoration: nil,
            defaultPath: path,
            restorationKey: nil
        )
    }

    // MARK: - Nobody is looking

    /// The property that keeps a test run — and a window still being restored at launch — from
    /// opening a connection. It is asserted over every remote backend rather than one, because what
    /// would break it is a gate re-keyed on a list of cases.
    @Test("a pane with no window on screen asks its server nothing", arguments: Remote.all)
    func headlessPaneDoesNotPoll(backend: VFSBackendID) {
        let pane = Self.pane(at: VFSPath(backend: backend, path: "/dir"))

        #expect(!pane.isRemoteRefreshWanted)
    }

    /// The narrowness control for the line above: it must be answering "nobody is looking", not
    /// "the view is not loaded". Reading the gate must leave the pane exactly as unloaded as it
    /// found it — otherwise the question builds the pane it is asking about, and a headless suite
    /// starts listing servers.
    @Test("asking whether anybody is looking does not load the view")
    func askingDoesNotLoadTheView() {
        let pane = Self.pane(at: VFSPath(backend: Remote.s3, path: "/dir"))

        _ = pane.isRemoteRefreshWanted

        #expect(pane.viewIfLoaded == nil)
    }

    // MARK: - The preference reaches the policy

    /// The shipped default has to be the core's, not a second number in the app that drifts from
    /// it — the duplicate-constant family, in the one place a user would never notice.
    @Test("an untouched install carries the policy's own default floor")
    func defaultFloorComesFromThePolicy() {
        let defaults = Self.cleanDefaults()
        let preferences = AppPreferences(defaults: defaults)

        #expect(preferences.remoteRefreshFloor == RemoteRefreshPolicy.defaultFloor)
    }

    /// **Zero is a setting, and a missing key is not zero.** `double(forKey:)` answers 0 for a key
    /// that was never written, which here means "never contact a server" — so the cheap spelling
    /// would ship every fresh install with the feature silently off and no way to tell that from a
    /// deliberate choice. This is the assertion that catches it.
    @Test("zero is honoured as a real setting, not read as a missing key")
    func zeroIsASetting() {
        let defaults = Self.cleanDefaults()
        // Filed into the domain rather than assigned through the published property, deliberately.
        // The claim is about the **read** — that a stored 0 comes back as 0 instead of being taken
        // for a key nobody ever wrote — and assigning would post `remoteRefreshFloorDidChange` on
        // the shared notification centre, which every pane in the test host observes. A suite that
        // measures whether anything repainted is documented as sensitive to exactly that
        // (docs/NOTES.md ▸ Testing), and a test has no business waking somebody else's panes.
        defaults.set(0.0, forKey: floorKey)

        let preferences = AppPreferences(defaults: defaults)

        #expect(preferences.remoteRefreshFloor == 0)
        #expect(
            !RemoteRefreshPolicy.shouldPoll(
                backend: Remote.s3, floor: preferences.remoteRefreshFloor, isOnScreen: true
            )
        )
    }

    /// A hand-edited defaults domain, or a value carried over from another build, is brought inside
    /// the band on the way in — so Settings' range and the timer's cannot disagree.
    @Test("a floor outside the band is clamped on its way in")
    func outOfBandFloorIsClamped() {
        let defaults = Self.cleanDefaults()
        defaults.set(-500.0, forKey: floorKey)

        let preferences = AppPreferences(defaults: defaults)

        #expect(RemoteRefreshPolicy.floorRange.contains(preferences.remoteRefreshFloor))
    }

    // MARK: - What each wake proves

    /// The one point on which the two wake sources differ, and the reason the refresh takes a wake
    /// rather than sharing one body blindly: an FSEvents ping is itself evidence that something
    /// under this directory changed, where a poll knows only what two listings disagree about.
    @Test("only a filesystem event is proof that the subtree changed")
    func onlyEventsProveTheSubtreeChanged() {
        #expect(RefreshWake.filesystemEvent.provesSubtreeChanged)
        #expect(!RefreshWake.poll.provesSubtreeChanged)
    }
}
