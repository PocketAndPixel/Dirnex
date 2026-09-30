import AppKit
import DirnexCore

/// The button beside the S3 connect sheet's bucket field that fills it in from the account
/// (PLAN.md §M21 Slice 7).
///
/// **It is an assist, never a root, and that distinction is the whole design.** PLAN.md declined to
/// browse an account as a second root on the ground that a key scoped to one bucket is the ordinary
/// way these are issued, so an account-rooted design fails at the root for exactly the users whose
/// credentials are set up properly. A picker has none of that failure mode: the field is a text
/// field first and stays exactly as typeable as it was, so a key that cannot list buckets costs the
/// user nothing they had before.
///
/// Three decisions worth stating, because each had an obvious alternative:
///
/// - **A button rather than an `NSComboBox`.** The combo box is the AppKit control that *means*
///   "type it or pick it", and it wants its items before it pops — which here is a signed network
///   request, so it would either block the main thread inside `comboBoxWillPopUp` or pop empty and
///   fill in later. The button makes the request the user's own gesture, which it should be: it
///   costs a round trip, and on a metered API a control that fires on focus is a control that
///   spends without being asked.
/// - **A glyph rather than a word.** The button shares its row with the bucket field, whose width
///   belongs to the field; prose in a control that cannot grow either overruns or clips, which
///   docs/NOTES.md records from the shortcut recorder's pill (7 of 14 languages over budget there).
///   The words live in the tooltip and in the accessibility label, where length is free.
/// - **Every outcome is spoken, including the ones that are not failures.** A gesture that answers
///   with nothing is the no-op that looks like it worked, so "this key can't list buckets" is a row
///   in the menu rather than silence — worded as an explanation with a way forward, since the user
///   has done nothing wrong.
@MainActor
final class ConnectServerS3BucketPicker {
    /// The control the form puts in its layout, beside the bucket field.
    let view = NSView()

    private let button = NSButton()
    private let spinner = NSProgressIndicator()

    /// The account the request is aimed at, read from the live form when the button is clicked —
    /// `nil` when what is typed so far cannot make one. Handed in rather than read from here, so
    /// this type owns a control and the form goes on owning its fields.
    var account: (() -> (account: S3Account, secretAccessKey: String)?)?

    /// Apply a chosen bucket. The region rides along because a bucket list spans regions while the
    /// form's region field holds one, and AWS names each bucket's own in `<BucketRegion>` — so
    /// picking can correct the region rather than leaving the user to discover it through a 301.
    var didChoose: ((_ bucket: String, _ region: String?) -> Void)?

    init() {
        button.image = NSImage(
            systemSymbolName: "list.bullet",
            accessibilityDescription: ConnectText.listBuckets
        )
        button.bezelStyle = .rounded
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(clicked)
        button.toolTip = ConnectText.listBuckets
        button.setAccessibilityLabel(ConnectText.listBuckets)

        spinner.style = .spinning
        spinner.controlSize = .small
        // **Hidden, not merely not-drawn.** `isDisplayedWhenStopped = false` stops a stopped
        // spinner *drawing*; it does not stop it being hit-tested, and this one is centered on the
        // button. Measured live: with only that flag set, a click on the middle of the button did
        // nothing at all while a click on its rim fired the action — the quiet direction twice
        // over, since the control looks perfect and half of it works.
        spinner.isHidden = true

        for child in [button, spinner] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            button.topAnchor.constraint(equalTo: view.topAnchor),
            button.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            button.widthAnchor.constraint(equalToConstant: 28),
            // The spinner sits *on* the button rather than beside it, so a fetch does not change
            // the row's width — a control that grows while it works shifts the field next to it.
            spinner.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: button.centerYAnchor)
        ])
    }

    @objc private func clicked() {
        guard let resolved = account?() else {
            // Nothing usable typed yet — most often an empty secret, and the common first click on
            // a freshly opened sheet. Said in the same place every other answer appears, rather
            // than doing nothing and leaving the button looking broken, and said as *its own*
            // sentence: no request has gone out, so a refusal would be a claim about a server that
            // has not been asked.
            present([disabledItem(ConnectText.bucketListNeedsCredentials)])
            return
        }
        beginLoading()
        Task { @MainActor in
            let outcome = await BlockingWork.run {
                S3BucketLister.buckets(
                    for: resolved.account,
                    secretAccessKey: resolved.secretAccessKey
                )
            }
            endLoading()
            present(menuItems(for: outcome))
        }
    }

    private func beginLoading() {
        button.isEnabled = false
        button.image = nil
        spinner.isHidden = false
        spinner.startAnimation(nil)
    }

    private func endLoading() {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        button.image = NSImage(
            systemSymbolName: "list.bullet",
            accessibilityDescription: ConnectText.listBuckets
        )
        button.isEnabled = true
    }

    /// The menu one outcome becomes. Every case produces at least one row: a menu that pops empty
    /// is indistinguishable from a menu that failed to pop.
    private func menuItems(for outcome: S3BucketLister.Outcome) -> [NSMenuItem] {
        switch outcome {
        case let .buckets(buckets) where buckets.isEmpty:
            return [disabledItem(ConnectText.bucketListEmpty)]
        case let .buckets(buckets):
            return buckets.map { bucket in
                let item = NSMenuItem(
                    title: bucket.name,
                    action: #selector(chose(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = bucket
                return item
            }
        case .notPermitted:
            return [disabledItem(ConnectText.bucketListNotPermitted)]
        case .badCredentials:
            return [disabledItem(ConnectText.bucketListBadCredentials)]
        case .unreachable:
            return [disabledItem(ConnectText.bucketListFailed)]
        }
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func present(_ items: [NSMenuItem]) {
        let menu = NSMenu()
        // A menu built here carries no unmodified accelerators, so it needs none of the
        // digit-clearing `PlacesMenu` does — but it is also not in the menu bar, which is what makes
        // that true (docs/NOTES.md ▸ AppKit).
        menu.autoenablesItems = false
        for item in items { menu.addItem(item) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height), in: view)
    }

    @objc private func chose(_ sender: NSMenuItem) {
        guard let bucket = sender.representedObject as? S3Bucket else { return }
        didChoose?(bucket.name, bucket.region)
    }
}
