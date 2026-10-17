import AppKit
import GitCommands
import GitExtensionsCore



@MainActor
final class CommitDiffWindowController: NSWindowController, NSWindowDelegate {
    let diffController = RevisionDiffViewController(mode: .diff, groupsByRevision: false)
    let infoController = CommitDetailViewController()
    var onClose: (() -> Void)?

    init(revision: Commit, source: any RepositoryFileStatusDataSource,
         infoSource: (any RepositoryCommitInfoDataSource)?, repositoryURL: URL?,
         comparedRevisions: [Commit]? = nil,
         command: @escaping (FileStatusListCommand) -> Void) {
        let split = RetainingSplitViewController(resizeBehavior: .fixedLeadingPane)
        split.splitView.isVertical = false
        super.init(window: nil)
        infoController.source = infoSource
        split.addSplitViewItem(NSSplitViewItem(viewController: infoController))
        split.splitViewItems[0].minimumThickness = 100
        split.splitViewItems[0].preferredThicknessFraction = 0.3
        split.addSplitViewItem(NSSplitViewItem(viewController: diffController))
        let window = RevisionComparisonWindow(contentViewController: split)
        window.title = "Diff - \(revision.shortID) - \(CommitInfoPresentation.fullDate(revision.authorDate)) - \(revision.authorName) - \(repositoryURL?.path ?? "")"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 717, height: 529))
        window.minSize = NSSize(width: 150, height: 148)
        window.setFrameAutosaveName("GitExtensionsMac.CommitDiff")
        window.contentView?.layoutSubtreeIfNeeded()
        split.setRetainedPosition(160)
        window.isReleasedWhenClosed = false
        self.window = window
        window.delegate = self
        diffController.filesController.supportsFindInCommitFilesGitGrep = false
        diffController.filesController.canAutoRefresh = false
        diffController.fileStatusSource = source
        diffController.repositoryURL = repositoryURL
        diffController.onCommand = command
        diffController.onFileCommand = { id, item in
            command(.init(identifier: id, items: [item], folder: nil, tool: nil, focused: item, remembered: nil))
        }
        infoController.apply(commit: revision, children: [])
        diffController.setDiffs(revisions: comparedRevisions ?? [revision], headID: nil)
        diffController.filesController.canShowInFileTree = false
        diffController.filesController.canFilterInGrid = false
    }

    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) { diffController.cancelLoads(); onClose?() }
}

@MainActor
class RevisionComparisonWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    init(content: NSViewController, title: String, size: NSSize, autosave: String) {
        let window = RevisionComparisonWindow(contentViewController: content)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(size)
        window.minSize = NSSize(width: 600, height: 400)
        window.setFrameAutosaveName(autosave)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }
    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) { onClose?() }
}

private final class RevisionComparisonWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}


@MainActor
final class RevisionPairViewController: NSViewController {
    let diff = RevisionDiffViewController(mode: .diff, groupsByRevision: false)
    private(set) var first: Commit
    private(set) var second: Commit
    private var firstLabel: String
    private var secondLabel: String
    let headID: ObjectID?

    let mergeBase: Commit?
    let baseCheckbox = NSButton(checkboxWithTitle: "Compare to merge base", target: nil, action: nil)
    private let firstText = NSTextField(labelWithString: "")
    private let secondText = NSTextField(labelWithString: "")
    private let directoryButton = NSButton(title: "Open diff using directory diff tool", target: nil, action: nil)
    var onPickBranch: ((Bool) -> Void)?
    var onPickCommit: ((Bool) -> Void)?
    var onDirectoryDiff: ((RevisionID, RevisionID) -> Void)?

    init(first: Commit, second: Commit, firstLabel: String?, secondLabel: String?, headID: ObjectID?, mergeBase: Commit?) {
        self.first = first; self.second = second; self.headID = headID; self.mergeBase = mergeBase
        self.firstLabel = firstLabel ?? first.subject; self.secondLabel = secondLabel ?? second.subject
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1042, height: 685))
        root.autoresizingMask = [.width, .height]
        func endpoint(_ title: String, _ label: NSTextField, first: Bool) -> NSBox {
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let branch = NSButton(title: "", target: self, action: #selector(pickBranch(_:)))
            branch.image = AppKitFactory.resourceImage("BranchCheckout"); branch.toolTip = "Select another branch"; branch.tag = first ? 0 : 1
            let commit = NSButton(title: "", target: self, action: #selector(pickCommit(_:)))
            commit.image = AppKitFactory.resourceImage("SelectRevision")
            for button in [branch, commit] {
                button.imagePosition = .imageOnly
                button.translatesAutoresizingMaskIntoConstraints = false
                button.widthAnchor.constraint(equalToConstant: 22).isActive = true
                button.heightAnchor.constraint(equalToConstant: 22).isActive = true
            }
            commit.toolTip = "Select another commit"; commit.tag = first ? 0 : 1
            let row = NSStackView(views: [label, branch, commit]); row.spacing = 5; row.distribution = .fill
            row.translatesAutoresizingMaskIntoConstraints = false
            let box = NSBox(); box.title = title; box.translatesAutoresizingMaskIntoConstraints = false
            box.contentView?.addSubview(row)
            if let content = box.contentView {
                NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 5),
                    row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -5),
                    row.topAnchor.constraint(equalTo: content.topAnchor, constant: 3), row.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -3)])
            }
            return box
        }
        firstText.textColor = .systemRed; secondText.textColor = .systemGreen
        let swap = NSButton(title: "⇄", target: self, action: #selector(swapClicked)); swap.toolTip = "Swap BASE and Compare"
        let a = endpoint("BASE", firstText, first: true), b = endpoint("Compare", secondText, first: false)
        let endpoints = NSStackView(views: [a, swap, b]); endpoints.translatesAutoresizingMaskIntoConstraints = false
        endpoints.distribution = .fill; endpoints.spacing = 8
        swap.widthAnchor.constraint(equalToConstant: 44).isActive = true
        a.widthAnchor.constraint(equalTo: endpoints.widthAnchor, multiplier: 0.5, constant: -30).isActive = true
        a.widthAnchor.constraint(equalTo: b.widthAnchor).isActive = true
        baseCheckbox.target = self; baseCheckbox.action = #selector(baseChanged)
        baseCheckbox.isEnabled = mergeBase != nil
        if let id = mergeBase?.objectID { baseCheckbox.title += " (\(id.shortString))" }
        directoryButton.target = self; directoryButton.action = #selector(directoryClicked)
        let options = NSStackView(views: [baseCheckbox, directoryButton]); options.spacing = 20
        options.translatesAutoresizingMaskIntoConstraints = false
        diff.filesController.supportsFindInCommitFilesGitGrep = false
        diff.filesController.canAutoRefresh = false
        addChild(diff); diff.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(endpoints); root.addSubview(options); root.addSubview(diff.view)
        NSLayoutConstraint.activate([
            endpoints.topAnchor.constraint(equalTo: root.topAnchor, constant: 6), endpoints.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            endpoints.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6), endpoints.heightAnchor.constraint(equalToConstant: 53),
            options.topAnchor.constraint(equalTo: endpoints.bottomAnchor, constant: 3), options.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            options.heightAnchor.constraint(equalToConstant: 24), options.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -6),
            diff.view.topAnchor.constraint(equalTo: options.bottomAnchor, constant: 4), diff.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            diff.view.trailingAnchor.constraint(equalTo: root.trailingAnchor), diff.view.bottomAnchor.constraint(equalTo: root.bottomAnchor)])
        view = root
        populate()
    }
    var effectiveFirst: Commit { baseCheckbox.state == .on ? mergeBase ?? first : first }
    func replaceEndpoint(first isFirst: Bool, revision: Commit, label: String? = nil) {
        if isFirst { first = revision; firstLabel = label ?? revision.subject }
        else { second = revision; secondLabel = label ?? revision.subject }
        populate()
    }
    func swapEndpoints() {
        swap(&first, &second); swap(&firstLabel, &secondLabel); populate()
    }
    func populate() {
        guard isViewLoaded else { return }
        firstText.stringValue = firstLabel; firstText.toolTip = first.id.description
        secondText.stringValue = secondLabel; secondText.toolTip = second.id.description
        directoryButton.isEnabled = first.id != .workingDirectory
        diff.setDiffs(revisions: [second, effectiveFirst], headID: headID)
    }
    @objc private func swapClicked() { swapEndpoints() }
    @objc private func baseChanged() { populate() }
    @objc private func directoryClicked() { onDirectoryDiff?(effectiveFirst.id, second.id) }
    @objc private func pickBranch(_ sender: NSButton) { onPickBranch?(sender.tag == 0) }
    @objc private func pickCommit(_ sender: NSButton) { onPickCommit?(sender.tag == 0) }
}


@MainActor
final class RevisionComparisonGridController: NSViewController {
    let grid = RevisionGridViewController()
    let diff = RevisionDiffViewController(mode: .diff, groupsByRevision: false)
    private let filters = RevisionFilterToolbar()
    private let parentButtons = NSStackView()
    private var parentIDs: [RevisionID] = []
    private let source: any RepositoryRevisionComparingDataSource
    private var task: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var reader: RevisionReader?
    private var generation = 0
    private var selectionGeneration = 0
    private var headID: ObjectID?
    private let preselect: RevisionID?
    private let showArtificial: Bool
    private var focusedInitialSelection = false
    let choosing: Bool
    var rebaseChoice: RebaseCommitChoice?
    var onChoose: ((Commit?) -> Void)?
    private(set) var revisions: [Commit] = []
    private(set) var isLoading = false

    init(source: any RepositoryRevisionComparingDataSource, choosing: Bool = false, preselect: RevisionID? = nil, showArtificial: Bool = false) {
        self.source = source; self.choosing = choosing; self.preselect = preselect; self.showArtificial = showArtificial
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 650)); root.autoresizingMask = [.width, .height]
        filters.grid = grid
        filters.showAdvancedFilter = { [weak self] in self?.advancedFilter() }
        grid.onShowAdvancedFilter = filters.showAdvancedFilter
        grid.onRefreshRequested = { [weak self] in self?.reload() }
        grid.onFilterChanged = { [weak self] in self?.filters.filterChanged($0) }
        grid.onSelection = { [weak self] _ in self?.selectionChanged() }
        if choosing {
            grid.allowsArtificialViewSelection = showArtificial
            grid.allowsMultipleRevisionSelection = false
            grid.onViewSelected = { [weak self] selected in self?.onChoose?(selected.first) }
        }
        let split = RetainingSplitViewController(resizeBehavior: .fixedLeadingPane)
        split.splitView.isVertical = false; split.view.frame = NSRect(x: 0, y: 0, width: 900, height: 610)
        split.addSplitViewItem(NSSplitViewItem(viewController: grid))
        if !choosing { split.addSplitViewItem(NSSplitViewItem(viewController: diff)); split.setRetainedPosition(205) }
        addChild(split); split.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(split.view)
        NSLayoutConstraint.activate([
            split.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.view.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: choosing ? -40 : 0)
        ])
        split.view.topAnchor.constraint(equalTo: root.topAnchor).isActive = true
        if !choosing {
            diff.filesController.supportsFindInCommitFilesGitGrep = false
            diff.filesController.canAutoRefresh = false
        }
        if choosing {
            let ok = NSButton(title: "OK", target: self, action: #selector(chooseClicked)); ok.keyEquivalent = "\r"
            let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked)); cancel.keyEquivalent = "\u{1b}"
            let goTo = NSButton(title: "Go to commit…", target: self, action: #selector(goToClicked))
            let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let buttons = NSStackView(views: [NSTextField(labelWithString: "Find specific commit:"), goTo, parentButtons, spacer, cancel, ok]); buttons.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(buttons)
            NSLayoutConstraint.activate([buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10), buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10), buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6)])
        }
        view = root
    }
    override func viewDidAppear() { super.viewDidAppear(); if reader == nil && !isLoading { reload() } }
    func reload() {
        task?.cancel(); generation += 1; let token = generation
        let selected = grid.selectedRevisionIDsBySelectionOrder
        revisions = []; isLoading = true; grid.beginIncrementalLoad(preferredCommitID: selected.first ?? preselect)
        grid.showLoading(spinner: true)
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if let reader { await reader.cancel() }
                let request = try await source.comparisonReadRequest()
                guard !Task.isCancelled, token == generation else { return }
                reader = request.reader; headID = request.context.headID
                grid.applyAuthorIdentity(request.identity)
                diff.repositoryURL = URL(fileURLWithPath: request.identity.currentRepository.path)
                diff.isBareRepository = request.identity.currentRepository.isBare
                filters.references = { .init(local: request.branches.filter { !$0.isRemote }.map(\.name), remote: request.remoteBranchNames, tags: request.references.tags.map(\.name)) }
                grid.referenceNames = { (request.branches.filter { !$0.isRemote }.map(\.name) + request.remoteBranchNames, request.references.tags.map(\.name)) }
                var options = grid.readOptions

                if choosing { options.showArtificialCommits = showArtificial && !request.identity.currentRepository.isBare }
                if let rebaseChoice {
                    options.filter = rebaseChoice.options(options.filter)
                    options.showArtificialCommits = false
                    options.showStashes = false
                }
                for try await batch in await request.reader.read(request.context.with(options), maximumCount: AppSettingsStore.shared.browseDisplayPreferences.maximumRevisionCount) {
                    guard !Task.isCancelled, token == generation else { return }
                    revisions += batch; grid.appendIncrementalBatch(batch)
                }
                guard !Task.isCancelled, token == generation else { return }
                grid.finishLoading(isBareRepository: request.identity.currentRepository.isBare); isLoading = false
                if !selected.isEmpty { grid.selectCommits(ids: selected) }
                else if let preselect { grid.selectCommit(id: preselect) }
                selectionChanged()
                if choosing && !focusedInitialSelection {
                    focusedInitialSelection = true
                    grid.focusRevisionList()
                }
            } catch {
                guard !Task.isCancelled, token == generation else { return }
                isLoading = false; grid.finishLoading(failed: true)
                if let window = view.window { await MutationDialogs.showError(error, title: "Compare revisions", window: window) }
            }
        }
    }
    private func selectionChanged() {
        if choosing {
            for view in parentButtons.arrangedSubviews { parentButtons.removeArrangedSubview(view); view.removeFromSuperview() }
            parentIDs = Array((grid.selectedCommits.first?.graphParentIDs ?? []).prefix(2))
            if !parentIDs.isEmpty {
                parentButtons.addArrangedSubview(NSTextField(labelWithString: "Parent(s):"))
                for (index, id) in parentIDs.enumerated() {
                    let button = NSButton(title: id.objectID?.shortString ?? id.description, target: self, action: #selector(parentClicked(_:)))
                    button.isBordered = false; button.contentTintColor = .linkColor
                    button.tag = index; parentButtons.addArrangedSubview(button)
                }
            }
            return
        }
        let selected = grid.selectedRevisionIDsBySelectionOrder
        selectionTask?.cancel(); selectionGeneration += 1; let token = selectionGeneration
        selectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var resolved: [Commit] = []
                for id in selected { resolved.append(try await source.comparisonRevision(id, headID: headID)) }
                guard !Task.isCancelled, token == selectionGeneration else { return }
                diff.setDiffs(revisions: resolved, headID: headID)
            } catch { if !Task.isCancelled, let window = view.window { await MutationDialogs.showError(error, title: "Compare revisions", window: window) } }
        }
    }
    private func advancedFilter() {
        guard let window = view.window else { return }
        RevisionFilterDialogController.present(filter: grid.currentFilter, defaultLimit: AppSettingsStore.shared.browseDisplayPreferences.maximumRevisionCount, window: window) { [weak self] result in
            if let result { self?.grid.updateFilter { $0 = result } }
        }
    }
    func cancel() { task?.cancel(); selectionTask?.cancel(); generation += 1; diff.cancelLoads(); if let reader { Task { await reader.cancel() } } }
    @objc private func chooseClicked() {
        if grid.selectedCommits.count == 1 { onChoose?(grid.selectedCommits.first) }
    }
    @objc private func cancelClicked() { onChoose?(nil) }
    @objc private func goToClicked() { grid.performGridCommand("revision.navigate.commit") }
    @objc private func parentClicked(_ sender: NSButton) {
        guard parentIDs.indices.contains(sender.tag) else { return }
        if !grid.setSelectedRevision(parentIDs[sender.tag]) { RevisionGridMessages.revisionFilteredInGrid(parentIDs[sender.tag]) }
    }
}


@MainActor
final class ComparisonBranchPicker: NSViewController, NSComboBoxDelegate {
    private let branches: [Branch]
    let selected: RevisionID
    let field = NSComboBox()
    private let local = NSButton(radioButtonWithTitle: "Local branch", target: nil, action: nil)
    private let remote = NSButton(radioButtonWithTitle: "Remote branch", target: nil, action: nil)
    private let count = NSTextField(labelWithString: "")
    private let source: any RepositoryRevisionComparingDataSource
    private let headID: ObjectID?
    private var task: Task<Void, Never>?
    var completion: ((String?) -> Void)?
    init(branches: [Branch], selected: RevisionID, headID: ObjectID?, source: any RepositoryRevisionComparingDataSource) {
        self.branches = branches; self.selected = selected; self.headID = headID; self.source = source
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 434, height: 140))
        remote.state = .on
        for button in [local, remote] { button.target = self; button.action = #selector(branchTypeChanged(_:)) }
        field.delegate = self; field.completes = true
        let compare = NSButton(title: "Compare", target: self, action: #selector(compareClicked)); compare.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked)); cancel.keyEquivalent = "\u{1b}"
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let types = NSStackView(views: [local, remote]), buttons = NSStackView(views: [spacer, cancel, compare])
        let selectLabel = NSTextField(labelWithString: "Select branch")
        count.setContentHuggingPriority(.required, for: .horizontal)
        let selector = NSStackView(views: [selectLabel, field, count]); selector.spacing = 8
        let stack = NSStackView(views: [types, selector, buttons]); stack.orientation = .vertical; stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 10), selector.widthAnchor.constraint(equalTo: stack.widthAnchor), buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        view = root; populate()
    }
    override func viewDidAppear() { super.viewDidAppear(); view.window?.makeFirstResponder(field) }
    private func populate() { field.removeAllItems(); field.addItems(withObjectValues: branches.filter { $0.isRemote == (remote.state == .on) }.map(RevisionComparisonReadRequest.branchName)); field.stringValue = ""; count.stringValue = "" }
    @objc private func branchTypeChanged(_ sender: NSButton) { local.state = sender === local ? .on : .off; remote.state = sender === remote ? .on : .off; task?.cancel(); populate(); view.window?.makeFirstResponder(field) }
    func controlTextDidChange(_ obj: Notification) { updateCount() }
    func comboBoxSelectionDidChange(_ notification: Notification) { updateCount((field.objectValueOfSelectedItem as? String) ?? field.stringValue) }
    var countText: String { count.stringValue }
    private func updateCount(_ expression: String? = nil) {
        task?.cancel(); let expression = expression ?? field.stringValue
        count.stringValue = ""
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            let text = try? await source.comparisonCount(from: selected, to: expression, headID: headID)
            guard !Task.isCancelled, field.stringValue == expression else { return }
            count.stringValue = text ?? ""
        }
    }
    @objc private func compareClicked() { let value = field.stringValue.trimmingCharacters(in: .whitespaces); if !value.isEmpty { completion?(value) } else { view.window?.makeFirstResponder(field) } }
    @objc private func cancelClicked() { completion?(nil) }
    func cancel() { task?.cancel() }
}

@MainActor
enum RevisionCommitChooser {
    static func choose(source: any RepositoryRevisionComparingDataSource, preselect: RevisionID?,
                       showArtificial: Bool = false, rebaseChoice: RebaseCommitChoice? = nil, owner: NSWindow,
                       configure: ((RevisionComparisonGridController, RevisionComparisonWindowController) -> Void)? = nil) async -> Commit? {
        let content = RevisionComparisonGridController(source: source, choosing: true, preselect: preselect, showArtificial: showArtificial)
        content.rebaseChoice = rebaseChoice
        content.grid.dataSource = source as? any RepositoryRevisionGridDataSource
        let controller = RevisionComparisonWindowController(content: content, title: "Choose commit", size: NSSize(width: 900, height: 550), autosave: "GitExtensionsMac.ChooseCommit")
        configure?(content, controller)
        guard let window = controller.window else { return nil }
        return await withCheckedContinuation { continuation in
            var completed = false
            let finish: (Commit?) -> Void = { value in
                guard !completed else { return }; completed = true
                content.cancel(); content.onChoose = nil; controller.onClose = nil
                owner.endSheet(window); window.orderOut(nil); continuation.resume(returning: value)
            }
            controller.onClose = { finish(nil) }
            content.onChoose = { [controller] value in finish(value); _ = controller }
            owner.beginSheet(window)
        }
    }
}

@MainActor
final class CommitPickerSmallControl: NSStackView, NSTextFieldDelegate {
    let field = NSTextField(string: "")
    let pick = NSButton(image: AppKitFactory.resourceImage("SelectRevision", accessibilityDescription: "Choose commit") ?? NSImage(), target: nil, action: nil)
    let count = NSTextField(labelWithString: "")
    private let source: (any RepositoryRevisionComparingDataSource)?
    private let revisions: [Commit]
    private var displayedExpression = ""
    private var inputChanged = false
    private var generation = 0
    private var countTask: Task<Void, Never>?
    private var editingTask: Task<Void, Never>?
    private(set) var selectedCommit: Commit?
    weak var errorOwner: NSWindow?
    var onSelectionChanged: ((Commit?) -> Void)?
    var isEnabled = true {
        didSet { field.isEnabled = isEnabled; pick.isEnabled = isEnabled && source != nil; count.textColor = isEnabled ? .secondaryLabelColor : .disabledControlTextColor }
    }

    init(source: (any RepositoryRevisionComparingDataSource)?, revisions: [Commit], selected: Commit?) {
        self.source = source; self.revisions = revisions; selectedCommit = selected?.isArtificial == false ? selected : nil
        super.init(frame: .zero)
        orientation = .horizontal; alignment = .centerY; spacing = 3
        field.delegate = self; field.formatter = CommitPickerHashFormatter()
        field.setAccessibilityIdentifier("CommitPicker.Hash")
        field.placeholderString = "Commit ID or revision"
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        pick.target = self; pick.action = #selector(chooseCommit)
        pick.setAccessibilityIdentifier("CommitPicker.Choose")
        pick.isEnabled = source != nil
        count.setAccessibilityIdentifier("CommitPicker.Count")
        count.textColor = .secondaryLabelColor
        for control in [pick, count] { control.setContentHuggingPriority(.required, for: .horizontal) }
        [field, pick, count].forEach(addArrangedSubview)
        presentSelection(hideHEAD: false)
    }
    required init?(coder: NSCoder) { nil }

    func controlTextDidEndEditing(_ obj: Notification) {
        editingTask?.cancel()
        editingTask = Task { [weak self] in await self?.validateInput() }
    }
    func controlTextDidChange(_ obj: Notification) { inputChanged = true }
    func validateInput(force: Bool = false) async {
        let expression = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard force || inputChanged || expression != displayedExpression else { return }
        generation += 1; let token = generation
        do {
            let commit: Commit?
            if expression.isEmpty { commit = nil }
            else if let source { commit = try await source.comparisonTarget(expression) }
            else if let known = revisions.first(where: { $0.objectID?.string == expression || $0.shortID == expression || (expression == "HEAD" && $0.isHEAD) }) { commit = known }
            else { throw RevisionComparisonError.invalidTarget(expression) }
            guard !Task.isCancelled, token == generation else { return }
            selectedCommit = commit; onSelectionChanged?(commit)
        } catch {
            guard !Task.isCancelled, token == generation else { return }
            await MutationDialogs.showValidationError("The given commit hash is not valid for this repository and was therefore discarded.", caption: "Error", window: window?.isVisible == true ? window : errorOwner)
            guard !Task.isCancelled, token == generation else { return }
        }
        presentSelection(hideHEAD: expression == "HEAD")
    }
    func setSelectedCommitHash(_ expression: String) async {
        field.stringValue = expression
        await validateInput(force: true)
    }
    private func presentSelection(hideHEAD: Bool) {
        displayedExpression = hideHEAD ? "" : selectedCommit?.shortID ?? ""
        inputChanged = false
        field.stringValue = displayedExpression
        countTask?.cancel(); count.stringValue = ""
        guard !hideHEAD, let selected = selectedCommit, let source else { return }
        countTask = Task { [weak self] in
            guard let head = try? await source.comparisonTarget("HEAD"), let id = selected.objectID else { return }
            let text = try? await source.comparisonCount(from: head.id, to: id.string, headID: head.objectID)
            guard !Task.isCancelled, let self, self.selectedCommit?.id == selected.id else { return }
            self.count.stringValue = text ?? ""
        }
    }
    @objc private func chooseCommit() {
        guard isEnabled, let source, let owner = window else { return }
        Task { [weak self] in
            guard let self else { return }
            let selected: Commit?
            if let commands = GitUICommands.commands(for: source as AnyObject) {
                selected = await commands.pickCommit(preselect: selectedCommit?.id, owner: owner)
            } else {
                selected = await RevisionCommitChooser.choose(source: source, preselect: selectedCommit?.id, owner: owner)
            }
            guard let selected else { return }
            generation += 1; selectedCommit = selected
            onSelectionChanged?(selected); presentSelection(hideHEAD: false)
        }
    }
    func cancel() { generation += 1; editingTask?.cancel(); countTask?.cancel() }
}

private final class CommitPickerHashFormatter: Formatter {
    override func string(for obj: Any?) -> String? { obj as? String }
    override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String, errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool { obj?.pointee = string as NSString; return true }
    override func isPartialStringValid(_ partialString: String, newEditingString: AutoreleasingUnsafeMutablePointer<NSString?>?, errorDescription: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool { partialString.utf16.count <= 100 }
}
