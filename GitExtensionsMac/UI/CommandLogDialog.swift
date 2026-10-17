import AppKit
import GitCommands

final class CommandLogDetailView: NSTextView {
    func setWordWrap(_ enabled: Bool) {
        guard let scrollView = enclosingScrollView, let textContainer else { return }
        scrollView.hasHorizontalScroller = !enabled
        isHorizontallyResizable = !enabled
        autoresizingMask = enabled ? [.width] : []
        textContainer.widthTracksTextView = enabled
        setFrameSize(NSSize(width: scrollView.contentSize.width, height: frame.height))
        textContainer.containerSize = NSSize(
            width: enabled ? max(0, frame.width - 2 * textContainerInset.width) : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        layoutManager?.ensureLayout(for: textContainer)
        sizeToFit()
        if !enabled, let used = layoutManager?.usedRect(for: textContainer) {
            setFrameSize(NSSize(width: max(scrollView.contentSize.width, used.maxX + 2 * textContainerInset.width), height: frame.height))
        }
        if enabled {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollView.contentView.bounds.minY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
}

private final class CommandLogTableView: NSTableView {
    var shortcut: ((String) -> Void)?
    var shortcutKeys: Set<String> = ["c", "s", "l"]
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
              let key = event.charactersIgnoringModifiers, shortcutKeys.contains(key) else {
            return super.performKeyEquivalent(with: event)
        }
        shortcut?(key)
        return true
    }
}

@MainActor
final class CommandLogWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTabViewDelegate {
    private let table = CommandLogTableView()
    private let detail = CommandLogDetailView()
    private let tabs = NSTabView()
    private let cacheTable = CommandLogTableView()
    private let cacheDetail = CommandLogDetailView()
    private var cachedEntries: [CommandCacheEntry] = []
    private var entries: [CommandLogEntry] = []
    private var timer: Timer?
    var onClose: (() -> Void)?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 659, height: 470), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Git Command Log"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 440, height: 280)
        window.setFrameAutosaveName("GitCommandLog")
        if !window.setFrameUsingName("GitCommandLog") { window.center() }
        window.delegate = self
        let root = NSStackView()
        root.orientation = .vertical
        root.distribution = .fill
        root.spacing = 6
        root.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        window.contentView = root
        let split = NSSplitView()
        split.setContentHuggingPriority(.defaultLow, for: .vertical)
        split.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        split.isVertical = false
        split.dividerStyle = .thin
        let list = NSScrollView(frame: NSRect(x: 0, y: 0, width: 643, height: 270))
        list.hasVerticalScroller = true; list.hasHorizontalScroller = true
        let column = NSTableColumn(identifier: .init("command"))
        column.width = 1800
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self; table.delegate = self
        table.shortcut = { [weak self] key in
            switch key {
            case "c": self?.copyCommand()
            case "s": self?.exportLog()
            default: self?.clearLog()
            }
        }
        table.allowsEmptySelection = false
        list.documentView = table
        let output = NSScrollView(frame: NSRect(x: 0, y: 0, width: 643, height: 130))
        output.hasVerticalScroller = true; output.hasHorizontalScroller = true
        detail.isEditable = false
        detail.isRichText = false
        detail.frame = NSRect(origin: .zero, size: output.contentSize)
        detail.minSize = NSSize(width: 0, height: output.contentSize.height)
        detail.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        detail.font = AppSettingsStore.shared.monospaceFont
        detail.isVerticallyResizable = true
        detail.autoresizingMask = [.width]
        detail.textContainer?.widthTracksTextView = true
        output.documentView = detail
        detail.setWordWrap(true)
        split.addArrangedSubview(list); split.addArrangedSubview(output)
        let logTab = NSTabViewItem(identifier: "log"); logTab.label = "Command log"; logTab.view = split
        let cacheSplit = NSSplitView(); cacheSplit.isVertical = false; cacheSplit.dividerStyle = .thin
        let cacheList = NSScrollView(frame: NSRect(x: 0, y: 0, width: 643, height: 183))
        cacheList.hasVerticalScroller = true; cacheList.hasHorizontalScroller = true
        let cacheColumn = NSTableColumn(identifier: .init("cachedCommand")); cacheColumn.width = 1800
        cacheTable.addTableColumn(cacheColumn); cacheTable.headerView = nil
        cacheTable.dataSource = self; cacheTable.delegate = self; cacheTable.allowsEmptySelection = false
        cacheTable.setAccessibilityIdentifier("CommandCache.Table")
        table.setAccessibilityIdentifier("CommandLog.Table")
        cacheTable.shortcutKeys = ["l"]
        cacheTable.shortcut = { [weak self] _ in self?.clearCache() }
        cacheList.documentView = cacheTable
        let cacheOutput = NSScrollView(frame: NSRect(x: 0, y: 0, width: 643, height: 231))
        cacheOutput.hasVerticalScroller = true; cacheOutput.hasHorizontalScroller = true
        cacheDetail.isEditable = false; cacheDetail.isRichText = false
        cacheDetail.setAccessibilityIdentifier("CommandCache.Output")
        cacheDetail.frame = NSRect(origin: .zero, size: cacheOutput.contentSize)
        cacheDetail.minSize = NSSize(width: 0, height: cacheOutput.contentSize.height)
        cacheDetail.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        cacheDetail.font = AppSettingsStore.shared.monospaceFont; cacheDetail.isVerticallyResizable = true
        cacheDetail.autoresizingMask = [.width]; cacheDetail.textContainer?.widthTracksTextView = true
        cacheOutput.documentView = cacheDetail; cacheDetail.setWordWrap(true)
        cacheSplit.addArrangedSubview(cacheList); cacheSplit.addArrangedSubview(cacheOutput)
        let cacheTab = NSTabViewItem(identifier: "cache"); cacheTab.label = "Command cache"; cacheTab.view = cacheSplit
        tabs.addTabViewItem(logTab); tabs.addTabViewItem(cacheTab); tabs.delegate = self
        tabs.setContentHuggingPriority(.defaultLow, for: .vertical)
        tabs.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        root.addArrangedSubview(tabs)
        tabs.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -16).isActive = true
        tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        let controls = NSStackView()
        for (title, action) in [("Always on top", #selector(top(_:))), ("Word wrap", #selector(wrap(_:))), ("Capture call stacks", #selector(capture(_:)))] {
            let button = NSButton(checkboxWithTitle: title, target: self, action: action)
            button.state = title == "Word wrap" || (title == "Capture call stacks" && CommandLog.shared.capturesCallStacks) ? .on : .off
            controls.addArrangedSubview(button)
        }
        root.addArrangedSubview(controls)
        let menu = NSMenu()
        for (title, selector, key) in [("Save to file…", #selector(exportLog), "s"), ("Copy full command line", #selector(copyCommand), "c"), ("Clear", #selector(clearLog), "l")] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = self; item.keyEquivalentModifierMask = .command
            menu.addItem(item)
        }
        table.menu = menu
        let cacheMenu = NSMenu()
        let clear = NSMenuItem(title: "Clear", action: #selector(clearCache), keyEquivalent: "l")
        clear.keyEquivalentModifierMask = .command; clear.target = self
        clear.image = NSImage(systemSymbolName: "eraser", accessibilityDescription: nil)
        cacheMenu.addItem(clear)
        cacheTable.menu = cacheMenu; cacheSplit.menu = cacheMenu
        split.menu = menu
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        window.makeFirstResponder(table)
    }

    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil; onClose?() }
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === cacheTable ? cachedEntries.count : entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === cacheTable {
            let field = NSTextField(labelWithString: cachedEntries[row].displayString)
            field.font = AppSettingsStore.shared.monospaceFont
            return field
        }
        let entry = entries[row]
        let duration = entry.duration.map { String(format: "%.0f ms", $0 * 1000) } ?? "running"
        let state = entry.cancelled ? "cancelled" : entry.exitStatus.map(String.init) ?? (entry.failedToExecute ? "error" : "")
        let field = NSTextField(labelWithString: "\(Self.time.string(from: entry.startedAt))  \(duration)  \(entry.processID.map(String.init) ?? "")  \(entry.isOnMainThread ? "UI" : "")  \(state)  \(entry.displayCommand)")
        field.font = AppSettingsStore.shared.monospaceFont
        return field
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSTableView === cacheTable { updateCacheDetail() } else { updateDetail() }
    }
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        refresh()
        window?.makeFirstResponder(tabViewItem?.identifier as? String == "cache" ? cacheTable : table)
    }
    private static let time: DateFormatter = { let value = DateFormatter(); value.dateFormat = "HH:mm:ss.SSS"; return value }()
    private func refresh() {
        if tabs.selectedTabViewItem?.identifier as? String == "cache" { refreshCache(); return }
        let updated = CommandLog.shared.snapshot()
        guard updated != entries else { return }
        let followsTail = entries.isEmpty || table.selectedRow == entries.count - 1
        let selected = entries.indices.contains(table.selectedRow) ? entries[table.selectedRow].id : nil
        entries = updated
        table.reloadData()
        if !entries.isEmpty {
            let row = followsTail ? entries.count - 1 : entries.firstIndex { $0.id == selected } ?? 0
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            if followsTail { table.scrollRowToVisible(row) }
        }
        updateDetail()
    }
    private func updateDetail() {
        if entries.isEmpty { return }
        guard entries.indices.contains(table.selectedRow) else { detail.string = ""; return }
        let entry = entries[table.selectedRow]
        detail.string = "Command: \(entry.commandLine)\nWorking dir: \(entry.directory)\nProcess ID: \(entry.processID.map(String.init) ?? "unknown")\nUI thread: \(entry.isOnMainThread)\nStarted at: \(entry.startedAt.ISO8601Format())\nDuration: \(entry.duration.map { String(format: "%.3f ms", $0 * 1000) } ?? "still running")\nExit code: \(entry.exitStatus.map(String.init) ?? "unknown")\nCancelled: \(entry.cancelled)\nLaunch error: \(entry.failedToExecute)\nRemote: \(entry.accessesRemote)\nMay change repository: \(entry.mayChangeRepository)\nOutput bytes: \(entry.stdoutBytes) stdout, \(entry.stderrBytes) stderr\nOutput bodies: not captured (credential safety)\nCall stack:\n\(entry.callStack.isEmpty ? "not captured" : entry.callStack.joined(separator: "\n"))"
    }
    private func refreshCache() {
        let updated = CommandCache.shared.snapshot()
        guard updated != cachedEntries else { return }
        let followsTail = cachedEntries.isEmpty || cacheTable.selectedRow == cachedEntries.count - 1
        let selected = cacheTable.selectedRow
        cachedEntries = updated
        let font = AppSettingsStore.shared.monospaceFont
        let longest = cachedEntries.map { ($0.displayString as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        cacheTable.tableColumns.first?.maxWidth = .greatestFiniteMagnitude
        cacheTable.tableColumns.first?.width = max(cacheTable.enclosingScrollView?.contentSize.width ?? 0, longest + 12)
        cacheTable.reloadData()
        if !cachedEntries.isEmpty {
            let row = followsTail ? cachedEntries.count - 1 : min(max(0, selected), cachedEntries.count - 1)
            cacheTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            if followsTail { cacheTable.scrollRowToVisible(row) }
            updateCacheDetail()
        }
    }
    private func updateCacheDetail() {
        guard cachedEntries.indices.contains(cacheTable.selectedRow),
              let entry = CommandCache.shared.value(for: cachedEntries[cacheTable.selectedRow].key) else { return }
        cacheDetail.string = entry.details
        cacheDetail.setWordWrap(!cacheDetail.enclosingScrollView!.hasHorizontalScroller)
    }
    @objc private func clearCache() { CommandCache.shared.clear(); refreshCache() }

    @objc private func clearLog() { CommandLog.shared.clear(); refresh() }
    @objc private func copyCommand() {
        guard entries.indices.contains(table.selectedRow) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entries[table.selectedRow].commandLine, forType: .string)
    }
    @objc private func exportLog() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "commands.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let separator = url.pathExtension.lowercased() == "csv" ? "," : "\t"
        let text = CommandLog.shared.snapshot().map { entry in
            let duration = entry.duration.map { String($0 * 1000) } ?? ""
            let pid = entry.processID.map { String($0) } ?? ""
            let exit = entry.exitStatus.map { String($0) } ?? ""
            let fields: [String] = [entry.startedAt.ISO8601Format(), duration, pid,
                                   entry.isOnMainThread ? "UI" : "", exit, entry.commandLine,
                                   entry.directory, entry.cancelled ? "cancelled" : "",
                                   entry.callStack.joined(separator: "\n")]
            return fields.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: separator)
        }.joined(separator: "\n")
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { NSAlert(error: error).runModal() }
    }
    @objc private func top(_ sender: NSButton) { window?.level = sender.state == .on ? .floating : .normal }
    @objc private func wrap(_ sender: NSButton) {
        detail.setWordWrap(sender.state == .on)
        cacheDetail.setWordWrap(sender.state == .on)
    }
    @objc private func capture(_ sender: NSButton) {
        CommandLog.shared.capturesCallStacks = sender.state == .on
        UserDefaults.standard.set(sender.state == .on, forKey: "GitExtensionsMac.commandLog.captureCallStacks")
    }
}
