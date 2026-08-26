import AppKit
import DirnexCore

/// What woke a passive refresh, and therefore what it is entitled to conclude.
///
/// The two wake sources run the *same* refresh — `performListRefresh` and `performTreeRefresh` —
/// and differ on exactly one thing: an FSEvents ping is itself evidence that something under this
/// directory changed, whether or not the rows moved, while a poll learns nothing at all until it
/// compares two listings and can only ever speak about the rows it can see. Encoded as a wake
/// rather than as a `Bool` parameter so the *reason* travels with the call and a third source added
/// later has to state which kind it is instead of inheriting a flag.
enum RefreshWake {
    /// The pane's `DirectoryWatcher` fired. Recursive, and it discards the event's paths, so what
    /// it proves is "something under here changed" and nothing narrower.
    case filesystemEvent
    /// The remote poll's timer came round on a server that can notify nobody. The listing diff is
    /// the whole of the evidence, and it says nothing about what lies below these rows.
    case poll

    /// Whether this wake is proof that the subtree changed, independently of the listing diff.
    var provesSubtreeChanged: Bool { self == .filesystemEvent }
}

/// What one completed poll cost, and of what. Named rather than a tuple so the three fields cannot
/// be read in the wrong order, and carrying its own `path` so it outlives the task that produced it
/// — which is what lets a pane resume where it left off instead of waiting out a fresh interval.
struct RemoteRefreshMeasurement {
    let path: VFSPath
    let duration: TimeInterval
    let finished: Date
}

/// Live refresh for a pane on a **connected server**, where no protocol will tell it anything
/// (docs/LOCATION-SUPPORT.md ▸ "No live refresh on a server": *a file added by somebody else never
/// appears until the folder is re-listed by hand*).
///
/// The local pane next to it has FSEvents, which is exact and free; SFTP has no `inotify`, FTP has
/// no verb, and S3 has no session to hold a notification open on. So the only way to learn that a
/// folder moved is to ask again, and everything here is about asking as little as will do.
///
/// **Three gates, and each of them says no in a different situation.**
///
/// 1. *Is this a pane that can be polled at all* — ``RemoteRefreshPolicy/polls(_:)``, keyed on
///    `isRemoteConnection` rather than on a list of backends.
/// 2. *Is anybody looking* — `NSWindow.occlusionState`, below.
/// 3. *How often* — ``RemoteRefreshPolicy/interval(afterRefreshTaking:floor:backend:)``, derived
///    from what the previous refresh actually cost, so an expensive folder backs off by itself.
///
/// **Why occlusion and not `isVisible`, and not "is the app active".** Probed on macOS 26 against
/// a real window: `occlusionState.contains(.visible)` goes false for *every* way a pane stops being
/// read — miniaturized, app hidden, ordered out, **and fully covered by another window** — while
/// `window.isVisible` stayed `true` throughout the covered case, which is the commonest one and the
/// property everybody reaches for first. One reading answers the whole question, and it answers it
/// for a window covered by another *application* too, since occlusion is the window server's own
/// bookkeeping. App-activity is deliberately *not* a fourth gate: a pane sitting beside the user's
/// editor showing rows that are quietly out of date is precisely the bug being fixed, and it is
/// still on screen and still being read.
///
/// The same probe found the trap: at the instant `didBecomeActive` fires, occlusion still reads
/// *not visible* and updates a beat later on its own notification. So this arms from
/// `didChangeOcclusionState` and never from an activation notification — reading occlusion inside
/// the latter stands the poll down at the exact moment it should start.
extension PanelViewController {
    // MARK: - Arming

    /// (Re-)decide whether this pane should be polling, and when next. The single funnel — every
    /// navigation, tab switch, occlusion change and preference edit ends here, so there is one
    /// definition of "should this pane be talking to a server right now".
    ///
    /// Idempotent by default: a pane already polling the path it is on is left alone, so a burst of
    /// occlusion notifications cannot keep resetting the clock and starve the poll forever. `force`
    /// is for a change to the *interval* rather than to the target — a Settings edit — which the
    /// path comparison cannot see.
    func updateRemoteRefreshSchedule(force: Bool = false) {
        let path = panel.path
        guard isRemoteRefreshWanted else {
            stopRemoteRefresh()
            return
        }
        guard force || remoteRefreshTask == nil || remoteRefreshScheduledFor != path else { return }
        stopRemoteRefresh()
        remoteRefreshScheduledFor = path
        remoteRefreshTask = Task { [weak self] in
            await self?.runRemoteRefreshLoop(for: path)
        }
    }

    /// Stop talking to the server. Called wherever the pane stops qualifying — a navigation to a
    /// local directory, the window going away, polling switched off in Settings.
    func stopRemoteRefresh() {
        remoteRefreshTask?.cancel()
        remoteRefreshTask = nil
        remoteRefreshScheduledFor = nil
    }

    /// Whether this pane should be asking its server for a fresh listing right now.
    ///
    /// Gathers the three inputs and hands them to the core, which owns the decision — so the rule
    /// is testable in every combination rather than only in whichever state a test host happens to
    /// be in (docs/NOTES.md ▸ Testing: a rule whose input is read by the rule is a rule with one
    /// test case).
    ///
    /// No window — or no *view* — reads as "nobody is looking", which is both true and the reason a
    /// headless test host never opens a connection: a pane whose view was never loaded, or was
    /// loaded and never put in a window, is exactly the shape every app test builds, and this is the
    /// line that keeps them from making network calls.
    ///
    /// `viewIfLoaded` rather than `view`, and that is load-bearing rather than defensive: reading
    /// `view` *loads* it, which runs `viewDidLoad` → `activateTab()` → a real listing. Asking
    /// whether anybody is looking must not be the thing that builds the pane.
    var isRemoteRefreshWanted: Bool {
        RemoteRefreshPolicy.shouldPoll(
            backend: panel.path.backend,
            floor: AppPreferences.shared.remoteRefreshFloor,
            isOnScreen: viewIfLoaded?.window?.occlusionState.contains(.visible) ?? false
        )
    }

    // MARK: - The loop

    /// Sleep, re-list, measure, repeat — until something cancels the task or the pane stops
    /// qualifying.
    ///
    /// A loop that re-arms **after** each refresh finishes, rather than a repeating timer, and that
    /// is what makes the duty cycle mean what it says: the gap is measured from the end of one
    /// round to the start of the next, so two rounds can never overlap and a slow server cannot
    /// queue requests behind itself.
    private func runRemoteRefreshLoop(for path: VFSPath) async {
        while !Task.isCancelled {
            guard let delay = remoteRefreshDelay(for: path) else { return }
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, panel.path == path, isRemoteRefreshWanted else { return }
            let started = Date()
            // The plans are built here, synchronously, for the same reason the FSEvents callers
            // build theirs: they *are* the staleness guards, and this loop has just woken from a
            // sleep during which anything could have happened to the pane.
            if panel.isTree {
                guard let plan = treeRefreshPlan() else { return }
                await performTreeRefresh(plan, selecting: nil, wake: .poll)
            } else {
                guard let plan = listRefreshPlan(for: path) else { return }
                await performListRefresh(plan, wake: .poll)
            }
            remoteRefreshLastPoll = RemoteRefreshMeasurement(
                path: path, duration: Date().timeIntervalSince(started), finished: Date()
            )
        }
    }

    /// How long to wait before the next round. Gathers what the last poll of *this* directory cost
    /// and how long ago it finished, and hands both to the policy, which owns the arithmetic.
    ///
    /// A measurement of a **different** directory says nothing about this one's cost and must not
    /// let a fresh path skip its first wait, so it is ignored rather than cleared — and that is what
    /// keeps the timings alive across a stand-down. Clearing them was the shipped bug: every
    /// stand-down threw away the elapsed time the catch-up is made of.
    private func remoteRefreshDelay(for path: VFSPath) -> TimeInterval? {
        let last = remoteRefreshLastPoll.flatMap { $0.path == path ? $0 : nil }
        return RemoteRefreshPolicy.delay(
            afterRefreshTaking: last?.duration,
            finishedSecondsAgo: last.map { Date().timeIntervalSince($0.finished) },
            floor: AppPreferences.shared.remoteRefreshFloor,
            backend: path.backend
        )
    }

    // MARK: - Observers

    /// Watch the floor in Settings, which changes the answer without any navigation.
    ///
    /// Selector-based, like every other observer on this class, because a block/token observer
    /// cannot be torn down from a `nonisolated deinit` — the `[NSObjectProtocol]` token array is not
    /// `Sendable` (docs/NOTES.md ▸ Swift 6). `removeObserver(self)` in `deinit` covers it.
    func observeRemoteRefreshConditions() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(remoteRefreshFloorDidChange),
            name: AppPreferences.remoteRefreshFloorDidChange,
            object: nil
        )
    }

    /// Watch **this pane's own window** for occlusion, once it has one.
    ///
    /// Scoped to the window rather than registered with `object: nil`, and that is not tidiness:
    /// with `nil` every pane in the process wakes on every window's occlusion change and asks
    /// whether it should be polling — panes in other windows, and in the test host every pane any
    /// suite has ever built, since suites there deliberately retain windows for the process's life.
    /// A pane has no business being woken by somebody else's window.
    ///
    /// It was *suspected* of destabilising `PanelPassiveRefreshTests` and that turned out to be a
    /// pre-existing flake — measured at 1 run in 6 with this whole feature stashed — so the suite is
    /// not evidence either way here. Kept on the argument above, which needs none.
    ///
    /// Installed from `viewDidAppear` because a pane has no window at `viewDidLoad` — which is the
    /// reason the `nil` version looked necessary — and re-pointed if the window ever changes, which
    /// costs nothing and cannot be wrong later.
    func observeWindowOcclusion() {
        guard let window = viewIfLoaded?.window, window !== occlusionObservedWindow else { return }
        if let occlusionObservedWindow {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didChangeOcclusionStateNotification,
                object: occlusionObservedWindow
            )
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(remoteRefreshConditionsDidChange),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window
        )
        occlusionObservedWindow = window
    }

    @objc private func remoteRefreshConditionsDidChange(_ notification: Notification) {
        updateRemoteRefreshSchedule()
    }

    /// A Settings edit changes the *interval* while the target path stays the same, which the
    /// idempotence guard cannot see — hence `force`. It is also how switching polling off reaches
    /// the pane the user is looking at rather than the one they see after the next navigation.
    @objc private func remoteRefreshFloorDidChange(_ notification: Notification) {
        updateRemoteRefreshSchedule(force: true)
    }
}
