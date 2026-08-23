import AppKit

struct CherryPickDialogSelection: Sendable {
    let commit: Commit
    let options: RepositoryCherryPickOptions
    let mainlineParent: Int?
}

@MainActor
enum CherryPickDialog {
    static func present(
        commit: Commit,
        history: [Commit],
        options: RepositoryCherryPickOptions,
        owner: NSWindow
    ) async -> CherryPickDialogSelection? {
        let controller = CherryPickViewController(
            commit: commit,
            history: history,
            options: options
        )
        let panel = NSPanel(contentViewController: controller)
        panel.title = "Cherry pick commit"
        panel.styleMask = [.titled, .closable, .resizable]
        panel.minSize = NSSize(width: 630, height: 370)
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isReleasedWhenClosed = false
        controller.panel = panel
        controller.updatePresentationSize()

        return await withCheckedContinuation { continuation in
            controller.onClose = { result in
                owner.endSheet(panel)
                continuation.resume(returning: result)
            }
            owner.beginSheet(panel)
        }
    }
}

@MainActor
private final class CherryPickViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    weak var panel: NSPanel?
    var onClose: ((CherryPickDialogSelection?) -> Void)?

    private var commit: Commit
    private let history: [Commit]
    private var parentRows: [(number: Int, commit: Commit?)] = []
    private var didClose = false

    private let summary = CommitSummaryView()
    private let parentHeading = NSTextField(labelWithString: "This commit is a merge, select parent:")
    private let parentTable = NSTableView()
    private let parentScroll = NSScrollView()
    private let parentSection = NSStackView()
    private var parentHeightConstraint: NSLayoutConstraint?
    private let automaticallyCommit: NSButton
    private let addReference: NSButton
    private let pickButton = NSButton(title: "Cherry pick", target: nil, action: nil)
    private let abortButton = NSButton(title: "Abort", target: nil, action: nil)

    init(commit: Commit, history: [Commit], options: RepositoryCherryPickOptions) {
        self.commit = commit
        self.history = history.filter { !$0.isArtificial }
        automaticallyCommit = NSButton(
            checkboxWithTitle: "Automatically create a commit",
            target: nil,
            action: nil
        )
        addReference = NSButton(
            checkboxWithTitle: "Add commit reference to commit message",
            target: nil,
            action: nil
        )
        automaticallyCommit.state = options.automaticallyCommit ? .on : .off
        addReference.state = options.addReference ? .on : .off
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()

        let heading = NSTextField(labelWithString: "Cherry pick this commit:")

        let chooseButton = NSButton(
            image: NSImage(systemSymbolName: "list.bullet.rectangle", accessibilityDescription: "Choose another revision")
                ?? NSImage(),
            target: self,
            action: #selector(chooseRevision)
        )
        chooseButton.bezelStyle = .rounded
        chooseButton.imagePosition = .imageOnly
        chooseButton.toolTip = "Choose another revision"
        chooseButton.setAccessibilityLabel("Choose another revision")
        chooseButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            chooseButton.widthAnchor.constraint(equalToConstant: 25),
            chooseButton.heightAnchor.constraint(equalToConstant: 24)
        ])
        let chooseLabel = NSTextField(labelWithString: "Choose another revision:")
        let chooseSpacer = NSView()
        chooseSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let chooseRow = NSStackView(views: [chooseSpacer, chooseLabel, chooseButton])
        chooseRow.orientation = .horizontal
        chooseRow.alignment = .centerY
        chooseRow.spacing = 6

        configureParentTable()
        parentSection.orientation = .vertical
        parentSection.alignment = .leading
        parentSection.spacing = 3
        parentSection.addArrangedSubview(parentHeading)
        parentSection.addArrangedSubview(parentScroll)
        parentScroll.widthAnchor.constraint(equalTo: parentSection.widthAnchor).isActive = true

        pickButton.target = self
        pickButton.action = #selector(pick)
        pickButton.keyEquivalent = "\r"
        pickButton.bezelStyle = .rounded
        pickButton.translatesAutoresizingMaskIntoConstraints = false
        pickButton.widthAnchor.constraint(equalToConstant: 109).isActive = true
        abortButton.target = self
        abortButton.action = #selector(abort)
        abortButton.keyEquivalent = "\u{1b}"
        abortButton.bezelStyle = .rounded
        abortButton.translatesAutoresizingMaskIntoConstraints = false
        abortButton.widthAnchor.constraint(equalToConstant: 75).isActive = true

        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [buttonSpacer, pickButton, abortButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 6

        let content = NSStackView(views: [
            heading,
            summary,
            chooseRow,
            parentSection,
            automaticallyCommit,
            addReference,
            buttonRow
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            summary.widthAnchor.constraint(equalTo: content.widthAnchor),
            summary.heightAnchor.constraint(equalToConstant: 160),
            chooseRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            parentSection.widthAnchor.constraint(equalTo: content.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            buttonRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 33)
        ])

        view = root
        updateCommit(commit)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        panel?.delegate = self
        focusInitialControl()
    }

    func updatePresentationSize() {
        _ = view
        let parentRowsHeight = CGFloat(parentRows.count * 18)
        let height: CGFloat = commit.isMerge ? 413 + parentRowsHeight : 344
        panel?.contentMinSize = NSSize(width: 614, height: height)
        panel?.setContentSize(NSSize(width: 614, height: height))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { parentRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < parentRows.count else { return nil }
        let parent = parentRows[row]
        let value: String
        switch tableColumn?.identifier.rawValue {
        case "number": value = String(parent.number)
        case "message": value = parent.commit?.subject ?? String(commit.parentIDs[row].prefix(8))
        case "author": value = parent.commit?.authorName ?? ""
        case "date": value = parent.commit.map { Self.shortDateFormatter.string(from: $0.commitDate) } ?? ""
        default: value = ""
        }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: value)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    @objc private func chooseRevision() {
        guard let panel else { return }
        Task { @MainActor [weak self, weak panel] in
            guard let self, let panel,
                  let selected = await CherryPickRevisionChooser.present(
                    history: history,
                    selectedCommitID: commit.id,
                    owner: panel
                  )
            else { return }
            updateCommit(selected)
            updatePresentationSize()
            focusInitialControl()
        }
    }

    @objc private func pick() {
        let mainline: Int?
        if commit.isMerge {
            guard parentTable.selectedRow >= 0, parentTable.selectedRow < parentRows.count else {
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "None parent is selected!"
                if let panel {
                    alert.beginSheetModal(for: panel)
                } else {
                    alert.runModal()
                }
                return
            }
            mainline = parentTable.selectedRow + 1
        } else {
            mainline = nil
        }
        finish(CherryPickDialogSelection(
            commit: commit,
            options: RepositoryCherryPickOptions(
                automaticallyCommit: automaticallyCommit.state == .on,
                addReference: addReference.state == .on
            ),
            mainlineParent: mainline
        ))
    }

    @objc private func abort() { finish(nil) }

    func windowWillClose(_ notification: Notification) { finish(nil) }

    private func configureParentTable() {
        let columns: [(String, String, CGFloat)] = [
            ("number", "No.", 43),
            ("message", "Message", 291),
            ("author", "Author", 120),
            ("date", "Date", 80)
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.minWidth = identifier == "message" ? 120 : width
            column.resizingMask = identifier == "message" ? .autoresizingMask : .userResizingMask
            parentTable.addTableColumn(column)
        }
        parentTable.headerView = NSTableHeaderView()
        parentTable.rowHeight = 18
        parentTable.allowsMultipleSelection = false
        parentTable.allowsEmptySelection = true
        parentTable.usesAlternatingRowBackgroundColors = false
        parentTable.delegate = self
        parentTable.dataSource = self
        parentScroll.documentView = parentTable
        parentScroll.hasVerticalScroller = true
        parentScroll.autohidesScrollers = true
        parentScroll.borderType = .bezelBorder
        parentScroll.translatesAutoresizingMaskIntoConstraints = false
        parentHeightConstraint = parentScroll.heightAnchor.constraint(equalToConstant: 54)
        parentHeightConstraint?.isActive = true
    }

    private func updateCommit(_ commit: Commit) {
        self.commit = commit
        summary.apply(commit)
        parentRows = commit.parentIDs.enumerated().map { offset, parentID in
            (offset + 1, history.first(where: { $0.id == parentID }))
        }
        parentTable.reloadData()
        parentSection.isHidden = !commit.isMerge
        if commit.isMerge, !parentRows.isEmpty {
            parentTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        parentHeightConstraint?.constant = 54 + CGFloat(parentRows.count * 18)
    }

    private func focusInitialControl() {
        if commit.isMerge {
            panel?.makeFirstResponder(parentTable)
        } else {
            panel?.makeFirstResponder(automaticallyCommit)
        }
    }

    private func finish(_ value: CherryPickDialogSelection?) {
        guard !didClose else { return }
        didClose = true
        onClose?(value)
    }

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }()
}

@MainActor
private enum CherryPickRevisionChooser {
    static func present(history: [Commit], selectedCommitID: String, owner: NSWindow) async -> Commit? {
        let controller = CherryPickRevisionChooserViewController(
            history: history,
            selectedCommitID: selectedCommitID
        )
        let panel = NSPanel(contentViewController: controller)
        panel.title = "Choose revision"
        panel.styleMask = [.titled, .closable, .resizable]
        panel.setContentSize(NSSize(width: 700, height: 430))
        panel.minSize = NSSize(width: 560, height: 330)
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isReleasedWhenClosed = false
        controller.panel = panel
        return await withCheckedContinuation { continuation in
            controller.onClose = { result in
                owner.endSheet(panel)
                continuation.resume(returning: result)
            }
            owner.beginSheet(panel)
        }
    }
}

@MainActor
private final class CherryPickRevisionChooserViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    weak var panel: NSPanel?
    var onClose: ((Commit?) -> Void)?

    private let history: [Commit]
    private let selectedCommitID: String
    private var filtered: [Commit]
    private var didClose = false
    private let search = NSSearchField()
    private let table = NSTableView()
    private let chooseButton = NSButton(title: "Choose", target: nil, action: nil)

    init(history: [Commit], selectedCommitID: String) {
        self.history = history.filter { !$0.isArtificial }
        self.selectedCommitID = selectedCommitID
        filtered = self.history
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        search.placeholderString = "Filter revisions"
        search.delegate = self

        for (identifier, title, width) in [
            ("commit", "Commit", CGFloat(92)),
            ("message", "Message", CGFloat(310)),
            ("author", "Author", CGFloat(150)),
            ("date", "Date", CGFloat(105))
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.resizingMask = identifier == "message" ? .autoresizingMask : .userResizingMask
            table.addTableColumn(column)
        }
        table.delegate = self
        table.dataSource = self
        table.rowHeight = 20
        table.allowsMultipleSelection = false
        table.target = self
        table.doubleAction = #selector(choose)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder

        chooseButton.target = self
        chooseButton.action = #selector(choose)
        chooseButton.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, chooseButton, cancel])
        buttons.orientation = .horizontal
        buttons.spacing = 6

        let stack = NSStackView(views: [search, scroll, buttons])
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
            search.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 250),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        view = root
        updateSelection()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        panel?.delegate = self
        panel?.makeFirstResponder(search)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filtered.count else { return nil }
        let commit = filtered[row]
        let value: String
        switch tableColumn?.identifier.rawValue {
        case "commit": value = commit.shortID
        case "message": value = commit.subject
        case "author": value = commit.authorName
        case "date": value = Self.dateFormatter.string(from: commit.commitDate)
        default: value = ""
        }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: value)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        chooseButton.isEnabled = table.selectedRow >= 0
    }

    func controlTextDidChange(_ obj: Notification) {
        let value = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        filtered = value.isEmpty ? history : history.filter { commit in
            commit.id.lowercased().contains(value)
                || commit.subject.lowercased().contains(value)
                || commit.authorName.lowercased().contains(value)
                || commit.references.contains { $0.name.lowercased().contains(value) }
        }
        table.reloadData()
        updateSelection()
    }

    @objc private func choose() {
        guard table.selectedRow >= 0, table.selectedRow < filtered.count else { return }
        finish(filtered[table.selectedRow])
    }

    @objc private func cancel() { finish(nil) }
    func windowWillClose(_ notification: Notification) { finish(nil) }

    private func updateSelection() {
        let row = filtered.firstIndex(where: { $0.id == selectedCommitID }) ?? (filtered.isEmpty ? nil : 0)
        if let row {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        } else {
            table.deselectAll(nil)
        }
        chooseButton.isEnabled = row != nil
    }

    private func finish(_ commit: Commit?) {
        guard !didClose else { return }
        didClose = true
        onClose?(commit)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }()
}
