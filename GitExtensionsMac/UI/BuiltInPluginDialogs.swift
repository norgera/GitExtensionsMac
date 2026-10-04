import AppKit
import GitCommands
import GitExtensionsCore

@MainActor
final class BuiltInPluginDialog: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let plugin: BuiltInPlugin
    let host: GitExtensionPluginHost
    private let stack = NSStackView()
    private let status = NSTextField(labelWithString: "")
    private let output = NSTextView()
    private let table = NSTableView()
    private var fields: [String: NSTextField] = [:]
    private var checks: [String: NSButton] = [:]
    private var buttons: [String: NSButton] = [:]
    private var branches: [ObsoleteBranch] = []
    private var objects: [LargeGitFile] = []
    private var selected: Set<String> = []
    private var notes: [ReleaseNote] = []
    private var statisticsTabs: NSTabView?
    private var settingsWindow: NSWindowController?
    private var task: Task<Void, Never>?
    private var completion: CheckedContinuation<Bool, Never>?
    private var changed = false
    private var busy = false
    private var generation = 0

    init(plugin: BuiltInPlugin, host: GitExtensionPluginHost) throws {
        self.plugin = plugin; self.host = host
        let height: CGFloat = switch plugin.kind {
        case .createBranches: 150
        case .proxy: 180
        case .gource: 250
        case .deleteBranches: 700
        case .releaseNotes: 500
        default: 500
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = plugin.name; window.isReleasedWhenClosed = false; window.delegate = self
        window.minSize = NSSize(width: 520, height: min(300, height))
        window.setFrameAutosaveName("BuiltInPlugin.\(plugin.identifier)")
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        window.contentView = stack
        try build()
    }
    required init?(coder: NSCoder) { nil }

    static func present(plugin: BuiltInPlugin, host: GitExtensionPluginHost) async throws -> Bool {
        if plugin.kind == .compileSubmodules { return try await compile(plugin, host) }
        if plugin.kind == .backgroundFetch {
            guard let controller = try plugin.settingsController(in: host) else { return false }
            let window = NSWindow(contentViewController: controller)
            window.title = "Settings — \(plugin.name)"; window.isReleasedWhenClosed = false
            let presentation = NSWindowController(window: window); presentation.showWindow(nil)
            defer { presentation.close() }
            while window.isVisible && !Task.isCancelled { try await Task.sleep(for: .milliseconds(100)) }
            return false
        }
        if plugin.kind == .proxy, try plugin.value("HTTP proxy", in: host).isEmpty {
            throw PluginError.invalid("There is no proxy configured. Please set the proxy host in the plugin settings.")
        }
        if plugin.kind == .gource {
            let path = try plugin.value("Path to Gource", in: host)
            if !path.isEmpty, !FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath) {
                let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "Reset configured Gource path?"
                alert.informativeText = "Gource was not found at \(path)."
                alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No")
                if alert.runModal() == .alertFirstButtonReturn { try host.setSetting("Path to Gource", value: "") }
            }
        }
        let controller = try BuiltInPluginDialog(plugin: plugin, host: host)
        if let owner = host.owner, let window = controller.window {
            window.setFrameOrigin(NSPoint(x: owner.frame.minX + 40, y: owner.frame.minY + 40))
            owner.addChildWindow(window, ordered: .above)
        }
        controller.showWindow(nil)
        let initial = controller.fields["remote"] ?? controller.fields["from"] ?? controller.fields["executable"]
        controller.window?.makeFirstResponder(initial ?? controller.table)
        controller.startInitialLoad()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { controller.completion = $0 }
        } onCancel: { Task { @MainActor in controller.close() } }
    }

    private func field(_ key: String, _ caption: String, value: String) {
        let row = NSStackView(); row.orientation = .horizontal; row.spacing = 8
        let label = NSTextField(labelWithString: caption)
        label.widthAnchor.constraint(equalToConstant: 255).isActive = true
        let text = NSTextField(string: value); text.target = self; text.action = #selector(inputsChanged); text.delegate = self
        row.addArrangedSubview(label); row.addArrangedSubview(text)
        fields[key] = text; stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
    }
    private func check(_ key: String, _ caption: String, value: Bool) {
        let button = NSButton(checkboxWithTitle: caption, target: self, action: #selector(inputsChanged))
        button.state = value ? .on : .off; checks[key] = button; stack.addArrangedSubview(button)
        if key == "unmerged" { button.action = #selector(unmergedChanged) }
    }
    private func button(_ title: String, _ action: Selector, in row: NSStackView) {
        let button = NSButton(title: title, target: self, action: action); buttons[title] = button; row.addArrangedSubview(button)
    }
    private func buildTable(_ columns: [(String, String, CGFloat)]) {
        for (key, title, width) in columns {
            let column = NSTableColumn(identifier: .init(key)); column.title = title; column.width = width
            if key != "delete" { column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true) }
            table.addTableColumn(column)
        }
        table.delegate = self; table.dataSource = self; table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.documentView = table; scroll.borderType = .bezelBorder; stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
    }
    private func buildOutput() {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        output.isEditable = false; output.isRichText = false; output.isVerticallyResizable = true
        output.autoresizingMask = [.width]; output.textContainer?.widthTracksTextView = true
        output.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        scroll.documentView = output; scroll.borderType = .bezelBorder; stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
    }
    private func build() throws {
        switch plugin.kind {
        case .createBranches:
            field("remote", "Remote to create tracking branches for", value: "origin")
        case .deleteBranches:
            field("days", "Delete branches older than x days", value: try plugin.value("Delete obsolete branches older than (days)", in: host))
            field("base", "Delete branches fully merged into branch", value: try plugin.value("Branch where all branches should be merged in", in: host))
            check("unmerged", "Include unmerged branches", value: try plugin.flag("Delete unmerged branches", in: host))
            check("remoteMode", "Delete remote branches from", value: try plugin.flag("Delete obsolete branches from remote", in: host))
            field("remote", "Remote", value: try plugin.value("Remote name obsoleted branches should be deleted from", in: host))
            check("regexMode", "Use regex to filter branches", value: try plugin.flag("Use regex to filter branches to delete", in: host))
            field("pattern", "Regular expression", value: try plugin.value("Regex to filter branches to delete", in: host))
            check("ignoreCase", "Case insensitive", value: try plugin.flag("Is regex filter case insensitive?", in: host))
            check("invert", "Does not match", value: try plugin.flag("Search branches that does not match regex", in: host))
            buildTable([("delete", "Delete", 45), ("name", "Name", 180), ("date", "Last activity", 135), ("author", "Last author", 120), ("message", "Last message", 230)])
        case .largeFiles:
            stack.addArrangedSubview(NSTextField(wrappingLabelWithString: "Reset local changes before deleting files. Choose files to delete. Force push is required after rewriting history."))
            buildTable([("delete", "Delete", 45), ("id", "SHA", 90), ("path", "Path", 200), ("size", "Size (Mb)", 80),
                ("compressed", "Compressed size (Mb)", 130), ("count", "Commit count", 95), ("date", "Last commit date", 135)])
        case .releaseNotes:
            field("from", "Commit expression From (excluding)", value: "")
            field("to", "Commit expression To (including)", value: "HEAD")
            field("arguments", "git log arguments", value: BuiltInPluginCommands.releaseArguments)
            stack.addArrangedSubview(NSTextField(labelWithString: "{0} = from; {1} = to. Most recent revisions are listed on top."))
            buildOutput()
            let copy = NSStackView(); copy.orientation = .horizontal
            for title in ["Original output", "Text table (tabs)", "Text table (spaces)", "HTML table"] {
                button(title, #selector(copyNotes(_:)), in: copy); buttons[title]?.isEnabled = false
            }
            stack.addArrangedSubview(copy)
        case .proxy:
            field("effective", "Current effective http.proxy", value: "")
            field("globalProxy", "Global http.proxy", value: "")
            fields["effective"]?.isEditable = false
            fields["globalProxy"]?.isEditable = false
            check("global", "Apply globally", value: false)
        case .statistics:
            let tabs = NSTabView(); statisticsTabs = tabs; stack.addArrangedSubview(tabs)
            tabs.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
            tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        case .gource:
            field("directory", "Working directory", value: host.repositoryURL?.path ?? "")
            field("executable", "Path to Gource", value: try plugin.value("Path to Gource", in: host))
            field("arguments", "Arguments", value: try plugin.value("Arguments", in: host))
            let browse = NSStackView(); browse.orientation = .horizontal
            button("Browse Gource…", #selector(browseExecutable), in: browse)
            button("Browse directory…", #selector(browseDirectory), in: browse)
            button("Gource project", #selector(gourceProject), in: browse)
            button("Help", #selector(gourceHelp), in: browse); stack.addArrangedSubview(browse)
            stack.addArrangedSubview(NSTextField(wrappingLabelWithString: "Install the native macOS Gource binary and select it above. $(AVATARS) uses the shared avatar provider and its privacy settings."))
        case .backgroundFetch, .compileSubmodules, .impact: break
        }
        stack.addArrangedSubview(status)
        let actions = NSStackView(); actions.orientation = .horizontal; actions.spacing = 8
        if plugin.kind == .deleteBranches { button("Settings…", #selector(showSettings), in: actions) }
        switch plugin.kind {
        case .createBranches: button("Create local tracking branches", #selector(run), in: actions)
        case .deleteBranches:
            button("Search branches", #selector(run), in: actions)
            button("Select all", #selector(toggleAllCandidates), in: actions); button("Delete", #selector(deleteSelected), in: actions)
        case .largeFiles: button("Select all", #selector(toggleAllCandidates), in: actions); button("Delete", #selector(deleteSelected), in: actions)
        case .releaseNotes: button("Generate", #selector(run), in: actions)
        case .proxy: button("Set proxy", #selector(run), in: actions); button("Unset proxy", #selector(unsetProxy), in: actions)
        case .gource: button("Run", #selector(run), in: actions)
        default: break
        }
        button("Close", #selector(closeDialog), in: actions); buttons["Close"]?.keyEquivalent = "\u{1b}"
        stack.addArrangedSubview(actions)
        let primary = buttons["Create local tracking branches"] ?? buttons["Generate"] ?? buttons["Run"]
        primary?.keyEquivalent = "\r"
        inputsChanged()
    }

    private func startInitialLoad() {
        if plugin.kind == .proxy { perform { [self] in try await setProxy(remove: false, initial: true) } }
        else if [.deleteBranches, .largeFiles, .statistics].contains(plugin.kind) { run() }
    }
    @objc private func inputsChanged() {
        if plugin.kind == .deleteBranches, busy {
            task?.cancel(); generation += 1; busy = false
            buttons.values.forEach { $0.isEnabled = true }
        }
        fields["remote"]?.isEnabled = checks["remoteMode"] == nil || enabled("remoteMode")
        fields["pattern"]?.isEnabled = enabled("regexMode")
        checks["ignoreCase"]?.isEnabled = enabled("regexMode"); checks["invert"]?.isEnabled = enabled("regexMode")
        fields["base"]?.isEnabled = !enabled("unmerged")
        if plugin.kind == .deleteBranches, !busy {
            branches.removeAll(); selected.removeAll(); table.reloadData(); status.stringValue = "Press Search branches to reload the list."
        }
        updateDeleteButton()
    }
    func controlTextDidChange(_ obj: Notification) { inputsChanged() }
    @objc private func unmergedChanged() {
        inputsChanged()
        if enabled("unmerged") {
            let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "Deleting unmerged branches"
            alert.informativeText = "Unmerged commits can become unreachable and may be permanently lost after pruning."
            alert.runModal()
        }
    }
    private func enabled(_ key: String) -> Bool { checks[key]?.state == .on }
    private func text(_ key: String) -> String { fields[key]?.stringValue ?? "" }
    private func updateDeleteButton() { buttons["Delete"]?.isEnabled = !busy && !selected.isEmpty }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        task?.cancel(); generation += 1; let currentGeneration = generation
        busy = true; status.stringValue = "Loading…"
        for (name, button) in buttons where name != "Close" { button.isEnabled = false }
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == currentGeneration {
                    busy = false
                    for (name, button) in buttons where !["Original output", "Text table (tabs)", "Text table (spaces)", "HTML table"].contains(name) { button.isEnabled = true }
                    updateDeleteButton(); table.reloadData()
                }
            }
            do { try await operation(); try Task.checkCancellation() }
            catch let error as BuiltInMutationError {
                if error.changed { host.requestRepositoryRefresh(); changed = false }
                if generation == currentGeneration {
                    status.stringValue = error.cancelled ? "Cancelled" : error.localizedDescription
                    if !error.cancelled, window?.isVisible == true { NSAlert(error: error).runModal() }
                }
            }
            catch is CancellationError {
                if changed { host.requestRepositoryRefresh(); changed = false }
                if generation == currentGeneration { status.stringValue = "Cancelled" }
            }
            catch { if generation == currentGeneration { status.stringValue = error.localizedDescription; if window?.isVisible == true { NSAlert(error: error).runModal() } } }
        }
    }
    private func source() throws -> any RepositoryBuiltInPluginDataSource {
        guard let source = host.builtInRepository else { throw PluginError.invalid("Open a repository first.") }
        return source
    }
    @objc private func run() {
        perform { [self] in
            switch plugin.kind {
            case .createBranches:
                let result = try await source().createTrackingBranches(remote: text("remote"))
                changed = result.created > 0
                try Task.checkCancellation()
                let alert = NSAlert(); alert.messageText = result.references == 0 ? "No remote branches found." : "\(result.references) local tracking branches have been created/updated."
                alert.runModal(); close()
            case .deleteBranches:
                guard let days = Int(text("days")), (0...100000).contains(days) else { throw PluginError.invalid("Enter a number of days from 0 to 100000.") }
                let values = try await source().obsoleteBranches(base: text("base"), remote: enabled("remoteMode") ? text("remote") : nil,
                    unmerged: enabled("unmerged"), pattern: enabled("regexMode") ? text("pattern") : nil,
                    ignoreCase: enabled("ignoreCase"), invert: enabled("invert"))
                try Task.checkCancellation(); branches = values
                let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
                selected = Set(values.filter { $0.date < cutoff }.map(\.name)); table.reloadData(); selectionStatus()
            case .largeFiles:
                guard let mb = Double(try plugin.value("Find large files bigger than (Mb)", in: host)), mb.isFinite, mb >= 0, mb * 1_048_576 < Double(Int64.max) else { throw PluginError.invalid("Enter a non-negative file size in Mb.") }
                let readGeneration = generation
                let values = try await source().findLargeFiles(minimum: Int64(mb * 1_048_576)) { [weak self] completed, total, objects in
                    Task { @MainActor in
                        guard let self, self.busy, self.generation == readGeneration, self.window?.isVisible == true else { return }
                        self.objects = objects; self.table.reloadData()
                        self.status.stringValue = "Scanning revision \(completed) / \(total)…"
                    }
                }
                try Task.checkCancellation(); objects = values; table.reloadData(); selectionStatus()
            case .releaseNotes:
                let command = try BuiltInPluginCommands.releaseNotes(from: text("from"), to: text("to"), arguments: text("arguments"))
                let result = try await source().executePluginCommand(command, standardInput: nil)
                try Task.checkCancellation()
                output.string = result.standardOutputString; notes = BuiltInPluginCommands.parseReleaseNotes(output.string)
                for title in ["Original output", "Text table (tabs)", "Text table (spaces)", "HTML table"] { buttons[title]?.isEnabled = !notes.isEmpty }
                status.stringValue = "Revisions count = \(notes.count)"
                if !result.succeeded { throw PluginError.invalid(result.standardErrorString) }
            case .proxy: try await setProxy(remove: false, initial: false)
            case .statistics:
                let values = try await source().codeStatistics(pattern: plugin.value("Code files", in: host),
                    ignoredDirectories: plugin.value("Directories to ignore (EndsWith)", in: host), includeSubmodules: !plugin.flag("Ignore submodules", in: host))
                try Task.checkCancellation(); showStatistics(values); status.stringValue = "\(values.code) Lines of code"
            case .gource: try await launchGource()
            default: break
            }
        }
    }

    private func selectionStatus() { status.stringValue = "\(selected.count) / \(plugin.kind == .largeFiles ? objects.count : branches.count) selected" }
    @objc private func toggleAllCandidates() {
        let ids = plugin.kind == .largeFiles ? objects.map { $0.id.string } : branches.map(\.name)
        selected = selected.count == ids.count ? [] : Set(ids); table.reloadData(); selectionStatus(); updateDeleteButton()
    }
    @objc private func deleteSelected() {
        guard !selected.isEmpty else { return }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = plugin.kind == .largeFiles ? "Permanently delete selected files from all history?" : "Are you sure to delete \(selected.count) selected branches?"
        alert.informativeText = plugin.kind == .largeFiles ? "This rewrites all refs, expires reflogs and prunes objects. This cannot be undone. Remote history requires a force push." : "The selected branches will be deleted."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Delete")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        if plugin.kind == .deleteBranches, enabled("remoteMode") {
            let danger = NSAlert(); danger.alertStyle = .critical; danger.messageText = "DANGEROUS ACTION!"
            danger.informativeText = "These branches will be deleted from the remote server. This cannot be undone."
            danger.addButton(withTitle: "Cancel"); danger.addButton(withTitle: "Delete from remote")
            guard danger.runModal() == .alertSecondButtonReturn else { return }
        }
        let ids = selected
        perform { [self] in
            if plugin.kind == .largeFiles {
                let paths = objects.filter { ids.contains($0.id.string) }.map(\.path)
                let result: BuiltInMutationOutcome
                do { result = try await source().removeLargeFiles(paths) }
                catch let error as BuiltInMutationError {
                    changed = error.changed
                    if error.changed { host.requestRepositoryRefresh(); changed = false }
                    if error.cancelled { throw CancellationError() }; throw error
                }
                changed = result.changed
                if !result.errors.isEmpty { throw PluginError.invalid(result.errors.joined(separator: "\n")) }
                close()
            } else {
                for branch in branches where ids.contains(branch.name) {
                    let command = BuiltInPluginCommands.deleteBranch(branch.name, remote: enabled("remoteMode") ? text("remote") : nil, unmerged: enabled("unmerged"))
                    let result = try await source().executePluginCommand(command, standardInput: nil)
                    guard result.succeeded else { throw PluginError.invalid(result.standardErrorString) }; changed = true
                }
                selected.removeAll(); branches.removeAll(); table.reloadData(); status.stringValue = "Deleted. Press Search branches to reload."
                host.requestRepositoryRefresh(); changed = false
            }
        }
    }

    @objc private func showSettings() {
        do {
            guard let controller = try plugin.settingsController(in: host) else { return }
            let window = NSWindow(contentViewController: controller); window.title = "Settings — \(plugin.name)"
            window.isReleasedWhenClosed = false; settingsWindow = NSWindowController(window: window)
            settingsWindow?.showWindow(nil)
        } catch { NSAlert(error: error).runModal() }
    }
    @objc private func unsetProxy() { perform { [self] in try await setProxy(remove: true, initial: false) } }
    private func setProxy(remove: Bool, initial: Bool) async throws {
        let executable = URL(fileURLWithPath: AppSettingsStore.shared.preferences.gitExecutablePath)
        func load(_ scope: GitSettingsScope) async throws -> String {
            if let source = host.builtInSettings { return try await source.loadGitSettings(scope)["http.proxy"]?.last ?? "" }
            return try await GitSettingsConfiguration.loadGlobal(scope, executableURL: executable)["http.proxy"]?.last ?? ""
        }
        if !initial {
            let command = BuiltInPluginCommands.proxy(host: try plugin.value("HTTP proxy", in: host), port: try plugin.value("HTTP proxy port", in: host),
                username: try plugin.value("Username", in: host), password: try plugin.value("Password", in: host), global: enabled("global"), remove: remove)
            let result: GitCommandResult
            if let source = host.builtInRepository { result = try await source.executePluginCommand(command, standardInput: nil) }
            else {
                guard enabled("global") else { throw PluginError.invalid("Open a repository or select Apply globally.") }
                result = try await BuiltInPluginCommands.globalProxy(command, executable: executable)
            }
            guard result.succeeded || (remove && result.exitStatus == 5) else { throw PluginError.invalid(result.standardErrorString) }
        }
        let effective = try await load(.effective), global = try await load(.global)
        fields["effective"]?.stringValue = Self.obscuredProxy(effective)
        fields["globalProxy"]?.stringValue = Self.obscuredProxy(global)
        checks["global"]?.state = Self.obscuredProxy(effective) == Self.obscuredProxy(global) || host.repositoryURL == nil ? .on : .off
        status.stringValue = ""
    }
    static func obscuredProxy(_ value: String) -> String {
        guard let at = value.lastIndex(of: "@"), let colon = value[..<at].lastIndex(of: ":") else { return value }
        return String(value[...colon]) + "****" + String(value[at...])
    }

    @objc private func copyNotes(_ button: NSButton) {
        let header = "Commit log from '\(text("from"))' to '\(text("to"))' (most recent changes are listed on top):"
        let content: String
        if button.title == "Original output" { content = output.string }
        else if button.title == "HTML table" {
            func escape(_ text: String) -> String { text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
            content = "<p>" + escape(header) + "</p><table>\r\n" + notes.map { "<tr>\r\n<td>\($0.commit)</td>\r\n<td>\($0.message.map(escape).joined(separator: "<br/>"))</td>\r\n</tr>\r\n" }.joined() + "</table>"
        } else {
            let tabs = button.title == "Text table (tabs)"
            content = header + "\n" + notes.map { $0.commit + (tabs ? "\t" : " ") + $0.message.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: tabs ? "\n\t" : "\n        ") + "\n" }.joined()
        }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(content, forType: .string)
        if button.title == "HTML table" { NSPasteboard.general.setString(content, forType: .html) }
    }

    private func showStatistics(_ values: CodeStatistics) {
        guard let tabs = statisticsTabs else { return }
        for item in tabs.tabViewItems { tabs.removeTabViewItem(item) }
        let pages: [(String, [(String, Int)])] = [
            ("Commits per contributor", values.contributors),
            ("Lines of code per language", values.byExtension.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }),
            ("Lines of code per type", [("Blank lines", values.blank), ("Comment lines", values.comments), ("Lines of code", values.code), ("Designer lines", values.designer)]),
            ("Lines of test code", [("Test code", values.test), ("Production code", values.code - values.test)])]
        for (title, entries) in pages {
            let row = NSStackView(); row.orientation = .horizontal; row.spacing = 12
            let pie = BuiltInStatisticsChart(values: entries); row.addArrangedSubview(pie)
            pie.widthAnchor.constraint(equalToConstant: 280).isActive = true; pie.heightAnchor.constraint(equalToConstant: 280).isActive = true
            let total = entries.reduce(0) { $0 + $1.1 }
            let text = NSTextField(wrappingLabelWithString: "\(total) \(title)\n\n" + entries.map {
                "\($0.1) \($0.0) (" + String(format: "%.1f%%", total > 0 ? Double($0.1) * 100 / Double(total) : 0) + ")"
            }.joined(separator: "\n"))
            row.addArrangedSubview(text)
            let item = NSTabViewItem(identifier: title); item.label = title; item.view = row; tabs.addTabViewItem(item)
        }
    }
    @objc private func browseExecutable() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
        if panel.runModal() == .OK { fields["executable"]?.stringValue = panel.url?.path ?? "" }
    }
    @objc private func browseDirectory() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK { fields["directory"]?.stringValue = panel.url?.path ?? "" }
    }
    @objc private func gourceProject() { NSWorkspace.shared.open(URL(string: "https://github.com/acaudwell/Gource")!) }
    @objc private func gourceHelp() { NSWorkspace.shared.open(URL(string: "https://github.com/acaudwell/Gource/blob/master/README")!) }
    private func launchGource() async throws {
        let executable = URL(fileURLWithPath: (text("executable") as NSString).expandingTildeInPath)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw PluginError.invalid("Select an installed native Gource executable.") }
        var arguments = text("arguments")
        if arguments.contains("$(AVATARS)") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitExtensionsMac-Gource-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (email, name) in try await source().gourceAuthors() {
                try Task.checkCancellation()
                guard !name.contains("/"), !name.contains("\0"), let image = await AvatarService.shared.image(email: email, name: name, size: 90),
                    let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { continue }
                try png.write(to: directory.appendingPathComponent(name + ".png"))
            }
            arguments = arguments.replacingOccurrences(of: "$(AVATARS)", with: directory.path)
        }
        let invocation = ScriptInvocation(executable: executable, arguments: try ScriptExecution.arguments(arguments),
            workingDirectory: URL(fileURLWithPath: (text("directory") as NSString).expandingTildeInPath), environment: [:])
        _ = try await ScriptExecution.startBackground(invocation)
        try host.setSetting("Path to Gource", value: text("executable")); try host.setSetting("Arguments", value: text("arguments")); close()
    }

    private static func compile(_ plugin: BuiltInPlugin, _ host: GitExtensionPluginHost) async throws -> Bool {
        guard let source = host.builtInRepository, let directory = host.repositoryURL else { return false }
        let files = try await source.solutionFiles()
        let list = files.dropFirst().reversed().map(\.lastPathComponent).joined(separator: "\n")
        for file in files.dropFirst().reversed() {
            try Task.checkCancellation()
            let alert = NSAlert(); alert.messageText = "Do you want to build \(file.lastPathComponent)?"; alert.informativeText = list
            alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No"); alert.addButton(withTitle: "Cancel")
            let result = alert.runModal()
            if result == .alertThirdButtonReturn { return false }; if result == .alertSecondButtonReturn { continue }
            let executable = URL(fileURLWithPath: (try plugin.value("Path to msbuild.exe", in: host) as NSString).expandingTildeInPath)
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                NSAlert(error: PluginError.invalid("Please configure the path to a native MSBuild-compatible executable in the plugin settings.")).runModal()
                continue
            }
            let invocation = ScriptInvocation(executable: executable, arguments: [file.path] + (try ScriptExecution.arguments(plugin.value("msbuild.exe arguments", in: host))), workingDirectory: directory, environment: [:])
            _ = try await ScriptProcessWindow.run(invocation, title: "MSBuild — \(file.lastPathComponent)", owner: host.owner)
        }
        return false
    }
    @objc private func closeDialog() { close() }
    override func close() {
        task?.cancel(); task = nil; settingsWindow?.close(); super.close()
        completion?.resume(returning: changed); completion = nil
    }
    func windowWillClose(_ notification: Notification) {
        task?.cancel(); task = nil; completion?.resume(returning: changed); completion = nil
    }
    func numberOfRows(in tableView: NSTableView) -> Int { plugin.kind == .largeFiles ? objects.count : branches.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let key = tableColumn?.identifier.rawValue ?? ""
        let id = plugin.kind == .largeFiles ? objects[row].id.string : branches[row].name
        if key == "delete" {
            let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleRow(_:)))
            check.tag = row; check.state = selected.contains(id) ? .on : .off; check.isEnabled = !busy; return check
        }
        let value: String
        if plugin.kind == .largeFiles {
            let file = objects[row]
            switch key {
            case "id": value = file.id.shortString
            case "path": value = file.path
            case "size": value = String(format: "%.2f", Double(file.size) / 1_048_576)
            case "compressed": value = file.compressedSize.map { String(format: "%.2f", Double($0) / 1_048_576) } ?? "Unknown"
            case "count": value = String(file.revisions.count)
            default: value = DateFormatter.localizedString(from: file.lastDate, dateStyle: .short, timeStyle: .short)
            }
        } else {
            let branch = branches[row]
            switch key {
            case "name": value = branch.name
            case "author": value = branch.author
            case "message": value = branch.subject
            default: value = DateFormatter.localizedString(from: branch.date, dateStyle: .short, timeStyle: .short)
            }
        }
        let label = NSTextField(labelWithString: value); label.lineBreakMode = .byTruncatingTail; label.toolTip = value; return label
    }
    @objc private func toggleRow(_ button: NSButton) {
        let id = plugin.kind == .largeFiles ? objects[button.tag].id.string : branches[button.tag].name
        if button.state == .on { selected.insert(id) } else { selected.remove(id) }; selectionStatus(); updateDeleteButton()
    }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let sort = table.sortDescriptors.first, let key = sort.key else { return }
        if plugin.kind == .largeFiles {
            objects.sort { a, b in
                let order: Bool
                switch key {
                case "size": order = a.size < b.size
                case "compressed": order = (a.compressedSize ?? 0) < (b.compressedSize ?? 0)
                case "count": order = a.revisions.count < b.revisions.count
                case "date": order = a.lastDate < b.lastDate
                case "id": order = a.id.string < b.id.string
                default: order = a.path < b.path
                }
                if key == "size", a.size == b.size { return a.id.string < b.id.string }
                if key == "compressed", a.compressedSize == b.compressedSize { return a.id.string < b.id.string }
                if key == "count", a.revisions.count == b.revisions.count { return a.id.string < b.id.string }
                if key == "date", a.lastDate == b.lastDate { return a.id.string < b.id.string }
                if key == "path", a.path == b.path { return a.id.string < b.id.string }
                return sort.ascending ? order : !order
            }
        } else {
            branches.sort { a, b in
                let comparison: ComparisonResult
                switch key {
                case "date": comparison = a.date.compare(b.date)
                case "author": comparison = a.author.localizedCaseInsensitiveCompare(b.author)
                case "message": comparison = a.subject.localizedCaseInsensitiveCompare(b.subject)
                default: comparison = a.name.localizedCaseInsensitiveCompare(b.name)
                }
                return comparison == (sort.ascending ? .orderedAscending : .orderedDescending)
            }
        }
        table.reloadData()
    }
}

@MainActor
final class BuiltInStatisticsChart: NSView {
    let values: [(String, Int)]
    private var slices: [(NSBezierPath, String)] = []
    init(values: [(String, Int)]) { self.values = values; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        toolTip = slices.first { $0.0.contains(point) }?.1
    }
    override func draw(_ dirtyRect: NSRect) {
        slices.removeAll()
        let total = values.reduce(0) { $0 + $1.1 }; guard total > 0 else { return }
        var angle: CGFloat = 90
        for (index, value) in values.enumerated() {
            let end = angle + 360 * CGFloat(value.1) / CGFloat(total)
            let path = NSBezierPath(); path.move(to: NSPoint(x: bounds.midX, y: bounds.midY))
            path.appendArc(withCenter: NSPoint(x: bounds.midX, y: bounds.midY), radius: min(bounds.width, bounds.height) / 2 - 10, startAngle: angle, endAngle: end)
            path.close(); NSColor(calibratedHue: CGFloat(index % 13) / 13, saturation: 0.65, brightness: 0.85, alpha: 1).setFill(); path.fill()
            slices.append((path, "\(value.1) \(value.0) (" + String(format: "%.1f%%", Double(value.1) * 100 / Double(total)) + ")"))
            angle = end
        }
    }
}
