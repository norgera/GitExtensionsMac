import AppKit
import GitCommands
import GitExtensionsCore

enum PatchDialogMode { case format, apply, view }

@MainActor
final class PatchWindowController: NSWindowController, NSWindowDelegate {
    private let content: PatchViewController
    private let closed: () -> Void

    init(mode: PatchDialogMode, source: (any RepositoryPatchingDataSource)?, revisions: [Commit],
         selected: [RevisionID], currentBranch: String? = nil, initialFile: URL? = nil, viewPatch: @escaping (URL) -> Void, changed: @escaping () -> Void,
         conflicts: @escaping (NSWindow) async -> Bool,
         closed: @escaping () -> Void) {
        self.closed = closed
        content = PatchViewController(mode: mode, source: source, revisions: revisions, selected: selected,
                                      currentBranch: currentBranch, initialFile: initialFile, viewPatch: viewPatch, changed: changed, conflicts: conflicts)
        let window = NSWindow(contentViewController: content)
        window.title = mode == .format ? "Format patch" : mode == .apply ? "Apply patch" : "View patch file"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(mode == .format ? NSSize(width: 1030, height: 665) : NSSize(width: 760, height: 520))
        window.minSize = NSSize(width: 640, height: 410)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("Patch.\(mode)")
        super.init(window: window)
        window.delegate = self
    }
    required init?(coder: NSCoder) { nil }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !content.isBusy }
    func windowWillClose(_ notification: Notification) { closed() }
}

@MainActor
private final class PatchViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let mode: PatchDialogMode
    let source: (any RepositoryPatchingDataSource)?
    let revisions: [Commit]
    let selected: [RevisionID]
    let currentBranch: String?
    let changed: () -> Void
    let conflicts: (NSWindow) async -> Bool
    let initialFile: URL?
    let viewPatch: (URL) -> Void
    private let path = NSTextField(string: "")
    private let directoryMode = NSButton(checkboxWithTitle: "Patch directory", target: nil, action: nil)
    private let ignoreWhitespace = NSButton(checkboxWithTitle: "Ignore whitespace", target: nil, action: nil)
    private let signOff = NSButton(checkboxWithTitle: "Sign-Off", target: nil, action: nil)
    private let keepOpen = NSButton(checkboxWithTitle: "Keep dialog open", target: nil, action: nil)
    private let table = NSTableView()
    private let viewer = DiffContentViewController()
    private let revisionGrid = RevisionGridViewController()
    private let transcript = NSTextView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var buttons: [String: NSButton] = [:]
    private var preview: PatchPreview?
    private var operation: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var previewGeneration = 0
    private var patchState: RepositoryPatchState?
    private var completedApply = false
    private static var sessionSkippedNumbers: Set<Int> = []
    private var skippedNumbers: Set<Int> {
        get { Self.sessionSkippedNumbers }
        set { Self.sessionSkippedNumbers = newValue }
    }
    var isBusy: Bool { operation != nil }

    init(mode: PatchDialogMode, source: (any RepositoryPatchingDataSource)?, revisions: [Commit], selected: [RevisionID],
         currentBranch: String?, initialFile: URL?, viewPatch: @escaping (URL) -> Void,
         changed: @escaping () -> Void, conflicts: @escaping (NSWindow) async -> Bool) {
        self.mode = mode; self.source = source; self.revisions = revisions; self.selected = selected
        self.currentBranch = currentBranch
        self.changed = changed; self.conflicts = conflicts
        self.initialFile = initialFile; self.viewPatch = viewPatch
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
        path.placeholderString = mode == .format ? "Output directory" : "Patch file"
        path.target = self; path.action = #selector(loadPreview)
        path.delegate = self
        let browse = button("Browse…", key: "browse", action: #selector(browse))
        let pathRow = NSStackView(views: [NSTextField(labelWithString: mode == .format ? "Output path:" : "Patch:"), path, browse])
        stack.addArrangedSubview(pathRow)
        pathRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        if mode == .apply {
            ignoreWhitespace.state = UserDefaults.standard.bool(forKey: "ApplyPatchIgnoreWhitespace") ? .on : .off
            signOff.state = (UserDefaults.standard.object(forKey: "ApplyPatchSignOff") as? Bool ?? true) ? .on : .off
            for control in [directoryMode, ignoreWhitespace, signOff] {
                control.target = self; control.action = #selector(optionsChanged)
            }
            stack.addArrangedSubview(NSStackView(views: [directoryMode, ignoreWhitespace, signOff]))
        }
        if mode == .format {
            path.stringValue = UserDefaults.standard.string(forKey: "LastFormatPatchDir") ?? ""
            stack.addArrangedSubview(NSTextField(labelWithString: "Current branch: \(currentBranch ?? "(detached HEAD)")"))
            addChild(revisionGrid)
            stack.addArrangedSubview(revisionGrid.view)
            revisionGrid.view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            revisionGrid.beginIncrementalLoad()
            revisionGrid.appendIncrementalBatch(revisions.filter { !$0.isArtificial })
            revisionGrid.selectCommits(ids: selected)
        } else {
            for (key, title, width) in mode == .apply
                ? [("status", "Status", 80.0), ("number", "File", 45.0), ("subject", "Subject", 300.0), ("author", "Author", 140.0), ("date", "Date", 150.0)]
                : [("file", "Filename", 450.0), ("change", "Change", 90.0), ("type", "Type", 65.0)] {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
                column.title = title; column.width = width
                column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
                table.addTableColumn(column)
            }
            table.delegate = self; table.dataSource = self
            table.target = self; table.doubleAction = #selector(openSeriesPatch)
            let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
            stack.addArrangedSubview(scroll)
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            scroll.heightAnchor.constraint(equalToConstant: 100).isActive = true
            addChild(viewer); viewer.supportedFileCommands = []
            stack.addArrangedSubview(viewer.view)
            viewer.view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            viewer.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        }
        if mode == .apply {
            transcript.isEditable = false; transcript.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            let output = NSScrollView(); output.documentView = transcript; output.hasVerticalScroller = true
            stack.addArrangedSubview(output)
            output.heightAnchor.constraint(equalToConstant: 70).isActive = true
            output.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            keepOpen.state = AppSettingsStore.shared.pullPreferences.closeProcessOnSuccess ? .off : .on
            keepOpen.target = self; keepOpen.action = #selector(keepOpenChanged)
            stack.addArrangedSubview(keepOpen)
        }
        stack.addArrangedSubview(status)
        status.maximumNumberOfLines = 2
        status.lineBreakMode = .byTruncatingTail
        status.heightAnchor.constraint(lessThanOrEqualToConstant: 34).isActive = true
        status.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let actions: [NSButton]
        switch mode {
        case .format: actions = [button("Create patch(es)", key: "format", action: #selector(format))]
        case .view: actions = []
        case .apply:
            actions = [button("Apply patch", key: "apply", action: #selector(apply)),
                       button("Conflicts resolved", key: "resolved", action: #selector(resolved)),
                       button("Skip patch", key: "skip", action: #selector(skip)),
                       button("Abort patch", key: "abort", action: #selector(abort)),
                       button("Solve conflicts", key: "conflicts", action: #selector(resolveConflicts)),
                       button("Add files", key: "add", action: #selector(stageFiles))]
        }
        for start in stride(from: 0, to: actions.count, by: 3) {
            let actionRow = NSStackView(views: Array(actions[start..<min(start + 3, actions.count)]))
            actionRow.distribution = .fillProportionally
            stack.addArrangedSubview(actionRow)
        }
        let close = button("Close", key: "close", action: #selector(close))
        close.keyEquivalent = "\u{1b}"
        stack.addArrangedSubview(close)
        view = root
        if let initialFile { path.stringValue = initialFile.path; loadPreview() }
        updateButtons()
        if mode == .apply { Task { await reloadState() } }
    }

    private func button(_ title: String, key: String, action: Selector) -> NSButton {
        let result = NSButton(title: title, target: self, action: action)
        buttons[key] = result
        return result
    }
    private func updateButtons() {
        let active = patchState?.isApplying == true
        for button in buttons.values { button.isEnabled = !isBusy; button.keyEquivalent = "" }
        buttons["close"]?.title = isBusy ? "Cancel operation" : "Close"
        buttons["close"]?.isEnabled = true
        buttons["close"]?.keyEquivalent = "\u{1b}"
        path.isEnabled = !isBusy && !active
        [directoryMode, ignoreWhitespace, signOff].forEach { $0.isEnabled = !isBusy && !active }
        buttons["browse"]?.isEnabled = !isBusy && !active
        buttons["apply"]?.isEnabled = !isBusy && !active
        for key in ["resolved", "skip", "abort", "add"] { buttons[key]?.isEnabled = !isBusy && active }
        buttons["resolved"]?.isEnabled = !isBusy && active && patchState?.hasConflicts == false
        buttons["conflicts"]?.isEnabled = !isBusy && patchState?.hasConflicts == true
        let defaultKey = mode == .format ? "format" : active ? (patchState?.hasConflicts == true ? "conflicts" : "resolved") : "apply"
        if !isBusy { buttons[defaultKey]?.keyEquivalent = "\r" }
    }
    @objc private func optionsChanged() {
        UserDefaults.standard.set(ignoreWhitespace.state == .on, forKey: "ApplyPatchIgnoreWhitespace")
        UserDefaults.standard.set(signOff.state == .on, forKey: "ApplyPatchSignOff")
        path.placeholderString = directoryMode.state == .on ? "Patch directory" : "Patch file"
    }
    @objc private func keepOpenChanged() {
        var preferences = AppSettingsStore.shared.pullPreferences
        preferences.closeProcessOnSuccess = keepOpen.state == .off
        AppSettingsStore.shared.savePullPreferences(preferences)
        if completedApply && keepOpen.state == .off { view.window?.close() }
    }
    @objc private func browse() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = mode == .format || directoryMode.state == .on
        panel.canChooseFiles = !panel.canChooseDirectories
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.path.stringValue = url.path
            if self.mode == .format { UserDefaults.standard.set(url.path, forKey: "LastFormatPatchDir") }
            else if self.directoryMode.state != .on { self.loadPreview() }
        }
    }
    @objc private func loadPreview() {
        guard mode != .format, directoryMode.state != .on, !path.stringValue.isEmpty else { return }
        previewTask?.cancel(); previewGeneration += 1
        preview = nil; table.reloadData(); viewer.view.isHidden = true
        let generation = previewGeneration
        let url = URL(fileURLWithPath: (path.stringValue as NSString).expandingTildeInPath)
        previewTask = Task { [weak self] in
            guard let self else { return }
            do {
                let preview = try await PatchPreviewParser.load(url)
                guard !Task.isCancelled, generation == previewGeneration else { return }
                self.preview = preview; table.reloadData()
                if !preview.files.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); showSelectedFile() }
            } catch { if generation == previewGeneration { status.stringValue = error.localizedDescription } }
        }
    }
    func controlTextDidChange(_ notification: Notification) {
        guard mode == .format else { return }
        let value = (path.stringValue as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: value, isDirectory: &isDirectory), isDirectory.boolValue {
            UserDefaults.standard.set(value, forKey: "LastFormatPatchDir")
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int {
        mode == .apply && patchState?.isApplying == true ? patchState?.series.count ?? 0 : preview?.files.count ?? 0
    }
    private var seriesRows: [RepositoryPatchEntry] {
        ordered(patchState?.series ?? []) { entry, key in
            switch key {
            case "status": return skippedNumbers.contains(entry.number) ? "Skipped" : entry.status.rawValue
            case "number": return entry.file.lastPathComponent
            case "author": return entry.author
            case "date": return entry.date
            default: return entry.subject
            }
        }
    }
    private var fileRows: [ChangedFile] {
        ordered(preview?.files ?? []) { file, key in
            switch key {
            case "change": return preview?.metadata[file.id]?.change.rawValue ?? ""
            case "type": return preview?.metadata[file.id]?.fileType.rawValue ?? ""
            default: return file.oldPath ?? file.path
            }
        }
    }
    private func ordered<T>(_ values: [T], field: (T, String) -> String) -> [T] {
        guard let descriptor = table.sortDescriptors.first, let key = descriptor.key else { return values }
        return values.enumerated().sorted { a, b in
            let first = field(a.element, key); let second = field(b.element, key)
            let order = mode == .view ? first.compare(second, options: .literal) : first.localizedCompare(second)
            if order == .orderedSame { return a.offset < b.offset }
            return descriptor.ascending ? order == .orderedAscending : order == .orderedDescending
        }.map(\.element)
    }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        table.reloadData()
        if numberOfRows(in: table) > 0 {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            showSelectedFile()
        }
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if mode == .apply, let state = patchState, state.isApplying, state.series.indices.contains(row) {
            let entry = seriesRows[row]
            let text: String
            switch tableColumn?.identifier.rawValue {
            case "status": text = skippedNumbers.contains(entry.number) ? "Skipped" : entry.status.rawValue
            case "number": text = entry.file.lastPathComponent
            case "author": text = entry.author
            case "date": text = entry.date
            default: text = entry.subject
            }
            return NSTextField(labelWithString: text)
        }
        guard fileRows.indices.contains(row) else { return nil }
        let file = fileRows[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "change": text = preview?.metadata[file.id]?.change.rawValue ?? ""
        case "type": text = preview?.metadata[file.id]?.fileType.rawValue ?? ""
        default: text = file.oldPath ?? file.path
        }
        return NSTextField(labelWithString: text)
    }
    func tableViewSelectionDidChange(_ notification: Notification) { showSelectedFile() }
    @objc private func openSeriesPatch() {
        guard mode == .apply, let state = patchState, state.isApplying,
              state.series.indices.contains(table.selectedRow) else { return }
        viewPatch(seriesRows[table.selectedRow].file)
    }
    private func showSelectedFile() {
        if mode == .apply, let state = patchState, state.isApplying, state.series.indices.contains(table.selectedRow) {
            let entry = seriesRows[table.selectedRow]
            previewTask?.cancel()
            previewTask = Task {
                do {
                    let content = try await PatchPreviewParser.load(entry.file)
                    guard !Task.isCancelled, let file = content.files.first else { return }
                    viewer.view.isHidden = false
                    viewer.apply(file: file, diff: content.diffs[file.id])
                } catch { if !Task.isCancelled { status.stringValue = error.localizedDescription } }
            }
            return
        }
        guard let preview, preview.files.indices.contains(table.selectedRow) else { return }
        let file = fileRows[table.selectedRow]
        viewer.view.isHidden = false
        viewer.apply(file: file, diff: preview.diffs[file.id])
    }
    @objc private func format() {
        guard let source else { return }
        let ids = Set(revisionGrid.selectedRevisionIDs)
        let chosen = revisions.filter { ids.contains($0.id) }.reversed().compactMap { commit in
            commit.objectID.map { PatchRevision(id: $0, firstParent: commit.parentIDs.first) }
        }
        guard !path.stringValue.isEmpty, !chosen.isEmpty else { status.stringValue = "Select at least one revision and an output directory."; return }
        let url = URL(fileURLWithPath: (path.stringValue as NSString).expandingTildeInPath)
        operation = Task {
            do {
                let output = try await source.formatPatches(chosen, outputDirectory: url)
                operation = nil; updateButtons()
                guard !output.isEmpty else {
                    status.stringValue = "Failed to create patch. Select revisions with changes to export."
                    return
                }
                let alert = NSAlert(); alert.messageText = "Patch result"; alert.informativeText = output
                if let window = view.window { await alert.beginSheetModal(for: window); window.close() }
            } catch { status.stringValue = error.localizedDescription; operation = nil; updateButtons() }
        }
        updateButtons()
    }
    @objc private func apply() {
        guard let source else { return }
        guard !path.stringValue.isEmpty else { status.stringValue = "Please select a patch to apply."; return }
        let url = URL(fileURLWithPath: (path.stringValue as NSString).expandingTildeInPath)
        let input: PatchInput = directoryMode.state == .on ? .directory(url) : .file(url)
        let sign = signOff.state == .on; let ignore = ignoreWhitespace.state == .on
        skippedNumbers = []
        run(closeOnSuccess: true) { [source] output in try await source.applyPatches(input, signOff: sign, ignoreWhitespace: ignore, output: output) }
    }
    @objc private func resolved() { continueWith(.resolved) }
    @objc private func skip() { if let next = patchState?.next { skippedNumbers.insert(next) }; continueWith(.skip) }
    @objc private func abort() { skippedNumbers = []; continueWith(.abort) }
    private func continueWith(_ action: PatchContinuation) {
        guard let source else { return }
        run { [source] output in try await source.continuePatches(action, output: output) }
    }
    private func run(closeOnSuccess: Bool = false, _ action: @escaping (@escaping GitOutputHandler) async throws -> RepositoryPatchResult) {
        transcript.string = ""
        completedApply = false
        operation = Task {
            do {
                let result = try await action { [weak self] event in
                    Task { @MainActor in self?.transcript.textStorage?.append(NSAttributedString(string: event.text,
                        attributes: [.foregroundColor: NSColor.textColor, .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)])) }
                }
                patchState = result.state
                refreshSeries()
                status.stringValue = result.output
                if result.changed { changed() }
                operation = nil; updateButtons()
                completedApply = closeOnSuccess && result.succeeded && !result.state.isApplying
                if completedApply && keepOpen.state == .off { view.window?.close() }
            } catch { status.stringValue = error.localizedDescription; operation = nil; updateButtons() }
        }
        updateButtons()
    }
    private func reloadState() async {
        guard let source else { return }
        do { patchState = try await source.loadPatchState() }
        catch { status.stringValue = error.localizedDescription }
        refreshSeries()
        updateButtons()
    }
    private func refreshSeries() {
        table.reloadData()
        if let row = seriesRows.firstIndex(where: { $0.status == .applying }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            showSelectedFile()
        }
    }
    @objc private func resolveConflicts() {
        guard let window = view.window else { return }
        operation = Task {
            if await conflicts(window) { changed() }
            operation = nil; await reloadState()
        }
        updateButtons()
    }
    @objc private func stageFiles() {
        guard let window = view.window, let source else { return }
        Task {
            let alert = NSAlert()
            alert.messageText = "Add files"
            alert.informativeText = "Enter one path or Git pathspec per line."
            alert.addButton(withTitle: "Add files")
            alert.addButton(withTitle: "Show files")
            alert.addButton(withTitle: "Cancel")
            let paths = NSTextView(frame: NSRect(x: 0, y: 30, width: 380, height: 85))
            paths.string = "."
            paths.isRichText = false
            let force = NSButton(checkboxWithTitle: "Force", target: nil, action: nil)
            force.frame = NSRect(x: 0, y: 0, width: 180, height: 24)
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 120))
            content.addSubview(paths); content.addSubview(force); alert.accessoryView = content
            while true {
                let answer = await alert.beginSheetModal(for: window)
                guard answer == .alertFirstButtonReturn || answer == .alertSecondButtonReturn else { return }
                do {
                    let result = try await source.addPatchFiles(paths.string.components(separatedBy: .newlines).filter { !$0.isEmpty },
                                                               force: force.state == .on, preview: answer == .alertSecondButtonReturn)
                    status.stringValue = result.output
                    if result.changed { changed() }
                    await reloadState()
                    if answer == .alertFirstButtonReturn && result.succeeded { return }
                    await MutationDialogs.showInformation(result.output, title: "Add files", window: window)
                } catch { await MutationDialogs.showError(error, title: "Add files", window: window) }
            }
        }
    }
    @objc private func close() {
        if let operation { operation.cancel() }
        else { previewTask?.cancel(); view.window?.close() }
    }
}
