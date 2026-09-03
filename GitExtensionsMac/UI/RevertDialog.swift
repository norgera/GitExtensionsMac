import GitExtensionsCore
import GitCommands
import AppKit

struct RevertDialogSelection: Sendable {
    let automaticallyCommit: Bool
    let mainlineParent: Int?
}

enum RevertWorkflowOrdering {
    static func ordered(_ selected: [Commit], in history: [Commit]) -> [Commit] {
        let historyIndex = Dictionary(uniqueKeysWithValues: history.enumerated().map { ($0.element.id, $0.offset) })
        return selected
            .filter { !$0.isArtificial && $0.objectID != nil }
            .sorted { (historyIndex[$0.id] ?? Int.max) < (historyIndex[$1.id] ?? Int.max) }
    }
}

@MainActor
enum RevertDialog {
    static func present(commit: Commit, history: [Commit], owner: NSWindow) async -> RevertDialogSelection? {
        let controller = RevertViewController(commit: commit, history: history)
        let panel = NSPanel(contentViewController: controller)
        panel.title = "Revert commit"
        panel.styleMask = [.titled, .closable]
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
private final class RevertViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    weak var panel: NSPanel?
    var onClose: ((RevertDialogSelection?) -> Void)?

    private let commit: Commit
    private let history: [Commit]
    private var parentRows: [(number: Int, commit: Commit?)] = []
    private var didClose = false
    private let summary = CommitSummaryView()
    private let parentHeading = NSTextField(labelWithString: "This commit is a merge, select parent:")
    private let parentTable = NSTableView()
    private let parentScroll = NSScrollView()
    private let parentSection = NSStackView()
    private var parentHeightConstraint: NSLayoutConstraint?
    private let automaticallyCommit = NSButton(
        checkboxWithTitle: "Automatically create a commit",
        target: nil,
        action: nil
    )

    init(commit: Commit, history: [Commit]) {
        self.commit = commit
        self.history = history.filter { !$0.isArtificial }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        let heading = NSTextField(labelWithString: "Revert this commit:")
        configureParentTable()
        parentSection.orientation = .vertical
        parentSection.alignment = .leading
        parentSection.spacing = 3
        parentSection.addArrangedSubview(parentHeading)
        parentSection.addArrangedSubview(parentScroll)
        parentScroll.widthAnchor.constraint(equalTo: parentSection.widthAnchor).isActive = true

        let revert = NSButton(title: "Revert this commit", target: self, action: #selector(accept))
        revert.keyEquivalent = "\r"
        revert.translatesAutoresizingMaskIntoConstraints = false
        revert.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        let abort = NSButton(title: "Abort", target: self, action: #selector(cancel))
        abort.keyEquivalent = "\u{1b}"
        abort.translatesAutoresizingMaskIntoConstraints = false
        abort.widthAnchor.constraint(equalToConstant: 75).isActive = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, revert, abort])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 6

        let content = NSStackView(views: [heading, summary, parentSection, automaticallyCommit, buttons])
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
            parentSection.widthAnchor.constraint(equalTo: content.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: content.widthAnchor),
            buttons.heightAnchor.constraint(greaterThanOrEqualToConstant: 33)
        ])
        view = root

        summary.apply(commit)
        parentRows = commit.parentIDs.enumerated().map { offset, parentID in
            (offset + 1, history.first(where: { $0.id == .object(parentID) }))
        }
        parentTable.reloadData()
        parentSection.isHidden = !commit.isMerge
        if commit.isMerge, !parentRows.isEmpty {
            parentTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        parentHeightConstraint?.constant = 54 + CGFloat(parentRows.count * 18)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        panel?.delegate = self
        panel?.makeFirstResponder(commit.isMerge ? parentTable : automaticallyCommit)
    }

    func updatePresentationSize() {
        _ = view
        let parentRowsHeight = CGFloat(parentRows.count * 18)
        let height: CGFloat = commit.isMerge ? 330 + parentRowsHeight : 252
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
        case "message": value = parent.commit?.subject ?? commit.parentIDs[row].shortString
        case "author": value = parent.commit?.authorName ?? ""
        case "date": value = parent.commit.map { Self.shortDateFormatter.string(from: $0.commitDate) } ?? ""
        default: value = ""
        }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: value)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = value
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    @objc private func accept() {
        let mainline: Int?
        if commit.isMerge {
            guard parentTable.selectedRow >= 0 else {
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "Error"
                alert.informativeText = "None parent is selected!"
                alert.runModal()
                return
            }
            mainline = parentRows[parentTable.selectedRow].number
        } else {
            mainline = nil
        }
        finish(RevertDialogSelection(
            automaticallyCommit: automaticallyCommit.state == .on,
            mainlineParent: mainline
        ))
    }

    @objc private func cancel() { finish(nil) }
    override func cancelOperation(_ sender: Any?) { cancel() }
    func windowWillClose(_ notification: Notification) { finish(nil) }

    private func configureParentTable() {
        for (identifier, title, width) in [
            ("number", "No.", 43.0),
            ("message", "Message", 291.0),
            ("author", "Author", 120.0),
            ("date", "Date", 80.0)
        ] {
            let column = NSTableColumn(identifier: .init(identifier))
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

    private func finish(_ value: RevertDialogSelection?) {
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
