import Foundation

/// An SFTP account's owner and group, over the exec channel (PLAN.md §M38 Slice 1).
public extension SFTPBackend {
    /// Who this account is on its server, or `nil` when it cannot be asked.
    ///
    /// **Remembered for the connection**, in either direction. Only an answer counts: a transport
    /// failure says nothing about the account, so the next Get Info asks again, and cancellation
    /// travels because it is the caller's own instruction.
    func accountIdentity(
        at path: VFSPath,
        isCancelled: () -> Bool
    ) throws -> RemoteAccountIdentity? {
        try requireOwnBackend(path)
        if let known = identitySupport.known { return known }
        let output: String?
        do {
            output = try transport.runCommand(SSHOwnershipCommand.identity, isCancelled: isCancelled)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
        guard let output else { return nil }
        let identity = RemoteAccountIdentity.parse(output)
        identitySupport.record(identity)
        return identity
    }
}

extension SFTPBackend {
    /// Run the ownership steps among `steps`, answering what was refused.
    ///
    /// Separate from the `sftp` batch because it is a different channel, and run first by the
    /// caller because **any group change clears set-uid and set-gid**, so the mode that restores them
    /// has to land after it (▸ ``RemoteAttributeChange/between(current:permissions:modificationTime:shownModificationTime:owner:group:editable:)``).
    func applyOwnership(
        _ steps: [RemoteMetadataStep],
        to remotePath: String
    ) throws -> [RemoteMetadataRefusal] {
        try steps.compactMap { step in
            guard case let .setOwnership(owner, group) = step else { return nil }
            guard let command = SSHOwnershipCommand.change(
                owner: owner,
                group: group,
                of: remotePath
            ) else { return .itemRefused("") }
            return try SSHOwnershipCommand.refusal(
                in: transport.runCommand(command, isCancelled: { false })
            )
        }
    }
}
