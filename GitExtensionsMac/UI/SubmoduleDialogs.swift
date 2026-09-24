import GitExtensionsCore
import GitCommands
import AppKit

@MainActor
enum SubmoduleDialogs {
    static func run(title: String, owner: NSWindow,
                    operation: @escaping @Sendable (@escaping GitOutputHandler) async throws -> RepositorySubmoduleResult) async -> RepositorySubmoduleResult {
        await withCheckedContinuation { continuation in
            let controller = SubmoduleProcessViewController(operation: operation) { continuation.resume(returning: $0) }
            let panel = NSPanel(contentViewController: controller)
            panel.title = title; panel.styleMask = [.titled, .closable, .resizable]
            panel.setContentSize(NSSize(width: 700, height: 430)); panel.minSize = NSSize(width: 520, height: 300)
            controller.panel = panel; panel.delegate = controller
            owner.beginSheet(panel); controller.start()
        }
    }
    static func resolveConflict(source: any RepositorySubmoduleManagingDataSource, path: String, owner: NSWindow,
                                scriptHooks: ((any RepositoryBrowsingDataSource) -> ApplicationScriptHooks)? = nil) async -> Bool {
        await withCheckedContinuation { continuation in
            let controller = SubmoduleConflictViewController(source: source, path: path) { continuation.resume(returning: $0) }
            controller.scriptHooks = scriptHooks
            let panel = NSPanel(contentViewController: controller)
            panel.title = "Submodule conflict"; panel.styleMask = [.titled, .closable, .resizable]
            panel.setContentSize(NSSize(width: 595, height: 300)); panel.minSize = NSSize(width: 595, height: 280)
            controller.panel = panel; panel.delegate = controller
            owner.beginSheet(panel)
        }
    }
    static func manage(source: any RepositorySubmoduleManagingDataSource, owner: NSWindow,
                       changed: @escaping () -> Void, open: @escaping (Submodule, Bool) -> Void,
                       closed: @escaping () -> Void) -> NSWindowController {
        let controller = SubmoduleManagerViewController(source: source, changed: changed, open: open, closed: closed)
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Submodules"; window.setContentSize(NSSize(width: 782, height: 372))
        window.minSize = NSSize(width: 650, height: 340)
        window.isReleasedWhenClosed = false; window.delegate = controller
        window.setFrameOrigin(NSPoint(x: owner.frame.midX - window.frame.width / 2, y: owner.frame.midY - window.frame.height / 2))
        window.setFrameAutosaveName("SubmoduleManagement")
        let result = NSWindowController(window: window); result.showWindow(nil)
        return result
    }

    static func add(source: any RepositorySubmoduleManagingDataSource, owner: NSWindow, changed: @escaping () -> Void) async {
        await withCheckedContinuation { continuation in
            let controller = AddSubmoduleViewController(source: source, changed: changed) { continuation.resume() }
            let panel = NSPanel(contentViewController: controller)
            panel.title = "Add submodule"; panel.styleMask = [.titled, .closable]
            panel.setContentSize(NSSize(width: 550, height: 230))
            controller.panel = panel; panel.delegate = controller
            owner.beginSheet(panel)
        }
    }
}

@MainActor
private final class SubmoduleProcessViewController: NSViewController, NSWindowDelegate {
    weak var panel: NSPanel?
    private let operation: @Sendable (@escaping GitOutputHandler) async throws -> RepositorySubmoduleResult
    private let completion: (RepositorySubmoduleResult) -> Void
    private let output = NSTextView()
    private let status = NSTextField(labelWithString: "Running…")
    private let progress = NSProgressIndicator()
    private let keepOpen = NSButton(checkboxWithTitle: "Keep dialog open", target: nil, action: nil)
    private let abort = NSButton(title: "Abort", target: nil, action: nil)
    private let close = NSButton(title: "OK", target: nil, action: nil)
    private var task: Task<Void, Never>?
    private var result: RepositorySubmoduleResult?
    private var finished = false
    init(operation: @escaping @Sendable (@escaping GitOutputHandler) async throws -> RepositorySubmoduleResult, completion: @escaping (RepositorySubmoduleResult) -> Void) {
        self.operation = operation; self.completion = completion; super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        let root = NSView()
        output.isEditable = false; output.isSelectable = true; output.font = AppSettingsStore.shared.fontPreferences.font(.monospace, fallback: .monospacedSystemFont(ofSize: 11, weight: .regular))
        output.isHorizontallyResizable = true; output.isVerticallyResizable = true
        output.textContainer?.widthTracksTextView = false
        output.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView(); scroll.documentView = output; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        progress.style = .bar; progress.isIndeterminate = true
        keepOpen.state = AppSettingsStore.shared.pullPreferences.closeProcessOnSuccess ? .off : .on
        keepOpen.target = self; keepOpen.action = #selector(keepOpenChanged)
        abort.target = self; abort.action = #selector(abortOperation)
        close.target = self; close.action = #selector(finish); close.keyEquivalent = "\r"; close.isEnabled = false
        let header = NSStackView(views: [progress, status]); header.spacing = 8
        let footer = NSStackView(views: [keepOpen, NSView(), abort, close]); footer.spacing = 8
        for child in [header, scroll, footer] { root.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), header.topAnchor.constraint(equalTo: root.topAnchor, constant: 12), header.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            progress.widthAnchor.constraint(equalToConstant: 92), scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10), scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12), footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
        view = root
    }
    func start() {
        progress.startAnimation(nil)
        task = Task { @MainActor in
            do {
                result = try await operation { [weak self] event in
                    Task { @MainActor in
                        guard let self, !self.finished else { return }
                        self.output.textStorage?.append(NSAttributedString(string: event.text, attributes: [.foregroundColor: event.stream == .standardError ? NSColor.systemRed : NSColor.textColor, .font: AppSettingsStore.shared.fontPreferences.font(.monospace, fallback: .monospacedSystemFont(ofSize: 11, weight: .regular))]))
                        self.output.scrollToEndOfDocument(nil)
                    }
                }
            } catch { result = .init(succeeded: false, changed: false, output: error.localizedDescription) }
            task = nil; progress.stopAnimation(nil); abort.isEnabled = false; close.isEnabled = true
            status.stringValue = result?.succeeded == true ? "Completed successfully" : "Operation failed or was aborted"
            if output.string.isEmpty { output.string = result?.output ?? "" }
            if result?.succeeded == true && keepOpen.state == .off { finish() }
        }
    }
    @objc private func keepOpenChanged() {
        var preferences = AppSettingsStore.shared.pullPreferences
        preferences.closeProcessOnSuccess = keepOpen.state == .off
        AppSettingsStore.shared.savePullPreferences(preferences)
    }
    @objc private func abortOperation() { task?.cancel(); status.stringValue = "Aborting…" }
    override func cancelOperation(_ sender: Any?) { task == nil ? finish() : abortOperation() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancelOperation(nil); return false }
    @objc private func finish() {
        guard !finished, task == nil, let result else { return }; finished = true
        if let panel { panel.sheetParent?.endSheet(panel); panel.orderOut(nil) }
        completion(result)
    }
}

@MainActor
private final class SubmoduleConflictViewController: NSViewController, NSWindowDelegate {
    var scriptHooks: ((any RepositoryBrowsingDataSource) -> ApplicationScriptHooks)?
    weak var panel: NSPanel?
    private let source: any RepositorySubmoduleManagingDataSource
    private let path: String
    private let completion: (Bool) -> Void
    private let details = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let checkout = NSButton(title: "Checkout Branch", target: nil, action: nil)
    private let stage = NSButton(title: "Stage Current", target: nil, action: nil)
    private var context: RepositorySubmoduleConflictContext?
    private var initialContext: RepositorySubmoduleConflictContext?
    private var coordinator: CheckoutBranchWorkflowCoordinator?
    private var changed = false
    private var busy = false
    private var finished = false
    init(source: any RepositorySubmoduleManagingDataSource, path: String, completion: @escaping (Bool) -> Void) {
        self.source = source; self.path = path; self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        let root = NSView()
        details.isSelectable = true; details.maximumNumberOfLines = 0; details.font = AppSettingsStore.shared.fontPreferences.font(.monospace, fallback: .monospacedSystemFont(ofSize: 12, weight: .regular))
        let open = NSButton(title: "Open submodule", target: self, action: #selector(openRepository))
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(reload))
        let close = NSButton(title: "Close", target: self, action: #selector(closeForm)); close.keyEquivalent = "\u{1b}"
        checkout.target = self; checkout.action = #selector(checkoutBranch)
        stage.target = self; stage.action = #selector(stageCurrent); stage.keyEquivalent = "\r"
        let actions = NSStackView(views: [open, refresh, checkout, stage, close]); actions.spacing = 8
        let stack = NSStackView(views: [NSTextField(labelWithString: "There is a conflict on the submodule: \(path)"), details, status, actions])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        root.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12), stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12), details.widthAnchor.constraint(equalTo: stack.widthAnchor), status.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        view = root; reload()
    }
    @objc private func reload() {
        guard !busy else { return }
        Task { @MainActor in
            do {
                let value = try await source.loadSubmoduleConflict(path: path)
                guard !finished else { return }; context = value
                if initialContext == nil { initialContext = value }
                details.stringValue = "Base:     \(value.conflict.base?.objectID.string ?? "deleted")\n\nLocal:    \(value.conflict.local?.objectID.string ?? "deleted")\n\nRemote:   \(value.conflict.remote?.objectID.string ?? "deleted")\n\nCurrent:  \(value.currentID?.string ?? "")"
                checkout.isEnabled = value.conflict.base != nil && value.conflict.remote != nil && value.conflict.local != nil && value.currentID != nil
                stage.isEnabled = value.currentID != nil
            } catch { status.stringValue = error.localizedDescription; checkout.isEnabled = false; stage.isEnabled = false }
        }
    }
    @objc private func stageCurrent() {
        guard !busy else { return }; busy = true; stage.isEnabled = false; checkout.isEnabled = false
        Task { @MainActor in
            do {
                let result = try await source.performSubmoduleAction(.stageCurrent(path: path), output: { _ in })
                changed = changed || result.changed; busy = false
                if result.succeeded { finish(); return }
                status.stringValue = result.output
            } catch { status.stringValue = error.localizedDescription; busy = false }
            reload()
        }
    }
    @objc private func openRepository() {
        guard let context, context.currentID != nil else { return }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--repository", context.repositoryURL.path]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error { Task { @MainActor in self.status.stringValue = error.localizedDescription } }
        }
    }
    @objc private func checkoutBranch() {
        guard let panel, !busy else { return }
        Task { @MainActor in
            do {
                let value = try await source.loadSubmoduleConflictCheckout(path: path)
                guard let child = value.source as? any RepositoryCheckoutBranchDataSource else { return }
                guard !value.branches.branches.isEmpty || value.branches.remotes.contains(where: { !$0.branches.isEmpty }) else {
                    status.stringValue = "No branch contains both the local and remote commits. Open the submodule to resolve it, then Stage Current."; return
                }
                coordinator = CheckoutBranchWorkflowCoordinator(source: child,
                    stashSource: value.source as? any RepositoryStashDataSource, pullSource: value.source as? any RepositoryPullingDataSource,
                    context: value.branches, revisions: [], owner: panel,
                    onRepositoryChanged: { [weak self] _ in self?.reload() },
                    onStatus: { [weak self] in self?.status.stringValue = $0 },
                    onConflicts: { [weak self] in
                        guard let resolver = value.source as? any RepositoryConflictResolutionDataSource else { return }
                        Task { @MainActor in
                            let changed = await WorkflowManagementDialogs.resolveConflicts(source: resolver, window: panel, scriptHooks: self?.scriptHooks?(value.source))
                            if changed { self?.changed = true }; self?.reload()
                        }
                    },
                    onMerge: { _ in }, onRebase: { _ in },
                    onCheckoutCompleted: { [weak self] in self?.stageCurrent() })
                coordinator?.scriptHooks = scriptHooks?(value.source)
                coordinator?.checkoutBranch(initialTarget: nil)
            } catch { status.stringValue = error.localizedDescription }
        }
    }
    @objc private func closeForm() { if !busy { finish() } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { closeForm(); return false }
    private func finish() {
        guard !finished else { return }; finished = true; coordinator = nil
        Task { @MainActor in
            if let initialContext, let actualChange = try? await source.submoduleConflictChanged(since: initialContext) { changed = changed || actualChange }
            if let panel { panel.sheetParent?.endSheet(panel); panel.orderOut(nil) }
            completion(changed)
        }
    }
}

@MainActor
private final class SubmoduleManagerViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let source: any RepositorySubmoduleManagingDataSource
    private let changed: () -> Void
    private let open: (Submodule, Bool) -> Void
    private let closed: () -> Void
    private let table = NSTableView()
    private let split = NSSplitView()
    private let details = NSTextField(wrappingLabelWithString: "")
    private let output = NSTextField(wrappingLabelWithString: "")
    private var buttons: [NSButton] = []
    private var context: RepositorySubmoduleContext?
    private var busy = false
    private var operation: Task<Void, Never>?
    private var generation = 0

    init(source: any RepositorySubmoduleManagingDataSource, changed: @escaping () -> Void, open: @escaping (Submodule, Bool) -> Void, closed: @escaping () -> Void) {
        self.source = source; self.changed = changed; self.open = open; self.closed = closed
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        let root = NSView()
        for (name, width) in [("Name", 110.0), ("Status", 100.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name)); column.title = name; column.width = width; table.addTableColumn(column)
            column.minWidth = name == "Name" ? 60 : 100
            column.resizingMask = name == "Name" ? [.autoresizingMask, .userResizingMask] : [.userResizingMask]
        }
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self; table.delegate = self
        table.allowsMultipleSelection = false; table.rowSizeStyle = .medium
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        details.isSelectable = true; details.maximumNumberOfLines = 0
        let box = NSBox(); box.title = "Details"; box.contentView = details
        output.isSelectable = true; output.maximumNumberOfLines = 4
        split.isVertical = true; split.dividerStyle = .thin; split.autosaveName = "SubmodulesSplitter"
        split.addArrangedSubview(scroll); split.addArrangedSubview(box)
        let actions: [(String, Selector)] = [("Add submodule", #selector(add)), ("Update", #selector(update)), ("Synchronize", #selector(synchronize)), ("Pull", #selector(pull)), ("Remove", #selector(remove))]
        buttons = actions.map { NSButton(title: $0.0, target: self, action: $0.1) }
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshList))
        let bar = NSStackView(views: buttons + [refresh]); bar.spacing = 8
        for child in [split, output, bar] { root.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), split.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            split.topAnchor.constraint(equalTo: root.topAnchor, constant: 12), split.bottomAnchor.constraint(equalTo: output.topAnchor, constant: -8),
            scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 220), box.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            output.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), output.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            output.heightAnchor.constraint(equalToConstant: 34), output.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -8),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), bar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12), bar.heightAnchor.constraint(equalToConstant: 30)
        ])
        view = root; selectionChanged(); reload()
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        if UserDefaults.standard.object(forKey: "NSSplitView SubmodulesSplitter") == nil { split.setPosition(222, ofDividerAt: 0) }
    }
    func windowDidBecomeKey(_ notification: Notification) { if !busy, isViewLoaded { reload() } }
    private var selected: Submodule? {
        guard let modules = context?.submodules, modules.indices.contains(table.selectedRow) else { return nil }
        return modules[table.selectedRow]
    }
    func numberOfRows(in tableView: NSTableView) -> Int { context?.submodules.count ?? 0 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let module = context?.submodules[row] else { return nil }
        let field = NSTextField(labelWithString: tableColumn?.identifier.rawValue == "Name" ? module.name : status(module))
        field.lineBreakMode = .byTruncatingMiddle; field.toolTip = field.stringValue
        return field
    }
    private func status(_ module: Submodule) -> String {
        switch module.state { case .clean: "Up-to-date"; case .uninitialized: "Not initialized"; case .modified: "Modified"; case .conflicted: "Conflicted"; case .unknown: "Unknown" }
    }
    func tableViewSelectionDidChange(_ notification: Notification) { selectionChanged() }
    private func selectionChanged() {
        for (index, button) in buttons.enumerated() { button.isEnabled = !busy && (index == 0 || selected != nil) }
        if buttons.count > 3 { buttons[3].isEnabled = !busy && selected != nil && selected?.state != .uninitialized }
        guard let selected else { details.stringValue = ""; return }
        details.stringValue = "Name:  \(selected.name)\n\nRemote path:  \(selected.url ?? "")\n\nLocal path:  \(selected.path)\n\nCommit:  \(selected.commitID?.string ?? "")\n\nBranch:  \(context?.branches[selected.path] ?? "")\n\nStatus:  \(status(selected))"
    }
    private func reload() {
        generation += 1; let current = generation; let path = selected?.path
        Task { @MainActor in
            do {
                let loaded = try await source.loadSubmoduleContext()
                guard generation == current else { return }
                context = loaded; table.reloadData()
                if let index = loaded.submodules.firstIndex(where: { $0.path == path }) ?? loaded.submodules.indices.first {
                    table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                }
                selectionChanged()
            } catch { output.stringValue = error.localizedDescription }
        }
    }
    @objc private func refreshList() { if !busy { reload() } }
    @objc private func add() {
        guard let owner = view.window else { return }
        Task { @MainActor in await SubmoduleDialogs.add(source: source, owner: owner, changed: changed); reload() }
    }
    @objc private func update() { if let selected { perform(.update(path: selected.path)) } }
    @objc private func synchronize() { if let selected { perform(.synchronize(path: selected.path)) } }
    @objc private func pull() {
        if let selected { open(selected, true) }
    }
    @objc private func remove() {
        guard let selected, let owner = view.window else { return }
        Task { @MainActor in
            let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "Remove submodule?"
            alert.informativeText = "Are you sure you want to remove the selected submodule ‘\(selected.path)’?\nThe directory will remain on disk."
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Remove")
            if await alert.beginSheetModal(for: owner) == .alertSecondButtonReturn { perform(.remove(path: selected.path)) }
        }
    }
    private func perform(_ action: RepositorySubmoduleAction) {
        guard !busy, let owner = view.window else { return }; busy = true; selectionChanged(); output.stringValue = ""
        operation = Task { @MainActor in
            let source = self.source
            let result = await SubmoduleDialogs.run(title: "Submodules", owner: owner) { output in try await source.performSubmoduleAction(action, output: output) }
            if result.changed { changed() }
            output.stringValue = result.output.isEmpty ? "Completed." : result.output
            busy = false; selectionChanged(); reload()
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if busy { operation?.cancel(); return false }; return true }
    func windowWillClose(_ notification: Notification) { generation += 1; operation?.cancel(); closed() }
}

@MainActor
private final class AddSubmoduleViewController: NSViewController, NSTextFieldDelegate, NSComboBoxDelegate, NSWindowDelegate {
    weak var panel: NSPanel?
    private let source: any RepositorySubmoduleManagingDataSource
    private let changed: () -> Void
    private let completion: () -> Void
    private let remote = NSComboBox()
    private let path = NSTextField()
    private let branch = NSComboBox()
    private let force = NSButton(checkboxWithTitle: "Force", target: nil, action: nil)
    private let add = NSButton(title: "Add", target: nil, action: nil)
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private let output = NSTextField(wrappingLabelWithString: "")
    private var busy = false
    private var completed = false
    private var operation: Task<Void, Never>?
    private var branchLoad: Task<Void, Never>?
    init(source: any RepositorySubmoduleManagingDataSource, changed: @escaping () -> Void, completion: @escaping () -> Void) {
        self.source = source; self.changed = changed; self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        let root = NSView(); remote.delegate = self; branch.delegate = self
        let settings = AppSettingsStore.shared
        var seen: Set<String> = []
        remote.addItems(withObjectValues: (settings.repositoryCreationPreferences.recentSources + settings.pullPreferences.recentURLs + settings.pushPreferences.recentURLs).filter { seen.insert($0).inserted })
        let browse = NSButton(title: "Browse…", target: self, action: #selector(browseSource))
        let sourceRow = NSStackView(views: [remote, browse]); sourceRow.spacing = 8
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Path to submodule"), sourceRow], [NSTextField(labelWithString: "Local path"), path], [NSTextField(labelWithString: "Branch"), branch]])
        grid.columnSpacing = 12; grid.rowSpacing = 8
        add.target = self; add.action = #selector(accept); add.keyEquivalent = "\r"
        cancel.target = self; cancel.action = #selector(cancelForm); cancel.keyEquivalent = "\u{1b}"
        let bar = NSStackView(views: [force, cancel, add]); bar.spacing = 10
        output.maximumNumberOfLines = 3; output.isSelectable = true
        let stack = NSStackView(views: [grid, output, bar]); stack.orientation = .vertical; stack.alignment = .trailing; stack.spacing = 10
        root.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12), stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12), grid.widthAnchor.constraint(equalTo: stack.widthAnchor), output.widthAnchor.constraint(equalTo: stack.widthAnchor), remote.widthAnchor.constraint(greaterThanOrEqualToConstant: 250)])
        view = root
    }
    override func viewDidAppear() { super.viewDidAppear(); panel?.makeFirstResponder(remote) }
    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSComboBox === remote {
            let name = GitSubmoduleCommands.directoryName(from: remote.stringValue)
            if !name.isEmpty { path.stringValue = name }
            branchLoad?.cancel()
        }
    }
    func comboBoxWillPopUp(_ notification: Notification) {
        guard notification.object as? NSComboBox === branch else { return }
        let value = remote.stringValue
        branchLoad?.cancel()
        branchLoad = Task { @MainActor in
            let names = (try? await source.submoduleBranches(source: value)) ?? []
            guard !Task.isCancelled, remote.stringValue == value else { return }
            branch.removeAllItems(); branch.addItems(withObjectValues: names)
        }
    }
    @objc private func browseSource() {
        guard let panel else { return }
        let picker = NSOpenPanel(); picker.canChooseFiles = false; picker.canChooseDirectories = true
        picker.beginSheetModal(for: panel) { [weak self] response in
            guard response == .OK, let url = picker.url, let self else { return }
            self.remote.stringValue = url.path
            self.path.stringValue = GitSubmoduleCommands.directoryName(from: url.path)
        }
    }
    @objc private func accept() {
        guard !busy, let panel else { return }
        guard !remote.stringValue.isEmpty, !path.stringValue.isEmpty else {
            output.stringValue = "A remote path and local path are required."
            panel.makeFirstResponder(remote.stringValue.isEmpty ? remote : path)
            return
        }
        busy = true; add.isEnabled = false; remote.isEnabled = false; path.isEnabled = false; branch.isEnabled = false; force.isEnabled = false
        let request = RepositoryAddSubmoduleRequest(source: remote.stringValue, path: path.stringValue, branch: branch.stringValue, force: force.state == .on)
        operation = Task { @MainActor in
            let source = self.source
            let result = await SubmoduleDialogs.run(title: "Add submodule", owner: panel) { output in try await source.addSubmodule(request, output: output) }
            if result.changed { changed() }
            if result.succeeded { busy = false; finish(); return }
            output.stringValue = result.output
            busy = false; add.isEnabled = true; remote.isEnabled = true; path.isEnabled = true; branch.isEnabled = true; force.isEnabled = true
        }
    }
    @objc private func cancelForm() { if busy { operation?.cancel() } else { finish() } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancelForm(); return false }
    private func finish() { guard !completed else { return }; completed = true; branchLoad?.cancel(); if let panel { panel.sheetParent?.endSheet(panel); panel.orderOut(nil) }; completion() }
}
