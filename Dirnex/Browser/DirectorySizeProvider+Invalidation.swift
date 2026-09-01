import DirnexCore
import Foundation

/// Everything `DirectorySizeProvider` **says to the panes**, and everything it forgets (PLAN.md
/// §M6).
///
/// Split from the provider when the set allowance pushed it past SwiftLint's file ceiling, along
/// the two seams its own MARKs already drew. It is a concept rather than a place to put lines:
/// what stayed behind is about *acquiring* a total — the queue, the order, the allowance, the
/// walks — and what is here is about a total that has been acquired or has stopped being true.
///
/// The three events land differently, which is why they sit together. A **scan landing** is common
/// and is coalesced, because ten publishes a second is what a wide queue produces and one re-render
/// each is what it would cost. A **filesystem change** is rare and publishes at once, because that
/// is the path where a stale number is on screen right now. And a **repository re-read** proves
/// something neither of the others can: not that the bytes moved but that the *question* changed,
/// so it drops only the git-aware totals and only underneath that repository.
extension DirectorySizeProvider {
    /// Announce the directories that gained totals, at most once per `publishInterval`. The trailing
    /// edge is the useful one here (unlike the providers', which debounce a *request*): results
    /// arrive continuously and the panes want them continuously, just not 68 times.
    func schedulePublish() {
        guard publish == nil else { return }
        let interval = publishInterval
        publish = Task { [weak self] in
            try? await Task.sleep(for: interval)
            self?.publish = nil
            self?.flush()
        }
    }

    private func flush() {
        let batches = landed
        let refusals = gaveUpSinceLastPublish
        landed = [:]
        gaveUpSinceLastPublish = [:]
        // Keyed by the union, so a publish carrying only give-ups is still sent: a set that spent
        // its allowance on its first child has nothing to hand over and still has something to say.
        for key in Set(batches.keys).union(refusals.keys) {
            var info: [String: Any] = [
                Self.directoryKey: key.path,
                Self.scopeKey: key.scope,
                Self.totalsKey: batches[key] ?? [:]
            ]
            if let refused = refusals[key], !refused.isEmpty { info[Self.gaveUpKey] = refused }
            NotificationCenter.default.post(
                name: Self.didChangeNotification,
                object: self,
                userInfo: info
            )
        }
    }

    /// Forget every total a change under `path` could have altered, and tell the panes.
    ///
    /// The rule itself is the core's (`DirectorySizeCache.invalidate(under:)`): the path, its
    /// descendants *and* its ancestors — everything on one root-to-leaf line — because an FSEvents
    /// ping proves only "something under here changed" (`DirectoryWatcher` discards the event paths)
    /// and an ancestor's total sums whatever it was. Siblings survive, which is the whole value.
    ///
    /// The publish is unconditional and immediate rather than batched: this is the path where a
    /// *stale* number is on screen right now, and it is rare (a real filesystem change), where the
    /// batched path is common (a scan landing).
    func invalidate(under path: VFSPath) {
        cache.invalidate(under: path)
        // A change under here is proof the question is worth asking again — the same line the cache
        // drops (root to leaf, siblings surviving), so a folder that grew re-earns its attempt
        // while one nothing happened to stays refused.
        gaveUp = gaveUp.filter {
            !($0.path.isSelfOrDescendant(of: path) || path.isSelfOrDescendant(of: $0.path))
        }
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: self,
            userInfo: [Self.directoryKey: path]
        )
    }

    /// A repository was re-read. Drop its git-aware totals **only if what it ignores actually
    /// changed**, and tell the panes to stop showing the ones they hold.
    ///
    /// The conditional is the whole method. `GitStatusProvider` republishes on every debounced read
    /// — the pane it feeds does its own equality check — so in a repository under a build this fires
    /// continuously. Invalidating on each would re-walk every sized folder several times a second,
    /// against the same disk the build is using. `GitStatusSnapshot.ignoredPaths` moves only when
    /// the rules do (a `.gitignore` edit, a branch switch, a `git add` of an ignored file), which is
    /// exactly when a git-aware total stops being true.
    ///
    /// A repository whose status could not be read caches no snapshot; its remembered set is dropped
    /// so the next successful read is treated as a first look rather than compared against a basis
    /// that no longer describes anything.
    @objc func gitStatusDidChange(_ notification: Notification) {
        guard let root = notification.userInfo?[GitStatusProvider.repositoryRootKey] as? VFSPath
        else { return }
        guard let snapshot = GitStatusProvider.shared.cachedSnapshot(for: root) else {
            ignoredPaths.removeValue(forKey: root)
            return
        }
        let ignored = snapshot.ignoredPaths
        let previous = ignoredPaths.updateValue(ignored, forKey: root)
        // A first look establishes the basis without invalidating: nothing has been walked under
        // rules we never saw, so there is nothing to be wrong.
        guard let previous, previous != ignored else { return }
        cache.invalidateGitAware(under: root)
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: self,
            userInfo: [Self.directoryKey: root, Self.rulesChangedKey: true]
        )
    }
}
