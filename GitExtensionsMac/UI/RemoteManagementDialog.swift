import AppKit

@MainActor
enum RemoteManagementDialog {
    static func present(
        source: any RepositoryRemoteManagingDataSource,
        selectedRemote: String? = nil,
        onSnapshot: @escaping (RepositorySnapshot) -> Void,
        onClose: @escaping () -> Void
    ) -> NSWindowController {
        let content = RemoteManagementViewController(
            source: source,
            selectedRemote: selectedRemote,
            onSnapshot: onSnapshot
        )
        let window = NSWindow(contentViewController: content)
        window.title = "Remote repositories"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 930, height: 470))
        window.minSize = NSSize(width: 690, height: 380)
        window.isReleasedWhenClosed = false
        let controller = NSWindowController(window: window)
        content.onClose = onClose
        window.delegate = content
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        return controller
    }
}

@MainActor
private final class RemoteManagementViewController: NSViewController, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private final class GroupNode: NSObject {
        let title: String
        var remotes: [RepositoryRemoteConfiguration]
        init(_ title: String, remotes: [RepositoryRemoteConfiguration]) {
            self.title = title
            self.remotes = remotes
        }
    }

    var onClose: (() -> Void)?
    private let source: any RepositoryRemoteManagingDataSource
    private let preselectedRemote: String?
    private let onSnapshot: (RepositorySnapshot) -> Void
    private var configurations: [RepositoryRemoteConfiguration] = []
    private var tracking: [RepositoryBranchTrackingConfiguration] = []
    private var remoteBranches: [String: [String]] = [:]
    private var groups: [GroupNode] = []
    private var selected: RepositoryRemoteConfiguration?
    private var isCreating = false
    private var task: Task<Void, Never>?

    private let tabs = NSTabView()
    private let outline = NSOutlineView()
    private let trackingTable = NSTableView()
    private let nameField = NSTextField()
    private let urlField = NSTextField()
    private let separatePushURL = NSButton(checkboxWithTitle: "Separate Push Url", target: nil, action: nil)
    private let pushURLField = NSTextField()
    private let puttyKeyField = NSTextField()
    private let prefixField = NSTextField()
    private let colorWell = NSColorWell()
    private var pushURLRow: NSGridRow?
    private let saveButton = NSButton()
    private let deleteButton = NSButton()
    private let toggleButton = NSButton()
    private let status = NSTextField(labelWithString: "")

    init(
        source: any RepositoryRemoteManagingDataSource,
        selectedRemote: String?,
        onSnapshot: @escaping (RepositorySnapshot) -> Void
    ) {
        self.source = source
        preselectedRemote = selectedRemote
        self.onSnapshot = onSnapshot
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    deinit { task?.cancel() }

    override func loadView() {
        let root = NSView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.addTabViewItem(NSTabViewItem(identifier: "remotes"))
        tabs.tabViewItem(at: 0).label = "Remote repositories"
        tabs.tabViewItem(at: 0).view = makeRemotesPage()
        tabs.addTabViewItem(NSTabViewItem(identifier: "tracking"))
        tabs.tabViewItem(at: 1).label = "Default pull behavior (fetch && merge)"
        tabs.tabViewItem(at: 1).view = makeTrackingPage()
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 10.5)
        status.lineBreakMode = .byTruncatingMiddle
        status.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabs)
        root.addSubview(status)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            tabs.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            tabs.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -4),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
            status.heightAnchor.constraint(equalToConstant: 16)
        ])
        view = root
        reload(selecting: preselectedRemote)
    }

    private func makeRemotesPage() -> NSView {
        let page = NSView()
        let column = NSTableColumn(identifier: .init("remote"))
        column.width = 260
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 23
        outline.indentationPerLevel = 10
        outline.delegate = self
        outline.dataSource = self
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let add = imageButton("RemoteAdd", tooltip: "Add a new remote", action: #selector(addRemote))
        deleteButton.image = AppKitFactory.resourceImage("RemoteDelete", accessibilityDescription: "Delete remote")
        deleteButton.bezelStyle = .texturedRounded
        deleteButton.target = self
        deleteButton.action = #selector(deleteRemote)
        deleteButton.toolTip = "Delete remote"
        toggleButton.image = AppKitFactory.resourceImage("RemoteEnableAndFetch", accessibilityDescription: "Activate or deactivate remote")
        toggleButton.bezelStyle = .texturedRounded
        toggleButton.target = self
        toggleButton.action = #selector(toggleRemote)
        toggleButton.toolTip = "Activate or deactivate remote"
        let actions = NSStackView(views: [add, deleteButton, toggleButton])
        actions.orientation = .vertical
        actions.spacing = 7
        actions.alignment = .centerX

        let editor = makeEditor()
        [scroll, actions, editor].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; page.addSubview($0) }
        let preferredListWidth = scroll.widthAnchor.constraint(equalToConstant: 295)
        preferredListWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 12),
            scroll.topAnchor.constraint(equalTo: page.topAnchor, constant: 14),
            scroll.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -12),
            scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            preferredListWidth,
            actions.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 8),
            actions.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 6),
            actions.widthAnchor.constraint(equalToConstant: 34),
            editor.leadingAnchor.constraint(equalTo: actions.trailingAnchor, constant: 10),
            editor.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -12),
            editor.topAnchor.constraint(equalTo: scroll.topAnchor),
            editor.bottomAnchor.constraint(lessThanOrEqualTo: page.bottomAnchor, constant: -12),
            editor.widthAnchor.constraint(greaterThanOrEqualToConstant: 360)
        ])
        return page
    }

    private func makeEditor() -> NSBox {
        let box = NSBox()
        box.title = "Edit Remote Details"
        box.titlePosition = .atTop
        box.boxType = .primary
        separatePushURL.target = self
        separatePushURL.action = #selector(separatePushChanged)
        let browseURL = NSButton(title: "Browse…", target: self, action: #selector(browseRemoteURL))
        browseURL.image = AppKitFactory.resourceImage("FolderClosed", accessibilityDescription: "Browse")
        browseURL.imagePosition = .imageLeading
        let browseKey = NSButton(title: "Browse…", target: self, action: #selector(browseKey))
        let urlRow = NSStackView(views: [urlField, browseURL])
        urlRow.spacing = 8
        urlField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        browseURL.widthAnchor.constraint(equalToConstant: 105).isActive = true
        let keyRow = NSStackView(views: [puttyKeyField, browseKey])
        keyRow.spacing = 8
        puttyKeyField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        browseKey.widthAnchor.constraint(equalToConstant: 105).isActive = true
        let grid = NSGridView(views: [
            [rightLabel("Url"), urlRow],
            [rightLabel("Name"), nameField],
            [NSView(), separatePushURL],
            [rightLabel("Push Url"), pushURLField],
            [rightLabel("Private key file"), keyRow],
            [rightLabel("Remote color"), colorWell],
            [rightLabel("Remote prefix"), prefixField]
        ])
        pushURLRow = grid.row(at: 3)
        pushURLRow?.isHidden = true
        grid.row(at: 4).isHidden = true
        grid.row(at: 5).isHidden = true
        grid.row(at: 6).isHidden = true
        grid.column(at: 0).width = 112
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        saveButton.title = "Save changes"
        saveButton.image = NSImage(systemSymbolName: "externaldrive.fill.badge.checkmark", accessibilityDescription: "Save")
        saveButton.imagePosition = .imageLeading
        saveButton.target = self
        saveButton.action = #selector(saveRemote)
        let stack = NSStackView(views: [grid, saveButton])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(stack)
        if let holder = box.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 12),
                stack.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -12),
                stack.topAnchor.constraint(equalTo: holder.topAnchor, constant: 12),
                stack.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -12),
                saveButton.widthAnchor.constraint(equalToConstant: 150)
            ])
        }
        return box
    }

    private func makeTrackingPage() -> NSView {
        let page = NSView()
        for (id, title, width) in [("branch", "Local branch", 260.0), ("remote", "Tracking Remote", 220.0), ("merge", "Merge With", 300.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            trackingTable.addTableColumn(column)
        }
        trackingTable.rowHeight = 24
        trackingTable.delegate = self
        trackingTable.dataSource = self
        let scroll = NSScrollView()
        scroll.documentView = trackingTable
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let help = NSTextField(wrappingLabelWithString: "Choose the remote and branch used by Pull for each local branch. Changes are saved immediately.")
        help.textColor = .secondaryLabelColor
        help.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(help)
        page.addSubview(scroll)
        NSLayoutConstraint.activate([
            help.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 12),
            help.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -12),
            help.topAnchor.constraint(equalTo: page.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: help.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -12)
        ])
        return page
    }

    private func reload(selecting name: String?) {
        task?.cancel()
        setBusy(true, text: "Loading remotes…")
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                async let remotes = source.loadRemoteConfigurations()
                async let tracking = source.loadBranchTrackingConfigurations()
                async let snapshot = source.loadSnapshot()
                configurations = try await remotes
                self.tracking = try await tracking
                let loadedSnapshot = try await snapshot
                remoteBranches = Dictionary(uniqueKeysWithValues: loadedSnapshot.remotes.map { remote in
                    let prefix = remote.name + "/"
                    let names = remote.branches.map { branch in
                        branch.name.hasPrefix(prefix) ? String(branch.name.dropFirst(prefix.count)) : branch.name
                    }.filter { $0 != "HEAD" }
                    return (remote.name, Array(Set(names)).sorted())
                })
                groups = [
                    GroupNode("Active", remotes: configurations.filter { !$0.isDisabled }),
                    GroupNode("Inactive", remotes: configurations.filter(\.isDisabled))
                ].filter { !$0.remotes.isEmpty }
                outline.reloadData()
                outline.expandItem(nil, expandChildren: true)
                trackingTable.reloadData()
                let preferred = name ?? selected?.name ?? configurations.first?.name
                selectRemote(named: preferred)
                setBusy(false, text: "")
            } catch is CancellationError {
            } catch {
                setBusy(false, text: error.localizedDescription)
                showError(error)
            }
        }
    }

    private func selectRemote(named name: String?) {
        guard let name else { beginNewRemote(); return }
        for row in 0..<outline.numberOfRows {
            if let remote = outline.item(atRow: row) as? RepositoryRemoteConfiguration, remote.name == name {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outline.scrollRowToVisible(row)
                show(remote)
                return
            }
        }
        beginNewRemote()
    }

    private func show(_ remote: RepositoryRemoteConfiguration) {
        selected = remote
        isCreating = false
        nameField.stringValue = remote.name
        urlField.stringValue = remote.fetchURL
        pushURLField.stringValue = remote.pushURL ?? ""
        separatePushURL.state = remote.pushURL == nil ? .off : .on
        puttyKeyField.stringValue = remote.puttyKeyFile ?? ""
        prefixField.stringValue = remote.prefix ?? ""
        colorWell.color = remote.color.flatMap(NSColor.init(hexString:)) ?? .clear
        let editable = !remote.isDisabled
        [nameField, urlField, separatePushURL, pushURLField, puttyKeyField, prefixField, colorWell, saveButton].forEach { $0.isEnabled = editable }
        pushURLField.isHidden = separatePushURL.state == .off
        pushURLRow?.isHidden = separatePushURL.state == .off
        deleteButton.isEnabled = true
        toggleButton.isEnabled = true
        toggleButton.toolTip = remote.isDisabled ? "Activate remote" : "Deactivate remote"
    }

    private func beginNewRemote() {
        selected = nil
        isCreating = true
        outline.deselectAll(nil)
        [nameField, urlField, pushURLField, puttyKeyField, prefixField].forEach { $0.stringValue = ""; $0.isEnabled = true }
        separatePushURL.state = .off
        separatePushURL.isEnabled = true
        pushURLField.isHidden = true
        pushURLRow?.isHidden = true
        colorWell.color = .clear
        colorWell.isEnabled = true
        saveButton.isEnabled = true
        deleteButton.isEnabled = false
        toggleButton.isEnabled = false
        nameField.becomeFirstResponder()
    }

    @objc private func addRemote() { beginNewRemote() }
    @objc private func separatePushChanged() {
        let hidden = separatePushURL.state == .off
        pushURLField.isHidden = hidden
        pushURLRow?.isHidden = hidden
    }

    @objc private func browseRemoteURL() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { urlField.stringValue = url.path }
    }

    @objc private func browseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        if panel.runModal() == .OK, let url = panel.url { puttyKeyField.stringValue = url.path }
    }

    @objc private func saveRemote() {
        let request = RepositoryRemoteSaveRequest(
            originalName: isCreating ? nil : selected?.name,
            name: nameField.stringValue,
            fetchURL: urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            pushURL: separatePushURL.state == .on ? pushURLField.stringValue : nil,
            puttyKeyFile: puttyKeyField.stringValue,
            color: colorWell.color.hexString,
            prefix: prefixField.stringValue
        )
        mutate("Saving remote…") { [source] in try await source.saveRemote(request) }
    }

    @objc private func deleteRemote() {
        guard let selected else { return }
        let alert = NSAlert()
        alert.messageText = "Delete remote ‘\(selected.name)’?"
        alert.informativeText = selected.isDisabled ? "The inactive remote configuration will be removed." : "The remote and its remote-tracking references will be removed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        mutate("Deleting remote…", preferredSelection: nil) { [source] in
            try await source.deleteRemote(named: selected.name, disabled: selected.isDisabled)
        }
    }

    @objc private func toggleRemote() {
        guard let selected else { return }
        mutate(selected.isDisabled ? "Activating remote…" : "Deactivating remote…") { [source] in
            try await source.setRemote(named: selected.name, disabled: !selected.isDisabled)
        }
    }

    private func mutate(_ message: String, preferredSelection: String? = nil, operation: @escaping @Sendable () async throws -> RepositorySnapshot) {
        task?.cancel()
        setBusy(true, text: message)
        let name = preferredSelection ?? nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await operation()
                onSnapshot(snapshot)
                setBusy(false, text: "")
                reload(selecting: name.isEmpty ? nil : name)
            } catch is CancellationError {
            } catch {
                setBusy(false, text: error.localizedDescription)
                showError(error)
            }
        }
    }

    private func setBusy(_ busy: Bool, text: String) {
        status.stringValue = text
        outline.isEnabled = !busy
        trackingTable.isEnabled = !busy
        saveButton.isEnabled = !busy && (selected?.isDisabled != true)
        deleteButton.isEnabled = !busy && selected != nil
        toggleButton.isEnabled = !busy && selected != nil
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window = view.window { alert.beginSheetModal(for: window) }
    }

    private func imageButton(_ image: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton(image: AppKitFactory.resourceImage(image, accessibilityDescription: tooltip) ?? NSImage(), target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.toolTip = tooltip
        button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    private func rightLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        return label
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? GroupNode)?.remotes.count ?? groups.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? GroupNode)?.remotes[index] ?? groups[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is GroupNode }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is GroupNode }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is RepositoryRemoteConfiguration }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let cell = NSTableCellView()
        let label: NSTextField
        if let group = item as? GroupNode {
            label = NSTextField(labelWithString: group.title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
        } else if let remote = item as? RepositoryRemoteConfiguration {
            label = NSTextField(labelWithString: remote.name)
            label.font = .systemFont(ofSize: 12)
            label.textColor = remote.isDisabled ? .tertiaryLabelColor : .labelColor
        } else { return nil }
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard outline.selectedRow >= 0, let remote = outline.item(atRow: outline.selectedRow) as? RepositoryRemoteConfiguration else { return }
        show(remote)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { tracking.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < tracking.count, let id = tableColumn?.identifier.rawValue else { return nil }
        let configuration = tracking[row]
        if id == "branch" { return NSTextField(labelWithString: configuration.branchName) }
        let popUp = NSPopUpButton()
        popUp.controlSize = .small
        popUp.tag = row
        popUp.target = self
        popUp.action = #selector(trackingChanged(_:))
        if id == "remote" {
            popUp.identifier = .init("remote")
            popUp.addItem(withTitle: "")
            popUp.addItems(withTitles: configurations.filter { !$0.isDisabled }.map(\.name))
            popUp.selectItem(withTitle: configuration.remoteName ?? "")
        } else {
            popUp.identifier = .init("merge")
            popUp.addItem(withTitle: "")
            let branchNames = Set((configuration.remoteName.flatMap { remoteBranches[$0] } ?? []) + [configuration.mergeBranch, configuration.branchName].compactMap { $0 })
            popUp.addItems(withTitles: branchNames.sorted())
            popUp.selectItem(withTitle: configuration.mergeBranch ?? "")
        }
        return popUp
    }

    @objc private func trackingChanged(_ sender: NSPopUpButton) {
        guard tracking.indices.contains(sender.tag) else { return }
        var value = tracking[sender.tag]
        let title = sender.titleOfSelectedItem.flatMap { $0.isEmpty ? nil : $0 }
        if sender.identifier?.rawValue == "remote" {
            value = RepositoryBranchTrackingConfiguration(branchName: value.branchName, remoteName: title, mergeBranch: value.mergeBranch)
        } else {
            value = RepositoryBranchTrackingConfiguration(branchName: value.branchName, remoteName: value.remoteName, mergeBranch: title)
        }
        tracking[sender.tag] = value
        let updatedValue = value
        mutate("Saving pull behavior…", preferredSelection: selected?.name) { [source] in
            try await source.setBranchTracking(updatedValue)
        }
    }

    func windowWillClose(_ notification: Notification) {
        task?.cancel()
        onClose?()
    }
}

private extension NSColor {
    convenience init?(hexString: String) {
        let value = hexString.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard value.count == 6, let rgb = Int(value, radix: 16) else { return nil }
        self.init(
            calibratedRed: CGFloat((rgb >> 16) & 0xff) / 255,
            green: CGFloat((rgb >> 8) & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255,
            alpha: 1
        )
    }

    var hexString: String? {
        guard alphaComponent > 0, let rgb = usingColorSpace(.deviceRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }
}
