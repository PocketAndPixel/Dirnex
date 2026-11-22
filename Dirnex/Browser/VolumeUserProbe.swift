import AppKit
import Darwin
import DirnexCore

/// Asks the kernel which processes hold something open on a volume, so an eject refused because
/// the volume is in use can say who is using it (``VolumeUsers`` is the pure half and says why
/// NSWorkspace's own error cannot).
///
/// It only sees this account's processes: `proc_listpidspath` reads each process's open files, and
/// the kernel shows those to their owner alone. A daemon of another account holding the volume
/// leaves the list empty, and the alert then says only that the volume is in use.
enum VolumeUserProbe {
    /// The names of what is using the volume at `path`, or `[]` when nothing can be seen.
    ///
    /// Blocking: it reads every process on the Mac (283 ms over 793 processes in a release build,
    /// 2026-11-19), so it runs off the main thread, and only once an eject has failed.
    static func names(usingVolumeAt path: String) -> [String] {
        VolumeUsers.names(of: holders(of: path)) { process($0) }
    }

    /// The processes with a file, a working directory or a mapped image on the volume.
    ///
    /// `EXCLUDE_EVTONLY` leaves out a descriptor opened only to watch for changes (`O_EVTONLY`),
    /// which never holds a volume: that is how Finder and a pane's watcher look at a folder.
    private static func holders(of path: String) -> [Int32] {
        let running = proc_listallpids(nil, 0)
        guard running > 0 else { return [] }
        // Twice the count, for processes started between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(running) * 2)
        let stride = MemoryLayout<pid_t>.stride
        let bytes = path.withCString { volume in
            proc_listpidspath(
                UInt32(PROC_ALL_PIDS),
                0,
                volume,
                UInt32(PROC_LISTPIDSPATH_PATH_IS_VOLUME | PROC_LISTPIDSPATH_EXCLUDE_EVTONLY),
                &pids,
                Int32(pids.count * stride)
            )
        }
        guard bytes > 0 else { return [] }
        return Array(pids.prefix(Int(bytes) / stride))
    }

    /// One process's parent, name and app name.
    ///
    /// The parent comes from `sysctl`, which answers for any process, rather than from
    /// `proc_pidinfo`, which refused (`EPERM`) the root-owned `login` between Terminal and the
    /// shell it starts, and so would end the walk to Terminal one step short.
    private static func process(_ pid: Int32) -> VolumeUsers.Process? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        // A pid that has exited answers 0 with nothing written.
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return VolumeUsers.Process(
            parent: info.kp_eproc.e_ppid,
            name: name(of: pid, command: info.kp_proc.p_comm),
            appName: NSRunningApplication(processIdentifier: pid)?.localizedName
        )
    }

    /// `proc_name`'s longer name where the kernel gives it, else the 16-character command name
    /// `sysctl` always carries.
    private static func name(of pid: Int32, command: some Any) -> String {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        if length > 0, let name = String(bytes: buffer.prefix(Int(length)), encoding: .utf8) {
            return name
        }
        return withUnsafeBytes(of: command) { bytes in
            String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8) ?? ""
        }
    }
}
