import GitExtensionsCore
import GitCommands
import AppKit



@MainActor
final class BlameViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {

    struct Context {

        var revisionInGrid: (ObjectID) -> Commit?

        var selectFileInRevision: (ObjectID, String) -> Bool

        var hostedRemotes: () async -> [HostedRemote] = { [] }
    }

    var source: (any RepositoryBlameDataSource)?
    var context: Context?
    var onShowChanges: ((ObjectID) -> Void)?

    let table = BlameTableView()
    private let scroll = NSScrollView()
    private let authorTable = BlameTableView()
    private let authorScroll = NSScrollView()
    private var synchronizing = false
    private var scrollObservers: [NSObjectProtocol] = []
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var blame: BlameResult?
    private var syntaxStates: [Int?] = []
    private(set) var blameID: ObjectID?
    private(set) var fileName: String?
    private var encoding: RepositoryTextEncoding?
    private var gutterTexts: [String] = []
    private var ageBuckets: [Int] = []
    private var actualParents: [ObjectID: [ObjectID]] = [:]

    private var clickedBlameLine: BlameLine?

    private(set) var lastBlameLine: BlameLine?
    private(set) var highlightedCommit: BlameCommit?
    private(set) var isLoading = false
    private var loadTask: Task<Void, Never>?
    private var hostedRemotes: [HostedRemote] = []
    private var preferencesObserver: NSObjectProtocol?
    private var generation = 0
    private var searchQuery = ""
    private var occurrences = FileViewerOccurrences()
    private var syntaxEnabled = AppSettingsStore.shared.preferencesForNewFileViewer().showsSyntaxHighlighting
    var onSelectedCommit: ((BlameCommit) -> Void)?


    static let ageBucketColors: [NSColor] = [(247, 252, 245), (199, 233, 192), (161, 217, 155), (116, 196, 118), (65, 171, 93), (35, 139, 69), (0, 68, 27)]
        .map { red, green, blue in
            NSColor(name: nil) { appearance in
                let color = NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
                guard appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua else { return color }
                var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
                color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
                return NSColor(calibratedHue: hue, saturation: saturation, brightness: 1 - brightness * 0.8, alpha: alpha)
            }
        }

    deinit {
        loadTask?.cancel()
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
        for observer in scrollObservers { NotificationCenter.default.removeObserver(observer) }
    }

    override func loadView() {
        let root = NSView()
        table.headerView = nil
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowHeight = AppSettingsStore.shared.diffLineHeight
        table.backgroundColor = ApplicationColors.color("EditorBackground", fallback: .textBackgroundColor)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.onHover = { [weak self] row in self?.hover(row: row) }
        table.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        table.setAccessibilityIdentifier("Blame.Lines")
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        table.menu = menu
        authorTable.headerView = nil
        authorTable.intercellSpacing = .zero
        authorTable.rowHeight = table.rowHeight
        authorTable.backgroundColor = table.backgroundColor
        authorTable.dataSource = self
        authorTable.allowsMultipleSelection = true
        authorTable.delegate = self
        authorTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        authorTable.target = self
        authorTable.doubleAction = #selector(doubleClicked)
        authorTable.onHover = table.onHover
        authorTable.onKey = table.onKey
        let authorMenu = NSMenu()
        authorMenu.delegate = self
        authorMenu.autoenablesItems = false
        authorTable.menu = authorMenu
        rebuildColumns()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.isHidden = true
        messageLabel.isSelectable = true
        authorScroll.documentView = authorTable
        authorScroll.hasVerticalScroller = false
        authorScroll.hasHorizontalScroller = true
        authorScroll.autohidesScrollers = false
        scroll.autohidesScrollers = false
        let panes = NSSplitView()
        panes.isVertical = true
        panes.dividerStyle = .thin
        panes.translatesAutoresizingMaskIntoConstraints = false
        panes.addArrangedSubview(authorScroll)
        panes.addArrangedSubview(scroll)
        authorScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 75).isActive = true
        let initialWidth = authorScroll.widthAnchor.constraint(equalToConstant: 220)
        initialWidth.priority = .defaultLow
        initialWidth.isActive = true
        root.addSubview(panes)
        for (from, to) in [(scroll, authorScroll), (authorScroll, scroll)] {
            from.contentView.postsBoundsChangedNotifications = true
            scrollObservers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: from.contentView, queue: .main) { [weak self, weak from, weak to] _ in
                MainActor.assumeIsolated {
                    guard let self, let from, let to, !self.synchronizing else { return }
                    self.synchronizing = true
                    to.contentView.scroll(to: NSPoint(x: to.contentView.bounds.origin.x, y: from.contentView.bounds.origin.y))
                    to.reflectScrolledClipView(to.contentView)
                    self.synchronizing = false
                }
            })
        }
        root.addSubview(messageLabel)
        NSLayoutConstraint.activate([
            panes.topAnchor.constraint(equalTo: root.topAnchor),
            panes.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            panes.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            panes.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            messageLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            messageLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            messageLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8)
        ])
        view = root
        preferencesObserver = NotificationCenter.default.addObserver(forName: .blamePreferencesDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferencesChanged() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(viewerSettingsChanged), name: .fileViewerSettingsApplied, object: nil)
    }

    @objc private func viewerSettingsChanged() {
        syntaxEnabled = AppSettingsStore.shared.preferencesForNewFileViewer().showsSyntaxHighlighting
        table.rowHeight = AppSettingsStore.shared.diffLineHeight
        authorTable.rowHeight = table.rowHeight
        preferencesChanged()
    }


    private func preferencesChanged() {
        let line = currentFileLine
        rebuildColumns()
        guard let blameID, let fileName, let encoding else { return }
        load(revision: blameID, file: fileName, encoding: encoding, initialLine: line, force: true)
    }

    private var preferences: BlamePreferences { AppSettingsStore.shared.blamePreferences }

    private func rebuildColumns() {
        for column in table.tableColumns { table.removeTableColumn(column) }
        for column in authorTable.tableColumns { authorTable.removeTableColumn(column) }
        func add(_ id: String, width: CGFloat, resizable: Bool = false) {
            let column = NSTableColumn(identifier: .init(id))
            column.width = width
            column.minWidth = id == "content" ? 100 : 4
            column.resizingMask = resizable ? .userResizingMask : []
            (id == "content" || id == "line" ? table : authorTable).addTableColumn(column)
        }
        let lineHeight = table.rowHeight

        if preferences.showAuthorAvatar { add("margin", width: lineHeight + 6) }

        if preferences.showLineNumbers { add("authorLine", width: 40) }
        add("author", width: 186, resizable: true)
        add("line", width: 44)
        add("content", width: 800, resizable: true)
        reloadLines()
    }

    private func reloadLines() {
        synchronizing = true
        table.reloadData()
        authorTable.reloadData()
        synchronizing = false
    }



    var currentFileLine: Int { table.selectedRow >= 0 ? table.selectedRow + 1 : 1 }

    func cancel() {
        generation += 1
        loadTask?.cancel()
        isLoading = false
    }


    func load(revision: ObjectID, file: String, encoding: RepositoryTextEncoding, initialLine: Int? = nil, force: Bool = false) {
        _ = view
        if !force, blame != nil, !isLoading, revision == blameID, file == fileName, encoding == self.encoding {
            if let initialLine, !isLoading { goToLine(initialLine) }
            return
        }
        let line = clickedBlameLine?.originLineNumber ?? initialLine ?? (file == fileName ? currentFileLine : 1)
        fileName = file
        self.encoding = encoding
        isLoading = true
        blame = nil
        blameID = nil
        gutterTexts = []
        ageBuckets = []
        highlightedCommit = nil
        occurrences.row = -1
        occurrences.column = -1
        lastBlameLine = nil
        actualParents = [:]
        hostedRemotes = []
        messageLabel.isHidden = true
        reloadLines()
        cancel()
        isLoading = true
        let requestGeneration = generation
        let options = Self.options(preferences)
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let source else { isLoading = false; return }
            do {
                let result = try await source.blame(file: file, revision: revision, encoding: encoding, options: options)
                guard !Task.isCancelled, generation == requestGeneration else { return }
                process(result, revision: revision, file: file, line: line)
                let ids = Array(Set(result.lines.map(\.commit.objectID)))
                let parents = await source.actualParentsMap(ids)
                guard !Task.isCancelled, generation == requestGeneration else { return }
                actualParents = parents
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, generation == requestGeneration else { return }
                blame = nil
                messageLabel.stringValue = error.localizedDescription
                messageLabel.isHidden = false
                reloadLines()
            }
            isLoading = false
            let remotes = await context?.hostedRemotes() ?? []
            guard !Task.isCancelled, generation == requestGeneration else { return }
            hostedRemotes = remotes
        }
    }

    static func options(_ preferences: BlamePreferences) -> BlameOptions {
        BlameOptions(ignoreWhitespace: preferences.ignoreWhitespace, detectCopyInFile: preferences.detectCopyInFile,
                     detectCopyInAll: preferences.detectCopyInAll,
                     histogramDiffAlgorithm: AppSettingsStore.shared.fileViewerPreferences.usesHistogram)
    }

    private func process(_ result: BlameResult, revision: ObjectID, file: String, line: Int) {
        blame = result
        syntaxStates = DiffSyntaxHighlighter.lineStates(result.lines.enumerated().map {
            DiffLine(id: String($0.offset), oldLineNumber: nil, newLineNumber: $0.offset + 1, kind: .context, text: $0.element.text)
        }, filePath: file)
        gutterTexts = Self.gutter(result, fileName: file, preferences: preferences)
        ageBuckets = Self.ageBuckets(result.lines.map(\.commit.authorTime), now: Date())
        let font = AppSettingsStore.shared.codeFont

        table.tableColumn(withIdentifier: .init("content"))?.width = max(800, result.lines.map {
            ($0.text as NSString).size(withAttributes: [.font: font]).width + 16
        }.max() ?? 0)
        reloadLines()
        goToLine(min(line, result.lines.count))


        lastBlameLine = nil
        clickedBlameLine = nil
        blameID = revision
    }

    func goToLine(_ line: Int) {
        guard line >= 1, line <= table.numberOfRows else { return }
        table.selectRowIndexes(IndexSet(integer: line - 1), byExtendingSelection: false)
        table.scrollRowToVisible(line - 1)
    }


    static func gutter(_ blame: BlameResult, fileName: String, preferences: BlamePreferences) -> [String] {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = preferences.showAuthorTime ? .short : .none
        var cache: [ObjectID: String] = [:]
        var previous: BlameCommit?
        return blame.lines.map { line in
            defer { previous = line.commit }
            if line.commit === previous { return "" }
            if let cached = cache[line.commit.objectID] { return cached }
            let text = authorLine(line.commit, fileName: fileName, preferences: preferences, formatter: formatter)
            cache[line.commit.objectID] = text
            return text
        }
    }


    static func authorLine(_ commit: BlameCommit, fileName: String, preferences: BlamePreferences, formatter: DateFormatter) -> String {
        var text = ""
        if preferences.showAuthor && preferences.displayAuthorFirst {
            text += commit.author
            if preferences.showAuthorDate { text += " - " }
        }
        if preferences.showAuthorDate { text += formatter.string(from: commit.authorTime) }
        if preferences.showAuthor && !preferences.displayAuthorFirst {
            if preferences.showAuthorDate { text += " - " }
            text += commit.author
        }
        if preferences.showOriginalFilePath && fileName != commit.fileName { text += " - " + commit.fileName }
        return text
    }


    static func ageBuckets(_ dates: [Date], now: Date) -> [Int] {
        let boundary = Calendar.current.date(byAdding: .year, value: -3, to: now) ?? now
        let oldest = min(boundary, dates.filter { $0 != .distantPast }.min() ?? boundary)
        let interval = (now.timeIntervalSince(oldest) + 0.000_000_1) / Double(ageBucketColors.count)
        return dates.map { date in
            let relative = max(0, date.timeIntervalSince(oldest))
            return min(Int(relative / interval), ageBucketColors.count - 1)
        }
    }



    func numberOfRows(in tableView: NSTableView) -> Int { blame?.lines.count ?? 0 }

    private static let tooltipFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let blame, blame.lines.indices.contains(row), let id = tableColumn?.identifier.rawValue else { return nil }
        let line = blame.lines[row]
        let font = AppSettingsStore.shared.codeFont
        switch id {
        case "margin":
            let cell = BlameMarginCell()
            cell.color = Self.ageBucketColors[ageBuckets.indices.contains(row) ? ageBuckets[row] : 0]

            if row == 0 || blame.lines[row - 1].commit !== line.commit {
                cell.avatar.apply(name: line.commit.author, email: line.commit.authorMail.trimmingCharacters(in: CharacterSet(charactersIn: "<>")))
            } else {
                cell.avatar.isHidden = true
            }
            return cell
        case "authorLine", "line":
            let field = NSTextField(labelWithString: String(row + 1))
            field.font = font
            field.textColor = .secondaryLabelColor
            field.alignment = .right
            return field
        case "author":
            let field = NSTextField(labelWithString: gutterTexts.indices.contains(row) ? gutterTexts[row] : "")
            field.font = font
            field.lineBreakMode = .byClipping
            field.toolTip = line.commit.description(dateFormatter: Self.tooltipFormatter)
            return field
        default:
            let field = NSTextField(labelWithString: "")
            field.isSelectable = true
            let diffLine = DiffLine(id: String(row), oldLineNumber: nil, newLineNumber: row + 1, kind: .context, text: line.text)
            let text = DiffSyntaxHighlighter.attributedText(for: diffLine, displayText: line.text,
                                                            enabled: syntaxEnabled,
                                                            filePath: fileName ?? "",
                                                            openSpan: syntaxStates.indices.contains(row) ? syntaxStates[row] : nil)
            let attributed = NSMutableAttributedString(attributedString: text)
            FileViewerOccurrences.highlight(occurrences.term, in: attributed)
            attributed.addAttribute(.font, value: font, range: NSRange(location: 0, length: attributed.length))
            field.attributedStringValue = attributed
            field.lineBreakMode = .byClipping
            return field
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = BlameRowView()
        rowView.isCommitHighlighted = isHighlighted(row)
        return rowView
    }

    private func isHighlighted(_ row: Int) -> Bool {
        guard let highlightedCommit, let blame, blame.lines.indices.contains(row) else { return false }
        return blame.lines[row].commit === highlightedCommit
    }


    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !synchronizing else { return }
        synchronizing = true
        if notification.object as? NSTableView === authorTable {
            table.selectRowIndexes(authorTable.selectedRowIndexes, byExtendingSelection: false)
        } else {
            authorTable.selectRowIndexes(table.selectedRowIndexes, byExtendingSelection: false)
        }
        synchronizing = false
        guard let blame, blame.lines.indices.contains(table.selectedRow) else { return }
        let line = blame.lines[table.selectedRow]
        let previous = lastBlameLine?.commit
        lastBlameLine = line
        if !isLoading, previous !== line.commit { onSelectedCommit?(line.commit) }
    }


    func hover(row: Int?) {
        let commit = row.flatMap { row in blame?.lines.indices.contains(row) == true ? blame?.lines[row].commit : nil }
        guard commit !== highlightedCommit else { return }
        highlightedCommit = commit
        table.enumerateAvailableRowViews { rowView, row in
            (rowView as? BlameRowView)?.isCommitHighlighted = self.isHighlighted(row)
        }
        authorTable.enumerateAvailableRowViews { rowView, row in
            (rowView as? BlameRowView)?.isCommitHighlighted = self.isHighlighted(row)
        }
    }




    @objc private func doubleClicked(_ sender: NSTableView) {
        guard sender === authorTable, sender.clickedRow >= 0,
              let line = lastBlameLine ?? blame?.lines[safe: sender.clickedRow] else { return }
        guard context?.revisionInGrid(line.commit.objectID) != nil else { return }
        blameRevision(line.commit.objectID, fileName: line.commit.fileName, line: line)
    }


    func blameRevision(_ commit: ObjectID, fileName: String, line: BlameLine) {
        clickedBlameLine = line
        guard let context else { return }
        if !context.selectFileInRevision(commit, fileName) {
            RevisionGridMessages.revisionFilteredInGrid(.object(commit))
        }
    }



    private var fileLines: [DiffLine] {
        (blame?.lines ?? []).map { DiffLine(id: String($0.finalLineNumber), oldLineNumber: nil,
                                          newLineNumber: $0.finalLineNumber, kind: .context, text: $0.text) }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if let id = ApplicationHotkeys.shared.matching(event, category: "File viewer"),
           let shortcut = FileViewerShortcut(rawValue: String(id.dropFirst("viewer.".count))) {
            switch shortcut {
            case .find: findText()
            case .findNext: findNext(forward: true)
            case .findPrevious: findNext(forward: false)
            case .nextOccurrence, .previousOccurrence:
                if occurrences.next(in: fileLines.map(\.text), forward: shortcut == .nextOccurrence) { goToLine(occurrences.row + 1) }
            case .goToLine: goToFileLine()
            case .syntax: toggleSyntax()
            default: return false
            }
            return true
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        switch (event.charactersIgnoringModifiers?.lowercased(), modifiers) {
        case ("c", .command): copySelectedLines()
        default: return false
        }
        return true
    }

    @objc private func toggleSyntax() {
        syntaxEnabled.toggle()
        let selected = table.selectedRowIndexes
        reloadLines()
        table.selectRowIndexes(selected, byExtendingSelection: false)
    }

    @objc private func copySelectedLines() {
        guard let blame else { return }
        copy(table.selectedRowIndexes.compactMap { blame.lines[safe: $0]?.text }.joined(separator: "\n"))
    }

    @objc private func findText() {
        if let row = FileViewerNavigationDialogs.find(lines: fileLines, after: table.selectedRow, query: &searchQuery) {
            highlightOccurrences(row: row); goToLine(row + 1)
        }
    }

    func findNext(forward: Bool, query: String? = nil) {
        if let query { searchQuery = query }
        if let row = FileViewerNavigationDialogs.matchingRow(lines: fileLines, query: searchQuery, after: table.selectedRow, forward: forward) {
            highlightOccurrences(row: row); goToLine(row + 1)
        }
    }

    private func highlightOccurrences(row: Int) {
        occurrences.term = searchQuery; occurrences.row = row
        occurrences.column = FileViewerOccurrences.ranges(of: searchQuery, in: fileLines[row].text).first?.location ?? -1
        reloadLines()
    }

    @objc private func goToFileLine() {
        if let row = FileViewerNavigationDialogs.goToLine(lines: fileLines) { goToLine(row + 1) }
    }

    private var menuRow = -1

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menuRow = menu === authorTable.menu ? authorTable.clickedRow : table.clickedRow
        guard let commit = blame?.lines[safe: menuRow]?.commit else { return }
        func item(_ title: String, _ action: Selector?, id: String, enabled: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled && action != nil
            item.identifier = .init("blame.\(id)")
            return item
        }
        let gridRevision = context?.revisionInGrid(commit.objectID)
        menu.addItem(item("Blame this revision", #selector(blameThisRevision), id: "revision", enabled: gridRevision != nil))
        let previous = previousRevision(of: commit)
        menu.addItem(item(previous.actual ? "Blame previous revision" : "Blame previous visible revision",
                          #selector(blamePreviousRevision), id: "previous", enabled: previous.target != nil))
        let showChanges = item("Show changes", #selector(showChanges), id: "showChanges", enabled: onShowChanges != nil)
        menu.addItem(showChanges)
        menu.addItem(.separator())
        let copy = NSMenuItem(title: "Copy to clipboard", action: nil, keyEquivalent: "")
        copy.identifier = .init("blame.copy")
        let copyMenu = NSMenu()
        copyMenu.autoenablesItems = false
        copyMenu.addItem(item("Commit hash", #selector(copyHash), id: "copyHash"))
        copyMenu.addItem(item("Commit message", #selector(copyMessage), id: "copyMessage"))
        copyMenu.addItem(item("All commit info", #selector(copyAll), id: "copyAll"))
        copy.submenu = copyMenu
        menu.addItem(copy)
        menu.addItem(.separator())
        menu.addItem(item("Copy selection", #selector(copySelectedLines), id: "copySelection", enabled: table.selectedRow >= 0))
        menu.addItem(item("Find…", #selector(findText), id: "find"))
        menu.addItem(item("Go to line…", #selector(goToFileLine), id: "goToLine"))
        let syntax = item("Show syntax highlighting", #selector(toggleSyntax), id: "syntax")
        syntax.state = syntaxEnabled ? .on : .off
        menu.addItem(syntax)

        if !hostedRemotes.isEmpty {
            let view = NSMenuItem(title: "View in GitHub", action: nil, keyEquivalent: "")
            view.identifier = .init("blame.viewInHost")
            let remotes = NSMenu()
            remotes.autoenablesItems = false
            for (index, remote) in hostedRemotes.sorted(by: { $0.displayData < $1.displayData }).enumerated() {
                let entry = item(remote.displayData, #selector(viewInHost(_:)), id: "viewInHost.\(index)")
                entry.representedObject = remote.identity
                remotes.addItem(entry)
            }
            view.submenu = remotes
            menu.addItem(view)
        }
    }

    func contextMenu(forRow row: Int) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let saved = table.clickedRowOverride
        table.clickedRowOverride = row
        menuNeedsUpdate(menu)
        table.clickedRowOverride = saved
        return menu
    }


    func previousRevision(of commit: BlameCommit) -> (target: ObjectID?, actual: Bool, revision: ObjectID?) {
        guard let context, let revision = context.revisionInGrid(commit.objectID) else { return (nil, false, nil) }
        if let actual = actualParents[commit.objectID]?.first, context.revisionInGrid(actual) != nil {
            return (actual, true, commit.objectID)
        }
        if let visible = revision.graphParentIDs.first?.objectID, context.revisionInGrid(visible) != nil {
            return (visible, false, commit.objectID)
        }
        return (nil, false, nil)
    }

    private var menuCommit: BlameCommit? { blame?.lines[safe: menuRow]?.commit }

    @objc private func blameThisRevision() {
        guard let commit = menuCommit, context?.revisionInGrid(commit.objectID) != nil,
              let line = lastBlameLine ?? blame?.lines[safe: menuRow] else { return }
        blameRevision(commit.objectID, fileName: commit.fileName, line: line)
    }


    @objc private func blamePreviousRevision() {
        guard let commit = menuCommit, let source else { return }
        let previous = previousRevision(of: commit)
        guard let parent = previous.target, let selected = lastBlameLine ?? blame?.lines[safe: menuRow] else { return }
        let options = Self.options(preferences)
        let requestGeneration = generation
        Task { @MainActor [weak self] in
            let origin = await source.originalLineInPreviousCommit(commit: commit.objectID, parent: parent, file: commit.fileName,
                                                                  line: selected.originLineNumber, options: options)
            guard let self, generation == requestGeneration, !Task.isCancelled else { return }
            let line = BlameLine(commit: selected.commit, finalLineNumber: selected.originLineNumber, originLineNumber: origin,
                                 text: "Dummy Git blame line used only to store the good 'originLineNumber' value to display and select it")
            blameRevision(parent, fileName: commit.fileName, line: line)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func copyHash() { if let commit = menuCommit { copy(commit.objectID.string) } }
    @objc private func copyMessage() { if let commit = menuCommit { copy(commit.summary) } }
    @objc private func copyAll() { if let commit = menuCommit { copy(commit.description(dateFormatter: Self.tooltipFormatter)) } }
    @objc private func showChanges() { if let commit = menuCommit { onShowChanges?(commit.objectID) } }


    @objc private func viewInHost(_ sender: NSMenuItem) {
        guard let identity = sender.representedObject as? HostedRepositoryIdentity, let blameID, let fileName,
              let url = identity.blameURL(commit: blameID, file: fileName, line: max(menuRow, 0) + 1) else { return }
        NSWorkspace.shared.open(url)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}


final class BlameTableView: NSTableView {
    var onHover: ((Int?) -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
    override func rightMouseDown(with event: NSEvent) {
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        if clicked >= 0 { selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false) }
        super.rightMouseDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, onKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    var clickedRowOverride: Int?
    override var clickedRow: Int { clickedRowOverride ?? super.clickedRow }
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        onHover?(row >= 0 ? row : nil)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(nil)
    }
}


final class BlameRowView: NSTableRowView {
    var isCommitHighlighted = false { didSet { if oldValue != isCommitHighlighted { needsDisplay = true } } }
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isCommitHighlighted else { return }
        NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.6).setFill()
        bounds.fill()
    }
}


final class BlameMarginCell: NSView {
    var color: NSColor = .clear { didSet { needsDisplay = true } }
    let avatar = AuthorAvatarView()
    override init(frame: NSRect) {
        super.init(frame: frame)
        avatar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(avatar)
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            avatar.topAnchor.constraint(equalTo: topAnchor),
            avatar.bottomAnchor.constraint(equalTo: bottomAnchor),
            avatar.widthAnchor.constraint(equalTo: avatar.heightAnchor)
        ])
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSRect(x: 0, y: 0, width: 4, height: bounds.height).fill()
    }
}
