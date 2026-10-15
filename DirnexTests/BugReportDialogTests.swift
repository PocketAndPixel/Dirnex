import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Answers every request of a session built with it, and records what it was asked. The app's tests
/// reach no network: what leaves the Mac is checked live against `Tooling/fake-bug-report-endpoint.py`.
final class BugReportStubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 201
        var body = Data(#"{"id":"STUB-1"}"#.utf8)
        var error: URLError.Code?
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var reply = Reply()
    private nonisolated(unsafe) static var requests: [(URLRequest, Data)] = []

    static func reset(_ reply: Reply = Reply()) {
        lock.withLock {
            self.reply = reply
            requests = []
        }
    }

    static var received: [(request: URLRequest, body: Data)] {
        lock.withLock { requests.map { (request: $0.0, body: $0.1) } }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BugReportStubProtocol.self]
        return BugReportSender.makeSession(configuration: configuration)
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // A body set on the request arrives here as a stream.
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let reply = Self.lock.withLock {
            Self.requests.append((request, body))
            return Self.reply
        }
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: URLError(error))
            return
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"),
            statusCode: reply.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )
        if let response {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The Report a Bug dialog (PLAN.md §M30): what each box sends, that Send sends what the preview
/// showed, the keys, and what is left when the server can't be reached.
@Suite("Bug report dialog", .serialized)
@MainActor
struct BugReportDialogTests {
    static let endpoint = URL(string: "https://dirnex.app/api/bug-reports")!
    static let system = BugReportSystemInfo(
        appVersion: "1.4.0",
        appBuild: "512",
        macOS: "26.0.1 (25A362)",
        macModel: "Mac16,5",
        language: "de"
    )

    private struct Dialog {
        let controller: BugReportController
        let window: NSWindow
    }

    private func dialog(
        form: BugReportForm = BugReportForm(),
        licensed: Bool? = true,
        crashReport: CrashReportFile? = nil
    ) -> Dialog {
        let context = BugReportController.Context(
            endpoint: Self.endpoint,
            system: Self.system,
            licensed: licensed,
            crashReport: crashReport,
            redaction: BugReportRedaction(homePath: "/Users/jane")
        )
        let controller = BugReportController(
            form: form,
            context: context,
            sender: BugReportSender(session: BugReportStubProtocol.session())
        )
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        return Dialog(controller: controller, window: window)
    }

    private func type(_ text: String, into view: BugReportTextView) {
        view.string = text
        view.didChangeText()
    }

    private func keys(of body: Data) throws -> Set<String> {
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        return Set(object.keys)
    }

    private func key(
        _ characters: String,
        code: UInt16,
        _ modifiers: NSEvent.ModifierFlags = [],
        in window: NSWindow
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: code
        ))
    }

    // MARK: - What goes in

    @Test("Send waits for a description, and each box's title shows what it sends")
    func opening() {
        let dialog = dialog()
        let controller = dialog.controller
        #expect(!controller.sendButton.isEnabled)
        #expect(controller.versionBox.title.contains("1.4.0 (512)"))
        #expect(controller.macOSBox.title.contains("26.0.1 (25A362)"))
        #expect(controller.modelBox.title.contains("Mac16,5"))
        #expect(controller.crashBox.state == .off)
        #expect(!controller.crashBox.isEnabled)
        type("The pane froze.", into: controller.descriptionView)
        #expect(controller.sendButton.isEnabled)
        #expect(controller.statusLabel.stringValue.isEmpty)
    }

    @Test("an unticked box leaves its field out of the body, and a ticked one puts it in")
    func boxes() throws {
        let controller = dialog().controller
        type("The pane froze.", into: controller.descriptionView)
        #expect(try keys(of: controller.body()) == [
            "v", "description", "appVersion", "appBuild", "macOS", "macModel", "language",
            "licensed"
        ])
        let boxes = [
            controller.versionBox,
            controller.macOSBox,
            controller.modelBox,
            controller.languageBox,
            controller.licenseBox
        ]
        for box in boxes {
            box.performClick(nil)
        }
        #expect(try keys(of: controller.body()) == ["v", "description"])
    }

    @Test("a build that shows nothing about licenses offers no license box and sends no such field")
    func noLicensing() throws {
        let controller = dialog(licensed: nil).controller
        type("The pane froze.", into: controller.descriptionView)
        #expect(controller.licenseBox.isHidden)
        #expect(try !keys(of: controller.body()).contains("licensed"))
    }

    @Test("the home folder becomes ~ in what is typed")
    func redaction() throws {
        let controller = dialog().controller
        type("Copying /Users/jane/Movies fails.", into: controller.descriptionView)
        let body = try #require(String(bytes: controller.body(), encoding: .utf8))
        #expect(body.contains("Copying ~/Movies fails."))
        #expect(!body.contains("/Users/jane"))
    }

    @Test("an incomplete email holds Send back and says why")
    func invalidEmail() {
        let controller = dialog().controller
        type("The pane froze.", into: controller.descriptionView)
        controller.emailField.stringValue = "jane@"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(!controller.sendButton.isEnabled)
        #expect(
            controller.statusLabel.stringValue == BugReportController.message(for: .invalidEmail)
        )
        controller.emailField.stringValue = "jane@example.com"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(controller.sendButton.isEnabled)
        #expect(controller.statusLabel.stringValue.isEmpty)
    }

    // MARK: - Sending

    @Test("Send sends exactly the bytes the preview shows, with headers that name nothing")
    func sendsWhatThePreviewShows() async throws {
        BugReportStubProtocol.reset()
        let controller = dialog().controller
        type("The pane froze.", into: controller.descriptionView)
        controller.languageBox.performClick(nil)
        let preview = BugReportPreviewController(body: try controller.body())

        controller.send(nil)
        #expect(!controller.sendButton.isEnabled)
        await controller.sending?.value

        let received = try #require(BugReportStubProtocol.received.first)
        #expect(BugReportStubProtocol.received.count == 1)
        #expect(String(bytes: received.body, encoding: .utf8) == preview.text)
        #expect(received.request.httpMethod == "POST")
        #expect(received.request.url == Self.endpoint)
        #expect(received.request.value(forHTTPHeaderField: "User-Agent") == "Dirnex")
        #expect(controller.lastOutcome == .sent(reference: "STUB-1"))
    }

    @Test("each failure keeps the report and says what to do", arguments: [
        BugReportStubProtocol.Reply(status: 500, body: Data()),
        BugReportStubProtocol.Reply(status: 429, body: Data(#"{"error":"rateLimited"}"#.utf8)),
        BugReportStubProtocol.Reply(status: 400, body: Data(#"{"error":"malformed"}"#.utf8)),
        BugReportStubProtocol.Reply(error: .notConnectedToInternet),
        BugReportStubProtocol.Reply(error: .timedOut)
    ])
    func failure(reply: BugReportStubProtocol.Reply) async throws {
        BugReportStubProtocol.reset(reply)
        let controller = dialog().controller
        type("The pane froze.", into: controller.descriptionView)
        controller.send(nil)
        await controller.sending?.value

        let outcome = try #require(controller.lastOutcome)
        #expect(!outcome.isSent)
        #expect(controller.statusLabel.stringValue == BugReportController.message(for: outcome))
        #expect(controller.statusLabel.textColor == .systemRed)
        #expect(controller.descriptionView.string == "The pane froze.")
        #expect(controller.sendButton.isEnabled)
        #expect(controller.copyButton.isEnabled)
        #expect(controller.emailButton.isEnabled)

        // A problem with the form takes the line while it lasts, and the failure comes back after.
        controller.emailField.stringValue = "jane@"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(
            controller.statusLabel.stringValue == BugReportController.message(for: .invalidEmail)
        )
        controller.emailField.stringValue = ""
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(controller.statusLabel.stringValue == BugReportController.message(for: outcome))
    }

    @Test("the preview shows the body to select and copy, and can't be typed in")
    func previewIsReadOnly() throws {
        let controller = dialog().controller
        type("The pane froze.", into: controller.descriptionView)
        let preview = BugReportPreviewController(body: try controller.body())
        preview.loadView()
        #expect(preview.textView.string == preview.text)
        #expect(!preview.textView.isEditable)
        #expect(preview.textView.isSelectable)
        let box = try #require(preview.textView.enclosingScrollView?.superview as? MultiLineField)
        #expect(!box.isEditable)
    }

    @Test("Copy Report puts the exact body on the clipboard")
    func copyReport() throws {
        let controller = dialog().controller
        type("The pane froze.", into: controller.descriptionView)
        let saved = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }
        controller.copyReport(nil)
        #expect(
            NSPasteboard.general.string(forType: .string) == String(
                bytes: try controller.body(),
                encoding: .utf8
            )
        )
        #expect(controller.statusLabel.stringValue == BugReportController.copiedMessage)
    }

    // MARK: - The keyboard

    @Test("Return starts a new line in the description, and ⌘Return sends")
    func returnAndCommandReturn() async throws {
        BugReportStubProtocol.reset()
        let dialog = dialog()
        let controller = dialog.controller
        type("The pane froze.", into: controller.descriptionView)
        #expect(controller.sendButton.keyEquivalent == "\r")
        #expect(controller.sendButton.keyEquivalentModifierMask == .command)
        dialog.window.makeFirstResponder(controller.descriptionView)
        controller.descriptionView.setSelectedRange(NSRange(location: 15, length: 0))

        // The order `NSApplication.sendEvent` uses for a key window: key equivalents, then the window.
        let plain = try key("\r", code: 36, in: dialog.window)
        if !dialog.window.performKeyEquivalent(with: plain) {
            dialog.window.sendEvent(plain)
        }
        #expect(controller.sending == nil)
        #expect(controller.descriptionView.string == "The pane froze.\n")

        let command = try key("\r", code: 36, .command, in: dialog.window)
        #expect(dialog.window.performKeyEquivalent(with: command))
        #expect(controller.sending != nil)
        await controller.sending?.value
        #expect(BugReportStubProtocol.received.count == 1)
    }

    @Test("Escape is Cancel's, and Tab leaves the description instead of typing a tab")
    func escapeAndTab() throws {
        let dialog = dialog()
        let controller = dialog.controller
        #expect(controller.cancelButton.keyEquivalent == "\u{1b}")
        dialog.window.orderFront(nil)
        defer { dialog.window.close() }
        #expect(dialog.window.firstResponder === controller.descriptionView)
        controller.descriptionView.insertTab(nil)
        #expect(dialog.window.firstResponder === controller.stepsView)
        #expect(controller.descriptionView.string.isEmpty)
        controller.stepsView.insertBacktab(nil)
        #expect(dialog.window.firstResponder === controller.descriptionView)
    }

    // MARK: - Keeping it

    @Test("the reply email is remembered when a report is sent with one, and forgotten when without")
    func rememberedEmail() {
        let defaults = ScratchDefaults.fresh()
        BugReportPresenter.remember(email: "jane@example.com", in: defaults)
        #expect(defaults.string(forKey: AppPreferences.Keys.bugReportEmail) == "jane@example.com")
        BugReportPresenter.remember(email: nil, in: defaults)
        #expect(defaults.string(forKey: AppPreferences.Keys.bugReportEmail) == nil)
    }
}
