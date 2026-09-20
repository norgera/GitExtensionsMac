import GitExtensionsCore
import GitCommands
import AppKit

enum WorktreePresentation {
    static func displayPaths(_ worktrees: [Worktree]) -> [String: String] {
        guard let main = worktrees.first else { return [:] }
        let parent = URL(fileURLWithPath: main.path).deletingLastPathComponent().pathComponents
        let relative = worktrees.map { item -> String in
            let target = URL(fileURLWithPath: item.path).pathComponents
            let common = zip(parent, target).prefix(while: { $0 == $1 }).count
            return (Array(repeating: "..", count: parent.count - common) + target.dropFirst(common)).joined(separator: "/")
        }
        let siblings = Array(relative.dropFirst())
        var prefix = siblings.first ?? ""
        for path in siblings.dropFirst() { prefix = String(zip(prefix, path).prefix(while: { $0.lowercased() == $1.lowercased() }).map(\.0)) }
        let separators: Set<Character> = siblings.contains(where: { $0.contains("/") }) ? ["/"] : ["/", "_", "-", ".", " "]
        if siblings.count < 2 { prefix = "" }
        else if let index = prefix.lastIndex(where: { separators.contains($0) }) { prefix = String(prefix[...index]) }
        else { prefix = "" }
        return Dictionary(uniqueKeysWithValues: zip(worktrees.indices, worktrees).map { index, item in
            (item.path, index > 0 ? String(relative[index].dropFirst(prefix.count)) : relative[index])
        })
    }
}

@MainActor
enum WorktreeDialogs {
    static func create(context: RepositoryWorktreeContext, owner: NSWindow,
                       execute: @escaping (RepositoryCreateWorktreeRequest, @escaping GitOutputHandler) async throws -> RepositoryWorktreeResult) async -> String? {
        await withCheckedContinuation { continuation in
            let controller = CreateWorktreeViewController(context: context, execute: execute) { continuation.resume(returning: $0) }
            let panel = NSPanel(contentViewController: controller)
            panel.title = "Create a new worktree"
            panel.styleMask = [.titled, .closable, .resizable]
            panel.setContentSize(NSSize(width: 608, height: 270))
            panel.minSize = NSSize(width: 608, height: 270)
            controller.panel = panel
            owner.beginSheet(panel)
        }
    }

    static func manage(source: any RepositoryWorktreeManagingDataSource, owner: NSWindow,
                       create: @escaping (NSWindow) async -> Void,
                       delete: @escaping (Worktree, NSWindow) async -> Void,
                       prune: @escaping (NSWindow) async -> Void,
                       open: @escaping (Worktree, NSWindow) -> Bool,
                       closed: @escaping () -> Void) -> NSWindowController {
        let controller = ManageWorktreesViewController(source: source, create: create, delete: delete, prune: prune, open: open, closed: closed)
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Existing worktrees"
        window.setContentSize(NSSize(width: 697, height: 361))
        window.minSize = NSSize(width: 710, height: 200)
        window.isReleasedWhenClosed = false
        controller.window = window
        window.delegate = controller
        let result = NSWindowController(window: window)
        window.setFrameOrigin(NSPoint(x: owner.frame.midX - window.frame.width / 2, y: owner.frame.midY - window.frame.height / 2))
        result.showWindow(nil)
        return result
    }
}

@MainActor
private final class CreateWorktreeViewController: NSViewController, NSTextFieldDelegate, NSWindowDelegate {
    weak var panel: NSPanel?
    let context: RepositoryWorktreeContext
    let execute: (RepositoryCreateWorktreeRequest, @escaping GitOutputHandler) async throws -> RepositoryWorktreeResult
    let completion: (String?) -> Void
    private let existing = NSButton(radioButtonWithTitle: "Checkout an existing branch:", target: nil, action: nil)
    private let new = NSButton(radioButtonWithTitle: "Create a new branch:\n(from current commit)", target: nil, action: nil)
    private let branches = NSPopUpButton()
    private let name = NSTextField()
    private let path = NSTextField()
    private let create = NSButton(title: "Create the new worktree", target: nil, action: nil)
    private let output = NSTextField(wrappingLabelWithString: "")
    private var busy = false
    private var completed = false
    private var operation: Task<Void, Never>?

    init(context: RepositoryWorktreeContext, execute: @escaping (RepositoryCreateWorktreeRequest, @escaping GitOutputHandler) async throws -> RepositoryWorktreeResult, completion: @escaping (String?) -> Void) {
        self.context = context; self.execute = execute; self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        let root = NSView()
        output.maximumNumberOfLines = 4
        output.isSelectable = true
        branches.addItems(withTitles: context.availableBranches)
        existing.isEnabled = !context.availableBranches.isEmpty
        existing.state = existing.isEnabled ? .on : .off
        new.state = existing.isEnabled ? .off : .on
        for button in [existing, new] { button.target = self; button.action = #selector(modeChanged(_:)) }
        branches.target = self; branches.action = #selector(branchChanged)
        name.delegate = self; path.delegate = self
        let browse = NSButton(title: "Browse…", target: self, action: #selector(browsePath))
        create.target = self; create.action = #selector(accept); create.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelForm)); cancel.keyEquivalent = "\u{1b}"
        let grid = NSGridView(views: [[existing, branches], [new, name]])
        grid.rowSpacing = 10; grid.columnSpacing = 12
        let box = NSBox(); box.title = "What to checkout:"; box.contentView = grid
        let directory = NSStackView(views: [NSTextField(labelWithString: "New worktree directory:"), path, browse])
        directory.spacing = 8
        let buttons = NSStackView(views: [cancel, create]); buttons.spacing = 8
        let stack = NSStackView(views: [box, directory, output, buttons])
        stack.orientation = .vertical; stack.alignment = .trailing; stack.spacing = 12
        root.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12), stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -12),
            box.widthAnchor.constraint(equalTo: stack.widthAnchor), directory.widthAnchor.constraint(equalTo: stack.widthAnchor),
            output.widthAnchor.constraint(equalTo: stack.widthAnchor), name.widthAnchor.constraint(greaterThanOrEqualToConstant: 280)
        ])
        view = root; updatePath()
    }
    override func viewDidAppear() { super.viewDidAppear(); panel?.delegate = self; panel?.makeFirstResponder(existing.isEnabled ? branches : name) }
    @objc private func modeChanged(_ sender: NSButton) { existing.state = sender === existing ? .on : .off; new.state = sender === new ? .on : .off; updatePath() }
    @objc private func branchChanged() { updatePath() }
    private var branch: String { new.state == .on ? name.stringValue : branches.titleOfSelectedItem ?? "" }
    private func updatePath() { path.stringValue = RepositoryWorktreePaths.destination(basePath: context.basePath, branch: branch); validate() }
    private func validate() {
        branches.isEnabled = !busy && existing.state == .on
        name.isEnabled = !busy && new.state == .on
        create.isEnabled = !busy && !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (new.state != .on || !context.branches.contains(branch))
            && RepositoryWorktreePaths.isEmptyDestination((path.stringValue as NSString).expandingTildeInPath)
    }
    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSTextField === name { updatePath() } else { validate() }
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        if obj.object as? NSTextField === name { normalizeName() }
    }
    private func normalizeName() {
        let previous = name.stringValue
        let preferences = AppSettingsStore.shared.checkoutBranchPreferences
        if preferences.autoNormaliseBranchName {
            name.stringValue = RepositoryBranchNameNormalizer.normalize(name.stringValue, replacementToken: preferences.branchNameReplacement)
        }
        if previous != name.stringValue { updatePath() } else { validate() }
    }
    @objc private func browsePath() {
        guard let panel else { return }
        let picker = NSOpenPanel(); picker.canChooseFiles = false; picker.canChooseDirectories = true; picker.canCreateDirectories = true
        picker.beginSheetModal(for: panel) { [weak self] response in
            if response == .OK, let url = picker.url { self?.path.stringValue = url.path; self?.validate() }
        }
    }
    @objc private func accept() {
        if new.state == .on { normalizeName() }
        guard create.isEnabled else { return }
        let request = RepositoryCreateWorktreeRequest(path: path.stringValue, branch: branch, createBranch: new.state == .on)
        busy = true; validate(); output.stringValue = "Creating worktree…"
        operation = Task { @MainActor in
            do {
                let result = try await execute(request) { [weak self] event in
                    Task { @MainActor in
                        guard let self, self.busy else { return }
                        self.output.stringValue += event.text
                        self.output.toolTip = self.output.stringValue
                    }
                }
                if result.succeeded { finish((request.path as NSString).expandingTildeInPath); return }
                output.stringValue = result.output
            } catch { output.stringValue = error.localizedDescription }
            busy = false; validate()
        }
    }
    @objc private func cancelForm() {
        if busy { operation?.cancel(); output.stringValue = "Cancelling…" }
        else { finish(nil) }
    }
    override func cancelOperation(_ sender: Any?) { cancelForm() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancelForm(); return false }
    private func finish(_ path: String?) {
        guard !completed else { return }; completed = true
        if let panel { panel.sheetParent?.endSheet(panel); panel.orderOut(nil) }
        completion(path)
    }
}

@MainActor
private final class ManageWorktreesViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    weak var window: NSWindow?
    let source: any RepositoryWorktreeManagingDataSource
    let createAction: (NSWindow) async -> Void
    let deleteAction: (Worktree, NSWindow) async -> Void
    let pruneAction: (NSWindow) async -> Void
    let openAction: (Worktree, NSWindow) -> Bool
    let closed: () -> Void
    private let table = WorktreeTableView()
    private let status = NSTextField(labelWithString: "")
    private let create = NSButton(title: "Create…", target: nil, action: nil)
    private let prune = NSButton(title: "Prune deleted worktrees", target: nil, action: nil)
    private let delete = NSButton(title: "Delete selected", target: nil, action: nil)
    private let open = NSButton(title: "Open selected", target: nil, action: nil)
    private var worktrees: [Worktree] = []
    private var busy = false

    init(source: any RepositoryWorktreeManagingDataSource, create: @escaping (NSWindow) async -> Void, delete: @escaping (Worktree, NSWindow) async -> Void, prune: @escaping (NSWindow) async -> Void, open: @escaping (Worktree, NSWindow) -> Bool, closed: @escaping () -> Void) {
        self.source = source; createAction = create; deleteAction = delete; pruneAction = prune; openAction = open; self.closed = closed
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidAppear() { super.viewDidAppear(); window?.makeFirstResponder(table) }
    override func loadView() {
        let root = NSView()
        for (key, title, width) in [("path", "Path", 280.0), ("type", "Type", 70.0), ("branch", "Branch", 165.0), ("sha", "SHA-1", 90.0)] {
            let column = NSTableColumn(identifier: .init(key)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self; table.rowHeight = 30; table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false; table.target = self; table.doubleAction = #selector(openSelected)
        table.onReturn = { [weak self] in self?.openSelected() }
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        for (button, action) in [(create, #selector(createWorktree)), (prune, #selector(pruneWorktrees)), (delete, #selector(deleteSelected)), (open, #selector(openSelected))] { button.target = self; button.action = action }
        let buttons = NSStackView(views: [create, prune, delete, open]); buttons.spacing = 8
        let stack = NSStackView(views: [scroll, status, buttons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        root.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 8), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)
        ])
        view = root; reload()
    }
    private var selected: Worktree? { worktrees.indices.contains(table.selectedRow) ? worktrees[table.selectedRow] : nil }
    func numberOfRows(in tableView: NSTableView) -> Int { worktrees.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = worktrees[row]
        let value: String = switch tableColumn?.identifier.rawValue {
        case "path": item.path
        case "type": item.headType
        case "branch": item.isBare || item.isDetached ? "" : item.branchName
        default: item.headID?.string ?? ""
        }
        let cell = NSTextField(labelWithString: value); cell.toolTip = value; cell.lineBreakMode = .byTruncatingMiddle
        if tableColumn?.identifier.rawValue == "sha" { cell.font = AppSettingsStore.shared.fontPreferences.font(.monospace, fallback: .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)) }
        if item.isDeleted { cell.attributedStringValue = NSAttributedString(string: value, attributes: [.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.secondaryLabelColor]) }
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
    private func updateButtons() {
        create.isEnabled = !busy
        prune.isEnabled = !busy && worktrees.dropFirst().contains(where: \.isDeleted)
        delete.isEnabled = !busy && selected?.canDelete == true
        open.isEnabled = !busy && selected?.canOpen == true
    }
    private func reload() {
        let selectedPath = selected?.path
        busy = true; updateButtons()
        Task { @MainActor in
            do {
                worktrees = try await source.loadWorktreeContext().worktrees; table.reloadData()
                if let index = worktrees.firstIndex(where: { $0.path == selectedPath }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
                else if !worktrees.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
                status.stringValue = ""
            } catch { status.stringValue = error.localizedDescription }
            busy = false; updateButtons()
        }
    }
    @objc private func createWorktree() { run { await self.createAction($0) } }
    @objc private func pruneWorktrees() { run { await self.pruneAction($0) } }
    @objc private func deleteSelected() { guard let selected, selected.canDelete else { return }; run { await self.deleteAction(selected, $0) } }
    private func run(_ action: @escaping (NSWindow) async -> Void) {
        guard !busy, let window else { return }; busy = true; updateButtons()
        Task { @MainActor in await action(window); reload() }
    }
    @objc private func openSelected() {
        guard !busy, let selected, selected.canOpen, let window else { return }
        if openAction(selected, window) { window.close() }
    }
    override func cancelOperation(_ sender: Any?) { if !busy { window?.close() } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !busy }
    func windowWillClose(_ notification: Notification) { closed() }
}

private final class WorktreeTableView: NSTableView {
    var onReturn: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onReturn?() } else { super.keyDown(with: event) }
    }
}
