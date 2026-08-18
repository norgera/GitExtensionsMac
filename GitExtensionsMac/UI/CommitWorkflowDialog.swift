import AppKit

@MainActor
enum CommitWorkflowDialog {
    static func present(
        source: any RepositoryMutatingDataSource,
        initialMode: RepositoryCommitMode,
        head: Commit?,
        draft: CommitDialogDraft?,
        owner: NSWindow,
        completion: @escaping (RepositoryCommitRequest?) -> Void
    ) -> NSWindowController {
        let controller = CommitWorkflowViewController(
            source: source,
            initialMode: initialMode,
            head: head,
            draft: draft
        )
        let commitWindow = NSWindow(contentViewController: controller)
        commitWindow.title = initialMode == .normal ? "Commit" : "Amend commit"
        commitWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        commitWindow.standardWindowButton(.closeButton)?.isEnabled = true
        commitWindow.standardWindowButton(.zoomButton)?.isEnabled = true
        commitWindow.setContentSize(NSSize(width: 1180, height: 720))
        commitWindow.contentMinSize = NSSize(width: 0, height: 0)
        commitWindow.minSize = NSSize(width: 180, height: 180)
        if let visibleFrame = owner.screen?.visibleFrame {
            commitWindow.maxSize = visibleFrame.size
        }
        controller.commitWindow = commitWindow
        commitWindow.delegate = controller

        let windowController = NSWindowController(window: commitWindow)
        controller.onComplete = { [weak commitWindow] request in
            commitWindow?.orderOut(nil)
            completion(request)
        }
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
private final class CommitWorkflowViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, NSWindowDelegate {
    private enum FileGroupingMode {
        case path
        case fileExtension
        case status
    }

    weak var commitWindow: NSWindow?
    var onComplete: ((RepositoryCommitRequest?) -> Void)?

    private let source: any RepositoryMutatingDataSource
    private let initialMode: RepositoryCommitMode
    private let head: Commit?
    private let draft: CommitDialogDraft?
    private let unstagedTable = NSTableView()
    private let stagedTable = NSTableView()
    private let unstagedFilter = NSSearchField()
    private let stagedFilter = NSSearchField()
    private let messageView = NSTextView()
    private let commitDiffView = CommitDiffView()
    private let mode = NSPopUpButton()
    private let amend = NSButton(checkboxWithTitle: "Amend commit", target: nil, action: nil)
    private let amendMessageOnly = NSButton(checkboxWithTitle: "Amend message only", target: nil, action: nil)
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
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let mainSplit = NSSplitView()
    private let fileSplit = NSSplitView()
    private let contentSplit = NSSplitView()
    private let messageSplit = NSSplitView()
    private var didSetInitialDividers = false
    private var unstaged: [ChangedFile] = []
    private var staged: [ChangedFile] = []
    private var currentSnapshot: RepositorySnapshot?
    private var loadTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var didComplete = false
    private var showOnlyMyMessages = true
    private var fileTreeMode = false
    private var fileGroupingMode: FileGroupingMode = .path
    private var showFileStatus = true
    private var showFileLineCounts = true

    init(source: any RepositoryMutatingDataSource, initialMode: RepositoryCommitMode, head: Commit?, draft: CommitDialogDraft?) {
        self.source = source
        self.initialMode = initialMode
        self.head = head
        self.draft = draft
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }
    deinit { loadTask?.cancel(); actionTask?.cancel() }

    override func loadView() {
        let root = NSView()
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
        mainSplit.setPosition(clamped(mainSplit.bounds.width * 0.36, minimum: 320, maximum: 520), ofDividerAt: 0)
        fileSplit.setPosition(clamped(fileSplit.bounds.height * 0.46, minimum: 170, maximum: fileSplit.bounds.height - 170), ofDividerAt: 0)
        contentSplit.setPosition(clamped(contentSplit.bounds.height * 0.68, minimum: 220, maximum: contentSplit.bounds.height - 165), ofDividerAt: 0)
        messageSplit.setPosition(184, ofDividerAt: 0)
    }

    private func clamped(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(maximum, max(minimum, value))
    }

    private func makeFilePane() -> NSView {
        configureTable(unstagedTable)
        configureTable(stagedTable)
        let unstagedScroll = scroll(for: unstagedTable)
        let stagedScroll = scroll(for: stagedTable)
        let stage = NSButton(title: "Stage", target: self, action: #selector(stageSelected))
        stage.keyEquivalent = "s"
        stage.keyEquivalentModifierMask = .command
        let stageAllButton = NSButton(title: "Stage All", target: self, action: #selector(stageEveryFile))
        let unstage = NSButton(title: "Unstage", target: self, action: #selector(unstageSelected))
        let unstageAll = NSButton(title: "Unstage All", target: self, action: #selector(unstageEveryFile))
        unstagedFilter.placeholderString = "Filter files using a regular expression…"
        stagedFilter.placeholderString = "Filter files using a regular expression…"
        let topTools = fileToolbar(for: unstagedTable)
        let transfer = transferToolbar(unstageAll: unstageAll, unstage: unstage, stage: stage, stageAll: stageAllButton)
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
        let messageScroll = NSScrollView()
        messageScroll.documentView = messageView
        messageScroll.hasVerticalScroller = true
        messageScroll.borderType = .bezelBorder
        configureDocumentView(messageView, width: 760, height: 260)
        messageScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 115).isActive = true

        mode.addItems(withTitles: ["Normal commit", "Amend", "Amend message only"])

        author.placeholderString = "Name <email@example.com>"
        author.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        let authorRow = NSStackView(views: [NSTextField(labelWithString: "Author:"), author])
        authorRow.orientation = .horizontal
        authorRow.spacing = 8

        commitButton.target = self
        commitButton.action = #selector(commit)
        commitButton.keyEquivalent = "\r"
        commitButton.keyEquivalentModifierMask = .command
        let commitAndPush = NSButton(title: "Commit & push", target: nil, action: nil)
        commitAndPush.isEnabled = false
        commitAndPush.toolTip = "Push is not implemented"
        amend.target = self
        amend.action = #selector(amendChanged)
        amendMessageOnly.target = self
        amendMessageOnly.action = #selector(amendMessageOnlyChanged)
        let stashStaged = NSButton(title: "Stash staged changes", target: self, action: #selector(stashStagedChanges))
        let resetAll = NSButton(title: "Reset all changes", target: nil, action: nil)
        let resetUnstaged = NSButton(title: "Reset unstaged changes", target: nil, action: nil)
        let resetSoft = NSButton(title: "Reset soft", target: nil, action: nil)
        resetSoft.isEnabled = false
        resetSoft.toolTip = "Soft reset is not implemented"
        resetAll.isEnabled = false
        resetUnstaged.isEnabled = false
        resetAll.toolTip = "Reset is not implemented"
        resetUnstaged.toolTip = "Reset is not implemented"
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        for button in [commitButton, commitAndPush, stashStaged, resetAll, resetUnstaged, cancelButton] {
            button.widthAnchor.constraint(equalToConstant: 168).isActive = true
        }
        amendPanel.orientation = .vertical
        amendPanel.alignment = .leading
        amendPanel.spacing = 2
        amendPanel.addArrangedSubview(resetAuthor)
        amendPanel.addArrangedSubview(resetSoft)
        amendPanel.isHidden = true
        let commands = NSStackView(views: [commitButton, commitAndPush, amend, amendPanel, amendMessageOnly, stashStaged, resetAll, resetUnstaged, cancelButton])
        commands.orientation = .vertical
        commands.alignment = .leading
        commands.spacing = 7
        commands.edgeInsets = NSEdgeInsets(top: 8, left: 3, bottom: 8, right: 3)

        messageMenu.removeAllItems()
        messageMenu.pullsDown = true
        messageMenu.addItem(withTitle: "Commit message")
        let createBranch = NSButton(title: "Create branch", target: nil, action: nil)
        createBranch.isEnabled = false
        templatesMenu.removeAllItems()
        templatesMenu.pullsDown = true
        templatesMenu.addItem(withTitle: "Commit templates")
        optionsMenu.removeAllItems()
        optionsMenu.pullsDown = true
        optionsMenu.addItem(withTitle: "Options")
        configureOptionsMenu()
        messageMenu.widthAnchor.constraint(lessThanOrEqualToConstant: 125).isActive = true
        templatesMenu.widthAnchor.constraint(lessThanOrEqualToConstant: 145).isActive = true
        createBranch.widthAnchor.constraint(lessThanOrEqualToConstant: 120).isActive = true
        optionsMenu.widthAnchor.constraint(lessThanOrEqualToConstant: 90).isActive = true
        [messageMenu, templatesMenu, createBranch, optionsMenu].forEach {
            $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            $0.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let messageToolbar = NSStackView(views: [messageMenu, templatesMenu, createBranch, spacer, optionsMenu])
        messageToolbar.orientation = .horizontal
        messageToolbar.alignment = .centerY
        messageToolbar.spacing = 6
        messageToolbar.edgeInsets = NSEdgeInsets(top: 3, left: 5, bottom: 3, right: 5)
        let options = NSStackView(views: [authorRow, stageAll, allowEmpty, signOff])
        options.orientation = .horizontal
        options.alignment = .centerY
        options.spacing = 9
        options.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        [authorRow, stageAll, allowEmpty, signOff].forEach {
            $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            $0.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        let editor = NSStackView(views: [messageToolbar, messageScroll, options])
        editor.orientation = .vertical
        editor.alignment = .leading
        editor.spacing = 0
        messageToolbar.widthAnchor.constraint(equalTo: editor.widthAnchor).isActive = true
        messageScroll.widthAnchor.constraint(equalTo: editor.widthAnchor).isActive = true
        options.widthAnchor.constraint(equalTo: editor.widthAnchor).isActive = true
        messageSplit.isVertical = true
        messageSplit.dividerStyle = .thin
        messageSplit.addArrangedSubview(commands)
        messageSplit.addArrangedSubview(editor)
        commands.widthAnchor.constraint(equalToConstant: 170).isActive = true

        contentSplit.isVertical = false
        contentSplit.dividerStyle = .paneSplitter
        contentSplit.addArrangedSubview(commitDiffView)
        contentSplit.addArrangedSubview(messageSplit)
        return contentSplit
    }

    private func configureMessageMenu() {
        guard let menu = messageMenu.menu else { return }
        while menu.items.count > 1 { menu.removeItem(at: 1) }
        let allHistory = (currentSnapshot?.commits ?? [])
            .filter { $0.kind == .revision }
            .prefix(8)
        let history = allHistory.filter { commit in
            guard showOnlyMyMessages,
                  let head,
                  (!head.authorName.isEmpty || !head.authorEmail.isEmpty) else { return true }
            let sameName = !head.authorName.isEmpty && commit.authorName == head.authorName
            let sameEmail = !head.authorEmail.isEmpty && commit.authorEmail == head.authorEmail
            return sameName || sameEmail
        }
        for commit in history {
            let item = NSMenuItem(title: shortenedMessage(commit.subject), action: #selector(selectRecentCommitMessage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = commit.subject + (commit.body.isEmpty ? "" : "\n\n\(commit.body)")
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
        let pat = NSMenuItem(title: "No GitHub personal access token (PAT) defined", action: nil, keyEquivalent: "")
        pat.isEnabled = false
        menu.addItem(pat)
        menu.addItem(.separator())

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
        let documentation = NSMenuItem(title: "Documentation…", action: nil, keyEquivalent: "")
        documentation.isEnabled = false
        submenu.addItem(documentation)
        conventional.submenu = submenu
        menu.addItem(conventional)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Edit commit message templates and settings…", action: nil, keyEquivalent: "")
        settings.isEnabled = false
        menu.addItem(settings)
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
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let sign = NSMenuItem(title: "Sign-off commit", action: #selector(toggleCommitOption(_:)), keyEquivalent: "")
        sign.target = self
        sign.representedObject = "signOff"
        sign.state = signOff.state
        menu.addItem(sign)
        let authorInfo = NSMenuItem(title: "Author: (Format: \"name <mail>\")", action: nil, keyEquivalent: "")
        authorInfo.isEnabled = false
        menu.addItem(authorInfo)
        let noVerify = NSMenuItem(title: "No verify", action: nil, keyEquivalent: "")
        noVerify.isEnabled = false
        menu.addItem(noVerify)
        menu.addItem(.separator())
        let gpg = NSMenuItem(title: "Git default GPG signing", action: nil, keyEquivalent: "")
        let gpgMenu = NSMenu(title: "GPG signing")
        for title in ["Git default GPG signing", "Do not sign commit", "Sign with default GPG", "Sign with specific GPG"] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            gpgMenu.addItem(item)
        }
        gpg.submenu = gpgMenu
        menu.addItem(gpg)
    }

    private func shortenedMessage(_ value: String) -> String {
        let firstLine = value.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first.map(String.init) ?? value
        return firstLine.count > 72 ? String(firstLine.prefix(69)) + "…" : firstLine
    }

    @objc private func selectRecentCommitMessage(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        messageView.string = value.trimmingCharacters(in: .whitespacesAndNewlines)
        commitWindow?.makeFirstResponder(messageView)
    }

    @objc private func generateSubmoduleMessage(_ sender: NSMenuItem) {
        status.stringValue = "Submodule change list generation is not implemented."
    }

    @objc private func toggleMyMessages(_ sender: NSMenuItem) {
        showOnlyMyMessages.toggle()
        configureMessageMenu()
    }

    @objc private func insertConventionalPrefix(_ sender: NSMenuItem) {
        guard let keyword = sender.representedObject as? String else { return }
        if messageView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messageView.string = "\(keyword): "
        } else {
            messageView.string = "\(keyword): \(messageView.string)"
        }
        commitWindow?.makeFirstResponder(messageView)
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
        } else {
            sender.state = sender.state == .on ? .off : .on
        }
    }

    private func configureInitialValues() {
        let initial = draft?.request
        let selectedMode = initial?.mode ?? initialMode
        mode.selectItem(at: selectedMode == .normal ? 0 : (selectedMode == .amend ? 1 : 2))
        amend.state = selectedMode == .normal ? .off : .on
        amendMessageOnly.state = selectedMode == .amendMessageOnly ? .on : .off
        messageView.string = initial?.message ?? (selectedMode == .normal ? "" : headMessage())
        let preferences = AppSettingsStore.shared.preferences
        stageAll.state = initial?.stageAllBeforeCommit == true ? .on : .off
        allowEmpty.state = (initial?.allowEmpty ?? preferences.defaultAllowEmpty) ? .on : .off
        signOff.state = (initial?.signOff ?? preferences.defaultSignOff) ? .on : .off
        resetAuthor.state = initial?.resetAuthor == true ? .on : .off
        author.stringValue = initial?.author ?? ""
        modeChanged()
    }

    private func configureTable(_ table: NSTableView) {
        let statusColumn = NSTableColumn(identifier: .init("Status"))
        statusColumn.title = "Status"
        statusColumn.width = 52
        let fileColumn = NSTableColumn(identifier: .init("File"))
        fileColumn.title = "File"
        fileColumn.width = 330
        table.addTableColumn(statusColumn)
        table.addTableColumn(fileColumn)
        table.headerView = NSTableHeaderView()
        table.rowHeight = 20
        table.intercellSpacing = .zero
        table.allowsMultipleSelection = true
        table.delegate = self
        table.dataSource = self
    }

    private func headMessage() -> String {
        guard let head else { return "" }
        return head.subject + (head.body.isEmpty ? "" : "\n\n\(head.body)")
    }

    private func scroll(for table: NSTableView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
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
        let refresh = AppKitFactory.resourceButton("ReloadRevisions", tooltip: "Refresh changes", target: self, action: #selector(refreshChanges))
        let tree = makeFileGroupingMenu()
        let folder = AppKitFactory.resourceButton("BrowseFileExplorer", tooltip: "Open containing folder", target: self, action: #selector(openContainingFolder(_:)))
        let viewFile = AppKitFactory.resourceButton("ViewFile", tooltip: "View selected file", target: self, action: #selector(viewSelectedFile(_:)))
        let filter = AppKitFactory.resourceButton("EditFilter", tooltip: "Edit file filter", target: self, action: #selector(editFileFilter(_:)))
        let settings = makeFileSettingsMenu()
        let buttons: [NSView] = [tree, folder, viewFile, filter, settings]
        buttons.forEach {
            if let button = $0 as? NSButton {
                button.contentTintColor = .secondaryLabelColor
            } else if let popup = $0 as? NSPopUpButton {
                popup.contentTintColor = .secondaryLabelColor
            }
        }
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [refresh] + buttons + [spacer])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 2
        bar.edgeInsets = NSEdgeInsets(top: 3, left: 5, bottom: 3, right: 5)
        return bar
    }

    private func makeFileGroupingMenu() -> NSView {
        let control = NSStackView()
        control.orientation = .horizontal
        control.spacing = 0
        control.alignment = .centerY
        let tree = AppKitFactory.resourceButton("FileTree", tooltip: "Toggle flat list / tree", target: self, action: #selector(toggleFileTree(_:)))
        tree.setButtonType(.pushOnPushOff)
        tree.state = fileTreeMode ? .on : .off
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
        let dense = NSMenuItem(title: "Dense tree (merge single item with its folder node)", action: nil, keyEquivalent: "")
        dense.isEnabled = false
        button.menu?.addItem(dense)
        let groupNodes = NSMenuItem(title: "Show group nodes in flat list (if multiple)", action: nil, keyEquivalent: "")
        groupNodes.isEnabled = false
        button.menu?.addItem(groupNodes)
        return control
    }

    private func makeFileSettingsMenu() -> NSPopUpButton {
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

        let statusItem = NSMenuItem(title: "Show file status", action: #selector(toggleFileListSetting(_:)), keyEquivalent: "")
        statusItem.target = self
        statusItem.representedObject = "status"
        statusItem.state = showFileStatus ? .on : .off
        button.menu?.addItem(statusItem)
        let countsItem = NSMenuItem(title: "Show changed line counts", action: #selector(toggleFileListSetting(_:)), keyEquivalent: "")
        countsItem.target = self
        countsItem.representedObject = "counts"
        countsItem.state = showFileLineCounts ? .on : .off
        button.menu?.addItem(countsItem)
        button.menu?.addItem(.separator())
        let filters = NSMenuItem(title: "Edit file filters…", action: #selector(editFileFilterMenu(_:)), keyEquivalent: "")
        filters.target = self
        button.menu?.addItem(filters)
        for title in ["Show skip-worktree files", "Show untracked files", "Edit ignored files", "Edit locally ignored files", "Show file differences for all parents"] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            button.menu?.addItem(item)
        }
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
        let unstagedFiles = displayedFiles(for: unstagedTable)
        let stagedFiles = displayedFiles(for: stagedTable)
        if let row = unstagedTable.selectedRowIndexes.first, unstagedFiles.indices.contains(row) { return unstagedFiles[row] }
        if let row = stagedTable.selectedRowIndexes.first, stagedFiles.indices.contains(row) { return stagedFiles[row] }
        return nil
    }

    @objc private func toggleFileTree(_ sender: NSButton) {
        fileTreeMode.toggle()
        unstagedTable.reloadData()
        stagedTable.reloadData()
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
        unstagedTable.reloadData()
        stagedTable.reloadData()
        status.stringValue = sender.title
    }

    @objc private func openContainingFolder(_ sender: NSButton) {
        guard let file = selectedChangedFile(), let snapshot = currentSnapshot else {
            status.stringValue = "Select a file first."
            return
        }
        let url = URL(fileURLWithPath: snapshot.currentRepository.path).appendingPathComponent(file.path).deletingLastPathComponent()
        NSWorkspace.shared.open(url)
    }

    @objc private func viewSelectedFile(_ sender: NSButton) {
        guard let file = selectedChangedFile(), let snapshot = currentSnapshot else {
            status.stringValue = "Select a file first."
            return
        }
        let url = URL(fileURLWithPath: snapshot.currentRepository.path).appendingPathComponent(file.path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            status.stringValue = "The selected file is not present in the working directory."
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func editFileFilter(_ sender: NSButton) {
        focusFileFilter()
    }

    @objc private func editFileFilterMenu(_ sender: NSMenuItem) {
        focusFileFilter()
    }

    private func focusFileFilter() {
        view.window?.makeFirstResponder(unstagedTable.selectedRow >= 0 ? unstagedFilter : stagedFilter)
    }

    @objc private func fileListSettings(_ sender: NSButton) {
        let menu = NSMenu(title: "File list settings")
        let statusItem = NSMenuItem(title: "Show file status", action: #selector(toggleFileListSetting(_:)), keyEquivalent: "")
        statusItem.target = self
        statusItem.representedObject = "status"
        statusItem.state = showFileStatus ? .on : .off
        menu.addItem(statusItem)
        let countsItem = NSMenuItem(title: "Show changed line counts", action: #selector(toggleFileListSetting(_:)), keyEquivalent: "")
        countsItem.target = self
        countsItem.representedObject = "counts"
        countsItem.state = showFileLineCounts ? .on : .off
        menu.addItem(countsItem)
        menu.addItem(.separator())
        let filters = NSMenuItem(title: "Edit file filters…", action: #selector(editFileFilterMenu(_:)), keyEquivalent: "")
        filters.target = self
        menu.addItem(filters)
        let point = NSPoint(x: 0, y: sender.bounds.minY)
        menu.popUp(positioning: nil, at: point, in: sender)
    }

    @objc private func toggleFileListSetting(_ sender: NSMenuItem) {
        switch sender.representedObject as? String {
        case "status": showFileStatus.toggle()
        case "counts": showFileLineCounts.toggle()
        default: break
        }
        sender.state = sender.state == .on ? .off : .on
        unstagedTable.reloadData()
        stagedTable.reloadData()
        status.stringValue = "File list settings updated."
    }

    private func displayedFiles(for tableView: NSTableView) -> [ChangedFile] {
        let files = tableView === unstagedTable ? unstaged : staged
        switch fileGroupingMode {
        case .path:
            return files.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        case .fileExtension:
            return files.sorted {
                let left = URL(fileURLWithPath: $0.path).pathExtension
                let right = URL(fileURLWithPath: $1.path).pathExtension
                return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
                    || (left == right && $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending)
            }
        case .status:
            return files.sorted {
                let left = $0.changeType.description
                let right = $1.changeType.description
                return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
                    || (left == right && $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending)
            }
        }
    }

    private func fileDisplayPath(_ file: ChangedFile) -> String {
        guard fileTreeMode else { return file.path }
        let components = file.path.split(separator: "/")
        guard components.count > 1 else { return file.path }
        return String(repeating: "  ", count: components.count - 1) + String(components.last!)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { displayedFiles(for: tableView).count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let file = displayedFiles(for: tableView)[row]
        let value: String
        if tableColumn?.identifier.rawValue == "Status" {
            value = showFileStatus ? file.changeType.description : ""
        } else if showFileLineCounts && (file.additions > 0 || file.deletions > 0) {
            value = "\(file.path)  +\(file.additions) -\(file.deletions)"
        } else {
            value = fileDisplayPath(file)
        }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === unstagedTable, !table.selectedRowIndexes.isEmpty {
            stagedTable.deselectAll(nil)
        } else if table === stagedTable, !table.selectedRowIndexes.isEmpty {
            unstagedTable.deselectAll(nil)
        }
        loadSelectedDiff(from: table)
    }

    private func reloadChanges() {
        loadTask?.cancel()
        commitButton.isEnabled = false
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await source.loadSnapshot()
                guard let worktree = snapshot.commits.first(where: { $0.kind == .workingDirectory }),
                      let index = snapshot.commits.first(where: { $0.kind == .index }) else {
                    throw RepositoryDataSourceError.unavailable
                }
                async let worktreeDetails = source.loadRevisionDetails(for: worktree)
                async let indexDetails = source.loadRevisionDetails(for: index)
                let (worktreeValue, indexValue) = try await (worktreeDetails, indexDetails)
                guard !Task.isCancelled else { return }
                currentSnapshot = snapshot
                configureMessageMenu()
                configureTemplatesMenu()
                let branch = snapshot.branches.first(where: \.isCurrent)?.name ?? "detached HEAD"
                commitWindow?.title = "Commit to \(branch) (\(snapshot.currentRepository.path))"
                unstaged = worktreeValue.files
                staged = indexValue.files
                unstagedTable.reloadData()
                stagedTable.reloadData()
                commitButton.isEnabled = true
                status.stringValue = "\(unstaged.count) unstaged, \(staged.count) staged"
            } catch is CancellationError {
                return
            } catch {
                status.stringValue = error.localizedDescription
            }
        }
    }

    private func loadSelectedDiff(from table: NSTableView) {
        guard table.selectedRow >= 0, let snapshot = currentSnapshot else { return }
        let files = displayedFiles(for: table)
        guard files.indices.contains(table.selectedRow) else { return }
        let file = files[table.selectedRow]
        let kind: Commit.Kind = table === unstagedTable ? .workingDirectory : .index
        guard let commit = snapshot.commits.first(where: { $0.kind == kind }) else { return }
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let diff = try await source.loadDiff(for: commit, file: file)
                guard !Task.isCancelled else { return }
                commitDiffView.apply(file: file, diff: diff)
            } catch is CancellationError {
                return
            } catch {
                status.stringValue = error.localizedDescription
            }
        }
    }

    @objc private func stageSelected() {
        let files = displayedFiles(for: unstagedTable)
        mutate(paths: unstagedTable.selectedRowIndexes.compactMap { files.indices.contains($0) ? files[$0].path : nil }, stage: true)
    }

    @objc private func unstageSelected() {
        let files = displayedFiles(for: stagedTable)
        mutate(paths: stagedTable.selectedRowIndexes.compactMap { files.indices.contains($0) ? files[$0].path : nil }, stage: false)
    }
    @objc private func stageEveryFile() { mutateAll(stage: true) }
    @objc private func unstageEveryFile() { mutateAll(stage: false) }

    private func mutate(paths: [String], stage: Bool) {
        guard !paths.isEmpty else { status.stringValue = "Select at least one file."; return }
        actionTask?.cancel()
        actionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                status.stringValue = stage ? "Staging…" : "Unstaging…"
                _ = try await (stage ? source.stage(paths: paths) : source.unstage(paths: paths))
                reloadChanges()
            } catch { status.stringValue = error.localizedDescription }
        }
    }

    private func mutateAll(stage: Bool) {
        actionTask?.cancel()
        actionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                status.stringValue = stage ? "Staging all…" : "Unstaging all…"
                _ = try await (stage ? source.stageAll() : source.unstageAll())
                reloadChanges()
            } catch { status.stringValue = error.localizedDescription }
        }
    }

    @objc private func modeChanged() {
        commitButton.title = mode.indexOfSelectedItem == 0 ? "Commit" : "Amend"
        amendPanel.isHidden = mode.indexOfSelectedItem == 0
        stageAll.isEnabled = mode.indexOfSelectedItem != 2
    }

    @objc private func amendChanged() {
        if amend.state == .off { amendMessageOnly.state = .off }
        if amend.state == .off { resetAuthor.state = .off }
        mode.selectItem(at: amend.state == .on ? (amendMessageOnly.state == .on ? 2 : 1) : 0)
        if amend.state == .on, messageView.string.isEmpty { messageView.string = headMessage() }
        modeChanged()
    }

    @objc private func amendMessageOnlyChanged() {
        if amendMessageOnly.state == .on { amend.state = .on }
        amendChanged()
    }

    @objc private func refreshChanges() { reloadChanges() }

    @objc private func stashStagedChanges() {
        guard !staged.isEmpty else { status.stringValue = "There are no staged changes to stash."; return }
        actionTask?.cancel()
        actionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                status.stringValue = "Stashing staged changes…"
                _ = try await source.createStash(RepositoryStashCreateRequest(message: "", includeUntracked: false, keepIndex: false, stagedOnly: true))
                reloadChanges()
            } catch { status.stringValue = error.localizedDescription }
        }
    }

    @objc private func commit() {
        let message = messageView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { status.stringValue = "Please enter a commit message."; commitWindow?.makeFirstResponder(messageView); return }
        let commitMode: RepositoryCommitMode = mode.indexOfSelectedItem == 1 ? .amend : (mode.indexOfSelectedItem == 2 ? .amendMessageOnly : .normal)
        if commitMode == .normal, staged.isEmpty, stageAll.state != .on, allowEmpty.state != .on {
            status.stringValue = "There are no staged changes to commit."
            return
        }
        let authorValue = author.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !authorValue.isEmpty,
           authorValue.range(of: #"^.+\s<[^<>]+>$"#, options: .regularExpression) == nil {
            status.stringValue = "Author must use the format Name <email@example.com>."
            commitWindow?.makeFirstResponder(author)
            return
        }
        finish(RepositoryCommitRequest(
            message: messageView.string,
            mode: commitMode,
            stageAllBeforeCommit: stageAll.state == .on,
            allowEmpty: allowEmpty.state == .on,
            signOff: signOff.state == .on,
            author: authorValue.isEmpty ? nil : authorValue,
            resetAuthor: resetAuthor.state == .on
        ))
    }

    @objc private func cancel() { finish(nil) }
    func windowWillClose(_ notification: Notification) { finish(nil) }
    func windowDidChangeScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let visibleFrame = window.screen?.visibleFrame else { return }
        window.maxSize = visibleFrame.size
    }
    private func finish(_ request: RepositoryCommitRequest?) {
        guard !didComplete else { return }
        didComplete = true
        onComplete?(request)
    }
}

@MainActor
private final class CommitDiffView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let tableView = NSTableView()
    private var presentations: [DiffLinePresentation] = []
    private var numberColumnWidth: CGFloat = 23

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("CommitDiff"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = BrowserMetrics.diffRowHeight
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .textBackgroundColor
        tableView.selectionHighlightStyle = .none
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.dataSource = self
        tableView.delegate = self

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func apply(file: ChangedFile, diff: FileDiff?) {
        presentations = DiffLinePresentation.build(from: diff?.lines ?? [])
        numberColumnWidth = Self.numberColumnWidth(for: diff?.lines ?? [])
        tableView.reloadData()
        if !presentations.isEmpty {
            tableView.scrollRowToVisible(0)
        }
        toolTip = diff == nil ? "No diff is available for \(file.path)." : file.path
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
            numberColumnWidth: numberColumnWidth,
            showsNonPrintingCharacters: false,
            showsSyntaxHighlighting: true
        )
        return cell
    }

    private static func numberColumnWidth(for lines: [DiffLine]) -> CGFloat {
        let maximum = lines
            .flatMap { [$0.oldLineNumber, $0.newLineNumber] }
            .compactMap { $0 }
            .max() ?? 0
        let digits = max(1, String(maximum).count)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let digitWidth = ceil(("0" as NSString).size(withAttributes: [.font: font]).width)
        let completeMarginWidth = 4 + (2 * CGFloat(digits + 1) * digitWidth)
        return ceil(completeMarginWidth / 2)
    }
}
