import AppKit

@MainActor
enum WorkflowManagementDialogs {
    static func manageStashes(
        source: any RepositoryMutatingDataSource,
        snapshot: RepositorySnapshot,
        window: NSWindow
    ) async -> RepositorySnapshot? {
        let controller = StashManagerViewController(source: source, snapshot: snapshot)
        let panel = NSPanel(contentViewController: controller)
        panel.title = "Stash"
        panel.styleMask = [.titled, .closable, .resizable]
        panel.setContentSize(NSSize(width: 720, height: 430))
        panel.minSize = NSSize(width: 570, height: 340)
        controller.panel = panel
        panel.delegate = controller
        return await withCheckedContinuation { continuation in
            controller.onClose = { refreshed in
                window.endSheet(panel)
                continuation.resume(returning: refreshed)
            }
            window.beginSheet(panel)
        }
    }

    static func resolveConflicts(
        source: any RepositoryMutatingDataSource,
        window: NSWindow
    ) async -> RepositorySnapshot? {
        let controller = ConflictResolverViewController(source: source)
        let panel = NSPanel(contentViewController: controller)
        panel.title = "Resolve merge conflicts"
        panel.styleMask = [.titled, .closable, .resizable]
        panel.setContentSize(NSSize(width: 680, height: 460))
        panel.minSize = NSSize(width: 540, height: 350)
        controller.panel = panel
        panel.delegate = controller
        return await withCheckedContinuation { continuation in
            controller.onClose = { refreshed in
                window.endSheet(panel)
                continuation.resume(returning: refreshed)
            }
            window.beginSheet(panel)
        }
    }
}

@MainActor
private final class StashManagerViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    weak var panel: NSPanel?
    var onClose: ((RepositorySnapshot?) -> Void)?
    private let source: any RepositoryMutatingDataSource
    private var snapshot: RepositorySnapshot
    private let table = NSTableView()
    private let details = NSTextField(wrappingLabelWithString: "Select a stash.")
    private let status = NSTextField(labelWithString: "")
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let popButton = NSButton(title: "Pop", target: nil, action: nil)
    private let dropButton = NSButton(title: "Drop", target: nil, action: nil)
    private var task: Task<Void, Never>?
    private var didClose = false

    init(source: any RepositoryMutatingDataSource, snapshot: RepositorySnapshot) {
        self.source = source
        self.snapshot = snapshot
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    deinit { task?.cancel() }

    override func loadView() {
        let root = NSView()
        let selector = NSTableColumn(identifier: .init("Selector")); selector.title = "Stash"; selector.width = 95
        let branch = NSTableColumn(identifier: .init("Branch")); branch.title = "Branch"; branch.width = 150
        let message = NSTableColumn(identifier: .init("Message")); message.title = "Message"; message.width = 390
        [selector, branch, message].forEach(table.addTableColumn)
        table.rowHeight = 22
        table.intercellSpacing = .zero
        table.delegate = self
        table.dataSource = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        details.maximumNumberOfLines = 3
        details.textColor = .secondaryLabelColor
        applyButton.target = self; applyButton.action = #selector(apply)
        popButton.target = self; popButton.action = #selector(pop)
        dropButton.target = self; dropButton.action = #selector(drop)
        let create = NSButton(title: "Create stash…", target: self, action: #selector(create))
        let close = NSButton(title: "Close", target: self, action: #selector(close))
        close.keyEquivalent = "\u{1b}"
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [create, applyButton, popButton, dropButton, spacer, close])
        buttons.orientation = .horizontal
        buttons.spacing = 7
        let stack = NSStackView(views: [scroll, details, status, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        view = root
        table.reloadData()
        if !snapshot.stashes.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        updateSelection()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { snapshot.stashes.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let stash = snapshot.stashes[row]
        let value: String
        switch tableColumn?.identifier.rawValue {
        case "Selector": value = stash.selector
        case "Branch": value = stash.branchName
        default: value = stash.subject
        }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }

    private var selectedStash: Stash? {
        guard table.selectedRow >= 0, table.selectedRow < snapshot.stashes.count else { return nil }
        return snapshot.stashes[table.selectedRow]
    }
    private func updateSelection() {
        let stash = selectedStash
        details.stringValue = stash.map { "\($0.selector) on \($0.branchName)\n\($0.subject)\n\($0.commitID)" } ?? "No stash selected."
        [applyButton, popButton, dropButton].forEach { $0.isEnabled = stash != nil }
    }

    @objc private func create() {
        guard let panel else { return }
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self, let request = await MutationDialogs.stashCreateRequest(window: panel) else { return }
            await mutate { try await $0.createStash(request) }
        }
    }
    @objc private func apply() { guard let stash = selectedStash else { return }; task = Task { await mutate { try await $0.applyStash(stash) } } }
    @objc private func pop() { guard let stash = selectedStash else { return }; task = Task { await mutate { try await $0.popStash(stash) } } }
    @objc private func drop() {
        guard let stash = selectedStash, let panel else { return }
        task = Task { @MainActor [weak self] in
            guard let self, await MutationDialogs.confirmDrop(stash: stash, window: panel) else { return }
            await mutate { try await $0.dropStash(stash) }
        }
    }

    private func mutate(_ operation: @escaping @Sendable (any RepositoryMutatingDataSource) async throws -> RepositoryMutationResult) async {
        do {
            status.stringValue = "Updating stash list…"
            let result = try await operation(source)
            snapshot = result.snapshot
            table.reloadData()
            if !snapshot.stashes.isEmpty { table.selectRowIndexes(IndexSet(integer: min(max(0, table.selectedRow), snapshot.stashes.count - 1)), byExtendingSelection: false) }
            updateSelection()
            status.stringValue = result.message
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func close() { finish(snapshot) }
    func windowWillClose(_ notification: Notification) { finish(snapshot) }
    private func finish(_ value: RepositorySnapshot?) {
        guard !didClose else { return }
        didClose = true
        onClose?(value)
    }
}

@MainActor
private final class ConflictResolverViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    weak var panel: NSPanel?
    var onClose: ((RepositorySnapshot?) -> Void)?
    private let source: any RepositoryMutatingDataSource
    private let table = NSTableView()
    private let descriptionLabel = NSTextField(labelWithString: "Select a file")
    private let status = NSTextField(labelWithString: "Scanning merge conflicts…")
    private let continueButton = NSButton(title: "Continue", target: nil, action: nil)
    private let skipButton = NSButton(title: "Skip", target: nil, action: nil)
    private let abortButton = NSButton(title: "Abort", target: nil, action: nil)
    private var state: RepositoryMutationState?
    private var mergeInProgress = false
    private var paths: [String] = []
    private var latestSnapshot: RepositorySnapshot?
    private var commitWindowController: NSWindowController?
    private var task: Task<Void, Never>?
    private var didClose = false

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
        let mergetool = NSButton(title: "Open in mergetool", target: nil, action: nil); mergetool.isEnabled = false; mergetool.toolTip = "External merge tool execution is not implemented"
        let solved = NSButton(title: "Mark conflict as solved", target: self, action: #selector(markSolved))
        let rescan = NSButton(title: "Rescan merge conflicts", target: self, action: #selector(rescan))
        continueButton.target = self; continueButton.action = #selector(continueOperation)
        skipButton.target = self; skipButton.action = #selector(skipOperation)
        abortButton.target = self; abortButton.action = #selector(abortOperation)
        let close = NSButton(title: "Close", target: self, action: #selector(close)); close.keyEquivalent = "\u{1b}"
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [mergetool, solved, rescan, spacer, continueButton, skipButton, abortButton, close])
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
    }
    @objc private func rescan() { reloadState() }
    private func reloadState() {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                async let loadedState = source.loadMutationState()
                async let snapshot = source.loadSnapshot()
                let (state, refreshed) = try await (loadedState, snapshot)
                var pullState: RepositoryPullState?
                if let pullSource = source as? any RepositoryPullingDataSource {
                    pullState = try? await pullSource.loadPullState()
                }
                self.state = state
                mergeInProgress = pullState?.mergeInProgress ?? false
                latestSnapshot = refreshed; paths = state.conflictedPaths; table.reloadData()
                status.stringValue = paths.isEmpty ? "No unresolved conflicts." : "\(paths.count) unresolved conflict(s)."
                continueButton.isHidden = !(state.rebaseInProgress || state.cherryPickInProgress || mergeInProgress)
                continueButton.title = mergeInProgress ? "Commit merge…" : "Continue"
                skipButton.isHidden = !state.rebaseInProgress
                abortButton.isHidden = !(state.rebaseInProgress || state.cherryPickInProgress || mergeInProgress)
                continueButton.isEnabled = paths.isEmpty
            } catch { status.stringValue = error.localizedDescription }
        }
    }
    @objc private func markSolved() {
        let selected = table.selectedRowIndexes.map { paths[$0] }
        guard !selected.isEmpty else { status.stringValue = "Select at least one conflict."; return }
        run { try await $0.stage(paths: selected) }
    }
    @objc private func continueOperation() {
        guard let state else { return }
        if state.rebaseInProgress { run { try await $0.continueRebase() } }
        else if state.cherryPickInProgress { run { try await $0.continueCherryPick() } }
        else if mergeInProgress { presentMergeCommit() }
    }
    @objc private func skipOperation() { run { try await $0.skipRebase() } }
    @objc private func abortOperation() {
        guard let state, let panel else { return }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            if state.rebaseInProgress {
                guard await MutationDialogs.confirmAbortRebase(window: panel) else { return }
                await execute { try await $0.abortRebase() }
            } else if state.cherryPickInProgress {
                guard await MutationDialogs.confirmAbortCherryPick(window: panel) else { return }
                await execute { try await $0.abortCherryPick() }
            } else if mergeInProgress {
                guard await MutationDialogs.confirmAbortMerge(window: panel) else { return }
                await execute { try await $0.abortMerge() }
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
    private func run(_ operation: @escaping @Sendable (any RepositoryMutatingDataSource) async throws -> RepositoryMutationResult) {
        task?.cancel(); task = Task { @MainActor [weak self] in guard let self else { return }; await execute(operation) }
    }
    private func execute(_ operation: @escaping @Sendable (any RepositoryMutatingDataSource) async throws -> RepositoryMutationResult) async {
        do {
            status.stringValue = "Updating repository…"
            let result = try await operation(source); latestSnapshot = result.snapshot
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
        onClose?(value)
    }
}
