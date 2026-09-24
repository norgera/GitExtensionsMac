import AppKit
import GitCommands
import GitExtensionsCore

@MainActor
final class ApplicationScriptsMenu: NSMenu, NSMenuDelegate {
    enum Placement { case toolbar, revisions, files }
    private let placement: Placement
    private let execute: (ScriptDefinition) -> Void
    private let manage: (() -> Void)?

    init(placement: Placement, execute: @escaping (ScriptDefinition) -> Void, manage: (() -> Void)? = nil) {
        self.placement = placement; self.execute = execute; self.manage = manage
        super.init(title: "Scripts")
        delegate = self
        autoenablesItems = false
        menuNeedsUpdate(self)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    static func includes(_ script: ScriptDefinition, placement: Placement) -> Bool {
        guard script.enabled else { return false }
        switch placement {
        case .toolbar: return script.onEvent == .showInUserMenuBar
        case .revisions: return script.addToRevisionGridContextMenu
        case .files: return script.onEvent == .showInFileList
        }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        removeAllItems()
        if placement == .toolbar { addItem(withTitle: "Scripts", action: nil, keyEquivalent: "") }
        do {
            for script in try ApplicationScriptsStore.shared.load() where script.enabled {
                guard Self.includes(script, placement: placement) else { continue }
                let item = NSMenuItem(title: script.displayName, action: #selector(run(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = script
                if let path = script.iconFilePath { item.image = NSImage(contentsOfFile: path) }
                if item.image == nil, let icon = script.icon { item.image = AppKitFactory.resourceImage(icon) }
                addItem(item)
            }
            if items.isEmpty { let item = addItem(withTitle: "No scripts configured", action: nil, keyEquivalent: ""); item.isEnabled = false }
        } catch {
            let item = addItem(withTitle: error.localizedDescription, action: nil, keyEquivalent: ""); item.isEnabled = false
        }
        if manage != nil {
            addItem(.separator())
            let item = addItem(withTitle: "Configure scripts…", action: #selector(configure), keyEquivalent: ""); item.target = self
        }
    }
    @objc private func run(_ item: NSMenuItem) { if let script = item.representedObject as? ScriptDefinition { execute(script) } }
    @objc private func configure() { manage?() }
}

@MainActor
final class ScriptProcessWindow: NSWindowController, NSWindowDelegate {
    private let output = NSTextView()
    private var task: Task<GitCommandResult, Error>?

    private init(title: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = title; window.isReleasedWhenClosed = false; window.delegate = self
        let root = NSStackView(); root.orientation = .vertical; root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        window.contentView = root
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true
        output.isEditable = false; output.isRichText = false
        output.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        output.isVerticallyResizable = true; output.autoresizingMask = [.width]
        output.frame = NSRect(x: 0, y: 0, width: 680, height: 350)
        output.textContainer?.widthTracksTextView = true
        scroll.documentView = output; root.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -20).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"; root.addArrangedSubview(cancel)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func cancel() { task?.cancel() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancel(); return false }

    static func run(_ invocation: ScriptInvocation, title: String, owner: NSWindow?) async throws -> GitCommandResult {
        let controller = ScriptProcessWindow(title: title)
        if let owner, let window = controller.window {
            window.setFrameOrigin(NSPoint(x: owner.frame.minX + 30, y: owner.frame.minY + 30))
            owner.addChildWindow(window, ordered: .above)
        }
        controller.showWindow(nil)
        let task = Task {
            try await ScriptExecution.run(invocation) { [weak controller] event in
                Task { @MainActor in
                    guard let controller else { return }
                    controller.output.textStorage?.append(NSAttributedString(string: String(decoding: event.data, as: UTF8.self)))
                    controller.output.scrollToEndOfDocument(nil)
                }
            }
        }
        controller.task = task
        defer {
            if let window = controller.window { owner?.removeChildWindow(window) }
            controller.close()
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}

@MainActor
struct ApplicationScriptHooks {
    let begin: () -> Void
    let end: () -> Void
    let run: (ScriptEvent) async -> Bool
    var contextualRun: ((ScriptEvent, [String: [String]]) async -> Bool)? = nil
    var manualRun: ((ScriptDefinition, [String: [String]]) async -> Bool)? = nil
    var childHooks: ((any RepositoryBrowsingDataSource) -> ApplicationScriptHooks)? = nil

    func runWithOptions(_ event: ScriptEvent, options: [String: [String]]) async -> Bool {
        if let contextualRun { return await contextualRun(event, options) }
        return await run(event)
    }
}

@MainActor
final class ApplicationScriptsStore {
    static let shared = ApplicationScriptsStore()
    private let defaults: UserDefaults
    private let key = "GitExtensionsMac.applicationScripts.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() throws -> [ScriptDefinition] {
        guard let data = defaults.data(forKey: key) else { return Self.defaultScripts }
        var scripts = try JSONDecoder().decode([ScriptDefinition].self, from: data)
        var used = Set<Int>()
        var next = max(8999, scripts.map(\.hotkeyCommandIdentifier).max() ?? 8999) + 1
        for index in scripts.indices {
            if !used.insert(scripts[index].hotkeyCommandIdentifier).inserted {
                scripts[index].hotkeyCommandIdentifier = next
                used.insert(next); next += 1
            }
        }
        return scripts
    }

    func save(_ scripts: [ScriptDefinition]) throws {
        defaults.set(try JSONEncoder().encode(scripts), forKey: key)
    }

    static var defaultScripts: [ScriptDefinition] {
        [("Fetch changes after commit", "fetch", ScriptEvent.afterCommit),
         ("Update submodules after pull", "submodule update --init --recursive", .afterPull)].enumerated().map { index, definition in
            var script = ScriptDefinition()
            script.name = definition.0; script.arguments = definition.1
            script.command = "git"; script.onEvent = definition.2
            script.enabled = false; script.askConfirmation = true
            script.hotkeyCommandIdentifier = 9000 + index
            return script
        }
    }
}

@MainActor
enum ApplicationScriptEvents {
    static func run(_ event: ScriptEvent, scripts: [ScriptDefinition],
                    execute: (ScriptDefinition) async throws -> Bool) async throws -> Bool {
        for script in scripts where script.enabled && script.onEvent == event {
            try Task.checkCancellation()
            if try await !execute(script) { return false }
        }
        return true
    }
}

@MainActor
enum ScriptPrompts {
    static func resolve(_ definition: ScriptDefinition, options: [String: [String]],
                        input: (String?, String) async -> String?,
                        files: () async -> [URL]?) async -> ScriptDefinition? {
        var script = definition
        let pattern = #"\{UserInput:([^}=]+)(=([^{}]*((\{[^{}]+\})+[^{}]*)*))?\}"#
        let regex = try! NSRegularExpression(pattern: pattern)
        while let match = regex.firstMatch(in: script.arguments, range: NSRange(script.arguments.startIndex..., in: script.arguments)) {
            let token = String(script.arguments[Range(match.range, in: script.arguments)!].dropFirst().dropLast())
            let label = String(script.arguments[Range(match.range(at: 1), in: script.arguments)!])
            let value = Range(match.range(at: 3), in: script.arguments).map { String(script.arguments[$0]) } ?? ""
            let initial = ScriptExecution.expand(value, options: options, powerShell: script.isPowerShell)
            guard let answer = await input(label, initial) else { return nil }
            script.arguments = ScriptExecution.replaceOption(token, in: script.arguments, values: [answer], powerShell: script.isPowerShell)
            script.arguments = ScriptExecution.replaceOption("UserInput:\(label)", in: script.arguments, values: [answer], powerShell: script.isPowerShell)
        }
        if script.arguments.contains("{UserInput}") {
            guard let answer = await input(nil, "") else { return nil }
            script.arguments = ScriptExecution.expand(script.arguments, options: ["UserInput": [answer]], powerShell: script.isPowerShell)
        }
        if script.arguments.contains("{UserFiles}") {
            guard let selected = await files() else { return nil }
            let quotedFiles = ScriptExecution.expand("{{files}}", options: ["files": selected.map(\.path)], powerShell: script.isPowerShell)
            script.arguments = ScriptExecution.replaceOption("UserFiles", in: script.arguments, values: [quotedFiles], powerShell: script.isPowerShell)
        }
        return script
    }

    static func resolve(_ script: ScriptDefinition, options: [String: [String]]) async -> ScriptDefinition? {
        await resolve(script, options: options, input: { label, initial in
            let alert = NSAlert(); alert.messageText = script.displayName
            alert.informativeText = label ?? "Enter script input"
            let field = NSTextField(string: initial); field.frame = NSRect(x: 0, y: 0, width: 400, height: 24)
            alert.accessoryView = field
            alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            return field.stringValue
        }, files: {
            let panel = NSOpenPanel(); panel.allowsMultipleSelection = true
            guard panel.runModal() == .OK else { return nil }
            return panel.urls
        })
    }
}

@MainActor
final class ScriptsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private var scripts: [ScriptDefinition]
    private let store: ApplicationScriptsStore
    private let execute: (ScriptDefinition, @escaping (Result<ScriptExecutionOutcome, Error>) -> Void) -> Void
    private let cancelExecution: () -> Void
    private let table = NSTableView()
    private let name = NSTextField(), command = NSTextField(), arguments = NSTextField()
    private let icon = NSTextField(), iconFile = NSTextField()
    private let enabled = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let confirmation = NSButton(checkboxWithTitle: "Ask confirmation", target: nil, action: nil)
    private let background = NSButton(checkboxWithTitle: "Run in background", target: nil, action: nil)
    private let revisionMenu = NSButton(checkboxWithTitle: "Show in revision context menu", target: nil, action: nil)
    private let powershell = NSButton(checkboxWithTitle: "PowerShell (pwsh)", target: nil, action: nil)
    private let event = NSPopUpButton()
    private let output = NSTextView()
    private var editingIndex: Int?
    private var running = false

    init(store: ApplicationScriptsStore = .shared,
         execute: @escaping (ScriptDefinition, @escaping (Result<ScriptExecutionOutcome, Error>) -> Void) -> Void,
         cancel: @escaping () -> Void) throws {
        self.store = store; scripts = try store.load(); self.execute = execute; cancelExecution = cancel
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 530),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Scripts"; window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("ApplicationScripts")
        let root = NSStackView(); root.orientation = .vertical; root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        window.contentView = root
        let list = NSScrollView(); list.hasVerticalScroller = true
        let column = NSTableColumn(identifier: .init("script")); column.width = 690
        table.addTableColumn(column); table.headerView = nil
        table.delegate = self; table.dataSource = self; list.documentView = table
        root.addArrangedSubview(list); list.heightAnchor.constraint(equalToConstant: 145).isActive = true
        list.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24).isActive = true
        for (label, field) in [("Name", name), ("Command", command), ("Arguments", arguments), ("Icon", icon), ("Icon file", iconFile)] {
            let row = NSStackView(views: [NSTextField(labelWithString: label), field])
            root.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            field.widthAnchor.constraint(equalToConstant: 570).isActive = true
        }
        root.addArrangedSubview(NSStackView(views: [enabled, confirmation, background]))
        root.addArrangedSubview(NSStackView(views: [revisionMenu, powershell]))
        event.addItems(withTitles: ScriptEvent.allCases.map(\.rawValue))
        root.addArrangedSubview(NSStackView(views: [NSTextField(labelWithString: "On event"), event]))
        let note = NSTextField(wrappingLabelWithString: "Configure an executable and its arguments. Use {WorkingDir}, {{cHash}}, {UserInput:Label=default} or {UserFiles}. ShowInUserMenuBar adds a toolbar action; ShowInFileList adds a file action. Shortcuts are configured in Settings → Hotkeys → Scripts.")
        root.addArrangedSubview(note); note.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        let actions = NSStackView()
        for (title, selector) in [("Add", #selector(add)), ("Delete", #selector(delete)), ("Up", #selector(moveScriptUp)), ("Down", #selector(moveScriptDown)), ("Save", #selector(save)), ("Run", #selector(run)), ("Cancel execution", #selector(cancelRun))] {
            actions.addArrangedSubview(NSButton(title: title, target: self, action: selector))
        }
        root.addArrangedSubview(actions)
        let result = NSScrollView(); result.hasVerticalScroller = true
        output.isEditable = false; output.isRichText = false
        output.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        output.isVerticallyResizable = true; output.autoresizingMask = [.width]
        output.frame = NSRect(x: 0, y: 0, width: 700, height: 120)
        output.textContainer?.widthTracksTextView = true
        result.documentView = output; root.addArrangedSubview(result)
        result.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        result.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        if !scripts.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }

    required init?(coder: NSCoder) { nil }
    func numberOfRows(in tableView: NSTableView) -> Int { scripts.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        NSTextField(labelWithString: scripts[row].name + " — " + scripts[row].onEvent.rawValue)
    }
    private func capture() {
        guard let index = editingIndex, scripts.indices.contains(index) else { return }
        scripts[index].name = name.stringValue; scripts[index].command = command.stringValue
        scripts[index].arguments = arguments.stringValue; scripts[index].enabled = enabled.state == .on
        scripts[index].askConfirmation = confirmation.state == .on
        scripts[index].runInBackground = background.state == .on
        scripts[index].addToRevisionGridContextMenu = revisionMenu.state == .on
        scripts[index].isPowerShell = powershell.state == .on
        scripts[index].icon = icon.stringValue.isEmpty ? nil : icon.stringValue
        scripts[index].iconFilePath = iconFile.stringValue.isEmpty ? nil : iconFile.stringValue
        scripts[index].onEvent = ScriptEvent.allCases[event.indexOfSelectedItem]
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        capture(); editingIndex = scripts.indices.contains(table.selectedRow) ? table.selectedRow : nil
        guard let index = editingIndex else { return }
        let script = scripts[index]
        name.stringValue = script.name; command.stringValue = script.command; arguments.stringValue = script.arguments
        enabled.state = script.enabled ? .on : .off; confirmation.state = script.askConfirmation ? .on : .off
        background.state = script.runInBackground ? .on : .off
        revisionMenu.state = script.addToRevisionGridContextMenu ? .on : .off
        powershell.state = script.isPowerShell ? .on : .off
        icon.stringValue = script.icon ?? ""; iconFile.stringValue = script.iconFilePath ?? ""
        event.selectItem(withTitle: script.onEvent.rawValue)
    }
    @objc private func add() {
        capture(); var script = ScriptDefinition()
        script.hotkeyCommandIdentifier = max(8999, scripts.map(\.hotkeyCommandIdentifier).max() ?? 8999) + 1
        scripts.append(script); table.reloadData()
        table.selectRowIndexes(IndexSet(integer: scripts.count - 1), byExtendingSelection: false)
    }
    @objc private func delete() {
        guard let index = editingIndex else { return }
        scripts.remove(at: index); editingIndex = nil; table.reloadData()
        if !scripts.isEmpty { table.selectRowIndexes(IndexSet(integer: min(index, scripts.count - 1)), byExtendingSelection: false) }
    }
    @objc private func moveScriptUp() { move(by: -1) }
    @objc private func moveScriptDown() { move(by: 1) }
    private func move(by offset: Int) {
        capture()
        guard let index = editingIndex, scripts.indices.contains(index + offset) else { return }
        scripts.swapAt(index, index + offset); editingIndex = nil
        table.reloadData(); table.selectRowIndexes(IndexSet(integer: index + offset), byExtendingSelection: false)
    }
    @objc private func save() {
        capture()
        do { try store.save(scripts); table.reloadData() }
        catch { NSAlert(error: error).runModal() }
    }
    @objc private func run() {
        guard !running else { return }; capture()
        guard let index = editingIndex else { return }
        let script = scripts[index]
        guard !script.command.isEmpty else { return }
        if script.askConfirmation {
            let alert = NSAlert(); alert.messageText = "Execute script ‘\(script.displayName)’?"
            alert.addButton(withTitle: "Execute"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        running = true; output.string = "Running…"
        execute(script) { [weak self] result in
            guard let self else { return }; running = false
            switch result {
            case .success(.completed(let result)): output.string = "Exit code: \(result.exitStatus)\n" + result.standardOutputString + result.standardErrorString
            case .success(.started(let pid)): output.string = "Started background process \(pid). Completion is not awaited."
            case .failure(let error): output.string = error is CancellationError ? "Cancelled" : error.localizedDescription
            }
        }
    }
    @objc private func cancelRun() { cancelExecution() }
}
