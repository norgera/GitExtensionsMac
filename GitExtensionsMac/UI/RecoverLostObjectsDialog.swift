import GitExtensionsCore
import GitCommands
import AppKit


@MainActor
final class RecoverLostObjectsWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    enum Strings {
        static let title = "Verify database"
        static let help = "By default only unreferenced objects that are older than \n2 weeks are removed when cleaning up the database. All\nother object are only deleted when you run \"Remove all\ndangling objects\"\n\nCheck commits you want to recover and press Recover button\nContext menu for additional operations"
        static let quickView = "Double-click on a row for quick view"
        static let showOther = "Show blobs and trees"
        static let showOtherTip = "To recover contents of files once staged but mistakenly deleted"
        static let showCommits = "Show commits and annotated tags"
        static let showCommitsTip = "To recover unreachable commits or annotated tags"
        static let noReflogs = "Do not consider commits that are referenced only by an entry in a \nreflog to be reachable."
        static let fullCheck = "Check not just objects in GIT_OBJECT_DIRECTORY ($GIT_DIR/objects), \nbut also the ones found in alternate object pools."
        static let unreachable = "Print out objects that exist but that aren't readable from any of the reference \nnodes."
        static let removeQuestion = "Are you sure you want to delete all dangling objects?"
        static let removeCaption = "Remove"
        static let selectToRestore = "Select objects to restore."
        static let selectToRestoreCaption = "Restore lost objects"
        static let seemingly = "seemingly"
        static func tagsCreated(_ count: Int) -> String { "\(count) Tags created.\n\nDo not forget to delete these tags when finished." }
    }


    struct Actions {
        var runProcess: (_ window: NSWindow, _ operation: @escaping HostingProcessDialog.Operation) async -> Bool
        var createTag: (_ id: ObjectID, _ window: NSWindow, _ finished: @escaping (Bool) -> Void) -> Void
        var createBranch: (_ id: ObjectID, _ window: NSWindow, _ finished: @escaping (Bool) -> Void) -> Void
        var createLightweightTag: (_ name: String, _ id: ObjectID) async throws -> Void
        var deleteTag: (_ name: String) async throws -> Void
    }

    private let source: any RepositoryLostObjectsDataSource
    private let actions: Actions
    private let workingDirectory: URL?
    private let onClose: () -> Void

    let table = LostObjectsTableView()
    let unreachable = NSButton(checkboxWithTitle: Strings.unreachable, target: nil, action: nil)
    let fullCheck = NSButton(checkboxWithTitle: Strings.fullCheck, target: nil, action: nil)
    let noReflogs = NSButton(checkboxWithTitle: Strings.noReflogs, target: nil, action: nil)
    let showCommitsAndTags = NSButton(checkboxWithTitle: Strings.showCommits, target: nil, action: nil)
    let showOtherObjects = NSButton(checkboxWithTitle: Strings.showOther, target: nil, action: nil)
    private let diffViewer = DiffContentViewController()
    private let fileViewer = RevisionFileContentViewController()
    private let previewContainer = NSView()

    private(set) var lostObjects: [LostObject] = []

    private(set) var displayed: [LostObject] = []
    private(set) var checked: Set<ObjectID> = []
    private var detectedBlobs: Set<ObjectID> = []
    private var previewedID: ObjectID?
    private(set) var defaultFileName: String?
    private var viewWindows: [NSWindowController] = []
    private(set) var isBusy = false
    private var closing = false

    init(source: any RepositoryLostObjectsDataSource, actions: Actions, workingDirectory: URL?, onClose: @escaping () -> Void) {
        self.source = source
        self.actions = actions
        self.workingDirectory = workingDirectory
        self.onClose = onClose
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 859, height: 575),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = Strings.title
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 760, height: 460)
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
        showCommitsAndTags.state = .on
        noReflogs.state = .on
    }

    required init?(coder: NSCoder) { nil }

    var options: LostObjectsOptions {
        LostObjectsOptions(unreachable: unreachable.state == .on, fullCheck: fullCheck.state == .on, noReflogs: noReflogs.state == .on)
    }



    private func makeContent() -> NSView {
        let root = NSView()



        let help = NSTextField(labelWithString: Strings.help)
        help.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let quickView = NSTextField(labelWithString: Strings.quickView)
        quickView.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let labels = NSStackView(views: [help, quickView])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 6
        for (button, action) in [(unreachable, #selector(optionChanged)), (fullCheck, #selector(optionChanged)), (noReflogs, #selector(optionChanged)),
                                 (showCommitsAndTags, #selector(showCommitsChanged)), (showOtherObjects, #selector(showOtherChanged))] {
            button.target = self
            button.action = action
        }
        showCommitsAndTags.toolTip = Strings.showCommitsTip
        showOtherObjects.toolTip = Strings.showOtherTip
        let showRow = NSStackView(views: [showCommitsAndTags, showOtherObjects])
        showRow.spacing = 20
        let optionsStack = NSStackView(views: [showRow, noReflogs, unreachable, fullCheck])
        optionsStack.orientation = .vertical
        optionsStack.alignment = .leading
        optionsStack.spacing = 6
        let top = NSStackView(views: [labels, optionsStack])
        top.alignment = .top
        top.spacing = 60
        top.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        for view in [top, labels, optionsStack] { view.setHuggingPriority(.required, for: .vertical) }
        bottomHugging = top


        let columns: [(String, String, CGFloat)] = [("check", "", 22), ("date", "Date", 150), ("type", "Type", 110), ("subject", "Subject", 200),
                                                   ("author", "Author", 150), ("hash", "Hash", 120), ("parent", "Parent(s) hashs", 120)]
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            column.minWidth = id == "check" ? 22 : 25
            if ["date", "type", "subject", "author", "hash"].contains(id) {
                column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: id != "date")
            }
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = false
        table.allowsColumnReordering = true
        table.usesAlternatingRowBackgroundColors = true
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        table.onReturn = { [weak self] in self?.viewCurrentItem() }
        table.keyEquivalentMenu = { [weak self] in self?.contextMenu() ?? NSMenu() }
        table.setAccessibilityIdentifier("RecoverLostObjects.Warnings")
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder


        diffViewer.supportedFileCommands = []
        for view in [diffViewer.view, fileViewer.view] {
            view.translatesAutoresizingMaskIntoConstraints = false
            previewContainer.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: previewContainer.topAnchor),
                view.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
                view.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor)
            ])

            let trailing = view.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor)
            trailing.priority = .init(200)
            trailing.isActive = true
        }
        previewContainer.wantsLayer = true
        previewContainer.layer?.masksToBounds = true
        fileViewer.view.isHidden = true
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(scroll)
        split.addArrangedSubview(previewContainer)
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 0)


        func button(_ title: String, _ selector: Selector, id: String) -> NSButton {
            let button = NSButton(title: title, target: self, action: selector)
            button.setAccessibilityIdentifier("RecoverLostObjects.\(id)")
            return button
        }
        let remove = button("Remove all dangling objects", #selector(removeClicked), id: "Remove")
        let deleteTags = button("Delete all LOST_AND_FOUND tags", #selector(deleteTagsClicked), id: "DeleteTags")
        let restore = button("Recover selected objects", #selector(restoreClicked), id: "Recover")
        let save = button("Save objects to .git/lost-found", #selector(saveObjectsClicked), id: "SaveObjects")
        let cancel = button("Cancel", #selector(cancelClicked), id: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        for view in [remove, deleteTags, save, cancel] { view.widthAnchor.constraint(equalToConstant: 230).isActive = true }
        let left = NSStackView(views: [remove, deleteTags])
        left.orientation = .vertical
        left.spacing = 2
        let right = NSStackView(views: [save, cancel])
        right.orientation = .vertical
        right.spacing = 2
        let bottom = NSStackView(views: [left, restore, right])
        bottom.distribution = .fill
        bottom.spacing = 12
        bottom.edgeInsets = NSEdgeInsets(top: 4, left: 3, bottom: 6, right: 8)
        restore.setContentHuggingPriority(.init(1), for: .horizontal)
        for view in [bottom, left, right] { view.setHuggingPriority(.required, for: .vertical) }

        for view in [top, split, bottom] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: root.topAnchor),
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            top.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor),
            split.topAnchor.constraint(equalTo: top.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottom.topAnchor.constraint(equalTo: split.bottomAnchor),
            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            split.heightAnchor.constraint(greaterThanOrEqualToConstant: 200)
        ])
        splitView = split
        return root
    }

    private weak var bottomHugging: NSView?
    private weak var splitView: NSSplitView?
    private var didPositionSplitter = false


    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard !didPositionSplitter, let window, let splitView else { return }
        didPositionSplitter = true
        window.contentView?.layoutSubtreeIfNeeded()
        splitView.setPosition(700, ofDividerAt: 0)
        DispatchQueue.main.async { [weak splitView] in splitView?.setPosition(700, ofDividerAt: 0) }
    }





    @discardableResult
    func updateLostObjects() async -> Bool {
        guard let window else { return false }
        isBusy = true
        defer { isBusy = false }
        let captured = CapturedResult()
        let options = self.options
        let source = self.source
        _ = await actions.runProcess(window) { output in
            let result = try await source.checkObjects(options, output: output)
            captured.result = result
            guard result.succeeded else {
                throw GitError.commandFailed(arguments: result.arguments, status: result.exitStatus, stderr: result.standardErrorString)
            }
            return true
        }
        guard let result = captured.result else {
            closeForm()
            return false
        }
        do { lostObjects = try await source.lostObjects(fromFsckOutput: result.standardOutputString) }
        catch {
            lostObjects = []
            await RepositoryFileEditorDialogs.message(error.localizedDescription, caption: "Error", window: window)
        }
        detectedBlobs = []
        updateFilteredLostObjects()
        return true
    }


    func updateFilteredLostObjects() {
        checked = []
        previewedID = nil
        let showCommits = showCommitsAndTags.state == .on
        let showOther = showOtherObjects.state == .on
        displayed = sorted(lostObjects.filter { ($0.isCommitOrTag && showCommits) || (!$0.isCommitOrTag && showOther) })
        for id in ["author", "subject", "parent"] {
            table.tableColumn(withIdentifier: .init(id))?.isHidden = !showCommits
        }
        table.reloadData()
        if !displayed.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) } else { clearPreview() }
        if showOther { detectBlobTypes() }
    }


    private func detectBlobTypes() {
        let blobs = lostObjects.filter { $0.objectType == .blob && !detectedBlobs.contains($0.objectID) }
        guard !blobs.isEmpty else { return }
        blobs.forEach { detectedBlobs.insert($0.objectID) }
        Task { @MainActor [weak self] in
            guard let self else { return }
            for blob in blobs {
                guard let data = try? await source.showObject(blob.objectID) else { continue }
                let suffix = " (\(Strings.seemingly): \(LostObjectsCommands.guessFileType(data)))"
                for index in lostObjects.indices where lostObjects[index].objectID == blob.objectID { lostObjects[index].rawType += suffix }
                for index in displayed.indices where displayed[index].objectID == blob.objectID { displayed[index].rawType += suffix }
            }
            table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<displayed.count), columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))

            if let column = table.tableColumn(withIdentifier: .init("type")) {
                let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
                let widest = displayed.map { ($0.rawType as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
                column.width = max(column.width, ceil(widest) + 12)
            }
        }
    }

    private func sorted(_ objects: [LostObject]) -> [LostObject] {
        guard let descriptor = table.sortDescriptors.first, let key = descriptor.key else { return objects }
        func less(_ a: LostObject, _ b: LostObject) -> Bool? {
            switch key {
            case "date":
                switch (a.date, b.date) {
                case let (l?, r?): return l == r ? nil : l < r
                case (nil, _?): return true
                case (_?, nil): return false
                default: return nil
                }
            case "type": return a.rawType == b.rawType ? nil : a.rawType < b.rawType
            case "subject": return (a.subject ?? "") == (b.subject ?? "") ? nil : (a.subject ?? "").localizedCompare(b.subject ?? "") == .orderedAscending
            case "author": return (a.author ?? "") == (b.author ?? "") ? nil : (a.author ?? "").localizedCompare(b.author ?? "") == .orderedAscending
            case "hash": return a.objectID == b.objectID ? nil : a.objectID < b.objectID
            default: return nil
            }
        }
        return objects.enumerated().sorted { lhs, rhs in
            guard let result = less(lhs.element, rhs.element) else { return lhs.offset < rhs.offset }
            return descriptor.ascending ? result : !result
        }.map(\.element)
    }

    var currentItem: LostObject? {
        let row = table.selectedRow
        return displayed.indices.contains(row) ? displayed[row] : nil
    }




    private func clearPreview() {
        defaultFileName = nil
        diffViewer.view.isHidden = true
        fileViewer.view.isHidden = true
    }

    private static let patchFile = ChangedFile(id: "commit.patch", path: "commit.patch", oldPath: nil, changeType: .modified, additions: 0, deletions: 0)

    func previewCurrentItem() async {
        defaultFileName = nil
        guard let item = currentItem, item.objectID != previewedID else { return }
        previewedID = item.objectID
        let data = (try? await source.showObject(item.objectID)) ?? Data()
        guard currentItem?.objectID == item.objectID else { return }
        switch item.objectType {
        case .commit, .tag:
            defaultFileName = "commit.patch"
            fileViewer.view.isHidden = true
            diffViewer.view.isHidden = false
            diffViewer.apply(file: Self.patchFile, diff: FileDiff(id: item.objectID.string, fileID: "commit.patch",
                                                                  lines: FixedPatchLines.lines(String(decoding: data, as: UTF8.self))))
        case .blob, .tree, .other:
            let name = item.objectType == .blob ? LostObjectsCommands.guessFileName(data, id: item.objectID) : "file.txt"
            defaultFileName = name
            diffViewer.view.isHidden = true
            fileViewer.view.isHidden = false
            fileViewer.apply(content: FileContentDecoder.decode(data, path: name, requestedEncoding: .automatic), revisionLabel: item.objectID.shortString)
        }
    }



    func numberOfRows(in tableView: NSTableView) -> Int { displayed.count }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn?.identifier.rawValue, displayed.indices.contains(row) else { return nil }
        let object = displayed[row]
        if column == "check" {
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkToggled(_:)))
            box.state = checked.contains(object.objectID) ? .on : .off
            box.tag = row
            box.setAccessibilityIdentifier("RecoverLostObjects.Check.\(row)")
            return box
        }
        let text: String
        switch column {
        case "date": text = object.date.map(Self.dateFormatter.string) ?? ""
        case "type": text = object.rawType
        case "subject": text = object.subject ?? ""
        case "author": text = object.author ?? ""
        case "hash": text = object.objectID.string
        case "parent": text = object.parent?.string ?? ""
        default: text = ""
        }
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingTail
        field.toolTip = text
        return field
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        let selected = currentItem?.objectID
        let keep = checked
        displayed = sorted(displayed)
        checked = keep
        tableView.reloadData()
        if let selected, let row = displayed.firstIndex(where: { $0.objectID == selected }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        Task { @MainActor [weak self] in await self?.previewCurrentItem() }
    }


    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard tableColumn.identifier.rawValue == "check" else { return }
        let all = Set(displayed.map(\.objectID))
        checked = checked == all ? [] : all
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<displayed.count), columnIndexes: IndexSet(integer: 0))
    }

    @objc private func checkToggled(_ sender: NSButton) {
        guard displayed.indices.contains(sender.tag) else { return }
        let id = displayed[sender.tag].objectID
        if sender.state == .on { checked.insert(id) } else { checked.remove(id) }
    }

    func setChecked(_ ids: Set<ObjectID>) {
        checked = ids
        table.reloadData()
    }


    @objc private func doubleClicked() {
        guard table.clickedRow >= 0, table.clickedColumn != 0 else { return }
        viewCurrentItem()
    }



    @objc private func optionChanged() { Task { await updateLostObjects() } }


    @objc private func showCommitsChanged() {
        if showCommitsAndTags.state == .off && showOtherObjects.state == .off { showOtherObjects.state = .on }
        updateFilteredLostObjects()
    }

    @objc private func showOtherChanged() {
        if showCommitsAndTags.state == .off && showOtherObjects.state == .off { showCommitsAndTags.state = .on }
        updateFilteredLostObjects()
    }



    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if table.clickedRow >= 0, table.clickedRow != table.selectedRow {
            table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
        }
        guard let item = currentItem else { return }
        let isCommit = item.objectType == .commit
        func add(_ title: String, _ selector: Selector, key: String = "", enabled: Bool = true, id: String) {
            let menuItem = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            menuItem.target = self
            menuItem.isEnabled = enabled
            menuItem.identifier = .init("lostObjects.\(id)")
            menu.addItem(menuItem)
        }
        add("View", #selector(viewClicked), id: "view")
        add("Create tag", #selector(createTagClicked), key: "t", enabled: isCommit, id: "createTag")
        add("Create branch", #selector(createBranchClicked), key: "b", enabled: isCommit, id: "createBranch")
        add("Copy object hash", #selector(copyHashClicked), id: "copyHash")
        add("Copy parent hash", #selector(copyParentClicked), enabled: isCommit, id: "copyParent")
        add("Save as...", #selector(saveAsClicked), key: "s", enabled: item.objectType == .blob, id: "saveAs")
    }

    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menuNeedsUpdate(menu)
        return menu
    }

    @objc private func viewClicked() { viewCurrentItem() }


    func viewCurrentItem() {
        guard let item = currentItem else { return }
        Task { @MainActor [weak self] in
            guard let self, let data = try? await source.showObject(item.objectID), !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            let controller = ReadOnlyTextWindowController(title: "View", text: text) { [weak self] closed in
                self?.viewWindows.removeAll { $0 === closed }
            }
            viewWindows.append(controller)
            if let window, let viewWindow = controller.window {
                viewWindow.setFrameOrigin(NSPoint(x: window.frame.midX - viewWindow.frame.width / 2, y: window.frame.midY - viewWindow.frame.height / 2))
            }
            controller.showWindow(nil)
        }
    }

    var openViewWindows: [NSWindowController] { viewWindows }

    @objc func createTagClicked() {
        guard let item = currentItem, item.objectType == .commit, let window else { return }
        actions.createTag(item.objectID, window) { [weak self] created in
            if created { Task { await self?.updateLostObjects() } }
        }
    }

    @objc func createBranchClicked() {
        guard let item = currentItem, item.objectType == .commit, let window else { return }
        actions.createBranch(item.objectID, window) { [weak self] created in
            if created { Task { await self?.updateLostObjects() } }
        }
    }

    @objc func copyHashClicked() {
        guard let item = currentItem else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.objectID.string, forType: .string)
    }

    @objc func copyParentClicked() {
        guard let parent = currentItem?.parent else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(parent.string, forType: .string)
    }


    @objc func saveAsClicked() {
        guard let item = currentItem, item.objectType == .blob, let window else { return }
        let name = defaultFileName ?? "\(item.objectID.string)_LOST_FOUND.txt"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.directoryURL = workingDirectory
        panel.isExtensionHidden = false
        panel.allowsOtherFileTypes = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in
                do { try await self.source.saveBlob(item.objectID, to: url) }
                catch { await RepositoryFileEditorDialogs.message(error.localizedDescription, caption: "Error", window: window) }
            }
        }
    }



    @objc private func saveObjectsClicked() {
        guard let window else { return }
        let options = self.options
        let source = self.source
        Task { @MainActor [weak self] in
            _ = await self?.actions.runProcess(window) { output in
                let result = try await source.saveLostObjects(options, output: output)
                guard result.succeeded else { throw GitError.commandFailed(arguments: result.arguments, status: result.exitStatus, stderr: result.standardErrorString) }
                return true
            }
            await self?.updateLostObjects()
        }
    }

    @objc private func removeClicked() {
        guard let window else { return }
        let source = self.source
        Task { @MainActor [weak self] in
            let alert = NSAlert()
            alert.messageText = Strings.removeCaption
            alert.informativeText = Strings.removeQuestion
            alert.addButton(withTitle: "Yes")
            alert.addButton(withTitle: "No")
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
            _ = await self?.actions.runProcess(window) { output in
                let result = try await source.pruneObjects(output: output)
                guard result.succeeded else { throw GitError.commandFailed(arguments: result.arguments, status: result.exitStatus, stderr: result.standardErrorString) }
                return true
            }
            await self?.updateLostObjects()
        }
    }

    @objc private func deleteTagsClicked() {
        Task { @MainActor [weak self] in
            await self?.deleteLostFoundTags()
            await self?.updateLostObjects()
        }
    }


    func deleteLostFoundTags() async {
        for name in (try? await source.lostFoundTagNames()) ?? [] { try? await actions.deleteTag(name) }
    }

    @objc private func restoreClicked() { Task { await restoreSelectedObjects() } }


    func restoreSelectedObjects() async {
        guard let window else { return }
        await deleteLostFoundTags()
        let selected = displayed.filter { checked.contains($0.objectID) }
        guard !selected.isEmpty else {
            await RepositoryFileEditorDialogs.message(Strings.selectToRestore, caption: Strings.selectToRestoreCaption, window: window, style: .warning)
            return
        }
        var count = 0
        for object in selected {
            count += 1
            let name = LostObjectsCommands.restoredObjectsTagPrefix + (object.objectType == .tag ? (object.tagName ?? "") : String(count))
            do { try await actions.createLightweightTag(name, object.objectID) }
            catch { await RepositoryFileEditorDialogs.message(error.localizedDescription, caption: "Error", window: window) }
        }
        await RepositoryFileEditorDialogs.message(Strings.tagsCreated(count), caption: "Tags created", window: window, style: .informational)

        if count == displayed.count {
            closeForm()
            return
        }
        await updateLostObjects()
    }

    @objc private func cancelClicked() { closeForm() }

    func closeForm() {
        closing = true
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        viewWindows.forEach { $0.close() }
        onClose()
    }
}


private final class CapturedResult: @unchecked Sendable {
    var result: GitCommandResult?
}


final class LostObjectsTableView: NSTableView {
    var onReturn: (() -> Void)?

    var keyEquivalentMenu: (() -> NSMenu)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, let menu = keyEquivalentMenu?(), menu.performKeyEquivalent(with: event) { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onReturn?(); return }
        super.keyDown(with: event)
    }
}


@MainActor
final class ReadOnlyTextWindowController: NSWindowController, NSWindowDelegate {
    let editor = EditableFileTextView()
    private let onClose: (NSWindowController) -> Void

    init(title: String, text: String, onClose: @escaping (NSWindowController) -> Void) {
        self.onClose = onClose
        let window = RepositoryFileEditorWindow(contentRect: NSRect(x: 0, y: 0, width: 733, height: 571),
                                                styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        editor.text = text
        editor.textView.isEditable = false
        editor.textView.onEscape = { [weak window] in window?.performClose(nil); return true }
        window.contentView = editor
        window.initialFirstResponder = editor.textView
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) { onClose(self) }
}
