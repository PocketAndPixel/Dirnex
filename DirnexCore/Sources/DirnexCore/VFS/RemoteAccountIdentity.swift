import Foundation

/// An owner or a group as a server's own tools name it (PLAN.md §M38 Slice 1).
///
/// A name where the server has one, and otherwise the number, which is what `id` and `ls` both print
/// for an id with no name (measured on GNU and busybox: `uid=1234 gid=5678 groups=5678`). `chown`
/// takes either.
///
/// The number rides along because the two sources need not print the same column. `id` gives both,
/// where a listing gives one of them, so a read-back compares with ``matches(_:)`` rather than
/// with `==`, or a server that lists numbers would report every change as refused.
public struct RemotePrincipal: Sendable, Hashable, Codable {
    /// What a command is handed: the name, or the number spelled out where there is no name.
    public let name: String
    /// The number, when the source reported it. A listing's column does not say which it printed.
    public let id: UInt32?

    public init(name: String, id: UInt32? = nil) {
        self.name = name
        self.id = id
    }

    /// Whether a listing's owner or group column is this one.
    public func matches(_ listed: String?) -> Bool {
        guard let listed else { return false }
        return listed == name || id.map(String.init) == listed
    }
}

/// Who an SFTP account is on its own server, as `id` says (PLAN.md §M38 Slice 1).
///
/// One `id` answers everything Get Info needs to know before it offers an owner or a group: whether
/// the account is root, and which groups it may hand an item to. **A non-root account can give an
/// item only to a group it belongs to, and to nobody else's ownership at all** (measured on a real
/// `sshd`: `chown` to another uid and `chgrp` to a stranger's group both answer `Permission denied`),
/// so a list from anywhere else would offer choices every Save refuses.
///
/// It has to come over the exec channel, and that is not a choice between routes. `sftp`'s batch
/// language has no verb that says who you are, and its `ls -ln` prints names on a current server,
/// resolved through the `users-groups-by-id` request (docs/NOTES.md ▸ sftp / ssh). An account with no
/// exec channel therefore has no answer, and stays read-only.
public struct RemoteAccountIdentity: Sendable, Equatable {
    public let user: RemotePrincipal
    /// Every group the account belongs to, its primary group first and none twice.
    public let groups: [RemotePrincipal]

    public init(user: RemotePrincipal, groups: [RemotePrincipal]) {
        self.user = user
        self.groups = groups
    }

    public var isSuperuser: Bool { user.id == 0 }

    /// The groups to offer for an item listed in the group `listed`: this account's own, led by the
    /// item's where the account does not belong to it.
    ///
    /// The item's group has to be there whatever the account's membership, because a control that
    /// cannot show what the item has now would open already reading as a change. Matched with
    /// ``RemotePrincipal/matches(_:)``, so a search hit's `20` selects the account's `staff`.
    public func groupChoices(listed: String?) -> [RemotePrincipal] {
        guard let listed, !groups.contains(where: { $0.matches(listed) }) else { return groups }
        return [RemotePrincipal(name: listed)] + groups
    }

    /// The account as `id`'s output describes it, or `nil` when `output` is not `id`'s.
    ///
    /// **The output's shape is the only evidence the command ran.** An `sftp`-only account answers
    /// an exec request with prose on stdout and a Synology non-admin with `Permission denied, please
    /// try again.` (docs/NOTES.md ▸ The SSH exec channel), and neither stream nor status tells those
    /// from a shell that ran something. A line has to begin with `uid=` and go on with a `gid=` to
    /// count, so neither sentence can be read as an account.
    ///
    /// Read from the last line up, because an rc file is free to print on stdout before the command.
    /// `id`'s own output is one line on every implementation measured: macOS, GNU and busybox.
    public static func parse(_ output: String) -> RemoteAccountIdentity? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            if let identity = identity(fromLine: line) { return identity }
        }
        return nil
    }

    /// `uid=501(oleg) gid=20(staff) groups=20(staff),12(everyone)`, and what can follow or be left
    /// out: GNU appends ` context=…` under SELinux, `euid=` and `egid=` sit between the two parts of
    /// a set-id process, and POSIX allows `groups=` to be absent for an account with none.
    private static func identity(fromLine line: Substring) -> RemoteAccountIdentity? {
        var reader = IDOutputReader(rest: line)
        guard reader.skip("uid="), let user = reader.principal(),
              reader.skip(" gid="), let primary = reader.principal()
        else { return nil }
        var groups = [primary]
        if reader.advance(past: " groups=") {
            while let group = reader.principal() {
                if !groups.contains(where: { $0.id == group.id }) { groups.append(group) }
                guard reader.skip(",") else { break }
            }
        }
        return RemoteAccountIdentity(user: user, groups: groups)
    }
}

/// A cursor over one line of `id`'s output.
private struct IDOutputReader {
    var rest: Substring

    mutating func skip(_ literal: String) -> Bool {
        guard rest.hasPrefix(literal) else { return false }
        rest.removeFirst(literal.count)
        return true
    }

    /// Move to just after `literal`, wherever it is, answering whether it was there.
    mutating func advance(past literal: String) -> Bool {
        guard let range = rest.range(of: literal) else { return false }
        rest = rest[range.upperBound...]
        return true
    }

    /// `501`, or `501(oleg)`.
    mutating func principal() -> RemotePrincipal? {
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard let number = UInt32(digits) else { return nil }
        rest.removeFirst(digits.count)
        guard rest.first == "(" else { return RemotePrincipal(name: String(number), id: number) }
        rest.removeFirst()
        guard let close = closingParenthesis() else { return nil }
        let name = String(rest[..<close])
        rest = rest[rest.index(after: close)...]
        return RemotePrincipal(name: name, id: number)
    }

    /// The `)` that ends a name: one followed by the end of the line, a comma or a space.
    ///
    /// Not simply the next one, since a directory service's group can be called anything
    /// (`domain users`), and not the next comma, since that would swallow the rest of the list.
    private func closingParenthesis() -> Substring.Index? {
        var from = rest.startIndex
        while let found = rest[from...].firstIndex(of: ")") {
            let next = rest.index(after: found)
            if next == rest.endIndex || rest[next] == "," || rest[next] == " " { return found }
            from = next
        }
        return nil
    }
}

/// What this connection has learned about its account on the server (PLAN.md §M38 Slice 1).
///
/// Held by the backend as a reference, for the reason the other `…Support` types are: the backend is
/// copied freely, and a fact about the *server* must not be copied away with it. Asked once per
/// connection, so opening Get Info twice on an `sftp`-only account does not pay for the refusal
/// twice (PLAN.md §M25's rule: learned when first needed, and remembered for that connection).
public final class RemoteAccountIdentitySupport: @unchecked Sendable {
    private let lock = NSLock()
    private var answer: RemoteAccountIdentity?
    private var isKnown = false

    public init() {}

    /// The remembered answer: `.some(nil)` is an account known to have none, and `nil` is not asked.
    public var known: RemoteAccountIdentity?? {
        lock.lock()
        defer { lock.unlock() }
        return isKnown ? .some(answer) : nil
    }

    public func record(_ identity: RemoteAccountIdentity?) {
        lock.lock()
        answer = identity
        isKnown = true
        lock.unlock()
    }
}
