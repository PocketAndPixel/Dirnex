import Foundation

/// Who is keeping a volume from being ejected, named the way the person at the Mac knows them.
///
/// `NSWorkspace.unmountAndEjectDevice` reports an open file on the volume as `fBsyErr` (-47) and
/// nothing else: its `userInfo` is empty, so the eject alert used to say *"OSStatus error -47"*
/// where Finder names the app. Probed 2026-11-19 on a disk image held open by a `sleep` and on the
/// NAS's `media` share held open by VLC. DiskArbitration knows the process too, but hands it over
/// only through `DADissenterGetProcessID`, which the framework exports and its header does not
/// declare. So the app asks the kernel itself (`proc_listpidspath`, which named VLC on the share),
/// and this type is the pure half: which failures mean "in use", and how the pids that answer
/// become names.
public enum VolumeUsers {
    /// What the app can learn about one process: its parent, its own name, and its app's name when
    /// it is one.
    public struct Process: Sendable, Equatable {
        public let parent: Int32
        /// The process's own name (`proc_name`), empty when the kernel would not say.
        public let name: String
        /// The app's display name when the process is an app, `nil` otherwise.
        public let appName: String?

        public init(parent: Int32, name: String, appName: String?) {
            self.parent = parent
            self.name = name
            self.appName = appName
        }
    }

    /// `fBsyErr` (MacErrors.h): the status `unmountAndEjectDevice` throws for a volume in use.
    static let fileBusyStatus = -47

    /// How many processes a holder's ancestry is followed through looking for an app. A shell in
    /// Terminal is two away (`bash`, then `login`), so this is generous and only bounds a loop.
    static let ancestryLimit = 16

    /// Whether an eject failed because something has a file open on the volume, which is the one
    /// failure worth asking the kernel about. `EBUSY` is what the same refusal is called below
    /// NSWorkspace (DiskArbitration's dissenter carried `unix_err(EBUSY)` in the same probe).
    public static func isInUse(_ error: any Error) -> Bool {
        let error = error as NSError
        switch error.domain {
        case NSOSStatusErrorDomain: return error.code == fileBusyStatus
        case NSPOSIXErrorDomain: return error.code == Int(EBUSY)
        default: return false
        }
    }

    /// The names to show for the processes holding a volume, first seen first, each once.
    ///
    /// A holder that is not an app is named by the nearest app above it, so a shell sitting in the
    /// volume reads as Terminal rather than `bash`. The walk stops at `launchd` (pid 1), which every
    /// daemon and agent is a child of and nobody can quit, and a holder with no app above it keeps
    /// its own name. A pid the lookup knows nothing about has exited since it was listed.
    public static func names(of holders: [Int32], lookup: (Int32) -> Process?) -> [String] {
        var names: [String] = []
        for holder in holders {
            guard let name = name(of: holder, lookup: lookup), !names.contains(name) else { continue }
            names.append(name)
        }
        return names
    }

    private static func name(of holder: Int32, lookup: (Int32) -> Process?) -> String? {
        guard let process = lookup(holder) else { return nil }
        var visited: Set<Int32> = [holder]
        var current = process
        for _ in 0..<ancestryLimit {
            if let app = current.appName, !app.isEmpty { return app }
            let parent = current.parent
            guard parent > 1, visited.insert(parent).inserted, let next = lookup(parent) else { break }
            current = next
        }
        return process.name.isEmpty ? nil : process.name
    }
}
