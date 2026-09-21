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
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
              let key = event.charactersIgnoringModifiers, ["c", "s", "l"].contains(key) else {
            return super.performKeyEquivalent(with: event)
        }
        shortcut?(key)
        return true
    }
}

@MainActor
final class CommandLogWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let table = CommandLogTableView()
    private let detail = CommandLogDetailView()
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
        root.addArrangedSubview(split)
        split.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -16).isActive = true
        split.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
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
        let buttons = NSStackView()
        for item in menu.items {
            let button = NSButton(title: item.title, target: self, action: item.action)
            buttons.addArrangedSubview(button)
        }
        root.addArrangedSubview(buttons)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        window.makeFirstResponder(table)
    }

    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil; onClose?() }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let duration = entry.duration.map { String(format: "%.0f ms", $0 * 1000) } ?? "running"
        let state = entry.cancelled ? "cancelled" : entry.exitStatus.map(String.init) ?? (entry.failedToExecute ? "error" : "")
        let field = NSTextField(labelWithString: "\(Self.time.string(from: entry.startedAt))  \(duration)  \(entry.processID.map(String.init) ?? "")  \(entry.isOnMainThread ? "UI" : "")  \(state)  \(entry.displayCommand)")
        field.font = AppSettingsStore.shared.monospaceFont
        return field
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateDetail() }
    private static let time: DateFormatter = { let value = DateFormatter(); value.dateFormat = "HH:mm:ss.SSS"; return value }()
    private func refresh() {
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
        guard entries.indices.contains(table.selectedRow) else { detail.string = ""; return }
        let entry = entries[table.selectedRow]
        detail.string = "Command: \(entry.commandLine)\nWorking dir: \(entry.directory)\nProcess ID: \(entry.processID.map(String.init) ?? "unknown")\nUI thread: \(entry.isOnMainThread)\nStarted at: \(entry.startedAt.ISO8601Format())\nDuration: \(entry.duration.map { String(format: "%.3f ms", $0 * 1000) } ?? "still running")\nExit code: \(entry.exitStatus.map(String.init) ?? "unknown")\nCancelled: \(entry.cancelled)\nLaunch error: \(entry.failedToExecute)\nRemote: \(entry.accessesRemote)\nMay change repository: \(entry.mayChangeRepository)\nOutput bytes: \(entry.stdoutBytes) stdout, \(entry.stderrBytes) stderr\nOutput bodies: not captured (credential safety)\nCall stack:\n\(entry.callStack.isEmpty ? "not captured" : entry.callStack.joined(separator: "\n"))"
    }
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
    }
    @objc private func capture(_ sender: NSButton) {
        CommandLog.shared.capturesCallStacks = sender.state == .on
        UserDefaults.standard.set(sender.state == .on, forKey: "GitExtensionsMac.commandLog.captureCallStacks")
    }
}
