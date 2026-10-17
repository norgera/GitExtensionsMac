import GitExtensionsCore
import GitCommands
import AppKit

enum ConflictSequencerAction: Equatable, Sendable {
    case none
    case continued
    case aborted
}

struct ConflictResolutionResult: Sendable {
    let repositoryChanged: Bool
    let sequencerAction: ConflictSequencerAction
}

@MainActor
enum WorkflowManagementDialogs {
    static func manageStashes(
        source: any RepositoryStashWorkflowDataSource,
        context: RepositoryStashContext,
        window: NSWindow,
        manageStashes: Bool = true,
        initialStash: String? = nil,
        openWithDifftool: (@MainActor (Commit, ChangedFile) -> Void)? = nil,
        scriptHooks: ApplicationScriptHooks? = nil
    ) async -> StashDialogResult {
        await StashDialog.present(
            source: source,
            context: context,
            manageStashes: manageStashes,
            initialStash: initialStash,
            owner: window,
            openWithDifftool: openWithDifftool,
            resolveConflicts: { stashWindow in
                await resolveConflicts(source: source, window: stashWindow, scriptHooks: scriptHooks)
            }
        )
    }

    static func resolveConflicts(
        source: any RepositoryConflictResolutionDataSource,
        window: NSWindow,
        offerCommit: Bool? = nil,
        scriptHooks: ApplicationScriptHooks? = nil
    ) async -> Bool {
        await presentConflictResolver(
            source: source,
            window: window,
            offerMergeCommit: offerCommit, scriptHooks: scriptHooks
        ).repositoryChanged
    }

    static func resolveCherryPickConflicts(
        source: any RepositoryCherryPickDataSource,
        window: NSWindow,
        scriptHooks: ApplicationScriptHooks? = nil
    ) async -> ConflictResolutionResult {
        await presentConflictResolver(source: source, window: window, scriptHooks: scriptHooks)
    }

    static func resolveRevertConflicts(
        source: any RepositoryRevertingDataSource,
        window: NSWindow,
        scriptHooks: ApplicationScriptHooks? = nil
    ) async -> ConflictResolutionResult {
        await presentConflictResolver(source: source, window: window, scriptHooks: scriptHooks)
    }

    static func resolveMergeConflicts(
        source: any RepositoryMergingDataSource,
        offerCommit: Bool,
        window: NSWindow,
        scriptHooks: ApplicationScriptHooks? = nil
    ) async -> ConflictResolutionResult {
        await presentConflictResolver(
            source: source,
            window: window,
            offerMergeCommit: offerCommit, scriptHooks: scriptHooks
        )
    }

    private static func presentConflictResolver(
        source: any RepositoryConflictResolutionDataSource,
        window: NSWindow,
        offerMergeCommit: Bool? = nil,
        scriptHooks: ApplicationScriptHooks? = nil
    ) async -> ConflictResolutionResult {
        let controller = ConflictResolverViewController(
            source: source,
            offerMergeCommit: offerMergeCommit
        )
        controller.scriptHooks = scriptHooks
        controller.fileHistory = ConflictResolverFileHistory.handler(for: source)
        let panel = NSWindow(contentViewController: controller)
        panel.title = "Resolve merge conflicts"
        panel.styleMask = [.titled, .closable, .resizable]
        panel.setContentSize(NSSize(width: 619, height: 392))
        panel.contentMinSize = NSSize(width: 450, height: 299)
        panel.isReleasedWhenClosed = false
        controller.panel = panel
        panel.delegate = controller
        return await withCheckedContinuation { continuation in
            controller.onClose = { result in
                NSApp.stopModal()
                panel.orderOut(nil)
                continuation.resume(returning: result)
            }
            Task { @MainActor in await OwnedModalWindow.runAsync(panel, owner: window) }
        }
    }

    static func manageRebase(
        source: any RepositoryRebaseDataSource,
        window: NSWindow,
        scriptHooks: ApplicationScriptHooks? = nil
    ) async -> Bool {
        let controller = RebaseManagerViewController(source: source)
        controller.scriptHooks = scriptHooks
        let panel = NSPanel(contentViewController: controller)
        panel.title = "Rebase"
        panel.styleMask = [.titled, .closable, .resizable]
        panel.setContentSize(NSSize(width: 1034, height: 461))
        panel.minSize = NSSize(width: 1050, height: 500)
        panel.setFrameAutosaveName("GitExtensionsMac.Rebase")
        controller.panel = panel
        panel.delegate = controller
        return await withCheckedContinuation { continuation in
            controller.onClose = { changed in
                window.endSheet(panel)
                continuation.resume(returning: changed)
            }
            window.beginSheet(panel)
        }
    }

    static func startRebase(
        source: any RepositoryRebaseDataSource,
        target: Commit?,
        interactive: Bool,
        initialActions: [ObjectID: RepositoryRebaseTodoAction],
        advancedFrom: String?,
        showAdvancedOptions: Bool,
        window: NSWindow,
        initialOnto: String? = nil,
        startImmediately: Bool? = nil,
        scriptHooks: ApplicationScriptHooks? = nil
    ) async -> Bool {
        let controller = RebaseManagerViewController(
            source: source,
            target: target,
            interactive: interactive,
            initialActions: initialActions,
            advancedFrom: advancedFrom,
            showAdvancedOptions: showAdvancedOptions,
            initialOnto: initialOnto,
            startImmediately: startImmediately
        )
        controller.scriptHooks = scriptHooks
        let panel = NSPanel(contentViewController: controller)
        panel.title = "Rebase"
        panel.styleMask = [.titled, .closable, .resizable]
        panel.setContentSize(NSSize(width: 1034, height: 461))
        panel.minSize = NSSize(width: 1050, height: 500)
        panel.setFrameAutosaveName("GitExtensionsMac.Rebase")
        controller.panel = panel; panel.delegate = controller
        return await withCheckedContinuation { continuation in
            controller.onClose = { changed in window.endSheet(panel); continuation.resume(returning: changed) }
            window.beginSheet(panel)
        }
    }
}

@MainActor
final class RebaseManagerViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    var scriptHooks: ApplicationScriptHooks?
    weak var panel: NSPanel?
    var onClose: ((Bool) -> Void)?
    private let source: any RepositoryRebaseDataSource
    private let target: Commit?
    private let initialOnto: String?
    private let startsImmediately: Bool
    private let initiallyInteractive: Bool
    private let initialActions: [ObjectID: RepositoryRebaseTodoAction]
    private let advancedFrom: String?
    private let showsAdvancedOptions: Bool
    private let table = NSTableView()
    private let currentBranch = NSTextField(labelWithString: "Current branch:")
    private let rebaseExplanation = NSTextField(labelWithString: "Rebase current branch on top of another branch")
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
    let specificRangeOption = NSButton(checkboxWithTitle: "Specific range", target: nil, action: nil)
    let fromField = NSTextField(string: "")
    let chooseFromButton = NSButton(title: "…", target: nil, action: nil)
    private let toField = NSComboBox()
    private let startButton = NSButton(title: "Rebase", target: nil, action: nil)
    private let helpPanel = NSView()
    private let helpToggle = NSButton(title: "", target: nil, action: nil)
    private let helpImage = NSImageView()
    private var helpWidthConstraint: NSLayoutConstraint?
    private var helpExpanded = AppSettingsStore.shared.rebasePreferences.helpExpanded
    private var rebaseState = RepositoryRebaseState(inProgress: false, hasConflicts: false, currentBranch: nil, currentCommitID: nil, patches: [], canEditTodo: false, hasAutoStash: false)
    private var rebaseConfiguration: RepositoryRebaseConfiguration?
    private var repositoryChanged = false
    private var task: Task<Void, Never>?
    private var commitWindowController: NSWindowController?
    private var skippedCommitIDs = Set<String>()
    private var didClose = false
    private var didAutoStart = false

    init(
        source: any RepositoryRebaseDataSource,
        target: Commit? = nil,
        interactive: Bool = false,
        initialActions: [ObjectID: RepositoryRebaseTodoAction] = [:],
        advancedFrom: String? = nil,
        showAdvancedOptions: Bool = false,
        initialOnto: String? = nil,
        startImmediately: Bool? = nil
    ) {
        self.source = source; self.target = target; initiallyInteractive = interactive
        self.initialOnto = initialOnto
        self.startsImmediately = startImmediately ?? !showAdvancedOptions
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
        heading.font = AppSettingsStore.shared.applicationFont(size: 13, weight: .bold)
        for (id, title, width) in [
            ("Status", "Status", 70.0), ("Action", "Action", 72.0), ("Subject", "Subject", 330.0),
            ("Author", "Author", 140.0), ("Date", "Date", 110.0), ("Hash", "Commit hash", 55.0)
        ] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width
            column.resizingMask = id == "Subject" ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            if id == "Hash" { column.width = ceil(column.headerCell.cellSize.width + 8) }
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
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
        let content = NSStackView(views: [rebaseExplanation, currentBranch, idleOptions, heading, scroll, secondary, footer])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 8
        configureHelpPanel()
        helpPanel.isHidden = AppSettingsStore.shared.preferences.dontShowHelpImages
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
        targetField.stringValue = initialOnto ?? target?.objectID?.string ?? ""
        targetField.completes = true; targetField.numberOfVisibleItems = 12
        targetField.widthAnchor.constraint(equalToConstant: 270).isActive = true
        interactiveOption.state = initiallyInteractive ? .on : .off
        autoStashOption.state = AppSettingsStore.shared.preferences.autoStashDuringRebase ? .on : .off
        specificRangeOption.state = advancedFrom == nil ? .off : .on
        fromField.stringValue = advancedFrom ?? ""
        fromField.placeholderString = "From (exclusive)"; fromField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        chooseFromButton.bezelStyle = .texturedRounded; chooseFromButton.toolTip = "Choose the lower revision"
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
            attributes: [.font: AppSettingsStore.shared.applicationFont(size: 12), .foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
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
        fromField.isEnabled = range; chooseFromButton.isEnabled = range; toField.isEnabled = range
    }

    @objc private func useInitialFromRevision() {
        guard let comparison = source as? any RepositoryRevisionComparingDataSource, let owner = panel else { return }
        let from = fromField.stringValue, onto = targetField.stringValue
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let choice = try await comparison.rebaseCommitChoice(onto: onto, from: from)
                if let selected = await RevisionCommitChooser.choose(source: comparison, preselect: choice.preselect, rebaseChoice: choice, owner: owner) {
                    acceptFromRevision(selected)
                }
            } catch { await MutationDialogs.showError(error, title: "Choose commit", window: owner) }
        }
    }

    func acceptFromRevision(_ revision: Commit?) {
        guard let revision else { return }
        fromField.stringValue = revision.objectID?.shortString ?? revision.id.description
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rebaseState.patches.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let patch = rebaseState.patches[row]
        let value: String = switch tableColumn?.identifier.rawValue {
        case "Status": skippedCommitIDs.contains(patch.revisionToken) && patch.status == .applied ? RepositoryRebasePatchStatus.skipped.rawValue : patch.status.rawValue
        case "Action": patch.action
        case "Author": patch.author
        case "Date": patch.date
        case "Hash": String(patch.revisionToken.prefix(10))
        default: patch.subject
        }
        let cell = NSTableCellView(); let label = NSTextField(labelWithString: value)
        label.font = AppSettingsStore.shared.applicationFont(size: 12); label.lineBreakMode = .byTruncatingTail; label.translatesAutoresizingMaskIntoConstraints = false
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
            async let context = source.loadRepositoryState().rebaseContext
            let (state, refreshedContext) = try await (loadedState, context)
            if rebaseConfiguration == nil { rebaseConfiguration = try await source.loadRebaseConfiguration() }
            apply(state: state, context: refreshedContext)
        } catch is CancellationError {
            status.stringValue = "Rebase operation cancelled."
        } catch {
            status.stringValue = error.localizedDescription
        }
    }

    private func apply(state: RepositoryRebaseState, context: RepositoryRebaseContext) {
        rebaseState = state
        currentBranch.stringValue = "Current branch: \(state.currentBranch ?? "(detached HEAD)")"
        populateReferences(from: context)
        if let configuration = rebaseConfiguration {
            if autosquashOption.state == .off { autosquashOption.state = configuration.autoSquash ? .on : .off }
            if updateRefsOption.state == .off { updateRefsOption.state = configuration.updateRefs ? .on : .off }
            updateRefsOption.isHidden = !configuration.supportsUpdateRefs
            autoStashOption.isEnabled = configuration.isDirty && !state.inProgress
        }
        let active = state.inProgress
        idleOptions.isHidden = active
        rebaseExplanation.isHidden = active
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
        AppKitFactory.autosizeColumns(table, ["Status", "Action", "Date"], includeHeader: true)
        table.sizeToFit()
        if let index = state.patches.firstIndex(where: { $0.status == .applying }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
        }
        optionChanged()
        if !active, target == nil, startsImmediately {
            finish(repositoryChanged)
        } else if !active, startsImmediately, !showsAdvancedOptions, !didAutoStart {
            didAutoStart = true
            DispatchQueue.main.async { [weak self] in self?.startRebase() }
        }
    }

    private func populateReferences(from context: RepositoryRebaseContext) {
        let refs = Array(Set(context.branches.map(\.name) + context.tags.map(\.name))).sorted()
        let targetValue = targetField.stringValue
        let toValue = toField.stringValue
        targetField.removeAllItems(); targetField.addItems(withObjectValues: refs)
        toField.removeAllItems(); toField.addItems(withObjectValues: context.branches.filter { !$0.isRemote }.map(\.name).sorted())
        targetField.stringValue = targetValue
        toField.stringValue = toValue.isEmpty ? (context.branches.first(where: \.isCurrent)?.name ?? "HEAD") : toValue
    }

    private func execute(
        status runningStatus: String,
        operation: @escaping @Sendable (any RepositoryRebaseDataSource) async throws -> RepositoryMutationResult
    ) {
        guard task == nil else { return }
        setBusy(true, status: runningStatus)
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await operation(source)
                repositoryChanged = true
                if case .completed = result.outcome, !(try await source.loadRebaseState()).inProgress {
                    if result.message.localizedCaseInsensitiveContains("up to date"), let panel {
                        await MutationDialogs.showInformation(result.message, title: "Rebase", window: panel)
                    }
                    task = nil; setBusy(false, status: result.message); finish(true)
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
                            finish(repositoryChanged)
                        }
                        return
                    }
                    execute(status: "Rebasing interactively…") { try await $0.interactiveRebase(request) }
                } catch is CancellationError {
                    task = nil; setBusy(false, status: "Rebase cancelled.")
                    if !showsAdvancedOptions { finish(repositoryChanged) }
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
        if let applying = rebaseState.patches.first(where: { $0.status == .applying }), !applying.revisionToken.isEmpty {
            skippedCommitIDs.insert(applying.revisionToken)
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
            if await WorkflowManagementDialogs.resolveConflicts(source: source, window: panel, scriptHooks: scriptHooks) { repositoryChanged = true }
            task = nil; reload()
        }
    }
    @objc private func openCommit() {
        guard let panel,
              commitWindowController == nil,
              let commitSource = source as? any RepositoryCommitWorkflowDataSource
        else { return }
        commitWindowController = CommitWorkflowDialog.present(
            source: commitSource, initialMode: .normal, head: nil, draft: nil, owner: panel,
            onRepositoryChanged: { [weak self] _ in self?.repositoryChanged = true; self?.reload() },
            onClose: { [weak self] in self?.commitWindowController = nil }
        )
    }
    @objc private func close() { finish(repositoryChanged) }
    func windowWillClose(_ notification: Notification) { finish(repositoryChanged) }
    private func showError(_ error: Error, title: String) async {
        guard let panel else { return }
        await MutationDialogs.showError(error, title: title, window: panel)
    }
    private func finish(_ changed: Bool) {
        guard !didClose else { return }; didClose = true; task?.cancel(); commitWindowController?.close(); onClose?(changed)
    }
}

private final class ConflictTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onShortcut: ((String) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self,
           let command = ApplicationHotkeys.shared.matching(event, category: "Conflict resolver"),
           onShortcut?(command) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if let command = ApplicationHotkeys.shared.matching(event, category: "Conflict resolver"),
           onShortcut?(command) == true { return }
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?()
        } else {
            super.keyDown(with: event)
        }
    }
}

struct ConflictResolverActionState: Equatable {
    let hasSelection: Bool
    let hasSingleSelection: Bool
    let hasConflicts: Bool
    let hasMergeTool: Bool
    let hasOnlySubmodules: Bool
    let hasLocalVersion: Bool
    let hasBaseVersion: Bool
    let hasRemoteVersion: Bool

    init(
        selectedConflicts: [RepositoryConflict],
        conflictCount: Int,
        mergeToolConfiguration: RepositoryMergeToolConfiguration?
    ) {
        let single = selectedConflicts.count == 1 ? selectedConflicts[0] : nil
        hasSelection = !selectedConflicts.isEmpty
        hasSingleSelection = single != nil
        hasConflicts = conflictCount > 0
        hasMergeTool = mergeToolConfiguration != nil
        hasOnlySubmodules = !selectedConflicts.isEmpty && selectedConflicts.allSatisfy(\.isSubmodule)
        hasLocalVersion = single?.local != nil
        hasBaseVersion = single?.base != nil
        hasRemoteVersion = single?.remote != nil
    }

    var canRunSelectedMergeTool: Bool { hasSelection && (hasMergeTool || hasOnlySubmodules) }
    var canRunAllMergeTool: Bool { hasConflicts && hasMergeTool }
    var canResolveSelection: Bool { hasSelection }
    var canResolveAll: Bool { hasConflicts }
    var canInspectWorkingFile: Bool { hasSingleSelection }

    func canShowFileHistory(available: Bool) -> Bool { hasSingleSelection && available }
}

@MainActor
enum ConflictResolverFileHistory {
    typealias Handler = @MainActor (String, NSWindow) -> NSWindowController?

    static func handler(for source: any RepositoryConflictResolutionDataSource) -> Handler? {
        guard GitUICommands.commands(for: source as AnyObject) != nil else { return nil }
        return { [weak source = source as AnyObject] path, window in
            guard let source, let commands = GitUICommands.commands(for: source) else { return nil }
            return commands.startFileHistory(file: path, owner: window)
        }
    }
}

@MainActor
final class ConflictResolverViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSMenuDelegate {
    var scriptHooks: ApplicationScriptHooks?
    var fileHistory: ConflictResolverFileHistory.Handler?
    weak var panel: NSWindow?
    var onClose: ((ConflictResolutionResult) -> Void)?
    private let source: any RepositoryConflictResolutionDataSource
    private var didShowMergeToolWarning = false
    private var pendingAlert: NSAlert?
    private let table = ConflictTableView()
    var conflictTable: NSTableView { table }
    private let descriptionLabel = NSTextField(wrappingLabelWithString: "Select file")
    private let localTitle = NSTextField(labelWithString: "Local/current (ours)")
    private let baseTitle = NSTextField(labelWithString: "Base")
    private let remoteTitle = NSTextField(labelWithString: "Remote/incoming (theirs)")
    private let localLabel = NSTextField(labelWithString: "—")
    private let baseLabel = NSTextField(labelWithString: "—")
    private let remoteLabel = NSTextField(labelWithString: "—")
    private let contentController = RevisionFileContentViewController()
    private let status = NSTextField(labelWithString: "Scanning merge conflicts…")
    private let progressIndicator = NSProgressIndicator()
    private let mergeButton = NSButton(title: "Merge", target: nil, action: nil)
    private let mergeToolButton = NSButton(title: "Open in mergetool", target: nil, action: nil)
    private let allMergeToolButton = NSButton(title: "Start mergetool", target: nil, action: nil)
    private let toolMenuButton = NSPopUpButton()
    private let chooseLocalButton = NSButton(title: "Choose local", target: nil, action: nil)
    private let chooseRemoteButton = NSButton(title: "Choose remote", target: nil, action: nil)
    private let chooseBaseButton = NSButton(title: "Choose base", target: nil, action: nil)
    private let solvedButton = NSButton(title: "Mark conflict as solved", target: nil, action: nil)
    private let solvedAllButton = NSButton(title: "Mark all as solved", target: nil, action: nil)
    private let continueButton = NSButton(title: "Continue", target: nil, action: nil)
    private let skipButton = NSButton(title: "Skip", target: nil, action: nil)
    private let abortButton = NSButton(title: "Abort", target: nil, action: nil)
    private var state: RepositoryMutationState?
    private var mergeToolConfiguration: RepositoryMergeToolConfiguration?
    private var availableMergeTools: [String] = []
    private var mergeInProgress = false
    private(set) var conflicts: [RepositoryConflict] = []
    private var paths: [String] = []
    private var repositoryChanged = false
    private var commitWindowController: NSWindowController?
    private var task: Task<Void, Never>?
    private var contentTask: Task<Void, Never>?
    private var didClose = false
    private var sequencerAction = ConflictSequencerAction.none
    private let offerMergeCommit: Bool?
    private var hadMergeConflicts = false
    private var didOfferMergeCompletion = false
    private var selectedSide: RepositoryConflictSide = .local
    private var sideContent: [RepositoryConflictSide: RepositoryFileContent] = [:]

    init(
        source: any RepositoryConflictResolutionDataSource,
        offerMergeCommit: Bool? = nil
    ) {
        self.source = source
        self.offerMergeCommit = offerMergeCommit
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    deinit { task?.cancel(); contentTask?.cancel() }

    static let helpURL = URL(string: ApplicationShellLinks.documentationURL.absoluteString + "modify_history#handle-merge-conflicts")!

    override func loadView() {
        let root = NSView()
        let title = NSTextField(labelWithString: "Unresolved merge conflicts")
        let fileColumn = NSTableColumn(identifier: .init("File"))
        fileColumn.title = "Filename"
        fileColumn.width = 420
        table.addTableColumn(fileColumn)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.rowHeight = 22
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = false
        table.delegate = self
        table.dataSource = self
        table.doubleAction = #selector(openMergeTool)
        table.target = self
        table.onReturn = { [weak self] in self?.openMergeTool() }
        table.onShortcut = { [weak self] command in
            guard let self else { return false }
            switch command {
            case "conflict.base": self.chooseBase()
            case "conflict.local": self.chooseLocal()
            case "conflict.remote": self.chooseRemote()
            case "conflict.merge": self.openMergeTool()
            case "conflict.rescan": self.rescan()
            default: return false
            }
            return true
        }
        let contextMenu = NSMenu()
        contextMenu.autoenablesItems = false
        contextMenu.delegate = self
        table.menu = contextMenu
        mergeButton.menu = contextMenu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        mergeButton.target = self
        mergeButton.action = #selector(openMergeTool)
        mergeButton.image = AppKitFactory.resourceImage("SelectBranch", accessibilityDescription: "Merge")
        mergeButton.imagePosition = .imageLeading
        mergeButton.keyEquivalent = "\r"
        mergeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        mergeToolButton.target = self
        mergeToolButton.action = #selector(openMergeTool)
        mergeToolButton.isEnabled = false
        allMergeToolButton.target = self
        allMergeToolButton.action = #selector(openAllInMergeTool)
        toolMenuButton.target = self
        toolMenuButton.action = #selector(openSelectedConfiguredTool(_:))
        let rescan = NSButton(title: "Rescan merge conflicts", target: self, action: #selector(rescan))
        rescan.keyEquivalent = "r"
        rescan.keyEquivalentModifierMask = [.command]
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetRepository))
        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = false
        progressIndicator.isHidden = true
        let listButtons = NSStackView(views: [mergeToolButton, allMergeToolButton, rescan, reset, progressIndicator])
        listButtons.orientation = .vertical
        listButtons.alignment = .leading
        listButtons.spacing = 6
        for button in [mergeToolButton, allMergeToolButton, rescan, reset] {
            button.widthAnchor.constraint(equalTo: listButtons.widthAnchor).isActive = true
        }
        progressIndicator.widthAnchor.constraint(equalTo: listButtons.widthAnchor).isActive = true
        for (name, field) in [("Local", localLabel), ("Base", baseLabel), ("Remote", remoteLabel)] {
            field.setAccessibilityIdentifier("ConflictResolver." + name + "File")
        }
        [localLabel, baseLabel, remoteLabel].forEach {
            $0.lineBreakMode = .byTruncatingMiddle
            $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let information = NSImageView(image: AppKitFactory.resourceImage("Information", accessibilityDescription: "Information") ?? NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Information")!)
        information.widthAnchor.constraint(equalToConstant: 16).isActive = true
        information.heightAnchor.constraint(equalToConstant: 16).isActive = true
        descriptionLabel.maximumNumberOfLines = 0
        descriptionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let descriptionRow = NSStackView(views: [information, descriptionLabel, mergeButton])
        descriptionRow.alignment = .centerY
        descriptionRow.spacing = 6
        mergeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let list = NSStackView(views: [title, scroll, descriptionRow])
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        let listAndTools = NSStackView(views: [list, listButtons])
        listAndTools.orientation = .horizontal
        listAndTools.alignment = .top
        listAndTools.spacing = 8
        let details = NSGridView(views: [[localTitle, localLabel], [baseTitle, baseLabel], [remoteTitle, remoteLabel]])
        details.column(at: 0).xPlacement = .leading
        details.column(at: 0).width = max(localTitle.intrinsicContentSize.width, remoteTitle.intrinsicContentSize.width)
        details.column(at: 1).xPlacement = .fill
        details.setContentHuggingPriority(.required, for: .vertical)
        listAndTools.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        details.columnSpacing = 10
        details.rowSpacing = 6
        let help = NSButton(title: "Help", target: self, action: #selector(openHelp))
        help.isBordered = false
        help.image = AppKitFactory.resourceImage("GotoManual", accessibilityDescription: "Help")
        help.imagePosition = .imageLeading
        help.contentTintColor = .linkColor
        help.toolTip = "Read more about this feature at " + Self.helpURL.absoluteString
        let stack = NSStackView(views: [listAndTools, details, help])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            listAndTools.widthAnchor.constraint(equalTo: stack.widthAnchor),
            list.heightAnchor.constraint(equalTo: listAndTools.heightAnchor),
            scroll.widthAnchor.constraint(equalTo: list.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
            descriptionRow.widthAnchor.constraint(equalTo: list.widthAnchor),
            listButtons.widthAnchor.constraint(equalToConstant: 155),
            details.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        view = root
        reloadState()
    }

    @objc private func openHelp() { NSWorkspace.shared.open(Self.helpURL) }
    func numberOfRows(in tableView: NSTableView) -> Int { paths.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: conflicts[row].path)
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = conflicts[row].path
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        updateSelectionPresentation()
        updateMergeToolButton()
    }
    @objc private func rescan() { reloadState() }
    private func reloadState() {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                async let loadedState = source.loadMutationState()
                async let loadedConflicts = source.loadConflicts()
                async let configuredMergeTool = source.loadMergeToolConfiguration()
                async let tools = source.loadMergeTools()
                let (state, conflictValues, mergeTool, availableTools) = try await (loadedState, loadedConflicts, configuredMergeTool, tools)
                self.state = state
                mergeToolConfiguration = mergeTool
                availableMergeTools = availableTools
                mergeInProgress = state.mergeInProgress
                if mergeInProgress && !state.conflictedPaths.isEmpty {
                    hadMergeConflicts = true
                }
                let selectedPaths = Set(self.table.selectedRowIndexes.compactMap {
                    $0 < self.paths.count ? self.paths[$0] : nil
                })
                let previousRow = max(0, table.selectedRow)
                conflicts = conflictValues
                paths = conflictValues.map(\.path)
                table.reloadData()
                let restoredSelection = IndexSet(self.paths.indices.filter {
                    selectedPaths.contains(self.paths[$0])
                })
                if !restoredSelection.isEmpty {
                    table.selectRowIndexes(restoredSelection, byExtendingSelection: false)
                } else if !paths.isEmpty {
                    table.selectRowIndexes(IndexSet(integer: min(previousRow, paths.count - 1)), byExtendingSelection: false)
                }
                status.stringValue = paths.isEmpty ? "No unresolved conflicts." : "\(paths.count) unresolved conflict(s)."
                continueButton.isHidden = !(state.rebaseInProgress || state.cherryPickInProgress || state.revertInProgress || mergeInProgress)
                continueButton.title = mergeInProgress ? "Commit merge…" : "Continue"
                skipButton.isHidden = !state.rebaseInProgress
                abortButton.isHidden = !(state.rebaseInProgress || state.cherryPickInProgress || state.revertInProgress || mergeInProgress)
                continueButton.isEnabled = paths.isEmpty
                updateMergeToolButton()
                updateToolMenu()
                updateSelectionPresentation()
                if !didShowMergeToolWarning {
                    didShowMergeToolWarning = true
                    if let alert = Self.mergeToolWarning(for: mergeTool) { _ = await present(alert) }
                }
                if mergeInProgress,
                   paths.isEmpty,
                   hadMergeConflicts,
                   offerMergeCommit != nil,
                   !didOfferMergeCompletion {
                    didOfferMergeCompletion = true
                    await offerMergeCompletion()
                }
            } catch { await showMessage(error.localizedDescription, title: "Error", isError: true) }
        }
    }

    private func offerMergeCompletion() async {
        guard let panel, let offerMergeCommit else { return }
        guard offerMergeCommit else {
            finish(repositoryChanged)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Commit"
        alert.informativeText = "All merge conflicts are resolved, you can commit.\nDo you want to commit now?"
        alert.addButton(withTitle: "Commit")
        alert.addButton(withTitle: "Not now")
        if await MutationDialogs.confirmSuppressible(alert, window: panel, suppressedBy: \.dontConfirmCommitAfterConflictsResolved) {
            presentMergeCommit(closeWhenCommitWindowCloses: true)
        } else {
            finish(repositoryChanged)
        }
    }

    private var selectedConflicts: [RepositoryConflict] {
        table.selectedRowIndexes.compactMap { conflicts.indices.contains($0) ? conflicts[$0] : nil }
    }

    private var actionState: ConflictResolverActionState {
        ConflictResolverActionState(
            selectedConflicts: selectedConflicts,
            conflictCount: conflicts.count,
            mergeToolConfiguration: mergeToolConfiguration
        )
    }

    private func conflictKindTitle(_ conflict: RepositoryConflict) -> String {
        if conflict.isSubmodule { return "Submodule" }
        return switch conflict.kind {
        case .bothModified: "Both modified"
        case .bothAdded: "Both added"
        case .deletedLocally: "Deleted locally"
        case .deletedRemotely: "Deleted remotely"
        case .bothDeleted: "Deleted both"
        case .unmerged: "Unmerged"
        }
    }

    private func sideTitle(_ side: RepositoryConflictSide) -> String {
        let rebase = state?.rebaseInProgress == true
        return switch side {
        case .base: "Base"
        case .local: rebase ? "Local/current (theirs)" : "Local/current (ours)"
        case .remote: rebase ? "Remote/incoming (ours)" : "Remote/incoming (theirs)"
        }
    }

    private func versionText(_ version: RepositoryConflictVersion?, conflict: RepositoryConflict, missing: String = "deleted") -> String {
        let name = version?.path ?? missing
        guard conflict.isSubmodule else { return name }
        return name + "@" + (version?.objectID.shortString ?? "deleted")
    }

    private func updateSelectionPresentation() {
        sideContent.removeAll()
        let values = selectedConflicts
        let single = values.count == 1 ? values[0] : nil
        if let conflict = single {
            descriptionLabel.stringValue = RepositoryConflictDescription.text(for: conflict.kind, rebase: state?.rebaseInProgress == true)
            localTitle.stringValue = sideTitle(.local)
            remoteTitle.stringValue = sideTitle(.remote)
            localLabel.stringValue = versionText(conflict.local, conflict: conflict)
            baseLabel.stringValue = versionText(conflict.base, conflict: conflict, missing: "no base")
            remoteLabel.stringValue = versionText(conflict.remote, conflict: conflict)
        } else {
            localLabel.stringValue = ""
            baseLabel.stringValue = ""
            remoteLabel.stringValue = ""
        }
        chooseLocalButton.isEnabled = !values.isEmpty
        chooseRemoteButton.isEnabled = !values.isEmpty
        chooseBaseButton.isEnabled = !values.isEmpty
        solvedButton.isEnabled = !values.isEmpty
        solvedAllButton.isEnabled = !paths.isEmpty
    }

    private func updateToolMenu() {
        toolMenuButton.removeAllItems()
        toolMenuButton.addItem(withTitle: "Configured tools…")
        toolMenuButton.item(at: 0)?.isEnabled = false
        for tool in mergeToolConfiguration?.availableTools ?? [] {
            toolMenuButton.addItem(withTitle: tool)
            toolMenuButton.lastItem?.representedObject = tool
        }
        toolMenuButton.isEnabled = toolMenuButton.numberOfItems > 1 && !selectedConflicts.isEmpty
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let actions = actionState
        guard actions.hasSelection else { return }
        let single = actions.hasSingleSelection
        addMenuItem("Open in \(mergeToolConfiguration?.name ?? "mergetool")", action: #selector(openMergeTool), enabled: single && mergeToolConfiguration?.hasExtrasConfigured == true, to: menu)
        let custom = addMenuItem("Open in mergetool", action: #selector(openCustomMergeTool(_:)), enabled: single, to: menu)
        let tools = availableMergeTools
        if tools.count > 1 {
            let toolMenu = NSMenu()
            toolMenu.autoenablesItems = false
            for (index, tool) in tools.enumerated() {
                let item = addMenuItem(tool, action: #selector(openCustomMergeTool(_:)), enabled: single, to: toolMenu)
                item.representedObject = tool
                if index == 0 { item.attributedTitle = NSAttributedString(string: tool, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]) }
            }
            custom.submenu = toolMenu
        }
        addMenuItem("Mark conflict as solved", action: #selector(markSolved), enabled: actions.canResolveSelection, to: menu)
        menu.addItem(.separator())
        let local = addMenuItem("Choose " + sideTitle(.local).prefix(1).lowercased() + sideTitle(.local).dropFirst(), action: #selector(chooseLocal), enabled: true, to: menu)
        let remote = addMenuItem("Choose " + sideTitle(.remote).prefix(1).lowercased() + sideTitle(.remote).dropFirst(), action: #selector(chooseRemote), enabled: true, to: menu)
        let base = addMenuItem("Choose base", action: #selector(chooseBase), enabled: true, to: menu)
        AppKitFactory.setMenuShortcut("conflict.local", for: local)
        AppKitFactory.setMenuShortcut("conflict.remote", for: remote)
        AppKitFactory.setMenuShortcut("conflict.base", for: base)
        menu.addItem(.separator())
        addMenuItem("Open local with", action: #selector(openLocalVersion), enabled: actions.hasLocalVersion, to: menu)
        addMenuItem("Open remote with", action: #selector(openRemoteVersion), enabled: actions.hasRemoteVersion, to: menu)
        addMenuItem("Open base with", action: #selector(openBaseVersion), enabled: actions.hasBaseVersion, to: menu)
        menu.addItem(.separator())
        addMenuItem("Save local as…", action: #selector(saveLocalVersion), enabled: actions.hasLocalVersion, to: menu)
        addMenuItem("Save remote as…", action: #selector(saveRemoteVersion), enabled: actions.hasRemoteVersion, to: menu)
        addMenuItem("Save base as…", action: #selector(saveBaseVersion), enabled: actions.hasBaseVersion, to: menu)
        menu.addItem(.separator())
        addMenuItem("Open", action: #selector(openWorkingFile), enabled: single, to: menu)
        addMenuItem("Open With", action: #selector(openWorkingFileWith), enabled: single, to: menu)
        let reveal = addMenuItem("Show in Finder", action: #selector(showWorkingFile), enabled: single, to: menu)
        AppKitFactory.setMenuImage("BrowseFileExplorer", for: reveal)
        menu.addItem(.separator())
        addMenuItem("File history", action: #selector(openFileHistory), enabled: actions.canShowFileHistory(available: fileHistory != nil), to: menu)
    }

    @discardableResult
    private func addMenuItem(_ title: String, action: Selector?, enabled: Bool, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = action == nil ? nil : self
        item.isEnabled = enabled
        menu.addItem(item)
        return item
    }

    @objc private func openCustomMergeTool(_ sender: NSMenuItem) {
        let selected = selectedConflicts
        let tool = sender.representedObject as? String
        guard selected.count == 1 else { return }
        runWorkflow { [weak self] _ in
            for conflict in selected { await self?.runInteractiveMergeTool(path: conflict.path, tool: tool) }
        }
    }

    @objc private func chooseLocal() { choose(.local) }
    @objc private func chooseRemote() { choose(.remote) }
    @objc private func chooseBase() { choose(.base) }

    private func choose(_ side: RepositoryConflictSide) {
        let values = selectedConflicts
        guard !values.isEmpty else { return }
        runWorkflow { await $0.choose(side, selection: values) }
    }

    private func makeWorkflow() -> ConflictResolutionWorkflow {
        ConflictResolutionWorkflow(source: source, presenter: self, rebase: state?.rebaseInProgress == true, mergeTool: mergeToolConfiguration)
    }

    private func runWorkflow(_ operation: @escaping @MainActor (ConflictResolutionWorkflow) async -> Void) {
        task?.cancel()
        let workflow = makeWorkflow()
        task = Task { @MainActor [weak self] in
            await OutputHistoryRecording.perform { await operation(workflow) }
            guard let self, !Task.isCancelled else { return }
            repositoryChanged = true
            reloadState()
        }
    }

    @objc private func openFileHistory() {
        guard let conflict = selectedConflicts.first, selectedConflicts.count == 1, let panel, let fileHistory else { return }
        _ = fileHistory(conflict.path, panel)
    }

    @objc private func openLocalVersion() { openVersion(.local) }
    @objc private func openRemoteVersion() { openVersion(.remote) }
    @objc private func openBaseVersion() { openVersion(.base) }
    @objc private func saveLocalVersion() { saveVersion(.local) }
    @objc private func saveRemoteVersion() { saveVersion(.remote) }
    @objc private func saveBaseVersion() { saveVersion(.base) }

    private func loadContent(_ side: RepositoryConflictSide) async throws -> RepositoryFileContent? {
        guard let conflict = selectedConflicts.first, selectedConflicts.count == 1 else { return nil }
        if let content = sideContent[side] { return content }
        return try await source.loadConflictContent(path: conflict.path, side: side, encoding: contentController.selectedEncoding)
    }

    private func openVersion(_ side: RepositoryConflictSide) {
        guard let conflict = selectedConflicts.first, selectedConflicts.count == 1 else { return }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let content = try await loadContent(side) else { return }
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("GitExtensionsMac-Conflict-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let name = URL(fileURLWithPath: conflict.path).lastPathComponent
                let url = directory.appendingPathComponent(name, isDirectory: false)
                try content.data.write(to: url, options: .atomic)
                if let panel { GitUICommands.openWith(url, owner: panel) }
            } catch { await showMessage(error.localizedDescription, title: "Error", isError: true) }
        }
    }

    private func saveVersion(_ side: RepositoryConflictSide) {
        guard let conflict = selectedConflicts.first, selectedConflicts.count == 1 else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = URL(fileURLWithPath: conflict.path).lastPathComponent
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let content = try await loadContent(side) else { return }
                try content.data.write(to: destination, options: .atomic)
                status.stringValue = "Saved \(sideTitle(side).lowercased()) version."
            } catch { await showMessage(error.localizedDescription, title: "Error", isError: true) }
        }
    }

    @objc private func openWorkingFile() { performWorkingFileAction(reveal: false) }
    @objc private func openWorkingFileWith() { performWorkingFileAction(reveal: false, chooseApplication: true) }
    @objc private func showWorkingFile() { performWorkingFileAction(reveal: true) }

    private func performWorkingFileAction(reveal: Bool, chooseApplication: Bool = false) {
        guard let conflict = selectedConflicts.first, selectedConflicts.count == 1 else { return }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let url = try await source.conflictWorkingTreeURL(path: conflict.path)
                if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                else if chooseApplication, let panel { GitUICommands.openWith(url, owner: panel) }
                else { NSWorkspace.shared.open(url) }
            } catch { await showMessage(error.localizedDescription, title: "Error", isError: true) }
        }
    }
    private func updateMergeToolButton() {
        let actions = actionState
        mergeButton.isEnabled = actions.hasSelection
        mergeToolButton.isEnabled = actions.hasSingleSelection && mergeToolConfiguration.map {
            !($0.path ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !($0.command ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } == true
        allMergeToolButton.isEnabled = true
        if let mergeToolConfiguration {
            mergeToolButton.title = "Open in \(mergeToolConfiguration.name)"
            mergeToolButton.toolTip = "Open the selected conflict in \(mergeToolConfiguration.name)"
        } else {
            mergeToolButton.title = "Open in"
            mergeToolButton.toolTip = "Configure merge.guitool or merge.tool in Git settings"
        }
    }
    @objc private func openMergeTool() {
        let selected = selectedConflicts
        guard !selected.isEmpty else { status.stringValue = "Select at least one conflict."; return }
        runWorkflow { await $0.openMergeTool(selected) }
    }
    @objc private func openAllInMergeTool() {
        runWorkflow { [weak self] _ in await self?.runInteractiveMergeTool(path: nil, tool: nil) }
    }
    @objc private func openSelectedConfiguredTool(_ sender: NSPopUpButton) {
        guard let tool = sender.selectedItem?.representedObject as? String else { return }
        sender.selectItem(at: 0)
        let selected = selectedConflicts
        guard !selected.isEmpty else { return }
        runWorkflow { [weak self] _ in
            for conflict in selected { await self?.runInteractiveMergeTool(path: conflict.path, tool: tool) }
        }
    }
    @objc private func markSolved() {
        let selected = selectedConflicts.map(\.path)
        guard !selected.isEmpty else { status.stringValue = "Select at least one conflict."; return }
        run { try await $0.stage(paths: selected) }
    }
    @objc private func markAllSolved() {
        guard !paths.isEmpty else { return }
        let allPaths = paths
        run { try await $0.stage(paths: allPaths) }
    }
    @objc private func resetRepository() {
        guard let panel else { return }
        let first = NSAlert()
        first.alertStyle = .warning
        first.messageText = "Reset conflict resolution?"
        first.informativeText = "A hard reset deletes all changes since the last commit."
        first.addButton(withTitle: "Continue")
        first.addButton(withTitle: "Cancel")
        guard first.runModal() == .alertFirstButtonReturn else { return }
        let second = NSAlert()
        second.alertStyle = .critical
        second.messageText = "WARNING!"
        second.informativeText = "Are you sure you want to DELETE all changes?\n\nThis action cannot be made undone."
        second.addButton(withTitle: "Reset")
        second.addButton(withTitle: "Cancel")
        task = Task { @MainActor [weak self] in
            guard await MutationDialogs.confirmSuppressible(second, window: nil, suppressedBy: \.dontConfirmSecondAbortConfirmation),
                  let self else { return }
            await execute(sequencerAction: .aborted) { source in
                try await source.resetChanges(RepositoryResetChangesRequest(scope: .all, deleteUntracked: false))
            }
            panel.orderOut(nil)
        }
    }
    @objc private func continueOperation() {
        guard let state else { return }
        if state.rebaseInProgress, let source = source as? any RepositoryRebaseDataSource {
            run(sequencerAction: .continued) { _ in try await source.continueRebase() }
        } else if state.cherryPickInProgress, let source = source as? any RepositoryCherryPickDataSource {
            run(sequencerAction: .continued) { _ in try await source.continueCherryPick() }
        } else if state.revertInProgress, let source = source as? any RepositoryRevertingDataSource {
            run(sequencerAction: .continued) { _ in try await source.continueRevert() }
        }
        else if mergeInProgress { presentMergeCommit(closeWhenCommitWindowCloses: false) }
    }
    @objc private func skipOperation() {
        guard let source = source as? any RepositoryRebaseDataSource else { return }
        run { _ in try await source.skipRebase() }
    }
    @objc private func abortOperation() {
        guard let state, let panel else { return }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            if state.rebaseInProgress, let source = source as? any RepositoryRebaseDataSource {
                await execute(sequencerAction: .aborted) { _ in try await source.abortRebase() }
            } else if state.cherryPickInProgress,
                      let source = source as? any RepositoryCherryPickDataSource {
                guard await MutationDialogs.confirmAbortCherryPick(window: panel) else { return }
                await execute(sequencerAction: .aborted) { _ in try await source.abortCherryPick() }
            } else if state.revertInProgress,
                      let source = source as? any RepositoryRevertingDataSource {
                guard await MutationDialogs.confirmAbortRevert(window: panel) else { return }
                await execute(sequencerAction: .aborted) { _ in try await source.abortRevert() }
            } else if mergeInProgress {
                guard await MutationDialogs.confirmAbortMerge(window: panel) else { return }
                await execute(sequencerAction: .aborted) { try await $0.abortMerge() }
            }
        }
    }
    private func presentMergeCommit(closeWhenCommitWindowCloses: Bool = false) {
        guard paths.isEmpty,
              commitWindowController == nil,
              let panel,
              let commitSource = source as? any RepositoryCommitWorkflowDataSource else { return }
        commitWindowController = CommitWorkflowDialog.present(
            source: commitSource,
            initialMode: .normal,
            head: nil,
            draft: nil,
            owner: panel,
            onRepositoryChanged: { [weak self] _ in
                guard let self else { return }
                repositoryChanged = true
                finish(true)
            },
            onClose: { [weak self] in
                guard let self else { return }
                commitWindowController = nil
                if closeWhenCommitWindowCloses { finish(repositoryChanged) }
            }
        )
    }
    private func commitMerge(_ request: RepositoryCommitRequest) {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                status.stringValue = "Committing merge…"
                _ = try await source.commit(request)
                repositoryChanged = true
                finish(true)
            } catch {
                await showMessage(error.localizedDescription, title: "Error", isError: true)
                reloadState()
            }
        }
    }
    private func run(
        sequencerAction: ConflictSequencerAction = .none,
        _ operation: @escaping @Sendable (any RepositoryConflictResolutionDataSource) async throws -> RepositoryMutationResult
    ) {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            await execute(sequencerAction: sequencerAction, operation)
        }
    }
    private func execute(
        sequencerAction: ConflictSequencerAction = .none,
        _ operation: @escaping @Sendable (any RepositoryConflictResolutionDataSource) async throws -> RepositoryMutationResult
    ) async {
        do {
            status.stringValue = "Updating repository…"
            let result = try await operation(source)
            repositoryChanged = true
            if sequencerAction != .none { self.sequencerAction = sequencerAction }
            if sequencerAction == .aborted {
                finish(true)
                return
            }
            switch result.outcome {
            case .completed: status.stringValue = result.message
            case .conflicts(let values): status.stringValue = "\(values.count) conflicted path(s) remain."
            case .paused(let reason): status.stringValue = reason
            }
            reloadState()
        } catch { await showMessage(error.localizedDescription, title: "Error", isError: true) }
    }
    override func cancelOperation(_ sender: Any?) { close() }
    @objc private func close() { finish(repositoryChanged) }
    func windowWillClose(_ notification: Notification) { finish(repositoryChanged) }
    private func finish(_ changed: Bool) {
        guard !didClose else { return }
        didClose = true
        task?.cancel()
        contentTask?.cancel()
        if let pendingAlert { panel?.endSheet(pendingAlert.window, returnCode: .cancel) }
        commitWindowController?.close()
        onClose?(ConflictResolutionResult(repositoryChanged: changed, sequencerAction: sequencerAction))
    }
}

extension ConflictResolverViewController: ConflictResolutionPresenter {
    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let panel, !didClose else { return .cancel }
        pendingAlert = alert
        defer { pendingAlert = nil }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: panel) { continuation.resume(returning: $0) }
        }
    }

    func decide(_ request: ConflictDecisionRequest) async -> ConflictDecision {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = request.path
        alert.informativeText = request.text
        for title in [request.localButton, request.remoteButton, request.baseButton, "Cancel"] { alert.addButton(withTitle: title) }
        alert.showsSuppressionButton = !request.applyToAllText.isEmpty
        alert.suppressionButton?.title = request.applyToAllText
        alert.window.title = ConflictDecisionRequest.caption
        let response = await present(alert)
        let applyToAll = alert.showsSuppressionButton && alert.suppressionButton?.state == .on
        return switch response {
        case .alertFirstButtonReturn: ConflictDecision(preference: .keepLocal, applyToAll: applyToAll)
        case .alertSecondButtonReturn: ConflictDecision(preference: .keepRemote, applyToAll: applyToAll)
        case .alertThirdButtonReturn: ConflictDecision(preference: .keepBase, applyToAll: applyToAll)
        default: .cancelled
        }
    }

    func confirmOpenBinary(path: String, tool: String) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Warning"
        alert.informativeText = "The selected file appears to be a binary file.\nAre you sure you want to open this file in \(tool)?"
        alert.addButton(withTitle: "No")
        alert.addButton(withTitle: "Yes")
        return await present(alert) == .alertSecondButtonReturn
    }

    func confirmTwoWayMerge(path: String) async -> TwoWayMergeAnswer {
        let alert = NSAlert()
        alert.messageText = "Merge"
        alert.informativeText = "There is no base revision for '\(path)'.\nFall back to 2-way merge?"
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")
        alert.addButton(withTitle: "Cancel")
        return switch await present(alert) {
        case .alertFirstButtonReturn: .yes
        case .alertSecondButtonReturn: .no
        default: .cancel
        }
    }

    func confirmConflictSolved() async -> Bool {
        let alert = NSAlert()
        alert.messageText = ConflictResolutionWorkflow.askSolvedCaption
        alert.informativeText = ConflictResolutionWorkflow.askSolved
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")
        return await present(alert) == .alertFirstButtonReturn
    }

    static func mergeToolWarning(for tool: RepositoryMergeToolConfiguration?) -> NSAlert? {
        guard let message = ConflictResolutionWorkflow.loadWarning(for: tool) else { return nil }
        let alert = NSAlert()
        alert.alertStyle = tool == nil ? .critical : .warning
        alert.messageText = tool == nil ? "Error" : "Warning"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        return alert
    }

    func showMessage(_ text: String, title: String, isError: Bool) async {
        let alert = NSAlert()
        alert.alertStyle = isError ? .critical : .informational
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        _ = await present(alert)
    }

    func runInteractiveMergeTool(path: String?, tool: String?) async {
        let source = source
        status.stringValue = "Running git mergetool…"
        do {
            _ = try await ScriptProcessWindow.run(title: "git mergetool", owner: panel) { output in
                try await source.runMergeTool(path: path, tool: tool, output: output)
            }
        } catch is CancellationError {
            return
        } catch {
            await showMessage(error.localizedDescription, title: "Error", isError: true)
        }
    }

    func resolveSubmodule(path: String) async -> Bool {
        guard let submodules = source as? any RepositorySubmoduleManagingDataSource, let panel else { return false }
        let changed = await GitUICommands.resolveSubmoduleConflict(source: submodules, path: path, owner: panel, scriptHooks: scriptHooks?.childHooks)
        if changed { repositoryChanged = true }
        return changed
    }

    func progress(completed: Int, total: Int) {
        progressIndicator.maxValue = Double(max(1, total))
        progressIndicator.doubleValue = Double(completed)
        progressIndicator.isHidden = total == 0 || completed >= total
    }
}
