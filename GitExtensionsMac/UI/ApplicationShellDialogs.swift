import AppKit

private final class NetworkHelpToggleButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if let target, let action {
            _ = NSApp.sendAction(action, to: target, from: self)
        }
    }
}

@MainActor
final class RepositoryStartupViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var onOpenRepository: (() -> Void)?
    var onOpenRecentRepository: ((URL) -> Void)?
    var onCloneRepository: (() -> Void)?
    var onSettings: (() -> Void)?

    private let store: AppSettingsStore
    private let tableView = NSTableView()
    private let searchField = NSSearchField()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var filteredRepositories: [RecentRepository] = []

    init(store: AppSettingsStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let left = NSView()
        left.translatesAutoresizingMaskIntoConstraints = false
        let logo = NSTextField(labelWithString: "Git Extensions")
        logo.font = .boldSystemFont(ofSize: 25)
        let startTitle = NSTextField(labelWithString: "Start")
        startTitle.font = .boldSystemFont(ofSize: 16)
        let open = commandButton("Open repository…", action: #selector(openRepository))
        open.keyEquivalent = "o"
        open.keyEquivalentModifierMask = .command
        let clone = commandButton("Clone repository…", action: #selector(cloneRepository))
        let settings = commandButton("Settings…", action: #selector(openSettings))
        let leftStack = NSStackView(views: [logo, startTitle, open, clone, settings])
        leftStack.orientation = .vertical
        leftStack.alignment = .leading
        leftStack.spacing = 9
        leftStack.setCustomSpacing(24, after: logo)
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        left.addSubview(leftStack)

        let recentTitle = NSTextField(labelWithString: "Recent repositories")
        recentTitle.font = .boldSystemFont(ofSize: 18)
        searchField.placeholderString = "Search recent repositories"
        searchField.controlSize = .small
        searchField.delegate = self

        let nameColumn = NSTableColumn(identifier: .init("Repository"))
        nameColumn.title = "Repository"
        nameColumn.width = 190
        let pathColumn = NSTableColumn(identifier: .init("Path"))
        pathColumn.title = "Path"
        pathColumn.width = 430
        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(pathColumn)
        tableView.headerView = NSTableHeaderView()
        tableView.rowHeight = 22
        tableView.intercellSpacing = .zero
        tableView.allowsEmptySelection = true
        tableView.delegate = self
        tableView.dataSource = self
        tableView.doubleAction = #selector(openSelectedRecent)
        tableView.target = self
        tableView.menu = makeRecentMenu()

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        let rightStack = NSStackView(views: [recentTitle, searchField, scroll, errorLabel])
        rightStack.orientation = .vertical
        rightStack.alignment = .leading
        rightStack.spacing = 8
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 450).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        root.addSubview(left)
        root.addSubview(rightStack)
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            left.topAnchor.constraint(equalTo: root.topAnchor),
            left.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            left.widthAnchor.constraint(equalToConstant: 250),
            leftStack.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 30),
            leftStack.trailingAnchor.constraint(lessThanOrEqualTo: left.trailingAnchor, constant: -20),
            leftStack.topAnchor.constraint(equalTo: left.topAnchor, constant: 34),
            rightStack.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 28),
            rightStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            rightStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 38),
            rightStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -28)
        ])
        view = root
        reloadRecents()
    }

    func reloadRecents() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filteredRepositories = store.recentRepositories.filter {
            query.isEmpty || $0.path.localizedCaseInsensitiveContains(query)
        }
        tableView.reloadData()
    }

    func show(error: Error) {
        errorLabel.stringValue = error.localizedDescription
        errorLabel.isHidden = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filteredRepositories.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let repository = filteredRepositories[row]
        let isName = tableColumn?.identifier.rawValue == "Repository"
        let cell = NSTableCellView()
        let value = isName ? URL(fileURLWithPath: repository.path).lastPathComponent : repository.path
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func controlTextDidChange(_ obj: Notification) { reloadRecents() }

    private func commandButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.font = .systemFont(ofSize: 14)
        button.alignment = .left
        return button
    }

    private func makeRecentMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open", action: #selector(openSelectedRecent), keyEquivalent: "")
        menu.addItem(withTitle: "Show in Finder", action: #selector(showSelectedInFinder), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Remove project from the list", action: #selector(removeSelectedRecent), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        return menu
    }

    @objc private func openRepository() { onOpenRepository?() }
    @objc private func cloneRepository() { onCloneRepository?() }
    @objc private func openSettings() { onSettings?() }

    @objc private func openSelectedRecent() {
        guard tableView.selectedRow >= 0 else { return }
        onOpenRecentRepository?(URL(fileURLWithPath: filteredRepositories[tableView.selectedRow].path, isDirectory: true))
    }

    @objc private func showSelectedInFinder() {
        guard tableView.selectedRow >= 0 else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: filteredRepositories[tableView.selectedRow].path)])
    }

    @objc private func removeSelectedRecent() {
        guard tableView.selectedRow >= 0 else { return }
        store.removeRecentRepository(path: filteredRepositories[tableView.selectedRow].path)
        reloadRecents()
    }
}

enum NetworkOperationKind: String, Sendable {
    case pull = "Pull"
    case push = "Push"
    case fetch = "Fetch"
}

enum NetworkDialogInitialAction: Sendable, Equatable {
    case merge
    case rebase
    case fetch
    case fetchAll
    case fetchPruneAll
}

struct RepositoryNetworkRequest: Hashable, Sendable {
    let kind: NetworkOperationKind
    let remote: String
    let localBranch: String
    let remoteBranch: String
    let sourceURL: String?
    let prune: Bool
    let tags: Bool
    let force: Bool
    let rebase: Bool
}

@MainActor
enum ApplicationShellDialogs {
    static func presentSettings(from window: NSWindow) async {
        let controller = SettingsViewController(store: .shared)
        let panel = NSPanel(contentViewController: controller)
        panel.title = "Settings"
        panel.styleMask = [.titled, .closable, .resizable]
        panel.setContentSize(NSSize(width: 1040, height: 720))
        panel.minSize = NSSize(width: 900, height: 620)
        controller.panel = panel
        panel.delegate = controller
        await withCheckedContinuation { continuation in
            controller.onClose = { response in
                window.endSheet(panel, returnCode: response)
            }
            window.beginSheet(panel) { _ in continuation.resume() }
        }
    }

    static func cloneShell(from window: NSWindow) async {
        let alert = NSAlert()
        alert.messageText = "Clone repository"
        alert.informativeText = "Repository networking is not implemented yet. The clone request can be configured but cannot be executed."
        alert.addButton(withTitle: "Clone")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].isEnabled = false
        let stack = formStack()
        stack.addArrangedSubview(labeled("Repository URL:", NSTextField(string: ""), width: 410))
        stack.addArrangedSubview(labeled("Destination:", NSTextField(string: ""), width: 410))
        stack.addArrangedSubview(checkBox("Recursive submodules", false))
        alert.accessoryView = accessory(for: stack, width: 540)
        _ = await begin(alert, for: window)
    }

    static func presentNetworkWindow(
        kind: NetworkOperationKind,
        initialAction: NetworkDialogInitialAction,
        snapshot: RepositorySnapshot,
        source: (any RepositoryRemoteManagingDataSource)?,
        onSnapshot: @escaping (RepositorySnapshot) -> Void,
        onClose: @escaping () -> Void
    ) -> NSWindowController {
        let controller = NetworkDialogViewController(kind: kind, initialAction: initialAction, snapshot: snapshot, source: source, onSnapshot: onSnapshot)
        let window = NSWindow(contentViewController: controller)
        window.title = "\(kind.rawValue) (\(snapshot.currentRepository.path))"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: kind == .push ? 760 : 920, height: kind == .push ? 500 : 620))
        window.minSize = NSSize(width: kind == .push ? 620 : 700, height: kind == .push ? 410 : 510)
        window.isReleasedWhenClosed = false
        window.delegate = controller
        controller.onClose = onClose
        let windowController = NSWindowController(window: window)
        windowController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        return windowController
    }

    static func mergeShell(snapshot: RepositorySnapshot, window: NSWindow) async {
        let alert = NSAlert()
        alert.messageText = "Merge branch"
        alert.informativeText = "Merge execution is not available in the typed backend yet."
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].isEnabled = false
        let stack = formStack()
        let branches = NSPopUpButton()
        branches.addItems(withTitles: snapshot.branches.filter { !$0.isCurrent }.map(\.name))
        stack.addArrangedSubview(labeled("Merge branch:", branches, width: 320))
        stack.addArrangedSubview(labeled("Into current branch:", NSTextField(labelWithString: snapshot.branches.first(where: \.isCurrent)?.name ?? "Detached HEAD"), width: 320))
        stack.addArrangedSubview(checkBox("Keep a single branch line if possible (fast forward)", true))
        stack.addArrangedSubview(checkBox("Always create a new merge commit", false))
        stack.addArrangedSubview(checkBox("Do not commit", false))
        stack.addArrangedSubview(checkBox("Squash commits", false))
        stack.addArrangedSubview(checkBox("Allow unrelated histories", false))
        alert.accessoryView = accessory(for: stack, width: 500)
        _ = await begin(alert, for: window)
    }

    private static func formStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    private static func labeled(_ title: String, _ control: NSView, width: CGFloat) -> NSView {
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalToConstant: width).isActive = true
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private static func checkBox(_ title: String, _ value: Bool) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        button.state = value ? .on : .off
        return button
    }

    private static func accessory(for stack: NSStackView, width: CGFloat) -> NSView {
        let view = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: width)
        ])
        return view
    }

    private static func begin(_ alert: NSAlert, for window: NSWindow) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }
}

@MainActor
private final class NetworkDialogViewController: NSViewController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let kind: NetworkOperationKind
    private let initialAction: NetworkDialogInitialAction
    private var snapshot: RepositorySnapshot
    private let source: (any RepositoryRemoteManagingDataSource)?
    private let onSnapshot: (RepositorySnapshot) -> Void
    private var didClose = false
    private var remoteWindowController: NSWindowController?
    private var remoteBranchTask: Task<Void, Never>?
    private var remotePopUp: NSPopUpButton?
    private var remoteURLField: NSTextField?
    private var localBranchField: NSTextField?
    private var branchPopUp: NSPopUpButton?
    private var reachableTagsButton: NSButton?
    private var allTagsButton: NSButton?
    private var pruneButton: NSButton?
    private var pruneTagsButton: NSButton?
    private var executeButton: NSButton?
    private let helpImageView = PullHelpImageView()
    private let helpNotice = NSTextField(labelWithString: "Hover to see scenario when fast forward is possible.")
    private let helpToggle = NetworkHelpToggleButton()
    private var helpWidthConstraint: NSLayoutConstraint?
    private var isHelpExpanded = true
    private let mergeMode = NSButton(radioButtonWithTitle: "Merge remote branch into current branch", target: nil, action: nil)
    private let rebaseMode = NSButton(radioButtonWithTitle: "Rebase current branch on top of remote branch, creates linear history (use with caution)", target: nil, action: nil)
    private let fetchMode = NSButton(radioButtonWithTitle: "Do not merge, only fetch remote changes", target: nil, action: nil)

    init(
        kind: NetworkOperationKind,
        initialAction: NetworkDialogInitialAction,
        snapshot: RepositorySnapshot,
        source: (any RepositoryRemoteManagingDataSource)?,
        onSnapshot: @escaping (RepositorySnapshot) -> Void
    ) {
        self.kind = kind
        self.initialAction = initialAction
        self.snapshot = snapshot
        self.source = source
        self.onSnapshot = onSnapshot
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        let help = makeHelpPanel()
        help.translatesAutoresizingMaskIntoConstraints = false

        let form = kind == .push ? makePushForm() : makePullFetchForm()
        form.translatesAutoresizingMaskIntoConstraints = false
        let document = TopAlignedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(form)
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            form.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            form.topAnchor.constraint(equalTo: document.topAnchor),
            form.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        let footer = makeFooter()
        footer.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(help)
        root.addSubview(scroll)
        root.addSubview(separator)
        root.addSubview(footer)
        let helpWidth = help.widthAnchor.constraint(equalToConstant: kind == .push ? 230 : 307)
        helpWidthConstraint = helpWidth
        NSLayoutConstraint.activate([
            help.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            help.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            help.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -10),
            helpWidth,
            scroll.leadingAnchor.constraint(equalTo: help.trailingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            scroll.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -8),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            footer.heightAnchor.constraint(equalToConstant: 42)
        ])
        view = root
        if kind == .push {
            updateHelpImage()
            return
        }
        let initialButton: NSButton = switch initialAction {
        case .rebase: rebaseMode
        case .fetch, .fetchAll, .fetchPruneAll: fetchMode
        case .merge: remotePopUp?.titleOfSelectedItem == "[ All ]" ? fetchMode : mergeMode
        }
        changePullMode(initialButton)
        if initialAction == .fetchPruneAll { pruneButton?.state = .on }
        loadAdvertisedRemoteBranches()
    }

    private func makeHelpPanel() -> NSView {
        let panel = NSView()
        helpToggle.isBordered = false
        helpToggle.target = self
        helpToggle.action = #selector(toggleHelp)
        helpToggle.alignment = .left
        helpToggle.setButtonType(.momentaryPushIn)
        updateHelpToggleTitle()

        helpNotice.font = .systemFont(ofSize: 12)
        helpNotice.lineBreakMode = .byTruncatingTail
        helpImageView.imageScaling = .scaleProportionallyUpOrDown
        helpImageView.imageAlignment = .alignTopLeft
        helpImageView.translatesAutoresizingMaskIntoConstraints = false
        let imageWidth: CGFloat = kind == .push ? 230 : 307
        NSLayoutConstraint.activate([
            helpImageView.widthAnchor.constraint(equalToConstant: imageWidth),
            helpImageView.heightAnchor.constraint(equalToConstant: imageWidth * 375 / 307)
        ])

        let stack = NSStackView(views: [helpToggle, helpNotice, helpImageView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.setCustomSpacing(10, after: helpNotice)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 3),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: panel.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.topAnchor)
        ])
        return panel
    }

    @objc private func toggleHelp() {
        isHelpExpanded.toggle()
        helpImageView.isHidden = !isHelpExpanded
        helpNotice.isHidden = !isHelpExpanded || helpImageView.alternateImage == nil
        helpWidthConstraint?.constant = isHelpExpanded ? (kind == .push ? 230 : 307) : 85
        updateHelpToggleTitle()
    }

    private func updateHelpToggleTitle() {
        helpToggle.attributedTitle = NSAttributedString(
            string: isHelpExpanded ? "Hide help" : "Show help",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
        )
    }

    private func makePullFetchForm() -> NSView {
        let remote = NSPopUpButton()
        remotePopUp = remote
        remote.target = self
        remote.action = #selector(remoteChanged(_:))
        let initialRemote = initialAction == .fetchAll || initialAction == .fetchPruneAll ? "[ All ]" : preferredRemoteName()
        populateRemotes(selecting: initialRemote)
        let url = NSTextField(string: snapshot.remotes.first?.fetchURL ?? "")
        remoteURLField = url
        url.isEnabled = false
        let remoteChoice = NSButton(radioButtonWithTitle: "Remote", target: nil, action: nil)
        remoteChoice.state = .on
        let urlChoice = NSButton(radioButtonWithTitle: "URL", target: nil, action: nil)
        let manage = NSButton(title: "Manage remotes", target: self, action: #selector(manageRemotes))
        manage.image = AppKitFactory.resourceImage("Remotes", accessibilityDescription: "Manage remotes")
        manage.imagePosition = .imageLeading
        manage.isEnabled = source != nil
        let sourceGrid = NSGridView(views: [
            [remoteChoice, remote, manage],
            [urlChoice, url, disabledButton("Browse…")]
        ])
        sourceGrid.column(at: 0).width = 90
        sourceGrid.column(at: 2).width = 140
        sourceGrid.rowSpacing = 6
        sourceGrid.columnSpacing = 8

        let currentBranch = snapshot.branches.first(where: \.isCurrent)?.name ?? ""
        let local = NSTextField(string: currentBranch)
        localBranchField = local
        let branches = NSPopUpButton()
        branchPopUp = branches
        url.stringValue = snapshot.remotes.first(where: { $0.name == remote.titleOfSelectedItem })?.fetchURL ?? ""
        populateRemoteBranches()
        let branchGrid = NSGridView(views: [
            [rightLabel("Local branch"), local],
            [rightLabel("Remote branch"), branches]
        ])
        branchGrid.column(at: 0).width = 130
        branchGrid.rowSpacing = 7
        branchGrid.columnSpacing = 8

        [mergeMode, rebaseMode, fetchMode].forEach {
            $0.target = self
            $0.action = #selector(changePullMode(_:))
        }
        mergeMode.image = AppKitFactory.resourceImage("Merge", accessibilityDescription: "Merge")
        mergeMode.imagePosition = .imageLeading
        rebaseMode.image = AppKitFactory.resourceImage("Rebase", accessibilityDescription: "Rebase")
        rebaseMode.imagePosition = .imageLeading
        if kind == .fetch { fetchMode.state = .on } else { mergeMode.state = .on }
        let mergeOptions = vertical([mergeMode, rebaseMode, fetchMode], spacing: 6)

        let reachable = NSButton(radioButtonWithTitle: "Follow tagopt, if not specified, fetch tags reachable from remote HEAD", target: nil, action: nil)
        reachable.state = .on
        reachableTagsButton = reachable
        let noTags = NSButton(radioButtonWithTitle: "Fetch no tag", target: nil, action: nil)
        let allTags = NSButton(radioButtonWithTitle: "Fetch all tags", target: nil, action: nil)
        allTagsButton = allTags
        let tagOptions = vertical([reachable, noTags, allTags], spacing: 6)

        let prune = NSButton(checkboxWithTitle: "Prune remote branches", target: nil, action: nil)
        let pruneTags = NSButton(checkboxWithTitle: "Prune remote branches and tags", target: nil, action: nil)
        pruneButton = prune
        pruneTagsButton = pruneTags
        let stack = vertical([
            group("Pull from", sourceGrid),
            group("Branch", branchGrid),
            group("Merge options", mergeOptions),
            group("Tag options", tagOptions),
            prune,
            pruneTags
        ], spacing: 9)
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 3, bottom: 10, right: 10)
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 540).isActive = true
        return stack
    }

    private func makePushForm() -> NSView {
        let remote = NSPopUpButton()
        remote.addItems(withTitles: snapshot.remotes.map(\.name).isEmpty ? ["origin"] : snapshot.remotes.map(\.name))
        let currentBranch = snapshot.branches.first(where: \.isCurrent)?.name ?? ""
        let local = NSTextField(string: currentBranch)
        let remoteBranch = NSTextField(string: currentBranch)
        let grid = NSGridView(views: [
            [rightLabel("Remote"), remote],
            [rightLabel("Local branch"), local],
            [rightLabel("Remote branch"), remoteBranch]
        ])
        grid.column(at: 0).width = 120
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        let forceLease = NSButton(checkboxWithTitle: "Force with lease", target: nil, action: nil)
        let force = NSButton(checkboxWithTitle: "Force", target: nil, action: nil)
        let tags = NSButton(checkboxWithTitle: "Push tags", target: nil, action: nil)
        let allBranches = NSButton(checkboxWithTitle: "Push all branches", target: nil, action: nil)
        let stack = vertical([group("Push to", grid), group("Options", vertical([forceLease, force, tags, allBranches], spacing: 7))], spacing: 10)
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 3, bottom: 10, right: 10)
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 450).isActive = true
        return stack
    }

    private func makeFooter() -> NSView {
        let conflicts = disabledButton("Solve conflicts")
        let stash = disabledButton("Stash changes")
        let autoStash = NSButton(checkboxWithTitle: "Auto stash", target: nil, action: nil)
        let status = NSTextField(labelWithString: "Network execution is not implemented")
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 10.5)
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let execute = NSButton(title: kind.rawValue, target: nil, action: nil)
        executeButton = execute
        execute.image = AppKitFactory.resourceImage(kind == .push ? "Push" : "Pull", accessibilityDescription: kind.rawValue)
        execute.imagePosition = .imageLeading
        execute.isEnabled = false
        execute.toolTip = "The typed network backend is not implemented"
        execute.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let stack = NSStackView(views: [conflicts, stash, autoStash, status, execute])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    @objc private func changePullMode(_ sender: NSButton) {
        for button in [mergeMode, rebaseMode, fetchMode] {
            button.state = button === sender ? .on : .off
        }
        localBranchField?.isEnabled = sender === fetchMode
        if sender !== fetchMode {
            localBranchField?.stringValue = snapshot.branches.first(where: \.isCurrent)?.name ?? ""
        }
        let isFetch = sender === fetchMode
        allTagsButton?.isEnabled = isFetch
        pruneButton?.isEnabled = isFetch
        pruneTagsButton?.isEnabled = isFetch
        if !isFetch, allTagsButton?.state == .on {
            allTagsButton?.state = .off
            reachableTagsButton?.state = .on
        }
        let effectiveKind: NetworkOperationKind = isFetch ? .fetch : .pull
        executeButton?.title = effectiveKind.rawValue
        executeButton?.image = AppKitFactory.resourceImage("Pull", accessibilityDescription: effectiveKind.rawValue)
        view.window?.title = "\(effectiveKind.rawValue) (\(snapshot.currentRepository.path))"
        updateHelpImage()
    }

    private func updateHelpImage() {
        let name: String
        let alternateName: String?
        if kind == .push {
            name = "HelpPullFetch"
            alternateName = nil
        } else if rebaseMode.state == .on {
            name = "HelpPullRebase"
            alternateName = nil
        } else if fetchMode.state == .on {
            name = "HelpPullFetch"
            alternateName = nil
        } else {
            name = "HelpPullMerge"
            alternateName = "HelpPullMergeFastForward"
        }
        let primary = AppKitFactory.resourceImage(
            name,
            accessibilityDescription: "\(kind.rawValue) scenario",
            size: NSSize(width: 307, height: 375),
            adaptLightness: true
        )
        let alternate = alternateName.flatMap {
            AppKitFactory.resourceImage(
                $0,
                accessibilityDescription: "Fast-forward merge scenario",
                size: NSSize(width: 307, height: 375),
                adaptLightness: true
            )
        }
        helpImageView.setImages(primary: primary, alternate: alternate)
        helpNotice.isHidden = alternate == nil || !isHelpExpanded
        helpImageView.toolTip = nil
    }

    private func preferredRemoteName() -> String? {
        let current = snapshot.branches.first(where: \.isCurrent)?.name
        let tracking = snapshot.commits.lazy.flatMap(\.references).first {
            ($0.kind == .currentBranch || $0.kind == .localBranch) && $0.name == current
        }?.trackingRemote
        return tracking ?? snapshot.remotes.first?.name
    }

    private func populateRemotes(selecting name: String?) {
        guard let remotePopUp else { return }
        remotePopUp.removeAllItems()
        remotePopUp.addItem(withTitle: "[ All ]")
        remotePopUp.addItems(withTitles: snapshot.remotes.map(\.name))
        if remotePopUp.numberOfItems == 0 { remotePopUp.addItem(withTitle: "[ All ]") }
        if let name { remotePopUp.selectItem(withTitle: name) }
        updateRemoteURL()
    }

    private func updateRemoteURL() {
        let name = remotePopUp?.titleOfSelectedItem
        remoteURLField?.stringValue = snapshot.remotes.first(where: { $0.name == name })?.fetchURL ?? ""
        let all = name == "[ All ]"
        mergeMode.isEnabled = !all
        rebaseMode.isEnabled = !all
        if all { changePullMode(fetchMode); fetchMode.state = .on }
        populateRemoteBranches()
    }

    private func populateRemoteBranches(advertisedNames: [String]? = nil) {
        guard let branchPopUp else { return }
        let remoteName = remotePopUp?.titleOfSelectedItem
        let currentBranch = snapshot.branches.first(where: \.isCurrent)?.name ?? ""
        let trackedBranch = snapshot.commits.lazy.flatMap(\.references).first {
            ($0.kind == .currentBranch || $0.kind == .localBranch) && $0.name == currentBranch && $0.trackingRemote == remoteName
        }?.mergeWith
        branchPopUp.removeAllItems()
        if remoteName == "[ All ]" {
            branchPopUp.addItem(withTitle: "*")
        } else if let remote = snapshot.remotes.first(where: { $0.name == remoteName }) {
            let prefix = remote.name + "/"
            let cachedNames = remote.branches.map { branch in
                branch.name.hasPrefix(prefix) ? String(branch.name.dropFirst(prefix.count)) : branch.name
            }.filter { $0 != "HEAD" }
            branchPopUp.addItem(withTitle: "")
            let names = advertisedNames ?? cachedNames
            branchPopUp.addItems(withTitles: Array(Set(names)).sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            })
        }
        if let trackedBranch,
           branchPopUp.itemTitles.contains(trackedBranch) {
            branchPopUp.selectItem(withTitle: trackedBranch)
        } else if branchPopUp.numberOfItems > 0 {
            branchPopUp.selectItem(at: 0)
        }
    }

    private func loadAdvertisedRemoteBranches() {
        remoteBranchTask?.cancel()
        guard let source,
              let remoteName = remotePopUp?.titleOfSelectedItem,
              remoteName != "[ All ]",
              !remoteName.isEmpty else {
            branchPopUp?.toolTip = nil
            return
        }

        branchPopUp?.toolTip = "Loading branches from \(remoteName)…"
        remoteBranchTask = Task { @MainActor [weak self] in
            do {
                let names = try await source.loadRemoteBranchNames(named: remoteName)
                guard !Task.isCancelled,
                      let self,
                      self.remotePopUp?.titleOfSelectedItem == remoteName else { return }
                self.populateRemoteBranches(advertisedNames: names)
                self.branchPopUp?.toolTip = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.remotePopUp?.titleOfSelectedItem == remoteName else { return }
                self.branchPopUp?.toolTip = "Could not query \(remoteName): \(error.localizedDescription)"
            }
        }
    }

    @objc private func remoteChanged(_ sender: NSPopUpButton) {
        updateRemoteURL()
        loadAdvertisedRemoteBranches()
    }

    @objc private func manageRemotes() {
        guard remoteWindowController == nil, let source else {
            remoteWindowController?.window?.makeKeyAndOrderFront(nil)
            return
        }
        let selectedName = remotePopUp?.titleOfSelectedItem
        remoteWindowController = RemoteManagementDialog.present(
            source: source,
            selectedRemote: selectedName == "[ All ]" ? nil : selectedName,
            onSnapshot: { [weak self] snapshot in
                guard let self else { return }
                self.snapshot = snapshot
                self.onSnapshot(snapshot)
                self.populateRemotes(selecting: self.remotePopUp?.titleOfSelectedItem)
                self.loadAdvertisedRemoteBranches()
            },
            onClose: { [weak self] in self?.remoteWindowController = nil }
        )
    }

    private func group(_ title: String, _ content: NSView) -> NSBox {
        let box = NSBox()
        box.title = title
        box.titlePosition = .atTop
        box.boxType = .primary
        content.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(content)
        if let holder = box.contentView {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 10),
                content.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -10),
                content.topAnchor.constraint(equalTo: holder.topAnchor, constant: 8),
                content.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -10)
            ])
        }
        return box
    }

    private func vertical(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func rightLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        return label
    }

    private func disabledButton(_ title: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.isEnabled = false
        return button
    }

    func windowWillClose(_ notification: Notification) { finish() }
    private func finish() {
        guard !didClose else { return }
        didClose = true
        remoteBranchTask?.cancel()
        onClose?()
    }
}

@MainActor
final class PullHelpImageView: NSImageView {
    private var primaryImage: NSImage?
    private(set) var alternateImage: NSImage?
    private var tracking: NSTrackingArea?
    private var hoverTimer: Timer?
    private var isShowingAlternate = false

    func setImages(primary: NSImage?, alternate: NSImage?) {
        primaryImage = primary
        alternateImage = alternate
        showAlternate(false)
        updateTrackingAreas()
        refreshHoverState()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hoverTimer?.invalidate()
        hoverTimer = nil
        window?.acceptsMouseMovedEvents = true
        updateTrackingAreas()
        guard window != nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshHoverState()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        showAlternate(true)
    }

    override func mouseMoved(with event: NSEvent) {
        showAlternate(true)
    }

    override func mouseExited(with event: NSEvent) {
        showAlternate(false)
    }

    private func refreshHoverState() {
        guard let window, window.isKeyWindow, !isHidden, alternateImage != nil else {
            showAlternate(false)
            return
        }
        let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        showAlternate(bounds.contains(convert(pointInWindow, from: nil)))
    }

    private func showAlternate(_ shouldShow: Bool) {
        let resolved = shouldShow && alternateImage != nil
        guard resolved != isShowingAlternate || image == nil else { return }
        isShowingAlternate = resolved
        image = resolved ? alternateImage : primaryImage
    }
}

final class TopAlignedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class PullFetchHelpView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let scale = min(bounds.width / 260, bounds.height / 500)
        NSGraphicsContext.current?.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: (bounds.width - 260 * scale) / 2, yBy: 28)
        transform.scale(by: scale)
        transform.concat()
        let muted = NSColor.secondaryLabelColor
        let accent = NSColor.systemPink
        let branch = NSColor.systemIndigo
        func line(_ points: [NSPoint], color: NSColor, width: CGFloat = 5, dashed: Bool = false) {
            let path = NSBezierPath()
            path.lineWidth = width
            if dashed { path.setLineDash([10, 8], count: 2, phase: 0) }
            for (index, point) in points.enumerated() { index == 0 ? path.move(to: point) : path.line(to: point) }
            color.setStroke(); path.stroke()
        }
        line([NSPoint(x: 55, y: 25), NSPoint(x: 55, y: 145)], color: accent)
        line([NSPoint(x: 55, y: 145), NSPoint(x: 55, y: 250)], color: muted, dashed: true)
        line([NSPoint(x: 55, y: 250), NSPoint(x: 55, y: 410)], color: branch)
        line([NSPoint(x: 55, y: 330), NSPoint(x: 120, y: 300), NSPoint(x: 120, y: 205)], color: .systemRed)
        line([NSPoint(x: 205, y: 25), NSPoint(x: 205, y: 410)], color: muted)
        line([NSPoint(x: 205, y: 330), NSPoint(x: 145, y: 300), NSPoint(x: 145, y: 205)], color: .systemRed)
        for x in [55.0, 205.0] {
            for (index, y) in [25.0, 85.0, 205.0, 265.0, 330.0, 410.0].enumerated() {
                let rect = NSRect(x: x - 13, y: y - 13, width: 26, height: 26)
                (index < 2 ? accent : branch).setFill()
                NSBezierPath(ovalIn: rect).fill()
                let letter = ["f", "e", "d", "c", "b", "a"][index]
                (letter as NSString).draw(at: NSPoint(x: x - 4, y: y - 9), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 15), .foregroundColor: NSColor.black])
            }
        }
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 92, y: 235)); arrow.line(to: NSPoint(x: 165, y: 235)); arrow.line(to: NSPoint(x: 148, y: 220)); arrow.move(to: NSPoint(x: 165, y: 235)); arrow.line(to: NSPoint(x: 148, y: 250))
        arrow.lineWidth = 9; muted.setStroke(); arrow.stroke()
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}

@MainActor
private final class SettingsNode: NSObject {
    let id: String
    let title: String
    let children: [SettingsNode]
    init(_ id: String, _ title: String, _ children: [SettingsNode] = []) {
        self.id = id
        self.title = title
        self.children = children
    }
}

@MainActor
private final class SettingsViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    weak var panel: NSPanel?
    var onClose: ((NSApplication.ModalResponse) -> Void)?

    private let store: AppSettingsStore
    private var draft: AppPreferences
    private var pushDraft: PushPreferences
    private var commitDraft: CommitPreferences
    private lazy var roots: [SettingsNode] = [
        SettingsNode("application", "Git Extensions", [
            SettingsNode("general", "General"),
            SettingsNode("appearance", "Appearance", [
                SettingsNode("sorting", "Sorting"), SettingsNode("colors", "Colors"),
                SettingsNode("fonts", "Fonts"), SettingsNode("console", "Console style")
            ]),
            SettingsNode("revision_links", "Revision links"),
            SettingsNode("build_server", "Build server integration"),
            SettingsNode("scripts", "Scripts"),
            SettingsNode("hotkeys", "Hotkeys"),
            SettingsNode("advanced", "Advanced", [SettingsNode("confirmations", "Confirmations")]),
            SettingsNode("detailed", "Detailed", [
                SettingsNode("browse", "Browse repository window"),
                SettingsNode("commit", "Commit dialog"),
                SettingsNode("diff", "Diff viewer"),
                SettingsNode("blame", "Blame viewer")
            ]),
            SettingsNode("ssh", "SSH")
        ]),
        SettingsNode("git", "Git", [
            SettingsNode("git_paths", "Paths"), SettingsNode("git_config", "Config"),
            SettingsNode("git_advanced", "Advanced")
        ]),
        SettingsNode("plugins", "Plugins")
    ]
    private var visibleRoots: [SettingsNode] = []
    private let outlineView = NSOutlineView()
    private let searchField = NSSearchField()
    private let content = NSStackView()
    private let settingsSplit = NSSplitView()
    private var didSetInitialDivider = false
    private var didClose = false

    init(store: AppSettingsStore) {
        self.store = store
        draft = store.preferences
        pushDraft = store.pushPreferences
        commitDraft = store.commitPreferences
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        let column = NSTableColumn(identifier: .init("Category"))
        column.width = 225
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = 23
        outlineView.indentationPerLevel = 17
        outlineView.delegate = self
        outlineView.dataSource = self
        let sidebar = NSScrollView()
        sidebar.documentView = outlineView
        sidebar.hasVerticalScroller = true
        sidebar.borderType = .bezelBorder
        searchField.placeholderString = "Type to find"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        let sidebarHolder = NSView()
        sidebarHolder.addSubview(searchField)
        sidebarHolder.addSubview(sidebar)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: sidebarHolder.leadingAnchor),
            searchField.trailingAnchor.constraint(equalTo: sidebarHolder.trailingAnchor),
            searchField.topAnchor.constraint(equalTo: sidebarHolder.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: sidebarHolder.leadingAnchor),
            sidebar.trailingAnchor.constraint(equalTo: sidebarHolder.trailingAnchor),
            sidebar.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            sidebar.bottomAnchor.constraint(equalTo: sidebarHolder.bottomAnchor)
        ])

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        let contentScroll = NSScrollView()
        contentScroll.documentView = content
        contentScroll.hasVerticalScroller = true
        contentScroll.borderType = .bezelBorder
        content.translatesAutoresizingMaskIntoConstraints = false
        content.widthAnchor.constraint(greaterThanOrEqualToConstant: 480).isActive = true

        settingsSplit.isVertical = true
        settingsSplit.dividerStyle = .thin
        settingsSplit.addArrangedSubview(sidebarHolder)
        settingsSplit.addArrangedSubview(contentScroll)
        settingsSplit.translatesAutoresizingMaskIntoConstraints = false
        sidebarHolder.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        contentScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 600).isActive = true

        let ok = NSButton(title: "OK", target: self, action: #selector(saveAndClose))
        ok.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let apply = NSButton(title: "Apply", target: self, action: #selector(applySettings))
        let buttons = NSStackView(views: [ok, cancel, apply])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(settingsSplit)
        root.addSubview(buttons)
        NSLayoutConstraint.activate([
            settingsSplit.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            settingsSplit.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            settingsSplit.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            settingsSplit.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
        view = root
        visibleRoots = roots
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        if let general = roots.first?.children.first {
            let row = outlineView.row(forItem: general)
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            showCategory(general)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !didSetInitialDivider else { return }
        didSetInitialDivider = true
        settingsSplit.setPosition(230, ofDividerAt: 0)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SettingsNode)?.children.count ?? visibleRoots.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SettingsNode)?.children[index] ?? visibleRoots[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? SettingsNode else { return false }
        return !node.children.isEmpty
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SettingsNode else { return nil }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: node.title)
        label.font = node.id == "application" || node.id == "git" || node.id == "plugins" ? .boldSystemFont(ofSize: 12) : .systemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 7), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? SettingsNode else { return }
        showCategory(node)
    }

    func controlTextDidChange(_ obj: Notification) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        visibleRoots = query.isEmpty ? roots : roots.compactMap { filtered($0, query: query) }
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
    }

    private func filtered(_ node: SettingsNode, query: String) -> SettingsNode? {
        let children = node.children.compactMap { filtered($0, query: query) }
        guard node.title.lowercased().contains(query) || !children.isEmpty else { return nil }
        return SettingsNode(node.id, node.title, children)
    }

    private func showCategory(_ node: SettingsNode) {
        content.arrangedSubviews.forEach { content.removeArrangedSubview($0); $0.removeFromSuperview() }
        panel?.title = "Settings - \(node.title)"
        let heading = NSTextField(labelWithString: node.title)
        heading.font = .boldSystemFont(ofSize: 16)
        content.addArrangedSubview(heading)
        switch node.id {
        case "general", "application":
            let source = NSStackView(views: [NSTextField(labelWithString: "Settings source:"), NSButton(radioButtonWithTitle: "Global for all repositories", target: nil, action: nil)])
            source.orientation = .horizontal
            source.spacing = 10
            (source.arrangedSubviews.last as? NSButton)?.state = .on
            content.addArrangedSubview(source)
            content.addArrangedSubview(settingsGroup("Performance", [
                disabledToggle("Show number of changed files on commit button", true),
                disabledToggle("Show number of changed files for artificial commits", true),
                disabledToggle("Show submodules status in browse menu", false),
                disabledToggle("Show stash count on status bar in browse window", false),
                disabledToggle("Show ahead and behind information on status bar in browse window", true),
                disabledToggle("Check for uncommitted changes in checkout branch dialog", true)
            ]))
            content.addArrangedSubview(settingsGroup("Behaviour", [
                disabledToggle("Close Process dialog when process succeeds", false),
                disabledToggle("Show console window when executing git process", false),
                disabledToggle("Use histogram diff algorithm", false),
                disabledToggle("Include untracked files in autostash", false),
                toggle("Open last working directory on startup", value: draft.reopenLastRepository) { self.draft.reopenLastRepository = $0 }
            ]))
        case "git_paths", "git_config", "git":
            content.addArrangedSubview(pathField("Git executable:", value: draft.gitExecutablePath) { self.draft.gitExecutablePath = $0 })
            content.addArrangedSubview(note("The configured executable is used for newly opened repositories."))
        case "appearance", "colors", "fonts", "console", "sorting":
            content.addArrangedSubview(popup("Theme:", values: ApplicationTheme.allCases.map(\.rawValue), selected: draft.theme.rawValue) { value in
                self.draft.theme = ApplicationTheme(rawValue: value) ?? .system
            })
        case "browse":
            content.addArrangedSubview(toggle("Merge common-parent lanes", value: draft.mergeCommonParentLanes) { self.draft.mergeCommonParentLanes = $0 })
            content.addArrangedSubview(toggle("Straighten graph diagonals", value: draft.straightenGraphDiagonals) { self.draft.straightenGraphDiagonals = $0 })
            content.addArrangedSubview(stepper("Maximum recent repositories:", value: draft.maximumRecentRepositories, range: 1...100) { self.draft.maximumRecentRepositories = $0 })
        case "detailed":
            content.addArrangedSubview(toggle("Get remote branches directly from remote", value: pushDraft.loadRemoteBranchesDirectly) { self.pushDraft.loadRemoteBranchesDirectly = $0 })
            content.addArrangedSubview(toggle("Merge common-parent lanes", value: draft.mergeCommonParentLanes) { self.draft.mergeCommonParentLanes = $0 })
            content.addArrangedSubview(toggle("Straighten graph diagonals", value: draft.straightenGraphDiagonals) { self.draft.straightenGraphDiagonals = $0 })
            content.addArrangedSubview(stepper("Maximum recent repositories:", value: draft.maximumRecentRepositories, range: 1...100) { self.draft.maximumRecentRepositories = $0 })
        case "diff":
            content.addArrangedSubview(stepper("Context lines:", value: draft.diffContextLines, range: 0...20) { self.draft.diffContextLines = $0 })
            content.addArrangedSubview(toggle("Ignore whitespace", value: draft.ignoreWhitespace) { self.draft.ignoreWhitespace = $0 })
            content.addArrangedSubview(note("Diff options are persisted; backend application is tracked for a later parity pass."))
        case "commit":
            content.addArrangedSubview(settingsGroup("Commit defaults", [
                toggle("Sign-off commit by default", value: draft.defaultSignOff) { self.draft.defaultSignOff = $0 },
                toggle("Allow empty commit by default", value: draft.defaultAllowEmpty) { self.draft.defaultAllowEmpty = $0 },
                toggle("Ensure the second line of a commit message is empty", value: commitDraft.ensureSecondLineEmpty) { self.commitDraft.ensureSecondLineEmpty = $0 },
                toggle("Remember amend mode", value: commitDraft.rememberAmendState) { self.commitDraft.rememberAmendState = $0 },
                toggle("Select a staged file when the message receives focus", value: commitDraft.selectStagedOnMessageFocus) { self.commitDraft.selectStagedOnMessageFocus = $0 }
            ]))
            content.addArrangedSubview(settingsGroup("Commit window", [
                stepper("Commit-message history entries:", value: commitDraft.historyLimit, range: 1...999) { self.commitDraft.historyLimit = $0 },
                toggle("Only show my commit messages in history", value: commitDraft.showOnlyMyMessages) { self.commitDraft.showOnlyMyMessages = $0 },
                toggle("Close after each successful commit", value: commitDraft.closeAfterCommit) { self.commitDraft.closeAfterCommit = $0 },
                toggle("Close after the last commit", value: commitDraft.closeAfterLastCommit) { self.commitDraft.closeAfterLastCommit = $0 },
                toggle("Refresh changes when the Commit window receives focus", value: commitDraft.refreshOnFocus) { self.commitDraft.refreshOnFocus = $0 }
            ]))
            content.addArrangedSubview(settingsGroup("Visible commands", [
                toggle("Show Commit & Push", value: commitDraft.showCommitAndPush) { self.commitDraft.showCommitAndPush = $0 },
                toggle("Show Reset unstaged changes", value: commitDraft.showResetUnstaged) { self.commitDraft.showResetUnstaged = $0 },
                toggle("Show Reset all changes", value: commitDraft.showResetAll) { self.commitDraft.showResetAll = $0 }
            ]))
        case "git_advanced":
            content.addArrangedSubview(toggle("Auto stash", value: draft.autoStashDuringRebase) { self.draft.autoStashDuringRebase = $0 })
        case "hotkeys":
            content.addArrangedSubview(note("Keyboard shortcut editing is not implemented. Current application shortcuts remain visible in menus."))
        case "ssh":
            content.addArrangedSubview(pathField("External diff tool:", value: draft.externalDiffToolPath) { self.draft.externalDiffToolPath = $0 })
            content.addArrangedSubview(pathField("External merge tool:", value: draft.externalMergeToolPath) { self.draft.externalMergeToolPath = $0 })
            content.addArrangedSubview(note("External tool execution is not implemented."))
        case "advanced":
            content.addArrangedSubview(toggle("Always show advanced options", value: pushDraft.showAdvancedOptions) { self.pushDraft.showAdvancedOptions = $0 })
            content.addArrangedSubview(pathField("Signing key:", value: draft.signingKey) { self.draft.signingKey = $0 })
            content.addArrangedSubview(note("The Commit window can use Git's configured signing behavior, disable signing, sign with the default key, or pass this key explicitly."))
        case "confirmations":
            content.addArrangedSubview(settingsGroup("Confirm actions — Branches", [
                toggle("Push a new branch for the remote", value: pushDraft.confirmNewBranch) { self.pushDraft.confirmNewBranch = $0 },
                toggle("Add a tracking reference for newly pushed branch", value: pushDraft.confirmAddTrackingReference) { self.pushDraft.confirmAddTrackingReference = $0 }
            ]))
            content.addArrangedSubview(settingsGroup("Confirm actions — Commit", [
                toggle("Amend the current commit", value: commitDraft.confirmAmend) { self.commitDraft.confirmAmend = $0 },
                toggle("Commit while HEAD is detached", value: commitDraft.confirmDetachedHead) { self.commitDraft.confirmDetachedHead = $0 },
                toggle("Use force-with-lease when pushing an amended commit", value: commitDraft.forceWithLeaseAfterAmend) { self.commitDraft.forceWithLeaseAfterAmend = $0 }
            ]))
        case "scripts":
            content.addArrangedSubview(pathField("Shell:", value: draft.shellPath) { self.draft.shellPath = $0 })
            content.addArrangedSubview(pathField("Editor:", value: draft.editorPath) { self.draft.editorPath = $0 })
            content.addArrangedSubview(note("Shell and editor execution are not implemented."))
        default:
            content.addArrangedSubview(note("This Git Extensions settings page is present for navigation parity. Its options are not implemented yet."))
        }
        content.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
    }

    private func disabledToggle(_ title: String, _ value: Bool) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        button.state = value ? .on : .off
        button.isEnabled = false
        button.toolTip = "Not implemented yet"
        return button
    }

    private func settingsGroup(_ title: String, _ views: [NSView]) -> NSBox {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        let box = NSBox()
        box.title = title
        box.boxType = .primary
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(stack)
        if let holder = box.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 12),
                stack.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -12),
                stack.topAnchor.constraint(equalTo: holder.topAnchor, constant: 10),
                stack.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -12),
                box.widthAnchor.constraint(greaterThanOrEqualToConstant: 610)
            ])
        }
        return box
    }

    private func toggle(_ title: String, value: Bool, changed: @escaping (Bool) -> Void) -> NSButton {
        let button = CallbackButton(checkboxWithTitle: title, target: nil, action: nil)
        button.state = value ? .on : .off
        button.callback = { changed(button.state == .on) }
        button.target = button
        button.action = #selector(CallbackButton.invoke)
        return button
    }

    private func popup(_ title: String, values: [String], selected: String, changed: @escaping (String) -> Void) -> NSView {
        let control = CallbackPopUpButton()
        control.addItems(withTitles: values)
        control.selectItem(withTitle: selected)
        control.callback = { changed(control.titleOfSelectedItem ?? selected) }
        control.target = control
        control.action = #selector(CallbackPopUpButton.invoke)
        return formRow(title, control)
    }

    private func stepper(_ title: String, value: Int, range: ClosedRange<Int>, changed: @escaping (Int) -> Void) -> NSView {
        let field = NSTextField(string: String(value))
        field.isEditable = false
        field.alignment = .right
        field.widthAnchor.constraint(equalToConstant: 45).isActive = true
        let step = CallbackStepper()
        step.minValue = Double(range.lowerBound)
        step.maxValue = Double(range.upperBound)
        step.integerValue = value
        step.callback = { field.integerValue = step.integerValue; changed(step.integerValue) }
        step.target = step
        step.action = #selector(CallbackStepper.invoke)
        let controls = NSStackView(views: [field, step])
        return formRow(title, controls)
    }

    private func pathField(_ title: String, value: String, changed: @escaping (String) -> Void) -> NSView {
        let field = CallbackTextField(string: value)
        field.widthAnchor.constraint(equalToConstant: 370).isActive = true
        field.callback = { changed(field.stringValue) }
        field.target = field
        field.action = #selector(CallbackTextField.invoke)
        return formRow(title, field)
    }

    private func formRow(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 170).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func note(_ value: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 0
        label.widthAnchor.constraint(equalToConstant: 450).isActive = true
        return label
    }

    @objc private func applySettings() {
        guard validate() else { return }
        store.save(draft)
        store.savePushPreferences(pushDraft)
        store.saveCommitPreferences(commitDraft)
    }
    @objc private func saveAndClose() {
        guard validate() else { return }
        store.save(draft)
        store.savePushPreferences(pushDraft)
        store.saveCommitPreferences(commitDraft)
        finish(.OK)
    }
    @objc private func cancel() { finish(.cancel) }
    func windowWillClose(_ notification: Notification) { finish(.cancel) }
    private func finish(_ response: NSApplication.ModalResponse) {
        guard !didClose else { return }
        didClose = true
        onClose?(response)
    }
    private func validate() -> Bool {
        let path = (draft.gitExecutablePath as NSString).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: path) else {
            let alert = NSAlert()
            alert.messageText = "Git executable is invalid"
            alert.informativeText = "Select an executable Git file before applying settings: \(path)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            if let panel { alert.beginSheetModal(for: panel) }
            return false
        }
        return true
    }
}

private final class CallbackButton: NSButton { var callback: (() -> Void)?; @objc func invoke() { callback?() } }
private final class CallbackPopUpButton: NSPopUpButton { var callback: (() -> Void)?; @objc func invoke() { callback?() } }
private final class CallbackStepper: NSStepper { var callback: (() -> Void)?; @objc func invoke() { callback?() } }
private final class CallbackTextField: NSTextField { var callback: (() -> Void)?; @objc func invoke() { callback?() } }
