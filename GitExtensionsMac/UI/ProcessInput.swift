import AppKit
import GitCommands

struct ProcessDialogPreferences: Codable, Equatable, Sendable {
    var showPasswordInput = false

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        showPasswordInput = try values.decodeIfPresent(Bool.self, forKey: .showPasswordInput) ?? false
    }
}

@MainActor
final class ProcessInputController: NSObject, NSTextFieldDelegate {
    static let toggleTitle = "Show password input"
    static let sendTitle = "Send input"
    static let revealToolTip = "Show or hide the input"

    let toggle = NSButton(checkboxWithTitle: ProcessInputController.toggleTitle, target: nil, action: nil)
    let inputRow = NSStackView()
    let secureField = NSSecureTextField()
    let plainField = NSTextField()
    let revealButton = NSButton()
    let sendButton = NSButton(title: ProcessInputController.sendTitle, target: nil, action: nil)
    weak var window: NSWindow?
    private(set) var session: GitInteractiveSession!
    private let store: AppSettingsStore
    private var pendingPrompt: (alert: NSAlert, sheet: NSWindow)?
    private var isFinished = false
    private var revealedForPrompt = false

    init(store: AppSettingsStore? = nil) {
        self.store = store ?? .shared
        super.init()
        session = GitInteractiveSession { [weak self] prompt in
            await self?.present(prompt)
        }
        toggle.target = self
        toggle.action = #selector(toggleChanged)
        toggle.setAccessibilityIdentifier("ProcessInput.toggle")
        toggle.state = self.store.processDialogPreferences.showPasswordInput ? .on : .off
        for field in [secureField as NSTextField, plainField] {
            field.placeholderString = "Input for the running process"
            field.target = self
            field.action = #selector(sendInput)
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        secureField.setAccessibilityIdentifier("ProcessInput.secureField")
        plainField.setAccessibilityIdentifier("ProcessInput.plainField")
        plainField.isHidden = true
        revealButton.bezelStyle = .texturedRounded
        revealButton.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: Self.revealToolTip)
        revealButton.toolTip = Self.revealToolTip
        revealButton.target = self
        revealButton.action = #selector(toggleReveal)
        sendButton.target = self
        sendButton.action = #selector(sendInput)
        sendButton.setAccessibilityIdentifier("ProcessInput.send")
        inputRow.orientation = .horizontal
        inputRow.alignment = .centerY
        inputRow.spacing = 6
        inputRow.setViews([secureField, plainField, revealButton, sendButton], in: .leading)
        inputRow.setAccessibilityIdentifier("ProcessInput.row")
        inputRow.isHidden = toggle.state == .off
    }

    var inputText: String {
        get { secureField.isHidden ? plainField.stringValue : secureField.stringValue }
        set { secureField.stringValue = newValue; plainField.stringValue = newValue }
    }

    func bottomStack(footer: NSView) -> NSStackView {
        let stack = NSStackView(views: [inputRow, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.detachesHiddenViews = true
        inputRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    func perform<T>(_ operation: () async throws -> T) async rethrows -> T {
        try await session.bind(operation)
    }

    func observeOutput(_ text: String) {
        guard !isFinished, !text.isEmpty, !text.hasSuffix("\n"), !text.hasSuffix("\r"), toggle.state == .off else { return }
        revealedForPrompt = true
        toggle.allowsMixedState = true
        toggle.state = .mixed
        inputRow.isHidden = false
        activeField.window?.makeFirstResponder(activeField)
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        toggle.isHidden = true
        inputRow.isHidden = true
        inputText = ""
        if let pending = pendingPrompt {
            pending.sheet.sheetParent?.endSheet(pending.sheet, returnCode: .alertSecondButtonReturn)
        }
        session.close()
    }

    private var activeField: NSTextField { secureField.isHidden ? plainField : secureField }

    @objc private func toggleChanged() {
        if revealedForPrompt {
            revealedForPrompt = false
            toggle.state = .off
        }
        toggle.allowsMixedState = false
        var preferences = store.processDialogPreferences
        preferences.showPasswordInput = toggle.state == .on
        store.saveProcessDialogPreferences(preferences)
        inputRow.isHidden = toggle.state == .off
    }

    @objc func sendInput() {
        let text = inputText
        inputText = ""
        if !session.send(text) { NSSound.beep() }
        activeField.window?.makeFirstResponder(activeField)
    }

    @objc private func toggleReveal() {
        let text = inputText
        let reveal = !secureField.isHidden
        secureField.isHidden = reveal
        plainField.isHidden = !reveal
        inputText = text
        revealButton.image = NSImage(systemSymbolName: reveal ? "eye" : "eye.slash", accessibilityDescription: Self.revealToolTip)
        activeField.window?.makeFirstResponder(activeField)
    }

    private func present(_ prompt: GitCredentialPrompt) async -> String? {
        guard !isFinished, let window, pendingPrompt == nil else { return nil }
        let alert = NSAlert()
        alert.messageText = prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = "The running Git operation is waiting for this input."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field: NSTextField = prompt.isSecret ? NSSecureTextField() : NSTextField()
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        field.setAccessibilityIdentifier("ProcessInput.prompt")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        pendingPrompt = (alert, alert.window)
        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        pendingPrompt = nil
        let value = field.stringValue
        field.stringValue = ""
        return response == .alertFirstButtonReturn && !isFinished ? value : nil
    }
}
