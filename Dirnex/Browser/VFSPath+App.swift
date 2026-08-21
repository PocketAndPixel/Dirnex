import DirnexCore
import Foundation

extension VFSPath {
    /// A file-system URL for a `.local` path. Only meaningful for the local backend
    /// (the only one wired up in M1); archive/SFTP paths get their own launch route
    /// when those backends land.
    var localURL: URL {
        URL(fileURLWithPath: path)
    }

    /// What this backend's **root** is called, or `nil` for a backend whose root has no name of its
    /// own (a plain local path, a virtual listing).
    ///
    /// One definition, because two surfaces need it at once and they must agree: the path bar's root
    /// crumb — which needs it at *every* depth, since the crumb trail always starts there — and
    /// ``displayName``, which needs it only at the root. They were separate copies until S3 arrived
    /// and got neither, so the tab chip at a bucket root read a bare `"/"` directly above a crumb
    /// reading `probe — 127.0.0.1` (seen live 2026-08-13). Naming a new backend here is what both
    /// surfaces read, rather than a fourth `else if` in each of them.
    ///
    /// A bucket is rooted at its own name rather than at an account: the key id is what *reaches*
    /// it, not what it is called. The endpoint rides along because two buckets of the same name on
    /// two providers are a real thing — and an account, which has no bucket, is the endpoint alone.
    var backendRootTitle: String? {
        if let archivePath = backend.archivePath {
            // For a nested mount this is the extracted member's file name — the inner archive's own.
            return (archivePath as NSString).lastPathComponent
        }
        if let location = backend.sftpLocation {
            return "\(location.username)@\(location.host)"
        }
        if let location = backend.ftpLocation {
            return "\(location.username)@\(location.host)"
        }
        if let location = backend.s3Location {
            return "\(location.bucket) — \(location.host)"
        }
        if let account = backend.s3Account {
            // The endpoint alone. An access key id is 20+ characters of noise a user never typed and
            // cannot read at a glance, and it was the *whole* crumb here, since an account pane's
            // path is `/` and nothing else — so the one line naming where the pane is standing was
            // mostly key. It also agrees with what the backend already calls this listing:
            // `S3AccountBackend.rootEntry` names the root `account.host`.
            //
            // The price is that two accounts on one endpoint — a personal key and a work key — draw
            // the same title, and the sidebar tooltip made the same trade (`ServerConnection
            // .address`), so nothing in the chrome names the key any more. They are told apart
            // where they are *chosen*: by the name the user gave each row, and by the region, which
            // both the tooltip and the connect sheet show.
            return account.host
        }
        return nil
    }

    /// Whether this path is a **bucket row** — an entry in an S3 account's own listing, which is
    /// the one thing an ``S3AccountBackend`` draws below its root.
    ///
    /// The subject is the *row*, never the pane that holds it, and that distinction is the whole
    /// reason this is a property rather than a comparison written out at each site. A tree rooted on
    /// an account draws each expanded bucket's own contents beneath it, and those rows carry `s3://`
    /// paths — so a pane-level test answers "bucket" for every folder inside every bucket, and ⏎ on
    /// a folder three levels down asked the service to connect to a bucket of that name (reported
    /// 2026-08-22: entering `test2` inside `amzn-s3-df` reported that the key may not list "test2").
    var isS3BucketRow: Bool {
        backend.isS3Account && !isRoot
    }

    /// What to call this location when a sentence has to name it — the load-failure sheet's title,
    /// the tab chip, the New Folder sheet, and anything else that would otherwise print a bare
    /// `lastComponent`.
    ///
    /// At a backend *root* `lastComponent` is `"/"`, which names nothing: opening a corrupt archive
    /// put «Can't open "/"» above a body that named `broken.zip` correctly, because the navigation
    /// target is the archive's inner root. So each backend that can be *rooted* supplies its own
    /// name through ``backendRootTitle``. Everything else keeps `lastComponent`, which is already
    /// right.
    var displayName: String {
        guard isRoot else { return lastComponent }
        return backendRootTitle ?? lastComponent
    }
}
