import Foundation

/// Reading `hdiutil`'s plist output: where a vault got mounted, and which vaults are mounted now.
///
/// `-plist` rather than `hdiutil`'s prose, for the reason `FTPProcessArguments` reads `curl`'s exit
/// code rather than its stderr: a structured answer says the same thing in every language and does
/// not change when Apple rewords a line. The plists these parse were captured from the real tool and
/// are committed as fixtures, so the parser is tested against bytes `hdiutil` actually produced.
public enum DiskImageMount {
    /// Where an attached image's volume landed.
    public struct Mounted: Sendable, Equatable {
        /// The volume's mount point, e.g. `/Volumes/Vault`.
        public let mountPoint: String
        /// The device entry backing it, e.g. `/dev/disk17s1`. Kept for diagnostics; Dirnex addresses
        /// a vault by its mount point everywhere else.
        public let deviceEntry: String?
    }

    /// One image `hdiutil info` knows about.
    public struct AttachedImage: Sendable, Equatable {
        /// The image's own path, as `hdiutil` reports it — **already resolved**, so a vault at
        /// `/tmp/v.sparsebundle` comes back as `/private/tmp/v.sparsebundle`. Matching against a
        /// path the user typed therefore has to resolve symlinks on both sides, which
        /// ``isMounted(imageAtPath:in:)`` does.
        public let imagePath: String
        public let isEncrypted: Bool
        public let mountPoint: String?
    }

    /// The mount point from `hdiutil attach -plist`.
    ///
    /// An attach reports **several** `system-entities` — the partition scheme, the container, and
    /// the volume — and only one of them carries a `mount-point`. Picking "the first entity" would
    /// get the GUID partition scheme and no mount point at all, which is the shape of mistake that
    /// reads as "attach didn't work".
    public static func mountPoint(fromAttachPlist data: Data) -> Mounted? {
        guard let root = plist(data),
              let entities = root["system-entities"] as? [[String: Any]]
        else { return nil }

        for entity in entities {
            guard let point = entity["mount-point"] as? String, !point.isEmpty else { continue }
            return Mounted(mountPoint: point, deviceEntry: entity["dev-entry"] as? String)
        }
        return nil
    }

    /// Every image `hdiutil info -plist` lists.
    public static func attachedImages(fromInfoPlist data: Data) -> [AttachedImage] {
        guard let root = plist(data), let images = root["images"] as? [[String: Any]] else { return [
        ] }

        return images.compactMap { image in
            guard let path = image["image-path"] as? String else { return nil }
            let entities = image["system-entities"] as? [[String: Any]] ?? []
            let point = entities.lazy
                .compactMap { $0["mount-point"] as? String }
                .first { !$0.isEmpty }
            return AttachedImage(
                imagePath: path,
                // Absent rather than false on an unencrypted image in some versions, so read it as
                // "encrypted only if it says so".
                isEncrypted: (image["image-encrypted"] as? Bool) ?? false,
                mountPoint: point
            )
        }
    }

    /// Where the vault at `path` is mounted, or `nil` if it is locked.
    ///
    /// Both sides go through ``VaultLocation/normalizedPath(_:)`` before comparing, because
    /// `hdiutil` answers with the `/private`-prefixed spelling while the user says `/tmp`. A plain
    /// string comparison reports a mounted vault as locked, whose visible symptom is an Unlock that
    /// appears to do nothing — and Foundation's own resolvers cannot be used for it, since they only
    /// fold the prefix for paths that currently exist (measured; see that method).
    public static func isMounted(imageAtPath path: String, in images: [AttachedImage]) -> String? {
        let wanted = VaultLocation.normalizedPath(path)
        for image in images {
            guard VaultLocation.normalizedPath(image.imagePath) == wanted else { continue }
            if let point = image.mountPoint, !point.isEmpty { return point }
        }
        return nil
    }

    private static func plist(_ data: Data) -> [String: Any]? {
        try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any]
    }
}
