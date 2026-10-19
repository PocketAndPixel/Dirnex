import DirnexCore
import Foundation

/// The batched listing a tree refresh asks for, **routed** to each connection's own backend.
///
/// Forwarded rather than inherited for the reason docs/NOTES.md ▸ Design lessons records three
/// times over: the app holds a composite, and `VFSBackend.listDirectories` defaults to listing each
/// folder in turn. A composite that left it unforwarded would answer the same rows, correctly, by
/// one FTP login per expanded folder — exactly the cost the seam exists to remove (three logins and
/// a 59 s refresh interval on the tree that reported it, measured 2026-10-19), with nothing on
/// screen to say so. `CompositeBackendListingTests` pins the forward.
extension CompositeBackend {
    func listDirectories(at paths: [VFSPath], isCancelled: () -> Bool) throws -> [[FileEntry]?] {
        var answers = [[FileEntry]?](repeating: nil, count: paths.count)
        // One call per connection, in first-seen order, each keeping its own paths' order. A tree
        // lives on one connection, so this is ordinarily a single group; the grouping is what keeps
        // a caller that mixed them from sending one connection's paths down another's wire.
        var groups: [VFSBackendID: [Int]] = [:]
        var order: [VFSBackendID] = []
        for (index, path) in paths.enumerated() {
            if groups[path.backend] == nil { order.append(path.backend) }
            groups[path.backend, default: []].append(index)
        }
        for id in order {
            guard !isCancelled() else { throw CancellationError() }
            guard let indices = groups[id], let first = indices.first else { continue }
            // A group nothing can route — a connection that has gone, a synthetic root — is a group
            // nothing could list, which is the `nil` each folder's own listing would have answered.
            guard let owner = try? backend(for: paths[first]) else { continue }
            let listed = try owner.listDirectories(
                at: indices.map { paths[$0] }, isCancelled: isCancelled
            )
            for (index, answer) in zip(indices, listed) {
                answers[index] = answer
            }
        }
        return answers
    }
}
