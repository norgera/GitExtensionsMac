import GitExtensionsCore
import GitCommands
import AppKit

@MainActor
enum RemoteManagementDialog {
    static func present(
        source: any RepositoryRemoteManagingDataSource,
        selectedRemote: String? = nil,
        selectedLocalBranch: String? = nil,
        onFetchRemote: @escaping @MainActor (String, NSWindow) async -> Void,
        onRepositoryChanged: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) -> NSWindowController {
        let content = RemoteManagementViewController(
            source: source,
            selectedRemote: selectedRemote,
            selectedLocalBranch: selectedLocalBranch,
            onFetchRemote: onFetchRemote,
            onRepositoryChanged: onRepositoryChanged
        )
        let window = NSWindow(contentViewController: content)
        window.title = "Remote repositories"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        let geometry = AppSettingsStore.shared.remoteManagementPreferences
        window.setContentSize(NSSize(width: geometry.windowWidth, height: geometry.windowHeight))
        window.minSize = NSSize(width: 950, height: 400)
        window.isReleasedWhenClosed = false
        let controller = NSWindowController(window: window)
        content.onClose = onClose
        window.delegate = content
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        return controller
    }

    static func focus(
        _ controller: NSWindowController,
        selectedRemote: String?,
        selectedLocalBranch: String?
    ) {
        (controller.contentViewController as? RemoteManagementViewController)?.select(
            remote: selectedRemote,
            localBranch: selectedLocalBranch
        )
        controller.window?.makeKeyAndOrderFront(nil)
    }
}

enum RemoteManagementSelectionResolver {
    static func preferredRemoteName(
        configurations: [RepositoryRemoteConfiguration],
        requested: String?
    ) -> String? {
        if let requested,
           configurations.contains(where: { $0.name == requested }) {
            return requested
        }
        return configurations.first?.name
    }

    static func preferredLocalBranch(
        configurations: [RepositoryBranchTrackingConfiguration],
        requested: String?
    ) -> String? {
        if let requested,
           configurations.contains(where: { $0.branchName == requested }) {
            return requested
        }
        return configurations.first?.branchName
    }
}

@MainActor
private final class RemoteManagementViewController: NSViewController, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSComboBoxDelegate {
    private enum DialogTab {
        case remotes
        case tracking

        var index: Int { self == .remotes ? 0 : 1 }
    }

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
    private var preselectedRemote: String?
    private var preselectedLocalBranch: String?
    private let onFetchRemote: @MainActor (String, NSWindow) async -> Void
    private let onRepositoryChanged: () -> Void
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
    private let urlField = NSComboBox()
    private let separatePushURL = NSButton(checkboxWithTitle: "Separate Push Url", target: nil, action: nil)
    private let pushURLField = NSComboBox()
    private let prefixField = NSTextField()
    private let colorWell = NSColorWell()
    private let resetColorButton = NSButton(title: "Default color", target: nil, action: nil)
    private let urlLabel = NSTextField(labelWithString: "Url")
    private var pushURLRow: NSGridRow?
    private var colorRow: NSGridRow?
    private var prefixRow: NSGridRow?
    private let advancedButton = NSButton()
    private let remoteEditorBox = NSBox()
    private let saveButton = NSButton()
    private let deleteButton = NSButton()
    private let toggleButton = NSButton()
    private let status = NSTextField(labelWithString: "")
    private let trackingLocalField = NSTextField()
    private let trackingRemoteCombo = NSComboBox()
    private let trackingMergeCombo = NSComboBox()
    private let trackingSaveButton = NSButton(title: "Save changes", target: nil, action: nil)
    private var selectedTrackingRow: Int?

    init(
        source: any RepositoryRemoteManagingDataSource,
        selectedRemote: String?,
        selectedLocalBranch: String?,
        onFetchRemote: @escaping @MainActor (String, NSWindow) async -> Void,
        onRepositoryChanged: @escaping () -> Void
    ) {
        self.source = source
        preselectedRemote = selectedRemote
        preselectedLocalBranch = selectedLocalBranch
        self.onFetchRemote = onFetchRemote
        self.onRepositoryChanged = onRepositoryChanged
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    deinit { task?.cancel() }

    override func loadView() {
        let root = NSView()
        nameField.delegate = self
        for combo in [urlField, pushURLField] {
            combo.isEditable = true
            combo.completes = true
            combo.numberOfVisibleItems = 12
            combo.addItems(withObjectValues: AppSettingsStore.shared.remoteManagementPreferences.recentURLs)
        }
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
        reload(
            selectingRemote: preselectedRemote,
            selectingLocalBranch: preselectedLocalBranch,
            selectingTab: preselectedLocalBranch == nil ? .remotes : .tracking
        )
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
        let box = remoteEditorBox
        box.title = "Edit Remote Details"
        box.titlePosition = .atTop
        box.boxType = .primary
        separatePushURL.target = self
        separatePushURL.action = #selector(separatePushChanged)
        let browseURL = NSButton(title: "Browse…", target: self, action: #selector(browseRemoteURL))
        browseURL.image = AppKitFactory.resourceImage("FolderClosed", accessibilityDescription: "Browse")
        browseURL.imagePosition = .imageLeading
        let browsePushURL = NSButton(title: "Browse…", target: self, action: #selector(browsePushRemoteURL))
        browsePushURL.image = AppKitFactory.resourceImage("FolderClosed", accessibilityDescription: "Browse")
        browsePushURL.imagePosition = .imageLeading
        let urlRow = NSStackView(views: [urlField, browseURL])
        urlRow.spacing = 8
        urlField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        browseURL.widthAnchor.constraint(equalToConstant: 105).isActive = true
        let pushURLStack = NSStackView(views: [pushURLField, browsePushURL])
        pushURLStack.spacing = 8
        pushURLField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        browsePushURL.widthAnchor.constraint(equalToConstant: 105).isActive = true
        urlLabel.alignment = .right
        resetColorButton.target = self
        resetColorButton.action = #selector(resetRemoteColor)
        let colorStack = NSStackView(views: [colorWell, resetColorButton])
        colorStack.spacing = 8
        let grid = NSGridView(views: [
            [urlLabel, urlRow],
            [rightLabel("Name"), nameField],
            [NSView(), separatePushURL],
            [rightLabel("Push Url"), pushURLStack],
            [rightLabel("Remote color"), colorStack],
            [rightLabel("Remote prefix"), prefixField]
        ])
        pushURLRow = grid.row(at: 3)
        pushURLRow?.isHidden = true
        colorRow = grid.row(at: 4)
        prefixRow = grid.row(at: 5)
        grid.column(at: 0).width = 112
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        advancedButton.title = AppSettingsStore.shared.remoteManagementPreferences.showAdvancedOptions
            ? "Hide advanced options"
            : "Show advanced options"
        advancedButton.bezelStyle = .inline
        advancedButton.imagePosition = .imageLeading
        advancedButton.target = self
        advancedButton.action = #selector(toggleAdvancedOptions)
        saveButton.title = "Save changes"
        saveButton.image = NSImage(systemSymbolName: "externaldrive.fill.badge.checkmark", accessibilityDescription: "Save")
        saveButton.imagePosition = .imageLeading
        saveButton.target = self
        saveButton.action = #selector(saveRemote)
        saveButton.keyEquivalent = "\r"
        let buttonRow = NSStackView(views: [advancedButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 12
        let stack = NSStackView(views: [grid, buttonRow])
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
        updateAdvancedOptions()
        return box
    }

    private func makeTrackingPage() -> NSView {
        let page = NSView()
        for (id, title, width) in [
            ("branch", "Local branch name", 260.0),
            ("remote", "Remote repository", 220.0),
            ("merge", "Default merge with", 300.0)
        ] {
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

        trackingLocalField.isEditable = false
        trackingLocalField.isSelectable = true
        trackingRemoteCombo.isEditable = true
        trackingRemoteCombo.completes = true
        trackingRemoteCombo.numberOfVisibleItems = 14
        trackingRemoteCombo.target = self
        trackingRemoteCombo.action = #selector(trackingRemoteChanged)
        trackingRemoteCombo.delegate = self
        trackingMergeCombo.isEditable = true
        trackingMergeCombo.completes = true
        trackingMergeCombo.numberOfVisibleItems = 14
        trackingSaveButton.target = self
        trackingSaveButton.action = #selector(saveTracking)
        trackingSaveButton.widthAnchor.constraint(equalToConstant: 150).isActive = true

        let detailsGrid = NSGridView(views: [
            [rightLabel("Local branch name"), trackingLocalField],
            [rightLabel("Remote repository"), trackingRemoteCombo],
            [rightLabel("Default merge with"), trackingMergeCombo]
        ])
        detailsGrid.column(at: 0).width = 150
        detailsGrid.column(at: 1).xPlacement = .fill
        detailsGrid.rowSpacing = 7
        detailsGrid.columnSpacing = 8
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let saveRow = NSStackView(views: [spacer, trackingSaveButton])
        saveRow.orientation = .horizontal
        let details = NSStackView(views: [detailsGrid, saveRow])
        details.orientation = .vertical
        details.spacing = 9
        details.translatesAutoresizingMaskIntoConstraints = false

        page.addSubview(details)
        page.addSubview(scroll)
        NSLayoutConstraint.activate([
            details.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 12),
            details.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -12),
            details.topAnchor.constraint(equalTo: page.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: details.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -12)
        ])
        return page
    }

    func select(remote: String?, localBranch: String?) {
        preselectedRemote = remote
        preselectedLocalBranch = localBranch
        guard isViewLoaded else { return }
        if localBranch != nil, !configurations.isEmpty {
            tabs.selectTabViewItem(at: 1)
        } else if remote != nil {
            tabs.selectTabViewItem(at: 0)
        }
        selectRemote(named: RemoteManagementSelectionResolver.preferredRemoteName(
            configurations: configurations,
            requested: remote
        ))
        selectLocalBranch(named: RemoteManagementSelectionResolver.preferredLocalBranch(
            configurations: tracking,
            requested: localBranch
        ))
    }

    private func reload(
        selectingRemote remoteName: String?,
        selectingLocalBranch localBranch: String? = nil,
        selectingTab tab: DialogTab
    ) {
        task?.cancel()
        setBusy(true, text: "Loading remotes…")
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                async let remotes = source.loadRemoteConfigurations()
                async let tracking = source.loadBranchTrackingConfigurations()
                async let navigation = source.loadRepositoryState().navigation
                configurations = try await remotes
                self.tracking = try await tracking
                let loadedNavigation = try await navigation
                remoteBranches = Dictionary(uniqueKeysWithValues: loadedNavigation.remotes.map { remote in
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
                let preferredRemote = RemoteManagementSelectionResolver.preferredRemoteName(
                    configurations: configurations,
                    requested: remoteName
                )
                let preferredLocal = RemoteManagementSelectionResolver.preferredLocalBranch(
                    configurations: self.tracking,
                    requested: localBranch
                )
                selectRemote(named: preferredRemote)
                selectLocalBranch(named: preferredLocal)
                tabs.selectTabViewItem(at: tab.index)
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

    private func selectLocalBranch(named name: String?) {
        guard let name,
              let row = tracking.firstIndex(where: { $0.branchName == name }) else {
            selectedTrackingRow = nil
            trackingTable.deselectAll(nil)
            showTracking(nil)
            return
        }
        selectedTrackingRow = row
        trackingTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        trackingTable.scrollRowToVisible(row)
        showTracking(tracking[row])
    }

    private func show(_ remote: RepositoryRemoteConfiguration) {
        selected = remote
        isCreating = false
        remoteEditorBox.title = "Edit Remote Details"
        nameField.stringValue = remote.name
        urlField.stringValue = remote.fetchURL
        pushURLField.stringValue = remote.pushURL ?? ""
        separatePushURL.state = remote.pushURL == nil ? .off : .on
        prefixField.stringValue = remote.prefix ?? ""
        colorWell.color = remote.color.flatMap(NSColor.init(hexString:)) ?? .clear
        let editable = !remote.isDisabled
        [nameField, urlField, separatePushURL, pushURLField, prefixField, colorWell, resetColorButton].forEach { $0.isEnabled = editable }
        pushURLField.isHidden = separatePushURL.state == .off
        pushURLRow?.isHidden = separatePushURL.state == .off
        urlLabel.stringValue = separatePushURL.state == .off ? "Url" : "Fetch Url"
        deleteButton.isEnabled = true
        toggleButton.isEnabled = true
        toggleButton.toolTip = remote.isDisabled ? "Activate remote" : "Deactivate remote"
        updateSaveButtonState()
    }

    private func beginNewRemote() {
        selected = nil
        isCreating = true
        remoteEditorBox.title = "Create New Remote"
        outline.deselectAll(nil)
        [nameField, urlField, pushURLField, prefixField].forEach { $0.stringValue = ""; $0.isEnabled = true }
        separatePushURL.state = .off
        separatePushURL.isEnabled = true
        pushURLField.isHidden = true
        pushURLRow?.isHidden = true
        urlLabel.stringValue = "Url"
        colorWell.color = .clear
        colorWell.isEnabled = true
        resetColorButton.isEnabled = true
        deleteButton.isEnabled = false
        toggleButton.isEnabled = false
        updateSaveButtonState()
        nameField.becomeFirstResponder()
    }

    @objc private func addRemote() { beginNewRemote() }
    @objc private func separatePushChanged() {
        let hidden = separatePushURL.state == .off
        pushURLField.isHidden = hidden
        pushURLRow?.isHidden = hidden
        urlLabel.stringValue = hidden ? "Url" : "Fetch Url"
    }

    @objc private func toggleAdvancedOptions() {
        var preferences = AppSettingsStore.shared.remoteManagementPreferences
        preferences.showAdvancedOptions.toggle()
        AppSettingsStore.shared.saveRemoteManagementPreferences(preferences)
        updateAdvancedOptions()
    }

    @objc private func resetRemoteColor() {
        colorWell.color = .clear
    }

    private func updateAdvancedOptions() {
        let visible = AppSettingsStore.shared.remoteManagementPreferences.showAdvancedOptions
        colorRow?.isHidden = !visible
        prefixRow?.isHidden = !visible
        advancedButton.title = visible ? "Hide advanced options" : "Show advanced options"
        advancedButton.image = NSImage(
            systemSymbolName: visible ? "chevron.down" : "chevron.right",
            accessibilityDescription: advancedButton.title
        )
    }

    @objc private func browseRemoteURL() {
        browseURL(into: urlField)
    }

    @objc private func browsePushRemoteURL() {
        browseURL(into: pushURLField)
    }

    private func browseURL(into field: NSComboBox) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { field.stringValue = url.path }
    }

    @objc private func saveRemote() {
        let oldFetchURL = selected?.fetchURL
        let oldPushURL = selected?.pushURL
        let request = RepositoryRemoteSaveRequest(
            originalName: isCreating ? nil : selected?.name,
            name: nameField.stringValue,
            fetchURL: urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            pushURL: separatePushURL.state == .on ? pushURLField.stringValue : nil,
            puttyKeyFile: selected?.puttyKeyFile,
            color: colorWell.color.hexString,
            prefix: normalizedPrefix(prefixField.stringValue)
        )
        let selectedName = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        task?.cancel()
        setBusy(true, text: "Saving remote…")
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await source.saveRemote(request)
                AppSettingsStore.shared.replaceRemoteURLHistory(oldFetchURL, with: request.fetchURL)
                if let pushURL = request.pushURL {
                    AppSettingsStore.shared.replaceRemoteURLHistory(oldPushURL, with: pushURL)
                }
                if let window = view.window {
                    await onFetchRemote(selectedName, window)
                }
                onRepositoryChanged()
                reload(selectingRemote: selectedName, selectingTab: .remotes)
            } catch is CancellationError {
                setBusy(false, text: "")
            } catch {
                setBusy(false, text: error.localizedDescription)
                showError(error)
            }
        }
    }

    @objc private func deleteRemote() {
        guard let selected else { return }
        let alert = NSAlert()
        alert.messageText = "Delete remote ‘\(selected.name)’?"
        alert.informativeText = selected.isDisabled ? "The inactive remote configuration will be removed." : "The remote and its remote-tracking references will be removed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        mutate("Deleting remote…", selectingRemote: nil, selectingLocalBranch: nil, selectingTab: .remotes) { [source] in
            try await source.deleteRemote(named: selected.name, disabled: selected.isDisabled)
        }
    }

    @objc private func toggleRemote() {
        guard let selected else { return }
        mutate(
            selected.isDisabled ? "Activating remote…" : "Deactivating remote…",
            selectingRemote: selected.name,
            selectingLocalBranch: nil,
            selectingTab: .remotes
        ) { [source] in
            try await source.setRemote(named: selected.name, disabled: !selected.isDisabled)
        }
    }

    private func mutate(
        _ message: String,
        selectingRemote remoteName: String?,
        selectingLocalBranch localBranch: String?,
        selectingTab tab: DialogTab,
        operation: @escaping @Sendable () async throws -> Void
    ) {
        task?.cancel()
        setBusy(true, text: message)
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await operation()
                onRepositoryChanged()
                reload(selectingRemote: remoteName, selectingLocalBranch: localBranch, selectingTab: tab)
            } catch is CancellationError {
                setBusy(false, text: "")
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
        [trackingLocalField, trackingRemoteCombo, trackingMergeCombo].forEach { $0.isEnabled = !busy && selectedTrackingRow != nil }
        trackingSaveButton.isEnabled = !busy && selectedTrackingRow != nil
        updateSaveButtonState(busy: busy)
        deleteButton.isEnabled = !busy && selected != nil
        toggleButton.isEnabled = !busy && selected != nil
    }

    private func updateSaveButtonState(busy: Bool = false) {
        saveButton.isEnabled = !busy
            && selected?.isDisabled != true
            && !nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selectedTrackingBranchName: String? {
        selectedTrackingRow.flatMap { tracking.indices.contains($0) ? tracking[$0].branchName : nil }
    }

    private func normalizedPrefix(_ value: String) -> String {
        let preferences = AppSettingsStore.shared.checkoutBranchPreferences
        let normalized = RepositoryBranchNameNormalizer.normalize(
            value,
            replacementToken: preferences.branchNameReplacement,
            allowTrailingSlash: true
        )
        prefixField.stringValue = normalized
        return normalized
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
        let value = switch id {
        case "branch": configuration.branchName
        case "remote": configuration.remoteName ?? ""
        default: configuration.mergeBranch ?? ""
        }
        let field = NSTextField(labelWithString: value)
        field.lineBreakMode = .byTruncatingMiddle
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSTableView === trackingTable else { return }
        let row = trackingTable.selectedRow
        guard tracking.indices.contains(row) else {
            selectedTrackingRow = nil
            showTracking(nil)
            return
        }
        selectedTrackingRow = row
        showTracking(tracking[row])
    }

    private func showTracking(_ configuration: RepositoryBranchTrackingConfiguration?) {
        trackingLocalField.stringValue = configuration?.branchName ?? ""
        trackingRemoteCombo.removeAllItems()
        trackingRemoteCombo.addItem(withObjectValue: "")
        trackingRemoteCombo.addItems(withObjectValues: configurations.map(\.name).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        })
        trackingRemoteCombo.stringValue = configuration?.remoteName ?? ""
        populateTrackingMergeChoices(selected: configuration?.mergeBranch)
        let enabled = configuration != nil
        [trackingLocalField, trackingRemoteCombo, trackingMergeCombo].forEach { $0.isEnabled = enabled }
        trackingSaveButton.isEnabled = enabled
    }

    @objc private func trackingRemoteChanged() {
        if trackingMergeCombo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !trackingRemoteCombo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            trackingMergeCombo.stringValue = trackingLocalField.stringValue
        }
        populateTrackingMergeChoices(selected: trackingMergeCombo.stringValue)
    }

    private func populateTrackingMergeChoices(selected: String?) {
        let remote = trackingRemoteCombo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let values = Set((remoteBranches[remote] ?? []) + [selected, trackingLocalField.stringValue].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        })
        trackingMergeCombo.removeAllItems()
        trackingMergeCombo.addItem(withObjectValue: "")
        trackingMergeCombo.addItems(withObjectValues: values.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        })
        trackingMergeCombo.stringValue = selected ?? ""
    }

    @objc private func saveTracking() {
        guard let branch = selectedTrackingBranchName else { return }
        let remote = trackingRemoteCombo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let merge = trackingMergeCombo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = RepositoryBranchTrackingConfiguration(
            branchName: branch,
            remoteName: remote.isEmpty ? nil : remote,
            mergeBranch: merge.isEmpty ? nil : merge
        )
        mutate(
            "Saving pull behavior…",
            selectingRemote: selected?.name,
            selectingLocalBranch: branch,
            selectingTab: .tracking
        ) { [source] in
            try await source.setBranchTracking(updated)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === nameField {
            updateSaveButtonState()
        }
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let combo = notification.object as? NSComboBox,
              combo === urlField || combo === pushURLField else { return }
        populateGeneratedURLs(in: combo, usesPushURL: combo === pushURLField)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if notification.object as? NSTextField === prefixField {
            _ = normalizedPrefix(prefixField.stringValue)
        }
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSComboBox === trackingRemoteCombo {
            trackingRemoteChanged()
        }
    }

    private func populateGeneratedURLs(in combo: NSComboBox, usesPushURL: Bool) {
        let current = combo.stringValue
        let enteredName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let genericNames: Set<String> = ["origin", "upstream", "fork", "remote", "internal"]
        let replacement = enteredName.isEmpty || genericNames.contains(enteredName) ? "TO_REPLACE" : enteredName
        let recentURLs = AppSettingsStore.shared.remoteManagementPreferences.recentURLs
        var generated = Set<String>()
        for remote in configurations {
            let value = usesPushURL ? (remote.pushURL ?? remote.fetchURL) : remote.fetchURL
            guard !value.isEmpty else { continue }
            generated.insert(value.replacingOccurrences(of: "\(remote.name)/", with: "\(replacement)/"))
            if let ownerRange = hostingOwnerRange(in: value) {
                var candidate = value
                candidate.replaceSubrange(ownerRange, with: replacement)
                generated.insert(candidate)
            }
        }
        let candidates = recentURLs + generated
            .filter { !recentURLs.contains($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        combo.removeAllItems()
        combo.addItems(withObjectValues: candidates)
        combo.stringValue = current
    }

    private func hostingOwnerRange(in value: String) -> Range<String.Index>? {
        let separator: String.Index
        if let scheme = value.range(of: "://") {
            guard let slash = value[scheme.upperBound...].firstIndex(of: "/") else { return nil }
            separator = slash
        } else if let colon = value.firstIndex(of: ":"), value[..<colon].contains("@") {
            separator = colon
        } else {
            return nil
        }
        let ownerStart = value.index(after: separator)
        guard ownerStart < value.endIndex,
              let ownerEnd = value[ownerStart...].firstIndex(of: "/"),
              ownerStart < ownerEnd else { return nil }
        return ownerStart..<ownerEnd
    }

    override func cancelOperation(_ sender: Any?) {
        view.window?.performClose(sender)
    }

    func windowWillClose(_ notification: Notification) {
        task?.cancel()
        if let size = view.window?.contentView?.bounds.size {
            var preferences = AppSettingsStore.shared.remoteManagementPreferences
            preferences.windowWidth = size.width
            preferences.windowHeight = size.height
            AppSettingsStore.shared.saveRemoteManagementPreferences(preferences)
        }
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
