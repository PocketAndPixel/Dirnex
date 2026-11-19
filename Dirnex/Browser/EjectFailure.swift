import DirnexCore
import Foundation

/// Why the sidebar's Eject failed. It is read off the main thread, where the failure is met,
/// because naming whoever holds the volume means reading every process on the Mac.
enum EjectFailure: Sendable, Equatable {
    /// Something has a file open on the volume. These are the names of whatever holds it, and the
    /// list can be empty.
    case inUse(by: [String])
    /// Any other failure, in the error's own words.
    case other(String)

    /// Reads an eject's error, and asks who is using the volume when that is why it failed.
    /// This blocks while it runs.
    static func reading(_ error: any Error, volumeAt path: String) -> EjectFailure {
        guard VolumeUsers.isInUse(error) else { return .other(error.localizedDescription) }
        return .inUse(by: VolumeUserProbe.names(usingVolumeAt: path))
    }

    /// The alert's body, under a title that names the volume. It used to read *"The operation
    /// couldn’t be completed. (OSStatus error -47.)"* for a share VLC was playing from, which
    /// Finder reports by naming VLC.
    var detail: String {
        switch self {
        case let .other(description):
            return description
        case let .inUse(names) where names.isEmpty:
            return String(
                localized: "The disk is still in use. Quit any app that may have files open on it, and try again.",
                comment: """
                Body of the eject-failure alert when the disk is in use and no process holding it \
                could be named. The title names the disk.
                """
            )
        case let .inUse(names) where names.count == 1:
            let name = names[0]
            return String(
                localized: "“\(name)” is using the disk. Quit it, or close what it has open there, and try again.",
                comment: """
                Body of the eject-failure alert when one app or process holds the disk; %@ is its \
                name (an app such as VLC or Terminal, or a process name). The title names the disk.
                """
            )
        case let .inUse(names):
            let list = ListFormatter.localizedString(byJoining: names)
            return String(
                localized: "\(list) are using the disk. Quit them, or close what they have open there, and try again.",
                comment: """
                Body of the eject-failure alert when several apps or processes hold the disk; %@ \
                is their names, as a list ("VLC and Terminal"). The title names the disk.
                """
            )
        }
    }
}
