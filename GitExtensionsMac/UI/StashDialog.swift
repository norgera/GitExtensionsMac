import AppKit

struct StashDialogResult: Sendable {
    let snapshot: RepositorySnapshot
    let selectedCommitID: String?
}

@MainActor
enum StashDialog {
    static func present(
        source: any RepositoryStashDataSource,
        snapshot: RepositorySnapshot,
        manageStashes: Bool,
        initialStash: String?,
        owner: NSWindow,
        resolveConflicts: @escaping @MainActor (NSWindow) async -> RepositorySnapshot?
    ) async -> StashDialogResult {
        let controller = StashViewController(
            source: source,
            snapshot: snapshot,
            manageStashes: manageStashes,
            initialStash: initialStash,
            resolveConflicts: resolveConflicts
        )
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 708, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = controller
        panel.title = "Stash"
        panel.minSize = NSSize(width: 627, height: 443)
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isReleasedWhenClosed = false
        let preferences = AppSettingsStore.shared.stashPreferences
        panel.setContentSize(NSSize(
            width: max(627, preferences.windowWidth),
            height: max(443, preferences.windowHeight)
        ))
        controller.panel = panel
        panel.delegate = controller

        let windowController = NSWindowController(window: panel)
        return await withCheckedContinuation { continuation in
            controller.onClose = { [windowController] result in
                panel.orderOut(nil)
                owner.makeKeyAndOrderFront(nil)
                _ = windowController // Retain the independent window until dismissal.
                continuation.resume(returning: result)
            }
            windowController.showWindow(nil)
            panel.setFrameOrigin(NSPoint(
                x: owner.frame.midX - panel.frame.width / 2,
                y: owner.frame.midY - panel.frame.height / 2
            ))
            panel.makeKeyAndOrderFront(nil)
        }
    }
}

@MainActor
private final class StashViewController: RetainingSplitViewController, NSWindowDelegate {
    private enum Selection: Equatable {
        case workingDirectory
        case stash(String)
    }

    private struct DisplayFileContext {
        let commit: Commit
        let sourceFile: ChangedFile
    }

    weak var panel: NSWindow?
    var onClose: ((StashDialogResult) -> Void)?

    private let source: any RepositoryStashDataSource
    private var snapshot: RepositorySnapshot
    private let manageStashes: Bool
    private let initialStash: String?
    private let resolveConflicts: @MainActor (NSWindow) async -> RepositorySnapshot?

    private let leadingController = NSViewController()
    private let filesController = ChangedFilesViewController()
    private let diffController = DiffContentViewController()
    private let selector = NSPopUpButton()
    private let messageView = NSTextView()
    private let includeUntracked = NSButton(checkboxWithTitle: "Include untracked files", target: nil, action: nil)
    private let keepIndex = NSButton(checkboxWithTitle: "Keep index", target: nil, action: nil)
    private let stashAllButton = NSButton(title: "Stash all changes", target: nil, action: nil)
    private let stashSelectedButton = NSButton(title: "Stash selected changes", target: nil, action: nil)
    private let dropButton = NSButton(title: "Drop Selected Stash", target: nil, action: nil)
    private let applyButton = NSButton(title: "Apply Selected Stash", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()

    private var displayFiles: [String: DisplayFileContext] = [:]
    private var mutationTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var diffTask: Task<Void, Never>?
    private var keyMonitor: Any?
    private var didClose = false
    private var isMutating = false
    private var isLoadingSelection = false
    private var lastOperationSelectedCommitID: String?
    private var didSetInitialDivider = false

    private var isBusy: Bool { isMutating || isLoadingSelection }

    init(
        source: any RepositoryStashDataSource,
        snapshot: RepositorySnapshot,
        manageStashes: Bool,
        initialStash: String?,
        resolveConflicts: @escaping @MainActor (NSWindow) async -> RepositorySnapshot?
    ) {
        self.source = source
        self.snapshot = snapshot
        self.manageStashes = manageStashes
        self.initialStash = initialStash
        self.resolveConflicts = resolveConflicts
        super.init(resizeBehavior: .fixedLeadingPane)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        mutationTask?.cancel()
        selectionTask?.cancel()
        diffTask?.cancel()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .paneSplitter

        configureLeadingView()
        let leadingItem = NSSplitViewItem(viewController: leadingController)
        leadingItem.minimumThickness = 170
        leadingItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 270)
        addSplitViewItem(leadingItem)

        let diffItem = NSSplitViewItem(viewController: diffController)
        diffItem.minimumThickness = 350
        diffItem.holdingPriority = .defaultLow
        addSplitViewItem(diffItem)
        diffController.selectionScope = .revision

        filesController.onSelection = { [weak self] file in
            self?.showDiff(for: file)
            self?.updateButtonStates()
        }

        let preferences = AppSettingsStore.shared.stashPreferences
        keepIndex.state = preferences.keepIndex ? .on : .off
        includeUntracked.state = preferences.includeUntracked ? .on : .off
        reloadSelector(initial: true)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        installKeyMonitor()
        focusInitialControl()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !didSetInitialDivider, splitView.bounds.width >= 600 else { return }
        didSetInitialDivider = true
        setRetainedPosition(AppSettingsStore.shared.stashPreferences.dividerPosition)
    }

    private func configureLeadingView() {
        let root = NSView()
        let showLabel = NSTextField(labelWithString: "Show:")
        showLabel.font = .systemFont(ofSize: 12)
        selector.target = self
        selector.action = #selector(selectionChanged)
        selector.controlSize = .small

        let selectorRow = NSStackView(views: [showLabel, selector])
        selectorRow.orientation = .horizontal
        selectorRow.alignment = .centerY
        selectorRow.spacing = 5
        selector.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addChild(filesController)
        let filesView = filesController.view
        filesView.translatesAutoresizingMaskIntoConstraints = false

        let messageLabel = NSTextField(labelWithString: "Message:")
        messageLabel.font = .systemFont(ofSize: 12)
        messageView.font = .systemFont(ofSize: 12)
        messageView.isRichText = false
        messageView.isAutomaticQuoteSubstitutionEnabled = false
        messageView.isAutomaticDashSubstitutionEnabled = false
        messageView.textContainerInset = NSSize(width: 4, height: 4)
        let messageScroll = NSScrollView()
        messageScroll.documentView = messageView
        messageScroll.hasVerticalScroller = true
        messageScroll.borderType = .noBorder
        messageScroll.drawsBackground = true
        messageScroll.backgroundColor = .controlBackgroundColor
        messageScroll.translatesAutoresizingMaskIntoConstraints = false
        messageScroll.heightAnchor.constraint(equalToConstant: 72).isActive = true

        keepIndex.toolTip = "All changes already added to the index are left intact"
        includeUntracked.toolTip = "All untracked files are also stashed and then cleaned"
        let options = NSStackView(views: [keepIndex, includeUntracked])
        options.orientation = .horizontal
        options.distribution = .fillEqually
        options.spacing = 4

        stashAllButton.toolTip = "Save local changes to a new stash, then revert local changes"
        stashSelectedButton.toolTip = "Stash changes for the selected files, then revert them to the original state"
        dropButton.toolTip = "Remove the selected stash from the list"
        applyButton.toolTip = "Apply the selected stash on top of the current working directory state"
        stashAllButton.target = self; stashAllButton.action = #selector(stashAll)
        stashSelectedButton.target = self; stashSelectedButton.action = #selector(stashSelected)
        dropButton.target = self; dropButton.action = #selector(dropSelected)
        applyButton.target = self; applyButton.action = #selector(applySelected)
        [stashAllButton, stashSelectedButton, dropButton, applyButton].forEach {
            $0.controlSize = .regular
            $0.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        let statusRow = NSStackView(views: [progress, status])
        statusRow.orientation = .horizontal
        statusRow.spacing = 5

        let stack = NSStackView(views: [
            selectorRow,
            filesView,
            messageLabel,
            messageScroll,
            options,
            stashAllButton,
            stashSelectedButton,
            dropButton,
            applyButton,
            statusRow
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            selectorRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            filesView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            filesView.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
            messageLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            messageScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            options.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stashAllButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stashSelectedButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            dropButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            applyButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        leadingController.view = root
    }

    private var selection: Selection {
        guard selector.indexOfSelectedItem > 0,
              selector.indexOfSelectedItem - 1 < snapshot.stashes.count else { return .workingDirectory }
        return .stash(snapshot.stashes[selector.indexOfSelectedItem - 1].commitID)
    }

    private var selectedStash: Stash? {
        guard case .stash(let commitID) = selection else { return nil }
        return snapshot.stashes.first { $0.commitID == commitID }
    }

    private func reloadSelector(initial: Bool = false, preferredCommitID: String? = nil, preferredIndex: Int? = nil) {
        let previous = selection
        selector.removeAllItems()
        selector.addItem(withTitle: "Current working directory changes")
        snapshot.stashes.forEach { stash in
            selector.addItem(withTitle: "\(stash.selector.replacingOccurrences(of: "stash", with: "")): \(stash.subject)")
        }

        let selectedIndex: Int
        if let preferredCommitID,
           let stashIndex = snapshot.stashes.firstIndex(where: { $0.commitID == preferredCommitID }) {
            selectedIndex = stashIndex + 1
        } else if let preferredIndex {
            selectedIndex = min(max(0, preferredIndex), max(0, selector.numberOfItems - 1))
        } else if initial,
                  let initialStash,
                  let stashIndex = snapshot.stashes.firstIndex(where: { $0.selector == initialStash }) {
            selectedIndex = stashIndex + 1
        } else if initial, manageStashes, !snapshot.stashes.isEmpty {
            selectedIndex = 1
        } else if !initial,
                  case .stash(let commitID) = previous,
                  let stashIndex = snapshot.stashes.firstIndex(where: { $0.commitID == commitID }) {
            selectedIndex = stashIndex + 1
        } else {
            selectedIndex = 0
        }
        selector.selectItem(at: selectedIndex)
        loadSelectedEntry()
    }

    @objc private func selectionChanged() {
        loadSelectedEntry()
    }

    private func loadSelectedEntry() {
        selectionTask?.cancel()
        diffTask?.cancel()
        displayFiles.removeAll()
        diffController.apply(
            file: ChangedFile(id: "empty", path: "Select a changed file", oldPath: nil, changeType: .modified, additions: 0, deletions: 0),
            diff: nil
        )

        let requestedSelection = selection
        configureMessage(for: requestedSelection)
        setBusy(true, statusText: "Loading changes…", mutation: false)
        selectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let sections = try await makeSections(for: requestedSelection)
                guard !Task.isCancelled, selection == requestedSelection else { return }
                filesController.apply(
                    sections: sections,
                    scope: requestedSelection == .workingDirectory ? .workingTree : .revision
                )
                setBusy(false, statusText: sections.isEmpty ? "No changes." : "", mutation: false)
            } catch is CancellationError {
                return
            } catch {
                guard selection == requestedSelection else { return }
                setBusy(false, statusText: error.localizedDescription, mutation: false)
            }
        }
    }

    private func makeSections(for selection: Selection) async throws -> [ChangedFileSection] {
        switch selection {
        case .workingDirectory:
            guard let indexCommit = snapshot.commits.first(where: { $0.id == "$index" }),
                  let worktreeCommit = snapshot.commits.first(where: { $0.id == "$working-directory" }) else { return [] }
            async let indexDetails = source.loadRevisionDetails(for: indexCommit)
            async let workspaceDetails = source.loadRevisionDetails(for: worktreeCommit)
            let (index, workspace) = try await (indexDetails, workspaceDetails)
            let indexFiles = register(index.files, commit: indexCommit, prefix: "index")
            let workspaceFiles = register(workspace.files, commit: worktreeCommit, prefix: "workspace")
            return [
                ChangedFileSection(
                    id: "workspace",
                    title: "Working directory",
                    imageName: "Diff",
                    files: workspaceFiles
                ),
                ChangedFileSection(
                    id: "index",
                    title: "Commit index",
                    imageName: "CommitSummary",
                    files: indexFiles
                )
            ].filter { !$0.files.isEmpty }

        case .stash(let commitID):
            guard let stash = snapshot.stashes.first(where: { $0.commitID == commitID }),
                  let commit = snapshot.commits.first(where: { $0.id == commitID }) else {
                throw RepositoryMutationError.invalidStash(selectedStash?.selector ?? "stash")
            }
            let details = try await source.loadRevisionDetails(for: commit)
            let files = register(details.files, commit: commit, prefix: stash.selector)
            return [ChangedFileSection(
                id: stash.selector,
                title: "\(stash.selector.replacingOccurrences(of: "stash", with: "")): \(stash.subject)",
                imageName: "stash",
                files: files
            )]
        }
    }

    private func register(_ files: [ChangedFile], commit: Commit, prefix: String) -> [ChangedFile] {
        files.map { file in
            let display = ChangedFile(
                id: "\(prefix)\u{0}\(file.id)",
                path: file.path,
                oldPath: file.oldPath,
                changeType: file.changeType,
                additions: file.additions,
                deletions: file.deletions
            )
            displayFiles[display.id] = DisplayFileContext(commit: commit, sourceFile: file)
            return display
        }
    }

    private func showDiff(for displayFile: ChangedFile) {
        diffTask?.cancel()
        guard let context = displayFiles[displayFile.id] else {
            diffController.apply(file: displayFile, diff: nil)
            return
        }
        diffController.apply(file: displayFile, diff: nil)
        diffTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let diff = try await source.loadDiff(for: context.commit, file: context.sourceFile)
                guard !Task.isCancelled else { return }
                diffController.apply(file: displayFile, diff: diff)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                status.stringValue = error.localizedDescription
            }
        }
    }

    private func configureMessage(for selection: Selection) {
        switch selection {
        case .workingDirectory:
            messageView.isEditable = true
            messageView.textColor = .labelColor
            messageView.string = snapshot.stashes.isEmpty ? "There are no stashes." : ""
        case .stash:
            messageView.isEditable = false
            messageView.textColor = .secondaryLabelColor
            messageView.string = selectedStash?.subject ?? ""
        }
        updateButtonStates()
    }

    @objc private func stashAll() {
        createStash(selectedOnly: false)
    }

    @objc private func stashSelected() {
        createStash(selectedOnly: true)
    }

    private func createStash(selectedOnly: Bool) {
        let paths = selectedOnly
            ? Array(Set(filesController.currentlySelectedFiles().map(\.path))).sorted()
            : []
        guard !selectedOnly || !paths.isEmpty else { return }
        let request = RepositoryStashCreateRequest(
            message: messageView.string,
            includeUntracked: includeUntracked.state == .on,
            keepIndex: keepIndex.state == .on,
            stagedOnly: false,
            selectedPaths: paths
        )
        mutate(statusText: selectedOnly ? "Stashing selected changes…" : "Stashing all changes…") {
            try await $0.createStash(request)
        } completion: { [weak self] result in
            self?.snapshot = result.snapshot
            self?.lastOperationSelectedCommitID = "$working-directory"
            self?.reloadSelector(preferredIndex: 0)
        }
    }

    @objc private func applySelected() {
        guard let stash = selectedStash else { return }
        mutate(statusText: "Applying \(stash.selector)…") {
            try await $0.applyStash(stash)
        } completion: { [weak self] result in
            self?.snapshot = result.snapshot
            self?.lastOperationSelectedCommitID = "$working-directory"
            self?.reloadSelector(preferredIndex: 0)
        }
    }

    @objc private func dropSelected() {
        guard let stash = selectedStash, let panel else { return }
        let droppedComboIndex = selector.indexOfSelectedItem
        mutationTask?.cancel()
        mutationTask = Task { @MainActor [weak self] in
            guard let self, await MutationDialogs.confirmDrop(stash: stash, window: panel) else { return }
            mutate(statusText: "Dropping \(stash.selector)…", cancelExisting: false) {
                try await $0.dropStash(stash)
            } completion: { [weak self] result in
                guard let self else { return }
                snapshot = result.snapshot
                lastOperationSelectedCommitID = result.selectedCommitID
                reloadSelector(preferredCommitID: result.selectedCommitID, preferredIndex: droppedComboIndex)
            }
        }
    }

    private func mutate(
        statusText: String,
        cancelExisting: Bool = true,
        operation: @escaping @Sendable (any RepositoryStashDataSource) async throws -> RepositoryMutationResult,
        completion: @escaping @MainActor (RepositoryMutationResult) -> Void
    ) {
        if cancelExisting { mutationTask?.cancel() }
        setBusy(true, statusText: statusText, mutation: true)
        mutationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var result = try await operation(source)
                guard !Task.isCancelled else { return }
                if case .conflicts(let paths) = result.outcome, let panel {
                    snapshot = result.snapshot
                    status.stringValue = "\(result.message) \(paths.count) conflicted path(s) remain."
                    if await MutationDialogs.confirmResolveStashConflicts(paths: paths, window: panel),
                       let resolved = await resolveConflicts(panel) {
                        result = RepositoryMutationResult(
                            snapshot: resolved,
                            selectedCommitID: result.selectedCommitID,
                            outcome: .completed,
                            message: "Repository refreshed after resolving stash conflicts."
                        )
                    }
                }
                guard !Task.isCancelled else { return }
                completion(result)
                setBusy(false, statusText: result.message, mutation: true)
            } catch is CancellationError {
                return
            } catch {
                if let refreshed = try? await source.loadSnapshot(), !Task.isCancelled {
                    snapshot = refreshed
                    reloadSelector()
                }
                setBusy(false, statusText: error.localizedDescription, mutation: true)
                if let panel { await MutationDialogs.showError(error, title: "Stash failed", window: panel) }
            }
        }
    }

    private func setBusy(_ busy: Bool, statusText: String, mutation: Bool) {
        if mutation {
            isMutating = busy
        } else {
            isLoadingSelection = busy
        }
        status.stringValue = statusText
        if isBusy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        updateButtonStates()
    }

    private func updateButtonStates() {
        let current = selection == .workingDirectory
        selector.isEnabled = !isBusy
        keepIndex.isEnabled = !isBusy
        includeUntracked.isEnabled = !isBusy
        stashAllButton.isEnabled = !isBusy
        stashSelectedButton.isEnabled = !isBusy && current && !filesController.currentlySelectedFiles().isEmpty
        dropButton.isEnabled = !isBusy && !current && selectedStash != nil
        applyButton.isEnabled = !isBusy && !current && selectedStash != nil
        messageView.isSelectable = !isBusy
        messageView.isEditable = !isBusy && current
    }

    private func focusInitialControl() {
        guard let panel else { return }
        if selection == .workingDirectory {
            panel.makeFirstResponder(messageView)
        } else {
            panel.makeFirstResponder(selector)
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === panel else { return event }
            if event.keyCode == 53 {
                if selector.cell?.isHighlighted == true {
                    return event
                }
                let selectedRange = messageView.selectedRange()
                if selectedRange.length > 0 {
                    messageView.setSelectedRange(NSRange(location: selectedRange.location, length: 0))
                    return nil
                }
                finish()
                return nil
            }
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                let key = event.charactersIgnoringModifiers?.lowercased()
                if key == "n" { changeSelectedStash(by: -1); return nil }
                if key == "p" { changeSelectedStash(by: 1); return nil }
            }
            if event.keyCode == 96 {
                refreshWorkingDirectoryIfSelected()
                return nil
            }
            return event
        }
    }

    private func changeSelectedStash(by offset: Int) {
        let next = selector.indexOfSelectedItem + offset
        guard next >= 0, next < selector.numberOfItems else { return }
        selector.selectItem(at: next)
        loadSelectedEntry()
    }

    private func refreshWorkingDirectoryIfSelected() {
        guard selection == .workingDirectory else { return }
        selectionTask?.cancel()
        selectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                snapshot = try await source.loadSnapshot()
                guard !Task.isCancelled else { return }
                reloadSelector(preferredIndex: 0)
                status.stringValue = "Refreshed working directory changes."
            } catch { status.stringValue = error.localizedDescription }
        }
    }

    func windowDidResize(_ notification: Notification) {
        persistPreferences()
    }

    func windowWillClose(_ notification: Notification) {
        finish()
    }

    private func persistPreferences() {
        guard let panel else { return }
        var preferences = AppSettingsStore.shared.stashPreferences
        preferences.keepIndex = keepIndex.state == .on
        preferences.includeUntracked = includeUntracked.state == .on
        preferences.windowWidth = panel.contentLayoutRect.width
        preferences.windowHeight = panel.contentLayoutRect.height
        if let leading = splitView.arrangedSubviews.first {
            preferences.dividerPosition = leading.frame.width
        }
        AppSettingsStore.shared.saveStashPreferences(preferences)
    }

    private func finish() {
        guard !didClose else { return }
        didClose = true
        persistPreferences()
        mutationTask?.cancel()
        selectionTask?.cancel()
        diffTask?.cancel()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        let close = onClose
        onClose = nil
        close?(StashDialogResult(snapshot: snapshot, selectedCommitID: lastOperationSelectedCommitID))
    }
}
