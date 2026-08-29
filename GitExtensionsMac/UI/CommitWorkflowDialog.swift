import GitExtensionsCore
import GitCommands
import AppKit

private enum CommitKeyboardShortcut {
    case unstaged
    case diff
    case staged
    case message
    case stageAll
    case filter
    case refresh
    case createBranch
    case nextFile
    case previousFile
    case addSelectionToMessage
    case conventionalType
    case conventionalScope
}

enum CommitWorkflowSpecialKind {
    case fixup(Commit)
    case squash(Commit)
    case amendAutosquash(Commit)

    var message: String {
        switch self {
        case .fixup(let commit):
            prefixed("fixup!", subject: commit.subject)
        case .squash(let commit):
            prefixed("squash!", subject: commit.subject)
        case .amendAutosquash(let commit):
            prefixed("amend!", subject: commit.subject) + (commit.body.isEmpty ? "" : "\n\n\(commit.body)")
        }
    }

    private func prefixed(_ prefix: String, subject: String) -> String {
        subject.hasPrefix(prefix) ? subject : "\(prefix) \(subject)"
    }
}

@MainActor
private final class CommitRootView: NSView {
    var onShortcut: ((CommitKeyboardShortcut) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let shortcut: CommitKeyboardShortcut?
        if modifiers.contains(.command) {
            switch (key, modifiers.contains(.shift)) {
            case ("1", _): shortcut = .unstaged
            case ("2", _): shortcut = .diff
            case ("3", _): shortcut = .staged
            case ("4", _): shortcut = .message
            case ("s", _): shortcut = .stageAll
            case ("f", false): shortcut = .filter
            case ("r", false): shortcut = .refresh
            case ("b", false): shortcut = .createBranch
            case ("n", false): shortcut = .nextFile
            case ("p", false): shortcut = .previousFile
            case ("t", true): shortcut = .conventionalScope
            case ("t", false): shortcut = .conventionalType
            default: shortcut = nil
            }
        } else if modifiers.contains(.option) {
            switch event.keyCode {
            case 124, 125: shortcut = .nextFile
            case 123, 126: shortcut = .previousFile
            default: shortcut = nil
            }
        } else if modifiers.isEmpty {
            if event.keyCode == 96 {
                shortcut = .refresh
            } else {
                shortcut = key == "c" ? .addSelectionToMessage : nil
            }
        } else {
            shortcut = nil
        }
        if let shortcut, onShortcut?(shortcut) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
enum CommitWorkflowDialog {
    static func present(
        source: any RepositoryCommitWorkflowDataSource,
        pushSource: (any RepositoryPushingDataSource)? = nil,
        initialMode: RepositoryCommitMode,
        specialKind: CommitWorkflowSpecialKind? = nil,
        head: Commit?,
        draft: CommitDialogDraft?,
        owner: NSWindow,
        onRepositoryChanged: @escaping (RevisionID?) -> Void,
        onClose: @escaping () -> Void
    ) -> NSWindowController {
        let controller = CommitWorkflowViewController(
            source: source,
            pushSource: pushSource,
            initialMode: initialMode,
            specialKind: specialKind,
            head: head,
            draft: draft,
            onRepositoryChanged: onRepositoryChanged
        )
        let commitWindow = NSWindow(contentViewController: controller)
        commitWindow.title = "Commit"
        commitWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        commitWindow.standardWindowButton(.closeButton)?.isEnabled = true
        commitWindow.standardWindowButton(.zoomButton)?.isEnabled = true
        let geometry = AppSettingsStore.shared.commitPreferences
        commitWindow.setContentSize(NSSize(width: geometry.windowWidth, height: geometry.windowHeight))
        commitWindow.contentMinSize = NSSize(width: 600, height: 297)
        commitWindow.minSize = NSSize(width: 600, height: 297)
        commitWindow.isReleasedWhenClosed = false
        if let visibleFrame = owner.screen?.visibleFrame {
            commitWindow.maxSize = visibleFrame.size
        }
        controller.commitWindow = commitWindow
        commitWindow.delegate = controller

        let windowController = NSWindowController(window: commitWindow)
        controller.onClose = onClose
        commitWindow.setFrameOrigin(NSPoint(
            x: owner.frame.midX - commitWindow.frame.width / 2,
            y: owner.frame.midY - commitWindow.frame.height / 2
        ))
        windowController.showWindow(nil)
        commitWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return windowController
    }
}

@MainActor
private final class CommitWorkflowViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextViewDelegate, NSSearchFieldDelegate, NSWindowDelegate, NSMenuDelegate {
    private struct TemplateMenuValue {
        let template: CommitMessageTemplate
    }

    weak var commitWindow: NSWindow?
    var onClose: (() -> Void)?

    private let source: any RepositoryCommitWorkflowDataSource
    private let pushSource: (any RepositoryPushingDataSource)?
    private let initialMode: RepositoryCommitMode
    private var activeSpecialKind: CommitWorkflowSpecialKind?
    private let head: Commit?
    private let draft: CommitDialogDraft?
    private let onRepositoryChanged: (RevisionID?) -> Void
    private let settings = AppSettingsStore.shared
    private let unstagedTable = NSOutlineView()
    private let stagedTable = NSOutlineView()
    private let unstagedFilter = NSSearchField()
    private let stagedFilter = NSSearchField()
    private let stageSelectedButton = NSButton(title: "Stage", target: nil, action: nil)
    private let stageAllFilesButton = NSButton(title: "Stage All", target: nil, action: nil)
    private let unstageSelectedButton = NSButton(title: "Unstage", target: nil, action: nil)
    private let unstageAllFilesButton = NSButton(title: "Unstage All", target: nil, action: nil)
    private let messageView = NSTextView()
    private let commitDiffView = CommitDiffView()
    private let amend = NSButton(checkboxWithTitle: "Amend commit", target: nil, action: nil)
    private let amendPanel = NSStackView()
    private let messageMenu = NSPopUpButton()
    private let templatesMenu = NSPopUpButton()
    private let optionsMenu = NSPopUpButton()
    private let stageAll = NSButton(checkboxWithTitle: "Stage all before committing", target: nil, action: nil)
    private let allowEmpty = NSButton(checkboxWithTitle: "Allow Empty", target: nil, action: nil)
    private let signOff = NSButton(checkboxWithTitle: "Sign-off commit", target: nil, action: nil)
    private let resetAuthor = NSButton(checkboxWithTitle: "Reset author", target: nil, action: nil)
    private let author = NSTextField(string: "")
    private let status = NSTextField(labelWithString: "Loading changes…")
    private let commitButton = NSButton(title: "Commit", target: nil, action: nil)
    private let commitAndPushButton = NSButton(title: "Commit & push", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let stashStagedButton = NSButton(title: "Stash staged changes", target: nil, action: nil)
    private let resetAllButton = NSButton(title: "Reset all changes", target: nil, action: nil)
    private let resetUnstagedButton = NSButton(title: "Reset unstaged changes", target: nil, action: nil)
    private let resetSoftButton = NSButton(title: "Reset soft", target: nil, action: nil)
    private let createBranchButton = NSButton(title: "Create branch", target: nil, action: nil)
    private let modifyCommitMessageButton = NSButton(title: "Modify commit message", target: nil, action: nil)
    private let mainSplit = NSSplitView()
    private let fileSplit = NSSplitView()
    private let contentSplit = NSSplitView()
    private let messageSplit = NSSplitView()
    private var didSetInitialDividers = false
    private var unstaged: [ChangedFile] = []
    private var staged: [ChangedFile] = []
    private var unstagedRootNodes: [ChangedFileNode] = []
    private var stagedRootNodes: [ChangedFileNode] = []
    private var repositoryContext: RepositoryCommitContext?
    private var networkContext: RepositoryNetworkContext?
    private var commitState: RepositoryCommitState?
    private var loadTask: Task<Void, Never>?
    private var diffLoadTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>? {
        didSet {
            if isViewLoaded { updateButtonStates() }
        }
    }
    private var didComplete = false
    private var showOnlyMyMessages = false
    private var usingTemplate = false
    private var noVerify = false
    private var gpgSigning: RepositoryCommitGPGSigning = .gitDefault
    private var gpgKey = ""
    private var pushWindowController: NSWindowController?
    private var didInitialFocus = false
    private var persistDraftOnClose = true
    private var didBecomeKeyOnce = false
    private var historyWasSoftReset = false
    private var closeWhenPushCompletes = false
    private var fileTreeMode: Bool
    private var fileGroupingMode: FileStatusGrouping
    private var usesDenseTree: Bool
    private var showsGroupNodesInFlatList: Bool
    private var showsUntrackedFiles: Bool
    private var fileTreeButtons: [NSButton] = []
    private var fileGroupingButtons: [NSButton] = []
    private var fileCollapseButtons: [NSButton] = []
    private var fileGroupingMenus: [NSMenu] = []
    private var isFormattingMessage = false
    private var lastShownMessageLoadError: String?
    private var selectedCommitMode: RepositoryCommitMode = .normal

    init(
        source: any RepositoryCommitWorkflowDataSource,
        pushSource: (any RepositoryPushingDataSource)?,
        initialMode: RepositoryCommitMode,
        specialKind: CommitWorkflowSpecialKind?,
        head: Commit?,
        draft: CommitDialogDraft?,
        onRepositoryChanged: @escaping (RevisionID?) -> Void
    ) {
        self.source = source
        self.pushSource = pushSource
        self.initialMode = initialMode
        self.activeSpecialKind = specialKind
        self.head = head
        self.draft = draft
        self.onRepositoryChanged = onRepositoryChanged
        self.showOnlyMyMessages = AppSettingsStore.shared.commitPreferences.showOnlyMyMessages
        let filePreferences = AppSettingsStore.shared.fileStatusListPreferences
        self.fileTreeMode = filePreferences.isTreeMode
        self.fileGroupingMode = filePreferences.grouping
        self.usesDenseTree = filePreferences.usesDenseTree
        self.showsGroupNodesInFlatList = filePreferences.showsGroupNodesInFlatList
        self.showsUntrackedFiles = filePreferences.showsUntrackedFiles
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }
    deinit { loadTask?.cancel(); diffLoadTask?.cancel(); actionTask?.cancel() }

    override func loadView() {
        let root = CommitRootView()
        root.onShortcut = { [weak self] shortcut in self?.perform(shortcut: shortcut) ?? false }
        commitDiffView.onApplyHunk = { [weak self] lineID, direction in
            self?.applySelectedHunk(lineID: lineID, direction: direction)
        }
        commitDiffView.onApplyLines = { [weak self] lineIDs, direction in
            self?.applySelectedLines(lineIDs: lineIDs, direction: direction)
        }
        commitDiffView.onAddSelectedText = { [weak self] text in
            self?.addSelectedDiffTextToMessage(text)
        }
        let left = makeFilePane()
        let right = makeMessagePane()
        mainSplit.isVertical = true
        mainSplit.dividerStyle = .paneSplitter
        mainSplit.addArrangedSubview(left)
        mainSplit.addArrangedSubview(right)
        mainSplit.translatesAutoresizingMaskIntoConstraints = false
        left.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(mainSplit)
        root.addSubview(status)
        NSLayoutConstraint.activate([
            mainSplit.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            mainSplit.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            mainSplit.topAnchor.constraint(equalTo: root.topAnchor),
            mainSplit.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -2),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -4),
            status.heightAnchor.constraint(equalToConstant: 18)
        ])
        view = root
        configureInitialValues()
        reloadChanges()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !didSetInitialDividers else { return }
        didSetInitialDividers = true
        view.layoutSubtreeIfNeeded()
        let geometry = settings.commitPreferences
        mainSplit.setPosition(clamped(geometry.mainDivider, minimum: 240, maximum: mainSplit.bounds.width - 320), ofDividerAt: 0)
        fileSplit.setPosition(clamped(geometry.fileDivider, minimum: 110, maximum: fileSplit.bounds.height - 110), ofDividerAt: 0)
        contentSplit.setPosition(clamped(geometry.contentDivider, minimum: 90, maximum: contentSplit.bounds.height - 135), ofDividerAt: 0)
        messageSplit.setPosition(clamped(geometry.commandDivider, minimum: 150, maximum: messageSplit.bounds.width - 230), ofDividerAt: 0)
    }

    private func clamped(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(maximum, max(minimum, value))
    }

    private func makeFilePane() -> NSView {
        configureTable(unstagedTable)
        configureTable(stagedTable)
        let unstagedScroll = scroll(for: unstagedTable)
        let stagedScroll = scroll(for: stagedTable)
        stageSelectedButton.target = self; stageSelectedButton.action = #selector(stageSelected)
        stageSelectedButton.keyEquivalent = "s"; stageSelectedButton.keyEquivalentModifierMask = .command
        stageAllFilesButton.target = self; stageAllFilesButton.action = #selector(stageEveryFile)
        unstageSelectedButton.target = self; unstageSelectedButton.action = #selector(unstageSelected)
        unstageAllFilesButton.target = self; unstageAllFilesButton.action = #selector(unstageEveryFile)
        unstagedFilter.placeholderString = "Filter files using a regular expression…"
        stagedFilter.placeholderString = "Filter files using a regular expression…"
        unstagedFilter.delegate = self
        stagedFilter.delegate = self
        unstagedTable.target = self; unstagedTable.doubleAction = #selector(stageSelected)
        stagedTable.target = self; stagedTable.doubleAction = #selector(unstageSelected)
        let topTools = fileToolbar(for: unstagedTable)
        let transfer = transferToolbar(
            unstageAll: unstageAllFilesButton,
            unstage: unstageSelectedButton,
            stage: stageSelectedButton,
            stageAll: stageAllFilesButton
        )
        let bottomTools = fileToolbar(for: stagedTable)
        let top = stacked(topTools, unstagedFilter, unstagedScroll)
        let bottom = stacked(transfer, bottomTools, stagedFilter, stagedScroll)
        fileSplit.isVertical = false
        fileSplit.dividerStyle = .paneSplitter
        fileSplit.addArrangedSubview(top)
        fileSplit.addArrangedSubview(bottom)
        return fileSplit
    }

    private func makeMessagePane() -> NSView {
        messageView.isRichText = false
        messageView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        messageView.delegate = self
        messageView.isAutomaticTextCompletionEnabled = true
        let messageScroll = NSScrollView()
        messageScroll.documentView = messageView
        messageScroll.hasVerticalScroller = true
        messageScroll.borderType = .bezelBorder
        configureDocumentView(messageView, width: 760, height: 260)
        messageScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 115).isActive = true

        commitButton.target = self
        commitButton.action = #selector(commit)
        commitButton.keyEquivalent = "\r"
        commitButton.keyEquivalentModifierMask = .command
        commitAndPushButton.target = self
        commitAndPushButton.action = #selector(commitAndPush)
        commitAndPushButton.isEnabled = pushSource != nil
        amend.target = self
        amend.action = #selector(amendChanged)
        modifyCommitMessageButton.target = self
        modifyCommitMessageButton.action = #selector(modifySpecialCommitMessage)
        modifyCommitMessageButton.bezelStyle = .inline
        stashStagedButton.target = self; stashStagedButton.action = #selector(stashStagedChanges)
        resetAllButton.target = self; resetAllButton.action = #selector(resetAllChanges)
        resetUnstagedButton.target = self; resetUnstagedButton.action = #selector(resetUnstagedChanges)
        resetSoftButton.target = self; resetSoftButton.action = #selector(resetSoft)
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        for button in [commitButton, commitAndPushButton, stashStagedButton, resetAllButton, resetUnstagedButton, cancelButton] {
            button.widthAnchor.constraint(equalToConstant: 171).isActive = true
            button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }
        resetSoftButton.widthAnchor.constraint(equalToConstant: 159).isActive = true
        resetSoftButton.heightAnchor.constraint(equalToConstant: 26).isActive = true
        amendPanel.orientation = .vertical
        amendPanel.alignment = .leading
        amendPanel.spacing = 2
        amendPanel.addArrangedSubview(resetAuthor)
        amendPanel.addArrangedSubview(resetSoftButton)
        amendPanel.isHidden = true
        let commands = NSStackView(views: [commitButton, commitAndPushButton, amend, amendPanel, modifyCommitMessageButton, stashStagedButton, resetAllButton, resetUnstagedButton, cancelButton])
        commands.orientation = .vertical
        commands.alignment = .leading
        commands.spacing = 7
        commands.edgeInsets = NSEdgeInsets(top: 8, left: 3, bottom: 8, right: 3)

        messageMenu.removeAllItems()
        messageMenu.pullsDown = true
        messageMenu.addItem(withTitle: "Commit message")
        createBranchButton.target = self
        createBranchButton.action = #selector(createBranch)
        templatesMenu.removeAllItems()
        templatesMenu.pullsDown = true
        templatesMenu.addItem(withTitle: "Commit templates")
        optionsMenu.removeAllItems()
        optionsMenu.pullsDown = true
        optionsMenu.addItem(withTitle: "Options")
        configureOptionsMenu()
        messageMenu.widthAnchor.constraint(equalToConstant: 85).isActive = true
        templatesMenu.widthAnchor.constraint(equalToConstant: 125).isActive = true
        createBranchButton.widthAnchor.constraint(equalToConstant: 100).isActive = true
        optionsMenu.widthAnchor.constraint(equalToConstant: 90).isActive = true
        [messageMenu, templatesMenu, createBranchButton, optionsMenu].forEach {
            $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            $0.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let messageToolbar = NSStackView(views: [messageMenu, templatesMenu, createBranchButton, spacer, optionsMenu])
        messageToolbar.orientation = .horizontal
        messageToolbar.alignment = .centerY
        messageToolbar.spacing = 6
        messageToolbar.edgeInsets = NSEdgeInsets(top: 3, left: 5, bottom: 3, right: 5)
        let editor = NSStackView(views: [messageToolbar, messageScroll])
        editor.orientation = .vertical
        editor.alignment = .leading
        editor.spacing = 0
        messageToolbar.widthAnchor.constraint(equalTo: editor.widthAnchor).isActive = true
        messageScroll.widthAnchor.constraint(equalTo: editor.widthAnchor).isActive = true
        messageSplit.isVertical = true
        messageSplit.dividerStyle = .thin
        messageSplit.addArrangedSubview(commands)
        messageSplit.addArrangedSubview(editor)
        commands.widthAnchor.constraint(greaterThanOrEqualToConstant: 171).isActive = true

        contentSplit.isVertical = false
        contentSplit.dividerStyle = .paneSplitter
        contentSplit.addArrangedSubview(commitDiffView)
        contentSplit.addArrangedSubview(messageSplit)
        return contentSplit
    }

    private func configureMessageMenu() {
        guard let menu = messageMenu.menu else { return }
        while menu.items.count > 1 { menu.removeItem(at: 1) }
        var history = commitState?.previousMessages ?? []
        let last = settings.commitPreferences.lastCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty, !history.contains(last) {
            history.insert(last, at: 0)
            history = Array(history.prefix(max(1, settings.commitPreferences.historyLimit)))
        }
        for message in history {
            let item = NSMenuItem(title: shortenedMessage(message), action: #selector(selectRecentCommitMessage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = message
            menu.addItem(item)
        }
        if history.isEmpty == false { menu.addItem(.separator()) }
        let changes = NSMenuItem(title: "Generate a list of changes in submodules", action: #selector(generateSubmoduleMessage(_:)), keyEquivalent: "")
        changes.target = self
        menu.addItem(changes)
        let mine = NSMenuItem(title: "Show only my messages", action: #selector(toggleMyMessages(_:)), keyEquivalent: "")
        mine.target = self
        mine.state = showOnlyMyMessages ? .on : .off
        mine.representedObject = "showOnlyMine"
        menu.addItem(mine)
    }

    private func configureTemplatesMenu() {
        guard let menu = templatesMenu.menu else { return }
        while menu.items.count > 1 { menu.removeItem(at: 1) }
        let templates = settings.commitPreferences.templates.filter { !$0.name.isEmpty }
        for template in templates {
            let item = NSMenuItem(title: template.name, action: #selector(selectCommitTemplate(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = TemplateMenuValue(template: template)
            menu.addItem(item)
        }
        if !templates.isEmpty { menu.addItem(.separator()) }

        let conventional = NSMenuItem(title: "Conventional Commits", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Conventional Commits")
        for keyword in ["build", "chore", "ci", "docs", "feat", "fix", "perf", "refactor", "style", "test"] {
            let item = NSMenuItem(title: keyword, action: #selector(insertConventionalPrefix(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = keyword
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        for footer in ["BREAKING CHANGE", "Co-authored-by", "Reviewed-by", "[skip ci]"] {
            let item = NSMenuItem(title: footer, action: #selector(insertTemplateFooter(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = footer
            submenu.addItem(item)
        }
        let documentation = NSMenuItem(title: "Documentation…", action: #selector(openConventionalCommitDocumentation), keyEquivalent: "")
        documentation.target = self
        submenu.addItem(documentation)
        conventional.submenu = submenu
        menu.addItem(conventional)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Edit commit message templates and settings…", action: #selector(editCommitTemplates), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
    }

    private func configureOptionsMenu() {
        guard let menu = optionsMenu.menu else { return }
        while menu.items.count > 1 { menu.removeItem(at: 1) }
        for (title, key) in [
            ("Close dialog after each commit", "closeEach"),
            ("Close dialog when all changes are committed", "closeAll"),
            ("Refresh dialog on form focus", "refreshFocus"),
            ("Select staged on entering message editor", "selectStaged")
        ] {
            let item = NSMenuItem(title: title, action: #selector(toggleCommitOption(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key
            let preferences = settings.commitPreferences
            item.state = switch key {
            case "closeEach": preferences.closeAfterCommit ? .on : .off
            case "closeAll": preferences.closeAfterLastCommit ? .on : .off
            case "refreshFocus": preferences.refreshOnFocus ? .on : .off
            case "selectStaged": preferences.selectStagedOnMessageFocus ? .on : .off
            default: .off
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let sign = NSMenuItem(title: "Sign-off commit", action: #selector(toggleCommitOption(_:)), keyEquivalent: "")
        sign.target = self
        sign.representedObject = "signOff"
        sign.state = signOff.state
        menu.addItem(sign)
        let emptyAuthor = author.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let authorInfo = NSMenuItem(
            title: emptyAuthor ? "Override author…" : "Author: \(author.stringValue)…",
            action: #selector(promptAuthorOverride),
            keyEquivalent: ""
        )
        authorInfo.target = self
        menu.addItem(authorInfo)
        if !emptyAuthor {
            let clearAuthor = NSMenuItem(title: "Clear author override", action: #selector(clearAuthorOverride), keyEquivalent: "")
            clearAuthor.target = self
            menu.addItem(clearAuthor)
        }
        let allowEmptyItem = NSMenuItem(title: "Allow Empty", action: #selector(toggleCommitOption(_:)), keyEquivalent: "")
        allowEmptyItem.target = self
        allowEmptyItem.representedObject = "allowEmpty"
        allowEmptyItem.state = allowEmpty.state
        menu.addItem(allowEmptyItem)
        let noVerifyItem = NSMenuItem(title: "No verify", action: #selector(toggleCommitOption(_:)), keyEquivalent: "")
        noVerifyItem.target = self
        noVerifyItem.representedObject = "noVerify"
        noVerifyItem.state = noVerify ? .on : .off
        menu.addItem(noVerifyItem)
        menu.addItem(.separator())
        let gpg = NSMenuItem(title: "Git default GPG signing", action: nil, keyEquivalent: "")
        let gpgMenu = NSMenu(title: "GPG signing")
        for (index, title) in ["Git default GPG signing", "Do not sign commit", "Sign with default GPG", "Sign with specific GPG"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(selectGPGSigning(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = gpgSelectionIndex == index ? .on : .off
            gpgMenu.addItem(item)
        }
        gpg.submenu = gpgMenu
        menu.addItem(gpg)
    }

    private func shortenedMessage(_ value: String) -> String {
        let firstLine = value.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first.map(String.init) ?? value
        return firstLine.count > 72 ? String(firstLine.prefix(69)) + "…" : firstLine
    }

    private var gpgSelectionIndex: Int {
        switch gpgSigning {
        case .gitDefault: 0
        case .doNotSign: 1
        case .signDefault: 2
        case .signSpecificKey: 3
        }
    }

    @objc private func selectRecentCommitMessage(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        messageView.string = value.trimmingCharacters(in: .whitespacesAndNewlines)
        commitWindow?.makeFirstResponder(messageView)
    }

    @objc private func generateSubmoduleMessage(_ sender: NSMenuItem) {
        let changed = (repositoryContext?.submodules ?? []).filter { module in
            staged.contains { $0.path == module.path }
        }
        guard !changed.isEmpty else {
            status.stringValue = "There are no staged submodule changes."
            return
        }
        var lines = ["Submodule\(changed.count == 1 ? "" : "s") \(changed.map(\.path).joined(separator: ", ")) updated", ""]
        for module in changed {
            lines.append("Submodule \(module.path):")
            lines.append("    * Revision changed to \(module.commitID.map { String($0.string.prefix(7)) } ?? "unknown")")
            lines.append("")
        }
        messageView.string = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
        commitWindow?.makeFirstResponder(messageView)
    }

    @objc private func toggleMyMessages(_ sender: NSMenuItem) {
        showOnlyMyMessages.toggle()
        var preferences = settings.commitPreferences
        preferences.showOnlyMyMessages = showOnlyMyMessages
        settings.saveCommitPreferences(preferences)
        reloadChanges(preserveMessage: true)
    }

    @objc private func selectCommitTemplate(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? TemplateMenuValue else { return }
        let branch = commitState?.mutationState.currentBranch ?? ""
        messageView.string = CommitTemplateExpander.expand(
            value.template.text,
            forBranch: branch,
            enabled: value.template.expandsBranchRegularExpressions
        )
        usingTemplate = true
        commitWindow?.makeFirstResponder(messageView)
    }

    @objc private func editCommitTemplates() {
        guard let commitWindow else { return }
        CommitTemplateSettingsDialog.present(parent: commitWindow) { [weak self] in
            self?.configureTemplatesMenu()
        }
    }

    @objc private func openConventionalCommitDocumentation() {
        guard let url = URL(string: "https://www.conventionalcommits.org/") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func insertConventionalPrefix(_ sender: NSMenuItem) {
        guard let keyword = sender.representedObject as? String else { return }
        insertConventionalPrefixItem(keyword)
    }

    @objc private func insertTemplateFooter(_ sender: NSMenuItem) {
        guard let footer = sender.representedObject as? String else { return }
        let suffix = messageView.string.isEmpty ? "" : "\n\n"
        messageView.string += suffix + footer + (footer == "[skip ci]" ? "" : ": ")
        commitWindow?.makeFirstResponder(messageView)
    }

    @objc private func toggleCommitOption(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        if key == "signOff" {
            signOff.state = signOff.state == .on ? .off : .on
            sender.state = signOff.state
        } else if key == "noVerify" {
            noVerify.toggle()
            sender.state = noVerify ? .on : .off
        } else if key == "allowEmpty" {
            allowEmpty.state = allowEmpty.state == .on ? .off : .on
            sender.state = allowEmpty.state
        } else {
            sender.state = sender.state == .on ? .off : .on
            var preferences = settings.commitPreferences
            switch key {
            case "closeEach": preferences.closeAfterCommit = sender.state == .on
            case "closeAll": preferences.closeAfterLastCommit = sender.state == .on
            case "refreshFocus": preferences.refreshOnFocus = sender.state == .on
            case "selectStaged": preferences.selectStagedOnMessageFocus = sender.state == .on
            default: break
            }
            settings.saveCommitPreferences(preferences)
        }
    }

    @objc private func promptAuthorOverride() {
        guard let commitWindow else { return }
        actionTask = Task { @MainActor [weak self, weak commitWindow] in
            guard let self, let commitWindow else { return }
            defer { actionTask = nil; updateButtonStates() }
            let alert = NSAlert()
            alert.messageText = "Override commit author"
            alert.informativeText = "Enter the author using the format Name <email@example.com>."
            alert.addButton(withTitle: "Use Author")
            alert.addButton(withTitle: "Cancel")
            let field = NSTextField(string: author.stringValue)
            field.placeholderString = "Name <email@example.com>"
            field.frame.size.width = 320
            alert.accessoryView = field
            guard await begin(alert, window: commitWindow) == .alertFirstButtonReturn else { return }
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.isEmpty || value.range(of: #"^.+\s<[^<>]+>$"#, options: .regularExpression) != nil else {
                status.stringValue = "Author must use the format Name <email@example.com>."
                return
            }
            author.stringValue = value
            configureOptionsMenu()
        }
    }

    @objc private func clearAuthorOverride() {
        author.stringValue = ""
        configureOptionsMenu()
    }

    @objc private func selectGPGSigning(_ sender: NSMenuItem) {
        switch sender.tag {
        case 1: gpgSigning = .doNotSign
        case 2: gpgSigning = .signDefault
        case 3:
            guard let commitWindow else { return }
            actionTask?.cancel()
            actionTask = Task { @MainActor [weak self, weak commitWindow] in
                guard let self, let commitWindow else { return }
                defer { actionTask = nil; updateButtonStates() }
                let alert = NSAlert()
                alert.messageText = "Sign with specific GPG key"
                alert.informativeText = "Enter the key ID, fingerprint, or signing identity Git should pass to --gpg-sign."
                alert.addButton(withTitle: "Use Key")
                alert.addButton(withTitle: "Cancel")
                let field = NSTextField(string: gpgKey.isEmpty ? settings.preferences.signingKey : gpgKey)
                field.placeholderString = "GPG key"
                field.frame.size.width = 320
                alert.accessoryView = field
                guard await begin(alert, window: commitWindow) == .alertFirstButtonReturn else { return }
                let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { status.stringValue = "Enter a GPG key."; return }
                gpgKey = key
                gpgSigning = .signSpecificKey(key)
                configureOptionsMenu()
            }
            return
        default: gpgSigning = .gitDefault
        }
        configureOptionsMenu()
    }

    private func configureInitialValues() {
        let initial = draft?.request
        let selectedMode = initial?.mode ?? initialMode
        selectedCommitMode = selectedMode
        amend.state = selectedMode == .normal ? .off : .on
        messageView.string = activeSpecialKind?.message ?? initial?.message ?? (selectedMode == .normal ? "" : headMessage())
        let preferences = settings.preferences
        let commitPreferences = settings.commitPreferences
        stageAll.state = initial?.stageAllBeforeCommit == true ? .on : .off
        allowEmpty.state = (initial?.allowEmpty ?? preferences.defaultAllowEmpty) ? .on : .off
        signOff.state = (initial?.signOff ?? preferences.defaultSignOff) ? .on : .off
        resetAuthor.state = initial?.resetAuthor == true ? .on : .off
        author.stringValue = initial?.author ?? ""
        noVerify = initial?.noVerify ?? false
        gpgSigning = initial?.gpgSigning ?? .gitDefault
        usingTemplate = initial?.usingTemplate ?? false
        applySpecialCommitState()
        commitAndPushButton.isHidden = !commitPreferences.showCommitAndPush
        resetAllButton.isHidden = !commitPreferences.showResetAll
        resetUnstagedButton.isHidden = !commitPreferences.showResetUnstaged
        modeChanged()
    }

    private func configureTable(_ table: NSOutlineView) {
        let fileColumn = NSTableColumn(identifier: .init("File"))
        fileColumn.width = 330
        table.addTableColumn(fileColumn)
        table.outlineTableColumn = fileColumn
        table.headerView = nil
        table.rowHeight = BrowserMetrics.fileRowHeight
        table.indentationPerLevel = 14
        table.intercellSpacing = .zero
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .controlBackgroundColor
        table.delegate = self
        table.dataSource = self
        let menu = NSMenu(title: "File actions")
        menu.identifier = NSUserInterfaceItemIdentifier(table === unstagedTable ? "unstaged" : "staged")
        menu.delegate = self
        table.menu = menu
    }

    private func headMessage() -> String {
        guard let head else { return "" }
        return head.subject + (head.body.isEmpty ? "" : "\n\n\(head.body)")
    }

    private func scroll(for table: NSOutlineView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        return scroll
    }

    private func toolbar(title: String, buttons: [NSButton]) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: 12)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [label, spacer] + buttons)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 5)
        return stack
    }

    private func stacked(_ views: NSView...) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.spacing = 0
        return stack
    }

    private func fileToolbar(for table: NSTableView) -> NSView {
        let tree = makeFileGroupingMenu()
        let path = makeDirectGroupingButton(.path, tag: 0, image: "FolderClosed", tooltip: "Group by file path")
        let fileExtension = makeDirectGroupingButton(.fileExtension, tag: 1, image: "File", tooltip: "Group by file type (extension)")
        let statusGrouping = makeDirectGroupingButton(.status, tag: 2, image: "FileStatusModified", tooltip: "Group by diff status")
        let settings = makeFileSettingsMenu(for: table)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let collapse = AppKitFactory.resourceButton(
            "CollapseAll",
            tooltip: "Collapse all groups, otherwise expand all groups",
            target: self,
            action: #selector(toggleFileGroupExpansion(_:))
        )
        collapse.tag = table === unstagedTable ? 0 : 1
        fileCollapseButtons.append(collapse)
        var controls: [NSView] = [collapse, AppKitFactory.separator()]
        if table === unstagedTable {
            controls.append(AppKitFactory.resourceButton("ReloadRevisions", tooltip: "Refresh changes", target: self, action: #selector(refreshChanges)))
            controls.append(AppKitFactory.separator())
        }
        controls += [tree, AppKitFactory.separator(), path, fileExtension, statusGrouping, AppKitFactory.separator(), settings, spacer]
        let bar = NSStackView(views: controls)
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 0
        bar.edgeInsets = NSEdgeInsets(top: 1, left: 3, bottom: 1, right: 3)
        bar.heightAnchor.constraint(equalToConstant: 25).isActive = true
        return bar
    }

    @objc private func toggleFileGroupExpansion(_ sender: NSButton) {
        let table = sender.tag == 0 ? unstagedTable : stagedTable
        let roots = rootNodes(for: table)
        let expanded = roots.contains { table.isItemExpanded($0) }
        roots.forEach { node in
            if expanded {
                table.collapseItem(node, collapseChildren: true)
            } else {
                table.expandItem(node, expandChildren: true)
            }
        }
    }

    private func makeDirectGroupingButton(_ grouping: FileStatusGrouping, tag: Int, image: String, tooltip: String) -> NSButton {
        let button = AppKitFactory.resourceButton(image, tooltip: tooltip, target: self, action: #selector(selectDirectFileGrouping(_:)))
        button.setButtonType(.pushOnPushOff)
        button.tag = tag
        button.state = fileGroupingMode == grouping ? .on : .off
        fileGroupingButtons.append(button)
        return button
    }

    private func makeFileGroupingMenu() -> NSView {
        let control = NSStackView()
        control.orientation = .horizontal
        control.spacing = 0
        control.alignment = .centerY
        let tree = AppKitFactory.resourceButton("FileTree", tooltip: "Toggle flat list / tree", target: self, action: #selector(toggleFileTree(_:)))
        tree.setButtonType(.pushOnPushOff)
        tree.state = fileTreeMode ? .on : .off
        fileTreeButtons.append(tree)
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.isBordered = false
        button.controlSize = .small
        button.toolTip = "File list grouping options"
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 12).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        button.addItem(withTitle: "")
        button.itemArray.first?.title = ""
        control.addArrangedSubview(tree)
        control.addArrangedSubview(button)
        let entries = [
            ("Group by file path - tree", 0),
            ("Group by file path - flat", 1),
            ("Group by file extension - tree", 2),
            ("Group by file extension - flat", 3),
            ("Group by file status - tree", 4),
            ("Group by file status - flat", 5)
        ]
        for (title, tag) in entries {
            let item = NSMenuItem(title: title, action: #selector(selectFileGrouping(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            button.menu?.addItem(item)
        }
        button.menu?.addItem(.separator())
        let dense = NSMenuItem(title: "Dense tree (merge single item with its folder node)", action: #selector(toggleTreePresentationOption(_:)), keyEquivalent: "")
        dense.target = self
        dense.tag = 10
        dense.state = usesDenseTree ? .on : .off
        dense.isEnabled = fileTreeMode
        button.menu?.addItem(dense)
        let groups = NSMenuItem(title: "Show group nodes in flat list (if multiple)", action: #selector(toggleTreePresentationOption(_:)), keyEquivalent: "")
        groups.target = self
        groups.tag = 11
        groups.state = showsGroupNodesInFlatList ? .on : .off
        groups.isEnabled = !fileTreeMode && fileGroupingMode != .path
        button.menu?.addItem(groups)
        if let menu = button.menu { fileGroupingMenus.append(menu) }
        return control
    }

    private func makeFileSettingsMenu(for table: NSTableView) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.isBordered = false
        button.controlSize = .small
        button.toolTip = "File list settings"
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        button.addItem(withTitle: "")
        button.itemArray.first?.title = ""
        button.itemArray.first?.image = AppKitFactory.resourceImage("Settings", accessibilityDescription: "File list settings")

        if table === unstagedTable {
            let ignoredFiles = NSMenuItem(title: "Show ignored files", action: nil, keyEquivalent: "")
            ignoredFiles.isEnabled = false
            ignoredFiles.toolTip = "Ignored-file discovery is not available in the typed repository status service."
            button.menu?.addItem(ignoredFiles)
        }
        let skipWorktree = NSMenuItem(title: "Show skip-worktree files", action: nil, keyEquivalent: "")
        skipWorktree.state = .off
        skipWorktree.isEnabled = false
        skipWorktree.toolTip = "Skip-worktree inspection is not available in this repository view."
        button.menu?.addItem(skipWorktree)
        if table === unstagedTable {
            let assumeUnchanged = NSMenuItem(title: "Show assumed-unchanged files", action: nil, keyEquivalent: "")
            assumeUnchanged.isEnabled = false
            assumeUnchanged.toolTip = "Assume-unchanged discovery is not available in the typed repository status service."
            button.menu?.addItem(assumeUnchanged)
        }
        let untracked = NSMenuItem(title: "Show untracked files", action: #selector(toggleShowUntrackedFiles(_:)), keyEquivalent: "")
        untracked.target = self
        untracked.state = showsUntrackedFiles ? .on : .off
        untracked.isEnabled = table === unstagedTable
        button.menu?.addItem(untracked)
        button.menu?.addItem(.separator())

        let ignored = NSMenuItem(title: "Edit ignored files", action: #selector(editIgnoredFiles(_:)), keyEquivalent: "")
        ignored.target = self
        ignored.tag = 0
        button.menu?.addItem(ignored)
        let localIgnored = NSMenuItem(title: "Edit locally ignored files", action: #selector(editIgnoredFiles(_:)), keyEquivalent: "")
        localIgnored.target = self
        localIgnored.tag = 1
        button.menu?.addItem(localIgnored)
        button.menu?.addItem(.separator())
        if table === unstagedTable {
            let refreshOnFocus = NSMenuItem(title: "Refresh artificial commits on form focus", action: #selector(toggleRefreshOnFocus(_:)), keyEquivalent: "")
            refreshOnFocus.target = self
            refreshOnFocus.state = settings.commitPreferences.refreshOnFocus ? .on : .off
            button.menu?.addItem(refreshOnFocus)
            button.menu?.addItem(.separator())
        }
        let toolbar = NSMenuItem(title: "Toolbar", action: nil, keyEquivalent: "")
        toolbar.isEnabled = false
        toolbar.toolTip = "Per-item toolbar customization is not available."
        button.menu?.addItem(toolbar)
        return button
    }

    private func transferToolbar(unstageAll: NSButton, unstage: NSButton, stage: NSButton, stageAll: NSButton) -> NSView {
        for button in [unstageAll, unstage, stage, stageAll] {
            let isStage = button === stage || button === stageAll
            let isAll = button === stageAll || button === unstageAll
            button.image = AppKitFactory.resourceImage(isStage ? "ArrowDown" : "ArrowUp", accessibilityDescription: isStage ? "Stage" : "Unstage", isTemplate: true)
            button.isBordered = false
            button.contentTintColor = .systemPurple
            button.toolTip = button === stageAll ? "Stage all" : button === stage ? "Stage selected" : button === unstageAll ? "Unstage all" : "Unstage selected"
            if isAll {
                button.title = ""
                button.imagePosition = .imageOnly
                button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            } else {
                button.title = isStage ? "Stage" : "Unstage"
                button.imagePosition = .imageLeading
                button.imageHugsTitle = true
                button.font = .systemFont(ofSize: 12)
                button.widthAnchor.constraint(greaterThanOrEqualToConstant: isStage ? 70 : 82).isActive = true
            }
        }
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [unstageAll, unstage, spacer, stage, stageAll])
        bar.orientation = .horizontal; bar.alignment = .centerY; bar.spacing = 5
        bar.edgeInsets = NSEdgeInsets(top: 3, left: 5, bottom: 3, right: 5)
        return bar
    }

    private func configureDocumentView(_ textView: NSTextView, width: CGFloat, height: CGFloat) {
        textView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
    }

    private func selectedChangedFile() -> ChangedFile? {
        selectedLeafFile(in: unstagedTable) ?? selectedLeafFile(in: stagedTable)
    }

    @objc private func toggleFileTree(_ sender: NSButton) {
        fileTreeMode.toggle()
        updateFileGroupingControls()
        persistFileListPreferences()
        reloadFileTrees()
        status.stringValue = fileTreeMode
            ? "File list: tree view"
            : "File list: flat view"
    }

    @objc private func selectFileGrouping(_ sender: NSMenuItem) {
        fileGroupingMode = switch sender.tag {
        case 2, 3: .fileExtension
        case 4, 5: .status
        default: .path
        }
        fileTreeMode = sender.tag.isMultiple(of: 2)
        updateFileGroupingControls()
        persistFileListPreferences()
        reloadFileTrees()
        status.stringValue = sender.title
    }

    @objc private func selectDirectFileGrouping(_ sender: NSButton) {
        fileGroupingMode = switch sender.tag {
        case 1: .fileExtension
        case 2: .status
        default: .path
        }
        updateFileGroupingControls()
        persistFileListPreferences()
        reloadFileTrees()
        status.stringValue = sender.toolTip ?? "File list grouping updated."
    }

    @objc private func toggleTreePresentationOption(_ sender: NSMenuItem) {
        if sender.tag == 10 {
            usesDenseTree.toggle()
            sender.state = usesDenseTree ? .on : .off
        } else {
            showsGroupNodesInFlatList.toggle()
            sender.state = showsGroupNodesInFlatList ? .on : .off
        }
        persistFileListPreferences()
        reloadFileTrees()
    }

    private func persistFileListPreferences() {
        settings.saveFileStatusListPreferences(FileStatusListPreferences(
            grouping: fileGroupingMode,
            isTreeMode: fileTreeMode,
            usesDenseTree: usesDenseTree,
            showsGroupNodesInFlatList: showsGroupNodesInFlatList,
            showsUntrackedFiles: showsUntrackedFiles
        ))
    }

    private func updateFileGroupingControls() {
        fileTreeButtons.forEach { $0.state = fileTreeMode ? .on : .off }
        fileGroupingButtons.forEach { button in
            let grouping: FileStatusGrouping = switch button.tag {
            case 1: .fileExtension
            case 2: .status
            default: .path
            }
            button.state = grouping == fileGroupingMode ? .on : .off
        }
        fileGroupingMenus.forEach { menu in
            for item in menu.items {
                if item.action == #selector(selectFileGrouping(_:)) {
                    let itemGrouping: FileStatusGrouping = switch item.tag {
                    case 2, 3: .fileExtension
                    case 4, 5: .status
                    default: .path
                    }
                    let itemIsTree = item.tag.isMultiple(of: 2)
                    item.state = itemGrouping == fileGroupingMode && itemIsTree == fileTreeMode ? .on : .off
                } else if item.tag == 10 {
                    item.state = usesDenseTree ? .on : .off
                    item.isEnabled = fileTreeMode
                } else if item.tag == 11 {
                    item.state = showsGroupNodesInFlatList ? .on : .off
                    item.isEnabled = !fileTreeMode && fileGroupingMode != .path
                }
            }
        }
    }

    @objc private func openContainingFolder(_ sender: NSButton) {
        guard let file = selectedChangedFile(), let context = repositoryContext else {
            status.stringValue = "Select a file first."
            return
        }
        let url = URL(fileURLWithPath: context.repository.path).appendingPathComponent(file.path).deletingLastPathComponent()
        NSWorkspace.shared.open(url)
    }

    @objc private func viewSelectedFile(_ sender: NSButton) {
        guard let file = selectedChangedFile(), let context = repositoryContext else {
            status.stringValue = "Select a file first."
            return
        }
        let url = URL(fileURLWithPath: context.repository.path).appendingPathComponent(file.path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            status.stringValue = "The selected file is not present in the working directory."
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func focusFileFilter() {
        view.window?.makeFirstResponder(unstagedTable.selectedRow >= 0 ? unstagedFilter : stagedFilter)
    }

    @objc private func editIgnoredFiles(_ sender: NSMenuItem) {
        guard let repository = repositoryContext?.repository else {
            status.stringValue = "Repository information is not available."
            return
        }
        let url = sender.tag == 1
            ? URL(fileURLWithPath: repository.path).appendingPathComponent(".git/info/exclude")
            : URL(fileURLWithPath: repository.path).appendingPathComponent(".gitignore")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleRefreshOnFocus(_ sender: NSMenuItem) {
        var preferences = settings.commitPreferences
        preferences.refreshOnFocus.toggle()
        settings.saveCommitPreferences(preferences)
        sender.state = preferences.refreshOnFocus ? .on : .off
    }

    @objc private func toggleShowUntrackedFiles(_ sender: NSMenuItem) {
        showsUntrackedFiles.toggle()
        sender.state = showsUntrackedFiles ? .on : .off
        persistFileListPreferences()
        reloadFileTrees()
    }

    private func displayedFiles(for tableView: NSOutlineView) -> [ChangedFile] {
        var files = tableView === unstagedTable ? unstaged : staged
        if tableView === unstagedTable, !showsUntrackedFiles {
            files.removeAll { $0.changeType == .added }
        }
        let query = (tableView === unstagedTable ? unstagedFilter : stagedFilter)
            .stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            if let expression = try? NSRegularExpression(pattern: query, options: [.caseInsensitive]) {
                files = files.filter { file in
                    let range = NSRange(file.path.startIndex..<file.path.endIndex, in: file.path)
                    return expression.firstMatch(in: file.path, range: range) != nil
                }
            } else {
                files = []
            }
        }
        return files
    }

    private func rootNodes(for outlineView: NSOutlineView) -> [ChangedFileNode] {
        outlineView === unstagedTable ? unstagedRootNodes : stagedRootNodes
    }

    private func reloadFileTrees(preserveSelection: Bool = true) {
        let unstagedPaths = preserveSelection ? selectedPaths(in: unstagedTable) : []
        let stagedPaths = preserveSelection ? selectedPaths(in: stagedTable) : []
        unstagedRootNodes = ChangedFileListTreeBuilder.build(
            files: displayedFiles(for: unstagedTable),
            grouping: fileGroupingMode,
            isTreeMode: fileTreeMode,
            usesDenseTree: usesDenseTree,
            showsGroupNodesInFlatList: showsGroupNodesInFlatList
        )
        stagedRootNodes = ChangedFileListTreeBuilder.build(
            files: displayedFiles(for: stagedTable),
            grouping: fileGroupingMode,
            isTreeMode: fileTreeMode,
            usesDenseTree: usesDenseTree,
            showsGroupNodesInFlatList: showsGroupNodesInFlatList
        )
        for table in [unstagedTable, stagedTable] {
            table.reloadData()
            rootNodes(for: table).forEach { table.expandItem($0, expandChildren: true) }
        }
        fileCollapseButtons.forEach { button in
            let table = button.tag == 0 ? unstagedTable : stagedTable
            button.isEnabled = rootNodes(for: table).contains { !$0.children.isEmpty }
        }
        restoreSelection(paths: unstagedPaths, in: unstagedTable)
        restoreSelection(paths: stagedPaths, in: stagedTable)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? ChangedFileNode)?.children.count ?? rootNodes(for: outlineView).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? ChangedFileNode)?.children[index] ?? rootNodes(for: outlineView)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? ChangedFileNode)?.children.isEmpty == false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? ChangedFileNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("ChangedFile")
        let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? ChangedFileCellView) ?? ChangedFileCellView()
        cell.identifier = identifier
        cell.apply(node: node)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        GitExtensionsSelectionRowView()
    }

    private func selectedFiles(in outlineView: NSOutlineView) -> [ChangedFile] {
        var seen = Set<String>()
        return outlineView.selectedRowIndexes.flatMap { row -> [ChangedFile] in
            guard let node = outlineView.item(atRow: row) as? ChangedFileNode else { return [] }
            return node.descendantFiles
        }.filter { seen.insert($0.id).inserted }
    }

    private func selectedLeafFile(in outlineView: NSOutlineView) -> ChangedFile? {
        guard outlineView.selectedRowIndexes.count == 1,
              let row = outlineView.selectedRowIndexes.first,
              let node = outlineView.item(atRow: row) as? ChangedFileNode else { return nil }
        return node.file
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.identifier?.rawValue == "unstaged" || menu.identifier?.rawValue == "staged" else { return }
        let table = menu.identifier?.rawValue == "unstaged" ? unstagedTable : stagedTable
        if table.clickedRow >= 0, !table.selectedRowIndexes.contains(table.clickedRow) {
            table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
        }
        menu.removeAllItems()
        let files = selectedFiles(in: table)
        let mutation = NSMenuItem(
            title: table === unstagedTable ? "Stage selected" : "Unstage selected",
            action: table === unstagedTable ? #selector(stageSelected) : #selector(unstageSelected),
            keyEquivalent: ""
        )
        mutation.target = self
        mutation.isEnabled = !files.isEmpty && actionTask == nil
        menu.addItem(mutation)
        let all = NSMenuItem(
            title: table === unstagedTable ? "Stage all" : "Unstage all",
            action: table === unstagedTable ? #selector(stageEveryFile) : #selector(unstageEveryFile),
            keyEquivalent: ""
        )
        all.target = self
        all.isEnabled = !displayedFiles(for: table).isEmpty && actionTask == nil
        menu.addItem(all)
        menu.addItem(.separator())

        let open = NSMenuItem(title: "Open file", action: #selector(openContextFile(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = files.first?.path
        open.isEnabled = files.count == 1 && files.first?.changeType != .deleted
        menu.addItem(open)
        let reveal = NSMenuItem(title: "Show in Finder", action: #selector(revealContextFile(_:)), keyEquivalent: "")
        reveal.target = self
        reveal.representedObject = files.first?.path
        reveal.isEnabled = files.count == 1
        menu.addItem(reveal)
        let copy = NSMenuItem(title: "Copy path", action: #selector(copyContextPaths(_:)), keyEquivalent: "")
        copy.target = self
        copy.representedObject = files.map(\.path)
        copy.isEnabled = !files.isEmpty
        menu.addItem(copy)
        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "Refresh", action: #selector(refreshChanges), keyEquivalent: "")
        refresh.target = self
        refresh.isEnabled = actionTask == nil
        menu.addItem(refresh)
    }

    @objc private func openContextFile(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String,
              let repository = repositoryContext?.repository else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: repository.path).appendingPathComponent(path))
    }

    @objc private func revealContextFile(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String,
              let repository = repositoryContext?.repository else { return }
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: repository.path).appendingPathComponent(path)
        ])
    }

    @objc private func copyContextPaths(_ sender: NSMenuItem) {
        guard let paths = sender.representedObject as? [String], !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSOutlineView else { return }
        if table === unstagedTable, !table.selectedRowIndexes.isEmpty {
            stagedTable.deselectAll(nil)
        } else if table === stagedTable, !table.selectedRowIndexes.isEmpty {
            unstagedTable.deselectAll(nil)
        }
        updateButtonStates()
        loadSelectedDiff(from: table)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField,
              field === unstagedFilter || field === stagedFilter else { return }
        reloadFileTrees()
        updateButtonStates()
        let query = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty, (try? NSRegularExpression(pattern: query)) == nil {
            status.stringValue = "The file filter is not a valid regular expression."
        }
    }

    private func reloadChanges(preserveMessage: Bool = false, preferredPath: String? = nil) {
        loadTask?.cancel()
        diffLoadTask?.cancel()
        let preservedMessage = messageView.string
        let unstagedSelection = preferredPath ?? selectedPaths(in: unstagedTable).first
        let stagedSelection = preferredPath ?? selectedPaths(in: stagedTable).first
        commitButton.isEnabled = false
        commitAndPushButton.isEnabled = false
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                loadTask = nil
                updateButtonStates()
            }
            do {
                async let repositoryStateValue = source.loadRepositoryState()
                async let stateValue = source.loadCommitState(
                    historyLimit: settings.commitPreferences.historyLimit,
                    showOnlyMyMessages: showOnlyMyMessages,
                    rememberAmend: settings.commitPreferences.rememberAmendState
                )
                let repositoryState = try await repositoryStateValue
                let context = repositoryState.commitContext
                let artificial = RevisionCommitBuilder.artificialRevisions(headID: context.headID)
                guard let worktree = artificial.first(where: { $0.kind == .workingDirectory }),
                      let index = artificial.first(where: { $0.kind == .index }) else {
                    throw RepositoryDataSourceError.unavailable
                }
                async let worktreeDetails = source.loadRevisionDetails(for: worktree)
                async let indexDetails = source.loadRevisionDetails(for: index)
                let (worktreeValue, indexValue, loadedCommitState) = try await (worktreeDetails, indexDetails, stateValue)
                guard !Task.isCancelled else { return }
                repositoryContext = context
                networkContext = repositoryState.networkContext
                commitState = loadedCommitState
                if preserveMessage {
                    messageView.string = preservedMessage
                } else if draft == nil, activeSpecialKind == nil, !loadedCommitState.message.isEmpty {
                    messageView.string = loadedCommitState.message
                    usingTemplate = loadedCommitState.loadedTemplate != nil
                }
                if draft == nil, initialMode == .normal, loadedCommitState.rememberedAmend {
                    amend.state = .on
                    selectedCommitMode = .amend
                    if messageView.string.isEmpty { messageView.string = headMessage() }
                    modeChanged()
                }
                configureMessageMenu()
                configureTemplatesMenu()
                configureOptionsMenu()
                let branch = context.branches.first(where: \.isCurrent)?.name ?? "detached HEAD"
                commitWindow?.title = "Commit to \(branch) (\(context.repository.path))"
                unstaged = worktreeValue.files
                staged = indexValue.files
                reloadFileTrees(preserveSelection: false)
                restoreSelection(path: unstagedSelection, in: unstagedTable)
                restoreSelection(path: stagedSelection, in: stagedTable)
                updateStatus()
                setInitialFocusIfNeeded()
                if let loadError = loadedCommitState.messageLoadError,
                   loadError != lastShownMessageLoadError,
                   let commitWindow {
                    lastShownMessageLoadError = loadError
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Commit message could not be loaded"
                    alert.informativeText = loadError
                    alert.addButton(withTitle: "OK")
                    _ = await begin(alert, window: commitWindow)
                }
            } catch is CancellationError {
                return
            } catch {
                status.stringValue = error.localizedDescription
            }
        }
    }

    private func loadSelectedDiff(from table: NSOutlineView) {
        guard let file = selectedLeafFile(in: table), let context = repositoryContext else { return }
        let kind: Commit.Kind = table === unstagedTable ? .workingDirectory : .index
        guard let commit = RevisionCommitBuilder.artificialRevisions(headID: context.headID)
            .first(where: { $0.kind == kind }) else { return }
        diffLoadTask?.cancel()
        diffLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let diff = try await source.loadDiff(for: commit, file: file)
                guard !Task.isCancelled else { return }
                commitDiffView.apply(
                    file: file,
                    diff: diff,
                    direction: table === unstagedTable ? .stage : .unstage
                )
            } catch is CancellationError {
                return
            } catch {
                status.stringValue = error.localizedDescription
            }
        }
    }

    @objc private func stageSelected() {
        mutate(paths: mutationPaths(for: selectedFiles(in: unstagedTable)), stage: true)
    }

    @objc private func unstageSelected() {
        mutate(paths: mutationPaths(for: selectedFiles(in: stagedTable)), stage: false)
    }
    @objc private func stageEveryFile() { mutateAll(stage: true) }
    @objc private func unstageEveryFile() { mutateAll(stage: false) }

    private func mutate(paths: [String], stage: Bool) {
        guard !paths.isEmpty else { status.stringValue = "Select at least one file."; return }
        actionTask?.cancel()
        actionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { actionTask = nil; updateButtonStates() }
            do {
                status.stringValue = stage ? "Staging…" : "Unstaging…"
                _ = try await (stage ? source.stage(paths: paths) : source.unstage(paths: paths))
                reloadChanges(preserveMessage: true, preferredPath: paths.first)
            } catch { await showOperationError(error, title: stage ? "Stage failed" : "Unstage failed") }
        }
    }

    private func mutateAll(stage: Bool) {
        let filter = stage ? unstagedFilter.stringValue : stagedFilter.stringValue
        let visibleFiles = displayedFiles(for: stage ? unstagedTable : stagedTable)
        let visiblePaths = mutationPaths(for: visibleFiles)
        let preferredPath = visibleFiles.first?.path
        actionTask?.cancel()
        actionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { actionTask = nil; updateButtonStates() }
            do {
                status.stringValue = stage ? "Staging all…" : "Unstaging all…"
                if filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    _ = try await (stage ? source.stageAll() : source.unstageAll())
                } else {
                    guard !visiblePaths.isEmpty else { throw RepositoryMutationError.noPaths }
                    _ = try await (stage ? source.stage(paths: visiblePaths) : source.unstage(paths: visiblePaths))
                }
                if stage { unstagedFilter.stringValue = "" } else { stagedFilter.stringValue = "" }
                reloadChanges(preserveMessage: true, preferredPath: preferredPath)
            } catch { await showOperationError(error, title: stage ? "Stage failed" : "Unstage failed") }
        }
    }

    private func applySelectedHunk(lineID: String, direction: RepositoryHunkDirection) {
        guard let selection = commitDiffView.currentSelection(lineID: lineID, direction: direction) else { return }
        actionTask?.cancel()
        actionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { actionTask = nil; updateButtonStates() }
            do {
                status.stringValue = direction == .stage ? "Staging selected hunk…" : "Unstaging selected hunk…"
                _ = try await source.applyHunk(selection)
                reloadChanges(preserveMessage: true, preferredPath: selection.file.path)
            } catch {
                commitDiffView.allowPatching()
                await showOperationError(error, title: direction == .stage ? "Stage hunk failed" : "Unstage hunk failed")
            }
        }
    }

    private func applySelectedLines(lineIDs: Set<String>, direction: RepositoryHunkDirection) {
        guard let selection = commitDiffView.currentLineSelection(lineIDs: lineIDs, direction: direction) else { return }
        actionTask?.cancel()
        actionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { actionTask = nil; updateButtonStates() }
            do {
                status.stringValue = direction == .stage ? "Staging selected line(s)…" : "Unstaging selected line(s)…"
                _ = try await source.applyLines(selection)
                reloadChanges(preserveMessage: true, preferredPath: selection.file.path)
            } catch {
                commitDiffView.allowPatching()
                await showOperationError(error, title: direction == .stage ? "Stage lines failed" : "Unstage lines failed")
            }
        }
    }

    private func addSelectedDiffTextToMessage(_ text: String) {
        guard !text.isEmpty, messageView.isEditable else { return }
        let selection = messageView.selectedRange()
        let insertion = selection.length == 0 ? text + "\n" : text
        messageView.insertText(insertion, replacementRange: selection)
        commitWindow?.makeFirstResponder(messageView)
    }

    @objc private func modeChanged() {
        amendPanel.isHidden = selectedCommitMode == .normal
        stageAll.isEnabled = selectedCommitMode != .amendMessageOnly
        updateButtonStates()
    }

    @objc private func amendChanged() {
        if amend.state == .off { resetAuthor.state = .off }
        selectedCommitMode = amend.state == .on ? .amend : .normal
        if amend.state == .on, messageView.string.isEmpty { messageView.string = headMessage() }
        modeChanged()
    }

    @objc private func modifySpecialCommitMessage() {
        activeSpecialKind = nil
        applySpecialCommitState()
        commitWindow?.makeFirstResponder(messageView)
    }

    private func applySpecialCommitState() {
        let isSpecial = activeSpecialKind != nil
        messageView.isEditable = !isSpecial
        messageMenu.isEnabled = !isSpecial
        templatesMenu.isEnabled = !isSpecial
        amend.isHidden = isSpecial
        amendPanel.isHidden = isSpecial || currentCommitMode == .normal
        modifyCommitMessageButton.isHidden = !isSpecial
    }

    @objc private func refreshChanges() { reloadChanges(preserveMessage: true) }

    @objc private func stashStagedChanges() {
        guard !staged.isEmpty else { status.stringValue = "There are no staged changes to stash."; return }
        actionTask?.cancel()
        actionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { actionTask = nil; updateButtonStates() }
            do {
                status.stringValue = "Stashing staged changes…"
                _ = try await source.createStash(RepositoryStashCreateRequest(message: "", includeUntracked: false, keepIndex: false, stagedOnly: true))
                reloadChanges(preserveMessage: true)
            } catch { await showOperationError(error, title: "Stash staged changes failed") }
        }
    }

    @objc private func commit() {
        if !(commitState?.mutationState.conflictedPaths.isEmpty ?? true) {
            resolveConflicts()
            return
        }
        performCommit(pushAfter: false)
    }

    @objc private func commitAndPush() {
        performCommit(pushAfter: true)
    }

    private func performCommit(pushAfter: Bool) {
        guard actionTask == nil, let commitWindow else { return }
        if pushAfter,
           currentCommitMode == .normal,
           staged.isEmpty,
           unstaged.isEmpty,
           allowEmpty.state == .off {
            openPush(context: networkContext, forceWithLease: false)
            return
        }
        actionTask = Task { @MainActor [weak self, weak commitWindow] in
            guard let self, let commitWindow else { return }
            defer { actionTask = nil; updateButtonStates() }
            do {
                let message = messageView.string
                guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !(usingTemplate && message == commitState?.loadedTemplate) else {
                    status.stringValue = "Please enter a commit message."
                    commitWindow.makeFirstResponder(messageView)
                    return
                }
                let authorValue = author.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !authorValue.isEmpty,
                   authorValue.range(of: #"^.+\s<[^<>]+>$"#, options: .regularExpression) == nil {
                    status.stringValue = "Author must use the format Name <email@example.com>."
                    commitWindow.makeFirstResponder(author)
                    return
                }
                if currentCommitMode != .normal,
                   settings.commitPreferences.confirmAmend,
                   !(await confirmAmend(window: commitWindow)) {
                    return
                }
                if commitState?.mutationState.currentBranch == nil,
                   settings.commitPreferences.confirmDetachedHead,
                   !(await resolveDetachedHead(window: commitWindow)) {
                    return
                }

                var shouldStageAll = stageAll.state == .on
                var shouldAllowEmpty = allowEmpty.state == .on
                if currentCommitMode == .normal, staged.isEmpty, !shouldStageAll, !shouldAllowEmpty {
                    if commitState?.isMergeCommit == true {
                        guard await confirmEmptyMerge(window: commitWindow) else { return }
                        shouldAllowEmpty = true
                    } else {
                    guard let choice = await noStagedChoice(window: commitWindow) else { return }
                    switch choice {
                    case .stage:
                        let filtered = mutationPaths(for: displayedFiles(for: unstagedTable))
                        if !unstagedFilter.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            guard !filtered.isEmpty else { throw RepositoryMutationError.noPaths }
                            _ = try await source.stage(paths: filtered)
                            shouldStageAll = false
                        } else {
                            shouldStageAll = true
                        }
                    case .empty:
                        shouldAllowEmpty = true
                    }
                    }
                }

                let validationContext = validationContext(for: message)
                let issues = CommitMessageValidator.issues(
                    in: message,
                    preferences: settings.commitPreferences.validation,
                    skipRegularExpression: validationContext.skipRegularExpression,
                    regularExpressionText: validationContext.regularExpressionText
                )
                for issue in issues {
                    if !(await confirmValidationIssue(issue, window: commitWindow)) { return }
                }

                let request = RepositoryCommitRequest(
                    message: message,
                    mode: currentCommitMode,
                    stageAllBeforeCommit: shouldStageAll,
                    allowEmpty: shouldAllowEmpty,
                    signOff: signOff.state == .on,
                    author: authorValue.isEmpty ? nil : authorValue,
                    resetAuthor: resetAuthor.state == .on,
                    noVerify: noVerify,
                    gpgSigning: gpgSigning,
                    messageEncoding: commitState?.commitEncoding,
                    usingTemplate: usingTemplate,
                    ensureSecondLineEmpty: settings.commitPreferences.ensureSecondLineEmpty
                )
                commitButton.isEnabled = false
                commitAndPushButton.isEnabled = false
                status.stringValue = currentCommitMode == .normal ? "Committing…" : "Amending…"
                let wasAmend = currentCommitMode != .normal
                let result = try await source.commit(request)
                onRepositoryChanged(result.selectedCommitID)
                let repositoryState = try await source.loadRepositoryState()
                repositoryContext = repositoryState.commitContext
                networkContext = repositoryState.networkContext
                var preferences = settings.commitPreferences
                preferences.lastCommitMessage = message
                settings.saveCommitPreferences(preferences)
                noVerify = false
                usingTemplate = false
                activeSpecialKind = nil
                applySpecialCommitState()
                status.stringValue = result.message

                if pushAfter {
                    openPush(
                        context: networkContext,
                        forceWithLease: (wasAmend || historyWasSoftReset) && preferences.forceWithLeaseAfterAmend
                    )
                }
                historyWasSoftReset = false
                let newState = try await source.loadMutationState()
                if preferences.closeAfterCommit || (preferences.closeAfterLastCommit && !newState.isDirty) {
                    if pushAfter, pushWindowController != nil {
                        persistDraftOnClose = false
                        closeWhenPushCompletes = true
                    } else {
                        closeAfterSuccessfulCommit()
                    }
                } else {
                    messageView.string = ""
                    amend.state = .off
                    selectedCommitMode = .normal
                    modeChanged()
                    reloadChanges()
                }
            } catch is CancellationError {
                status.stringValue = "Commit cancelled."
                reloadChanges(preserveMessage: true)
                return
            } catch {
                status.stringValue = error.localizedDescription
                await showOperationError(error, title: "Commit failed")
                reloadChanges(preserveMessage: true)
            }
        }
    }

    private enum NoStagedChoice { case stage, empty }

    private func validationContext(for message: String) -> (skipRegularExpression: Bool, regularExpressionText: String?) {
        switch activeSpecialKind {
        case .fixup, .squash:
            return (true, nil)
        case .amendAutosquash:
            let lines = message.components(separatedBy: .newlines)
            if lines.count > 2, lines[1].isEmpty {
                return (false, lines.dropFirst(2).joined(separator: "\n"))
            }
            return (false, nil)
        case nil:
            return (false, nil)
        }
    }

    private var currentCommitMode: RepositoryCommitMode {
        selectedCommitMode
    }

    private func confirmAmend(window: NSWindow) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Amend commit"
        alert.informativeText = "Amending rewrites the current commit. Do not amend a commit that has already been published."
        alert.addButton(withTitle: "Amend")
        alert.addButton(withTitle: "Cancel")
        return await begin(alert, window: window) == .alertFirstButtonReturn
    }

    private func noStagedChoice(window: NSWindow) async -> NoStagedChoice? {
        let alert = NSAlert()
        alert.messageText = "There are no staged changes"
        let filtered = !unstagedFilter.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        alert.informativeText = unstaged.isEmpty
            ? "Create an empty commit or cancel."
            : "Stage \(filtered ? "the filtered changes" : "all changes") and commit, create an empty commit, or cancel."
        alert.addButton(withTitle: unstaged.isEmpty ? "Commit Empty" : (filtered ? "Stage Filtered and Commit" : "Stage All and Commit"))
        if !unstaged.isEmpty { alert.addButton(withTitle: "Commit Empty") }
        alert.addButton(withTitle: "Cancel")
        let response = await begin(alert, window: window)
        if unstaged.isEmpty { return response == .alertFirstButtonReturn ? .empty : nil }
        if response == .alertFirstButtonReturn { return .stage }
        if response == .alertSecondButtonReturn { return .empty }
        return nil
    }

    private func confirmEmptyMerge(window: NSWindow) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Commit an empty merge?"
        alert.informativeText = "No files are staged. The merge itself can still be committed, but confirm that no files were accidentally left unstaged."
        alert.addButton(withTitle: "Commit Merge")
        alert.addButton(withTitle: "Cancel")
        return await begin(alert, window: window) == .alertFirstButtonReturn
    }

    private func confirmValidationIssue(_ issue: CommitMessageValidationIssue, window: NSWindow) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Commit message validation"
        alert.informativeText = issue.localizedDescription
        alert.addButton(withTitle: "Commit Anyway")
        alert.addButton(withTitle: "Edit Message")
        return await begin(alert, window: window) == .alertFirstButtonReturn
    }

    private func resolveDetachedHead(window: NSWindow) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "HEAD is detached"
        alert.informativeText = "The new commit will not belong to a branch unless you create or checkout one first."
        alert.addButton(withTitle: "Continue Detached")
        alert.addButton(withTitle: "Create Branch…")
        alert.addButton(withTitle: "Checkout Branch…")
        alert.addButton(withTitle: "Cancel")
        switch await begin(alert, window: window) {
        case .alertFirstButtonReturn:
            return true
        case .alertSecondButtonReturn:
            return await promptAndCreateBranch(window: window)
        case .alertThirdButtonReturn:
            return await promptAndCheckoutBranch(window: window)
        default:
            return false
        }
    }

    private func openPush(context: RepositoryNetworkContext?, forceWithLease: Bool) {
        guard let source = pushSource, let context else {
            status.stringValue = "Push is unavailable for this repository."
            return
        }
        if let pushWindowController {
            pushWindowController.window?.makeKeyAndOrderFront(nil)
            return
        }
        pushWindowController = PushDialog.present(
            source: source,
            context: context,
            initialBranch: context.branches.first(where: \.isCurrent)?.name,
            executeImmediately: true,
            initialForceWithLease: forceWithLease,
            onRepositoryChanged: { [weak self] selected in
                self?.onRepositoryChanged(selected)
                self?.reloadChanges(preserveMessage: true)
            },
            onCompletion: { [weak self] completed in
                guard let self else { return }
                if completed, closeWhenPushCompletes {
                    closeAfterSuccessfulCommit()
                } else if !completed, closeWhenPushCompletes {
                    closeWhenPushCompletes = false
                    persistDraftOnClose = true
                    messageView.string = ""
                    amend.state = .off
                    selectedCommitMode = .normal
                    modeChanged()
                    reloadChanges()
                }
            },
            onClose: { [weak self] in
                guard let self else { return }
                pushWindowController = nil
            }
        )
    }

    @objc private func resetUnstagedChanges() { confirmReset(scope: .worktree) }
    @objc private func resetAllChanges() { confirmReset(scope: .all) }

    private func confirmReset(scope: RepositoryResetChangesScope) {
        guard let commitWindow else { return }
        actionTask?.cancel()
        actionTask = Task { @MainActor [weak self, weak commitWindow] in
            guard let self, let commitWindow else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = scope == .worktree ? "Reset unstaged changes" : "Reset all changes"
            alert.informativeText = scope == .worktree
                ? "Discard tracked working-tree changes? This cannot be undone."
                : "Reset the index and working tree to HEAD? This cannot be undone."
            alert.addButton(withTitle: "Reset")
            alert.addButton(withTitle: "Cancel")
            let clean = NSButton(checkboxWithTitle: "Delete new files and directories", target: nil, action: nil)
            clean.state = .off
            clean.isEnabled = commitState?.mutationState.hasUntrackedFiles == true
            alert.accessoryView = clean
            guard await begin(alert, window: commitWindow) == .alertFirstButtonReturn else { actionTask = nil; return }
            do {
                let result = try await source.resetChanges(RepositoryResetChangesRequest(scope: scope, deleteUntracked: clean.state == .on))
                onRepositoryChanged(result.selectedCommitID)
                reloadChanges(preserveMessage: true)
            } catch { await showOperationError(error, title: "Reset failed") }
            actionTask = nil
        }
    }

    @objc private func resetSoft() {
        guard let commitWindow else { return }
        actionTask?.cancel()
        actionTask = Task { @MainActor [weak self, weak commitWindow] in
            guard let self, let commitWindow else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Reset soft"
            alert.informativeText = "Move HEAD to its parent and leave the removed commit's changes staged?"
            alert.addButton(withTitle: "Reset Soft")
            alert.addButton(withTitle: "Cancel")
            guard await begin(alert, window: commitWindow) == .alertFirstButtonReturn else { actionTask = nil; return }
            do {
                let result = try await source.resetSoftToParent()
                onRepositoryChanged(result.selectedCommitID)
                historyWasSoftReset = true
                amend.state = .off; selectedCommitMode = .normal; modeChanged()
                reloadChanges(preserveMessage: true)
            } catch { await showOperationError(error, title: "Reset soft failed") }
            actionTask = nil
        }
    }

    @objc private func createBranch() {
        guard let commitWindow else { return }
        actionTask = Task { @MainActor [weak self, weak commitWindow] in
            guard let self, let commitWindow else { return }
            _ = await promptAndCreateBranch(window: commitWindow)
            actionTask = nil
        }
    }

    private func promptAndCreateBranch(window: NSWindow) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Create branch"
        alert.informativeText = "Create and checkout a local branch at HEAD."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: "")
        field.placeholderString = "Branch name"
        field.frame.size.width = 320
        alert.accessoryView = field
        guard await begin(alert, window: window) == .alertFirstButtonReturn else { return false }
        do {
            let result = try await source.createBranch(named: field.stringValue)
            onRepositoryChanged(result.selectedCommitID)
            reloadChanges(preserveMessage: true)
            return true
        } catch {
            await showOperationError(error, title: "Create branch failed")
            return false
        }
    }

    private func promptAndCheckoutBranch(window: NSWindow) async -> Bool {
        let branches = (repositoryContext?.branches ?? []).filter { !$0.isRemote }
        guard !branches.isEmpty else { return await promptAndCreateBranch(window: window) }
        let alert = NSAlert()
        alert.messageText = "Checkout branch"
        alert.addButton(withTitle: "Checkout")
        alert.addButton(withTitle: "Cancel")
        let popup = NSPopUpButton()
        popup.addItems(withTitles: branches.map(\.name))
        popup.frame.size.width = 320
        alert.accessoryView = popup
        guard await begin(alert, window: window) == .alertFirstButtonReturn,
              let name = popup.titleOfSelectedItem else { return false }
        do {
            let result = try await source.checkout(RepositoryCheckoutRequest(target: .localBranch(name), localChanges: .keep))
            onRepositoryChanged(result.selectedCommitID)
            reloadChanges(preserveMessage: true)
            return true
        } catch {
            await showOperationError(error, title: "Checkout failed")
            return false
        }
    }

    private func resolveConflicts() {
        guard let commitWindow else { return }
        actionTask = Task { @MainActor [weak self, weak commitWindow] in
            guard let self, let commitWindow else { return }
            if await WorkflowManagementDialogs.resolveConflicts(source: source, window: commitWindow) {
                onRepositoryChanged(nil)
            }
            actionTask = nil
            reloadChanges(preserveMessage: true)
        }
    }

    private func selectedPaths(in table: NSOutlineView) -> [String] {
        selectedFiles(in: table).map(\.path)
    }

    private func mutationPaths(for files: [ChangedFile]) -> [String] {
        var seen = Set<String>()
        return files.flatMap { [$0.oldPath, $0.path].compactMap { $0 } }
            .filter { seen.insert($0).inserted }
    }

    private func restoreSelection(path: String?, in table: NSOutlineView) {
        guard let path else { return }
        restoreSelection(paths: [path], in: table)
    }

    private func restoreSelection(paths: [String], in table: NSOutlineView) {
        let requested = Set(paths)
        guard !requested.isEmpty else { return }
        var rows = IndexSet()
        for row in 0..<table.numberOfRows {
            guard let file = (table.item(atRow: row) as? ChangedFileNode)?.file,
                  requested.contains(file.path) else { continue }
            rows.insert(row)
        }
        guard !rows.isEmpty else { return }
        table.selectRowIndexes(rows, byExtendingSelection: false)
        if let row = rows.first { table.scrollRowToVisible(row) }
    }

    private func updateButtonStates() {
        let busy = actionTask != nil || loadTask != nil
        let conflicts = !(commitState?.mutationState.conflictedPaths.isEmpty ?? true)
        commitButton.title = conflicts ? "Solve conflicts" : "Commit"
        commitButton.isEnabled = !busy
        commitAndPushButton.title = currentCommitMode == .normal && staged.isEmpty && unstaged.isEmpty ? "Push" : "Commit & push"
        commitAndPushButton.isEnabled = !busy && pushSource != nil && !conflicts
        stageSelectedButton.isEnabled = !busy && !selectedFiles(in: unstagedTable).isEmpty
        unstageSelectedButton.isEnabled = !busy && !selectedFiles(in: stagedTable).isEmpty
        stageAllFilesButton.isEnabled = !busy && !displayedFiles(for: unstagedTable).isEmpty
        unstageAllFilesButton.isEnabled = !busy && !displayedFiles(for: stagedTable).isEmpty
        stashStagedButton.isEnabled = !busy && !staged.isEmpty
        resetUnstagedButton.isEnabled = !busy && !unstaged.isEmpty
        resetAllButton.isEnabled = !busy && (!unstaged.isEmpty || !staged.isEmpty)
        let currentHead = head
        resetSoftButton.isEnabled = !busy && currentHead?.parentIDs.isEmpty == false
        cancelButton.title = actionTask == nil ? "Cancel" : "Abort"
    }

    private func perform(shortcut: CommitKeyboardShortcut) -> Bool {
        guard actionTask == nil else { return false }
        switch shortcut {
        case .unstaged:
            commitWindow?.makeFirstResponder(unstagedTable)
        case .diff:
            commitWindow?.makeFirstResponder(commitDiffView.focusView)
        case .staged:
            commitWindow?.makeFirstResponder(stagedTable)
        case .message:
            commitWindow?.makeFirstResponder(messageView)
        case .stageAll:
            stageEveryFile()
        case .filter:
            commitWindow?.makeFirstResponder(unstagedTable.selectedRow >= 0 ? unstagedFilter : stagedFilter)
        case .refresh:
            refreshChanges()
        case .createBranch:
            createBranch()
        case .nextFile:
            moveFileSelection(backwards: false)
        case .previousFile:
            moveFileSelection(backwards: true)
        case .addSelectionToMessage:
            guard let responder = commitWindow?.firstResponder as? NSView,
                  responder === commitDiffView.focusView || responder.isDescendant(of: commitDiffView),
                  commitDiffView.addSelectionToMessage() else { return false }
        case .conventionalType:
            insertConventionalPrefixItem("feat")
        case .conventionalScope:
            promptForConventionalScope()
        }
        return true
    }

    private func moveFileSelection(backwards: Bool) {
        let responder = commitWindow?.firstResponder as? NSView
        let stagedHasFocus = responder.map { $0 === stagedTable || $0.isDescendant(of: stagedTable) } == true
        let messageHasFocus = responder.map { $0 === messageView || $0.isDescendant(of: messageView) } == true
        let table = stagedHasFocus || messageHasFocus || (unstagedTable.selectedRow < 0 && stagedTable.selectedRow >= 0)
            ? stagedTable
            : unstagedTable
        let rows = (0..<table.numberOfRows).filter {
            (table.item(atRow: $0) as? ChangedFileNode)?.file != nil
        }
        guard !rows.isEmpty else { return }
        let currentIndex = rows.firstIndex(of: table.selectedRow)
        let row: Int
        if let currentIndex {
            let next = backwards
                ? (currentIndex == 0 ? rows.count - 1 : currentIndex - 1)
                : (currentIndex + 1 == rows.count ? 0 : currentIndex + 1)
            row = rows[next]
        } else {
            row = backwards ? rows.last! : rows[0]
        }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        commitWindow?.makeFirstResponder(table)
    }

    private func insertConventionalPrefixItem(_ keyword: String) {
        if messageView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messageView.string = "\(keyword): "
        } else {
            messageView.string = "\(keyword): \(messageView.string)"
        }
        commitWindow?.makeFirstResponder(messageView)
        messageView.setSelectedRange(NSRange(location: (messageView.string as NSString).length, length: 0))
    }

    private func promptForConventionalScope() {
        guard let commitWindow else { return }
        actionTask = Task { @MainActor [weak self, weak commitWindow] in
            guard let self, let commitWindow else { return }
            defer { actionTask = nil; updateButtonStates() }
            let alert = NSAlert()
            alert.messageText = "Conventional Commit"
            alert.informativeText = "Enter an optional scope for a feat commit."
            alert.addButton(withTitle: "Insert")
            alert.addButton(withTitle: "Cancel")
            let field = NSTextField(string: "")
            field.placeholderString = "scope"
            field.frame.size.width = 260
            alert.accessoryView = field
            guard await begin(alert, window: commitWindow) == .alertFirstButtonReturn else { return }
            let scope = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = scope.isEmpty ? "feat: " : "feat(\(scope)): "
            if messageView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                messageView.string = prefix
            } else {
                messageView.string = prefix + messageView.string
            }
            commitWindow.makeFirstResponder(messageView)
        }
    }

    private func updateStatus() {
        let branch = commitState?.mutationState.currentBranch ?? "detached HEAD"
        let encoding = commitState?.commitEncoding ?? "UTF-8"
        let committer = commitState?.committer ?? "Loading author…"
        status.stringValue = "\(committer)   \(branch)   \(staged.count) staged / \(unstaged.count) unstaged   \(encoding)"
    }

    private func setInitialFocusIfNeeded() {
        guard !didInitialFocus, let commitWindow else { return }
        didInitialFocus = true
        if activeSpecialKind != nil {
            commitWindow.makeFirstResponder(messageView)
            return
        }
        if !unstaged.isEmpty {
            commitWindow.makeFirstResponder(unstagedTable)
            if let row = firstFileRow(in: unstagedTable) {
                unstagedTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        } else if !staged.isEmpty {
            commitWindow.makeFirstResponder(messageView)
            if let row = firstFileRow(in: stagedTable) {
                stagedTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        } else {
            amend.state = .on
            selectedCommitMode = .amend
            modeChanged()
            commitWindow.makeFirstResponder(messageView)
        }
    }

    func textDidChange(_ notification: Notification) {
        if !isFormattingMessage {
            let original = messageView.string
            let formatted = CommitMessageAutoFormatter.format(
                original,
                preferences: settings.commitPreferences.validation
            )
            if formatted != original {
                let oldSelection = messageView.selectedRange()
                let lengthDelta = (formatted as NSString).length - (original as NSString).length
                isFormattingMessage = true
                messageView.string = formatted
                messageView.setSelectedRange(NSRange(
                    location: min((formatted as NSString).length, max(0, oldSelection.location + lengthDelta)),
                    length: 0
                ))
                isFormattingMessage = false
            }
        }
        usingTemplate = usingTemplate && messageView.string == commitState?.loadedTemplate
        updateLineAndColumn()
    }

    func textView(
        _ textView: NSTextView,
        completions words: [String],
        forPartialWordRange charRange: NSRange,
        indexOfSelectedItem index: UnsafeMutablePointer<Int>?
    ) -> [String] {
        var completions = Set(words)
        completions.formUnion([
            "Co-authored-by: ",
            "Signed-off-by: ",
            "BREAKING CHANGE: ",
            "Reviewed-by: ",
            "Tested-by: "
        ])
        for file in unstaged + staged {
            for path in [file.path, file.oldPath].compactMap({ $0 }) {
                let name = (path as NSString).lastPathComponent
                completions.insert(name)
                completions.insert((name as NSString).deletingPathExtension)
            }
        }
        return completions.filter { !$0.isEmpty }.sorted()
    }

    func textViewDidChangeSelection(_ notification: Notification) { updateLineAndColumn() }

    func textDidBeginEditing(_ notification: Notification) {
        if settings.commitPreferences.selectStagedOnMessageFocus,
           stagedTable.selectedRow < 0,
           !staged.isEmpty,
           let row = firstFileRow(in: stagedTable) {
            stagedTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    private func firstFileRow(in table: NSOutlineView) -> Int? {
        (0..<table.numberOfRows).first {
            (table.item(atRow: $0) as? ChangedFileNode)?.file != nil
        }
    }

    private func updateLineAndColumn() {
        let location = min(messageView.selectedRange().location, (messageView.string as NSString).length)
        let prefix = (messageView.string as NSString).substring(to: location)
        let lines = prefix.components(separatedBy: "\n")
        updateStatus()
        let column = (lines.last.map { ($0 as NSString).length } ?? 0) + 1
        status.stringValue += "   Ln \(lines.count), Col \(column)"
    }

    private func showOperationError(_ error: Error, title: String) async {
        status.stringValue = error.localizedDescription
        guard let commitWindow else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        _ = await begin(alert, window: commitWindow)
    }

    private func begin(_ alert: NSAlert, window: NSWindow) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    @objc private func cancel() {
        if let actionTask {
            status.stringValue = "Cancelling…"
            actionTask.cancel()
        } else {
            commitWindow?.performClose(nil)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let actionTask else { return true }
        status.stringValue = "Cancelling…"
        actionTask.cancel()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        saveGeometry()
        if persistDraftOnClose {
            let message = messageView.string
            let amendState = currentCommitMode != .normal
            let remember = settings.commitPreferences.rememberAmendState
            let encoding = commitState?.commitEncoding
            Task { try? await source.saveCommitDraft(message: message, amend: amendState, rememberAmend: remember, encoding: encoding) }
        }
        finishClose()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard didBecomeKeyOnce else { didBecomeKeyOnce = true; return }
        if settings.commitPreferences.refreshOnFocus, actionTask == nil {
            reloadChanges(preserveMessage: true)
        }
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let visibleFrame = window.screen?.visibleFrame else { return }
        window.maxSize = visibleFrame.size
    }

    private func saveGeometry() {
        guard let commitWindow else { return }
        var preferences = settings.commitPreferences
        preferences.windowWidth = commitWindow.contentLayoutRect.width
        preferences.windowHeight = commitWindow.contentLayoutRect.height
        if mainSplit.subviews.count > 1 { preferences.mainDivider = mainSplit.subviews[0].frame.width }
        if fileSplit.subviews.count > 1 { preferences.fileDivider = fileSplit.subviews[0].frame.height }
        if contentSplit.subviews.count > 1 { preferences.contentDivider = contentSplit.subviews[0].frame.height }
        if messageSplit.subviews.count > 1 { preferences.commandDivider = messageSplit.subviews[0].frame.width }
        settings.saveCommitPreferences(preferences)
    }

    private func closeAfterSuccessfulCommit() {
        persistDraftOnClose = false
        actionTask = nil
        commitWindow?.performClose(nil)
    }

    private func finishClose() {
        guard !didComplete else { return }
        didComplete = true
        onClose?()
    }
}

@MainActor
private final class CommitDiffView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let tableView = NSTableView()
    private let trackingView = DiffTrackingView()
    private let hoverToolbar = DiffViewerToolbar(showsNonPrintingCharacters: false, showsSyntaxHighlighting: true)
    private var presentations: [DiffLinePresentation] = []
    private var gutterMetrics = DiffGutterMetrics.empty
    private var caretRow = -1
    private var showsNonPrintingCharacters = false
    private var showsSyntaxHighlighting = true
    private var file: ChangedFile?
    private var diff: FileDiff?
    private var direction: RepositoryHunkDirection = .stage
    private var patchingAllowed = true
    var onApplyHunk: ((String, RepositoryHunkDirection) -> Void)?
    var onApplyLines: ((Set<String>, RepositoryHunkDirection) -> Void)?
    var onAddSelectedText: ((String) -> Void)?
    var focusView: NSView { tableView }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        trackingView.onPointerPresenceChanged = { [weak self] isPresent in
            self?.hoverToolbar.isHidden = !isPresent
        }
        hoverToolbar.onAction = { [weak self] action, state in
            self?.performToolbarAction(action, state: state)
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("CommitDiff"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = BrowserMetrics.diffRowHeight
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .textBackgroundColor
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.dataSource = self
        tableView.delegate = self
        let menu = NSMenu(title: "Diff actions")
        let lines = NSMenuItem(title: "Stage selected line(s)", action: #selector(applyLines), keyEquivalent: "")
        lines.target = self
        let hunk = NSMenuItem(title: "Stage selected hunk", action: #selector(applyHunk), keyEquivalent: "")
        hunk.target = self
        menu.addItem(lines)
        menu.addItem(hunk)
        menu.addItem(.separator())
        let addToMessage = NSMenuItem(title: "Add selection to commit message", action: #selector(addSelectedText), keyEquivalent: "")
        addToMessage.target = self
        menu.addItem(addToMessage)
        tableView.menu = menu

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        trackingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(trackingView)
        trackingView.addSubview(scrollView)
        hoverToolbar.install(in: trackingView)
        NSLayoutConstraint.activate([
            trackingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            trackingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            trackingView.topAnchor.constraint(equalTo: topAnchor),
            trackingView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: trackingView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trackingView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: trackingView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: trackingView.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func apply(file: ChangedFile, diff: FileDiff?, direction: RepositoryHunkDirection) {
        self.file = file
        self.diff = diff
        self.direction = direction
        patchingAllowed = true
        presentations = DiffLinePresentation.build(from: diff?.lines ?? [])
        gutterMetrics = DiffGutterMetrics(lines: diff?.lines ?? [])
        caretRow = -1
        hoverToolbar.toolTip = "\(file.path) — \(file.changeType.description), +\(file.additions) −\(file.deletions)"
        tableView.reloadData()
        if !presentations.isEmpty {
            tableView.scrollRowToVisible(0)
        }
        toolTip = diff == nil ? "No diff is available for \(file.path)." : file.path
        tableView.menu?.items.first?.title = direction == .stage ? "Stage selected line(s)" : "Unstage selected line(s)"
        tableView.menu?.items[1].title = direction == .stage ? "Stage selected hunk" : "Unstage selected hunk"
    }

    func currentSelection(lineID: String, direction: RepositoryHunkDirection) -> RepositoryHunkSelection? {
        guard patchingAllowed, self.direction == direction, let file, let diff else { return nil }
        patchingAllowed = false
        return RepositoryHunkSelection(file: file, diff: diff, lineID: lineID, direction: direction)
    }

    func currentLineSelection(lineIDs: Set<String>, direction: RepositoryHunkDirection) -> RepositoryLineSelection? {
        guard patchingAllowed, self.direction == direction, let file, let diff, !lineIDs.isEmpty else { return nil }
        patchingAllowed = false
        return RepositoryLineSelection(file: file, diff: diff, lineIDs: lineIDs, direction: direction)
    }

    func allowPatching() { patchingAllowed = true }

    @objc private func applyLines() {
        guard patchingAllowed else { return }
        let ids = Set(tableView.selectedRowIndexes.compactMap { row -> String? in
            guard presentations.indices.contains(row) else { return nil }
            let line = presentations[row].line
            return line.kind == .addition || line.kind == .deletion ? line.id : nil
        })
        guard !ids.isEmpty else { return }
        onApplyLines?(ids, direction)
    }

    @objc private func applyHunk() {
        guard patchingAllowed,
              let row = tableView.selectedRowIndexes.first,
              presentations.indices.contains(row) else { return }
        onApplyHunk?(presentations[row].line.id, direction)
    }

    @objc private func addSelectedText() {
        _ = addSelectionToMessage()
    }

    @discardableResult
    func addSelectionToMessage() -> Bool {
        let text = tableView.selectedRowIndexes.compactMap { row -> String? in
            guard presentations.indices.contains(row) else { return nil }
            let line = presentations[row].line
            guard line.kind != .header, line.kind != .hunk else { return nil }
            return line.text
        }.joined(separator: "\n")
        guard !text.isEmpty else { return false }
        onAddSelectedText?(text)
        return true
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        presentations.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard presentations.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("CommitDiffLine")
        let cell: DiffLineCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? DiffLineCellView {
            cell = reused
        } else {
            cell = DiffLineCellView()
            cell.identifier = identifier
        }
        cell.apply(
            presentation: presentations[row],
            gutterMetrics: gutterMetrics,
            showsNonPrintingCharacters: showsNonPrintingCharacters,
            showsSyntaxHighlighting: showsSyntaxHighlighting
        )
        return cell
    }

    private func performToolbarAction(_ action: String, state: NSControl.StateValue) {
        switch action {
        case "Next change": navigateToChange(forward: true)
        case "Previous change": navigateToChange(forward: false)
        case "Show nonprinting characters":
            showsNonPrintingCharacters = state == .on
            reloadRenderedLines()
        case "Show syntax highlighting":
            showsSyntaxHighlighting = state == .on
            reloadRenderedLines()
        default:
            BrowserCommandCenter.perform(.unavailable(action))
        }
    }

    private func navigateToChange(forward: Bool) {
        let starts = presentations.indices.filter { index in
            let kind = presentations[index].line.kind
            guard kind == .addition || kind == .deletion else { return false }
            guard index > 0 else { return true }
            let previous = presentations[index - 1].line.kind
            return previous != .addition && previous != .deletion
        }
        let destination = forward
            ? starts.first(where: { $0 > caretRow })
            : starts.last(where: { $0 < (caretRow < 0 ? presentations.count : caretRow) })
        guard let destination else { NSSound.beep(); return }
        caretRow = destination
        tableView.selectRowIndexes(IndexSet(integer: destination), byExtendingSelection: false)
        tableView.scrollRowToVisible(destination)
    }

    private func reloadRenderedLines() {
        let selection = tableView.selectedRowIndexes
        tableView.reloadData()
        tableView.selectRowIndexes(selection, byExtendingSelection: false)
    }

}

@MainActor
private enum CommitTemplateSettingsDialog {
    static func present(parent: NSWindow, onClose: @escaping () -> Void) {
        let controller = CommitTemplateSettingsViewController()
        let panel = NSPanel(contentViewController: controller)
        panel.title = "Commit message templates and validation"
        panel.styleMask = [.titled, .closable, .resizable]
        panel.setContentSize(NSSize(width: 680, height: 570))
        panel.minSize = NSSize(width: 600, height: 500)
        controller.panel = panel
        controller.onFinish = { saved in
            parent.endSheet(panel)
            if saved { onClose() }
        }
        parent.beginSheet(panel)
    }
}

@MainActor
private final class CommitTemplateSettingsViewController: NSViewController, NSWindowDelegate {
    weak var panel: NSPanel?
    var onFinish: ((Bool) -> Void)?
    private var preferences = AppSettingsStore.shared.commitPreferences
    private var templates: [CommitMessageTemplate] = []
    private var selectedSlot = 0
    private var didFinish = false
    private let slots = NSPopUpButton()
    private let nameField = NSTextField(string: "")
    private let regexCheck = NSButton(checkboxWithTitle: "Expand {{branch regular expression}}[group] placeholders", target: nil, action: nil)
    private let textView = NSTextView()
    private let subjectLength = NSTextField(string: "0")
    private let lineLength = NSTextField(string: "0")
    private let secondLine = NSButton(checkboxWithTitle: "Require validation-time empty second line", target: nil, action: nil)
    private let formatSecondLine = NSButton(checkboxWithTitle: "Insert an empty second line when writing the message", target: nil, action: nil)
    private let autoWrap = NSButton(checkboxWithTitle: "Auto-wrap using the configured line length", target: nil, action: nil)
    private let indent = NSButton(checkboxWithTitle: "Indent wrapped lines after the first line", target: nil, action: nil)
    private let validationRegex = NSTextField(string: "")

    override func loadView() {
        templates = Array(preferences.templates.prefix(10))
        while templates.count < 10 { templates.append(CommitMessageTemplate()) }
        let root = NSView()
        slots.addItems(withTitles: (1...10).map { "\($0): <empty>" })
        slots.target = self; slots.action = #selector(slotChanged)
        nameField.placeholderString = "Template name"
        nameField.maximumNumberOfLines = 1
        nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        let selector = row(label: "Template:", controls: [slots, nameField])

        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.textContainer?.widthTracksTextView = true
        let textScroll = NSScrollView()
        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.borderType = .bezelBorder
        textScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true

        for field in [subjectLength, lineLength] {
            field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 60).isActive = true
        }
        subjectLength.stringValue = String(preferences.validation.maximumSubjectLength)
        lineLength.stringValue = String(preferences.validation.maximumLineLength)
        secondLine.state = preferences.validation.requireEmptySecondLine ? .on : .off
        formatSecondLine.state = preferences.ensureSecondLineEmpty ? .on : .off
        autoWrap.state = preferences.validation.autoWrap ? .on : .off
        indent.state = preferences.validation.indentAfterFirstLine ? .on : .off
        validationRegex.stringValue = preferences.validation.regularExpression
        validationRegex.placeholderString = "Empty disables regular-expression validation"

        let validation = NSBox()
        validation.title = "Commit message validation"
        let validationStack = NSStackView(views: [
            row(label: "Maximum first-line length (0 disables):", controls: [subjectLength]),
            row(label: "Maximum line length (0 disables):", controls: [lineLength]),
            secondLine,
            formatSecondLine,
            autoWrap,
            indent,
            row(label: "Regular expression:", controls: [validationRegex])
        ])
        validationStack.orientation = .vertical
        validationStack.alignment = .leading
        validationStack.spacing = 6
        validationStack.translatesAutoresizingMaskIntoConstraints = false
        validation.contentView?.addSubview(validationStack)
        if let content = validation.contentView {
            NSLayoutConstraint.activate([
                validationStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
                validationStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
                validationStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
                validationStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8)
            ])
        }

        let ok = NSButton(title: "OK", target: self, action: #selector(save))
        ok.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, ok])
        buttons.orientation = .horizontal; buttons.spacing = 8
        let stack = NSStackView(views: [selector, regexCheck, textScroll, validation, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            selector.widthAnchor.constraint(equalTo: stack.widthAnchor),
            textScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            validation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        view = root
        refreshSlotTitles()
        loadSlot(0)
    }

    private func row(label: String, controls: [NSView]) -> NSStackView {
        let labelView = NSTextField(labelWithString: label)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [labelView, spacer] + controls)
        stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = 7
        return stack
    }

    @objc private func slotChanged() {
        captureSlot(selectedSlot)
        selectedSlot = max(0, slots.indexOfSelectedItem)
        loadSlot(selectedSlot)
    }

    private func captureSlot(_ index: Int) {
        guard templates.indices.contains(index) else { return }
        templates[index].name = String(nameField.stringValue.prefix(80))
        templates[index].text = textView.string
        templates[index].expandsBranchRegularExpressions = regexCheck.state == .on
        refreshSlotTitles()
    }

    private func loadSlot(_ index: Int) {
        guard templates.indices.contains(index) else { return }
        nameField.stringValue = templates[index].name
        textView.string = templates[index].text
        regexCheck.state = templates[index].expandsBranchRegularExpressions ? .on : .off
    }

    private func refreshSlotTitles() {
        for index in templates.indices {
            let name = templates[index].name.isEmpty ? "<empty>" : String(templates[index].name.prefix(50))
            slots.item(at: index)?.title = "\(index + 1): \(name)"
        }
    }

    @objc private func save() {
        captureSlot(selectedSlot)
        preferences.templates = templates
        preferences.validation.maximumSubjectLength = max(0, Int(subjectLength.stringValue) ?? 0)
        preferences.validation.maximumLineLength = max(0, Int(lineLength.stringValue) ?? 0)
        preferences.validation.requireEmptySecondLine = secondLine.state == .on
        preferences.ensureSecondLineEmpty = formatSecondLine.state == .on
        preferences.validation.autoWrap = autoWrap.state == .on
        preferences.validation.indentAfterFirstLine = indent.state == .on
        preferences.validation.regularExpression = validationRegex.stringValue
        AppSettingsStore.shared.saveCommitPreferences(preferences)
        finish(true)
    }

    @objc private func cancel() { finish(false) }
    func windowWillClose(_ notification: Notification) { finish(false) }
    private func finish(_ saved: Bool) {
        guard !didFinish else { return }
        didFinish = true
        onFinish?(saved)
    }
}
