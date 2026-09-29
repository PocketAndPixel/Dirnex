import Foundation

/// The links a license travels in (PLAN.md §M29 "Holding a key").
///
/// The license email carries a link to `https://dirnex.app/activate#<key>`, a page that offers
/// **Open in Dirnex**, which is `dirnex://license?key=<key>`. The key sits after the `#` on the
/// web page so it never reaches a server log. This type reads the key out of either link, and
/// builds the store's buy and renew addresses.
public enum LicenseLinks {
    public static let scheme = "dirnex"

    /// The store page that sells a license.
    public static let buy = URL(string: "https://dirnex.app/buy")!

    /// The store page that renews `key`. Only the random license id goes into the address, never
    /// the name or an email, since an address ends up in browser history and server logs.
    public static func renew(_ key: LicenseKey) -> URL {
        var components = URLComponents(string: "https://dirnex.app/renew")!
        components.queryItems = [URLQueryItem(name: "license", value: key.id)]
        return components.url ?? buy
    }

    /// The key text `dirnex://license?key=…` carries, not yet checked, or `nil` when `url` is not
    /// that link. The scheme and host are case-insensitive, as URL schemes and hosts are; a link
    /// with two `key` values is refused rather than guessed at.
    public static func keyText(in url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme,
              components.host?.lowercased() == "license",
              components.path.isEmpty || components.path == "/"
        else {
            return nil
        }
        let values = (components.queryItems ?? []).filter { $0.name == "key" }.compactMap(\.value)
        guard values.count == 1, let value = values.first, !value.isEmpty else { return nil }
        return value
    }

    /// What to check when someone pastes into the License field: the key inside either activation
    /// link, or the text as it was. People copy the link as often as the key.
    ///
    /// The link is looked for after the invisible characters are removed, because a mail client
    /// wraps a long link across lines the same way it wraps a key.
    public static func keyText(fromPasted text: String) -> String {
        let compact = LicenseKey.normalized(text)
        guard let url = URL(string: compact) else { return text }
        if let key = keyText(in: url) { return key }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              ["dirnex.app", "www.dirnex.app"].contains(components.host?.lowercased() ?? ""),
              components.path == "/activate",
              let fragment = components.fragment, !fragment.isEmpty
        else {
            return text
        }
        return fragment
    }
}
