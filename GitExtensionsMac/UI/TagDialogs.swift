import GitExtensionsCore
import GitCommands
import AppKit

struct CreateTagDialogValue {
    var name = ""
    var target = ""
    var operation: RepositoryTagOperation = .lightweight
    var message = ""
    var signingKey = ""
    var force = false
    var pushToRemote = false
}

struct DeleteTagDialogValue {
    var name: String
    var deleteFromRemote = false
    var remote: String
}

@MainActor
enum TagDialogs {
    static func createTag(
        initial: CreateTagDialogValue,
        revisions: [Commit],
        remote: String?,
        window: NSWindow
    ) async -> CreateTagDialogValue? {
        let alert = NSAlert()
        alert.messageText = "Create tag"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let name = NSTextField(string: initial.name)
        name.placeholderString = "Tag name"
        name.widthAnchor.constraint(equalToConstant: 330).isActive = true

        let target = NSComboBox()
        target.isEditable = true
        target.completes = true
        target.addItems(withObjectValues: revisionTargetValues(revisions))
        target.stringValue = initial.target
        target.placeholderString = "Commit ID or revision"
        target.widthAnchor.constraint(equalToConstant: 330).isActive = true

        let operation = NSPopUpButton()
        operation.addItems(withTitles: [
            "Lightweight tag",
            "Annotated tag",
            "Sign with default GPG",
            "Sign with specific GPG"
        ])
        operation.selectItem(at: initial.operation.rawValue)

        let signingKey = NSTextField(string: initial.signingKey)
        signingKey.placeholderString = "Key ID"
        signingKey.maximumNumberOfLines = 1
        signingKey.formatter = TagSigningKeyFormatter(maximumLength: 16)
        signingKey.widthAnchor.constraint(equalToConstant: 160).isActive = true

        let message = NSTextView(frame: NSRect(x: 0, y: 0, width: 330, height: 92))
        message.font = .systemFont(ofSize: 12)
        message.isRichText = false
        message.isAutomaticQuoteSubstitutionEnabled = false
        message.isAutomaticDashSubstitutionEnabled = false
        message.string = initial.message
        let messageScroll = NSScrollView()
        messageScroll.documentView = message
        messageScroll.hasVerticalScroller = true
        messageScroll.borderType = .bezelBorder
        messageScroll.widthAnchor.constraint(equalToConstant: 330).isActive = true
        messageScroll.heightAnchor.constraint(equalToConstant: 92).isActive = true

        let force = NSButton(checkboxWithTitle: "Force", target: nil, action: nil)
        force.state = initial.force ? .on : .off
        let push = NSButton(
            checkboxWithTitle: remote.map { "Push tag to ‘\($0)’" } ?? "Push tag",
            target: nil,
            action: nil
        )
        push.state = initial.pushToRemote ? .on : .off
        push.isEnabled = remote != nil

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.addArrangedSubview(row("Tag name:", name))
        stack.addArrangedSubview(row("Tag revision:", target))
        stack.addArrangedSubview(force)
        stack.addArrangedSubview(push)
        stack.addArrangedSubview(row("Type:", operation))
        stack.addArrangedSubview(row("Specific Key ID:", signingKey))
        stack.addArrangedSubview(label("Message:"))
        stack.addArrangedSubview(messageScroll)

        let accessory = enclosing(stack, minimumWidth: 455)
        alert.accessoryView = accessory
        let coordinator = TagOperationControlCoordinator(
            operation: operation,
            signingKey: signingKey,
            message: message,
            messageScroll: messageScroll
        )
        coordinator.update()
        alert.window.initialFirstResponder = name

        let response = await begin(alert, window: window)
        withExtendedLifetime(coordinator) {}
        guard response == .alertFirstButtonReturn else { return nil }
        return CreateTagDialogValue(
            name: name.stringValue,
            target: target.stringValue,
            operation: RepositoryTagOperation(rawValue: operation.indexOfSelectedItem) ?? .lightweight,
            message: message.string,
            signingKey: signingKey.stringValue,
            force: force.state == .on,
            pushToRemote: push.state == .on
        )
    }

    static func deleteTag(
        initial: DeleteTagDialogValue,
        tags: [Tag],
        remotes: [Remote],
        window: NSWindow
    ) async -> DeleteTagDialogValue? {
        let alert = NSAlert()
        alert.messageText = "Delete tag"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        let names = tags.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let tag = NSComboBox()
        tag.isEditable = true
        tag.completes = true
        tag.addItems(withObjectValues: names)
        tag.stringValue = initial.name
        tag.widthAnchor.constraint(equalToConstant: 295).isActive = true

        let deleteRemote = NSButton(
            checkboxWithTitle: "Delete tag also from the following remote:",
            target: nil,
            action: nil
        )
        deleteRemote.state = initial.deleteFromRemote ? .on : .off
        deleteRemote.isEnabled = !remotes.isEmpty
        let remote = NSPopUpButton()
        remote.addItems(withTitles: remotes.map(\.name))
        remote.selectItem(withTitle: initial.remote)
        if remote.indexOfSelectedItem < 0 { remote.selectItem(at: 0) }
        remote.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let coordinator = DeleteTagRemoteControlCoordinator(toggle: deleteRemote, remote: remote)
        coordinator.update()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.addArrangedSubview(row("Tag:", tag))
        stack.addArrangedSubview(deleteRemote)
        stack.addArrangedSubview(row("Remote:", remote))
        alert.accessoryView = enclosing(stack, minimumWidth: 420)
        alert.window.initialFirstResponder = tag

        let response = await begin(alert, window: window)
        withExtendedLifetime(coordinator) {}
        guard response == .alertFirstButtonReturn else { return nil }
        return DeleteTagDialogValue(
            name: tag.stringValue,
            deleteFromRemote: deleteRemote.state == .on,
            remote: remote.titleOfSelectedItem ?? ""
        )
    }

    static func showError(_ error: Error, title: String, window: NSWindow) async {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        _ = await begin(alert, window: window)
    }

    private static func revisionTargetValues(_ revisions: [Commit]) -> [String] {
        var seen = Set<ObjectID>()
        return revisions.compactMap { commit in
            guard let id = commit.objectID, seen.insert(id).inserted else { return nil }
            return id.string
        }
    }

    private static func row(_ title: String, _ control: NSView) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        let caption = NSTextField(labelWithString: title)
        caption.alignment = .right
        caption.widthAnchor.constraint(equalToConstant: 110).isActive = true
        row.addArrangedSubview(caption)
        row.addArrangedSubview(control)
        return row
    }

    private static func label(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: 12)
        return label
    }

    private static func enclosing(_ stack: NSStackView, minimumWidth: CGFloat) -> NSView {
        stack.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: minimumWidth)
        ])
        return view
    }

    private static func begin(_ alert: NSAlert, window: NSWindow) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }
}

@MainActor
private final class TagOperationControlCoordinator: NSObject {
    private let operation: NSPopUpButton
    private let signingKey: NSTextField
    private let message: NSTextView
    private let messageScroll: NSScrollView

    init(operation: NSPopUpButton, signingKey: NSTextField, message: NSTextView, messageScroll: NSScrollView) {
        self.operation = operation
        self.signingKey = signingKey
        self.message = message
        self.messageScroll = messageScroll
        super.init()
        operation.target = self
        operation.action = #selector(update)
    }

    @objc func update() {
        let selected = RepositoryTagOperation(rawValue: operation.indexOfSelectedItem) ?? .lightweight
        let canMessage = selected.providesMessage
        message.isEditable = canMessage
        message.textColor = canMessage ? .textColor : .disabledControlTextColor
        messageScroll.borderType = canMessage ? .bezelBorder : .noBorder
        let specific = selected == .signWithSpecificKey
        signingKey.isEnabled = specific
    }
}

@MainActor
private final class DeleteTagRemoteControlCoordinator: NSObject {
    private let toggle: NSButton
    private let remote: NSPopUpButton

    init(toggle: NSButton, remote: NSPopUpButton) {
        self.toggle = toggle
        self.remote = remote
        super.init()
        toggle.target = self
        toggle.action = #selector(update)
    }

    @objc func update() {
        remote.isEnabled = toggle.state == .on && remote.numberOfItems > 0
    }
}

private final class TagSigningKeyFormatter: Formatter {
    private let maximumLength: Int

    init(maximumLength: Int) {
        self.maximumLength = maximumLength
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    override func string(for obj: Any?) -> String? { obj as? String }

    override func getObjectValue(
        _ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?,
        for string: String,
        errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
        obj?.pointee = string as NSString
        return string.count <= maximumLength
    }

    override func isPartialStringValid(
        _ partialString: String,
        newEditingString newString: AutoreleasingUnsafeMutablePointer<NSString?>?,
        errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
        partialString.count <= maximumLength
    }
}
