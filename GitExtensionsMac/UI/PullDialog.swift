import AppKit

@MainActor
extension ApplicationShellDialogs {
    static func presentPullWindow(
        initialAction: NetworkDialogInitialAction,
        executeImmediately: Bool,
        snapshot: RepositorySnapshot,
        source: any RepositoryPullingDataSource,
        onSnapshot: @escaping (RepositorySnapshot, String?) -> Void,
        onClose: @escaping () -> Void
    ) -> NSWindowController {
        let controller = PullDialogViewController(
            initialAction: initialAction,
            executeImmediately: executeImmediately,
            snapshot: snapshot,
            source: source,
            onSnapshot: onSnapshot
        )
        let window = NSWindow(contentViewController: controller)
        window.title = "Pull (\(snapshot.currentRepository.path))"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 920, height: 620))
        window.minSize = NSSize(width: 690, height: 564)
        window.maxSize = NSSize(width: 10_000, height: 10_000)
        window.contentMaxSize = NSSize(width: 10_000, height: 10_000)
        window.isReleasedWhenClosed = false
        window.delegate = controller
        controller.onClose = onClose
        let windowController = NSWindowController(window: window)
        windowController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        return windowController
    }
}

@MainActor
private final class PullDialogViewController: NSViewController, NSWindowDelegate, NSComboBoxDelegate {
    var onClose: (() -> Void)?

    private let initialAction: NetworkDialogInitialAction
    private let executeImmediately: Bool
    private var snapshot: RepositorySnapshot
    private let source: any RepositoryPullingDataSource
    private let onSnapshot: (RepositorySnapshot, String?) -> Void
    private let settings = AppSettingsStore.shared
    private var pullState: RepositoryPullState?
    private var remoteBranchTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var remoteWindowController: NSWindowController?
    private var didClose = false
    private var applyingState = false
    private var didAttemptImmediateExecution = false

    private let helpPanel = NSView()
    private let helpToggle = NSButton()
    private let helpNotice = NSTextField(labelWithString: "Hover to see scenario when fast forward is possible.")
    private let helpImageView = PullHelpImageView()
    private var helpWidthConstraint: NSLayoutConstraint?
    private var isHelpExpanded: Bool

    private let remoteChoice = NSButton(radioButtonWithTitle: "Remote", target: nil, action: nil)
    private let urlChoice = NSButton(radioButtonWithTitle: "URL", target: nil, action: nil)
    private let remoteCombo = NSComboBox()
    private let urlCombo = NSComboBox()
    private let browseButton = NSButton(title: "Browse…", target: nil, action: nil)
    private let manageButton = NSButton(title: "Manage remotes", target: nil, action: nil)
    private let localBranchField = NSTextField()
    private let remoteBranchCombo = NSComboBox()
    private let mergeMode = NSButton(radioButtonWithTitle: "Merge remote branch into current branch", target: nil, action: nil)
    private let rebaseMode = NSButton(radioButtonWithTitle: "Rebase current branch on top of remote branch, creates linear history (use with caution)", target: nil, action: nil)
    private let fetchMode = NSButton(radioButtonWithTitle: "Do not merge, only fetch remote changes", target: nil, action: nil)
    private let reachableTags = NSButton(radioButtonWithTitle: "Follow tagopt, if not specified, fetch tags reachable from remote HEAD", target: nil, action: nil)
    private let noTags = NSButton(radioButtonWithTitle: "Fetch no tag", target: nil, action: nil)
    private let allTags = NSButton(radioButtonWithTitle: "Fetch all tags", target: nil, action: nil)
    private let unshallow = NSButton(checkboxWithTitle: "Download full history", target: nil, action: nil)
    private let prune = NSButton(checkboxWithTitle: "Prune remote branches", target: nil, action: nil)
    private let pruneTags = NSButton(checkboxWithTitle: "Prune remote branches and tags", target: nil, action: nil)
    private let conflictsButton = NSButton(title: "Solve conflicts", target: nil, action: nil)
    private let stashButton = NSButton(title: "Stash changes", target: nil, action: nil)
    private let autoStash = NSButton(checkboxWithTitle: "Auto stash", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let executeButton = NSButton(title: "Pull", target: nil, action: nil)

    init(
        initialAction: NetworkDialogInitialAction,
        executeImmediately: Bool,
        snapshot: RepositorySnapshot,
        source: any RepositoryPullingDataSource,
        onSnapshot: @escaping (RepositorySnapshot, String?) -> Void
    ) {
        self.initialAction = initialAction
        self.executeImmediately = executeImmediately
        self.snapshot = snapshot
        self.source = source
        self.onSnapshot = onSnapshot
        isHelpExpanded = AppSettingsStore.shared.pullPreferences.helpExpanded
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }
    deinit {
        remoteBranchTask?.cancel()
        operationTask?.cancel()
    }

    override func loadView() {
        let root = NSView()
        configureControls()
        let help = makeHelpPanel()
        let form = makeForm()
        let document = TopAlignedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        form.translatesAutoresizingMaskIntoConstraints = false
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
        help.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(help)
        root.addSubview(scroll)
        root.addSubview(separator)
        root.addSubview(footer)
        let helpWidth = help.widthAnchor.constraint(equalToConstant: isHelpExpanded ? 307 : 30)
        helpWidthConstraint = helpWidth
        NSLayoutConstraint.activate([
            help.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            help.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            help.bottomAnchor.constraint(lessThanOrEqualTo: separator.topAnchor, constant: -8),
            helpWidth,
            scroll.leadingAnchor.constraint(equalTo: help.trailingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -8),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            footer.heightAnchor.constraint(equalToConstant: 41)
        ])
        view = root
        populateRemotes()
        applyInitialAction()
        updateHelp()
        updateHelpVisibility()
        reloadRepositoryState()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if let window = view.window {
            window.styleMask.insert(.resizable)
            window.maxSize = NSSize(width: 10_000, height: 10_000)
            window.contentMaxSize = NSSize(width: 10_000, height: 10_000)
        }
        view.window?.makeFirstResponder(remoteCombo)
        attemptImmediateExecutionIfReady()
    }

    override func cancelOperation(_ sender: Any?) { view.window?.performClose(sender) }

    private func configureControls() {
        for combo in [remoteCombo, urlCombo, remoteBranchCombo] {
            combo.isEditable = true
            combo.completes = true
            combo.numberOfVisibleItems = 15
        }
        remoteCombo.delegate = self
        remoteCombo.target = self
        remoteCombo.action = #selector(remoteChanged)
        urlCombo.delegate = self
        urlCombo.target = self
        urlCombo.action = #selector(urlChanged)
        localBranchField.delegate = self
        remoteChoice.target = self; remoteChoice.action = #selector(sourceChanged(_:))
        urlChoice.target = self; urlChoice.action = #selector(sourceChanged(_:))
        manageButton.target = self; manageButton.action = #selector(manageRemotes)
        manageButton.image = AppKitFactory.resourceImage("Remotes", accessibilityDescription: "Manage remotes")
        manageButton.imagePosition = .imageLeading
        browseButton.target = self; browseButton.action = #selector(browseForSource)
        for button in [mergeMode, rebaseMode, fetchMode] {
            button.target = self; button.action = #selector(modeChanged(_:))
        }
        decorateRadioTitle(
            mergeMode,
            imageName: "Merge",
            title: "Merge remote branch into current branch"
        )
        decorateRadioTitle(
            rebaseMode,
            imageName: "Rebase",
            title: "Rebase current branch on top of remote branch, creates linear history (use with caution)"
        )
        for button in [reachableTags, noTags, allTags] {
            button.target = self; button.action = #selector(tagModeChanged(_:))
        }
        reachableTags.state = .on
        prune.target = self; prune.action = #selector(pruneChanged)
        pruneTags.target = self; pruneTags.action = #selector(pruneTagsChanged)
        helpToggle.target = self; helpToggle.action = #selector(toggleHelp); helpToggle.isBordered = false
        conflictsButton.target = self; conflictsButton.action = #selector(solveConflicts)
        stashButton.target = self; stashButton.action = #selector(stashChanges)
        autoStash.state = settings.pullPreferences.autoStash ? .on : .off
        executeButton.target = self; executeButton.action = #selector(execute)
        executeButton.image = AppKitFactory.resourceImage("ArrowDown", accessibilityDescription: "Pull")
        executeButton.imagePosition = .imageLeading
        executeButton.keyEquivalent = "\r"
        executeButton.widthAnchor.constraint(equalToConstant: 124).isActive = true
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 10.5)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func makeHelpPanel() -> NSView {
        helpNotice.font = .systemFont(ofSize: 12)
        helpNotice.maximumNumberOfLines = 2
        helpImageView.imageScaling = .scaleProportionallyUpOrDown
        helpImageView.imageAlignment = .alignTopLeft
        helpImageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            helpImageView.widthAnchor.constraint(equalToConstant: 307),
            helpImageView.heightAnchor.constraint(equalToConstant: 375)
        ])
        let stack = NSStackView(views: [helpToggle, helpNotice, helpImageView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.setCustomSpacing(10, after: helpNotice)
        stack.translatesAutoresizingMaskIntoConstraints = false
        helpPanel.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: helpPanel.leadingAnchor, constant: 3),
            stack.topAnchor.constraint(equalTo: helpPanel.topAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: helpPanel.trailingAnchor)
        ])
        return helpPanel
    }

    private func makeForm() -> NSView {
        let sourceGrid = NSGridView(views: [
            [remoteChoice, remoteCombo, manageButton],
            [urlChoice, urlCombo, browseButton]
        ])
        sourceGrid.column(at: 0).width = 92
        sourceGrid.column(at: 1).xPlacement = .fill
        sourceGrid.column(at: 2).width = 150
        sourceGrid.columnSpacing = 7
        sourceGrid.rowSpacing = 5
        for combo in [remoteCombo, urlCombo] {
            combo.widthAnchor.constraint(greaterThanOrEqualToConstant: 288).isActive = true
            combo.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        let branchGrid = NSGridView(views: [
            [rightLabel("Local branch"), localBranchField],
            [rightLabel("Remote branch"), remoteBranchCombo]
        ])
        branchGrid.column(at: 0).width = 138
        branchGrid.column(at: 1).xPlacement = .fill
        branchGrid.columnSpacing = 7
        branchGrid.rowSpacing = 6
        for field in [localBranchField, remoteBranchCombo] {
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 288).isActive = true
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        let pullFromGroup = group("Pull from", sourceGrid)
        let branchGroup = group("Branch", branchGrid)
        let mergeGroup = group("Merge options", vertical([mergeMode, rebaseMode, fetchMode], spacing: 5))
        let tagGroup = group("Tag options", vertical([reachableTags, noTags, allTags], spacing: 5))
        let stack = vertical([
            pullFromGroup,
            branchGroup,
            mergeGroup,
            tagGroup,
            unshallow,
            prune,
            pruneTags
        ], spacing: 8)
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 8, right: 8)
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 598).isActive = true
        for section in [pullFromGroup, branchGroup, mergeGroup, tagGroup] {
            section.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -10).isActive = true
        }
        return stack
    }

    private func makeFooter() -> NSView {
        conflictsButton.widthAnchor.constraint(equalToConstant: 141).isActive = true
        stashButton.widthAnchor.constraint(equalToConstant: 132).isActive = true
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [conflictsButton, stashButton, autoStash, statusLabel, spacer, executeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        return stack
    }

    private func populateRemotes(selecting requested: String? = nil) {
        let previous = requested ?? remoteCombo.stringValue
        remoteCombo.removeAllItems()
        remoteCombo.addItem(withObjectValue: "[ All ]")
        snapshot.remotes.map(\.name).forEach { remoteCombo.addItem(withObjectValue: $0) }
        let preferred = previous.isEmpty ? preferredRemoteName() : previous
        let names = remoteCombo.objectValues.compactMap { $0 as? String }
        if let preferred, names.contains(preferred) { remoteCombo.stringValue = preferred }
        else if let first = preferredRemoteName() { remoteCombo.stringValue = first }
        else { remoteCombo.stringValue = "[ All ]" }
        urlCombo.removeAllItems()
        settings.pullPreferences.recentURLs.forEach { urlCombo.addItem(withObjectValue: $0) }
        snapshot.remotes.map(\.fetchURL).filter { !$0.isEmpty }.forEach { urlCombo.addItem(withObjectValue: $0) }
        updateRemoteURL(resetRemoteBranch: true)
    }

    private func applyInitialAction() {
        remoteChoice.state = .on
        urlChoice.state = .off
        switch initialAction {
        case .merge: setMode(.merge, resetLocal: true)
        case .rebase: setMode(.rebase, resetLocal: true)
        case .fetch: setMode(.fetch, resetLocal: true)
        case .fetchAll:
            remoteCombo.stringValue = "[ All ]"; updateRemoteURL(resetRemoteBranch: true); setMode(.fetch, resetLocal: true)
        case .fetchPruneAll:
            remoteCombo.stringValue = "[ All ]"; updateRemoteURL(resetRemoteBranch: true); setMode(.fetch, resetLocal: true); prune.state = .on
        }
        updateSourceControls()
    }

    private func reloadRepositoryState() {
        operationTask?.cancel()
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let state = try await source.loadPullState()
                guard !Task.isCancelled else { operationTask = nil; return }
                pullState = state
                unshallow.isHidden = !state.isShallow
                conflictsButton.isEnabled = !state.conflictedPaths.isEmpty || state.rebaseInProgress || state.mergeInProgress
                stashButton.isEnabled = state.hasTrackedChanges || state.hasUntrackedFiles
                statusLabel.stringValue = state.isDetached ? "Detached HEAD" : ""
                updateEnabledState()
                operationTask = nil
                attemptImmediateExecutionIfReady()
            } catch {
                operationTask = nil
                statusLabel.stringValue = error.localizedDescription
                executeButton.isEnabled = false
            }
        }
    }

    private func preferredRemoteName() -> String? {
        let current = snapshot.branches.first(where: \.isCurrent)?.name
        let tracking = snapshot.commits.lazy.flatMap(\.references).first {
            ($0.kind == .currentBranch || $0.kind == .localBranch) && $0.name == current
        }?.trackingRemote
        return tracking ?? snapshot.remotes.first?.name
    }

    private func updateRemoteURL(resetRemoteBranch: Bool = false) {
        let name = remoteCombo.stringValue
        if let url = snapshot.remotes.first(where: { $0.name == name })?.fetchURL { urlCombo.stringValue = url }
        let all = name == "[ All ]"
        mergeMode.isEnabled = !all
        rebaseMode.isEnabled = !all
        if all { setMode(.fetch, resetLocal: true) }
        populateRemoteBranches(preserveSelection: !resetRemoteBranch)
        loadAdvertisedRemoteBranches()
        updateEnabledState()
    }

    private func populateRemoteBranches(advertised: [String]? = nil, preserveSelection: Bool = true) {
        let selected = preserveSelection ? remoteBranchCombo.stringValue : ""
        let remoteName = remoteCombo.stringValue
        remoteBranchCombo.removeAllItems()
        if remoteName == "[ All ]" {
            remoteBranchCombo.addItem(withObjectValue: "")
            remoteBranchCombo.stringValue = ""
            return
        }
        remoteBranchCombo.addItem(withObjectValue: "")
        let remote = snapshot.remotes.first(where: { $0.name == remoteName })
        let prefix = remoteName + "/"
        let cached = remote?.branches.map {
            $0.name.hasPrefix(prefix) ? String($0.name.dropFirst(prefix.count)) : $0.name
        }.filter { $0 != "HEAD" } ?? []
        let names = Array(Set(advertised ?? cached)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        names.forEach { remoteBranchCombo.addItem(withObjectValue: $0) }
        if !selected.isEmpty, names.contains(selected) { remoteBranchCombo.stringValue = selected }
        else { remoteBranchCombo.stringValue = "" }
    }

    private func loadAdvertisedRemoteBranches() {
        remoteBranchTask?.cancel()
        guard remoteChoice.state == .on else { return }
        let remote = remoteCombo.stringValue
        guard !remote.isEmpty, remote != "[ All ]", snapshot.remotes.contains(where: { $0.name == remote }) else { return }
        remoteBranchCombo.toolTip = "Loading branches from \(remote)…"
        remoteBranchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let names = try await source.loadRemoteBranchNames(named: remote)
                guard !Task.isCancelled, remoteCombo.stringValue == remote else { return }
                populateRemoteBranches(advertised: names, preserveSelection: true)
                remoteBranchCombo.toolTip = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, remoteCombo.stringValue == remote else { return }
                remoteBranchCombo.toolTip = "Could not query \(remote): \(error.localizedDescription)"
            }
        }
    }

    private var selectedMode: RepositoryPullMode {
        if fetchMode.state == .on { return .fetch }
        if rebaseMode.state == .on { return .rebase }
        return .merge
    }

    private func setMode(_ mode: RepositoryPullMode, resetLocal: Bool) {
        mergeMode.state = mode == .merge ? .on : .off
        rebaseMode.state = mode == .rebase ? .on : .off
        fetchMode.state = mode == .fetch ? .on : .off
        if resetLocal {
            localBranchField.stringValue = mode == .fetch ? "" : snapshot.branches.first(where: \.isCurrent)?.name ?? ""
        }
        if mode != .fetch, allTags.state == .on {
            allTags.state = .off; reachableTags.state = .on
        }
        updateEnabledState()
        updateHelp()
    }

    private func updateEnabledState() {
        guard !applyingState else { return }
        applyingState = true
        defer { applyingState = false }
        let isFetch = selectedMode == .fetch
        let all = remoteChoice.state == .on && remoteCombo.stringValue == "[ All ]"
        mergeMode.isEnabled = !all
        rebaseMode.isEnabled = !all
        localBranchField.isEnabled = isFetch
        allTags.isEnabled = isFetch
        prune.isEnabled = isFetch
        pruneTags.isEnabled = isFetch
        remoteBranchCombo.isEnabled = !all
        executeButton.title = isFetch ? "Fetch" : "Pull"
        executeButton.image = AppKitFactory.resourceImage("ArrowDown", accessibilityDescription: executeButton.title)
        executeButton.isEnabled = true
        view.window?.title = "\(executeButton.title) (\(snapshot.currentRepository.path))"
    }

    private func updateSourceControls() {
        let remote = remoteChoice.state == .on
        remoteCombo.isEnabled = remote
        manageButton.isEnabled = remote
        urlCombo.isEnabled = !remote
        browseButton.isEnabled = !remote
        if remote {
            updateRemoteURL(resetRemoteBranch: true)
        } else {
            populateURLBranches(preserveSelection: false)
        }
        updateEnabledState()
    }

    private func populateURLBranches(preserveSelection: Bool = true) {
        remoteBranchTask?.cancel()
        let selected = preserveSelection ? remoteBranchCombo.stringValue : ""
        remoteBranchCombo.removeAllItems()
        remoteBranchCombo.addItem(withObjectValue: "")
        snapshot.branches.filter { !$0.isRemote }.map(\.name).forEach { remoteBranchCombo.addItem(withObjectValue: $0) }
        remoteBranchCombo.stringValue = selected
    }

    private func request() -> RepositoryPullRequest {
        let sourceValue: RepositoryPullSource
        if remoteChoice.state == .on {
            sourceValue = remoteCombo.stringValue == "[ All ]" ? .allRemotes : .remote(remoteCombo.stringValue)
        } else {
            sourceValue = .url(urlCombo.stringValue)
        }
        let tags: RepositoryFetchTagMode = allTags.state == .on ? .allTags : (noTags.state == .on ? .noTags : .followTagOption)
        return RepositoryPullRequest(
            source: sourceValue,
            mode: selectedMode,
            localBranch: localBranchField.stringValue,
            remoteBranch: remoteBranchCombo.stringValue,
            tagMode: tags,
            unshallow: unshallow.state == .on,
            prune: prune.state == .on,
            pruneTags: pruneTags.state == .on,
            autoStash: autoStash.state == .on,
            includeUntrackedInAutoStash: settings.pullPreferences.includeUntrackedInAutoStash,
            updateSubmodulesAfterPull: false
        )
    }

    private func attemptImmediateExecutionIfReady() {
        guard executeImmediately, !didAttemptImmediateExecution, pullState != nil, view.window != nil else { return }
        didAttemptImmediateExecution = true
        execute()
    }

    @objc private func execute() {
        guard operationTask == nil, let window = view.window else { return }
        let request = request()
        if request.source.commandValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            showValidation("Please select a remote or source URL.")
            return
        }
        if request.mode != .fetch, request.remoteBranch?.replacingOccurrences(of: " ", with: "") == "*" {
            showValidation("The wildcard branch can be used only with Fetch.")
            return
        }
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { operationTask = nil }
            guard let prepared = await prepare(request) else { return }
            persistExecutionChoices(prepared)
            let process = await PullProcessDialog.run(request: prepared, source: source, parent: window)
            switch process {
            case .success(let result):
                snapshot = result.snapshot
                onSnapshot(result.snapshot, result.selectedCommitID)
                statusLabel.stringValue = result.message
                if case .conflicts = result.outcome {
                    if let refreshed = await WorkflowManagementDialogs.resolveConflicts(source: source, window: window) {
                        snapshot = refreshed
                        onSnapshot(refreshed, refreshed.commits.first(where: \.isHEAD)?.id)
                    }
                } else if result.automaticStashCreated, result.outcome == .completed {
                    await handleAutomaticStash()
                }
                if let remote = result.suggestsRemotePrune { await offerRemotePrune(remote) }
                view.window?.performClose(nil)
            case .failure(let error):
                statusLabel.stringValue = error is CancellationError ? "Aborted" : error.localizedDescription
                await refreshAfterInterruptedOperation()
                view.window?.performClose(nil)
            case nil:
                statusLabel.stringValue = "Aborted"
                await refreshAfterInterruptedOperation()
                view.window?.performClose(nil)
            }
        }
    }

    private func prepare(_ original: RepositoryPullRequest) async -> RepositoryPullRequest? {
        guard let state = pullState else { return original }
        var localBranch = original.localBranch?.trimmingCharacters(in: .whitespacesAndNewlines)
        var remoteBranch = original.remoteBranch?.trimmingCharacters(in: .whitespacesAndNewlines)
        if localBranch?.isEmpty == true { localBranch = nil }
        if remoteBranch?.isEmpty == true { remoteBranch = nil }

        if executeImmediately,
           initialAction == .fetchPruneAll,
           settings.pullPreferences.confirmFetchAndPruneAll {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Prune remote branches from \(original.source.commandValue)"
            alert.informativeText = "The fetch with prune will remove remote-tracking references which no longer exist on their remotes. Do you want to proceed?"
            alert.addButton(withTitle: "Fetch and prune")
            alert.addButton(withTitle: "Cancel")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Do not ask again"
            guard await begin(alert) == .alertFirstButtonReturn else { return nil }
            if alert.suppressionButton?.state == .on {
                var preferences = settings.pullPreferences
                preferences.confirmFetchAndPruneAll = false
                settings.savePullPreferences(preferences)
            }
        }

        if original.mode != .fetch,
           state.isDetached,
           remoteBranch == nil {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "HEAD is detached"
            alert.informativeText = "You cannot Pull onto a named branch while HEAD is detached. Check out a branch first, continue anyway, or cancel."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Checkout branch…")
            alert.addButton(withTitle: "Continue")
            switch await begin(alert) {
            case .alertSecondButtonReturn:
                guard await checkoutBranchForDetachedHead() else { return nil }
                let refreshed = try? await source.loadPullState()
                pullState = refreshed
                localBranch = refreshed?.currentBranch
            case .alertThirdButtonReturn:
                break
            default:
                return nil
            }
        }

        if case .remote(let remote) = original.source,
           remoteBranch == nil,
           let localBranch,
           !localBranch.isEmpty {
            if original.mode == .fetch, localBranch == state.currentBranch {
                self.localBranchField.stringValue = ""
                return copy(
                    original,
                    localBranch: nil,
                    remoteBranch: nil,
                    updateSubmodules: false
                )
            }
            let configuredRemote = state.configuredRemote?.trimmingCharacters(in: .whitespacesAndNewlines)
            let shouldDeriveRemoteBranch = original.mode == .fetch
                || (configuredRemote?.isEmpty == false && remote != configuredRemote)
            if shouldDeriveRemoteBranch {
                let verb = original.mode == .fetch ? "Fetch" : "Pull"
                let alert = NSAlert()
                alert.messageText = "Remote branch not specified"
                alert.informativeText = "You asked to \(verb.lowercased()) from ‘\(remote)’, but did not specify a remote branch. Use ‘\(remote)/\(localBranch)’?"
                alert.addButton(withTitle: "\(verb) from \(remote)/\(localBranch)")
                alert.addButton(withTitle: "Cancel")
                guard await begin(alert) == .alertFirstButtonReturn else { return nil }
                remoteBranch = localBranch
            }
        }

        if original.mode == .rebase,
           case .remote(let remote) = original.source,
           (try? await source.hasUnpushedMergeCommit(remote: remote, branch: remoteBranch)) == true {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Rebase merge commit?"
            alert.informativeText = "The current commit is a merge. Are you sure you want to rebase this merge?"
            alert.addButton(withTitle: "No")
            alert.addButton(withTitle: "Yes")
            alert.addButton(withTitle: "Cancel")
            guard await begin(alert) == .alertSecondButtonReturn else { return nil }
        }

        var updateSubmodules = false
        if original.mode != .fetch, !snapshot.submodules.isEmpty {
            switch settings.pullPreferences.updateSubmodulesAfterPull {
            case true:
                updateSubmodules = true
            case false:
                updateSubmodules = false
            case nil:
                let initializing = snapshot.submodules.contains(where: { $0.state == .uninitialized })
                let alert = NSAlert()
                alert.messageText = "Submodules"
                if initializing {
                    alert.informativeText = "The repository has uninitialized submodules. Initialize and update all submodules recursively after Pull?"
                    alert.addButton(withTitle: "Initialize submodules")
                } else {
                    alert.informativeText = "Update all configured submodules recursively after Pull?"
                    alert.addButton(withTitle: "Update submodules")
                }
                alert.addButton(withTitle: "Not now")
                updateSubmodules = await begin(alert) == .alertFirstButtonReturn
            }
        }

        return copy(
            original,
            localBranch: localBranch,
            remoteBranch: remoteBranch,
            updateSubmodules: updateSubmodules
        )
    }

    private func copy(
        _ request: RepositoryPullRequest,
        localBranch: String?,
        remoteBranch: String?,
        updateSubmodules: Bool
    ) -> RepositoryPullRequest {
        RepositoryPullRequest(
            source: request.source,
            mode: request.mode,
            localBranch: localBranch,
            remoteBranch: remoteBranch,
            tagMode: request.tagMode,
            unshallow: request.unshallow,
            prune: request.prune,
            pruneTags: request.pruneTags,
            autoStash: request.autoStash,
            includeUntrackedInAutoStash: request.includeUntrackedInAutoStash,
            updateSubmodulesAfterPull: updateSubmodules,
            environment: request.environment
        )
    }

    private func checkoutBranchForDetachedHead() async -> Bool {
        guard view.window != nil else { return false }
        let branches = snapshot.branches.filter { !$0.isRemote }
        guard !branches.isEmpty else {
            await showError(RepositoryPullError.operationInProgress("HEAD is detached and no local branch is available"), title: "Checkout branch")
            return false
        }
        let selector = NSPopUpButton()
        selector.addItems(withTitles: branches.map(\.name))
        let alert = NSAlert()
        alert.messageText = "Checkout branch"
        alert.informativeText = "Select a local branch before Pull."
        alert.addButton(withTitle: "Checkout")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = selector
        guard await begin(alert) == .alertFirstButtonReturn,
              let name = selector.titleOfSelectedItem else { return false }
        do {
            let result = try await source.checkout(RepositoryCheckoutRequest(target: .localBranch(name), localChanges: .keep))
            snapshot = result.snapshot
            onSnapshot(result.snapshot, result.selectedCommitID)
            localBranchField.stringValue = name
            return true
        } catch {
            await showError(error, title: "Checkout failed")
            return false
        }
    }

    private func refreshAfterInterruptedOperation() async {
        do {
            let refreshed = try await source.loadSnapshot()
            snapshot = refreshed
            onSnapshot(refreshed, nil)
            pullState = try await source.loadPullState()
            updateEnabledState()
        } catch {
            statusLabel.stringValue = error.localizedDescription
        }
    }

    private func persistExecutionChoices(_ request: RepositoryPullRequest) {
        var preferences = settings.pullPreferences
        preferences.formAction = switch request.mode {
        case .merge: .merge
        case .rebase: .rebase
        case .fetch: .fetch
        }
        preferences.autoStash = request.autoStash
        settings.savePullPreferences(preferences)
        if case .url(let value) = request.source { settings.recordPullURL(value) }
    }

    private func handleAutomaticStash() async {
        let shouldPop: Bool
        switch settings.pullPreferences.autoPopStash {
        case .always: shouldPop = true
        case .never: shouldPop = false
        case .ask:
            let alert = NSAlert()
            alert.messageText = "Apply the automatic stash?"
            alert.informativeText = "The Pull completed successfully. Reapply the changes saved before Pull?"
            alert.addButton(withTitle: "Apply stash"); alert.addButton(withTitle: "Keep stash")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Do not ask again"
            shouldPop = await begin(alert) == .alertFirstButtonReturn
            if alert.suppressionButton?.state == .on {
                var preferences = settings.pullPreferences
                preferences.autoPopStash = shouldPop ? .always : .never
                settings.savePullPreferences(preferences)
            }
        }
        guard shouldPop else { return }
        do {
            let result = try await source.popStash(nil)
            snapshot = result.snapshot
            onSnapshot(result.snapshot, result.selectedCommitID)
            statusLabel.stringValue = result.message
            if case .conflicts = result.outcome,
               let window = view.window,
               let refreshed = await WorkflowManagementDialogs.resolveConflicts(source: source, window: window) {
                snapshot = refreshed
                onSnapshot(refreshed, refreshed.commits.first(where: \.isHEAD)?.id)
            }
        } catch { await showError(error, title: "Automatic stash could not be applied") }
    }

    private func offerRemotePrune(_ remote: String) async {
        let alert = NSAlert()
        alert.messageText = "Remote branch no longer exists"
        alert.informativeText = "Do you want to delete all stale remote-tracking branches from ‘\(remote)’?"
        alert.addButton(withTitle: "Prune")
        alert.addButton(withTitle: "No")
        alert.addButton(withTitle: "Cancel")
        guard await begin(alert) == .alertFirstButtonReturn, let window = view.window else { return }
        let result = await PullProcessDialog.runPrune(remote: remote, source: source, parent: window)
        if case .success(let value) = result {
            snapshot = value.snapshot
            onSnapshot(value.snapshot, value.selectedCommitID)
            statusLabel.stringValue = value.message
        }
    }

    @objc private func sourceChanged(_ sender: NSButton) {
        remoteChoice.state = sender === remoteChoice ? .on : .off
        urlChoice.state = sender === urlChoice ? .on : .off
        updateSourceControls()
    }
    @objc private func remoteChanged() { updateRemoteURL(resetRemoteBranch: true) }
    @objc private func urlChanged() { if urlChoice.state == .on { populateURLBranches(preserveSelection: false) } }
    func comboBoxSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSComboBox === remoteCombo { updateRemoteURL(resetRemoteBranch: true) }
        if notification.object as? NSComboBox === urlCombo, urlChoice.state == .on { populateURLBranches(preserveSelection: false) }
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        if let combo = notification.object as? NSComboBox, combo === remoteCombo {
            updateRemoteURL(resetRemoteBranch: true)
        } else if let combo = notification.object as? NSComboBox, combo === urlCombo, urlChoice.state == .on {
            populateURLBranches(preserveSelection: false)
        } else if let field = notification.object as? NSTextField,
                  field === localBranchField,
                  selectedMode == .fetch,
                  localBranchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) != pullState?.currentBranch,
                  remoteBranchCombo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            remoteBranchCombo.stringValue = localBranchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    @objc private func modeChanged(_ sender: NSButton) {
        if sender === fetchMode { setMode(.fetch, resetLocal: true) }
        else if sender === rebaseMode { setMode(.rebase, resetLocal: true) }
        else { setMode(.merge, resetLocal: true) }
    }
    @objc private func tagModeChanged(_ sender: NSButton) {
        for button in [reachableTags, noTags, allTags] {
            button.state = button === sender ? .on : .off
        }
    }
    @objc private func pruneChanged() { if prune.state == .off { pruneTags.state = .off } }
    @objc private func pruneTagsChanged() {
        if pruneTags.state == .on {
            prune.state = .on; allTags.state = .on; reachableTags.state = .off; noTags.state = .off
        }
    }

    @objc private func browseForSource() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let path = panel.url?.path else { return }
            self?.urlCombo.stringValue = path
            self?.urlChoice.state = .on
            self?.remoteChoice.state = .off
            self?.updateSourceControls()
        }
    }

    @objc private func manageRemotes() {
        if let remoteWindowController { remoteWindowController.window?.makeKeyAndOrderFront(nil); return }
        let selected = remoteCombo.stringValue == "[ All ]" ? nil : remoteCombo.stringValue
        remoteWindowController = RemoteManagementDialog.present(
            source: source,
            selectedRemote: selected,
            onSnapshot: { [weak self] snapshot in
                guard let self else { return }
                self.snapshot = snapshot; self.onSnapshot(snapshot, nil)
                self.populateRemotes(selecting: self.remoteCombo.stringValue)
            },
            onClose: { [weak self] in self?.remoteWindowController = nil }
        )
    }

    @objc private func solveConflicts() {
        guard operationTask == nil, let window = view.window else { return }
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if let refreshed = await WorkflowManagementDialogs.resolveConflicts(source: source, window: window) {
                snapshot = refreshed
                onSnapshot(refreshed, refreshed.commits.first(where: \.isHEAD)?.id)
            }
            operationTask = nil
            reloadRepositoryState()
        }
    }

    @objc private func stashChanges() {
        guard operationTask == nil, let window = view.window else { return }
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if let request = await MutationDialogs.stashCreateRequest(window: window) {
                do {
                    let result = try await source.createStash(request)
                    snapshot = result.snapshot
                    onSnapshot(result.snapshot, result.selectedCommitID)
                    statusLabel.stringValue = result.message
                } catch { await showError(error, title: "Stash failed") }
            }
            operationTask = nil
            reloadRepositoryState()
        }
    }

    @objc private func toggleHelp() {
        let oldWidth = isHelpExpanded ? 307.0 : 30.0
        isHelpExpanded.toggle()
        let newWidth = isHelpExpanded ? 307.0 : 30.0
        helpWidthConstraint?.constant = newWidth
        updateHelpVisibility()
        var preferences = settings.pullPreferences
        preferences.helpExpanded = isHelpExpanded
        settings.savePullPreferences(preferences)
        guard let window = view.window else { return }
        var frame = window.frame
        frame.origin.x -= newWidth - oldWidth
        frame.size.width += newWidth - oldWidth
        if let screen = window.screen ?? NSScreen.main {
            frame = window.constrainFrameRect(frame, to: screen)
        }
        window.setFrame(frame, display: true, animate: false)
    }

    private func updateHelpVisibility() {
        helpImageView.isHidden = !isHelpExpanded
        helpNotice.isHidden = !isHelpExpanded || helpImageView.alternateImage == nil
        if isHelpExpanded {
            helpToggle.image = nil
            helpToggle.isBordered = false
            helpToggle.attributedTitle = NSAttributedString(
                string: "Hide help",
                attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
            )
            helpToggle.toolTip = nil
        } else {
            helpToggle.attributedTitle = NSAttributedString(string: "")
            helpToggle.image = AppKitFactory.resourceImage("Information", accessibilityDescription: "Show help")
            helpToggle.imagePosition = .imageOnly
            helpToggle.isBordered = true
            helpToggle.bezelStyle = .texturedRounded
            helpToggle.toolTip = "Show help"
            helpToggle.setAccessibilityLabel("Show help")
        }
    }

    private func updateHelp() {
        let names: (String, String?) = switch selectedMode {
        case .fetch: ("HelpPullFetch", nil)
        case .rebase: ("HelpPullRebase", nil)
        case .merge: ("HelpPullMerge", "HelpPullMergeFastForward")
        }
        let primary = AppKitFactory.resourceImage(names.0, accessibilityDescription: "Pull scenario", size: NSSize(width: 307, height: 375), adaptLightness: true)
        let alternate = names.1.flatMap { AppKitFactory.resourceImage($0, accessibilityDescription: "Fast-forward merge scenario", size: NSSize(width: 307, height: 375), adaptLightness: true) }
        helpImageView.setImages(primary: primary, alternate: alternate)
        updateHelpVisibility()
    }

    private func group(_ title: String, _ content: NSView) -> NSBox {
        let box = NSBox()
        box.title = title; box.titlePosition = .atTop; box.boxType = .custom
        box.borderWidth = 1; box.cornerRadius = 0; box.fillColor = .clear
        content.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(content)
        if let holder = box.contentView {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 8),
                content.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -8),
                content.topAnchor.constraint(equalTo: holder.topAnchor, constant: 6),
                content.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -8)
            ])
        }
        return box
    }

    private func vertical(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        return stack
    }
    private func rightLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title); label.alignment = .right; return label
    }
    private func decorateRadioTitle(_ button: NSButton, imageName: String, title: String) {
        let value = NSMutableAttributedString()
        if let image = AppKitFactory.resourceImage(
            imageName,
            accessibilityDescription: nil,
            size: NSSize(width: 16, height: 16)
        ) {
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)
            value.append(NSAttributedString(attachment: attachment))
            value.append(NSAttributedString(string: " "))
        }
        value.append(NSAttributedString(
            string: title,
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
        ))
        button.attributedTitle = value
        button.setAccessibilityLabel(title)
    }
    private func showValidation(_ message: String) {
        let alert = NSAlert(); alert.messageText = "Pull"; alert.informativeText = message; alert.addButton(withTitle: "OK")
        if let window = view.window { alert.beginSheetModal(for: window) }
    }
    private func showError(_ error: Error, title: String) async {
        let alert = NSAlert(error: error); alert.messageText = title; alert.addButton(withTitle: "OK"); _ = await begin(alert)
    }
    private func begin(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = view.window else { return .abort }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }
    func windowWillClose(_ notification: Notification) { finish() }
    private func finish() {
        guard !didClose else { return }
        didClose = true
        remoteBranchTask?.cancel(); operationTask?.cancel(); remoteWindowController?.close(); onClose?()
    }
}

@MainActor
enum PullProcessDialog {
    typealias Operation = @Sendable (@escaping GitOutputHandler) async throws -> RepositoryPullResult

    static func run(
        request: RepositoryPullRequest,
        source: any RepositoryPullingDataSource,
        parent: NSWindow
    ) async -> Result<RepositoryPullResult, Error>? {
        let title = request.mode == .fetch ? "Fetch" : "Pull"
        let initialStatus = request.mode == .fetch
            ? "Fetching…"
            : (request.mode == .rebase ? "Pulling with rebase…" : "Pulling with merge…")
        return await run(title: title, initialStatus: initialStatus, parent: parent) { output in
            try await source.performPull(request, output: output)
        }
    }

    static func runPrune(
        remote: String,
        source: any RepositoryPullingDataSource,
        parent: NSWindow
    ) async -> Result<RepositoryPullResult, Error>? {
        await run(title: "Prune remote branches from \(remote)", initialStatus: "Pruning \(remote)…", parent: parent) { output in
            try await source.pruneRemote(named: remote, output: output)
        }
    }

    private static func run(
        title: String,
        initialStatus: String,
        parent: NSWindow,
        operation: @escaping Operation
    ) async -> Result<RepositoryPullResult, Error>? {
        let controller = PullProcessViewController(initialStatus: initialStatus, operation: operation)
        let panel = NSPanel(contentViewController: controller)
        panel.title = title
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
private final class PullProcessViewController: NSViewController, NSWindowDelegate {
    weak var panel: NSPanel?
    var onClose: ((Result<RepositoryPullResult, Error>?) -> Void)?
    private let initialStatus: String
    private let operation: PullProcessDialog.Operation
    private let progress = NSProgressIndicator()
    private let status = NSTextField(labelWithString: "Waiting…")
    private let outputView = NSTextView()
    private let keepOpen = NSButton(checkboxWithTitle: "Keep dialog open", target: nil, action: nil)
    private let abortButton = NSButton(title: "Abort", target: nil, action: nil)
    private let closeButton = NSButton(title: "OK", target: nil, action: nil)
    private var task: Task<Void, Never>?
    private var result: Result<RepositoryPullResult, Error>?
    private var didClose = false

    init(initialStatus: String, operation: @escaping PullProcessDialog.Operation) {
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
        outputView.isEditable = false; outputView.isSelectable = true
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
        scroll.documentView = outputView; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .bezelBorder
        keepOpen.state = AppSettingsStore.shared.pullPreferences.closeProcessOnSuccess ? .off : .on
        keepOpen.target = self; keepOpen.action = #selector(keepOpenChanged)
        abortButton.target = self; abortButton.action = #selector(abort)
        closeButton.target = self; closeButton.action = #selector(close); closeButton.keyEquivalent = "\r"; closeButton.isEnabled = false
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [progress, status]); header.orientation = .horizontal; header.alignment = .centerY; header.spacing = 8
        let footer = NSStackView(views: [keepOpen, spacer, abortButton, closeButton]); footer.orientation = .horizontal; footer.alignment = .centerY; footer.spacing = 8
        for subview in [header, scroll, footer] { subview.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(subview) }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
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
                case .conflicts(_, let paths): status.stringValue = "Stopped with \(paths.count) conflict(s)"
                case .failed:
                    let failed = value.followUpCommands.first(where: { !$0.succeeded }) ?? value.command
                    status.stringValue = "Failed (exit \(failed.exitStatus))"
                }
            } catch is CancellationError {
                status.stringValue = "Aborted"; result = .failure(CancellationError()); appendText("\nAborted\n", color: .systemOrange)
            } catch {
                status.stringValue = "Failed"; result = .failure(error); appendText("\n\(error.localizedDescription)\n", color: .systemRed)
            }
            progress.stopAnimation(nil); abortButton.isEnabled = false; closeButton.isEnabled = true; task = nil
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
           value.outcome == .completed {
            finish()
        }
    }
    @objc private func abort() { status.stringValue = "Aborting…"; task?.cancel() }
    @objc private func close() { finish() }
    func windowWillClose(_ notification: Notification) { if task != nil { task?.cancel() }; finish() }
    private func finish() { guard !didClose else { return }; didClose = true; onClose?(result) }
}
