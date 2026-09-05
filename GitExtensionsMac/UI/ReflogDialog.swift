import GitExtensionsCore
import GitCommands
import AppKit

@MainActor
enum ReflogDialog {
    static func present(
        source: any RepositoryReflogDataSource,
        owner: NSWindow,
        createBranch: @escaping @MainActor (ObjectID, String, NSWindow) -> Void,
        resetCurrentBranch: @escaping @MainActor (ObjectID, String, Bool, NSWindow) -> Void,
        onClose: @escaping @MainActor () -> Void
    ) -> NSWindowController {
        let controller = ReflogViewController(
            source: source,
            createBranch: createBranch,
            resetCurrentBranch: resetCurrentBranch,
            onClose: onClose
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 782, height: 555),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Reflog"
        window.minSize = NSSize(width: 400, height: 200)
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 782, height: 555))
        window.isReleasedWhenClosed = false
        controller.window = window
        window.delegate = controller

        let windowController = NSWindowController(window: window)
        windowController.showWindow(nil)
        window.setFrameOrigin(NSPoint(
            x: owner.frame.midX - window.frame.width / 2,
            y: owner.frame.midY - window.frame.height / 2
        ))
        window.makeKeyAndOrderFront(nil)
        return windowController
    }

    static func focus(_ controller: NSWindowController) {
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}

struct ReflogActionEligibility: Equatable {
    let canCopyObjectID: Bool
    let canCreateBranch: Bool
    let canResetCurrentBranch: Bool

    init(hasSelection: Bool, isBranchCheckedOut: Bool) {
        canCopyObjectID = hasSelection
        canCreateBranch = hasSelection
        canResetCurrentBranch = hasSelection && isBranchCheckedOut
    }
}

@MainActor
private final class ReflogViewController: NSViewController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    weak var window: NSWindow?

    private let source: any RepositoryReflogDataSource
    private let createBranch: @MainActor (ObjectID, String, NSWindow) -> Void
    private let resetCurrentBranch: @MainActor (ObjectID, String, Bool, NSWindow) -> Void
    private let onClose: @MainActor () -> Void
    private let warning = NSTextField(wrappingLabelWithString: "Warning: you've got changes in your working directory that could be lost if you want to reset the current branch to another commit.\nStash them before if you don't want to lose them.")
    private let referenceSelector = NSPopUpButton()
    private let currentBranchButton = NSButton(title: "", target: nil, action: nil)
    private let headButton = NSButton(title: "HEAD", target: nil, action: nil)
    private let table = ReflogTableView()
    private let status = NSTextField(labelWithString: "Loading reflog…")
    private let progress = NSProgressIndicator()
    private var context: RepositoryReflogContext?
    private var entries: [RepositoryReflogEntry] = []
    private var loadTask: Task<Void, Never>?
    private var didClose = false

    init(
        source: any RepositoryReflogDataSource,
        createBranch: @escaping @MainActor (ObjectID, String, NSWindow) -> Void,
        resetCurrentBranch: @escaping @MainActor (ObjectID, String, Bool, NSWindow) -> Void,
        onClose: @escaping @MainActor () -> Void
    ) {
        self.source = source
        self.createBranch = createBranch
        self.resetCurrentBranch = resetCurrentBranch
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    deinit { loadTask?.cancel() }

    override func loadView() {
        let root = NSView()
        warning.textColor = .systemRed
        warning.alignment = .center
        warning.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        warning.maximumNumberOfLines = 2
        warning.isHidden = true

        let referenceLabel = NSTextField(labelWithString: "Reference:")
        referenceSelector.target = self
        referenceSelector.action = #selector(referenceChanged)
        referenceSelector.widthAnchor.constraint(equalToConstant: 272).isActive = true

        configureLinkButton(currentBranchButton, action: #selector(selectCurrentBranch))
        configureLinkButton(headButton, action: #selector(selectHEAD))
        let displayLabel = NSTextField(labelWithString: "Display reflog for:")
        let referenceRow = NSStackView(views: [referenceLabel, referenceSelector])
        referenceRow.orientation = .horizontal
        referenceRow.alignment = .centerY
        referenceRow.spacing = 8
        let displayRow = NSStackView(views: [displayLabel, currentBranchButton, headButton])
        displayRow.orientation = .horizontal
        displayRow.alignment = .centerY
        displayRow.spacing = 8
        let controls = NSStackView(views: [referenceRow, NSView(), displayRow])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 12
        controls.views[1].setContentHuggingPriority(.defaultLow, for: .horizontal)

        configureTable()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.documentView = table

        progress.style = .spinning
        progress.controlSize = .small
        progress.startAnimation(nil)
        status.textColor = .secondaryLabelColor
        let statusRow = NSStackView(views: [progress, status])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 7

        let content = NSStackView(views: [warning, controls, scroll, statusRow])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            warning.widthAnchor.constraint(equalTo: content.widthAnchor),
            controls.widthAnchor.constraint(equalTo: content.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)
        ])
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        loadContext()
    }

    override func cancelOperation(_ sender: Any?) { window?.close() }

    func windowWillClose(_ notification: Notification) {
        guard !didClose else { return }
        didClose = true
        loadTask?.cancel()
        onClose()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row), let identifier = tableColumn?.identifier else { return nil }
        let entry = entries[row]
        let text: String = switch identifier.rawValue {
        case "sha": entry.objectID.string
        case "ref": entry.selector.rawValue
        default: entry.action
        }
        let cell = NSTextField(labelWithString: text)
        cell.lineBreakMode = .byTruncatingTail
        cell.toolTip = text
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key else { return }
        let selectedID = selectedEntry?.id
        let ascending = descriptor.ascending
        entries.sort { left, right in
            let comparison: ComparisonResult = switch key {
            case "sha": left.objectID.string.compare(right.objectID.string)
            case "ref": left.selector.rawValue.compare(right.selector.rawValue)
            default: left.action.localizedCompare(right.action)
            }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
        table.reloadData()
        if let selectedID, let index = entries.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    @objc private func referenceChanged() { loadEntries(preserving: nil) }
    @objc private func selectCurrentBranch() {
        guard let current = context?.currentBranch else { return }
        referenceSelector.selectItem(withTitle: current)
        loadEntries(preserving: nil)
    }
    @objc private func selectHEAD() {
        referenceSelector.selectItem(withTitle: "HEAD")
        loadEntries(preserving: nil)
    }

    @objc private func copyObjectID() {
        guard let entry = selectedEntry else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.objectID.string, forType: .string)
    }

    @objc private func createBranchAtEntry() {
        guard let entry = selectedEntry, let window else { return }
        createBranch(entry.objectID, entry.selector.rawValue, window)
    }

    @objc private func resetAtEntry() {
        guard let entry = selectedEntry, let context, context.currentBranch != nil, let window else { return }
        resetCurrentBranch(entry.objectID, entry.selector.rawValue, context.isDirty, window)
    }

    private var selectedEntry: RepositoryReflogEntry? {
        entries.indices.contains(table.selectedRow) ? entries[table.selectedRow] : nil
    }

    private func loadContext() {
        loadTask?.cancel()
        setLoading(true, text: "Loading reflog…")
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let loaded = try await source.loadReflogContext()
                guard !Task.isCancelled else { return }
                context = loaded
                warning.isHidden = !loaded.isDirty
                currentBranchButton.isHidden = loaded.currentBranch == nil
                currentBranchButton.title = loaded.currentBranch.map { "current branch (\($0))" } ?? ""
                referenceSelector.removeAllItems()
                referenceSelector.addItems(withTitles: loaded.references)
                referenceSelector.selectItem(withTitle: "HEAD")
                loadEntries(preserving: nil)
            } catch is CancellationError {
                return
            } catch {
                setLoading(false, text: error.localizedDescription)
            }
        }
    }

    private func loadEntries(preserving selector: RepositoryReflogSelector?) {
        guard let reference = referenceSelector.titleOfSelectedItem else { return }
        loadTask?.cancel()
        setLoading(true, text: "Loading \(reference) reflog…")
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let loaded = try await source.loadReflog(reference: reference)
                guard !Task.isCancelled else { return }
                entries = loaded
                table.sortDescriptors = []
                table.reloadData()
                if let selector, let index = loaded.firstIndex(where: { $0.selector == selector }) {
                    table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                } else if !loaded.isEmpty {
                    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                }
                setLoading(false, text: loaded.isEmpty ? "No reflog entries." : "\(loaded.count) reflog entries")
            } catch is CancellationError {
                return
            } catch {
                entries = []
                table.reloadData()
                setLoading(false, text: error.localizedDescription)
            }
        }
    }

    private func configureLinkButton(_ button: NSButton, action: Selector) {
        button.target = self
        button.action = action
        button.isBordered = false
        button.font = .systemFont(ofSize: NSFont.systemFontSize)
        button.contentTintColor = .linkColor
        button.setButtonType(.momentaryChange)
    }

    private func configureTable() {
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.rowHeight = 24
        table.headerView?.frame.size.height = 30
        table.addTableColumn(column("sha", title: "SHA-1", width: 285))
        table.addTableColumn(column("ref", title: "Ref", width: 170))
        table.addTableColumn(column("action", title: "Action", width: 350))

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(menuItem("Copy SHA-1", action: #selector(copyObjectID), key: "sha"))
        menu.addItem(menuItem("Create a branch on this commit…", action: #selector(createBranchAtEntry), key: "branch"))
        menu.addItem(menuItem("Reset current branch to this commit…", action: #selector(resetAtEntry), key: "reset"))
        table.menu = menu
        table.prepareMenu = { [weak self] menu in
            guard let self else { return }
            let eligibility = ReflogActionEligibility(
                hasSelection: selectedEntry != nil,
                isBranchCheckedOut: context?.currentBranch != nil
            )
            menu.items.first(where: { $0.identifier?.rawValue == "sha" })?.isEnabled = eligibility.canCopyObjectID
            menu.items.first(where: { $0.identifier?.rawValue == "branch" })?.isEnabled = eligibility.canCreateBranch
            menu.items.first(where: { $0.identifier?.rawValue == "reset" })?.isEnabled = eligibility.canResetCurrentBranch
        }
    }

    private func column(_ id: String, title: String, width: CGFloat) -> NSTableColumn {
        let column = NSTableColumn(identifier: .init(id))
        column.title = title
        column.width = width
        column.minWidth = 60
        column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
        return column
    }

    private func menuItem(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.identifier = .init(key)
        return item
    }

    private func setLoading(_ loading: Bool, text: String) {
        status.stringValue = text
        if loading { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        progress.isHidden = !loading
        referenceSelector.isEnabled = !loading
    }
}

private final class ReflogTableView: NSTableView {
    var prepareMenu: ((NSMenu) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if let menu { prepareMenu?(menu) }
        return menu
    }
}
