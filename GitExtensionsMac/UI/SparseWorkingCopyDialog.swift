import GitExtensionsCore
import GitCommands
import AppKit


@MainActor
final class SparseWorkingCopyWindowController: NSWindowController, NSWindowDelegate {
    enum Strings {
        static let title = "Sparse Working Copy"
        static let headerDetails = "Need only a small part of a large repository?\nWith sparse checkout, you can skip the rest from being extracted into your working copy."
        static let notEnabled = "Git Sparse feature has not been enabled for this repository."
        static let enable = "Enable"
        static let isEnabled = "Git Sparse feature is currently enabled."
        static let disable = "Disable for this repository"
        static let rulesLine1 = "Specify the pass-filter rules for files and directories:"
        static let rulesLine2 = "The rules have the same format as the “.gitignore” file, matched items are included. To exclude, prefix a rule with an exclamation mark “!”.\n“#” comments a line. This is only a filter, so it cannot change the structure like pulling up a deep subfolder to the first level."
        static let refreshOnSave = "Refresh working copy using the current settings and rules"
        static let refreshHint = "As the sparse working copy rules are changed, it might become outdated.\nRefreshes the working copy against the current set of the rules to restore any missing files and remove any extra files.\n\nnActual command line: \(SparseWorkingCopyCommands.refreshCommandLine)"
        static let enableHint = "Sets the Git property “\(SparseWorkingCopyCommands.settingName)” to True for the local repository."
        static let disableHint = "Sets the Git property “\(SparseWorkingCopyCommands.settingName)” to False for the local repository."
        static let editorHint = "Edits the contents of the “.git/info/sparse-checkout” file."
        static let unsaved = "You have made changes to settings or rules.\nWould you like to save them?"
        static let couldNotSave = "Could not save the modified settings and rules."
        static let cannotLoad = "Cannot load the text of the sparse file."
        static let disableCaption = "Disable Git Sparse"
        static func confirmDisable(isCurrentRuleSetEmpty: Bool) -> String {
            let state = isCurrentRuleSetEmpty ? "with the sparse pass-filter empty or missing" : "with some rules still in the sparse pass-filter"
            return "You are about to disable Git Sparse feature for this repository, \(state).\nGit won't be able to restore the working copy to its full content this way.\n\nWould you like to have the filter modified so that it allowed for the full working copy?"
        }
    }

    typealias Source = any RepositorySparseWorkingCopyDataSource & RepositoryFileEditingDataSource

    private let source: Source
    private let processTitle: String
    private let onSaved: () -> Void
    private let onClose: () -> Void
    let editor = EditableFileTextView()
    let refreshCheckbox = NSButton(checkboxWithTitle: Strings.refreshOnSave, target: nil, action: nil)
    private var disabledViews: [NSView] = []
    private var enabledViews: [NSView] = []
    private var closing = false


    private(set) var isSparseCheckoutEnabled = false { didSet { updateVisibility() } }
    private(set) var isSparseCheckoutEnabledAsSaved = false

    private(set) var rulesText: String?
    private var rulesTextAsOnDisk: String?
    private(set) var fileURL: URL?
    var isRefreshWorkingCopyOnSave: Bool { refreshCheckbox.state == .on }

    var isRulesTextChanged: Bool { rulesText.map { $0 != (rulesTextAsOnDisk ?? "") } ?? false }
    var hasUnsavedChanges: Bool { isSparseCheckoutEnabled != isSparseCheckoutEnabledAsSaved || isRulesTextChanged }

    init(source: Source, processTitle: String, onSaved: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.source = source
        self.processTitle = processTitle
        self.onSaved = onSaved
        self.onClose = onClose
        let window = RepositoryFileEditorWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                                backing: .buffered, defer: false)
        window.title = Strings.title
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 800, height: 572)
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
        window.initialFirstResponder = editor.textView
        editor.onTextChanged = { [weak self] in self?.setRulesText(self?.editor.text ?? "") }
        editor.textView.onEscape = { [weak self] in self?.cancel(); return true }

        window.onCommandReturn = { [weak self] in self?.saveAndClose() }
        refreshCheckbox.state = .on
        updateVisibility()
    }

    required init?(coder: NSCoder) { nil }


    func load() async {
        isSparseCheckoutEnabled = (try? await source.isSparseCheckoutEnabled()) ?? false
        isSparseCheckoutEnabledAsSaved = isSparseCheckoutEnabled
        do {
            let url = try await source.sparseCheckoutFileURL()
            fileURL = url
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let loaded = try await source.loadEditableFile(at: url)
            editor.text = loaded.text

            rulesTextAsOnDisk = loaded.text
            rulesText = loaded.text
        } catch {
            if let window {
                await RepositoryFileEditorDialogs.message("\(Strings.cannotLoad)\n\n\(error.localizedDescription)",
                                                          caption: "\(Strings.title) – Load File", window: window)
            }
        }
    }

    func setRulesText(_ text: String) { rulesText = text }
    func setSparseCheckoutEnabled(_ enabled: Bool) { isSparseCheckoutEnabled = enabled }



    private func makeContent() -> NSView {
        let root = NSView()
        let header = NSStackView()
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        let title = NSTextField(labelWithString: Strings.title)
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let details = NSTextField(wrappingLabelWithString: Strings.headerDetails)
        let detailsRow = NSStackView(views: [details])
        detailsRow.edgeInsets = NSEdgeInsets(top: 0, left: 15, bottom: 0, right: 0)
        header.addArrangedSubview(title)
        header.addArrangedSubview(detailsRow)
        let headerBox = Self.backgroundBox(header, color: .textBackgroundColor)


        let notEnabled = NSTextField(wrappingLabelWithString: Strings.notEnabled)
        notEnabled.textColor = ApplicationColors.color("InfoText", fallback: .black)
        let enableButton = Self.button(Strings.enable) { [weak self] in self?.setSparseCheckoutEnabled(true) }
        enableButton.toolTip = Strings.enableHint
        enableButton.setAccessibilityIdentifier("Sparse.Enable")
        let disabledRow = NSStackView(views: [notEnabled, enableButton])
        disabledRow.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        notEnabled.setContentHuggingPriority(.init(1), for: .horizontal)
        let disabledPanel = Self.backgroundBox(disabledRow, color: ApplicationColors.color("Info", fallback: NSColor(calibratedRed: 1, green: 1, blue: 0.88, alpha: 1)))

        disabledPanel.appearance = NSAppearance(named: .aqua)
        let disabledSeparator = Self.separator()


        let enabledLabel = NSTextField(labelWithString: Strings.isEnabled + " ")
        let disableLink = Self.button(Strings.disable) { [weak self] in self?.setSparseCheckoutEnabled(false) }
        disableLink.isBordered = false
        disableLink.attributedTitle = NSAttributedString(string: Strings.disable, attributes: [
            .foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        disableLink.setAccessibilityIdentifier("Sparse.Disable")
        let enabledRow = NSStackView(views: [enabledLabel, disableLink])
        enabledRow.spacing = 0
        enabledRow.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 5, right: 10)
        enabledRow.toolTip = Strings.disableHint
        disableLink.toolTip = Strings.disableHint


        let line1 = NSTextField(wrappingLabelWithString: Strings.rulesLine1)
        let line1Row = NSStackView(views: [line1])
        line1Row.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 0, right: 10)
        let line2 = NSTextField(wrappingLabelWithString: Strings.rulesLine2)
        line2.textColor = .secondaryLabelColor
        let line2Row = NSStackView(views: [line2])
        line2Row.edgeInsets = NSEdgeInsets(top: 3, left: 25, bottom: 3, right: 10)
        let rulesSeparator = Self.separator()
        editor.toolTip = Strings.editorHint
        editor.textView.toolTip = Strings.editorHint


        refreshCheckbox.toolTip = Strings.refreshHint
        let save = Self.button("Save") { [weak self] in self?.saveAndClose() }
        save.setAccessibilityIdentifier("Sparse.Save")
        let cancel = Self.button("Cancel") { [weak self] in self?.cancel() }
        cancel.keyEquivalent = "\u{1b}"
        cancel.setAccessibilityIdentifier("Sparse.Cancel")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footerRow = NSStackView(views: [refreshCheckbox, spacer, save, cancel])
        footerRow.spacing = 10
        footerRow.edgeInsets = NSEdgeInsets(top: 15, left: 10, bottom: 15, right: 10)
        let footer = Self.backgroundBox(footerRow, color: .textBackgroundColor)

        let stack = NSStackView(views: [headerBox, Self.separator(), disabledPanel, disabledSeparator, enabledRow,
                                        line1Row, line2Row, rulesSeparator, editor, Self.separator(), footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        for label in [details, notEnabled, line1, line2] { label.preferredMaxLayoutWidth = 740 }
        editor.setContentHuggingPriority(.init(1), for: .vertical)
        editor.setContentCompressionResistancePriority(.init(1), for: .vertical)
        editor.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        disabledViews = [disabledPanel, disabledSeparator]
        enabledViews = [enabledRow, line1Row, line2Row, rulesSeparator, editor]

        let filler = NSView()
        filler.setContentHuggingPriority(.init(1), for: .vertical)
        stack.insertArrangedSubview(filler, at: stack.arrangedSubviews.count - 2)
        filler.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        fillerView = filler
        return root
    }

    private var fillerView: NSView?


    private func updateVisibility() {
        disabledViews.forEach { $0.isHidden = isSparseCheckoutEnabled }
        enabledViews.forEach { $0.isHidden = !isSparseCheckoutEnabled }
        fillerView?.isHidden = isSparseCheckoutEnabled
    }

    private static func separator() -> NSView {
        let view = NSBox()
        view.boxType = .separator
        return view
    }

    private static func backgroundBox(_ content: NSView, color: NSColor) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 0
        box.cornerRadius = 0
        box.fillColor = color
        box.contentViewMargins = .zero
        content.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(content)
        if let container = box.contentView {
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: container.topAnchor),
                content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                content.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
        }
        return box
    }

    private static func button(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        let button = SparseActionButton(title: title, target: nil, action: #selector(SparseActionButton.invoke))
        button.target = button
        button.callback = action
        button.bezelStyle = .rounded
        return button
    }




    func saveAndClose() {
        Task { @MainActor [weak self] in
            guard let self, let window else { return }
            await saveReportingErrors(window: window)
            closing = true
            window.close()
        }
    }


    func cancel() { window?.performClose(nil) }

    private func saveReportingErrors(window: NSWindow) async {
        do { try await saveChanges(window: window) } catch {
            await RepositoryFileEditorDialogs.message("\(Strings.couldNotSave)\n\n\(error.localizedDescription)",
                                                      caption: "\(Strings.title) – Save File", window: window)
        }
    }


    func saveChanges(window: NSWindow) async throws {
        if !isSparseCheckoutEnabled, isSparseCheckoutEnabledAsSaved, let rules = rulesText,
           let adjustment = SparseWorkingCopyRules.adjustmentNeeded(rules) {
            let alert = NSAlert()
            alert.messageText = Strings.disableCaption
            alert.informativeText = Strings.confirmDisable(isCurrentRuleSetEmpty: adjustment.isCurrentRuleSetEmpty)
            alert.addButton(withTitle: "Yes")
            alert.addButton(withTitle: "No")
            if await alert.beginSheetModal(for: window) == .alertFirstButtonReturn {
                rulesText = SparseWorkingCopyRules.adjustedForDisabling(rules)
            }
        }
        if isSparseCheckoutEnabled != isSparseCheckoutEnabledAsSaved {
            try await source.setSparseCheckoutEnabled(isSparseCheckoutEnabled)
            isSparseCheckoutEnabledAsSaved = isSparseCheckoutEnabled
        }
        if isRulesTextChanged {
            let text = rulesText ?? ""
            let url: URL
            if let fileURL { url = fileURL } else { url = try await source.sparseCheckoutFileURL() }

            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

            try Data(text.utf8).write(to: url)
            rulesTextAsOnDisk = text
        }
        if isRefreshWorkingCopyOnSave {

            let source = self.source
            _ = await HostingProcessDialog.run(processTitle, window) { output in
                let result = try await source.refreshSparseWorkingCopy(output: output)
                guard result.succeeded else {
                    throw GitError.commandFailed(arguments: result.arguments, status: result.exitStatus, stderr: result.standardErrorString)
                }
                return true
            }
        }
        onSaved()
    }



    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closing || !hasUnsavedChanges { return true }
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch await RepositoryFileEditorDialogs.yesNoCancel(Strings.unsaved, caption: "\(Strings.title) – Cancel", window: sender) {
            case .yes: await saveReportingErrors(window: sender)
            case .no: break
            case .cancel: return
            }
            closing = true
            sender.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) { onClose() }
}

private final class SparseActionButton: NSButton {
    var callback: (() -> Void)?
    @objc func invoke() { callback?() }
}
