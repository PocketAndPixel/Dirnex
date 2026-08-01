import Foundation

/// The `/bin/sh` command that applies an ``AttributeChangePlan`` **as root**, for the narrow cases
/// the M14 probe matrix says need it (PLAN.md §M14 Slice 5): a file the user does not own, and the
/// `SF_*` / system-immutable bits an owner cannot clear.
///
/// One command serves **both** escalation paths, which is the exit criterion ("the authenticate path
/// and the copyable command produce the same result on the same file"). The in-app path hands
/// ``scriptBody`` to `do shell script … with administrator privileges`; the copyable "or run it
/// yourself" field wraps the same body in ``terminalCommand`` (`sudo /bin/sh -c …`). Same bytes, same
/// result.
///
/// This is the security-critical seam — the same lesson as FTP's `-Q` and the Google `doc_id`: a file
/// name is attacker-controlled data (unzip an archive and you can be editing a folder called
/// `` `touch /tmp/pwned` ``), and every byte here ends up on the command line of a shell running as
/// **root**. So every path and every ACL subject is quoted through ``ShellQuoting`` and nothing is
/// interpolated raw. The tools are named by absolute path, both because a root command must not trust
/// `PATH` and because it is what the user reads in the copyable field.
///
/// **It reproduces the plan through stock CLI, and two aspects have no faithful stock reproduction —
/// so they are omitted and named, never silently dropped** (decided with Oleg, 2026-08-01):
///
/// - **The birth/Created date.** No tool in a stock shell sets it: `SetFile` is Xcode-only, and
///   whole-second and US-format at that. A ``AttributeChangePlan/Step/setCreationDate(_:)`` becomes
///   ``Omission/creationDate``.
/// - **An ACL that `chmod` cannot express.** `chmod +a#` reproduces an *exact ordered* list
///   (probed), but only for entries with a resolved subject and no `inherited` marker — it rejects a
///   bare GUID ("Unable to translate … to a UUID") and re-creates an inherited entry as an explicit
///   one. When any entry fails that test the *whole* ACL is left for the user rather than written
///   wrongly, as ``Omission/accessControlList``.
///
/// Everything else is faithful. `chmod` and `chflags` carry the whole target word (the setuid digit
/// included); `touch` sets times whole-second, which is exactly the `NSDatePicker`'s own resolution,
/// and only the time that actually changed, so an untouched neighbour keeps its sub-second value.
/// `chflags` is **additive** (probed: `chflags hidden` then `chflags uchg` yields `uchg,hidden`), so
/// each flags step is emitted as the minimal `keyword` / `nokeyword` delta against the word on disk at
/// that point in the plan — which is also the readable form for the copyable field.
public struct EscalatedAttributeCommand: Sendable, Equatable {
    /// An aspect of the requested change no stock shell tool can reproduce faithfully, so the command
    /// leaves it out. The app states each one so the user knows what the elevated run will *not* do.
    public enum Omission: Sendable, Hashable, CaseIterable {
        /// The birth/Created date — omitted because no stock CLI sets it (see the type doc).
        case creationDate
        /// The access-control list — omitted whole because at least one entry is not reproducible by
        /// `chmod` (an inherited entry, an unresolved GUID subject, or a token this build only keeps
        /// verbatim).
        case accessControlList
    }

    /// The shell script body — one or more commands joined by `&&`, run as root. Empty when the plan
    /// reduces to nothing this can express (e.g. the only change was the Created date). Joined by
    /// `&&` on purpose: a failed step stops the chain, matching ``FileAttributeIO/apply(_:to:)``'s
    /// stop-on-first-error, and its exit code is what `do shell script` surfaces.
    public let scriptBody: String

    /// The aspects the command does not reproduce, if any.
    public let omissions: Set<Omission>

    public init(scriptBody: String, omissions: Set<Omission>) {
        self.scriptBody = scriptBody
        self.omissions = omissions
    }

    /// Nothing for an elevated run to do — no commands. It may still carry ``omissions``, which is the
    /// "the only thing you changed cannot be elevated" case the caller reports rather than running.
    public var hasCommands: Bool { !scriptBody.isEmpty }

    /// The self-contained line for the copyable field: the same body, run as root by the user.
    /// `sudo /bin/sh -c '<body>'` is one paste and one password; the body is quoted as a single
    /// argument (the nested quoting `ShellQuoting` exists for), so the shell hands the whole script to
    /// the inner `sh` untouched. `nil` when there are no commands.
    public var terminalCommand: String? {
        guard hasCommands else { return nil }
        return "sudo /bin/sh -c \(ShellQuoting.quoted(scriptBody, for: .other))"
    }

    // MARK: - Building

    /// Translate `plan` into the elevated command that applies it to `path`, given the item's
    /// `current` attributes (needed to emit minimal `chflags` deltas and to touch only the times that
    /// actually changed).
    public static func build(
        for plan: AttributeChangePlan,
        path: String,
        current: FileAttributes
    ) -> EscalatedAttributeCommand {
        let quoted = ShellQuoting.quoted(path, for: .other)
        let link = plan.actsOnLink
        var commands: [String] = []
        var omissions: Set<Omission> = []
        // The flags word as each step leaves it, so a `setFlags` step is a delta from what is on disk
        // now rather than an absolute set (`chflags` is additive).
        var flagsOnDisk = current.flags

        for step in plan.steps {
            switch step {
            case let .setFlags(target):
                if let command = chflagsCommand(
                    from: flagsOnDisk,
                    to: target,
                    link: link,
                    path: quoted
                ) {
                    commands.append(command)
                }
                flagsOnDisk = target
            case let .setOwnership(userID, groupID):
                if let command = chownCommand(
                    userID: userID,
                    groupID: groupID,
                    link: link,
                    path: quoted
                ) {
                    commands.append(command)
                }
            case let .setPermissions(permissions):
                commands.append("\(chmodTool) \(flag(link))\(permissions.octalString) \(quoted)")
            case let .setTimes(access, modification):
                commands.append(contentsOf: touchCommands(
                    access: access, modification: modification, current: current, link: link,
                    path: quoted
                ))
            case .setCreationDate:
                omissions.insert(.creationDate)
            case let .setAccessControlList(list):
                if let commandsForACL = accessControlListCommands(list, link: link, path: quoted) {
                    commands.append(contentsOf: commandsForACL)
                } else {
                    omissions.insert(.accessControlList)
                }
            }
        }

        return EscalatedAttributeCommand(
            scriptBody: commands.joined(separator: " && "),
            omissions: omissions
        )
    }

    // MARK: - One step at a time

    /// The minimal `chflags` delta from `from` to `to`, or `nil` when nothing changed. Each changed
    /// bit is emitted as its keyword (to set) or `no`-keyword (to clear), which leaves every other bit
    /// on the file untouched — the additive semantics `chflags` actually has.
    private static func chflagsCommand(
        from: BSDFileFlags,
        to: BSDFileFlags,
        link: Bool,
        path: String
    ) -> String? {
        let changed = from.symmetricDifference(to)
        guard !changed.isEmpty else { return nil }
        var tokens: [String] = []
        for (option, keyword) in flagKeywords where changed.contains(option) {
            tokens.append(to.contains(option) ? keyword : "no\(keyword)")
        }
        // `changed` can only ever contain bits with a keyword here: the offered `UF_*` boxes, the two
        // immutable bits the unlock/relock toggles, and nothing else — `SF_DATALESS` is preserved by
        // both sides of every step, so it never lands in a delta (it also cannot be set by `chflags`).
        guard !tokens.isEmpty else { return nil }
        return "\(chflagsTool) \(flag(link))\(tokens.joined(separator: ",")) \(path)"
    }

    /// `chown uid:gid` / `chown uid` / `chgrp gid`, by numeric id so no name resolution is trusted.
    /// `nil` only for the impossible "change nothing" ownership step.
    private static func chownCommand(
        userID: UInt32?,
        groupID: UInt32?,
        link: Bool,
        path: String
    ) -> String? {
        switch (userID, groupID) {
        case let (userID?, groupID?):
            return "\(chownTool) \(flag(link))\(userID):\(groupID) \(path)"
        case let (userID?, nil):
            return "\(chownTool) \(flag(link))\(userID) \(path)"
        case let (nil, groupID?):
            return "\(chgrpTool) \(flag(link))\(groupID) \(path)"
        case (nil, nil):
            return nil
        }
    }

    /// `touch -a` and/or `touch -m`, one per time that actually changed. `touch -t` sets a single
    /// value for whatever flags it is given, so two different times need two commands — and emitting
    /// only the changed one is what keeps an untouched time's sub-second value (`touch` is
    /// whole-second) from being rewritten. Time is formatted in the local zone, which is what
    /// `touch -t` reads.
    private static func touchCommands(
        access: Date,
        modification: Date,
        current: FileAttributes,
        link: Bool,
        path: String
    ) -> [String] {
        var commands: [String] = []
        if access != current.accessDate {
            commands.append("\(touchTool) \(flag(link))-a -t \(touchStamp(access)) \(path)")
        }
        if modification != current.modificationDate {
            commands.append("\(touchTool) \(flag(link))-m -t \(touchStamp(modification)) \(path)")
        }
        return commands
    }

    /// Clear the ACL and rebuild it in order with `chmod +a#`, or `nil` when any entry is one `chmod`
    /// cannot express (see ``Omission/accessControlList``). An empty list is a plain `chmod -N`.
    private static func accessControlListCommands(
        _ list: AccessControlList,
        link: Bool,
        path: String
    ) -> [String]? {
        let clear = "\(chmodTool) \(flag(link))-N \(path)"
        guard !list.isEmpty else { return [clear] }

        var commands = [clear]
        for (index, entry) in list.entries.enumerated() {
            guard entry.subject.isResolved, !entry.isInherited, entry.isMeaningful,
                  entry.unrecognizedRights.isEmpty, entry.unrecognizedFlags.isEmpty,
                  let spec = accessControlEntrySpec(entry)
            else { return nil }
            commands.append(
                "\(chmodTool) \(flag(link))+a# \(index) \(ShellQuoting.quoted(spec, for: .other)) \(path)"
            )
        }
        return commands
    }

    /// One entry as `chmod +a`'s friendly form: `user:name allow read,write,file_inherit`. The
    /// canonical `read/write/execute/append` spelling is accepted verbatim on a directory too —
    /// `chmod` translates it to `list/add_file/…` itself (probed) — so no per-kind relabelling here.
    private static func accessControlEntrySpec(_ entry: ACLEntry) -> String? {
        var rights = ACLRight.allCases.filter { entry.rights.contains($0) }.map(\.rawValue)
        for (token, option) in ACLInheritance.tokenTable
            where option != .inherited && entry.inheritance.contains(option) {
            rights.append(token)
        }
        guard !rights.isEmpty else { return nil }
        return "\(entry.subject.kind.rawValue):\(entry.subject.name) "
            + "\(entry.disposition.rawValue) \(rights.joined(separator: ","))"
    }

    // MARK: - Pieces

    /// `-h ` when acting on a symlink itself, empty otherwise — every tool here takes `-h` for that
    /// (matching the `l*` syscalls ``FileAttributeIO`` uses). Carries its own trailing space so it
    /// drops cleanly out of a command that does not need it.
    private static func flag(_ link: Bool) -> String { link ? "-h " : "" }

    /// `touch -t`'s `[[CC]YY]MMDDhhmm[.SS]`, in the local calendar and zone.
    private static func touchStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmm.ss"
        return formatter.string(from: date)
    }

    /// Each modelled flag bit and the `chflags` keyword for it. `SF_DATALESS` has none — it is never
    /// user-set and never appears in a delta.
    private static let flagKeywords: [(option: BSDFileFlags, keyword: String)] = [
        (.noDump, "nodump"),
        (.userImmutable, "uchg"),
        (.userAppend, "uappnd"),
        (.opaque, "opaque"),
        (.hidden, "hidden"),
        (.archived, "arch"),
        (.systemImmutable, "schg"),
        (.systemAppend, "sappnd")
    ]

    // Absolute tool paths: a root command must not trust `PATH`, and these are what the copyable
    // field shows the user.
    private static let chmodTool = "/bin/chmod"
    private static let chflagsTool = "/usr/bin/chflags"
    private static let chownTool = "/usr/sbin/chown"
    private static let chgrpTool = "/usr/bin/chgrp"
    private static let touchTool = "/usr/bin/touch"
}
