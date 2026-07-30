import AppKit
import DirnexCore

/// The create-checksum sheet's accessory: a name field over an algorithm popup, and the one piece
/// of behaviour between them — picking an algorithm re-suffixes the name, so choosing CRC32 turns
/// `Downloads.sha256` into `Downloads.sfv` without the user editing anything.
///
/// An object rather than a struct because it is the popup's target/action. Kept alive by the
/// sheet's completion closure, which captures it: `NSControl.target` is weak, so the accessory
/// would otherwise be gone by the time the user changes the algorithm.
///
/// SHA-256 leads. The M14 probe inverted the usual intuition — it is simultaneously the strongest
/// of the four *and* among the fastest, because SHA-1 and SHA-256 are ARMv8 crypto instructions
/// while MD5 and CRC32 are ordinary code. The other three are labelled as what they are: formats
/// carried to match a checksum someone else published, never a security property.
@MainActor
final class ChecksumAccessory: NSObject {
    let view: NSView
    let nameField: NSTextField
    private let algorithmPopup = NSPopUpButton()

    /// The order the popup lists — the recommended algorithm first, the interop formats after it,
    /// in `allCases` order so the list never reshuffles between launches.
    private static let order: [ChecksumAlgorithm] =
        [.recommended] + ChecksumAlgorithm.allCases.filter { $0 != .recommended }

    init(baseName: String) {
        let width: CGFloat = 340
        let nameLabel = NSTextField(labelWithString: String(
            localized: "Name:",
            comment: "Label before the file-name field in the pack and checksum sheets."
        ))
        let algorithmLabel = NSTextField(labelWithString: String(
            localized: "Algorithm:",
            comment: "Label before the algorithm popup in the create-checksum sheet."
        ))
        nameLabel.alignment = .right
        algorithmLabel.alignment = .right

        // Sized to the wider of the two *localized* captions, never a magic number: the 48 pt that
        // fits "Name:" and "Format:" in English clipped Russian «Формат:» in the pack sheet, and a
        // translation's fit is a live concern (docs/NOTES.md).
        let labelWidth = ceil(
            max(nameLabel.intrinsicContentSize.width, algorithmLabel.intrinsicContentSize.width)
        )
        let fieldX = labelWidth + 8
        nameLabel.frame = NSRect(x: 0, y: 34, width: labelWidth, height: 18)
        algorithmLabel.frame = NSRect(x: 0, y: 4, width: labelWidth, height: 18)

        nameField = NSTextField(frame: NSRect(x: fieldX, y: 30, width: width - fieldX, height: 24))
        nameField.stringValue = ChecksumManifest.suggestedFileName(
            for: baseName,
            algorithm: .recommended
        )

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 56))
        algorithmPopup.frame = NSRect(x: fieldX, y: 0, width: 220, height: 26)
        view = container
        super.init()

        for algorithm in Self.order {
            algorithmPopup.addItem(withTitle: Self.title(for: algorithm))
        }
        algorithmPopup.selectItem(at: 0)
        algorithmPopup.target = self
        algorithmPopup.action = #selector(algorithmChanged)

        for subview in [nameLabel, algorithmLabel, nameField, algorithmPopup] {
            container.addSubview(subview)
        }
    }

    /// The chosen algorithm. The popup is built from ``order``, so the index maps straight back; a
    /// negative index (no selection) falls back to the recommended one.
    var algorithm: ChecksumAlgorithm {
        Self.order[max(0, algorithmPopup.indexOfSelectedItem)]
    }

    /// The manifest's file name, with the algorithm's own extension enforced.
    ///
    /// The user may type anything, but a `.sha256` file holding CRC32 digests is a file every other
    /// tool will misread — and the width is the only signal an unlabelled line carries, so the
    /// extension is the one part of the name that is not theirs to get wrong. An empty field falls
    /// back to the algorithm's extension alone rather than writing a nameless file.
    var manifestFileName: String {
        let typed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (typed as NSString).deletingPathExtension
        let stem = base.isEmpty ? typed : base
        guard !stem.isEmpty else { return "checksums.\(algorithm.fileExtension)" }
        return ChecksumManifest.suggestedFileName(for: stem, algorithm: algorithm)
    }

    /// `SHA-256 (recommended)` for the default, the bare name for the interop three.
    ///
    /// The digest names themselves are never localized — `SHA-256` is technical vocabulary in the
    /// same class as `SFTP`, and a translated one would stop matching what every other tool prints.
    /// Only the parenthetical is.
    private static func title(for algorithm: ChecksumAlgorithm) -> String {
        guard !algorithm.isInteropOnly else { return algorithm.displayName }
        return String(
            localized: "\(algorithm.displayName) (recommended)",
            comment: "Algorithm popup item for the default digest; %@ is its name, e.g. SHA-256."
        )
    }

    /// Re-suffix the typed name for the newly chosen algorithm, so the extension always matches the
    /// digests inside. A name the user has re-typed keeps its stem; only the extension moves.
    @objc private func algorithmChanged(_ sender: NSPopUpButton) {
        nameField.stringValue = manifestFileName
    }
}
