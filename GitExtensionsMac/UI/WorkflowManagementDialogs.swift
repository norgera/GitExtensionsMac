import AppKit

enum ConflictSequencerAction: Equatable, Sendable {
    case none
    case continued
    case aborted
}

struct ConflictResolutionResult: Sendable {
    let snapshot: RepositorySnapshot?
    let sequencerAction: ConflictSequencerAction
}

@MainActor
enum WorkflowManagementDialogs {
    static func manageStashes(
        source: any RepositoryMutatingDataSource,
        snapshot: RepositorySnapshot,
        window: NSWindow,
        manageStashes: Bool = true,
        initialStash: String? = nil
    ) async -> StashDialogResult {
        await StashDialog.present(
            source: source,
            snapshot: snapshot,
            manageStashes: manageStashes,
            initialStash: initialStash,
            owner: window,
            resolveConflicts: { stashWindow in
                await resolveConflicts(source: source, window: stashWindow)
            }
        )
    }

    static func resolveConflicts(
        source: any RepositoryMutatingDataSource,
        window: NSWindow
    ) async -> RepositorySnapshot? {
        await presentConflictResolver(source: source, window: window).snapshot
    }

    static func resolveCherryPickConflicts(
        source: any RepositoryMutatingDataSource,
        window: NSWindow
    ) async -> ConflictResolutionResult {
        await presentConflictResolver(source: source, window: window)
    }

    private static func presentConflictResolver(
        source: any RepositoryMutatingDataSource,
        window: NSWindow
    ) async -> ConflictResolutionResult {
        let controller = ConflictResolverViewController(source: source)
        let panel = NSPanel(contentViewController: controller)
        panel.title = "Resolve merge conflicts"
        panel.styleMask = [.titled, .closable, .resizable]
        panel.setContentSize(NSSize(width: 680, height: 460))
        panel.minSize = NSSize(width: 540, height: 350)
        controller.panel = panel
        panel.delegate = controller
        return await withCheckedContinuation { continuation in
            controller.onClose = { result in
                window.endSheet(panel)
                continuation.resume(returning: result)
            }
            window.beginSheet(panel)
        }
    }

    static func manageRebase(
        source: any RepositoryMutatingDataSource,
        window: NSWindow
    ) async -> RepositorySnapshot? {
        let controller = RebaseManagerViewController(source: source)
        let panel = NSPanel(contentViewController: controller)
        panel.title = "Rebase"
        panel.styleMask = [.titled, .closable, .resizable]
        panel.setContentSize(NSSize(width: 1034, height: 461))
        panel.minSize = NSSize(width: 1050, height: 500)
        panel.setFrameAutosaveName("GitExtensionsMac.Rebase")
        controller.panel = panel
        panel.delegate = controller
        return await withCheckedContinuation { continuation in
            controller.onClose = { snapshot in
                window.endSheet(panel)
                continuation.resume(returning: snapshot)
            }
            window.beginSheet(panel)
        }
    }

    static func startRebase(
        source: any RepositoryMutatingDataSource,
        target: Commit,
        interactive: Bool,
        initialActions: [String: RepositoryRebaseTodoAction],
        advancedFrom: String?,
        showAdvancedOptions: Bool,
        window: NSWindow
    ) async -> RepositorySnapshot? {
        let controller = RebaseManagerViewController(
            source: source,
            target: target,
            interactive: interactive,
            initialActions: initialActions,
            advancedFrom: advancedFrom,
            showAdvancedOptions: showAdvancedOptions
        )
        let panel = NSPanel(contentViewController: controller)
        panel.title = "Rebase"
        panel.styleMask = [.titled, .closable, .resizable]
        panel.setContentSize(NSSize(width: 1034, height: 461))
        panel.minSize = NSSize(width: 1050, height: 500)
        panel.setFrameAutosaveName("GitExtensionsMac.Rebase")
        controller.panel = panel; panel.delegate = controller
        return await withCheckedContinuation { continuation in
            controller.onClose = { snapshot in window.endSheet(panel); continuation.resume(returning: snapshot) }
            window.beginSheet(panel)
        }
    }
}

@MainActor
private final class RebaseManagerViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    weak var panel: NSPanel?
    var onClose: ((RepositorySnapshot?) -> Void)?
    private let source: any RepositoryMutatingDataSource
    private let target: Commit?
    private let initiallyInteractive: Bool
    private let initialActions: [String: RepositoryRebaseTodoAction]
    private let advancedFrom: String?
    private let showsAdvancedOptions: Bool
    private let table = NSTableView()
    private let currentBranch = NSTextField(labelWithString: "Current branch:")
    private let status = NSTextField(labelWithString: "Loading rebase state…")
    private let heading = NSTextField(labelWithString: "Commits to re-apply:")
    private let scroll = NSScrollView()
    private let secondary = NSStackView()
    private let addFilesButton = NSButton(title: "Add files…", target: nil, action: nil)
    private let commitButton = NSButton(title: "Commit…", target: nil, action: nil)
    private let solveButton = NSButton(title: "Solve conflicts", target: nil, action: nil)
    private let continueButton = NSButton(title: "Continue rebase", target: nil, action: nil)
    private let skipButton = NSButton(title: "Skip currently applying commit", target: nil, action: nil)
    private let editTodoButton = NSButton(title: "Edit todo…", target: nil, action: nil)
    private let abortButton = NSButton(title: "Abort", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)
    private let idleOptions = NSStackView()
    private let targetField = NSComboBox()
    private let interactiveOption = NSButton(checkboxWithTitle: "Interactive Rebase", target: nil, action: nil)
    private let preserveMergesOption = NSButton(checkboxWithTitle: "Preserve Merges", target: nil, action: nil)
    private let autosquashOption = NSButton(checkboxWithTitle: "Autosquash", target: nil, action: nil)
    private let autoStashOption = NSButton(checkboxWithTitle: "Auto stash", target: nil, action: nil)
    private let ignoreDateOption = NSButton(checkboxWithTitle: "Ignore date", target: nil, action: nil)
    private let committerDateOption = NSButton(checkboxWithTitle: "Committer date is author date", target: nil, action: nil)
    private let updateRefsOption = NSButton(checkboxWithTitle: "Update dependent refs", target: nil, action: nil)
    private let specificRangeOption = NSButton(checkboxWithTitle: "Specific range", target: nil, action: nil)
    private let fromField = NSTextField(string: "")
    private let chooseFromButton = NSButton(title: "…", target: nil, action: nil)
    private let toField = NSComboBox()
    private let startButton = NSButton(title: "Rebase", target: nil, action: nil)
    private let helpPanel = NSView()
    private let helpToggle = NSButton(title: "", target: nil, action: nil)
    private let helpImage = NSImageView()
    private var helpWidthConstraint: NSLayoutConstraint?
    private var helpExpanded = AppSettingsStore.shared.rebasePreferences.helpExpanded
    private var rebaseState = RepositoryRebaseState(inProgress: false, hasConflicts: false, currentBranch: nil, currentCommitID: nil, patches: [], canEditTodo: false, hasAutoStash: false)
    private var rebaseConfiguration: RepositoryRebaseConfiguration?
    private var latestSnapshot: RepositorySnapshot?
    private var task: Task<Void, Never>?
    private var commitWindowController: NSWindowController?
    private var skippedCommitIDs = Set<String>()
    private var didClose = false
    private var didAutoStart = false

    init(
        source: any RepositoryMutatingDataSource,
        target: Commit? = nil,
        interactive: Bool = false,
        initialActions: [String: RepositoryRebaseTodoAction] = [:],
        advancedFrom: String? = nil,
        showAdvancedOptions: Bool = false
    ) {
        self.source = source; self.target = target; initiallyInteractive = interactive
        self.initialActions = initialActions; self.advancedFrom = advancedFrom
        showsAdvancedOptions = showAdvancedOptions
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    deinit { task?.cancel() }

    override func viewDidAppear() {
        super.viewDidAppear()
        if rebaseState.inProgress {
            panel?.makeFirstResponder(rebaseState.hasConflicts ? solveButton : continueButton)
        } else {
            panel?.makeFirstResponder(targetField)
        }
    }

    override func loadView() {
        let root = NSView()
        configureIdleOptions()
        heading.font = .boldSystemFont(ofSize: 13)
        for (id, title, width) in [
            ("Status", "Status", 82.0), ("Action", "Action", 72.0), ("Subject", "Subject", 330.0),
            ("Author", "Author", 130.0), ("Date", "Date", 150.0), ("Hash", "Commit hash", 92.0)
        ] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width
            table.addTableColumn(column)
        }
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true
        table.delegate = self
        table.dataSource = self
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .bezelBorder

        addFilesButton.target = self; addFilesButton.action = #selector(openCommit)
        commitButton.target = self; commitButton.action = #selector(openCommit)
        editTodoButton.target = self; editTodoButton.action = #selector(editTodo)
        solveButton.target = self; solveButton.action = #selector(resolveConflicts)
        continueButton.target = self; continueButton.action = #selector(continueRebase)
        skipButton.target = self; skipButton.action = #selector(skipRebase)
        abortButton.target = self; abortButton.action = #selector(abortRebase)
        cancelButton.target = self; cancelButton.action = #selector(cancelCurrentOperation); cancelButton.isHidden = true
        closeButton.target = self; closeButton.action = #selector(close); closeButton.keyEquivalent = "\u{1b}"
        startButton.keyEquivalent = "\r"
        startButton.image = AppKitFactory.resourceImage("Rebase", accessibilityDescription: "Rebase")
        startButton.imagePosition = .imageLeading
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        secondary.setViews([addFilesButton, commitButton, editTodoButton, spacer, skipButton], in: .leading)
        secondary.orientation = .horizontal; secondary.spacing = 6
        let footerSpacer = NSView(); footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [status, progress, footerSpacer, cancelButton, startButton, solveButton, continueButton, abortButton, closeButton])
        footer.orientation = .horizontal; footer.spacing = 7
        let content = NSStackView(views: [currentBranch, idleOptions, heading, scroll, secondary, footer])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 8
        configureHelpPanel()
        let stack = NSStackView(views: [helpPanel, content])
        stack.orientation = .horizontal; stack.alignment = .top; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            content.widthAnchor.constraint(greaterThanOrEqualToConstant: 650),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 215),
            secondary.widthAnchor.constraint(equalTo: content.widthAnchor), footer.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
        view = root
        reload()
    }

    private func configureIdleOptions() {
        targetField.stringValue = target?.id ?? ""
        targetField.completes = true; targetField.numberOfVisibleItems = 12
        targetField.widthAnchor.constraint(equalToConstant: 270).isActive = true
        interactiveOption.state = initiallyInteractive ? .on : .off
        autoStashOption.state = AppSettingsStore.shared.preferences.autoStashDuringRebase ? .on : .off
        specificRangeOption.state = advancedFrom == nil ? .off : .on
        fromField.stringValue = advancedFrom ?? ""
        fromField.placeholderString = "From (exclusive)"; fromField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        chooseFromButton.bezelStyle = .texturedRounded; chooseFromButton.toolTip = "Use the selected lower revision"
        chooseFromButton.target = self; chooseFromButton.action = #selector(useInitialFromRevision)
        toField.placeholderString = "Current branch"; toField.completes = true; toField.numberOfVisibleItems = 12
        toField.widthAnchor.constraint(equalToConstant: 170).isActive = true
        startButton.target = self; startButton.action = #selector(startRebase)
        interactiveOption.target = self; interactiveOption.action = #selector(optionChanged)
        ignoreDateOption.target = self; ignoreDateOption.action = #selector(optionChanged)
        committerDateOption.target = self; committerDateOption.action = #selector(optionChanged)
        specificRangeOption.target = self; specificRangeOption.action = #selector(optionChanged)
        let targetRow = NSStackView(views: [NSTextField(labelWithString: "Rebase on"), targetField])
        targetRow.orientation = .horizontal; targetRow.spacing = 7
        let top = NSStackView(views: [interactiveOption, preserveMergesOption, autosquashOption, autoStashOption, ignoreDateOption])
        top.orientation = .horizontal; top.spacing = 10
        let lower = NSStackView(views: [committerDateOption, updateRefsOption])
        lower.orientation = .horizontal; lower.spacing = 10
        let range = NSStackView(views: [specificRangeOption, NSTextField(labelWithString: "From (exc.)"), fromField, chooseFromButton, NSTextField(labelWithString: "To"), toField])
        range.orientation = .horizontal; range.spacing = 6
        idleOptions.orientation = .vertical; idleOptions.alignment = .leading; idleOptions.spacing = 6
        idleOptions.addArrangedSubview(NSTextField(labelWithString: "Rebase current branch on top of another branch"))
        idleOptions.addArrangedSubview(targetRow); idleOptions.addArrangedSubview(top); idleOptions.addArrangedSubview(lower); idleOptions.addArrangedSubview(range)
        optionChanged()
    }

    private func configureHelpPanel() {
        helpToggle.target = self; helpToggle.action = #selector(toggleHelp)
        helpToggle.setButtonType(.momentaryPushIn); helpToggle.alignment = .left
        helpImage.image = AppKitFactory.resourceImage(
            "HelpCommandRebase",
            accessibilityDescription: "Rebase scenario",
            size: NSSize(width: 289, height: 373),
            adaptLightness: true
        )
        helpImage.imageScaling = .scaleProportionallyDown; helpImage.imageAlignment = .alignTopLeft
        helpImage.translatesAutoresizingMaskIntoConstraints = false
        let helpStack = NSStackView(views: [helpToggle, helpImage])
        helpStack.orientation = .vertical; helpStack.alignment = .leading; helpStack.spacing = 6
        helpStack.translatesAutoresizingMaskIntoConstraints = false
        helpPanel.addSubview(helpStack)
        let width = helpPanel.widthAnchor.constraint(equalToConstant: helpExpanded ? 289 : 82)
        helpWidthConstraint = width
        NSLayoutConstraint.activate([
            width,
            helpStack.leadingAnchor.constraint(equalTo: helpPanel.leadingAnchor),
            helpStack.trailingAnchor.constraint(lessThanOrEqualTo: helpPanel.trailingAnchor),
            helpStack.topAnchor.constraint(equalTo: helpPanel.topAnchor),
            helpImage.widthAnchor.constraint(equalToConstant: 289),
            helpImage.heightAnchor.constraint(equalToConstant: 373)
        ])
        updateHelpVisibility()
    }

    @objc private func toggleHelp() {
        helpExpanded.toggle()
        helpWidthConstraint?.constant = helpExpanded ? 289 : 82
        updateHelpVisibility()
        var preferences = AppSettingsStore.shared.rebasePreferences
        preferences.helpExpanded = helpExpanded
        AppSettingsStore.shared.saveRebasePreferences(preferences)
    }

    private func updateHelpVisibility() {
        helpImage.isHidden = !helpExpanded
        helpToggle.attributedTitle = NSAttributedString(
            string: helpExpanded ? "Hide help" : "Show help",
            attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        )
        helpToggle.toolTip = helpExpanded ? "Hide help" : "Show help"
        helpToggle.setAccessibilityLabel(helpExpanded ? "Hide help" : "Show help")
    }

    @objc private func optionChanged() {
        let dateMode = ignoreDateOption.state == .on || committerDateOption.state == .on
        ignoreDateOption.isEnabled = committerDateOption.state != .on
        committerDateOption.isEnabled = ignoreDateOption.state != .on
        interactiveOption.isEnabled = !dateMode; preserveMergesOption.isEnabled = !dateMode
        autosquashOption.isEnabled = interactiveOption.state == .on && !dateMode
        let range = specificRangeOption.state == .on
        fromField.isEnabled = range; chooseFromButton.isEnabled = range && advancedFrom != nil; toField.isEnabled = range
    }

    @objc private func useInitialFromRevision() {
        if let advancedFrom { fromField.stringValue = advancedFrom }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rebaseState.patches.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let patch = rebaseState.patches[row]
        let value: String = switch tableColumn?.identifier.rawValue {
        case "Status": skippedCommitIDs.contains(patch.commitID) && patch.status == .applied ? RepositoryRebasePatchStatus.skipped.rawValue : patch.status.rawValue
        case "Action": patch.action
        case "Author": patch.author
        case "Date": patch.date
        case "Hash": String(patch.commitID.prefix(10))
        default: patch.subject
        }
        let cell = NSTableCellView(); let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: 12); label.lineBreakMode = .byTruncatingTail; label.translatesAutoresizingMaskIntoConstraints = false
        if patch.status == .applying { label.textColor = .systemOrange }
        cell.addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }

    private func reload() {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            await loadState()
            task = nil
        }
    }

    private func loadState() async {
        do {
            async let loadedState = source.loadRebaseState()
            async let snapshot = source.loadSnapshot()
            let (state, refreshed) = try await (loadedState, snapshot)
            if rebaseConfiguration == nil { rebaseConfiguration = try await source.loadRebaseConfiguration() }
            apply(state: state, snapshot: refreshed)
        } catch is CancellationError {
            status.stringValue = "Rebase operation cancelled."
        } catch {
            status.stringValue = error.localizedDescription
        }
    }

    private func apply(state: RepositoryRebaseState, snapshot: RepositorySnapshot) {
        rebaseState = state; latestSnapshot = snapshot
        currentBranch.stringValue = "Current branch: \(state.currentBranch ?? "(detached HEAD)")"
        populateReferences(from: snapshot)
        if let configuration = rebaseConfiguration {
            if autosquashOption.state == .off { autosquashOption.state = configuration.autoSquash ? .on : .off }
            if updateRefsOption.state == .off { updateRefsOption.state = configuration.updateRefs ? .on : .off }
            updateRefsOption.isHidden = !configuration.supportsUpdateRefs
            autoStashOption.isEnabled = configuration.isDirty && !state.inProgress
        }
        let active = state.inProgress
        idleOptions.isHidden = active
        startButton.isHidden = active
        secondary.isHidden = !active
        solveButton.isHidden = !active || !state.hasConflicts
        continueButton.isHidden = !active || state.hasConflicts
        abortButton.isHidden = !active
        startButton.keyEquivalent = active ? "" : "\r"
        continueButton.keyEquivalent = active && !state.hasConflicts ? "\r" : ""
        solveButton.keyEquivalent = active && state.hasConflicts ? "\r" : ""
        editTodoButton.isEnabled = state.canEditTodo
        skipButton.isEnabled = active
        heading.isHidden = false; scroll.isHidden = false
        status.stringValue = active
            ? (state.hasConflicts ? "Rebase is currently in progress with merge conflicts." : "Rebase is currently in progress.")
            : "Ready."
        table.reloadData()
        if let index = state.patches.firstIndex(where: { $0.status == .applying }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
        }
        optionChanged()
        if !active, target == nil {
            finish(snapshot)
        } else if !active, !showsAdvancedOptions, !didAutoStart {
            didAutoStart = true
            DispatchQueue.main.async { [weak self] in self?.startRebase() }
        }
    }

    private func populateReferences(from snapshot: RepositorySnapshot) {
        let refs = Array(Set(snapshot.branches.map(\.name) + snapshot.tags.map(\.name))).sorted()
        let targetValue = targetField.stringValue
        let toValue = toField.stringValue
        targetField.removeAllItems(); targetField.addItems(withObjectValues: refs)
        toField.removeAllItems(); toField.addItems(withObjectValues: snapshot.branches.filter { !$0.isRemote }.map(\.name).sorted())
        targetField.stringValue = targetValue
        toField.stringValue = toValue.isEmpty ? (snapshot.branches.first(where: \.isCurrent)?.name ?? "HEAD") : toValue
    }

    private func execute(
        status runningStatus: String,
        operation: @escaping @Sendable (any RepositoryMutatingDataSource) async throws -> RepositoryMutationResult
    ) {
        guard task == nil else { return }
        setBusy(true, status: runningStatus)
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await operation(source)
                latestSnapshot = result.snapshot
                if case .completed = result.outcome, !(try await source.loadRebaseState()).inProgress {
                    if result.message.localizedCaseInsensitiveContains("up to date"), let panel {
                        await MutationDialogs.showInformation(result.message, title: "Rebase", window: panel)
                    }
                    task = nil; setBusy(false, status: result.message); finish(result.snapshot)
                } else {
                    await loadState(); task = nil; setBusy(false, status: result.message)
                }
            } catch is CancellationError {
                task = nil; setBusy(false, status: "Rebase operation cancelled."); await loadState()
            } catch {
                task = nil; setBusy(false, status: error.localizedDescription); await showError(error, title: "Rebase failed"); await loadState()
            }
        }
    }

    private func setBusy(_ busy: Bool, status message: String) {
        status.stringValue = message
        if busy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        cancelButton.isHidden = !busy
        startButton.isEnabled = !busy; continueButton.isEnabled = !busy; solveButton.isEnabled = !busy
        skipButton.isEnabled = !busy && rebaseState.inProgress; abortButton.isEnabled = !busy && rebaseState.inProgress
        editTodoButton.isEnabled = !busy && rebaseState.canEditTodo; closeButton.isEnabled = !busy
    }

    @objc private func startRebase() {
        guard task == nil, let panel else { return }
        let upstream = targetField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !upstream.isEmpty else {
            status.stringValue = "Please select a branch."
            NSSound.beep()
            return
        }
        let useRange = specificRangeOption.state == .on
        let from = useRange ? fromField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let branch = useRange ? toField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        if useRange, from?.isEmpty != false || branch?.isEmpty != false {
            status.stringValue = "Specific range requires both From and To revisions."
            NSSound.beep()
            return
        }
        var preferences = AppSettingsStore.shared.preferences
        preferences.autoStashDuringRebase = autoStashOption.state == .on
        AppSettingsStore.shared.save(preferences)
        let updateRefs: Bool? = rebaseConfiguration.flatMap {
            $0.updateRefs == (updateRefsOption.state == .on) ? nil : updateRefsOption.state == .on
        }
        let usesInteractiveRebase = interactiveOption.state == .on
            && ignoreDateOption.state != .on
            && committerDateOption.state != .on
        if usesInteractiveRebase {
            setBusy(true, status: "Loading interactive rebase plan…")
            task = Task { @MainActor [weak self, weak panel] in
                guard let self, let panel else { return }
                do {
                    let todo = try await source.loadNativeInteractiveRebaseTodo(RepositoryInteractiveRebaseTodoRequest(
                        upstream: upstream,
                        autoStash: autoStashOption.state == .on,
                        autoSquash: autosquashOption.state == .on,
                        rebaseMerges: preserveMergesOption.state == .on,
                        updateRefs: updateRefs,
                        onto: useRange ? upstream : nil,
                        from: from,
                        branch: branch
                    ))
                    setBusy(false, status: "Edit the rebase todo.")
                    task = nil
                    guard let target,
                          let request = await MutationDialogs.nativeInteractiveRebaseRequest(
                            target: target,
                            upstream: upstream,
                            todo: todo,
                            initialActions: initialActions,
                            autoStash: autoStashOption.state == .on,
                            autoSquash: autosquashOption.state == .on,
                            rebaseMerges: preserveMergesOption.state == .on,
                            updateRefs: updateRefs,
                            onto: useRange ? upstream : nil,
                            from: from,
                            branch: branch,
                            window: panel
                          ) else {
                        if showsAdvancedOptions {
                            status.stringValue = "Rebase cancelled."
                        } else {
                            finish(latestSnapshot)
                        }
                        return
                    }
                    execute(status: "Rebasing interactively…") { try await $0.interactiveRebase(request) }
                } catch is CancellationError {
                    task = nil; setBusy(false, status: "Rebase cancelled.")
                    if !showsAdvancedOptions { finish(latestSnapshot) }
                } catch {
                    task = nil; setBusy(false, status: error.localizedDescription); await showError(error, title: "Rebase failed")
                }
            }
        } else {
            let request = RepositoryRebaseRequest(
                upstream: upstream,
                autoStash: autoStashOption.state == .on,
                rebaseMerges: preserveMergesOption.state == .on,
                updateRefs: updateRefs,
                ignoreDate: ignoreDateOption.state == .on,
                committerDateIsAuthorDate: committerDateOption.state == .on,
                onto: useRange ? upstream : nil,
                from: from,
                branch: branch
            )
            execute(status: "Rebasing…") { try await $0.rebase(request) }
        }
    }

    @objc private func continueRebase() { execute(status: "Continuing rebase…") { try await $0.continueRebase() } }
    @objc private func skipRebase() {
        if let applying = rebaseState.patches.first(where: { $0.status == .applying }), !applying.commitID.isEmpty {
            skippedCommitIDs.insert(applying.commitID)
        }
        execute(status: "Skipping the current patch…") { try await $0.skipRebase() }
    }
    @objc private func abortRebase() { execute(status: "Aborting rebase…") { try await $0.abortRebase() } }
    @objc private func cancelCurrentOperation() { task?.cancel() }
    @objc private func editTodo() {
        guard let panel else { return }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let currentTodo = try await source.loadRebaseTodoText()
                guard let edited = await MutationDialogs.editNativeRebaseTodoRequest(todo: currentTodo, window: panel) else {
                    task = nil
                    return
                }
                rebaseState = try await source.editRebaseTodoText(edited)
                table.reloadData(); status.stringValue = "Rebase todo updated."
            } catch { status.stringValue = error.localizedDescription; await showError(error, title: "Edit rebase todo failed") }
            task = nil
        }
    }
    @objc private func resolveConflicts() {
        guard let panel else { return }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            if let snapshot = await WorkflowManagementDialogs.resolveConflicts(source: source, window: panel) { latestSnapshot = snapshot }
            task = nil; reload()
        }
    }
    @objc private func openCommit() {
        guard let panel, commitWindowController == nil else { return }
        commitWindowController = CommitWorkflowDialog.present(
            source: source, initialMode: .normal, head: latestSnapshot?.commits.first(where: \.isHEAD), draft: nil, owner: panel,
            onSnapshot: { [weak self] snapshot, _ in self?.latestSnapshot = snapshot; self?.reload() },
            onClose: { [weak self] in self?.commitWindowController = nil }
        )
    }
    @objc private func close() { finish(latestSnapshot) }
    func windowWillClose(_ notification: Notification) { finish(latestSnapshot) }
    private func showError(_ error: Error, title: String) async {
        guard let panel else { return }
        await MutationDialogs.showError(error, title: title, window: panel)
    }
    private func finish(_ snapshot: RepositorySnapshot?) {
        guard !didClose else { return }; didClose = true; task?.cancel(); commitWindowController?.close(); onClose?(snapshot)
    }
}

@MainActor
private final class ConflictResolverViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    weak var panel: NSPanel?
    var onClose: ((ConflictResolutionResult) -> Void)?
    private let source: any RepositoryMutatingDataSource
    private let table = NSTableView()
    private let descriptionLabel = NSTextField(labelWithString: "Select a file")
    private let status = NSTextField(labelWithString: "Scanning merge conflicts…")
    private let mergeToolButton = NSButton(title: "Open in mergetool", target: nil, action: nil)
    private let continueButton = NSButton(title: "Continue", target: nil, action: nil)
    private let skipButton = NSButton(title: "Skip", target: nil, action: nil)
    private let abortButton = NSButton(title: "Abort", target: nil, action: nil)
    private var state: RepositoryMutationState?
    private var mergeToolConfiguration: RepositoryMergeToolConfiguration?
    private var mergeInProgress = false
    private var paths: [String] = []
    private var latestSnapshot: RepositorySnapshot?
    private var commitWindowController: NSWindowController?
    private var task: Task<Void, Never>?
    private var didClose = false
    private var sequencerAction = ConflictSequencerAction.none

    init(source: any RepositoryMutatingDataSource) { self.source = source; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }
    deinit { task?.cancel() }

    override func loadView() {
        let root = NSView()
        let title = NSTextField(labelWithString: "Unresolved merge conflicts")
        title.font = .boldSystemFont(ofSize: 15)
        let column = NSTableColumn(identifier: .init("File")); column.title = "File"; column.width = 500
        table.addTableColumn(column)
        table.rowHeight = 22
        table.allowsMultipleSelection = true
        table.delegate = self
        table.dataSource = self
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        mergeToolButton.target = self; mergeToolButton.action = #selector(openMergeTool); mergeToolButton.isEnabled = false
        let solved = NSButton(title: "Mark conflict as solved", target: self, action: #selector(markSolved))
        let rescan = NSButton(title: "Rescan merge conflicts", target: self, action: #selector(rescan))
        continueButton.target = self; continueButton.action = #selector(continueOperation)
        skipButton.target = self; skipButton.action = #selector(skipOperation)
        abortButton.target = self; abortButton.action = #selector(abortOperation)
        let close = NSButton(title: "Close", target: self, action: #selector(close)); close.keyEquivalent = "\u{1b}"
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [mergeToolButton, solved, rescan, spacer, continueButton, skipButton, abortButton, close])
        buttons.orientation = .horizontal; buttons.spacing = 6
        let stack = NSStackView(views: [title, scroll, descriptionLabel, status, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8; stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 10), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 230), buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        view = root
        reloadState()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { paths.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView(); let label = NSTextField(labelWithString: paths[row]); label.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        descriptionLabel.stringValue = table.selectedRow >= 0 ? paths[table.selectedRow] : "Select a file"
        updateMergeToolButton()
    }
    @objc private func rescan() { reloadState() }
    private func reloadState() {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                async let loadedState = source.loadMutationState()
                async let snapshot = source.loadSnapshot()
                async let configuredMergeTool = source.loadMergeToolConfiguration()
                let (state, refreshed, mergeTool) = try await (loadedState, snapshot, configuredMergeTool)
                var pullState: RepositoryPullState?
                if let pullSource = source as? any RepositoryPullingDataSource {
                    pullState = try? await pullSource.loadPullState()
                }
                self.state = state
                mergeToolConfiguration = mergeTool
                mergeInProgress = pullState?.mergeInProgress ?? false
                let selectedPaths = Set(self.table.selectedRowIndexes.compactMap {
                    $0 < self.paths.count ? self.paths[$0] : nil
                })
                latestSnapshot = refreshed; paths = state.conflictedPaths; table.reloadData()
                let restoredSelection = IndexSet(self.paths.indices.filter {
                    selectedPaths.contains(self.paths[$0])
                })
                if !restoredSelection.isEmpty {
                    table.selectRowIndexes(restoredSelection, byExtendingSelection: false)
                } else if !paths.isEmpty {
                    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                }
                status.stringValue = paths.isEmpty ? "No unresolved conflicts." : "\(paths.count) unresolved conflict(s)."
                continueButton.isHidden = !(state.rebaseInProgress || state.cherryPickInProgress || mergeInProgress)
                continueButton.title = mergeInProgress ? "Commit merge…" : "Continue"
                skipButton.isHidden = !state.rebaseInProgress
                abortButton.isHidden = !(state.rebaseInProgress || state.cherryPickInProgress || mergeInProgress)
                continueButton.isEnabled = paths.isEmpty
                updateMergeToolButton()
            } catch { status.stringValue = error.localizedDescription }
        }
    }
    private func updateMergeToolButton() {
        let selectedCount = table.selectedRowIndexes.filter { $0 < paths.count }.count
        mergeToolButton.isEnabled = selectedCount > 0 && mergeToolConfiguration != nil
        if let mergeToolConfiguration {
            mergeToolButton.title = "Open in \(mergeToolConfiguration.name)"
            mergeToolButton.toolTip = "Open the selected conflict in \(mergeToolConfiguration.name)"
        } else {
            mergeToolButton.title = "Open in mergetool"
            mergeToolButton.toolTip = "Configure merge.guitool or merge.tool in Git settings"
        }
    }
    @objc private func openMergeTool() {
        let selected = table.selectedRowIndexes.compactMap { $0 < paths.count ? paths[$0] : nil }
        guard !selected.isEmpty else { status.stringValue = "Select at least one conflict."; return }
        status.stringValue = "Opening \(mergeToolConfiguration?.name ?? "merge tool")…"
        run { try await $0.runMergeTool(paths: selected) }
    }
    @objc private func markSolved() {
        let selected = table.selectedRowIndexes.map { paths[$0] }
        guard !selected.isEmpty else { status.stringValue = "Select at least one conflict."; return }
        run { try await $0.stage(paths: selected) }
    }
    @objc private func continueOperation() {
        guard let state else { return }
        if state.rebaseInProgress { run(sequencerAction: .continued) { try await $0.continueRebase() } }
        else if state.cherryPickInProgress { run(sequencerAction: .continued) { try await $0.continueCherryPick() } }
        else if mergeInProgress { presentMergeCommit() }
    }
    @objc private func skipOperation() { run { try await $0.skipRebase() } }
    @objc private func abortOperation() {
        guard let state, let panel else { return }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            if state.rebaseInProgress {
                await execute(sequencerAction: .aborted) { try await $0.abortRebase() }
            } else if state.cherryPickInProgress {
                guard await MutationDialogs.confirmAbortCherryPick(window: panel) else { return }
                await execute(sequencerAction: .aborted) { try await $0.abortCherryPick() }
            } else if mergeInProgress {
                guard await MutationDialogs.confirmAbortMerge(window: panel) else { return }
                await execute(sequencerAction: .aborted) { try await $0.abortMerge() }
            }
        }
    }
    private func presentMergeCommit() {
        guard paths.isEmpty,
              commitWindowController == nil,
              let panel else { return }
        let head = latestSnapshot?.commits.first(where: \.isHEAD)
        commitWindowController = CommitWorkflowDialog.present(
            source: source,
            initialMode: .normal,
            head: head,
            draft: nil,
            owner: panel,
            onSnapshot: { [weak self] snapshot, _ in
                guard let self else { return }
                latestSnapshot = snapshot
                finish(snapshot)
            },
            onClose: { [weak self] in
            guard let self else { return }
            commitWindowController = nil
        })
    }
    private func commitMerge(_ request: RepositoryCommitRequest) {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                status.stringValue = "Committing merge…"
                let result = try await source.commit(request)
                latestSnapshot = result.snapshot
                finish(result.snapshot)
            } catch {
                status.stringValue = error.localizedDescription
                reloadState()
            }
        }
    }
    private func run(
        sequencerAction: ConflictSequencerAction = .none,
        _ operation: @escaping @Sendable (any RepositoryMutatingDataSource) async throws -> RepositoryMutationResult
    ) {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            await execute(sequencerAction: sequencerAction, operation)
        }
    }
    private func execute(
        sequencerAction: ConflictSequencerAction = .none,
        _ operation: @escaping @Sendable (any RepositoryMutatingDataSource) async throws -> RepositoryMutationResult
    ) async {
        do {
            status.stringValue = "Updating repository…"
            let result = try await operation(source)
            latestSnapshot = result.snapshot
            if sequencerAction != .none { self.sequencerAction = sequencerAction }
            switch result.outcome {
            case .completed: status.stringValue = result.message
            case .conflicts(let values): status.stringValue = "\(values.count) conflicted path(s) remain."
            case .paused(let reason): status.stringValue = reason
            }
            reloadState()
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func close() { finish(latestSnapshot) }
    func windowWillClose(_ notification: Notification) { finish(latestSnapshot) }
    private func finish(_ value: RepositorySnapshot?) {
        guard !didClose else { return }
        didClose = true
        commitWindowController?.close()
        onClose?(ConflictResolutionResult(snapshot: value, sequencerAction: sequencerAction))
    }
}
