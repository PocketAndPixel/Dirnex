import CoreFoundation
import DirnexCore
import Foundation
import NetFS
import NetFS.NetFSPlugin

/// Lists an SMB server's shares in-process, through the SMB plugin that `NetFSMountURLSync` itself
/// mounts with (PLAN.md §M35). The non-hermetic half of ``SMBServerBackend``: no subprocess, and the
/// password stays in memory, inside a `CFURL` the plugin builds, never in `argv`.
///
/// One call is one session: `CreateSessionRef`, `CreateURL`, `OpenSession`, `EnumerateShares`,
/// `CloseSession`. Three things about the plugin that are not guessable (docs/NOTES.md ▸ SMB): the
/// header is the submodule `NetFS.NetFSPlugin`; `QueryInterface` hands back a `NetFSInterface`
/// wrapper whose `_interface` is the table, not the table itself; and the type and interface ids are
/// macros Swift cannot import, so they are spelled out below.
///
/// **A listing comes only after `OpenSession` answered 0.** Measured 2026-11-04 on the NAS: after a
/// refused guest session, `EnumerateShares` still answered, as an account nobody had asked for.
/// Blocking: call it off the main actor.
struct SMBShareEnumerator: SMBShareEnumerating {
    let server: SMBLocation
    /// The account's password, or `nil` for a guest.
    let password: String?

    func shares() throws -> [SMBShare] {
        let plugin = try Self.mountInterface()
        defer { plugin.release() }
        let table = plugin.table

        var session: UnsafeMutableRawPointer?
        try Self.check(table.CreateSessionRef(&session))
        defer { _ = table.CloseSession(session) }

        var urlRef: Unmanaged<CFURL>?
        try Self.check(table.CreateURL(urlParameters as CFDictionary, &urlRef))
        guard let url = urlRef?.takeRetainedValue() else {
            throw SMBShareListingError(status: Int32(EINVAL))
        }

        var sessionInfo: Unmanaged<CFDictionary>?
        try Self.check(table.OpenSession(url, session, openOptions as CFDictionary, &sessionInfo))
        sessionInfo?.release()

        var sharepoints: Unmanaged<CFDictionary>?
        try Self.check(table.EnumerateShares(session, nil, &sharepoints))
        let answer = sharepoints?.takeRetainedValue() as? [String: Any] ?? [:]
        return SMBShare.shares(fromSharepoints: answer)
    }

    // MARK: - What is asked

    /// The parts `CreateURL` builds the session's URL from. The password goes in here rather than
    /// into a string: the plugin escapes it, and an `@` in it came back as `%40` with the host still
    /// parsed as the host (measured 2026-11-04).
    private var urlParameters: [String: Any] {
        var parameters: [String: Any] = [
            kNetFSSchemeKey as String: "smb",
            kNetFSHostKey as String: server.host
        ]
        if server.port != SMBLocation.defaultPort {
            parameters[kNetFSAlternatePortKey as String] = String(server.port)
        }
        if let username = server.username {
            parameters[kNetFSUserNameKey as String] = username
            parameters[kNetFSPasswordKey as String] = password ?? ""
        }
        return parameters
    }

    /// No UI, ever: a wrong password fails here rather than raising NetAuthAgent's dialog. A
    /// location with no account asks for a guest session.
    private var openOptions: [String: Any] {
        var options: [String: Any] = [kNAUIOptionKey as String: kNAUIOptionNoUI as String]
        if server.username == nil { options[kNetFSUseGuestKey as String] = true }
        return options
    }

    private static func check(_ status: netfsError) throws {
        guard status == 0 else { throw SMBShareListingError(status: status) }
    }

    // MARK: - The plugin

    /// The SMB plugin's mount interface, held for one call.
    private struct MountInterface {
        let instance: UnsafeMutableRawPointer
        let queried: UnsafeMutableRawPointer
        let table: NetFSMountInterface_V1

        /// Give back both references: the instance's and the one `QueryInterface` added.
        func release() {
            _ = table.Release(queried)
            let unknown = instance.assumingMemoryBound(to: UnsafeMutablePointer<IUnknownVTbl>.self)
            _ = unknown.pointee.pointee.Release(instance)
        }
    }

    private static let pluginPath = "/System/Library/Filesystems/NetFSPlugins/smb.bundle"

    /// `kNetFSTypeID`, `02FE7D14-4E91-481E-946C-CE233C798CC0`.
    private static var netFSTypeID: CFUUID {
        CFUUIDGetConstantUUIDWithBytes(
            nil, 0x02, 0xFE, 0x7D, 0x14, 0x4E, 0x91, 0x48, 0x1E,
            0x94, 0x6C, 0xCE, 0x23, 0x3C, 0x79, 0x8C, 0xC0
        )
    }

    /// `kfs_NetFSMountInterfaceID_V1`, `8F34B6C4-F2E4-4ECD-8625-E5665811DE37`.
    private static var mountInterfaceID: CFUUID {
        CFUUIDGetConstantUUIDWithBytes(
            nil, 0x8F, 0x34, 0xB6, 0xC4, 0xF2, 0xE4, 0x4E, 0xCD,
            0x86, 0x25, 0xE5, 0x66, 0x58, 0x11, 0xDE, 0x37
        )
    }

    private static func mountInterface() throws -> MountInterface {
        let unavailable = SMBShareListingError(status: Int32(ENOTSUP))
        let bundleURL = URL(fileURLWithPath: pluginPath) as CFURL
        guard let plugin = CFPlugInCreate(kCFAllocatorDefault, bundleURL),
              let factories = CFPlugInFindFactoriesForPlugInTypeInPlugIn(netFSTypeID, plugin)
              as? [CFUUID],
              let factory = factories.first,
              let instance = CFPlugInInstanceCreate(kCFAllocatorDefault, factory, netFSTypeID)
        else { throw unavailable }

        let unknown = instance.assumingMemoryBound(to: UnsafeMutablePointer<IUnknownVTbl>.self)
        var queried: LPVOID?
        let result = unknown.pointee.pointee.QueryInterface(
            instance,
            CFUUIDGetUUIDBytes(mountInterfaceID),
            &queried
        )
        guard result == 0, let queried,
              let tablePointer = queried.assumingMemoryBound(to: NetFSInterface.self)
                  .pointee._interface
        else {
            _ = unknown.pointee.pointee.Release(instance)
            throw unavailable
        }
        let table = tablePointer.assumingMemoryBound(to: NetFSMountInterface_V1.self).pointee
        return MountInterface(instance: instance, queried: queried, table: table)
    }
}
