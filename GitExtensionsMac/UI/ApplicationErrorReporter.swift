import AppKit
import GitCommands

struct ExceptionReportProperty: Equatable {
    let name: String
    let value: String
    var extended = false
}

struct ExceptionReportSnapshot {
    let type: String
    let message: String
    var targetSite: String? = nil
    var source: String? = nil
    var helpLink: String? = nil
    var stackTrace: String? = nil
    var data: [ExceptionReportProperty] = []
    var extended: [ExceptionReportProperty] = []
    var children: [ExceptionReportSnapshot] = []

    var properties: [ExceptionReportProperty] {
        var values = [ExceptionReportProperty(name: "Exception", value: type), .init(name: "Message", value: message)]
        if let targetSite { values.append(.init(name: "Target Site", value: targetSite)) }
        if let inner = children.first { values.append(.init(name: "Inner Exception", value: inner.type)) }
        if let source { values.append(.init(name: "Source", value: source)) }
        if let helpLink { values.append(.init(name: "Help Link", value: helpLink)) }
        if let stackTrace { values.append(.init(name: "Stack Trace", value: stackTrace)) }
        values += data.map { .init(name: "Data[\"\($0.name)\"]", value: $0.value) }
        values += extended.map { .init(name: $0.name, value: $0.value, extended: true) }
        return values
    }

    var details: String {
        var result = "\(type): \(message)"
        for child in children { result += "\n ---> " + child.details + "\n   --- End of inner exception stack trace ---" }
        if let stackTrace { result += "\n" + stackTrace }
        return result
    }

    static func capture(_ error: Error, depth: Int = 0) -> Self {
        let value = error as NSError
        var snapshot = Self(type: value.domain, message: value.localizedDescription, source: value.domain)
        snapshot.extended = [.init(name: "Code", value: String(value.code), extended: true)]
        if depth < 16, let inner = value.userInfo[NSUnderlyingErrorKey] as? NSError { snapshot.children = [capture(inner, depth: depth + 1)] }
        let ignored = [NSLocalizedDescriptionKey, NSUnderlyingErrorKey]
        snapshot.data = value.userInfo.keys.sorted().filter { !ignored.contains($0) }.map {
            .init(name: $0, value: String(describing: value.userInfo[$0]!))
        }
        return snapshot
    }

    static func capture(_ exception: NSException) -> Self {
        Self(type: exception.name.rawValue, message: exception.reason ?? "", targetSite: exception.callStackSymbols.first,
             source: Bundle.main.bundleIdentifier, stackTrace: exception.callStackSymbols.joined(separator: "\n"),
             data: (exception.userInfo ?? [:]).map { .init(name: String(describing: $0.key), value: String(describing: $0.value)) }.sorted { $0.name < $1.name })
    }
}

struct ErrorReportContext {
    var isExternalOperation = false
    var isUserExternalOperation = false
    var isTerminating = false
    var canIgnore: Bool { !isTerminating }
    var showIgnore: Bool { isExternalOperation }
    var focusDetails: Bool { isUserExternalOperation }
}

struct ErrorReportContent {
    let exception: ExceptionReportSnapshot
    let environment: String
    var exceptionInfo = ""

    static func containsInformation(_ value: String) -> Bool { value.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil }
    func details(description: String) -> String {
        let info = exceptionInfo.isEmpty ? "" : "\n" + exceptionInfo.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
        let additional = Self.containsInformation(description) ? description.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" : ""
        return info + "```\n" + exception.details.trimmingCharacters(in: .whitespacesAndNewlines) + "\n```\n\n" + additional
    }
    func copyText(description: String) -> String { environment + details(description: description) }
    func issueURL(description: String, base: String = "https://github.com/gitextensions/gitextensions/issues/new") -> URL? {
        guard let url = URL(string: base), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        var title = "[NBug] " + exception.message
        if (title as NSString).length > 69 { title = (title as NSString).substring(to: 66) + "..." }
        let fields = [("title", title), ("template", "bug_report.yml"), ("labels", "type: NBug"),
                      ("about", environment), ("description", details(description: description))]
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let query = fields.map { $0.0 + "=" + ($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }.joined(separator: "&")
        return URL(string: base + (url.query?.isEmpty == false ? "&" : "?") + query)
    }
}

@MainActor
final class ExceptionPropertyWindow: NSWindowController, NSWindowDelegate {
    let property = NSTextField(labelWithString: "")
    let information = NSTextView()
    init(_ value: ExceptionReportProperty) {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 567, height: 218),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window); window.title = "Property Details"; window.isReleasedWhenClosed = false; window.delegate = self
        window.minSize = NSSize(width: 350, height: 180)
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8); window.contentView = root
        property.stringValue = value.name; property.isSelectable = true
        let row = NSStackView(views: [NSTextField(labelWithString: "Property:"), property]); root.addArrangedSubview(row)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        information.frame = NSRect(x: 0, y: 0, width: 540, height: 160)
        information.isEditable = false; information.isRichText = false; information.isSelectable = true
        information.string = value.value; information.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        information.isVerticallyResizable = true; information.isHorizontallyResizable = true
        information.textContainer?.widthTracksTextView = false
        information.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = information; root.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -16).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
    }
    func run(owner: NSWindow?) {
        guard let window else { return }
        if let owner {
            window.setFrameTopLeftPoint(NSPoint(x: owner.frame.minX + 25, y: owner.frame.maxY - 25))
            owner.addChildWindow(window, ordered: .above)
        }
        window.makeKeyAndOrderFront(nil); NSApp.runModal(for: window)
        owner?.removeChildWindow(window); window.orderOut(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.stopModal(withCode: .OK); return true }
    required init?(coder: NSCoder) { nil }
}

@MainActor
private final class ErrorReportSplitView: NSSplitView {
    private var positioned = false
    override func layout() {
        super.layout()
        if !positioned, bounds.width > 250, subviews.count == 2 {
            positioned = true
            setPosition(170, ofDividerAt: 0)
        }
    }
}

@MainActor
final class ErrorReportWindow: NSWindowController, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTableViewDataSource, NSTableViewDelegate {
    final class Node {
        let snapshot: ExceptionReportSnapshot
        let children: [Node]
        init(_ snapshot: ExceptionReportSnapshot) { self.snapshot = snapshot; children = snapshot.children.map(Node.init) }
    }
    enum Result { case resume, quit }
    let content: ErrorReportContent
    let context: ErrorReportContext
    let tabs = NSTabView()
    let descriptionInput = NSTextView()
    let tree = NSOutlineView()
    let properties = NSTableView()
    let send = NSButton(title: "Send and Quit", target: nil, action: nil)
    let ignore = NSButton(title: "Ignore", target: nil, action: nil)
    let copy = NSButton(title: "Copy", target: nil, action: nil)
    let quit = NSButton(title: "Quit", target: nil, action: nil)
    let node: Node
    private(set) var displayed: [ExceptionReportProperty] = []
    private(set) var result: Result = .resume
    private var detailWindows: [ExceptionPropertyWindow] = []
    var copyAction: (String) -> Void = { value in NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
    var openAction: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    var confirmSend: () -> Bool = {
        let alert = NSAlert(); alert.messageText = "Error Report"
        alert.informativeText = "Give as much as information as possible please to help the developers solve this issue. Otherwise, your issue ticket may be closed without any follow-up from the developers.\n\nBecause of this, make sure to fill in all the fields in the report template please.\n\nSend report?"
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Send report")
        return alert.runModal() == .alertSecondButtonReturn
    }
    var validation: (String) -> Void = { message in
        let alert = NSAlert(); alert.messageText = "Error Report"; alert.informativeText = message; alert.runModal()
    }

    init(content: ErrorReportContent, context: ErrorReportContext, gitVersion: String = "") {
        self.content = content; self.context = context; node = Node(content.exception)
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 540),
                             styleMask: context.canIgnore ? [.titled, .closable, .resizable] : [.titled, .resizable], backing: .buffered, defer: false)
        super.init(window: window); window.title = "Git Extensions Error Report"
        window.identifier = NSUserInterfaceItemIdentifier("Application.ErrorReport"); window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 558, height: 500); window.delegate = self
        let root = NSStackView(); root.orientation = .vertical; root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 8, right: 4); window.contentView = root
        root.addArrangedSubview(tabs); tabs.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -8).isActive = true
        tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 450).isActive = true
        let general = NSTabViewItem(identifier: "General"); general.label = "General"; general.view = generalView(gitVersion: gitVersion)
        let exception = NSTabViewItem(identifier: "Exception"); exception.label = "Exception"; exception.view = exceptionView()
        tabs.addTabViewItem(general); tabs.addTabViewItem(exception)
        if context.focusDetails { tabs.selectTabViewItem(exception) }
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil); copy.imagePosition = .imageLeft
        copy.target = self; copy.action = #selector(copyReport); copy.toolTip = "Copy the issue details into clipboard"
        send.image = AppKitFactory.resourceImage("GitHub"); send.imagePosition = .imageLeft
        send.target = self; send.action = #selector(sendReport); send.isEnabled = !context.focusDetails
        send.toolTip = "Report the issue to GitHub and quit application.\nA valid GitHub account is required"
        ignore.target = self; ignore.action = #selector(ignoreReport); ignore.isHidden = !context.showIgnore; ignore.isEnabled = context.canIgnore
        quit.target = self; quit.action = #selector(quitReport); quit.keyEquivalent = "\u{1b}"; quit.toolTip = "Quit application without reporting the issue"
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [copy, spacer, ignore, send, quit]); footer.spacing = 8
        root.addArrangedSubview(footer); footer.widthAnchor.constraint(equalTo: tabs.widthAnchor).isActive = true
        window.initialFirstResponder = descriptionInput
        displayed = node.snapshot.properties; properties.reloadData(); tree.reloadData(); tree.expandItem(nil, expandChildren: true)
        tree.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }
    required init?(coder: NSCoder) { nil }

    private func generalView(gitVersion: String) -> NSView {
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 6
        root.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        let warning = NSTextField(wrappingLabelWithString: "The application has crashed and it will now be terminated. If you click Quit, the application will close immediately. If you click Send and Quit, the application will close and a bug report will be sent.")
        let warningIcon = NSImageView(image: NSImage(named: NSImage.cautionName)!)
        warningIcon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        let warningRow = NSStackView(views: [warningIcon, warning]); warningRow.spacing = 8
        root.addArrangedSubview(warningRow); warningRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -16).isActive = true
        func value(_ string: String) -> NSTextField {
            let field = NSTextField(string: string); field.isEditable = false; field.isSelectable = true
            field.lineBreakMode = .byTruncatingTail; field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return field
        }
        let typeIcon = NSImageView(image: AppKitFactory.resourceImage("DashboardBug") ?? NSImage())
        typeIcon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let typeField = value(content.exception.type)
        let type = NSStackView(views: [typeIcon, NSTextField(labelWithString: "Exception Type:"), typeField]); type.spacing = 8
        root.addArrangedSubview(type); type.widthAnchor.constraint(equalTo: warningRow.widthAnchor).isActive = true
        let message = NSTextField(wrappingLabelWithString: content.exception.message); message.isSelectable = true
        message.maximumNumberOfLines = 3
        root.addArrangedSubview(message); message.widthAnchor.constraint(equalTo: warningRow.widthAnchor).isActive = true
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let application = value("Git Extensions [\(version)]")
        let git = value(gitVersion)
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Target Site:"), value(content.exception.targetSite ?? ""), NSGridCell.emptyContentView, NSGridCell.emptyContentView],
            [NSTextField(labelWithString: "Application:"), application, NSTextField(labelWithString: "Git:"), git],
            [NSTextField(labelWithString: "Date/Time:"), value(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)), NSTextField(labelWithString: "Runtime:"), value("Swift / AppKit")]
        ])
        grid.mergeCells(inHorizontalRange: NSRange(location: 1, length: 3), verticalRange: NSRange(location: 0, length: 1))
        grid.column(at: 0).width = 95; grid.column(at: 2).width = 60
        grid.xPlacement = .fill
        grid.identifier = NSUserInterfaceItemIdentifier("ErrorReport.Environment")
        root.addArrangedSubview(grid); grid.widthAnchor.constraint(equalTo: warningRow.widthAnchor).isActive = true
        application.widthAnchor.constraint(equalTo: git.widthAnchor).isActive = true
        let label = NSTextField(wrappingLabelWithString: "Please add a brief description (in English) of how we can reproduce the error:")
        root.addArrangedSubview(label); label.widthAnchor.constraint(equalTo: warningRow.widthAnchor).isActive = true
        descriptionInput.frame = NSRect(x: 0, y: 0, width: 580, height: 100)
        descriptionInput.autoresizingMask = [.width]
        descriptionInput.isRichText = false; descriptionInput.font = .systemFont(ofSize: 12); descriptionInput.isVerticallyResizable = true
        descriptionInput.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = descriptionInput
        root.addArrangedSubview(scroll); scroll.widthAnchor.constraint(equalTo: warningRow.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 95).isActive = true
        return root
    }

    private func exceptionView() -> NSView {
        let split = ErrorReportSplitView(); split.isVertical = true; split.dividerStyle = .thin
        let treeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Exception")); tree.addTableColumn(treeColumn)
        tree.outlineTableColumn = treeColumn; tree.headerView = nil; tree.dataSource = self; tree.delegate = self
        tree.identifier = NSUserInterfaceItemIdentifier("ErrorReport.ExceptionTree")
        let treeScroll = NSScrollView(); treeScroll.documentView = tree; treeScroll.hasVerticalScroller = true
        for (id, width) in [("Property", 101.0), ("Information", 350.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = id; column.width = width
            properties.addTableColumn(column)
        }
        properties.dataSource = self; properties.delegate = self; properties.target = self; properties.doubleAction = #selector(openProperty)
        properties.identifier = NSUserInterfaceItemIdentifier("ErrorReport.ExceptionProperties")
        let propertyScroll = NSScrollView(); propertyScroll.documentView = properties; propertyScroll.hasVerticalScroller = true; propertyScroll.hasHorizontalScroller = true
        split.addArrangedSubview(treeScroll); split.addArrangedSubview(propertyScroll)
        treeScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 135).isActive = true
        return split
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? Node)?.children.count ?? 1 }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? Node)?.children[index] ?? node }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !(item as! Node).children.isEmpty }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? { NSTextField(labelWithString: (item as! Node).snapshot.type) }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        if let selected = tree.item(atRow: tree.selectedRow) as? Node { displayed = selected.snapshot.properties; properties.reloadData() }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { displayed.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let property = displayed[row]
        let text = NSTextField(labelWithString: tableColumn?.identifier.rawValue == "Property" ? property.name : property.value)
        text.toolTip = property.value; text.lineBreakMode = .byTruncatingTail
        if property.extended && tableColumn?.identifier.rawValue == "Property" { text.font = .boldSystemFont(ofSize: NSFont.systemFontSize) }
        return text
    }
    @objc func openProperty() {
        guard displayed.indices.contains(properties.selectedRow) else { return }
        let detail = ExceptionPropertyWindow(displayed[properties.selectedRow]); detailWindows.append(detail)
        detail.run(owner: window)
    }
    @objc func copyReport() { copyAction(content.copyText(description: descriptionInput.string)) }
    @objc func sendReport() {
        guard send.isEnabled else { return }
        guard ErrorReportContent.containsInformation(descriptionInput.string) else {
            validation("Please provide as much as information as possible to help the developers solve this issue.")
            window?.makeFirstResponder(descriptionInput); return
        }
        guard confirmSend(), let url = content.issueURL(description: descriptionInput.string), openAction(url) else { return }
        quitReport()
    }
    @objc func ignoreReport() { if context.showIgnore && context.canIgnore { NSApp.stopModal(withCode: .OK) } }
    @objc func quitReport() { result = .quit; NSApp.stopModal(withCode: .cancel) }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard context.canIgnore else { return false }; NSApp.stopModal(withCode: .OK); return true
    }
    func run(owner: NSWindow?) -> Result {
        guard let window else { return .resume }
        if let owner { window.setFrameTopLeftPoint(NSPoint(x: owner.frame.midX - window.frame.width / 2, y: owner.frame.midY + window.frame.height / 2)) }
        else { window.center() }
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(descriptionInput)
        NSApp.runModal(for: window)
        detailWindows.forEach { $0.close() }; window.orderOut(nil)
        return result
    }
}

@MainActor
enum ApplicationErrorReporter {
    private static var reporting = false
    static func report(_ snapshot: ExceptionReportSnapshot, context: ErrorReportContext = .init(), owner suppliedOwner: NSWindow? = nil) {
        guard !reporting else { NSLog("Recursive application error: %@", snapshot.details); return }
        reporting = true
        let owner = suppliedOwner ?? NSApp.mainWindow
        Task { @MainActor in
            defer { reporting = false }
            let version = await UserEnvironmentInformation.gitVersion()
            let content = ErrorReportContent(exception: snapshot, environment: UserEnvironmentInformation.information(gitVersion: version))
            if ErrorReportWindow(content: content, context: context, gitVersion: version ?? "").run(owner: owner) == .quit || context.isTerminating {
                NSApp.terminate(nil)
            }
        }
    }
}

@objc(GitExtensionsApplication)
package final class GitExtensionsApplication: NSApplication {
    override package func reportException(_ exception: NSException) {
        ApplicationErrorReporter.report(.capture(exception))
    }
}
