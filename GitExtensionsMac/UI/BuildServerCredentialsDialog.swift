import AppKit
import GitCommands

@MainActor
enum BuildServerCredentialStore {
    static func account(_ key: String) -> String { "Credentials|" + key.lowercased() }
    static func load(_ key: String) -> BuildServerCredentials? {
        guard let text = BuildServerSettingsStore.token(account(key)), let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BuildServerCredentials.self, from: data)
    }
    static func save(_ value: BuildServerCredentials, key: String) throws {
        let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try RepositoryHostCredentials.save(text, for: account(key), service: RepositoryHostCredentials.buildServerService)
    }
}

@MainActor
final class BuildServerCredentialsController: NSViewController, NSWindowDelegate {
    var onComplete: (BuildServerCredentials?) -> Void = { _ in }
    private let key: String
    private var original: BuildServerCredentials
    private let guest = NSButton(radioButtonWithTitle: "Guest access", target: nil, action: nil)
    private let authenticated = NSButton(radioButtonWithTitle: "Authenticated user", target: nil, action: nil)
    private let bearer = NSButton(radioButtonWithTitle: "Bearer token", target: nil, action: nil)
    private let username = NSTextField(string: "")
    private let password = NSSecureTextField(string: "")
    private let token = NSSecureTextField(string: "")
    init(key: String, value: BuildServerCredentials = .init()) {
        self.key = key; original = value; super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.addArrangedSubview(NSTextField(wrappingLabelWithString: "Please enter the credentials for the build server at \(key)."))
        for button in [guest, authenticated, bearer] { button.target = self; button.action = #selector(methodChanged); root.addArrangedSubview(button) }
        for (caption, field) in [("Username:", username), ("Password:", password), ("Bearer token:", token)] {
            let label = NSTextField(labelWithString: caption); label.widthAnchor.constraint(equalToConstant: 90).isActive = true
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 340).isActive = true
            root.addArrangedSubview(NSStackView(views: [label, field]))
        }
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel)); cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: "OK", target: self, action: #selector(accept)); ok.keyEquivalent = "\r"
        root.addArrangedSubview(NSStackView(views: [cancel, ok]))
        view = root
        username.stringValue = original.username; password.stringValue = original.password; token.stringValue = original.bearerToken
        guest.state = original.kind == .guest ? .on : .off
        authenticated.state = original.kind == .usernameAndPassword ? .on : .off
        bearer.state = original.kind == .bearerToken ? .on : .off
        updateControls()
    }
    private func updateControls() {
        username.isEnabled = authenticated.state == .on; password.isEnabled = username.isEnabled
        token.isEnabled = bearer.state == .on
    }
    @objc private func methodChanged(_ sender: NSButton) {
        for button in [guest, authenticated, bearer] { button.state = button === sender ? .on : .off }
        updateControls()
        view.window?.makeFirstResponder(authenticated.state == .on ? username : bearer.state == .on ? token : guest)
    }
    var value: BuildServerCredentials {
        .init(kind: authenticated.state == .on ? .usernameAndPassword : bearer.state == .on ? .bearerToken : .guest,
              username: username.stringValue, password: password.stringValue, bearerToken: token.stringValue)
    }
    var enabledFields: (username: Bool, password: Bool, token: Bool) { (username.isEnabled, password.isEnabled, token.isEnabled) }
    @objc private func accept() { onComplete(value) }
    @objc private func cancel() { onComplete(nil) }
    func windowWillClose(_ notification: Notification) { onComplete(nil) }
}

@MainActor
private enum BuildServerCredentialPrompter {
    static var pending: [String: Task<BuildServerCredentials?, Never>] = [:]
    static func request(_ key: String, useStored: Bool) async -> BuildServerCredentials? {
        if useStored, let saved = BuildServerCredentialStore.load(key) { return saved }
        if let task = pending[key] { return await task.value }
        let task = Task { @MainActor in
            await withCheckedContinuation { continuation in
                let controller = BuildServerCredentialsController(key: key, value: BuildServerCredentialStore.load(key) ?? .init())
                let window = NSWindow(contentViewController: controller)
                window.delegate = controller
                window.title = "Enter credentials"; window.styleMask = [.titled, .closable]
                window.setContentSize(NSSize(width: 580, height: 310))
                let owner = NSApp.keyWindow
                var completed = false
                controller.onComplete = { value in
                    guard !completed else { return }; completed = true
                    if let value {
                        do { try BuildServerCredentialStore.save(value, key: key) }
                        catch { HostingMessages.error(error.localizedDescription, "Could not save credentials") }
                    }
                    if let owner { owner.endSheet(window) }
                    window.orderOut(nil)
                    controller.onComplete = { _ in }
                    continuation.resume(returning: value)
                }
                if let owner { owner.beginSheet(window) }
                else { window.center(); window.makeKeyAndOrderFront(nil) }
            }
        }
        pending[key] = task
        let value = await task.value
        pending[key] = nil
        return value
    }
}

extension GitUICommands {
    static func requestBuildServerCredentials(key: String, useStored: Bool) async -> BuildServerCredentials? {
        await BuildServerCredentialPrompter.request(key, useStored: useStored)
    }
}

@MainActor
final class TeamCityBuildChooserController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    final class Node: NSObject {
        let project: TeamCityProject?
        let build: TeamCityBuildType?
        var children: [Node] = []
        var loaded = false
        var loading: Task<[TeamCityBuildType], Error>?
        init(project: TeamCityProject) { self.project = project; build = nil; super.init() }
        init(build: TeamCityBuildType) { project = nil; self.build = build; super.init() }
        var title: String { project?.name ?? build.map { "\($0.name) (\($0.id))" } ?? "" }
    }
    private let adapter: TeamCityBuildAdapter
    private let selectedProject: String
    private let selectedBuild: String
    private let tree = NSOutlineView()
    private let status = NSTextField(labelWithString: "Loading…")
    private let ok = NSButton(title: "OK", target: nil, action: nil)
    private var roots: [Node] = []
    private var task: Task<Void, Never>?
    var onComplete: (TeamCityBuildType?) -> Void = { _ in }
    init(adapter: TeamCityBuildAdapter, project: String, build: String) {
        self.adapter = adapter; selectedProject = project; selectedBuild = build
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    deinit { task?.cancel() }
    override func loadView() {
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        let column = NSTableColumn(identifier: .init("Project")); tree.addTableColumn(column); tree.outlineTableColumn = column
        tree.headerView = nil; tree.delegate = self; tree.dataSource = self
        tree.target = self; tree.doubleAction = #selector(accept)
        let scroll = NSScrollView(); scroll.documentView = tree; scroll.hasVerticalScroller = true
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        root.addArrangedSubview(scroll); root.addArrangedSubview(status)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel)); cancel.keyEquivalent = "\u{1b}"
        ok.target = self; ok.action = #selector(accept); ok.keyEquivalent = "\r"; ok.isEnabled = false
        root.addArrangedSubview(NSStackView(views: [cancel, ok])); view = root
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let projects = try await adapter.availableProjects(); try Task.checkCancellation()
                let nodes = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, Node(project: $0)) })
                for project in projects {
                    guard let node = nodes[project.id] else { continue }
                    if let parent = project.parent.flatMap({ nodes[$0] }) { parent.children.append(node) } else { roots.append(node) }
                }
                for node in nodes.values { node.children.sort { $0.title < $1.title } }
                tree.reloadData(); roots.forEach { tree.expandItem($0) }; status.stringValue = ""
                if let selected = nodes[selectedProject] {
                    var parent = selected.project?.parent
                    while let id = parent, let node = nodes[id] { tree.expandItem(node); parent = node.project?.parent }
                    await loadBuilds(selected)
                    tree.expandItem(selected)
                    let target = selected.children.first { $0.build?.id == selectedBuild } ?? selected
                    let row = tree.row(forItem: target)
                    if row >= 0 { tree.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
                }
            } catch is CancellationError { } catch { status.stringValue = "Failed to load the projects and build list. Please verify the server url." }
        }
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? Node)?.children.count ?? roots.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { ((item as? Node)?.children ?? roots)[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? Node)?.project != nil }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        let field = NSTextField(labelWithString: node.title); if node.build != nil { field.textColor = .selectedContentBackgroundColor }; return field
    }
    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? Node else { return }
        Task { await loadBuilds(node) }
    }
    private func loadBuilds(_ node: Node) async {
        guard !node.loaded, let project = node.project else { return }
        if node.loading == nil { node.loading = Task { try await adapter.projectBuilds(project.id) } }
        guard let loading = node.loading else { return }
        do {
            let builds = try await loading.value; try Task.checkCancellation()
            guard !node.loaded else { return }
            node.loaded = true; node.loading = nil
            let selected = tree.item(atRow: tree.selectedRow) as? Node
            func expanded(_ node: Node) -> [Node] {
                (tree.isItemExpanded(node) ? [node] : []) + node.children.flatMap(expanded)
            }
            let expansion = roots.flatMap(expanded)
            node.children += builds.sorted { $0.id < $1.id }.map(Node.init(build:))
            tree.reloadItem(node, reloadChildren: true)
            for item in expansion { tree.expandItem(item) }
            if let selected {
                let row = tree.row(forItem: selected)
                if row >= 0 { tree.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            }
        } catch { node.loading = nil; status.stringValue = error.localizedDescription }
    }
    func outlineViewSelectionDidChange(_ notification: Notification) { ok.isEnabled = (tree.item(atRow: tree.selectedRow) as? Node)?.build != nil }
    @objc private func accept() { if let build = (tree.item(atRow: tree.selectedRow) as? Node)?.build { onComplete(build) } }
    @objc private func cancel() { task?.cancel(); onComplete(nil) }
}
