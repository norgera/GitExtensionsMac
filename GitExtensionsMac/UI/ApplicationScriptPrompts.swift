import AppKit
import GitCommands
import GitExtensionsCore

struct ScriptInputPresentation {
    let caption: String
    let label: String

    init(scriptName: String, label: String?) {
        caption = "User input for script '\(scriptName)'"
        self.label = label?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? label! + ":" : "Please specify your input:"
    }

    static func escape(_ selection: NSRange) -> NSRange? {
        selection.length == 0 ? nil : NSRange(location: selection.location, length: 0)
    }
}

@MainActor
final class ScriptPromptPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor
final class ScriptInputWindow: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    let input = NSTextField()
    let label = NSTextField(labelWithString: "")
    let accept = NSButton(title: "OK", target: nil, action: nil)
    let browse = NSButton(title: "Browse...", target: nil, action: nil)
    private let filePrompt: Bool
    private(set) var answer: String?

    init(scriptName: String, label: String?, initial: String, files: Bool = false) {
        filePrompt = files
        let presentation = ScriptInputPresentation(scriptName: scriptName, label: label)
        let panel = ScriptPromptPanel(contentRect: NSRect(x: 0, y: 0, width: files ? 549 : 430, height: files ? 100 : 112),
                                      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = files ? "Select script files" : presentation.caption
        panel.identifier = NSUserInterfaceItemIdentifier(files ? "Script.FilePrompt" : "Script.InputPrompt")
        panel.isReleasedWhenClosed = false; panel.delegate = self
        panel.minSize = NSSize(width: files ? 450 : 350, height: panel.frame.height)
        panel.maxSize = NSSize(width: files ? 800 : 1000, height: panel.frame.height)
        panel.onEscape = { [weak self] in self?.escape() }
        self.label.stringValue = files ? "Select file(s)" : presentation.label
        input.stringValue = initial; input.delegate = self
        input.identifier = NSUserInterfaceItemIdentifier("Script.PromptInput")
        accept.target = self; accept.action = #selector(acceptInput); accept.keyEquivalent = "\r"
        browse.target = self; browse.action = #selector(browseFiles)
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        panel.contentView = root
        let row = NSStackView(views: files ? [self.label, input, browse] : [self.label, input])
        row.orientation = files ? .horizontal : .vertical; row.alignment = files ? .centerY : .leading; row.spacing = 8
        input.setContentHuggingPriority(.defaultLow, for: .horizontal)
        input.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        root.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24).isActive = true
        if !files { input.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true }
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [spacer, accept]); footer.orientation = .horizontal
        root.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        panel.initialFirstResponder = input
    }

    required init?(coder: NSCoder) { nil }

    func run(owner suppliedOwner: NSWindow? = nil) -> String? {
        guard let panel = window else { return nil }
        let owner = suppliedOwner ?? NSApp.keyWindow
        if let owner { panel.setFrameTopLeftPoint(NSPoint(x: owner.frame.midX - panel.frame.width / 2, y: owner.frame.midY + panel.frame.height / 2)) }
        else { panel.center() }
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(input); input.selectText(nil)
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return answer
    }

    @objc func acceptInput() {
        answer = filePrompt && input.stringValue.isEmpty ? nil : input.stringValue
        NSApp.stopModal(withCode: answer == nil ? .cancel : .OK)
    }

    func escape() {
        if !filePrompt, let editor = input.currentEditor() as? NSTextView,
           let selection = ScriptInputPresentation.escape(editor.selectedRange()) {
            editor.setSelectedRange(selection)
        } else {
            answer = nil; NSApp.stopModal(withCode: .cancel)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { escape(); return true }
        return false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        answer = nil; NSApp.stopModal(withCode: .cancel); return true
    }

    static func filePayload(_ urls: [URL]) -> String {
        urls.map { "\"" + $0.path.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }.joined(separator: " ")
    }

    @objc private func browseFiles() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        if panel.runModal() == .OK { input.stringValue = Self.filePayload(panel.urls) }
    }
}

struct ScriptChoiceRow: Equatable {
    let label: String
    let originalIndex: Int?
}

struct ScriptChoicePresentation {
    let rows: [ScriptChoiceRow]
    let initialRow: Int

    init(option: String, values: [String], options: [String: [String]]) {
        let prefix = option.hasPrefix("c") ? "c" : "s"
        let grouped = ["sTag", "cTag", "sBranch", "cBranch", "sLocalBranch", "cLocalBranch", "sRemoteBranch", "cRemoteBranch", "sRemoteBranchName", "cRemoteBranchName", "cDefaultRemote"].contains(option)
        if !grouped {
            rows = values.enumerated().sorted { $0.element.localizedCompare($1.element) == .orderedAscending }
                .map { ScriptChoiceRow(label: $0.element, originalIndex: $0.offset) }
            initialRow = rows.isEmpty ? -1 : 0
            return
        }
        let locals = Set(options[prefix + "LocalBranch"] ?? [])
        let tags = Set(options[prefix + "Tag"] ?? [])
        func category(_ value: String) -> Int {
            if option.hasSuffix("Tag") || tags.contains(value) { return 2 }
            if option.hasSuffix("LocalBranch") || option == "cDefaultRemote" || locals.contains(value) { return 0 }
            return 1
        }
        var result: [ScriptChoiceRow] = []
        for (kind, name) in ["local", "remote", "tag"].enumerated() {
            let entries = values.enumerated().filter { category($0.element) == kind }
                .sorted { $0.element.localizedCompare($1.element) == .orderedAscending }
            if !entries.isEmpty {
                result.append(ScriptChoiceRow(label: String((name + " " + String(repeating: "―", count: 18)).prefix(18)), originalIndex: nil))
                result += entries.map { ScriptChoiceRow(label: $0.element, originalIndex: $0.offset) }
            }
        }
        rows = result; initialRow = rows.isEmpty ? -1 : 1
    }
}

@MainActor
final class ScriptChoiceWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    let presentation: ScriptChoicePresentation
    let table = NSTableView()
    let accept: NSButton
    private(set) var accepted = false
    var selectedIndex: Int? { presentation.rows.indices.contains(table.selectedRow) ? presentation.rows[table.selectedRow].originalIndex : nil }

    init(presentation: ScriptChoicePresentation, action: String = "Select") {
        self.presentation = presentation
        accept = NSButton(title: action, target: nil, action: nil)
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let width = max(150, presentation.rows.map { (String($0.label.prefix(100)) as NSString).size(withAttributes: [.font: font]).width }.max() ?? 150) + 20
        let height = CGFloat(min(8, max(1, presentation.rows.count))) * 22 + 42
        let panel = ScriptPromptPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = action; panel.hasShadow = true; panel.identifier = NSUserInterfaceItemIdentifier("Script.QuickSelector")
        panel.isReleasedWhenClosed = false; panel.delegate = self
        panel.onEscape = { NSApp.stopModal(withCode: .cancel) }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("choice")); column.width = width - 8
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 20
        table.dataSource = self; table.delegate = self; table.allowsEmptySelection = false
        table.target = self; table.doubleAction = #selector(acceptChoice)
        table.identifier = NSUserInterfaceItemIdentifier("Script.Choices")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        let root = NSStackView(); root.orientation = .vertical; root.spacing = 4
        root.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 4, right: 2)
        panel.contentView = root; root.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -4).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: height - 38).isActive = true
        accept.target = self; accept.action = #selector(acceptChoice); accept.keyEquivalent = "\r"
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [spacer, accept]); root.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true
        table.reloadData()
        if presentation.initialRow >= 0 { table.selectRowIndexes(IndexSet(integer: presentation.initialRow), byExtendingSelection: false) }
        panel.initialFirstResponder = table
    }

    required init?(coder: NSCoder) { nil }
    func numberOfRows(in tableView: NSTableView) -> Int { presentation.rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text = NSTextField(labelWithString: presentation.rows[row].label)
        text.lineBreakMode = .byTruncatingTail
        return text
    }
    @objc func acceptChoice() { accepted = true; NSApp.stopModal(withCode: .OK) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.stopModal(withCode: .cancel); return true }
    func run(owner: NSWindow?, anchor: NSPoint?) -> Int? {
        guard !presentation.rows.isEmpty, let panel = window else { return nil }
        if let anchor { panel.setFrameTopLeftPoint(anchor) }
        else if let owner { panel.setFrameTopLeftPoint(NSPoint(x: owner.frame.midX - panel.frame.width / 2, y: owner.frame.midY + panel.frame.height / 2)) }
        else { panel.center() }
        if let visible = owner?.screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: min(max(panel.frame.minX, visible.minX), visible.maxX - panel.frame.width),
                                         y: min(max(panel.frame.minY, visible.minY), visible.maxY - panel.frame.height)))
        }
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(table)
        NSApp.runModal(for: panel); panel.orderOut(nil)
        return selectedIndex
    }
}
