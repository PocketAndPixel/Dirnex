import Foundation
import Testing

@testable import DirnexCore

@Suite("DirectorySizeCache")
struct DirectorySizeCacheTests {
    // MARK: - Storage

    @Test("stores and returns a total")
    func storesAndReturns() {
        var cache = DirectorySizeCache()
        cache.store(1234, for: .local("/a"))

        #expect(cache.size(for: .local("/a")) == 1234)
        #expect(cache.size(for: .local("/b")) == nil)
    }

    @Test("re-storing replaces the total rather than accumulating an entry")
    func reStoreReplaces() {
        var cache = DirectorySizeCache()
        cache.store(100, for: .local("/a"))
        cache.store(200, for: .local("/a"))

        #expect(cache.size(for: .local("/a")) == 200)
        #expect(cache.count == 1)
    }

    @Test("a negative total is clamped at the boundary")
    func negativeClamped() {
        var cache = DirectorySizeCache()
        cache.store(-5, for: .local("/a"))

        #expect(cache.size(for: .local("/a")) == 0)
    }

    @Test("paths in different backends are distinct keys")
    func backendScopedKeys() {
        var cache = DirectorySizeCache()
        cache.store(10, for: .local("/a"))
        cache.store(20, for: VFSPath(backend: VFSBackendID("sftp"), path: "/a"))

        #expect(cache.size(for: .local("/a")) == 10)
        #expect(cache.size(for: VFSPath(backend: VFSBackendID("sftp"), path: "/a")) == 20)
    }

    // MARK: - Eviction

    @Test("evicts the least-recently-stored entry past capacity")
    func evictsOldest() {
        var cache = DirectorySizeCache(capacity: 2)
        cache.store(1, for: .local("/a"))
        cache.store(2, for: .local("/b"))
        cache.store(3, for: .local("/c"))

        #expect(cache.count == 2)
        #expect(cache.size(for: .local("/a")) == nil) // oldest store, evicted
        #expect(cache.size(for: .local("/b")) == 2)
        #expect(cache.size(for: .local("/c")) == 3)
    }

    @Test("re-storing renews an entry's place in the eviction order")
    func reStoreRenews() {
        var cache = DirectorySizeCache(capacity: 2)
        cache.store(1, for: .local("/a"))
        cache.store(2, for: .local("/b"))
        cache.store(1, for: .local("/a")) // /a is now the most recent, /b the oldest
        cache.store(3, for: .local("/c"))

        #expect(cache.size(for: .local("/a")) == 1)
        #expect(cache.size(for: .local("/b")) == nil)
    }

    @Test("capacity is floored at one rather than accepting zero or negative")
    func capacityFloored() {
        var cache = DirectorySizeCache(capacity: 0)
        cache.store(1, for: .local("/a"))

        #expect(cache.capacity == 1)
        #expect(cache.size(for: .local("/a")) == 1)
    }

    // MARK: - Invalidation: the root-to-leaf line

    @Test("a change invalidates the directory itself")
    func invalidatesSelf() {
        var cache = DirectorySizeCache()
        cache.store(1, for: .local("/a/b"))
        cache.invalidate(under: .local("/a/b"))

        #expect(cache.size(for: .local("/a/b")) == nil)
    }

    @Test("a change invalidates every ancestor, whose totals include it")
    func invalidatesAncestors() {
        var cache = DirectorySizeCache()
        cache.store(1, for: .local("/"))
        cache.store(2, for: .local("/a"))
        cache.store(3, for: .local("/a/b"))
        cache.store(4, for: .local("/a/b/c"))

        cache.invalidate(under: .local("/a/b/c"))

        #expect(cache.size(for: .local("/a/b/c")) == nil)
        #expect(cache.size(for: .local("/a/b")) == nil)
        #expect(cache.size(for: .local("/a")) == nil)
        #expect(cache.size(for: .local("/")) == nil)
    }

    @Test("a path-less ping invalidates descendants too, since it cannot say which changed")
    func invalidatesDescendants() {
        // What `DirectoryWatcher` actually delivers: "something under /a changed", no path.
        var cache = DirectorySizeCache()
        cache.store(1, for: .local("/a"))
        cache.store(2, for: .local("/a/b"))
        cache.store(3, for: .local("/a/b/c"))

        cache.invalidate(under: .local("/a"))

        #expect(cache.size(for: .local("/a")) == nil)
        #expect(cache.size(for: .local("/a/b")) == nil)
        #expect(cache.size(for: .local("/a/b/c")) == nil)
    }

    @Test("siblings survive — a change under one branch cannot alter another's total")
    func siblingsSurvive() {
        var cache = DirectorySizeCache()
        cache.store(1, for: .local("/a/b"))
        cache.store(2, for: .local("/a/c"))
        cache.store(3, for: .local("/x/y"))

        cache.invalidate(under: .local("/a/b"))

        #expect(cache.size(for: .local("/a/b")) == nil)
        #expect(cache.size(for: .local("/a/c")) == 2) // sibling
        #expect(cache.size(for: .local("/x/y")) == 3) // unrelated branch
    }

    @Test("a name that merely shares a prefix is not a descendant")
    func prefixIsNotDescendant() {
        // The `/a` vs `/ab` boundary — the reason this goes through VFSPath rather than
        // a hand-rolled string prefix test.
        var cache = DirectorySizeCache()
        cache.store(1, for: .local("/ab"))
        cache.store(2, for: .local("/a"))

        cache.invalidate(under: .local("/a"))

        #expect(cache.size(for: .local("/a")) == nil)
        #expect(cache.size(for: .local("/ab")) == 1)
    }

    @Test("invalidation does not cross backends")
    func invalidationIsBackendScoped() {
        var cache = DirectorySizeCache()
        cache.store(1, for: .local("/a/b"))
        cache.store(2, for: VFSPath(backend: VFSBackendID("sftp"), path: "/a/b"))

        cache.invalidate(under: .local("/a"))

        #expect(cache.size(for: .local("/a/b")) == nil)
        #expect(cache.size(for: VFSPath(backend: VFSBackendID("sftp"), path: "/a/b")) == 2)
    }

    @Test("invalidating frees eviction slots, leaving no stale ordering entries behind")
    func invalidationReleasesOrderSlots() {
        var cache = DirectorySizeCache(capacity: 2)
        cache.store(1, for: .local("/a/b"))
        cache.invalidate(under: .local("/a/b"))
        cache.store(2, for: .local("/x"))
        cache.store(3, for: .local("/y"))

        // If the invalidated key still occupied a slot in the order, /x would have been evicted.
        #expect(cache.count == 2)
        #expect(cache.size(for: .local("/x")) == 2)
        #expect(cache.size(for: .local("/y")) == 3)
    }

    @Test("invalidating an uncached branch is a no-op")
    func invalidateUnknownIsNoOp() {
        var cache = DirectorySizeCache()
        cache.store(1, for: .local("/a"))
        cache.invalidate(under: .local("/somewhere/else"))

        #expect(cache.size(for: .local("/a")) == 1)
    }

    @Test("removeAll forgets everything — the explicit-refresh path")
    func removeAllClears() {
        var cache = DirectorySizeCache()
        cache.store(1, for: .local("/a"))
        cache.store(2, for: .local("/b"))
        cache.removeAll()

        #expect(cache.isEmpty)
        #expect(cache.size(for: .local("/a")) == nil)
    }
}
