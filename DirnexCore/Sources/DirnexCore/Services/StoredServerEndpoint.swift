import Foundation

/// A ``ServerEndpoint`` written into something that outlives this build — a persisted tab, a saved
/// workspace — that decodes to *nothing* rather than throwing when it cannot be read.
///
/// It exists because of what a throw costs at the place it happens. A pane's tabs are one JSON
/// blob and a workspace holds two panes' worth, so `[PersistedTab]` and `[WorkspaceTab]` are
/// arrays: one element that refuses to decode takes the **whole array** with it. An endpoint is an
/// enum with associated values, which is exactly the shape a synthesized `Codable` refuses on an
/// unknown case (docs/NOTES.md records the same trap for `PersistedTab.viewMode`, where a raw
/// string was chosen for it) — so the day a new protocol is added, a build that has it and a build
/// that has not would not merely disagree about one tab, they would empty each other's sessions.
///
/// Tolerant in exactly one direction: an endpoint this build cannot read comes back as `nil`, and
/// the tab is then restored *without* a connection to re-establish rather than being dropped. The
/// data behind an unreadable case is not preserved across a re-save — nothing short of holding the
/// raw JSON could do that, and a session is rewritten on every quit regardless.
public struct StoredServerEndpoint: Sendable, Hashable, Codable {
    /// The endpoint, or `nil` when what was stored is a shape this build has never heard of.
    public let endpoint: ServerEndpoint?

    /// Non-optional on purpose: an absent endpoint is an absent *field*, so a caller writes
    /// `endpoint.map(StoredServerEndpoint.init)` and "nothing to reconnect" stays out of the JSON
    /// entirely. `nil` inside one can therefore only ever be a decode this build could not make.
    public init(_ endpoint: ServerEndpoint) {
        self.endpoint = endpoint
    }

    public init(from decoder: any Decoder) throws {
        endpoint = try? ServerEndpoint(from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        guard let endpoint else {
            // Reachable only by re-saving a session that held an unreadable endpoint. A null is
            // valid JSON and decodes straight back to `nil`, where omitting the value would leave
            // the single-value container empty and fail the encode of the whole pane.
            var container = encoder.singleValueContainer()
            try container.encodeNil()
            return
        }
        try endpoint.encode(to: encoder)
    }
}
