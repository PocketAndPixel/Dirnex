import DirnexCore
import Foundation

/// Why a vault did not lock, along with whatever was holding it when that was the reason. It is the
/// sidebar Eject's ``EjectFailure`` for a vault.
///
/// `hdiutil detach` on a busy image exits 16 with *"couldn't unmount "disk11" - Resource busy"*,
/// and that refusal came back in 0.16 s with the holder still open, so the kernel can be asked
/// right after it (measured 2026-11-19 on an image held open by a `sleep`). The question is put in
/// the same off-main body as the detach.
struct VaultLockFailure: Sendable, Equatable {
    let error: VaultError
    /// The names of whatever is using the vault, which can be empty. A failure for any other
    /// reason has none.
    let users: [String]

    /// The sentence under a vault alert's title. A vault in use names whatever is using it, when
    /// anything could be named. Otherwise it is the vault failure's own sentence, which for a vault
    /// in use says only *"“Secret” is still in use, so it couldn’t be locked."*
    static func detail(for error: VaultError, users: [String]) -> String {
        guard case let .volumeInUse(vault) = error, let user = users.first else {
            return LocalizedCatalog.sentence(for: error)
        }
        guard users.count > 1 else {
            return String(
                localized: "“\(user)” is using “\(vault)”. Quit it, or close what it has open there, and try again.",
                comment: """
                Body of the alert when a vault couldn't be locked because one app or process is \
                using it. %1$@ is that app or process (VLC, Terminal, or a process name), %2$@ the \
                vault's name. The title says the vault couldn't be locked.
                """
            )
        }
        let list = ListFormatter.localizedString(byJoining: users)
        return String(
            localized: "\(list) are using “\(vault)”. Quit them, or close what they have open there, and try again.",
            comment: """
            Body of the alert when a vault couldn't be locked because several apps or processes are \
            using it. %1$@ is their names, as a list ("VLC and Terminal"), %2$@ the vault's name. \
            The title says the vault couldn't be locked.
            """
        )
    }
}

extension VaultLockFailure {
    /// Reads a detach's error, and asks who is using the volume when that is why it failed.
    /// This blocks while it runs. In an extension, so the memberwise initializer stays.
    init(reading error: any Error, mountPoint: String) {
        let error = (error as? VaultError) ?? .couldNotLock
        guard case .volumeInUse = error else {
            self.init(error: error, users: [])
            return
        }
        self.init(error: error, users: VolumeUserProbe.names(usingVolumeAt: mountPoint))
    }
}
