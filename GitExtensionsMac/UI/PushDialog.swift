import GitExtensionsCore
import GitCommands
import AppKit

@MainActor
enum PushDialog {
    static func present(
        source: any RepositoryPushingDataSource,
        context: RepositoryNetworkContext,
        initialBranch: String? = nil,
        executeImmediately: Bool = false,
        initialForceWithLease: Bool = false,
        onManageRemotes: @escaping (String?, String?) -> Void,
        onRepositoryChanged: @escaping (RevisionID?) -> Void,
        onCompletion: ((Bool) -> Void)? = nil,
        onClose: @escaping () -> Void
    ) -> NSWindowController {
        let controller = PushDialogViewController(
            source: source,
            context: context,
            initialBranch: initialBranch,
            executeImmediately: executeImmediately,
            initialForceWithLease: initialForceWithLease,
            onManageRemotes: onManageRemotes,
            onRepositoryChanged: onRepositoryChanged
        )
        let window = NSWindow(contentViewController: controller)
        window.title = "Push (\(context.repository.path))"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 584, height: 290))
        window.minSize = NSSize(width: 600, height: 329)
        window.isReleasedWhenClosed = false
        window.delegate = controller
        controller.window = window
        controller.onClose = onClose
        controller.onCompletion = onCompletion
        let windowController = NSWindowController(window: window)
        windowController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        return windowController
    }
}

@MainActor
private final class PushDialogViewController: NSViewController,
    NSWindowDelegate, NSComboBoxDelegate, NSTextFieldDelegate, NSTabViewDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static let allRefs = "[ All ]"
    private static let head = "HEAD"

    weak var window: NSWindow?
    var onClose: (() -> Void)?
    var onCompletion: ((Bool) -> Void)?

    private let source: any RepositoryPushingDataSource
    private var context: RepositoryNetworkContext
    private let initialBranch: String?
    private let executeImmediately: Bool
    private let initialForceWithLease: Bool
    private let onManageRemotes: (String?, String?) -> Void
    private let onRepositoryChanged: (RevisionID?) -> Void
    private let settings = AppSettingsStore.shared
    private var pushState: RepositoryPushState?
    private var didClose = false
    private var didBecomeKeyOnce = false
    private var didAttemptImmediateExecution = false
    private var lastPushCompleted = false
    private var operationTask: Task<Void, Never>?
    private var pullWindowController: NSWindowController?
    private var multipleBranchTask: Task<Void, Never>?

    private let remoteChoice = NSButton(radioButtonWithTitle: "Remote", target: nil, action: nil)
    private let urlChoice = NSButton(radioButtonWithTitle: "Url", target: nil, action: nil)
    private let remoteCombo = NSComboBox()
    private let destinationCombo = NSComboBox()
    private let manageRemotesButton = NSButton(title: "Manage remotes", target: nil, action: nil)
    private let browseButton = NSButton(title: "Browse…", target: nil, action: nil)
    private let tabs = NSTabView()
    private let localBranchCombo = NSComboBox()
    private let remoteBranchCombo = NSComboBox()
    private let tagCombo = NSComboBox()
    private let showOptionsButton = NSButton()
    private let advancedOptions = NSView()
    private let forceWithLease = NSButton(checkboxWithTitle: "Force with lease", target: nil, action: nil)
    private let forceBranches = NSButton(checkboxWithTitle: "Force push", target: nil, action: nil)
    private let replaceTracking = NSButton(checkboxWithTitle: "Replace tracking reference", target: nil, action: nil)
    private let createPullRequest = NSButton(checkboxWithTitle: "Create pull request after push", target: nil, action: nil)
    private let recursiveSubmodules = NSPopUpButton()
    private let forceTags = NSButton(checkboxWithTitle: "Force push", target: nil, action: nil)
    private let branchTable = NSTableView()
    private var branchRows: [PushBranchRow] = []
    private let pullButton = NSButton(title: "Pull", target: nil, action: nil)
    private let pushButton = NSButton(title: "Push", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "Loading repository state…")

    init(
        source: any RepositoryPushingDataSource,
        context: RepositoryNetworkContext,
        initialBranch: String?,
        executeImmediately: Bool,
        initialForceWithLease: Bool,
        onManageRemotes: @escaping (String?, String?) -> Void,
        onRepositoryChanged: @escaping (RevisionID?) -> Void
    ) {
        self.source = source
        self.context = context
        self.initialBranch = initialBranch
        self.executeImmediately = executeImmediately
        self.initialForceWithLease = initialForceWithLease
        self.onManageRemotes = onManageRemotes
        self.onRepositoryChanged = onRepositoryChanged
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }
    deinit {
        operationTask?.cancel()
        multipleBranchTask?.cancel()
    }

    override func loadView() {
        let root = NSView()
        let destination = makeDestinationGroup()
        let tabView = makeTabs()
        let separator = NSBox()
        separator.boxType = .separator
        let footer = makeFooter()
        for child in [destination, tabView, separator, footer] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        NSLayoutConstraint.activate([
            destination.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            destination.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            destination.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            destination.heightAnchor.constraint(equalToConstant: 80),
            tabView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            tabView.topAnchor.constraint(equalTo: destination.bottomAnchor, constant: 6),
            tabView.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -6),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 11),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            footer.heightAnchor.constraint(equalToConstant: 34)
        ])
        view = root
        configureActions()
        updateSourceControls()
        setAdvancedOptionsVisible(settings.pushPreferences.showAdvancedOptions, resize: false)
        reloadRepositoryState()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(remoteCombo)
    }

    private func makeDestinationGroup() -> NSView {
        remoteChoice.state = .on
        remoteChoice.setAccessibilityLabel("Push to remote")
        urlChoice.setAccessibilityLabel("Push to URL")
        remoteCombo.isEditable = false
        remoteCombo.completes = true
        remoteCombo.delegate = self
        destinationCombo.isEditable = true
        destinationCombo.completes = true
        destinationCombo.delegate = self
        destinationCombo.addItems(withObjectValues: settings.pushPreferences.recentURLs)
        manageRemotesButton.image = AppKitFactory.resourceImage("Remotes", accessibilityDescription: "Manage remotes")
        manageRemotesButton.imagePosition = .imageLeading
        let grid = NSGridView(views: [
            [remoteChoice, remoteCombo, manageRemotesButton],
            [urlChoice, destinationCombo, browseButton]
        ])
        grid.column(at: 0).width = 106
        grid.column(at: 1).width = 262
        grid.column(at: 2).width = 150
        grid.column(at: 1).xPlacement = .fill
        grid.column(at: 2).xPlacement = .fill
        grid.rowSpacing = 5
        grid.columnSpacing = 6
        return group("Push to", content: grid, horizontalInset: 6, verticalInset: 4)
    }

    private func makeTabs() -> NSTabView {
        tabs.delegate = self
        let items: [(String, String, NSView)] = [
            ("branches", "Push branches", makeBranchTab()),
            ("tags", "Push tags", makeTagTab()),
            ("multiple", "Push multiple branches", makeMultipleTab())
        ]
        for (identifier, label, content) in items {
            let item = NSTabViewItem(identifier: identifier)
            item.label = label
            item.view = content
            tabs.addTabViewItem(item)
        }
        tabs.setAccessibilityLabel("Push operation")
        return tabs
    }

    private func makeBranchTab() -> NSView {
        let content = NSView()
        localBranchCombo.isEditable = true
        localBranchCombo.completes = true
        localBranchCombo.delegate = self
        remoteBranchCombo.isEditable = true
        remoteBranchCombo.completes = true
        remoteBranchCombo.delegate = self

        let branchLabel = NSTextField(labelWithString: "Branch to push")
        branchLabel.alignment = .left
        let toLabel = NSTextField(labelWithString: "to")
        let branchRow = NSGridView(views: [[branchLabel, localBranchCombo, toLabel, remoteBranchCombo]])
        branchRow.column(at: 0).width = 110
        branchRow.column(at: 1).width = 197
        branchRow.column(at: 2).width = 20
        branchRow.column(at: 3).width = 197
        branchRow.column(at: 1).xPlacement = .fill
        branchRow.column(at: 3).xPlacement = .fill
        branchRow.columnSpacing = 4
        branchRow.translatesAutoresizingMaskIntoConstraints = false

        showOptionsButton.isBordered = false
        showOptionsButton.alignment = .left
        showOptionsButton.attributedTitle = NSAttributedString(
            string: "Show options",
            attributes: [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        )
        showOptionsButton.translatesAutoresizingMaskIntoConstraints = false
        configureAdvancedOptions()
        advancedOptions.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(branchRow)
        content.addSubview(showOptionsButton)
        content.addSubview(advancedOptions)
        NSLayoutConstraint.activate([
            branchRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 6),
            branchRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -7),
            branchRow.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            showOptionsButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            showOptionsButton.topAnchor.constraint(equalTo: branchRow.bottomAnchor, constant: 3),
            advancedOptions.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 5),
            advancedOptions.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -7),
            advancedOptions.topAnchor.constraint(equalTo: branchRow.bottomAnchor, constant: 3),
            advancedOptions.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -3)
        ])
        return content
    }

    private func configureAdvancedOptions() {
        recursiveSubmodules.addItems(withTitles: RepositoryPushSubmoduleMode.allCases.map(\.title))
        recursiveSubmodules.selectItem(at: settings.pushPreferences.recursiveSubmodules.rawValue)
        recursiveSubmodules.setAccessibilityLabel("Recursive submodules")
        forceWithLease.toolTip = "Force with lease only overwrites remote work that is present in your local remote-tracking refs."
        let forceRow = NSStackView(views: [forceWithLease, forceBranches])
        forceRow.orientation = .horizontal
        forceRow.spacing = 10
        let recursiveLabel = NSTextField(labelWithString: "Recursive submodules")
        let recursiveRow = NSStackView(views: [recursiveLabel, recursiveSubmodules])
        recursiveRow.orientation = .horizontal
        recursiveRow.alignment = .centerY
        recursiveRow.spacing = 4
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let top = NSStackView(views: [forceRow, spacer, recursiveRow])
        top.orientation = .horizontal
        top.alignment = .centerY
        let stack = NSStackView(views: [top, replaceTracking, createPullRequest])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        advancedOptions.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: advancedOptions.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: advancedOptions.trailingAnchor),
            stack.topAnchor.constraint(equalTo: advancedOptions.topAnchor),
            stack.bottomAnchor.constraint(equalTo: advancedOptions.bottomAnchor)
        ])
    }

    private func makeTagTab() -> NSView {
        let content = NSView()
        tagCombo.isEditable = true
        tagCombo.completes = true
        let label = NSTextField(labelWithString: "Tag to push")
        label.alignment = .left
        let grid = NSGridView(views: [[label, tagCombo]])
        grid.column(at: 0).width = 110
        grid.translatesAutoresizingMaskIntoConstraints = false
        forceTags.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(grid)
        content.addSubview(forceTags)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 6),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -155),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            forceTags.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 121),
            forceTags.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 5)
        ])
        return content
    }

    private func makeMultipleTab() -> NSView {
        branchTable.usesAlternatingRowBackgroundColors = true
        branchTable.rowHeight = 20
        branchTable.intercellSpacing = NSSize(width: 1, height: 1)
        branchTable.allowsEmptySelection = true
        branchTable.delegate = self
        branchTable.dataSource = self
        let definitions: [(String, String, CGFloat)] = [
            ("local", "Local Branch", 111),
            ("remote", "Remote Branch", 111),
            ("ahead", "Ahead/Behind", 86),
            ("push", "Push", 42),
            ("force", "Force", 46),
            ("delete", "Delete Remote Branch", 150)
        ]
        for (identifier, title, width) in definitions {
            let column = NSTableColumn(identifier: .init(identifier))
            column.title = title
            column.width = width
            column.minWidth = identifier == "local" || identifier == "remote" ? 80 : width
            branchTable.addTableColumn(column)
        }
        let menu = NSMenu(title: "Push selection")
        menu.addItem(withTitle: "Unselect all", action: #selector(unselectAllRows), keyEquivalent: "")
        menu.addItem(withTitle: "Select tracked", action: #selector(selectTrackedRows), keyEquivalent: "")
        menu.addItem(withTitle: "Select all", action: #selector(selectAllRows), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        branchTable.menu = menu
        let header = PushBranchHeaderView()
        header.pushSelectionMenu = menu
        branchTable.headerView = header
        let scroll = NSScrollView()
        scroll.documentView = branchTable
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        return scroll
    }

    private func makeFooter() -> NSView {
        pullButton.widthAnchor.constraint(equalToConstant: 101).isActive = true
        pushButton.widthAnchor.constraint(equalToConstant: 101).isActive = true
        pushButton.image = AppKitFactory.resourceImage("ArrowUp", accessibilityDescription: "Push")
        pushButton.imagePosition = .imageLeading
        pushButton.keyEquivalent = "\r"
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 10.5)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [pullButton, statusLabel, spacer, pushButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func configureActions() {
        remoteChoice.target = self; remoteChoice.action = #selector(destinationModeChanged(_:))
        urlChoice.target = self; urlChoice.action = #selector(destinationModeChanged(_:))
        manageRemotesButton.target = self; manageRemotesButton.action = #selector(manageRemotes)
        browseButton.target = self; browseButton.action = #selector(browseForDestination)
        localBranchCombo.target = self; localBranchCombo.action = #selector(localBranchChanged)
        showOptionsButton.target = self; showOptionsButton.action = #selector(showAdvancedOptions)
        forceWithLease.target = self; forceWithLease.action = #selector(forceWithLeaseChanged)
        forceBranches.target = self; forceBranches.action = #selector(forceBranchesChanged)
        forceTags.target = self; forceTags.action = #selector(forceTagsChanged)
        pullButton.target = self; pullButton.action = #selector(openPull)
        pushButton.target = self; pushButton.action = #selector(push)
    }

    private func reloadRepositoryState(selectRemote: String? = nil) {
        operationTask?.cancel()
        pushButton.isEnabled = false
        statusLabel.stringValue = "Loading repository state…"
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                async let loadedPushState = source.loadPushState()
                async let repositoryState = source.loadRepositoryState()
                let state = try await loadedPushState
                let refreshedContext = try await repositoryState.networkContext
                guard !Task.isCancelled else { return }
                context = refreshedContext
                pushState = state
                populateRemotes(selecting: selectRemote ?? remoteCombo.stringValue)
                populateLocalBranches()
                populateTags()
                updateRemoteSelection(resetBranch: true)
                createPullRequest.isEnabled = pullRequestURL(branch: selectedLocalBranch()) != nil
                pushButton.isEnabled = true
                statusLabel.stringValue = state.isDetached ? "Detached HEAD — enter an explicit destination branch" : "Ready"
                operationTask = nil
                attemptImmediateExecutionIfReady()
            } catch is CancellationError {
                return
            } catch {
                statusLabel.stringValue = error.localizedDescription
                operationTask = nil
            }
        }
    }

    private func populateRemotes(selecting requested: String?) {
        guard let state = pushState else { return }
        let remotes = state.remotes.filter { !$0.isDisabled }
        remoteCombo.removeAllItems()
        remoteCombo.addItems(withObjectValues: remotes.map(\.name))
        let preferred = remotes.contains(where: { $0.name == requested }) ? requested : state.preferredRemoteName
        if let preferred { remoteCombo.stringValue = preferred }
        if remoteCombo.stringValue.isEmpty, let first = remotes.first { remoteCombo.stringValue = first.name }
    }

    private func populateLocalBranches() {
        guard let state = pushState else { return }
        let previous = localBranchCombo.stringValue
        localBranchCombo.removeAllItems()
        localBranchCombo.addItems(withObjectValues: [Self.allRefs, Self.head] + state.localBranches.map(\.name))
        let desired = initialBranch ?? (!previous.isEmpty ? previous : (state.isDetached ? Self.head : state.currentBranch))
        localBranchCombo.stringValue = desired ?? ""
        if initialForceWithLease {
            forceWithLease.state = .on
            forceBranches.state = .off
        }
        updateRemoteBranchForLocalSelection()
    }

    private func populateTags() {
        guard let state = pushState else { return }
        tagCombo.removeAllItems()
        tagCombo.addItems(withObjectValues: [Self.allRefs] + state.tags)
        tagCombo.stringValue = Self.allRefs
    }

    private func updateSourceControls() {
        let isURL = urlChoice.state == .on
        remoteChoice.state = isURL ? .off : .on
        urlChoice.state = isURL ? .on : .off
        remoteCombo.isEnabled = !isURL
        manageRemotesButton.isEnabled = !isURL
        destinationCombo.isEnabled = isURL
        browseButton.isEnabled = isURL
        if isURL {
            destinationCombo.stringValue = destinationCombo.stringValue
        } else {
            updateRemoteSelection(resetBranch: true)
        }
    }

    private func updateRemoteSelection(resetBranch: Bool) {
        guard let state = pushState,
              let remote = state.remotes.first(where: { !$0.isDisabled && $0.name == remoteCombo.stringValue })
        else {
            destinationCombo.stringValue = ""
            return
        }
        destinationCombo.stringValue = remote.pushURL?.isEmpty == false ? remote.pushURL! : remote.fetchURL
        if resetBranch { updateRemoteBranchForLocalSelection() }
        createPullRequest.isEnabled = pullRequestURL(branch: selectedLocalBranch()) != nil
        if tabs.selectedTabViewItem?.identifier as? String == "multiple" { populateMultipleBranches() }
    }

    private func updateRemoteBranchForLocalSelection() {
        guard let state = pushState else { return }
        let local = selectedLocalBranch()
        remoteBranchCombo.removeAllItems()
        if !local.isEmpty, local != Self.allRefs, local != Self.head { remoteBranchCombo.addItem(withObjectValue: local) }
        let remoteName = remoteCombo.stringValue
        let names = state.remoteBranches.filter { $0.remote == remoteName }.map(\.name)
        remoteBranchCombo.addItems(withObjectValues: names.filter { $0 != local })
        if local == Self.allRefs {
            remoteBranchCombo.stringValue = ""
            remoteBranchCombo.isEnabled = false
        } else if local == Self.head {
            remoteBranchCombo.stringValue = ""
            remoteBranchCombo.isEnabled = true
        } else {
            remoteBranchCombo.stringValue = state.defaultRemoteBranch(localBranch: local, remoteName: remoteName)
            remoteBranchCombo.isEnabled = true
        }
        createPullRequest.isEnabled = pullRequestURL(branch: local) != nil
    }

    private func selectedLocalBranch() -> String {
        localBranchCombo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func populateMultipleBranches() {
        multipleBranchTask?.cancel()
        guard let state = pushState else { return }
        let remoteName = remoteCombo.stringValue
        let cached = state.remoteBranches.filter { $0.remote == remoteName }
        if !settings.pushPreferences.loadRemoteBranchesDirectly {
            buildMultipleRows(remoteNames: cached.map(\.name), cached: cached)
            return
        }
        statusLabel.stringValue = "Loading branches from \(remoteName)…"
        multipleBranchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let remoteBranches = try await source.loadPushRemoteBranches(named: remoteName)
                guard !Task.isCancelled, remoteCombo.stringValue == remoteName else { return }
                buildMultipleRows(remoteNames: remoteBranches.map(\.name), cached: remoteBranches)
                statusLabel.stringValue = "Ready"
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                buildMultipleRows(remoteNames: cached.map(\.name), cached: cached)
                statusLabel.stringValue = "Could not query \(remoteName): \(error.localizedDescription)"
            }
        }
    }

    private func buildMultipleRows(remoteNames: [String], cached: [RepositoryPushRemoteBranchState]) {
        guard let state = pushState else { return }
        let remoteName = remoteCombo.stringValue
        let uniqueRemoteNames = Array(Set(remoteNames)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        branchRows = state.localBranches.map { local in
            let tracksSelected = local.trackingRemote?.caseInsensitiveCompare(remoteName) == .orderedSame
            let destination = tracksSelected ? (local.mergeWith ?? local.name) : ""
            let remote = cached.first(where: { $0.name == local.name })
            let comparison: String
            if tracksSelected {
                comparison = aheadBehind(ahead: local.ahead, behind: local.behind)
            } else if let remote {
                comparison = remote.objectID == local.objectID ? "=" : "<>"
            } else {
                comparison = ""
            }
            return PushBranchRow(localBranch: local.name, remoteBranch: destination, aheadBehind: comparison)
        }
        for name in uniqueRemoteNames where !state.localBranches.contains(where: { $0.name == name }) {
            branchRows.append(PushBranchRow(localBranch: nil, remoteBranch: name, aheadBehind: ""))
        }
        branchTable.reloadData()
    }

    private func aheadBehind(ahead: Int, behind: Int) -> String {
        if ahead == 0, behind == 0 { return "=" }
        var values: [String] = []
        if ahead > 0 { values.append("\(ahead)↑") }
        if behind > 0 { values.append("\(behind)↓") }
        return values.joined(separator: " ")
    }

    func numberOfRows(in tableView: NSTableView) -> Int { branchRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < branchRows.count, let identifier = tableColumn?.identifier.rawValue else { return nil }
        let model = branchRows[row]
        switch identifier {
        case "local", "remote":
            let field = NSTextField(string: identifier == "local" ? (model.localBranch ?? "") : model.remoteBranch)
            field.isBordered = false
            field.drawsBackground = false
            field.tag = row
            field.identifier = .init(identifier)
            field.target = self
            field.action = #selector(multipleTextChanged(_:))
            field.delegate = self
            if identifier == "local", model.localBranch == nil { field.isEditable = false }
            return field
        case "ahead":
            let value = NSTextField(labelWithString: model.aheadBehind)
            value.alignment = .center
            return value
        case "push", "force", "delete":
            let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(multipleCheckChanged(_:)))
            button.tag = row
            button.identifier = .init(identifier)
            button.state = switch identifier {
            case "push": model.mode == .push ? .on : .off
            case "force": model.mode == .force ? .on : .off
            default: model.mode == .delete ? .on : .off
            }
            if model.localBranch == nil, identifier != "delete" { button.isEnabled = false }
            return button
        default: return nil
        }
    }

    @objc private func multipleTextChanged(_ sender: NSTextField) {
        guard branchRows.indices.contains(sender.tag) else { return }
        if sender.identifier?.rawValue == "local" {
            branchRows[sender.tag].localBranch = sender.stringValue
        } else {
            branchRows[sender.tag].remoteBranch = sender.stringValue
        }
    }

    @objc private func multipleCheckChanged(_ sender: NSButton) {
        guard branchRows.indices.contains(sender.tag), let identifier = sender.identifier?.rawValue else { return }
        if sender.state == .on {
            branchRows[sender.tag].mode = switch identifier {
            case "push": .push
            case "force": .force
            default: .delete
            }
        } else {
            branchRows[sender.tag].mode = nil
        }
        branchTable.reloadData(forRowIndexes: IndexSet(integer: sender.tag), columnIndexes: IndexSet(integersIn: 3..<6))
    }

    @objc private func unselectAllRows() { setPushSelection { _ in false } }
    @objc private func selectAllRows() { setPushSelection { $0.localBranch != nil } }
    @objc private func selectTrackedRows() {
        setPushSelection { $0.localBranch != nil && !$0.remoteBranch.isEmpty }
    }

    private func setPushSelection(_ selected: (PushBranchRow) -> Bool) {
        for row in branchRows { row.mode = selected(row) ? .push : nil }
        branchTable.reloadData()
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        switch tabViewItem?.identifier as? String {
        case "tags": populateTags()
        case "multiple": populateMultipleBranches()
        default:
            populateLocalBranches()
            updateRemoteBranchForLocalSelection()
        }
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let combo = notification.object as? NSComboBox else { return }
        if combo === remoteCombo { updateRemoteSelection(resetBranch: true) }
        else if combo === localBranchCombo { updateRemoteBranchForLocalSelection() }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if let field = notification.object as? NSTextField,
           let identifier = field.identifier?.rawValue,
           identifier == "local" || identifier == "remote" {
            multipleTextChanged(field)
            return
        }
        guard let combo = notification.object as? NSComboBox else { return }
        if combo === remoteCombo { updateRemoteSelection(resetBranch: true) }
        else if combo === localBranchCombo { updateRemoteBranchForLocalSelection() }
    }

    @objc private func destinationModeChanged(_ sender: NSButton) {
        remoteChoice.state = sender === remoteChoice ? .on : .off
        urlChoice.state = sender === urlChoice ? .on : .off
        updateSourceControls()
    }

    @objc private func localBranchChanged() { updateRemoteBranchForLocalSelection() }

    @objc private func showAdvancedOptions() {
        setAdvancedOptionsVisible(true, resize: true)
    }

    private func setAdvancedOptionsVisible(_ visible: Bool, resize: Bool) {
        advancedOptions.isHidden = !visible
        showOptionsButton.isHidden = visible
        guard visible, resize, let window, window.frame.height < window.minSize.height + 50 else { return }
        var frame = window.frame
        frame.origin.y -= 50
        frame.size.height += 50
        window.setFrame(frame, display: true)
    }

    @objc private func forceWithLeaseChanged() {
        if forceWithLease.state == .on {
            forceBranches.state = .off
            forceTags.state = .on
        }
    }

    @objc private func forceBranchesChanged() {
        if forceBranches.state == .on { forceWithLease.state = .off }
    }

    @objc private func forceTagsChanged() {
        if forceTags.state == .on { forceWithLease.state = .on; forceBranches.state = .off }
        else if tabs.selectedTabViewItem?.identifier as? String == "tags" { forceWithLease.state = .off }
    }

    @objc private func browseForDestination() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let path = panel.url?.path else { return }
            self?.destinationCombo.stringValue = path
            self?.urlChoice.state = .on
            self?.remoteChoice.state = .off
            self?.updateSourceControls()
        }
    }

    @objc private func manageRemotes() {
        onManageRemotes(remoteCombo.stringValue.isEmpty ? nil : remoteCombo.stringValue, nil)
    }

    @objc private func openPull() {
        if let pullWindowController { pullWindowController.window?.makeKeyAndOrderFront(nil); return }
        pullWindowController = ApplicationShellDialogs.presentPullWindow(
            initialAction: .merge,
            executeImmediately: false,
            context: context,
            source: source,
            onManageRemotes: onManageRemotes,
            onRepositoryChanged: { [weak self] selected in
                guard let self else { return }
                self.onRepositoryChanged(selected)
                self.reloadRepositoryState(selectRemote: self.remoteCombo.stringValue)
            },
            onClose: { [weak self] in self?.pullWindowController = nil }
        )
    }

    private func attemptImmediateExecutionIfReady() {
        guard executeImmediately, !didAttemptImmediateExecution else { return }
        didAttemptImmediateExecution = true
        push()
    }

    @objc private func push() {
        guard operationTask == nil, let window, let state = pushState else { return }
        operationTask = Task { @MainActor [weak self, weak window] in
            guard let self, let window else { return }
            do {
                guard var request = try await makeValidatedRequest(state: state, window: window) else {
                    operationTask = nil
                    return
                }
                persistExecutionPreferences(request)
                while true {
                    guard let processResult = await PushProcessDialog.run(request: request, source: source, parent: window) else {
                        statusLabel.stringValue = "Push cancelled"
                        break
                    }
                    switch processResult {
                    case .failure(let error):
                        if error is CancellationError { statusLabel.stringValue = "Push aborted" }
                        else { statusLabel.stringValue = error.localizedDescription }
                        onRepositoryChanged(context.headID.map(RevisionID.object))
                        operationTask = nil
                        return
                    case .success(let result):
                        onRepositoryChanged(result.selectedCommitID)
                        statusLabel.stringValue = result.message
                        if result.outcome == .completed {
                            lastPushCompleted = true
                            openPullRequestIfRequested(request: request)
                            self.window?.close()
                            operationTask = nil
                            return
                        }
                        guard result.outcome == .rejected,
                              let recovered = await recoveryForRejectedPush(
                                  request: request,
                                  state: state,
                                  rejectionText: result.rejectionText ?? "",
                                  window: window
                              )
                        else {
                            operationTask = nil
                            return
                        }
                        request = recovered
                    }
                }
            } catch is CancellationError {
                statusLabel.stringValue = "Push cancelled"
            } catch {
                await showError(error, title: "Push failed", window: window)
                statusLabel.stringValue = error.localizedDescription
            }
            operationTask = nil
        }
    }

    private func makeValidatedRequest(state: RepositoryPushState, window: NSWindow) async throws -> RepositoryPushRequest? {
        guard !state.remotes.filter({ !$0.isDisabled }).isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Push to remote"
            alert.informativeText = "Please configure a remote repository first.\nWould you like to do it now?"
            alert.addButton(withTitle: "Yes")
            alert.addButton(withTitle: "No")
            if await begin(alert, window: window) == .alertFirstButtonReturn { manageRemotes() }
            return nil
        }
        let destination: RepositoryPushDestination
        if urlChoice.state == .on {
            let value = destinationCombo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isAbsoluteDestination(value) else {
                throw RepositoryPushError.missingDestination
            }
            destination = .url(value)
        } else {
            guard !remoteCombo.stringValue.isEmpty else { throw RepositoryPushError.missingDestination }
            destination = .remote(remoteCombo.stringValue)
        }

        let tab = tabs.selectedTabViewItem?.identifier as? String
        var track = replaceTracking.state == .on
        let operation: RepositoryPushOperation
        var force: RepositoryForcePushMode = .doNotForce
        switch tab {
        case "tags":
            let tag = tagCombo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty else { throw RepositoryPushError.missingTag }
            operation = tag == Self.allRefs ? .allTags : .tag(tag)
            force = forceTags.state == .on ? .force : .doNotForce
        case "multiple":
            let actions = branchRows.compactMap { row -> RepositoryPushAction? in
                guard let mode = row.mode else { return nil }
                let destination = row.remoteBranch.trimmingCharacters(in: .whitespacesAndNewlines)
                let effectiveDestination = destination.isEmpty ? (row.localBranch ?? "") : destination
                guard !effectiveDestination.isEmpty else { return nil }
                return RepositoryPushAction(localBranch: row.localBranch, remoteBranch: effectiveDestination, mode: mode)
            }
            operation = .multiple(actions)
        default:
            let local = selectedLocalBranch()
            guard !local.isEmpty, local != "(no branch)" else { throw RepositoryPushError.missingBranch }
            if local == Self.allRefs {
                operation = .allBranches
            } else {
                let remoteBranch = remoteBranchCombo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !remoteBranch.isEmpty else { throw RepositoryPushError.missingRemoteBranch }
                if case .remote(let remoteName) = destination,
                   !state.isBare,
                   remoteBranch != state.defaultRemoteBranch(localBranch: local, remoteName: remoteName),
                   !state.isBranchKnown(remote: remoteName, branch: remoteBranch),
                   settings.pushPreferences.confirmNewBranch {
                    let alert = NSAlert()
                    alert.messageText = "Push"
                    alert.informativeText = "The branch you are about to push seems to be a new branch for the remote.\nAre you sure you want to push this branch?"
                    alert.addButton(withTitle: "Yes")
                    alert.addButton(withTitle: "No")
                    guard await begin(alert, window: window) == .alertFirstButtonReturn else { return nil }
                }
                if !track,
                   state.shouldOfferTrackingReference(for: local) {
                    track = true
                    if settings.pushPreferences.confirmAddTrackingReference {
                        let alert = NSAlert()
                        alert.messageText = "Push"
                        alert.informativeText = "The branch \(local) does not have a tracking reference. Do you want to add a tracking reference to \(remoteBranch)?"
                        alert.addButton(withTitle: "Yes")
                        alert.addButton(withTitle: "No")
                        alert.addButton(withTitle: "Cancel")
                        let response = await begin(alert, window: window)
                        if response == .alertThirdButtonReturn { return nil }
                        track = response == .alertFirstButtonReturn
                    }
                }
                operation = .branch(source: state.commandSource(for: local), destination: remoteBranch)
            }
            if forceBranches.state == .on {
                let alert = NSAlert()
                alert.messageText = "Question"
                alert.informativeText = "Force push may overwrite changes since your last fetch. Do you want to use the safer force with lease instead?"
                alert.addButton(withTitle: "Yes")
                alert.addButton(withTitle: "No")
                alert.addButton(withTitle: "Cancel")
                let response = await begin(alert, window: window)
                if response == .alertThirdButtonReturn { return nil }
                if response == .alertFirstButtonReturn {
                    forceBranches.state = .off
                    forceWithLease.state = .on
                }
            }
            force = forceBranches.state == .on ? .force : (forceWithLease.state == .on ? .forceWithLease : .doNotForce)
        }

        return RepositoryPushRequest(
            destination: destination,
            operation: operation,
            force: force,
            setUpstream: track,
            recursiveSubmodules: RepositoryPushSubmoduleMode(rawValue: recursiveSubmodules.indexOfSelectedItem) ?? .check
        )
    }

    private func persistExecutionPreferences(_ request: RepositoryPushRequest) {
        var preferences = settings.pushPreferences
        preferences.recursiveSubmodules = request.recursiveSubmodules
        settings.savePushPreferences(preferences)
        if case .url(let value) = request.destination { settings.recordPushURL(value) }
    }

    private func recoveryForRejectedPush(
        request: RepositoryPushRequest,
        state: RepositoryPushState,
        rejectionText: String,
        window: NSWindow
    ) async -> RepositoryPushRequest? {
        let selectedBranch: String? = switch request.operation {
        case .branch(let source, _): source.hasPrefix("refs/heads/") ? String(source.dropFirst("refs/heads/".count)) : source
        default: nil
        }
        guard selectedBranch == state.currentBranch,
              case .remote = request.destination,
              !state.isBare
        else { return nil }
        let escapedBranch = NSRegularExpression.escapedPattern(for: state.currentBranch ?? "")
        let allOptions = rejectionText.range(
            of: "!\\s+\\[rejected\\]\\s+\(escapedBranch)\\s+->",
            options: .regularExpression
        ) != nil
        let preference = settings.pushPreferences.rejectedAction
        var action = preference
        if preference == .ask {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = allOptions ? "Pull latest changes from remote repository" : "Push rejected"
            alert.informativeText = allOptions
                ? "The push was rejected because the tip of your current branch is behind its remote counterpart. Merge the remote changes before pushing again."
                : "The push was rejected because the tip of the selected destination is behind its remote counterpart."
            if allOptions {
                alert.addButton(withTitle: "Pull with default action")
                alert.addButton(withTitle: "Pull with rebase")
                alert.addButton(withTitle: "Pull with merge")
            }
            alert.addButton(withTitle: "Force push with lease")
            alert.addButton(withTitle: "Cancel")
            alert.showsSuppressionButton = true
            let response = await begin(alert, window: window)
            if !allOptions {
                guard response == .alertFirstButtonReturn else { return nil }
                return request.force == .doNotForce
                    ? requestReplacingForce(request, with: .forceWithLease)
                    : request
            }
            action = switch response {
            case .alertFirstButtonReturn: .defaultPull
            case .alertSecondButtonReturn: .rebase
            case .alertThirdButtonReturn: .merge
            default: .none
            }
            if response.rawValue == NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1 {
                return request.force == .doNotForce
                    ? requestReplacingForce(request, with: .forceWithLease)
                    : request
            }
            if alert.suppressionButton?.state == .on, action != .none {
                var preferences = settings.pushPreferences
                preferences.rejectedAction = action
                settings.savePushPreferences(preferences)
            }
        }
        if action == .none { return nil }
        var pullAction = action
        if action == .defaultPull {
            pullAction = switch settings.pullPreferences.defaultAction {
            case .merge: .merge
            case .rebase: .rebase
            default: .none
            }
        }
        guard pullAction == .merge || pullAction == .rebase,
              case .remote(let remote) = request.destination,
              case .branch(_, let destination) = request.operation
        else {
            await showMessage("Automatic pull can only be performed when the pull action is Merge or Rebase.", title: "Push was rejected", window: window)
            return nil
        }
        if pullAction == .rebase,
           (try? await source.hasUnpushedMergeCommit(remote: remote, branch: destination)) == true {
            await showMessage("Cannot perform automatic pull with Rebase because one of the commits to rebase is a merge commit.", title: "Push was rejected", window: window)
            return nil
        }
        let pullPreferences = settings.pullPreferences
        let pullRequest = RepositoryPullRequest(
            source: .remote(remote),
            mode: pullAction == .rebase ? .rebase : .merge,
            localBranch: state.currentBranch,
            remoteBranch: destination,
            autoStash: pullPreferences.autoStash,
            includeUntrackedInAutoStash: pullPreferences.includeUntrackedInAutoStash,
            updateSubmodulesAfterPull: pullPreferences.updateSubmodulesAfterPull == true
        )
        guard let pullResult = await PullProcessDialog.run(request: pullRequest, source: source, parent: window) else { return nil }
        switch pullResult {
        case .success(let value) where value.outcome == .completed:
            onRepositoryChanged(value.selectedCommitID)
            return request
        default:
            return nil
        }
    }

    private func requestReplacingForce(_ request: RepositoryPushRequest, with force: RepositoryForcePushMode) -> RepositoryPushRequest {
        RepositoryPushRequest(
            destination: request.destination,
            operation: request.operation,
            force: force,
            setUpstream: request.setUpstream,
            recursiveSubmodules: request.recursiveSubmodules,
            environment: request.environment
        )
    }

    private func isAbsoluteDestination(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        if value.hasPrefix("/") { return true }
        if let components = URLComponents(string: value), components.scheme?.isEmpty == false { return true }
        return false
    }

    private func openPullRequestIfRequested(request: RepositoryPushRequest) {
        guard createPullRequest.state == .on,
              let branch = selectedLocalBranch().nilIfPushSentinel,
              let url = pullRequestURL(branch: branch)
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func pullRequestURL(branch: String) -> URL? {
        guard !branch.isEmpty,
              let state = pushState,
              let remote = state.remotes.first(where: { !$0.isDisabled && $0.name == remoteCombo.stringValue })
        else { return nil }
        return RepositoryPullRequestURLBuilder.url(remoteURL: remote.fetchURL, branch: branch)
    }

    private func group(_ title: String, content: NSView, horizontalInset: CGFloat, verticalInset: CGFloat) -> NSBox {
        let box = NSBox()
        box.title = title
        box.titlePosition = .atTop
        box.boxType = .custom
        box.borderWidth = 1
        box.cornerRadius = 0
        content.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(content)
        if let holder = box.contentView {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: horizontalInset),
                content.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -horizontalInset),
                content.topAnchor.constraint(equalTo: holder.topAnchor, constant: verticalInset),
                content.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -verticalInset)
            ])
        }
        return box
    }

    private func begin(_ alert: NSAlert, window: NSWindow) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    private func showError(_ error: Error, title: String, window: NSWindow) async {
        let alert = NSAlert(error: error)
        alert.messageText = title
        _ = await begin(alert, window: window)
    }

    private func showMessage(_ message: String, title: String, window: NSWindow) async {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        _ = await begin(alert, window: window)
    }

    override func cancelOperation(_ sender: Any?) {
        if operationTask == nil { window?.close() }
    }

    func windowWillClose(_ notification: Notification) { finish() }

    func windowDidBecomeKey(_ notification: Notification) {
        if didBecomeKeyOnce {
            guard operationTask == nil else { return }
            reloadRepositoryState(selectRemote: remoteCombo.stringValue)
        } else {
            didBecomeKeyOnce = true
        }
    }

    private func finish() {
        guard !didClose else { return }
        didClose = true
        operationTask?.cancel()
        multipleBranchTask?.cancel()
        pullWindowController?.close()
        onCompletion?(lastPushCompleted)
        onClose?()
    }
}

@MainActor
private final class PushBranchRow {
    var localBranch: String?
    var remoteBranch: String
    let aheadBehind: String
    var mode: RepositoryPushActionMode?

    init(localBranch: String?, remoteBranch: String, aheadBehind: String, mode: RepositoryPushActionMode? = nil) {
        self.localBranch = localBranch
        self.remoteBranch = remoteBranch
        self.aheadBehind = aheadBehind
        self.mode = mode
    }
}

private final class PushBranchHeaderView: NSTableHeaderView {
    var pushSelectionMenu: NSMenu?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let columnIndex = column(at: point)
        if columnIndex >= 0,
           tableView?.tableColumns[columnIndex].identifier.rawValue == "push",
           let pushSelectionMenu {
            NSMenu.popUpContextMenu(pushSelectionMenu, with: event, for: self)
            return
        }
        super.mouseDown(with: event)
    }
}

private extension String {
    var nilIfPushSentinel: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == "[ All ]" || value == "HEAD" ? nil : value
    }
}

@MainActor
enum RemoteBranchDeleteDialog {
    static func present(
        source: any RepositoryPushingDataSource,
        initialRemote: String,
        initialBranch: String,
        onRepositoryChanged: @escaping (RevisionID?) -> Void,
        onClose: @escaping () -> Void
    ) -> NSWindowController {
        let controller = RemoteBranchDeleteViewController(
            source: source,
            initialRemote: initialRemote,
            initialBranch: initialBranch,
            onRepositoryChanged: onRepositoryChanged,
            onClose: onClose
        )
        let window = NSWindow(contentViewController: controller)
        window.title = "Delete branch"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 403, height: 150))
        window.contentMinSize = NSSize(width: 403, height: 102)
        window.isReleasedWhenClosed = false
        window.delegate = controller
        controller.window = window
        let windowController = NSWindowController(window: window)
        windowController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        return windowController
    }
}

@MainActor
private final class RemoteBranchDeleteViewController: NSViewController, NSWindowDelegate {
    weak var window: NSWindow?
    private let source: any RepositoryPushingDataSource
    private let initialRemote: String
    private let initialBranch: String
    private let onRepositoryChanged: (RevisionID?) -> Void
    private let onClose: () -> Void
    private let branchesButton = NSPopUpButton()
    private let deleteRemote = NSButton(checkboxWithTitle: "Delete branch(es) from remote repository", target: nil, action: nil)
    private let deleteTracking = NSButton(checkboxWithTitle: "Delete local tracking branch (if available)", target: nil, action: nil)
    private let trackingCandidates = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(labelWithString: "Loading branches…")
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private var state: RepositoryPushState?
    private var mergedRemoteBranches: Set<String> = []
    private var selectedBranches: Set<String> = []
    private var task: Task<Void, Never>?
    private var didClose = false

    init(
        source: any RepositoryPushingDataSource,
        initialRemote: String,
        initialBranch: String,
        onRepositoryChanged: @escaping (RevisionID?) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.source = source
        self.initialRemote = initialRemote
        self.initialBranch = initialBranch
        self.onRepositoryChanged = onRepositoryChanged
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }
    deinit { task?.cancel() }

    override func loadView() {
        let root = NSView()
        branchesButton.setAccessibilityLabel("Select remote branches")
        branchesButton.autoenablesItems = false
        branchesButton.target = self
        branchesButton.action = #selector(branchSelectionChanged(_:))
        deleteRemote.target = self
        deleteRemote.action = #selector(deleteOptionsChanged)
        deleteTracking.target = self
        deleteTracking.action = #selector(deleteOptionsChanged)
        deleteTracking.isEnabled = false
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelectedBranches)
        deleteButton.keyEquivalent = "\r"
        deleteButton.isEnabled = false
        deleteButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 75).isActive = true
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 10.5)
        trackingCandidates.font = .systemFont(ofSize: 11)
        trackingCandidates.textColor = .secondaryLabelColor

        let label = NSTextField(labelWithString: "Select branches")
        let branchRow = NSGridView(views: [[label, branchesButton]])
        branchRow.column(at: 0).width = 89
        branchRow.columnSpacing = 0
        let options = NSStackView(views: [deleteRemote, deleteTracking, trackingCandidates])
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 3
        let body = NSStackView(views: [branchRow, options])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 3
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [status, spacer, deleteButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        let separator = NSBox()
        separator.boxType = .separator
        for child in [body, separator, footer] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 9),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -9),
            body.topAnchor.constraint(equalTo: root.topAnchor, constant: 9),
            branchesButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 290),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -3),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            footer.heightAnchor.constraint(equalToConstant: 30),
            body.bottomAnchor.constraint(lessThanOrEqualTo: separator.topAnchor, constant: -4)
        ])
        view = root
        loadState()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(branchesButton)
    }

    private func loadState() {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                async let loadedState = source.loadPushState()
                async let merged = source.loadMergedRemoteBranches()
                let (state, mergedBranches) = try await (loadedState, merged)
                guard !Task.isCancelled else { return }
                self.state = state
                mergedRemoteBranches = mergedBranches
                let initial = "\(initialRemote)/\(initialBranch)"
                if state.remoteBranches.contains(where: { "\($0.remote)/\($0.name)" == initial }) {
                    selectedBranches = [initial]
                }
                populateBranches()
                updateTrackingCandidates()
                status.stringValue = "Ready"
                task = nil
            } catch is CancellationError {
                return
            } catch {
                status.stringValue = error.localizedDescription
                task = nil
            }
        }
    }

    private func populateBranches() {
        branchesButton.removeAllItems()
        guard let state else { return }
        for branch in state.remoteBranches.sorted(by: {
            ("\($0.remote)/\($0.name)").localizedStandardCompare("\($1.remote)/\($1.name)") == .orderedAscending
        }) {
            let fullName = "\(branch.remote)/\(branch.name)"
            branchesButton.addItem(withTitle: fullName)
            guard let item = branchesButton.lastItem else { continue }
            item.representedObject = fullName
            item.state = selectedBranches.contains(fullName) ? .on : .off
        }
        updateBranchButtonTitle()
    }

    @objc private func branchSelectionChanged(_ sender: NSPopUpButton) {
        guard let fullName = sender.selectedItem?.representedObject as? String else { return }
        if selectedBranches.contains(fullName) { selectedBranches.remove(fullName) }
        else { selectedBranches.insert(fullName) }
        for item in sender.itemArray {
            guard let name = item.representedObject as? String else { continue }
            item.state = selectedBranches.contains(name) ? .on : .off
        }
        updateBranchButtonTitle()
        updateTrackingCandidates()
    }

    private func updateBranchButtonTitle() {
        let names = selectedBranches.sorted()
        branchesButton.title = switch names.count {
        case 0: "Select branches…"
        case 1: names[0]
        default: "\(names.count) branches selected"
        }
        deleteOptionsChanged()
    }

    private func localTrackingCandidates() -> [String] {
        guard let state else { return [] }
        let selections = selectedBranches.compactMap(splitRemoteBranch)
        return state.localBranches.filter { local in
            guard let tracking = local.trackingRemote, let mergeWith = local.mergeWith else { return false }
            return selections.contains { $0.remote.caseInsensitiveCompare(tracking) == .orderedSame && $0.branch == mergeWith }
        }.map(\.name).sorted()
    }

    private func updateTrackingCandidates() {
        let candidates = localTrackingCandidates()
        deleteTracking.isEnabled = !candidates.isEmpty
        if candidates.isEmpty {
            deleteTracking.state = .off
            trackingCandidates.stringValue = ""
        } else {
            let visible = candidates.prefix(8).map { " • \($0)" }.joined(separator: "\n")
            let remainder = candidates.count > 8 ? "\nand \(candidates.count - 8) more…" : ""
            trackingCandidates.stringValue = "Local tracking branch(es) candidate to deletion:\n\(visible)\(remainder)"
        }
        resizeForCandidates(candidates.count)
        deleteOptionsChanged()
    }

    private func resizeForCandidates(_ count: Int) {
        guard let window else { return }
        let desiredHeight = CGFloat(150 + min(count, 8) * 15 + (count > 0 ? 15 : 0))
        guard abs(window.contentLayoutRect.height - desiredHeight) > 1 else { return }
        var frame = window.frame
        let delta = desiredHeight - window.contentLayoutRect.height
        frame.origin.y -= delta
        frame.size.height += delta
        window.setFrame(frame, display: true)
    }

    @objc private func deleteOptionsChanged() {
        deleteButton.isEnabled = deleteRemote.state == .on && !selectedBranches.isEmpty && task == nil
    }

    @objc private func deleteSelectedBranches() {
        guard task == nil, let window, state != nil else { return }
        task = Task { @MainActor [weak self, weak window] in
            guard let self, let window else { return }
            let unmerged = selectedBranches.filter { !self.mergedRemoteBranches.contains($0) }
            if !unmerged.isEmpty {
                let alert = NSAlert()
                alert.messageText = "Delete remote branches"
                alert.informativeText = "At least one remote branch is unmerged. Are you sure you want to delete it?\nDeleting a branch can cause commits to be deleted too!"
                alert.addButton(withTitle: "Yes")
                alert.addButton(withTitle: "No")
                alert.buttons[0].keyEquivalent = ""
                alert.buttons[1].keyEquivalent = "\r"
                guard await begin(alert, window: window) == .alertFirstButtonReturn else {
                    task = nil
                    deleteOptionsChanged()
                    return
                }
            }

            let grouped = Dictionary(grouping: selectedBranches.compactMap(splitRemoteBranch), by: \.remote)
            for remote in grouped.keys.sorted() {
                let actions = (grouped[remote] ?? []).map {
                    RepositoryPushAction(localBranch: nil, remoteBranch: $0.branch, mode: .delete)
                }
                let request = RepositoryPushRequest(
                    destination: .remote(remote),
                    operation: .multiple(actions),
                    recursiveSubmodules: .none
                )
                guard let processResult = await PushProcessDialog.run(request: request, source: source, parent: window) else {
                    status.stringValue = "Deletion cancelled"
                    task = nil
                    deleteOptionsChanged()
                    return
                }
                switch processResult {
                case .success(let result) where result.outcome == .completed:
                    onRepositoryChanged(result.selectedCommitID)
                case .success(let result):
                    status.stringValue = result.message
                    task = nil
                    deleteOptionsChanged()
                    return
                case .failure(let error):
                    status.stringValue = error.localizedDescription
                    task = nil
                    deleteOptionsChanged()
                    return
                }
            }

            if deleteTracking.state == .on {
                let candidates = localTrackingCandidates()
                do {
                    try await source.deleteLocalTrackingBranches(candidates, force: false)
                    onRepositoryChanged(state?.headID.map(RevisionID.object))
                } catch {
                    let alert = NSAlert()
                    alert.alertStyle = .critical
                    alert.messageText = "Delete local tracking branches failed"
                    alert.informativeText = "\(error.localizedDescription)\n\nDo you want to force-delete these local branches?"
                    alert.addButton(withTitle: "Force delete")
                    alert.addButton(withTitle: "Cancel")
                    guard await begin(alert, window: window) == .alertFirstButtonReturn else {
                        self.window?.close()
                        return
                    }
                    do {
                        try await source.deleteLocalTrackingBranches(candidates, force: true)
                        onRepositoryChanged(state?.headID.map(RevisionID.object))
                    } catch {
                        await showError(error, window: window)
                    }
                }
            }
            self.window?.close()
        }
    }

    private func splitRemoteBranch(_ value: String) -> (remote: String, branch: String)? {
        if let remote = state?.remotes
            .map(\.name)
            .sorted(by: { $0.count > $1.count })
            .first(where: { value.hasPrefix($0 + "/") }) {
            let branch = String(value.dropFirst(remote.count + 1))
            return branch.isEmpty ? nil : (remote, branch)
        }
        guard let slash = value.firstIndex(of: "/") else { return nil }
        let remote = String(value[..<slash])
        let branch = String(value[value.index(after: slash)...])
        return remote.isEmpty || branch.isEmpty ? nil : (remote, branch)
    }

    private func begin(_ alert: NSAlert, window: NSWindow) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    private func showError(_ error: Error, window: NSWindow) async {
        _ = await begin(NSAlert(error: error), window: window)
    }

    override func cancelOperation(_ sender: Any?) { if task == nil { window?.close() } }
    func windowWillClose(_ notification: Notification) {
        guard !didClose else { return }
        didClose = true
        task?.cancel()
        onClose()
    }
}

@MainActor
enum PushProcessDialog {
    static func run(
        request: RepositoryPushRequest,
        source: any RepositoryPushingDataSource,
        parent: NSWindow
    ) async -> Result<RepositoryPushResult, Error>? {
        let controller = PushProcessViewController(initialStatus: "Pushing…") { output in
            try await source.performPush(request, output: output)
        }
        let panel = NSPanel(contentViewController: controller)
        panel.title = "Push to \(request.destination.commandValue)"
        panel.styleMask = [.titled, .closable, .resizable]
        panel.setContentSize(NSSize(width: 700, height: 430))
        panel.minSize = NSSize(width: 520, height: 300)
        controller.panel = panel
        panel.delegate = controller
        return await withCheckedContinuation { continuation in
            controller.onClose = { result in
                if parent.attachedSheet === panel { parent.endSheet(panel) }
                continuation.resume(returning: result)
            }
            parent.beginSheet(panel)
            controller.start()
        }
    }
}

@MainActor
private final class PushProcessViewController: NSViewController, NSWindowDelegate {
    typealias Operation = @Sendable (@escaping GitOutputHandler) async throws -> RepositoryPushResult
    weak var panel: NSPanel?
    var onClose: ((Result<RepositoryPushResult, Error>?) -> Void)?
    private let initialStatus: String
    private let operation: Operation
    private let progress = NSProgressIndicator()
    private let status = NSTextField(labelWithString: "Waiting…")
    private let outputView = NSTextView()
    private let keepOpen = NSButton(checkboxWithTitle: "Keep dialog open", target: nil, action: nil)
    private let abortButton = NSButton(title: "Abort", target: nil, action: nil)
    private let closeButton = NSButton(title: "OK", target: nil, action: nil)
    private var task: Task<Void, Never>?
    private var result: Result<RepositoryPushResult, Error>?
    private var didClose = false

    init(initialStatus: String, operation: @escaping Operation) {
        self.initialStatus = initialStatus
        self.operation = operation
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    deinit { task?.cancel() }

    override func loadView() {
        let root = NSView()
        progress.style = .bar
        progress.controlSize = .small
        progress.isIndeterminate = true
        progress.minValue = 0
        progress.maxValue = 100
        progress.widthAnchor.constraint(equalToConstant: 92).isActive = true
        status.font = .boldSystemFont(ofSize: 12)
        outputView.isEditable = false
        outputView.isSelectable = true
        outputView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        outputView.textContainerInset = NSSize(width: 6, height: 6)
        outputView.frame = NSRect(x: 0, y: 0, width: 676, height: 330)
        outputView.minSize = .zero
        outputView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        outputView.isVerticallyResizable = true
        outputView.isHorizontallyResizable = true
        outputView.autoresizingMask = [.width, .height]
        outputView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        outputView.textContainer?.widthTracksTextView = false
        let scroll = NSScrollView()
        scroll.documentView = outputView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        keepOpen.state = AppSettingsStore.shared.pullPreferences.closeProcessOnSuccess ? .off : .on
        keepOpen.target = self; keepOpen.action = #selector(keepOpenChanged)
        abortButton.target = self; abortButton.action = #selector(abort)
        closeButton.target = self; closeButton.action = #selector(close)
        closeButton.keyEquivalent = "\r"
        closeButton.isEnabled = false
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [progress, status])
        header.orientation = .horizontal; header.alignment = .centerY; header.spacing = 8
        let footer = NSStackView(views: [keepOpen, spacer, abortButton, closeButton])
        footer.orientation = .horizontal; footer.alignment = .centerY; footer.spacing = 8
        for child in [header, scroll, footer] { child.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(child) }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 9),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -9),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            footer.heightAnchor.constraint(equalToConstant: 30)
        ])
        view = root
    }

    func start() {
        guard task == nil else { return }
        progress.startAnimation(nil)
        status.stringValue = initialStatus
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let value = try await operation { [weak self] event in
                    Task { @MainActor in self?.append(event) }
                }
                result = .success(value)
                switch value.outcome {
                case .completed: status.stringValue = "Completed successfully"
                case .rejected: status.stringValue = "Push rejected (exit \(value.command.exitStatus))"
                case .failed: status.stringValue = "Failed (exit \(value.command.exitStatus))"
                }
            } catch is CancellationError {
                status.stringValue = "Aborted"
                result = .failure(CancellationError())
                appendText("\nAborted\n", color: .systemOrange)
            } catch {
                status.stringValue = "Failed"
                result = .failure(error)
                appendText("\n\(error.localizedDescription)\n", color: .systemRed)
            }
            progress.stopAnimation(nil)
            abortButton.isEnabled = false
            closeButton.isEnabled = true
            task = nil
            if case .success(let value) = result, value.outcome == .completed, keepOpen.state == .off { finish() }
        }
    }

    private func append(_ event: GitOutputEvent) {
        appendText(event.text, color: event.stream == .standardError ? .systemRed : .textColor)
        let lines = event.text.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
        if let last = lines.last, !last.isEmpty {
            let message = String(last)
            status.stringValue = message
            if let range = message.range(of: #"(?:^|\s)(\d{1,3})%"#, options: .regularExpression) {
                let token = message[range].trimmingCharacters(in: .whitespacesAndNewlines).dropLast()
                if let value = Double(token), (0...100).contains(value) {
                    progress.isIndeterminate = false
                    progress.doubleValue = value
                }
            }
        }
    }

    private func appendText(_ value: String, color: NSColor) {
        outputView.textStorage?.append(NSAttributedString(
            string: value,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: color]
        ))
        outputView.scrollToEndOfDocument(nil)
    }

    override func cancelOperation(_ sender: Any?) { task != nil ? abort() : close() }

    @objc private func keepOpenChanged() {
        var preferences = AppSettingsStore.shared.pullPreferences
        preferences.closeProcessOnSuccess = keepOpen.state == .off
        AppSettingsStore.shared.savePullPreferences(preferences)
        if keepOpen.state == .off,
           case .success(let value) = result,
           value.outcome == .completed { finish() }
    }

    @objc private func abort() { status.stringValue = "Aborting…"; task?.cancel() }
    @objc private func close() { finish() }
    func windowWillClose(_ notification: Notification) { if task != nil { task?.cancel() }; finish() }
    private func finish() { guard !didClose else { return }; didClose = true; onClose?(result) }
}
