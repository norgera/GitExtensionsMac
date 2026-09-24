import GitExtensionsCore
import GitCommands
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
    var onInitializeRepository: (() -> Void)?
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
        logo.font = AppSettingsStore.shared.applicationFont(size: 25, weight: .bold)
        let startTitle = NSTextField(labelWithString: "Start")
        startTitle.font = AppSettingsStore.shared.applicationFont(size: 16, weight: .bold)
        let open = commandButton("Open repository…", action: #selector(openRepository))
        open.keyEquivalent = "o"
        open.keyEquivalentModifierMask = .command
        let clone = commandButton("Clone repository…", action: #selector(cloneRepository))
        let create = commandButton("Create new repository…", action: #selector(initializeRepository))
        let settings = commandButton("Settings…", action: #selector(openSettings))
        let leftStack = NSStackView(views: [logo, startTitle, open, clone, create, settings])
        leftStack.orientation = .vertical
        leftStack.alignment = .leading
        leftStack.spacing = 9
        leftStack.setCustomSpacing(24, after: logo)
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        left.addSubview(leftStack)

        let recentTitle = NSTextField(labelWithString: "Recent repositories")
        recentTitle.font = AppSettingsStore.shared.applicationFont(size: 18, weight: .bold)
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
        label.font = AppSettingsStore.shared.applicationFont(size: 12)
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
        button.font = AppSettingsStore.shared.applicationFont(size: 14)
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
    @objc private func initializeRepository() { onInitializeRepository?() }
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
    static func presentSettings(from window: NSWindow, source: (any RepositorySettingsDataSource)? = nil, repositoryChanged: @escaping () -> Void = {}) async {
        let controller = SettingsViewController(store: .shared, source: source, repositoryChanged: repositoryChanged)
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

    static func presentNetworkWindow(
        kind: NetworkOperationKind,
        initialAction: NetworkDialogInitialAction,
        context: RepositoryNetworkContext,
        source: (any RepositoryRemoteManagingDataSource)?,
        onManageRemotes: @escaping (String?) -> Void,
        onRepositoryChanged: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) -> NSWindowController {
        let controller = NetworkDialogViewController(
            kind: kind,
            initialAction: initialAction,
            context: context,
            source: source,
            onManageRemotes: onManageRemotes,
            onRepositoryChanged: onRepositoryChanged
        )
        let window = NSWindow(contentViewController: controller)
        window.title = "\(kind.rawValue) (\(context.repository.path))"
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
    private var context: RepositoryNetworkContext
    private let source: (any RepositoryRemoteManagingDataSource)?
    private let onManageRemotes: (String?) -> Void
    private let onRepositoryChanged: () -> Void
    private var didClose = false
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
        context: RepositoryNetworkContext,
        source: (any RepositoryRemoteManagingDataSource)?,
        onManageRemotes: @escaping (String?) -> Void,
        onRepositoryChanged: @escaping () -> Void
    ) {
        self.kind = kind
        self.initialAction = initialAction
        self.context = context
        self.source = source
        self.onManageRemotes = onManageRemotes
        self.onRepositoryChanged = onRepositoryChanged
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

        helpNotice.font = AppSettingsStore.shared.applicationFont(size: 12)
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
                .font: AppSettingsStore.shared.applicationFont(size: 12),
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
        let url = NSTextField(string: context.remotes.first?.fetchURL ?? "")
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

        let currentBranch = context.branches.first(where: \.isCurrent)?.name ?? ""
        let local = NSTextField(string: currentBranch)
        localBranchField = local
        let branches = NSPopUpButton()
        branchPopUp = branches
        url.stringValue = context.remotes.first(where: { $0.name == remote.titleOfSelectedItem })?.fetchURL ?? ""
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
        remote.addItems(withTitles: context.remotes.map(\.name).isEmpty ? ["origin"] : context.remotes.map(\.name))
        let currentBranch = context.branches.first(where: \.isCurrent)?.name ?? ""
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
        status.font = AppSettingsStore.shared.applicationFont(size: 10.5)
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
            localBranchField?.stringValue = context.branches.first(where: \.isCurrent)?.name ?? ""
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
        view.window?.title = "\(effectiveKind.rawValue) (\(context.repository.path))"
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
        let current = context.branches.first(where: \.isCurrent)?.name
        let tracking = context.references.first {
            ($0.kind == .currentBranch || $0.kind == .localBranch) && $0.name == current
        }?.trackingRemote
        return tracking ?? context.remotes.first?.name
    }

    private func populateRemotes(selecting name: String?) {
        guard let remotePopUp else { return }
        remotePopUp.removeAllItems()
        remotePopUp.addItem(withTitle: "[ All ]")
        remotePopUp.addItems(withTitles: context.remotes.map(\.name))
        if remotePopUp.numberOfItems == 0 { remotePopUp.addItem(withTitle: "[ All ]") }
        if let name { remotePopUp.selectItem(withTitle: name) }
        updateRemoteURL()
    }

    private func updateRemoteURL() {
        let name = remotePopUp?.titleOfSelectedItem
        remoteURLField?.stringValue = context.remotes.first(where: { $0.name == name })?.fetchURL ?? ""
        let all = name == "[ All ]"
        mergeMode.isEnabled = !all
        rebaseMode.isEnabled = !all
        if all { changePullMode(fetchMode); fetchMode.state = .on }
        populateRemoteBranches()
    }

    private func populateRemoteBranches(advertisedNames: [String]? = nil) {
        guard let branchPopUp else { return }
        let remoteName = remotePopUp?.titleOfSelectedItem
        let currentBranch = context.branches.first(where: \.isCurrent)?.name ?? ""
        let trackedBranch = context.references.first {
            ($0.kind == .currentBranch || $0.kind == .localBranch) && $0.name == currentBranch && $0.trackingRemote == remoteName
        }?.mergeWith
        branchPopUp.removeAllItems()
        if remoteName == "[ All ]" {
            branchPopUp.addItem(withTitle: "*")
        } else if let remote = context.remotes.first(where: { $0.name == remoteName }) {
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
        let selectedName = remotePopUp?.titleOfSelectedItem
        onManageRemotes(selectedName == "[ All ]" ? nil : selectedName)
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
    private let source: (any RepositorySettingsDataSource)?
    private let repositoryChanged: () -> Void
    private var viewerDraft: FileViewerPreferences
    private var viewerRememberDraft: FileViewerRememberPreferences
    private var fontDraft: ApplicationFontPreferences
    private var browseDisplayDraft: BrowseDisplayPreferences
    private var editingFontRole: ApplicationFontRole?
    private var pullDraft: PullPreferences
    private var creationDraft: RepositoryCreationPreferences
    private var checkoutDraft: CheckoutBranchPreferences
    private var treeDraft: RepositoryTreePreferences
    private var tagDraft: TagPreferences
    private var configScope: GitSettingsScope = .effective
    private var configValues: [GitSettingsScope: [String: [String]]] = [:]
    private var configEdits: [GitSettingsScope: [String: String]] = [:]
    private var loadingConfig = false
    private var currentCategoryID = ""
    private var saving = false
    private var draft: AppPreferences
    private var pushDraft: PushPreferences
    private var commitDraft: CommitPreferences
    private var stashDraft: StashPreferences
    private var mergeDraft: MergePreferences
    private var distributedSettings: DistributedSettings?
    private var distributedScope: DistributedSettingsScope = .effective
    private var distributedEdits: [DistributedSettingsScope: [String: String]] = [:]
    private var loadingDistributed = false
    private var revisionLinksDraft: [DistributedSettingsScope: [RevisionLinkDefinition]] = [:]
    private var revisionLinksChanged: Set<DistributedSettingsScope> = []
    private var selectedRevisionLink = 0
    private var encodingDraft: [RepositoryTextEncoding]?
    private var hotkeyDraft: [String: ApplicationKeyChord]?
    private var hotkeyCategory = "Browse"
    private var hotkeyCommand = "openRepository"
    private var colorDraft: ApplicationColorPreferences?
    private lazy var roots: [SettingsNode] = [
        SettingsNode("application", "Git Extensions", [
            SettingsNode("general", "General"),
            SettingsNode("appearance", "Appearance", [
                SettingsNode("sorting", "Sorting"), SettingsNode("colors", "Colors"),
                SettingsNode("fonts", "Fonts"), SettingsNode("console", "Console style")
            ]),
            SettingsNode("revision_links", "Revision links"),
            SettingsNode("scripts", "Scripts"),
            SettingsNode("hotkeys", "Hotkeys"),
            SettingsNode("advanced", "Advanced", [SettingsNode("confirmations", "Confirmations")]),
            SettingsNode("detailed", "Detailed", [
                SettingsNode("browse", "Browse repository window"),
                SettingsNode("commit", "Commit dialog"),
                SettingsNode("diff", "Diff viewer")
            ]),
            SettingsNode("ssh", "SSH")
        ]),
        SettingsNode("git", "Git", [
            SettingsNode("git_paths", "Paths"), SettingsNode("git_config", "Config"),
            SettingsNode("git_advanced", "Advanced")
        ])
    ]
    private var visibleRoots: [SettingsNode] = []
    private let outlineView = NSOutlineView()
    private let searchField = NSSearchField()
    private let content = NSStackView()
    private let settingsSplit = NSSplitView()
    private var didSetInitialDivider = false
    private var didClose = false

    init(store: AppSettingsStore, source: (any RepositorySettingsDataSource)?, repositoryChanged: @escaping () -> Void) {
        self.store = store
        self.source = source
        self.repositoryChanged = repositoryChanged
        viewerDraft = store.fileViewerPreferences
        viewerRememberDraft = store.fileViewerRemember
        fontDraft = store.fontPreferences
        browseDisplayDraft = store.browseDisplayPreferences
        pullDraft = store.pullPreferences
        creationDraft = store.repositoryCreationPreferences
        checkoutDraft = store.checkoutBranchPreferences
        treeDraft = store.repositoryTreePreferences
        tagDraft = store.tagPreferences
        draft = store.preferences
        pushDraft = store.pushPreferences
        commitDraft = store.commitPreferences
        stashDraft = store.stashPreferences
        mergeDraft = store.mergePreferences
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
        outlineView.rowHeight = store.applicationRowHeight(minimum: 23)
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
        let document = TopAlignedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        let contentScroll = NSScrollView()
        contentScroll.documentView = document
        contentScroll.hasVerticalScroller = true
        contentScroll.borderType = .bezelBorder
        content.translatesAutoresizingMaskIntoConstraints = false
        content.widthAnchor.constraint(greaterThanOrEqualToConstant: 480).isActive = true
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: contentScroll.contentView.widthAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])

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
        label.font = store.applicationFont(size: 12, weight: node.id == "application" || node.id == "git" || node.id == "plugins" ? .bold : .regular)
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
        currentCategoryID = node.id
        content.arrangedSubviews.forEach { content.removeArrangedSubview($0); $0.removeFromSuperview() }
        panel?.title = "Settings - \(node.title)"
        let heading = NSTextField(labelWithString: node.title)
        heading.font = AppSettingsStore.shared.applicationFont(size: 16, weight: .bold)
        content.addArrangedSubview(heading)
        switch node.id {
        case "general", "application":
            let source = NSStackView(views: [NSTextField(labelWithString: "Settings source:"), NSButton(radioButtonWithTitle: "Global for all repositories", target: nil, action: nil)])
            source.orientation = .horizontal
            source.spacing = 10
            (source.arrangedSubviews.last as? NSButton)?.state = .on
            content.addArrangedSubview(source)
            let submoduleStatus = toggle("Show submodules status in browse menu", value: browseDisplayDraft.showSubmoduleStatus) { self.browseDisplayDraft.showSubmoduleStatus = $0 }
            func updateSubmoduleStatus() {
                submoduleStatus.isEnabled = self.browseDisplayDraft.showChangedFilesOnCommitButton || self.browseDisplayDraft.showArtificialRevisionCounts
                if !submoduleStatus.isEnabled {
                    submoduleStatus.state = .off
                    self.browseDisplayDraft.showSubmoduleStatus = false
                }
            }
            updateSubmoduleStatus()
            content.addArrangedSubview(settingsGroup("Performance", [
                toggle("Show number of changed files on commit button", value: browseDisplayDraft.showChangedFilesOnCommitButton) { self.browseDisplayDraft.showChangedFilesOnCommitButton = $0; updateSubmoduleStatus() },
                toggle("Show number of changed files for artificial commits", value: browseDisplayDraft.showArtificialRevisionCounts) { self.browseDisplayDraft.showArtificialRevisionCounts = $0; updateSubmoduleStatus() },
                submoduleStatus,
                toggle("Show stash count on status bar in browse window", value: stashDraft.showStashCount) { self.stashDraft.showStashCount = $0 },
                toggle("Show ahead and behind information on status bar in browse window", value: browseDisplayDraft.showAheadBehind) { self.browseDisplayDraft.showAheadBehind = $0 },
                toggle("Check for uncommitted changes in checkout branch dialog", value: checkoutDraft.checkForUncommittedChanges) { self.checkoutDraft.checkForUncommittedChanges = $0 }
            ]))
            content.addArrangedSubview(settingsGroup("Behaviour", [
                toggle("Close Process dialog when process succeeds", value: pullDraft.closeProcessOnSuccess) { self.pullDraft.closeProcessOnSuccess = $0 },
                disabledToggle("Show console window when executing git process", false),
                toggle("Use histogram diff algorithm", value: viewerDraft.usesHistogram) { self.viewerDraft.usesHistogram = $0 },
                toggle("Include untracked files in autostash", value: pullDraft.includeUntrackedInAutoStash) { self.pullDraft.includeUntrackedInAutoStash = $0 },
                toggle("Open last working directory on startup", value: draft.reopenLastRepository) { self.draft.reopenLastRepository = $0 }
            ]))
            content.addArrangedSubview(stepper("Revision grid quick-search timeout (milliseconds):", value: browseDisplayDraft.quickSearchTimeoutMilliseconds, range: 100...1_000_000) { self.browseDisplayDraft.quickSearchTimeoutMilliseconds = $0 })
            content.addArrangedSubview(stepper("Maximum revisions (0 = unlimited):", value: browseDisplayDraft.maximumRevisionCount, range: 0...Int(Int32.max)) { self.browseDisplayDraft.maximumRevisionCount = $0 })
            content.addArrangedSubview(pathField("Default clone destination:", value: creationDraft.cloneDestinationPath) { self.creationDraft.cloneDestinationPath = $0 })
            let pullActions: [(String, PullActionPreference)] = [
                ("Open pull dialog", .openDialog), ("Pull - merge", .merge), ("Pull - rebase", .rebase),
                ("Fetch", .fetch), ("Fetch all", .fetchAll), ("Fetch and prune all", .fetchPruneAll)
            ]
            content.addArrangedSubview(popup("Default Pull button action:", values: pullActions.map(\.0), selected: pullActions.first { $0.1 == pullDraft.defaultAction }!.0) { title in
                self.pullDraft.defaultAction = pullActions.first { $0.0 == title }!.1
            })
            content.addArrangedSubview(popup("Update submodules on checkout:", values: ["Ask", "Yes", "No"], selected: checkoutDraft.updateSubmodulesOnCheckout.map { $0 ? "Yes" : "No" } ?? "Ask") { title in
                self.checkoutDraft.updateSubmodulesOnCheckout = title == "Ask" ? nil : title == "Yes"
            })
        case "git_paths", "git":
            content.addArrangedSubview(pathField("Git executable:", value: draft.gitExecutablePath) { self.draft.gitExecutablePath = $0 })
            content.addArrangedSubview(note("The configured executable is used for newly opened repositories."))
        case "git_config", "git_advanced":
            showGitConfiguration(advanced: node.id == "git_advanced")
        case "sorting":
            content.addArrangedSubview(popup("Order refs by:", values: RepositoryTreeSortBy.allCases.map(\.title), selected: treeDraft.sortBy.title) { value in
                self.treeDraft.sortBy = RepositoryTreeSortBy.allCases.first { $0.title == value } ?? .gitDefault
            })
            content.addArrangedSubview(popup("Sort direction:", values: RepositoryTreeSortOrder.allCases.map(\.rawValue), selected: treeDraft.sortOrder.rawValue) { self.treeDraft.sortOrder = RepositoryTreeSortOrder(rawValue: $0) ?? .ascending })
        case "fonts":
            content.addArrangedSubview(note("Fonts (restart required). Native macOS fonts replace Windows-specific font families."))
            content.addArrangedSubview(toggle("Show end-of-line markers as glyph instead of \\r\\n etc.", value: fontDraft.showEolMarkerAsGlyph) { self.fontDraft.showEolMarkerAsGlyph = $0 })
            for role in ApplicationFontRole.allCases {
                let fallback = role == .application ? NSFont.systemFont(ofSize: 11) : NSFont.monospacedSystemFont(ofSize: role == .commit ? 12 : 11, weight: .regular)
                let font = fontDraft.font(role, fallback: fallback)
                let button = CallbackButton(title: "\(font.displayName ?? font.fontName), \(Int(font.pointSize))", target: nil, action: #selector(CallbackButton.invoke))
                button.font = font
                button.target = button
                button.callback = { [weak self] in
                    guard let self else { return }
                    self.editingFontRole = role
                    NSFontManager.shared.target = self
                    NSFontManager.shared.setSelectedFont(font, isMultiple: false)
                    NSFontManager.shared.orderFrontFontPanel(self)
                }
                content.addArrangedSubview(formRow(role.title + ":", button))
            }
        case "appearance", "console":
            content.addArrangedSubview(popup("Theme:", values: ApplicationTheme.allCases.map(\.rawValue), selected: draft.theme.rawValue) { value in
                self.draft.theme = ApplicationTheme(rawValue: value) ?? .system
            })
        case "colors":
            if colorDraft == nil { colorDraft = store.colorPreferences }
            let themes = ["Native system colors"] + ApplicationThemeReader.availableThemes()
            content.addArrangedSubview(popup("Theme:", values: themes, selected: colorDraft!.themeFile.isEmpty ? themes[0] : colorDraft!.themeFile) { value in
                self.colorDraft?.themeFile = value == themes[0] ? "" : value
                if value == "invariant.css" || value == "light+.css" { self.draft.theme = .light }
                if value == "dark.css" || value == "dark+.css" { self.draft.theme = .dark }
            })
            content.addArrangedSubview(toggle("Colorblind variation", value: colorDraft!.colorblind) { self.colorDraft?.colorblind = $0 })
            content.addArrangedSubview(toggle("Multicolor branches", value: colorDraft!.multicolorBranches) { self.colorDraft?.multicolorBranches = $0 })
            content.addArrangedSubview(toggle("Draw non-relative graph branches gray", value: colorDraft!.nonRelativeGraphGray) { self.colorDraft?.nonRelativeGraphGray = $0 })
            content.addArrangedSubview(toggle("Fill ref labels", value: colorDraft!.fillRefLabels) { self.colorDraft?.fillRefLabels = $0 })
            content.addArrangedSubview(toggle("Draw alternate row background", value: colorDraft!.alternateRows) { self.colorDraft?.alternateRows = $0 })
            content.addArrangedSubview(toggle("Highlight authored revisions", value: colorDraft!.highlightAuthored) { self.colorDraft?.highlightAuthored = $0 })
            content.addArrangedSubview(toggle("Draw non-relative revision text gray", value: colorDraft!.nonRelativeTextGray) { self.colorDraft?.nonRelativeTextGray = $0 })
            for (title, url) in [("Open application themes folder", ApplicationThemeReader.bundledDirectory), ("Open user themes folder", ApplicationThemeReader.userDirectory)] {
                let button = CallbackButton(title: title, target: nil, action: #selector(CallbackButton.invoke))
                button.target = button
                button.callback = { [weak self] in
                    do {
                        if url == ApplicationThemeReader.userDirectory { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
                        NSWorkspace.shared.open(url)
                    } catch {
                        if let panel = self?.panel { Task { await MutationDialogs.showError(error, title: "Themes", window: panel) } }
                    }
                }
                content.addArrangedSubview(button)
            }
            content.addArrangedSubview(note("Custom themes use upstream application-color CSS files in the user themes folder. Reopen this page after adding a file. AppKit retains ownership of system chrome."))
        case "browse":
            content.addArrangedSubview(toggle("Show tags in revision grid", value: tagDraft.showTagsInRevisionGrid) { self.tagDraft.showTagsInRevisionGrid = $0 })
            for root in RepositoryTreeRoot.allCases {
                content.addArrangedSubview(toggle("Show \(root.title) in repository tree", value: treeDraft.visibleRoots.contains(root)) { visible in
                    if visible { self.treeDraft.visibleRoots.insert(root) } else { self.treeDraft.visibleRoots.remove(root) }
                    if root == .tags { self.tagDraft.showTagsInRepositoryTree = visible }
                    if root == .stashes { self.stashDraft.showStashesInRepositoryTree = visible }
                })
            }
            content.addArrangedSubview(toggle("Merge common-parent lanes", value: draft.mergeCommonParentLanes) { self.draft.mergeCommonParentLanes = $0 })
            content.addArrangedSubview(toggle("Straighten graph diagonals", value: draft.straightenGraphDiagonals) { self.draft.straightenGraphDiagonals = $0 })
            content.addArrangedSubview(stepper("Maximum recent repositories:", value: draft.maximumRecentRepositories, range: 1...100) { self.draft.maximumRecentRepositories = $0 })
        case "detailed":
            showDetailedSettings()
            let graphControls = [
                toggle("Merge common-parent lanes", value: draft.mergeCommonParentLanes) { self.draft.mergeCommonParentLanes = $0 },
                toggle("Straighten graph diagonals", value: draft.straightenGraphDiagonals) { self.draft.straightenGraphDiagonals = $0 }
            ]
            graphControls.forEach { $0.isEnabled = distributedScope == .global; content.addArrangedSubview($0) }
        case "diff":
            content.addArrangedSubview(settingsGroup("Remember viewer preferences", [
                toggle("Remember the Ignore whitespaces preference", value: viewerRememberDraft.whitespace) { self.viewerRememberDraft.whitespace = $0 },
                toggle("Remember the Show entire file preference", value: viewerRememberDraft.entireFile) { self.viewerRememberDraft.entireFile = $0 },
                toggle("Remember the Show nonprinting characters preference", value: viewerRememberDraft.nonPrinting) { self.viewerRememberDraft.nonPrinting = $0 },
                toggle("Remember the Number of context lines preference", value: viewerRememberDraft.contextLines) { self.viewerRememberDraft.contextLines = $0 },
                toggle("Remember syntax highlighting", value: viewerRememberDraft.syntaxHighlighting) { self.viewerRememberDraft.syntaxHighlighting = $0 }
            ]))
            let saveDefaults = CallbackButton(title: "Save current view settings as default", target: nil, action: #selector(CallbackButton.invoke))
            saveDefaults.target = saveDefaults
            saveDefaults.callback = { [weak self] in
                guard let self else { return }
                self.store.saveFileViewerPreferences(self.store.fileViewerPreferences)
                self.draft.diffContextLines = self.store.preferences.diffContextLines
                self.draft.ignoreWhitespace = self.store.preferences.ignoreWhitespace
            }
            content.addArrangedSubview(saveDefaults)
            content.addArrangedSubview(stepper("Context lines:", value: viewerDraft.contextLines, range: 0...100) { self.viewerDraft.contextLines = $0 })
            content.addArrangedSubview(popup("Whitespace:", values: DiffWhitespaceMode.allCases.map(\.rawValue), selected: viewerDraft.whitespace.rawValue) { self.viewerDraft.whitespace = DiffWhitespaceMode(rawValue: $0) ?? .none })
            content.addArrangedSubview(toggle("Show entire file", value: viewerDraft.showsEntireFile) { self.viewerDraft.showsEntireFile = $0 })
            content.addArrangedSubview(toggle("Treat all files as text", value: viewerDraft.treatsAllFilesAsText) { self.viewerDraft.treatsAllFilesAsText = $0 })
            content.addArrangedSubview(toggle("Show non-printing characters", value: viewerDraft.showsNonPrintingCharacters) { self.viewerDraft.showsNonPrintingCharacters = $0 })
            content.addArrangedSubview(toggle("Syntax highlighting", value: viewerDraft.showsSyntaxHighlighting) { self.viewerDraft.showsSyntaxHighlighting = $0 })
            let encodings = store.viewerEncodings(including: viewerDraft.textEncoding)
            content.addArrangedSubview(popup("Text encoding:", values: encodings.map(\.title), selected: viewerDraft.textEncoding.title) { title in self.viewerDraft.textEncoding = encodings.first { $0.title == title } ?? .automatic })
            content.addArrangedSubview(note("Apply changes the current viewer preferences. Runtime choices persist for future sessions only with Save current view settings as default; remembered context lines are persisted automatically."))
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
        case "encodings":
            if encodingDraft == nil { encodingDraft = store.includedTextEncodings }
            content.addArrangedSubview(note("Select encodings offered by viewers and Git Config. Unicode and ASCII remain available. Apply saves the list; Cancel preserves the previous list."))
            for encoding in RepositoryTextEncoding.allCases where encoding != .automatic {
                let control = toggle("\(encoding.title) (\(encoding.ianaName))", value: encodingDraft!.contains(encoding)) { included in
                    if included { self.encodingDraft?.append(encoding) }
                    else { self.encodingDraft?.removeAll { $0 == encoding } }
                }
                control.isEnabled = !AppSettingsStore.requiredTextEncodings.contains(encoding)
                content.addArrangedSubview(control)
            }
        case "revision_links":
            showRevisionLinks()
            if distributedScope == .effective {
                func disable(_ view: NSView) {
                    (view as? NSControl)?.isEnabled = false
                    view.subviews.forEach(disable)
                }
                content.arrangedSubviews.dropFirst().forEach(disable)
            }
        case "scripts":
            content.addArrangedSubview(note("Scripts are application preferences, shared across repositories. Configure event hooks, prompts, background execution and context-menu actions in the Scripts window. Keyboard assignments are under Hotkeys → Scripts."))
            let button = CallbackButton(title: "Configure scripts…", target: nil, action: #selector(CallbackButton.invoke))
            button.target = button
            button.callback = { BrowserCommandCenter.perform(.scripts) }
            content.addArrangedSubview(button)
        case "hotkeys":
            showHotkeys()
        case "ssh":
            content.addArrangedSubview(note("Git uses the configured SSH executable, credential helpers and the macOS SSH agent. Configure Git tools and credentials under Git → Config. PuTTY/Pageant controls are Windows-only."))
        case "advanced":
            content.addArrangedSubview(toggle("Always show advanced options", value: pushDraft.showAdvancedOptions) { self.pushDraft.showAdvancedOptions = $0 })
            content.addArrangedSubview(pathField("Signing key:", value: draft.signingKey) { self.draft.signingKey = $0 })
            content.addArrangedSubview(note("The Commit window can use Git's configured signing behavior, disable signing, sign with the default key, or pass this key explicitly."))
        case "confirmations":
            content.addArrangedSubview(settingsGroup("Confirm actions — Branches", [
                toggle("Fetch and prune all", value: pullDraft.confirmFetchAndPruneAll) { self.pullDraft.confirmFetchAndPruneAll = $0 },
                toggle("Delete an unmerged branch", value: !checkoutDraft.dontConfirmDeleteUnmerged) { self.checkoutDraft.dontConfirmDeleteUnmerged = !$0 },
                toggle("Check out a branch directly", value: checkoutDraft.confirmDirectCheckout) { self.checkoutDraft.confirmDirectCheckout = $0 },
                toggle("Push a new branch for the remote", value: pushDraft.confirmNewBranch) { self.pushDraft.confirmNewBranch = $0 },
                toggle("Add a tracking reference for newly pushed branch", value: pushDraft.confirmAddTrackingReference) { self.pushDraft.confirmAddTrackingReference = $0 }
            ]))
            content.addArrangedSubview(settingsGroup("Confirm actions — Commit", [
                toggle("Amend the current commit", value: commitDraft.confirmAmend) { self.commitDraft.confirmAmend = $0 },
                toggle("Commit while HEAD is detached", value: commitDraft.confirmDetachedHead) { self.commitDraft.confirmDetachedHead = $0 },
                toggle("Use force-with-lease when pushing an amended commit", value: commitDraft.forceWithLeaseAfterAmend) { self.commitDraft.forceWithLeaseAfterAmend = $0 }
            ]))
            content.addArrangedSubview(toggle("Confirm stash drop", value: !stashDraft.dontConfirmDrop) { self.stashDraft.dontConfirmDrop = !$0 })
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

    private func showGitConfiguration(advanced: Bool) {
        let scopes = GitSettingsScope.allCases.filter { source != nil || $0 != .local }
        content.addArrangedSubview(popup("Settings source:", values: scopes.map(\.rawValue), selected: configScope.rawValue) { value in
            self.configScope = GitSettingsScope(rawValue: value) ?? .effective
            self.showCategory(SettingsNode(advanced ? "git_advanced" : "git_config", advanced ? "Advanced" : "Config"))
        })
        guard let loaded = configValues[configScope] else {
            content.addArrangedSubview(note("Loading Git configuration…"))
            guard !loadingConfig else { return }
            loadingConfig = true
            let scope = configScope
            Task {
                do {
                    if let source { configValues[scope] = try await source.loadGitSettings(scope) }
                    else { configValues[scope] = try await GitSettingsConfiguration.loadGlobal(scope, executableURL: URL(fileURLWithPath: (draft.gitExecutablePath as NSString).expandingTildeInPath)) }
                    loadingConfig = false
                    if currentCategoryID == "git_config" || currentCategoryID == "git_advanced" {
                        showCategory(SettingsNode(currentCategoryID, currentCategoryID == "git_advanced" ? "Advanced" : "Config"))
                    }
                } catch {
                    loadingConfig = false
                    if currentCategoryID == "git_config" || currentCategoryID == "git_advanced" {
                        content.addArrangedSubview(note(error.localizedDescription))
                    }
                }
            }
            return
        }
        let scope = configScope
        let readOnly = scope == .effective || scope == .system
        func value(_ key: String) -> String { configEdits[scope]?[key] ?? loaded[key]?.last ?? "" }
        @discardableResult func field(_ key: String, _ label: String, browse: Bool = false) -> CallbackTextField {
            let control = CallbackTextField(string: value(key))
            control.widthAnchor.constraint(equalToConstant: 370).isActive = true
            control.delegate = control
            control.isEnabled = !readOnly && (loaded[key]?.count ?? 0) <= 1
            control.callback = { [weak self, weak control] in
                guard let self, let control else { return }
                self.configEdits[scope, default: [:]][key] = control.stringValue
            }
            content.addArrangedSubview(formRow(label, control))
            if browse {
                let button = CallbackButton(title: "Browse…", target: nil, action: #selector(CallbackButton.invoke))
                button.target = button
                button.isEnabled = control.isEnabled
                button.callback = { [weak self, weak control] in
                    guard let self, let control, let owner = self.panel else { return }
                    let picker = NSOpenPanel()
                    picker.canChooseDirectories = false
                    picker.allowsMultipleSelection = false
                    picker.beginSheetModal(for: owner) { result in
                        guard result == .OK, let url = picker.url else { return }
                        control.stringValue = url.path
                        control.callback?()
                    }
                }
                content.addArrangedSubview(button)
            }
            if (loaded[key]?.count ?? 0) > 1 { content.addArrangedSubview(note("\(key) has multiple values; preserved without collapsing them.")) }
            return control
        }
        func choice(_ key: String, _ label: String, _ options: [String]) {
            let raw = value(key)
            let isEmptyBoolean = raw.isEmpty && loaded[key] != nil && configEdits[scope]?[key] == nil && options.contains("false")
            let current = isEmptyBoolean ? "false" : (raw.isEmpty ? "Not set" : raw)
            let row = popup(label, values: ["Not set"] + options + (raw.isEmpty || options.contains(raw) ? [] : [raw]), selected: current) { [weak self] selected in
                self?.configEdits[scope, default: [:]][key] = selected == "Not set" ? "" : selected
            }
            (row as? NSStackView)?.arrangedSubviews.compactMap { $0 as? NSControl }.forEach { $0.isEnabled = !readOnly }
            content.addArrangedSubview(row)
        }
        content.addArrangedSubview(note(readOnly ? "Effective and System values are read-only. Select Global or Local to edit." : "Blank / Not set removes this scope's override. Other scopes and unrelated keys are preserved."))
        if advanced {
            for key in ["pull.rebase", "fetch.prune", "merge.autostash", "rebase.autostash", "rebase.autosquash", "rebase.updaterefs", "rerere.enabled", "rerere.autoupdate"] {
                choice(key, key + ":", ["true", "false"])
            }
        } else {
            field("user.name", "User name:"); field("user.email", "Email:")
            field("core.editor", "Editor:"); field("commit.template", "Commit template:", browse: true)
            if scope != .effective { field("credential.helper", "Credential helper:") }
            choice("core.autocrlf", "Line endings:", ["false", "input", "true"])
            for kind in ["diff", "merge"] {
                let root = "\(kind).guitool"
                let toolField = field(root, kind == "diff" ? "Diff tool:" : "Merge tool:")
                if kind == "merge", scope == .effective, value(root).isEmpty { toolField.stringValue = value("merge.tool") }
                let known = popup("Known tools:", values: ["Choose…"] + GitSettingsTools.names, selected: "Choose…") { selected in
                    guard selected != "Choose…" else { return }
                    self.configEdits[scope, default: [:]][root] = selected
                    self.showCategory(SettingsNode("git_config", "Config"))
                }
                (known as? NSStackView)?.arrangedSubviews.compactMap { $0 as? NSControl }.forEach { $0.isEnabled = !readOnly }
                content.addArrangedSubview(known)
                let tool = toolField.stringValue
                if !tool.isEmpty {
                    let pathField = field("\(kind)tool.\(tool).path", "Tool path:", browse: true)
                    let commandField = field("\(kind)tool.\(tool).cmd", "Tool command:")
                    let suggest = CallbackButton(title: "Suggest", target: nil, action: #selector(CallbackButton.invoke))
                    suggest.target = suggest
                    suggest.isEnabled = !readOnly && GitSettingsTools.names.contains(tool.lowercased()) && commandField.isEnabled
                    suggest.callback = { [weak commandField, weak pathField] in
                        guard let commandField, let pathField,
                              let command = GitSettingsTools.suggestedCommand(tool: tool, path: pathField.stringValue, merge: kind == "merge") else { return }
                        commandField.stringValue = command
                        commandField.callback?()
                    }
                    let previous = pathField.callback
                    pathField.callback = { [weak suggest] in previous?(); if suggest?.isEnabled == true { suggest?.callback?() } }
                    content.addArrangedSubview(suggest)
                }
            }
            choice("i18n.filesencoding", "Files content encoding:", (encodingDraft ?? store.includedTextEncodings).map(\.ianaName))
            let configure = CallbackButton(title: "Configure available encodings…", target: nil, action: #selector(CallbackButton.invoke))
            configure.target = configure
            configure.isEnabled = !readOnly
            configure.callback = { [weak self] in self?.showCategory(SettingsNode("encodings", "Available encodings")) }
            content.addArrangedSubview(configure)
            content.addArrangedSubview(note("After changing a tool name, Apply to load its path and command. Existing unused tool definitions are retained."))
        }
    }

    private func showHotkeys() {
        if hotkeyDraft == nil { hotkeyDraft = store.hotkeyOverrides }
        let categories = ApplicationHotkeys.definitions.map(\.category).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        content.addArrangedSubview(popup("Control:", values: categories, selected: hotkeyCategory) { value in
            self.hotkeyCategory = value
            self.showCategory(SettingsNode("hotkeys", "Hotkeys"))
        })
        let commands = ApplicationHotkeys.definitions.filter { $0.category == hotkeyCategory }
        guard !commands.isEmpty else { return }
        if !commands.contains(where: { $0.id == hotkeyCommand }) { hotkeyCommand = commands[0].id }
        content.addArrangedSubview(popup("Command:", values: commands.map(\.title), selected: commands.first { $0.id == hotkeyCommand }!.title) { value in
            self.hotkeyCommand = commands.first { $0.title == value }!.id
            self.showCategory(SettingsNode("hotkeys", "Hotkeys"))
        })
        let id = hotkeyCommand
        let recorder = SettingsHotkeyRecorder(frame: .zero)
        recorder.title = ApplicationHotkeys.chord(id, overrides: hotkeyDraft!).title
        recorder.widthAnchor.constraint(equalToConstant: 280).isActive = true
        recorder.onRecord = { [weak self] chord in self?.hotkeyDraft?[id] = chord }
        content.addArrangedSubview(formRow("Shortcut:", recorder))
        content.addArrangedSubview(note("Click the shortcut field and press the desired keys. Assignments are specific to the selected control; Apply saves them."))
        for (title, reset) in [("Clear shortcut", false), ("Reset all to defaults", true)] {
            let button = CallbackButton(title: title, target: nil, action: #selector(CallbackButton.invoke))
            button.target = button
            button.callback = { [weak self] in
                guard let self else { return }
                if reset { hotkeyDraft = [:] } else { hotkeyDraft?[id] = .init("") }
                showCategory(SettingsNode("hotkeys", "Hotkeys"))
            }
            content.addArrangedSubview(button)
        }
    }

    private func showRevisionLinks() {
        if let source, distributedSettings == nil {
            content.addArrangedSubview(note("Loading application settings scopes…"))
            guard !loadingDistributed else { return }
            loadingDistributed = true
            Task {
                defer { loadingDistributed = false }
                do {
                    distributedSettings = try await DistributedSettings.loadLocations(from: source)
                    if currentCategoryID == "revision_links" { showCategory(SettingsNode("revision_links", "Revision links")) }
                } catch { content.addArrangedSubview(note(error.localizedDescription)) }
            }
            return
        }
        if source == nil { distributedScope = .global }
        let scopes = source == nil ? [DistributedSettingsScope.global] : DistributedSettingsScope.allCases
        content.addArrangedSubview(popup("Settings source:", values: scopes.map(\.rawValue), selected: distributedScope.rawValue) { value in
            self.distributedScope = DistributedSettingsScope(rawValue: value) ?? .effective
            self.selectedRevisionLink = 0
            self.showCategory(SettingsNode("revision_links", "Revision links"))
        })
        do {
            for scope in [DistributedSettingsScope.local, .distributed, .global] where revisionLinksDraft[scope] == nil {
                let xml = scope == .global ? store.revisionLinksXML : try distributedSettings?.values(scope, global: [:])[RevisionLinkDefinition.settingKey]
                revisionLinksDraft[scope] = try RevisionLinkDefinition.decode(xml)
            }
        } catch {
            content.addArrangedSubview(note("Cannot read revision links: \(error.localizedDescription). Existing definitions will not be overwritten."))
            return
        }
        let visibleScopes: [DistributedSettingsScope] = distributedScope == .effective ? [.local, .distributed, .global] : [distributedScope]
        let entries = visibleScopes.flatMap { scope in
            (revisionLinksDraft[scope] ?? []).indices.map { (scope, $0) }
        }
        func refresh() { showCategory(SettingsNode("revision_links", "Revision links")) }
        func button(_ title: String, _ action: @escaping () -> Void) -> NSButton {
            let button = CallbackButton(title: title, target: nil, action: #selector(CallbackButton.invoke))
            button.target = button; button.callback = action
            return button
        }
        content.addArrangedSubview(button("Add", { [weak self] in
            guard let self else { return }
            var scope = distributedScope
            if scope == .effective {
                scope = .global
                if revisionLinksDraft[.global]?.contains(where: { $0.name == "<new>" }) == true { scope = .distributed }
                if scope == .distributed && revisionLinksDraft[.distributed]?.contains(where: { $0.name == "<new>" }) == true { scope = .local }
            }
            guard revisionLinksDraft[scope]?.contains(where: { $0.name == "<new>" }) != true else { NSSound.beep(); return }
            revisionLinksDraft[scope, default: []].append(RevisionLinkDefinition())
            revisionLinksChanged.insert(scope)
            selectedRevisionLink = visibleScopes.prefix(while: { $0 != scope }).reduce(0) { $0 + (self.revisionLinksDraft[$1]?.count ?? 0) } + (revisionLinksDraft[scope]?.count ?? 1) - 1
            refresh()
        }))
        guard !entries.isEmpty else { content.addArrangedSubview(note("No revision links configured.")); return }
        selectedRevisionLink = min(max(0, selectedRevisionLink), entries.count - 1)
        let titles = entries.enumerated().map { index, entry in
            "\(index + 1). \(revisionLinksDraft[entry.0]![entry.1].name) [\(entry.0.rawValue)]"
        }
        content.addArrangedSubview(popup("Link definitions:", values: titles, selected: titles[selectedRevisionLink]) { value in
            self.selectedRevisionLink = titles.firstIndex(of: value) ?? 0
            refresh()
        })
        let (scope, index) = entries[selectedRevisionLink]
        let definition = revisionLinksDraft[scope]![index]
        func edit(_ change: (inout RevisionLinkDefinition) -> Void) {
            change(&revisionLinksDraft[scope]![index]); revisionLinksChanged.insert(scope)
        }
        content.addArrangedSubview(button("Remove", { [weak self] in
            self?.revisionLinksDraft[scope]?.remove(at: index)
            self?.revisionLinksChanged.insert(scope)
            refresh()
        }))
        content.addArrangedSubview(pathField("Name:", value: definition.name) { value in edit { $0.name = value } })
        content.addArrangedSubview(toggle("Enabled", value: definition.enabled) { value in edit { $0.enabled = value } })
        content.addArrangedSubview(pathField("Search pattern:", value: definition.searchPattern) { value in edit { $0.searchPattern = value } })
        content.addArrangedSubview(pathField("Nested search pattern:", value: definition.nestedSearchPattern) { value in edit { $0.nestedSearchPattern = value } })
        for part in ["Message", "LocalBranches", "RemoteBranches"] {
            content.addArrangedSubview(toggle("Search in \(part)", value: definition.searchInParts.contains(part)) { value in
                edit { if value { $0.searchInParts.insert(part) } else { $0.searchInParts.remove(part) } }
            })
        }
        content.addArrangedSubview(pathField("Use remotes matching:", value: definition.useRemotesPattern) { value in edit { $0.useRemotesPattern = value } })
        content.addArrangedSubview(toggle("Use only first matching remote", value: definition.useOnlyFirstRemote) { value in edit { $0.useOnlyFirstRemote = value } })
        content.addArrangedSubview(pathField("Remote search pattern:", value: definition.remoteSearchPattern) { value in edit { $0.remoteSearchPattern = value } })
        for part in ["URL", "PushURL"] {
            content.addArrangedSubview(toggle("Search remote \(part)", value: definition.remoteSearchInParts.contains(part)) { value in
                edit { if value { $0.remoteSearchInParts.insert(part) } else { $0.remoteSearchInParts.remove(part) } }
            })
        }
        for (formatIndex, format) in definition.formats.enumerated() {
            content.addArrangedSubview(pathField("Link caption:", value: format.caption) { value in edit { $0.formats[formatIndex].caption = value } })
            content.addArrangedSubview(pathField("Link format:", value: format.format) { value in edit { $0.formats[formatIndex].format = value } })
            content.addArrangedSubview(button("Remove link format", { edit { $0.formats.remove(at: formatIndex) }; refresh() }))
        }
        content.addArrangedSubview(button("Add link format", { edit { $0.formats.append(.init(caption: "", format: "")) }; refresh() }))
        content.addArrangedSubview(note("Capture groups use {0}, {1}, …; remote groups precede revision groups. %COMMIT_HASH% inserts the resolved commit ID. Effective shows definitions from all scopes read-only; select a writable scope to edit."))
    }

    private func showDetailedSettings() {
        if let source, distributedSettings == nil {
            content.addArrangedSubview(note("Loading application settings scopes…"))
            guard !loadingDistributed else { return }
            loadingDistributed = true
            Task {
                defer { loadingDistributed = false }
                do {
                    distributedSettings = try await DistributedSettings.loadLocations(from: source)
                    if currentCategoryID == "detailed" { showCategory(SettingsNode("detailed", "Detailed")) }
                } catch {
                    if currentCategoryID == "detailed" { content.addArrangedSubview(note(error.localizedDescription)) }
                }
            }
            return
        }
        if source == nil { distributedScope = .global }
        let scopes = source == nil ? [DistributedSettingsScope.global] : DistributedSettingsScope.allCases
        content.addArrangedSubview(popup("Settings source:", values: scopes.map(\.rawValue), selected: distributedScope.rawValue) { value in
            self.distributedScope = DistributedSettingsScope(rawValue: value) ?? .effective
            self.showCategory(SettingsNode("detailed", "Detailed"))
        })
        let global = [DistributedSettings.remoteBranches: String(pushDraft.loadRemoteBranchesDirectly),
                      DistributedSettings.mergeLog: String(mergeDraft.addLogMessages),
                      DistributedSettings.mergeLogCount: String(mergeDraft.logMessagesCount)]
        do {
            func pending(_ scope: DistributedSettingsScope) throws -> [String: String] {
                var values = try distributedSettings?.values(scope, global: global) ?? global
                for (key, value) in distributedEdits[scope] ?? [:] { values[key] = value.isEmpty ? nil : value }
                return values
            }
            let values: [String: String]
            if distributedScope == .effective {
                values = try pending(.global).merging(pending(.distributed), uniquingKeysWith: { _, new in new })
                    .merging(pending(.local), uniquingKeysWith: { _, new in new })
            } else { values = try pending(distributedScope) }
            let scope = distributedScope
            for (key, label) in [(DistributedSettings.remoteBranches, "Get remote branches directly from remote"), (DistributedSettings.mergeLog, "Add merge log messages")] {
                let value = distributedEdits[scope]?[key] ?? values[key] ?? ""
                let row = popup(label + ":", values: ["Not set", "true", "false"], selected: value.isEmpty ? "Not set" : value.lowercased()) { value in
                    let value = value == "Not set" ? "" : value
                    self.distributedEdits[scope, default: [:]][key] = value
                    if scope == .global {
                        if key == DistributedSettings.remoteBranches { self.pushDraft.loadRemoteBranchesDirectly = value == "true" }
                        else { self.mergeDraft.addLogMessages = value == "true" }
                    }
                }
                (row as? NSStackView)?.arrangedSubviews.compactMap { $0 as? NSControl }.forEach { $0.isEnabled = scope != .effective }
                content.addArrangedSubview(row)
            }
            let key = DistributedSettings.mergeLogCount
            let row = pathField("Merge log messages count:", value: distributedEdits[scope]?[key] ?? values[key] ?? "") { value in
                self.distributedEdits[scope, default: [:]][key] = value
                if scope == .global, let count = Int(value) { self.mergeDraft.logMessagesCount = count }
            }
            if let field = (row as? NSStackView)?.arrangedSubviews.compactMap({ $0 as? CallbackTextField }).first {
                let changed = field.callback
                field.callback = { [weak field] in
                    changed?()
                    guard let field else { return }
                    let valid = field.stringValue.isEmpty || DistributedSettings.normalizedMergeLogCount(field.stringValue) != nil
                    field.drawsBackground = true
                    field.backgroundColor = valid ? .textBackgroundColor : .systemRed
                    field.toolTip = valid ? nil : "Invalid number: applying will remove this override."
                }
            }
            (row as? NSStackView)?.arrangedSubviews.compactMap { $0 as? NSControl }.forEach { $0.isEnabled = scope != .effective }
            content.addArrangedSubview(row)
            content.addArrangedSubview(note("Local overrides are private to this repository. Distributed overrides are stored in the working directory's GitExtensions.settings file and may be versioned. Effective settings are read-only."))
        } catch { content.addArrangedSubview(note(error.localizedDescription)) }
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
        let field = CallbackTextField(string: String(value))
        field.delegate = field
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = NSNumber(value: range.lowerBound)
        formatter.maximum = NSNumber(value: range.upperBound)
        field.formatter = formatter
        field.alignment = .right
        let fieldWidth = field.widthAnchor.constraint(equalToConstant: 100)
        fieldWidth.priority = .defaultHigh
        fieldWidth.isActive = true
        let step = CallbackStepper()
        step.minValue = Double(range.lowerBound)
        step.maxValue = Double(range.upperBound)
        step.integerValue = value
        field.callback = {
            guard let number = Int(field.stringValue), range.contains(number) else { return }
            step.integerValue = number
            changed(number)
        }
        step.callback = { field.integerValue = step.integerValue; changed(step.integerValue) }
        step.target = step
        step.action = #selector(CallbackStepper.invoke)
        let controls = NSStackView(views: [field, step])
        return formRow(title, controls)
    }

    private func pathField(_ title: String, value: String, changed: @escaping (String) -> Void) -> NSView {
        let field = CallbackTextField(string: value)
        field.delegate = field
        let fieldWidth = field.widthAnchor.constraint(equalToConstant: 370)
        fieldWidth.priority = .defaultHigh
        fieldWidth.isActive = true
        field.callback = { changed(field.stringValue) }
        field.target = field
        field.action = #selector(CallbackTextField.invoke)
        return formRow(title, field)
    }

    private func formRow(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .left
        let labelWidth = label.widthAnchor.constraint(equalToConstant: 300)
        labelWidth.priority = .defaultHigh
        labelWidth.isActive = true
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
        saveSettings(closeAfter: false)
    }
    @objc func changeFont(_ sender: NSFontManager) {
        guard let role = editingFontRole else { return }
        let fallback = role == .application ? NSFont.systemFont(ofSize: 11) : NSFont.monospacedSystemFont(ofSize: role == .commit ? 12 : 11, weight: .regular)
        let selected = sender.convert(fontDraft.font(role, fallback: fallback))
        guard role != .code || selected.isFixedPitch else { NSSound.beep(); return }
        fontDraft.fonts[role] = StoredApplicationFont(selected)
        showCategory(SettingsNode("fonts", "Fonts"))
    }
    @objc private func saveAndClose() {
        saveSettings(closeAfter: true)
    }
    private func saveSettings(closeAfter: Bool) {
        guard panel?.makeFirstResponder(nil) != false else { return }
        guard !saving, validate() else { return }
        saving = true
        func controls(in view: NSView) -> [NSControl] {
            (view as? NSControl).map { [$0] } ?? view.subviews.flatMap { controls(in: $0) }
        }
        let enabledControls = controls(in: view).filter(\.isEnabled)
        enabledControls.forEach { $0.isEnabled = false }
        let edits = configEdits
        Task {
            defer { enabledControls.forEach { $0.isEnabled = true } }
            var changed = false
            do {
                for scope in revisionLinksChanged where scope != .global {
                    let xml = RevisionLinkDefinition.encode(revisionLinksDraft[scope] ?? [])
                    if let distributedSettings {
                        let url = scope == .local ? distributedSettings.localURL : distributedSettings.distributedURL
                        changed = try DistributedSettings.write([RevisionLinkDefinition.settingKey: xml], to: url) || changed
                    }
                }
                if let distributedSettings {
                    for (scope, url) in [(DistributedSettingsScope.local, distributedSettings.localURL), (.distributed, distributedSettings.distributedURL)] {
                        let edits = distributedEdits[scope] ?? [:]
                        if !edits.isEmpty {
                            changed = try DistributedSettings.write(edits.mapValues { $0.isEmpty ? nil : $0 }, to: url) || changed
                        }
                    }
                }
                for scope in GitSettingsScope.allCases {
                    for (key, value) in (edits[scope] ?? [:]).sorted(by: { $0.key < $1.key }) {
                        let existing = configValues[scope]?[key]
                        if value.isEmpty { guard existing != nil else { continue } }
                        else { guard value != existing?.last else { continue } }
                        if let source { try await source.saveGitSetting(key, value: value.isEmpty ? nil : value, scope: scope) }
                        else { try await GitSettingsConfiguration.saveGlobal(key, value: value.isEmpty ? nil : value, scope: scope, executableURL: URL(fileURLWithPath: (draft.gitExecutablePath as NSString).expandingTildeInPath)) }
                        changed = true
                        configValues[scope]?[key] = value.isEmpty ? nil : [value]
                    }
                }
                store.saveFileViewerRemember(viewerRememberDraft)
                if let colorDraft { store.colorPreferences = colorDraft }
                if let hotkeyDraft { store.hotkeyOverrides = hotkeyDraft }
                if let encodingDraft { store.includedTextEncodings = encodingDraft }
                if revisionLinksChanged.contains(.global) {
                    store.revisionLinksXML = RevisionLinkDefinition.encode(revisionLinksDraft[.global] ?? [])
                }
                revisionLinksChanged = []
                store.saveFontPreferences(fontDraft)
                store.saveBrowseDisplayPreferences(browseDisplayDraft)
                store.applyFileViewerPreferences(viewerDraft)
                store.savePushPreferences(pushDraft); store.saveCommitPreferences(commitDraft)
                store.saveStashPreferences(stashDraft); store.savePullPreferences(pullDraft)
                store.saveRepositoryCreationPreferences(creationDraft)
                store.saveMergePreferences(mergeDraft)
                store.saveCheckoutBranchPreferences(checkoutDraft)
                store.saveRepositoryTreePreferences(treeDraft); store.saveTagPreferences(tagDraft)
                store.save(draft)
                configEdits = [:]; configValues = [:]
                distributedEdits = [:]
                saving = false
                if changed { repositoryChanged() }
                if closeAfter { finish(.OK) }
                else if let node = outlineView.item(atRow: outlineView.selectedRow) as? SettingsNode { showCategory(node) }
            } catch {
                saving = false
                if changed { repositoryChanged() }
                if let panel { await MutationDialogs.showError(error, title: "Settings", window: panel) }
            }
        }
    }
    @objc private func cancel() { if !saving { finish(.cancel) } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !saving }
    func windowWillClose(_ notification: Notification) { finish(.cancel) }
    private func finish(_ response: NSApplication.ModalResponse) {
        guard !didClose else { return }
        didClose = true
        if editingFontRole != nil {
            NSFontManager.shared.target = nil
            NSFontPanel.shared.orderOut(nil)
        }
        onClose?(response)
    }
    private func validate() -> Bool {
        if let colorDraft, !colorDraft.themeFile.isEmpty {
            do { _ = try ApplicationThemeReader.load(colorDraft.themeFile, colorblind: colorDraft.colorblind) }
            catch {
                let alert = NSAlert(); alert.messageText = "Cannot load theme"; alert.informativeText = error.localizedDescription
                if let panel { alert.beginSheetModal(for: panel) }
                return false
            }
        }
        for scope in Array(distributedEdits.keys) {
            if let value = distributedEdits[scope]?[DistributedSettings.mergeLogCount] {
                let normalized = DistributedSettings.normalizedMergeLogCount(value)
                distributedEdits[scope]?[DistributedSettings.mergeLogCount] = normalized ?? ""
                if scope == .global { mergeDraft.logMessagesCount = normalized.flatMap(Int.init) ?? 20 }
            }
        }
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
private final class CallbackTextField: NSTextField, NSTextFieldDelegate {
    var callback: (() -> Void)?
    @objc func invoke() { callback?() }
    func controlTextDidChange(_ notification: Notification) { callback?() }
    func controlTextDidEndEditing(_ notification: Notification) { callback?() }
}
