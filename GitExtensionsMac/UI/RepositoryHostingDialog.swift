import AppKit
import GitCommands
import GitExtensionsCore
import Security

enum RepositoryHostCredentials {
    static let gitHubAccount = "github.com"
    static let hostService = "GitExtensionsMac.RepositoryHosts"
    static let buildServerService = "GitExtensionsMac.BuildServers"
    static func token(for account: String, service: String = hostService) throws -> String {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw PluginError.invalid("Unable to read the repository-host credential from Keychain (\(status)).")
        }
        return value
    }
    static func save(_ token: String?, for account: String, service: String = hostService) throws {
        let key: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        let status: OSStatus
        if let token {
            let update = SecItemUpdate(key as CFDictionary, [kSecValueData: Data(token.utf8)] as CFDictionary)
            if update == errSecItemNotFound {
                var attributes = key
                attributes[kSecValueData] = Data(token.utf8)
                attributes[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                status = SecItemAdd(attributes as CFDictionary, nil)
            } else { status = update }
        } else { status = SecItemDelete(key as CFDictionary) }
        guard status == errSecSuccess || (token == nil && status == errSecItemNotFound) else {
            throw PluginError.invalid("Unable to update the repository-host credential in Keychain (\(status)).")
        }
    }
    static var gitHubToken: String { (try? token(for: gitHubAccount)) ?? "" }
}

@MainActor
enum HostingMessages {
    static var present: (_ message: String, _ title: String, _ style: NSAlert.Style) -> Void = { message, title, style in
        let alert = NSAlert()
        alert.messageText = title.isEmpty ? message : title
        alert.informativeText = title.isEmpty ? "" : message
        alert.alertStyle = style
        alert.runModal()
    }
    static func error(_ message: String, _ title: String = "Error") { present(message, title, .critical) }
    static func information(_ message: String, _ title: String) { present(message, title, .informational) }
}

@MainActor
final class GitHubAccountSettingsController: NSViewController {
    private let token = NSSecureTextField(string: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let generated: NSViewController?
    init(host: GitExtensionPluginHost?, settings: [GitExtensionPluginSetting]) {
        generated = host.map { PluginSettingsViewController(settings: settings, host: $0) }
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 520))
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.addArrangedSubview(NSTextField(labelWithString: "Personal Access Token"))
        token.placeholderString = RepositoryHostCredentials.gitHubToken.isEmpty ? "Not set" : "Stored in Keychain — enter a replacement"
        stack.addArrangedSubview(token)
        let actions = NSStackView()
        for (title, action) in [("Save token", #selector(save)), ("Remove token", #selector(remove))] {
            actions.addArrangedSubview(NSButton(title: title, target: self, action: action))
        }
        stack.addArrangedSubview(actions)
        for (title, action) in [("Generate a GitHub personal access token", #selector(generate)), ("Manage GitHub personal access token", #selector(manage))] {
            let link = NSButton(title: title, target: self, action: action)
            link.isBordered = false; link.contentTintColor = .linkColor
            stack.addArrangedSubview(link)
        }
        status.stringValue = "Tokens are stored in the macOS Keychain and take effect immediately; existing tokens are never displayed."
        stack.addArrangedSubview(status)
        if let generated {
            addChild(generated)
            stack.addArrangedSubview(generated.view)
            generated.view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        } else {
            let close = NSButton(title: "Close", target: self, action: #selector(closeWindow)); close.keyEquivalent = "\r"
            stack.addArrangedSubview(close)
        }
        view.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16), token.widthAnchor.constraint(equalTo: stack.widthAnchor)])
    }
    @objc private func save() {
        guard !token.stringValue.isEmpty else { status.stringValue = "Enter a token to replace the existing credential."; return }
        do { try RepositoryHostCredentials.save(token.stringValue, for: RepositoryHostCredentials.gitHubAccount); token.stringValue = ""; status.stringValue = "Token saved in Keychain." }
        catch { NSAlert(error: error).runModal() }
    }
    @objc private func remove() {
        let alert = NSAlert(); alert.messageText = "Remove the GitHub credential?"; alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Remove")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do { try RepositoryHostCredentials.save(nil, for: RepositoryHostCredentials.gitHubAccount); status.stringValue = "Token removed." }
        catch { NSAlert(error: error).runModal() }
    }
    @objc private func closeWindow() { view.window?.close() }
    @objc private func generate() { NSWorkspace.shared.open(URL(string: "https://github.com/settings/tokens/new?description=Token%20for%20GitExtensions&scopes=repo,public_repo")!) }
    @objc private func manage() { NSWorkspace.shared.open(URL(string: "https://github.com/settings/tokens")!) }
}

@MainActor
final class GitHubRepositoryPlugin: NSObject, GitExtensionPlugin {
    override required init() { super.init() }
    let identifier = UUID(uuidString: "2EC3E1F0-EF37-413F-BEA5-B8FE1F9C505C")!
    let name = "GitHub"
    let pluginDescription = "GitHub"
    var icon: NSImage? { NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: "GitHub") }
    static let helperEnabled = "IssueCommitMessageHelperEnabled"
    static let helperMaxCount = "IssueCommitMessageHelperMaxCount"
    static let noToken = "No GitHub personal access token (PAT) defined"
    static let noAssignedIssues = "No assigned GitHub issues found"
    static var tokenProvider: () -> String = { RepositoryHostCredentials.gitHubToken }
    static var token: String { tokenProvider() }
    var settings: [GitExtensionPluginSetting] {
        [.init(name: Self.helperEnabled, caption: "Enable commit message issue helper", defaultValue: "true", kind: .boolean),
         .init(name: Self.helperMaxCount, caption: "Maximum number of issues retrieved", defaultValue: "10",
               kind: .number(minimum: Int(Int32.min), maximum: Int(Int32.max)))]
    }
    var clientFactory: (String) -> RepositoryHostClient = { token in
        RepositoryHostClient(identity: HostedRepositoryIdentity.parse("https://github.com/api/api")!, token: token)
    }
    private var currentMessages: [String] = []
    private var observers: [UUID] = []
    private(set) var issueTask: Task<Void, Never>?

    func register(with host: GitExtensionPluginHost) throws {
        observers = [
            host.observe("PreCommit") { [weak self, weak host] _ in
                if let self, let host { self.preCommit(host) }
                return true
            },
            host.observe("PostCommit") { [weak self, weak host] _ in
                guard let self, let host else { return true }
                currentMessages.forEach(host.removeCommitTemplate)
                currentMessages.removeAll()
                return true
            }
        ]
    }
    func unregister(from host: GitExtensionPluginHost) {
        observers.forEach(host.removeObserver); observers = []
        issueTask?.cancel()
    }

    private func preCommit(_ host: GitExtensionPluginHost) {
        guard (try? host.setting(Self.helperEnabled))??.lowercased() != "false" else { return }
        let token = Self.token
        guard !token.isEmpty else {
            host.addCommitTemplate(Self.noToken, text: { "" }, icon: icon)
            return
        }
        let maximum = Int((try? host.setting(Self.helperMaxCount)) ?? nil ?? "") ?? 10
        let client = clientFactory(token)
        issueTask?.cancel()
        issueTask = Task { @MainActor [weak self, weak host] in
            guard let host else { return }
            let config = try? await host.runGit(arguments: ["config", "--get-regexp", #"^remote\..*\.url$"#], accessesRemote: false, mayChangeRepository: false)
            let remotes = String(decoding: config?.stdout ?? Data(), as: UTF8.self).split(separator: "\n").compactMap { line -> HostedRepositoryIdentity? in
                guard let space = line.firstIndex(of: " ") else { return nil }
                let identity = HostedRepositoryIdentity.parse(String(line[line.index(after: space)...]))
                return identity?.provider == .gitHub ? identity : nil
            }
            let hosted = Array(Set(remotes))
            guard !hosted.isEmpty, let issues = try? await client.assignedIssues(), !Task.isCancelled, let self else { return }
            if issues.allSatisfy({ $0.number == 0 }) {
                host.addCommitTemplate(Self.noAssignedIssues, text: { "" }, icon: icon)
                return
            }
            let recent = issues.filter { issue in
                issue.number != 0 && hosted.contains { $0.owner == issue.repository?.owner.login && $0.repository == issue.repository?.name }
            }.enumerated().sorted { ($1.element.updated_at, $0.offset) < ($0.element.updated_at, $1.offset) }.map(\.element).prefix(max(0, maximum))
            for issue in recent {
                let suffix = hosted.count > 1 ? " (\(issue.repository?.owner.login ?? "")/\(issue.repository?.name ?? ""))" : ""
                let key = "\(issue.number): \(issue.title)\(suffix)"
                currentMessages.append(key)
                let text = issue.commitTemplate
                host.addCommitTemplate(key, text: { text }, icon: icon)
            }
        }
    }

    func execute(in host: GitExtensionPluginHost) async throws -> Bool {
        if Self.token.isEmpty {
            await Self.presentSettings(host: host, settings: settings, owner: host.owner)
        } else {
            HostingMessages.error("You already have an personal access token. To get a new one, delete your old one in Plugins > Plugin Settings first.")
        }
        return false
    }
    func settingsController(in host: GitExtensionPluginHost) throws -> NSViewController? {
        GitHubAccountSettingsController(host: host, settings: settings)
    }

    static func presentSettings(host: GitExtensionPluginHost?, settings: [GitExtensionPluginSetting], owner: NSWindow?) async {
        let controller = GitHubAccountSettingsController(host: host, settings: settings)
        let window = NSWindow(contentViewController: controller)
        window.title = "Settings — GitHub"; window.isReleasedWhenClosed = false
        window.styleMask = [.titled, .closable, .resizable]
        if let owner { window.setFrameOrigin(NSPoint(x: owner.frame.midX - window.frame.width / 2, y: owner.frame.midY - window.frame.height / 2)) }
        await withCheckedContinuation { continuation in
            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                if let observer { NotificationCenter.default.removeObserver(observer) }
                continuation.resume()
            }
            window.makeKeyAndOrderFront(nil)
        }
    }

    static func ensureConfigured(owner: NSWindow?, host: GitExtensionPluginHost? = nil) async -> Bool {
        if !token.isEmpty { return true }
        let plugin = GitHubRepositoryPlugin()
        await presentSettings(host: host, settings: plugin.settings, owner: owner)
        return !token.isEmpty
    }
}


@MainActor
struct GitHubHostingContext {
    let remotes: [HostedRemote]
    let currentRemote: String?
    let protocolRemoteURL: String?
    let source: (any RepositoryHostingDataSource)?
    let saveRemote: ((RepositoryRemoteSaveRequest) async throws -> Void)?
    let client: (HostedRepositoryIdentity) throws -> RepositoryHostClient
    var lockNotifier: () -> Void = {}
    var unlockNotifier: () -> Void = {}
    var changed: () -> Void = {}
}

@MainActor
enum HostingProcessDialog {
    typealias Operation = @Sendable (@escaping GitOutputHandler) async throws -> Bool
    static var run: (_ title: String, _ parent: NSWindow, _ operation: @escaping Operation) async -> Bool = { title, parent, operation in
        let controller = HostingProcessViewController(operation: operation)
        let panel = NSPanel(contentViewController: controller)
        panel.title = title; panel.styleMask = [.titled, .closable, .resizable]
        panel.setContentSize(NSSize(width: 700, height: 430)); panel.minSize = NSSize(width: 520, height: 300)
        panel.delegate = controller
        return await withCheckedContinuation { continuation in
            controller.onClose = { succeeded in
                if parent.attachedSheet === panel { parent.endSheet(panel) }
                continuation.resume(returning: succeeded)
            }
            parent.beginSheet(panel); controller.start()
        }
    }
    static func command(_ command: GitCommand, title: String, source: any RepositoryHostingDataSource, parent: NSWindow) async -> Bool {
        await run(title, parent) { output in
            let result = try await source.runHostingCommand(command, output: output)
            guard result.succeeded else {
                throw GitError.commandFailed(arguments: result.arguments, status: result.exitStatus, stderr: "")
            }
            return true
        }
    }
}

@MainActor
private final class HostingProcessViewController: NSViewController, NSWindowDelegate {
    var onClose: ((Bool) -> Void)?
    private let operation: HostingProcessDialog.Operation
    private let progress = NSProgressIndicator()
    private let status = NSTextField(labelWithString: "Running…")
    private let outputView = NSTextView()
    private let keepOpen = NSButton(checkboxWithTitle: "Keep dialog open", target: nil, action: nil)
    private let abortButton = NSButton(title: "Abort", target: nil, action: nil)
    private let closeButton = NSButton(title: "OK", target: nil, action: nil)
    private var task: Task<Void, Never>?
    private var succeeded = false
    private var didClose = false
    init(operation: @escaping HostingProcessDialog.Operation) { self.operation = operation; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        let root = NSView()
        progress.style = .bar; progress.isIndeterminate = true; progress.controlSize = .small
        progress.widthAnchor.constraint(equalToConstant: 92).isActive = true
        status.font = AppSettingsStore.shared.applicationFont(size: 12, weight: .bold)
        outputView.isEditable = false; outputView.isVerticallyResizable = true; outputView.autoresizingMask = [.width, .height]
        outputView.font = AppSettingsStore.shared.fontPreferences.font(.monospace, fallback: .monospacedSystemFont(ofSize: 11, weight: .regular))
        let scroll = NSScrollView(); scroll.documentView = outputView; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        keepOpen.state = AppSettingsStore.shared.pullPreferences.closeProcessOnSuccess ? .off : .on
        keepOpen.target = self; keepOpen.action = #selector(keepOpenChanged)
        abortButton.target = self; abortButton.action = #selector(abort)
        closeButton.target = self; closeButton.action = #selector(closeDialog); closeButton.keyEquivalent = "\r"; closeButton.isEnabled = false
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [progress, status])
        let footer = NSStackView(views: [keepOpen, spacer, abortButton, closeButton])
        for item in [header, scroll, footer] { item.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(item) }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), header.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 9), scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -9),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10)
        ])
        view = root
    }
    func start() {
        progress.startAnimation(nil)
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                succeeded = try await operation { [weak self] event in Task { @MainActor in self?.append(event.text, error: event.stream == .standardError) } }
                status.stringValue = succeeded ? "Completed successfully" : "Failed"
            } catch is CancellationError { status.stringValue = "Aborted"; append("\nAborted\n", error: true) }
            catch { status.stringValue = "Failed"; append("\n\(error.localizedDescription)\n", error: true) }
            progress.stopAnimation(nil); abortButton.isEnabled = false; closeButton.isEnabled = true; task = nil
            if succeeded, keepOpen.state == .off { finish() }
        }
    }
    private func append(_ text: String, error: Bool) {
        outputView.textStorage?.append(NSAttributedString(string: text, attributes: [.font: outputView.font as Any, .foregroundColor: error ? NSColor.systemRed : NSColor.textColor]))
        outputView.scrollToEndOfDocument(nil)
    }
    @objc private func keepOpenChanged() {
        var preferences = AppSettingsStore.shared.pullPreferences
        preferences.closeProcessOnSuccess = keepOpen.state == .off
        AppSettingsStore.shared.savePullPreferences(preferences)
        if keepOpen.state == .off, succeeded, task == nil { finish() }
    }
    @objc private func abort() { status.stringValue = "Aborting…"; task?.cancel() }
    @objc private func closeDialog() { finish() }
    override func cancelOperation(_ sender: Any?) { task != nil ? abort() : finish() }
    func windowWillClose(_ notification: Notification) { task?.cancel(); finish() }
    private func finish() { guard !didClose else { return }; didClose = true; onClose?(succeeded) }
}

private func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }
private func scrolled(_ view: NSView) -> NSScrollView {
    let scroll = NSScrollView(); scroll.documentView = view; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; return scroll
}
private func textView() -> NSTextView {
    let view = NSTextView(); view.isRichText = false; view.isVerticallyResizable = true; view.isHorizontallyResizable = false
    view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true; return view
}
private func configure(_ table: NSTableView, _ columns: [(String, String, CGFloat)], owner: NSTableViewDataSource & NSTableViewDelegate) {
    for (id, title, width) in columns {
        let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width; table.addTableColumn(column)
    }
    table.dataSource = owner; table.delegate = owner; table.usesAlternatingRowBackgroundColors = true
}
private func constrain(_ root: NSView, in window: NSWindow, inset: CGFloat = 12) {
    window.contentView!.addSubview(root); root.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: inset),
        root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -inset),
        root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: inset),
        root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -inset)])
}

@MainActor
final class PullRequestsWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let context: GitHubHostingContext
    private let choose = NSPopUpButton()
    private let list = NSTableView()
    private let files = NSTableView()
    private let diff = DiffContentViewController()
    private let tabs = NSTabView()
    private let discussion = NSTextView()
    private let comment = textView()
    private let fetchButton = NSButton(title: "Fetch to pr/ branch", target: nil, action: nil)
    private let addAndFetchButton = NSButton(title: "Add remote and fetch", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close pull request", target: nil, action: nil)
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let postButton = NSButton(title: "Post comment", target: nil, action: nil)
    private var repositories: [Int: HostedRepositoryDetails] = [:]
    private var pullRequests: [HostedPullRequest] = []
    private var loading = false
    private var isFirstLoad = true
    private var cloneHTTPS = false
    private var current: HostedPullRequest?
    private var patch: PatchPreview?
    private var listTask: Task<Void, Never>?
    private var detailTasks: [Task<Void, Never>] = []
    private(set) var busy = false { didSet { updateButtons() } }

    init(context: GitHubHostingContext) {
        self.context = context
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 754, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "View Pull Requests"; window.minSize = NSSize(width: 640, height: 420); window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self; window.setFrameAutosaveName("RepositoryHosting.PullRequests")
        configure(list, [("id", "#", 44), ("heading", "Heading", 340), ("by", "By", 110), ("created", "Created", 150),
                         ("branch", "Will be fetched to branch", 190)], owner: self)
        configure(files, [("file", "File", 600)], owner: self)
        choose.target = self; choose.action = #selector(selectedOwnerChanged)
        let top = NSStackView(views: [label("Choose repository:"), choose])
        list.target = self; list.doubleAction = nil
        for (button, action) in [(fetchButton, #selector(fetchToBranch)), (addAndFetchButton, #selector(addRemoteAndFetch)),
                                 (closeButton, #selector(closePullRequest)), (refreshButton, #selector(refreshDiscussion)), (postButton, #selector(postComment))] {
            button.target = self; button.action = action
        }
        let actions = NSStackView(views: [fetchButton, addAndFetchButton, NSView(), closeButton])
        actions.orientation = .vertical; actions.alignment = .width; actions.distribution = .fill
        actions.widthAnchor.constraint(equalToConstant: 170).isActive = true
        let upper = NSStackView(views: [scrolled(list), actions]); upper.alignment = .top
        let upperPane = NSStackView(views: [top, upper]); upperPane.orientation = .vertical; upperPane.alignment = .leading
        upper.widthAnchor.constraint(equalTo: upperPane.widthAnchor).isActive = true

        let fileSplit = NSSplitView(); fileSplit.isVertical = false; fileSplit.dividerStyle = .thin
        fileSplit.addArrangedSubview(scrolled(files)); fileSplit.addArrangedSubview(diff.view)
        diff.supportedFileCommands = []
        let diffs = NSTabViewItem(identifier: "diffs"); diffs.label = "Diffs"; diffs.view = fileSplit
        discussion.isEditable = false; discussion.isVerticallyResizable = true; discussion.autoresizingMask = [.width]
        discussion.textContainer?.widthTracksTextView = true
        let commentScroll = scrolled(comment)
        commentScroll.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let commentButtons = NSStackView(views: [refreshButton, NSView(), postButton])
        let comments = NSStackView(views: [scrolled(discussion), commentScroll, commentButtons])
        comments.orientation = .vertical; comments.alignment = .width
        let commentsItem = NSTabViewItem(identifier: "comments"); commentsItem.label = "Comments"; commentsItem.view = comments
        tabs.addTabViewItem(diffs); tabs.addTabViewItem(commentsItem)

        let split = NSSplitView(); split.isVertical = false; split.dividerStyle = .thin
        split.addArrangedSubview(upperPane); split.addArrangedSubview(tabs)
        constrain(split, in: window)
        split.setPosition(170, ofDividerAt: 0); fileSplit.setPosition(116, ofDividerAt: 0)
        updateButtons()
        load()
    }
    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) { listTask?.cancel(); detailTasks.forEach { $0.cancel() } }

    private var selectedRemoteIndex: Int? { context.remotes.indices.contains(choose.indexOfSelectedItem) ? choose.indexOfSelectedItem : nil }
    private func client(_ index: Int) throws -> RepositoryHostClient { try context.client(context.remotes[index].identity) }

    private func load() {
        busy = true
        listTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for (index, remote) in context.remotes.enumerated() {
                do { repositories[index] = try await client(index).repository() }
                catch is CancellationError { return }
                catch { HostingMessages.error(String(format: "%@\n\nRemote: %@", error.localizedDescription, remote.displayData), "Remote ignored") }
            }
            choose.removeAllItems()
            choose.addItems(withTitles: context.remotes.map(\.displayData))
            cloneHTTPS = HostedRemote.isHTTP(context.protocolRemoteURL ?? "")
            if let index = context.remotes.firstIndex(where: { $0.name.caseInsensitiveCompare(context.currentRemote ?? "") == .orderedSame }) {
                choose.selectItem(at: index)
            } else if !context.remotes.isEmpty { choose.selectItem(at: 0) }
            busy = false
            selectedOwnerChanged()
        }
    }

    @objc private func selectedOwnerChanged() {
        pullRequests = []; list.reloadData()
        guard let index = selectedRemoteIndex else { return }
        listTask?.cancel()
        busy = true
        listTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if repositories[index] == nil {
                do { repositories[index] = try await client(index).repository() }
                catch is CancellationError { return }
                catch { busy = false; if isFirstLoad { selectNext() }; return }
            }
            choose.isEnabled = false
            resetAndShowLoading()
            do {
                let result = try await client(index).pullRequests()
                try Task.checkCancellation()
                choose.isEnabled = true
                setPullRequests(result)
            } catch is CancellationError { return }
            catch {
                choose.isEnabled = true; loading = false; list.reloadData()
                HostingMessages.error("Failed to fetch pull data!\n" + error.localizedDescription)
            }
            busy = false
        }
    }

    private func selectNext() {
        let next = choose.indexOfSelectedItem + 1
        guard context.remotes.indices.contains(next) else { isFirstLoad = false; loading = false; list.reloadData(); return }
        choose.selectItem(at: next)
        selectedOwnerChanged()
    }

    private func resetAndShowLoading() {
        discussion.string = ""; diff.view.isHidden = true; patch = nil; files.reloadData()
        current = nil; loading = true; list.reloadData(); updateButtons()
    }

    private func setPullRequests(_ result: [HostedPullRequest]) {
        if isFirstLoad {
            if result.isEmpty, !context.remotes.isEmpty, context.remotes.indices.contains(choose.indexOfSelectedItem + 1) {
                selectNext(); return
            }
            isFirstLoad = false
        }
        loading = false
        pullRequests = result
        list.reloadData()
        if !pullRequests.isEmpty { list.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === files { return patch?.files.count ?? 0 }
        return loading ? 1 : pullRequests.count
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let column = tableColumn?.identifier.rawValue
        if tableView === files { return patch.map { label($0.files[row].path) } }
        if loading { return label(column == "heading" ? " : LOADING : " : "") }
        let entry = pullRequests[row]
        let text: String
        switch column {
        case "id": text = String(entry.number)
        case "by": text = entry.user.login
        case "created": text = DateFormatter.localizedString(from: entry.created_at, dateStyle: .short, timeStyle: .medium)
        case "branch": text = entry.fetchBranch
        default: text = entry.title
        }
        let field = label(text); field.lineBreakMode = .byTruncatingTail; return field
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === files { showSelectedFile(); return }
        let previous = current
        guard !loading, pullRequests.indices.contains(list.selectedRow), list.numberOfSelectedRows == 1 else {
            current = nil; discussion.string = ""; diff.view.isHidden = true; updateButtons(); return
        }
        current = pullRequests[list.selectedRow]
        updateButtons()
        guard previous?.number != current?.number else { return }
        discussion.string = ""; patch = nil; files.reloadData(); diff.view.isHidden = true
        loadDiff(); loadDiscussion()
    }
    private func updateButtons() {
        let enabled = current != nil && !busy
        [fetchButton, addAndFetchButton, closeButton, refreshButton, postButton].forEach { $0.isEnabled = enabled }
    }

    private func loadDiff() {
        guard let pullRequest = current, let index = selectedRemoteIndex else { return }
        detailTasks.append(Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let data = try await client(index).pullRequestDiff(pullRequest.number)
                guard current?.number == pullRequest.number else { return }
                guard let parsed = try? PatchPreviewParser.parse(data), !(parsed.files.isEmpty && !data.isEmpty) else {
                    HostingMessages.error("Error: Unable to understand patch"); return
                }
                patch = parsed; files.reloadData()
                if !parsed.files.isEmpty { files.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); showSelectedFile() }
            } catch is CancellationError { }
            catch { HostingMessages.error("Failed to load diff data!\n" + error.localizedDescription) }
        })
    }
    private func showSelectedFile() {
        guard let patch, patch.files.indices.contains(files.selectedRow) else { return }
        let file = patch.files[files.selectedRow]
        diff.view.isHidden = false
        diff.apply(file: file, diff: patch.diffs[file.id])
    }

    static func discussionText(_ entries: [HostedDiscussionEntry]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let heading: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.textColor]
        for entry in entries {
            var title = DateFormatter.localizedString(from: entry.created, dateStyle: .short, timeStyle: .medium) + "  " + entry.author
            if let commit = entry.commit { title += "  Commit:  " + commit }
            result.append(NSAttributedString(string: title + "\n", attributes: heading))
            result.append(NSAttributedString(string: entry.body + "\n\n", attributes: body))
        }
        return result
    }
    private func loadDiscussion() {
        guard let pullRequest = current, let index = selectedRemoteIndex else { return }
        detailTasks.append(Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let entries = try await client(index).discussion(pullRequest)
                guard current?.number == pullRequest.number else { return }
                discussion.textStorage?.setAttributedString(Self.discussionText(entries))
                discussion.scrollToEndOfDocument(nil)
            } catch is CancellationError { }
            catch {
                HostingMessages.error("Could not load discussion!\n" + error.localizedDescription)
                discussion.string = ""
            }
        })
    }
    @objc private func refreshDiscussion() { loadDiscussion() }
    @objc private func postComment() {
        let text = comment.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pullRequest = current, let index = selectedRemoteIndex, !text.isEmpty else { return }
        detailTasks.append(Task { @MainActor [weak self] in
            guard let self else { return }
            do { _ = try await client(index).postComment(pullRequest.number, body: text); comment.string = ""; loadDiscussion() }
            catch is CancellationError { }
            catch { HostingMessages.error("Failed to post discussion item!\n" + error.localizedDescription) }
        })
    }

    @objc private func closePullRequest() {
        guard let pullRequest = current, let index = selectedRemoteIndex else { return }
        detailTasks.append(Task { @MainActor [weak self] in
            guard let self else { return }
            do { _ = try await client(index).closePullRequest(pullRequest.number); selectedOwnerChanged() }
            catch is CancellationError { }
            catch { HostingMessages.error("Failed to close pull request!\n" + error.localizedDescription) }
        })
    }

    @objc private func fetchToBranch() {
        guard let pullRequest = current, let window, let source = context.source else { return }
        guard let head = pullRequest.head.repo else { HostingMessages.error("The pull request's source repository is no longer available."); return }
        let command = RepositoryHostingCommands.fetchPullRequest(url: head.cloneURL(https: cloneHTTPS), headRef: pullRequest.head.ref, localBranch: pullRequest.fetchBranch)
        busy = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { busy = false }
            guard await HostingProcessDialog.command(command, title: "Fetch", source: source, parent: window) else { return }
            context.changed()
            close()
        }
    }

    @objc private func addRemoteAndFetch() {
        guard let pullRequest = current, let window, let source = context.source else { return }
        guard let head = pullRequest.head.repo else { HostingMessages.error("The pull request's source repository is no longer available."); return }
        let remoteName = pullRequest.user.login, remoteURL = head.cloneURL(https: cloneHTTPS), remoteRef = pullRequest.head.ref
        busy = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            context.lockNotifier()
            defer { context.unlockNotifier(); busy = false }
            if let existing = context.remotes.firstIndex(where: { $0.name == remoteName }) {
                let details: HostedRepositoryDetails
                do {
                    if let cached = repositories[existing] { details = cached }
                    else { details = try await client(existing).repository(); repositories[existing] = details }
                } catch { HostingMessages.error(error.localizedDescription); return }
                if details.cloneURL(https: cloneHTTPS) != remoteURL {
                    HostingMessages.error(String(format: "ERROR: Remote with name %@ already exists but it points to a different repository!\nDetails: Is %@ expected %@",
                                                 remoteName, details.cloneURL(https: cloneHTTPS), remoteURL))
                    return
                }
            } else {
                do {
                    guard let saveRemote = context.saveRemote else { throw RepositoryHostError.unsupported }
                    try await saveRemote(.init(originalName: nil, name: remoteName, fetchURL: remoteURL, pushURL: nil,
                                                       puttyKeyFile: nil, color: nil, prefix: nil))
                } catch {
                    HostingMessages.error(error.localizedDescription, String(format: "Could not add remote with name %@ and URL %@", remoteName, remoteURL))
                    return
                }
                context.changed()
            }
            guard await HostingProcessDialog.command(RepositoryHostingCommands.fetchRemoteBranch(remote: remoteName, ref: remoteRef),
                                                     title: "Fetch", source: source, parent: window) else { return }
            context.changed()
            if await HostingProcessDialog.command(RepositoryHostingCommands.checkout(remote: remoteName, ref: remoteRef),
                                                  title: "Checkout", source: source, parent: window) {
                context.changed()
            }
            close()
        }
    }
}

@MainActor
final class CreateHostedPullRequestWindowController: NSWindowController, NSWindowDelegate, NSComboBoxDelegate {
    private let context: GitHubHostingContext
    private let chooseRemote: String?
    private let targetRepository = NSPopUpButton()
    private let yourBranch = NSComboBox()
    private let targetBranch = NSComboBox()
    private let titleField = NSTextField(string: "")
    private let body = textView()
    private let createButton = NSButton(title: "Create", target: nil, action: nil)
    private var foreign: [HostedRemote] = []
    private var mine: HostedRemote?
    private var login = ""
    private var previousTitle = ""
    private var ignoreRemoteSelection = true
    private var tasks: [Task<Void, Never>] = []
    private var subjectTask: Task<Void, Never>?

    init(context: GitHubHostingContext, chooseRemote: String? = nil) {
        self.context = context; self.chooseRemote = chooseRemote
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 546, height: 380),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Create Pull Request"; window.minSize = NSSize(width: 480, height: 340); window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self; window.setFrameAutosaveName("RepositoryHosting.CreatePullRequest")
        targetRepository.identifier = .init("pullRequest.targetRepository")
        yourBranch.identifier = .init("pullRequest.sourceBranch")
        targetBranch.identifier = .init("pullRequest.targetBranch")
        titleField.identifier = .init("pullRequest.title")
        body.identifier = .init("pullRequest.body")
        let grid = NSGridView(views: [[label("Target repository:"), targetRepository], [label("Your branch:"), yourBranch], [label("Target branch:"), targetBranch]])
        grid.column(at: 0).xPlacement = .trailing
        let data = NSStackView(views: [label("Title:"), titleField, label("Body:"), scrolled(body)])
        data.orientation = .vertical; data.alignment = .width
        let group = NSBox(); group.title = "Pull request data"; group.contentView = data
        data.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 8, right: 8)
        createButton.target = self; createButton.action = #selector(create); createButton.keyEquivalent = "\r"; createButton.isEnabled = false
        let root = NSStackView(views: [grid, group, createButton]); root.orientation = .vertical; root.alignment = .trailing
        grid.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        group.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        constrain(root, in: window)
        targetRepository.target = self; targetRepository.action = #selector(targetChanged)
        yourBranch.delegate = self; targetBranch.delegate = self
        yourBranch.stringValue = "Loading..."
        tasks.append(Task { @MainActor [weak self] in await self?.load() })
    }
    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) { tasks.forEach { $0.cancel() }; subjectTask?.cancel() }

    private func load() {
        tasks.append(Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if let first = context.remotes.first { login = try await context.client(first.identity).currentUser() }
            } catch is CancellationError { return }
            catch { login = "" }
            foreign = context.remotes.filter { $0.identity.owner != login }
            mine = context.remotes.first { $0.identity.owner == login }
            guard !foreign.isEmpty else {
                HostingMessages.error("Failed to create pull request.\nPlease clone GitHub repository before pull request.", "")
                close(); return
            }
            targetRepository.addItems(withTitles: foreign.map(\.displayData))
            if let chooseRemote { if let index = foreign.firstIndex(where: { $0.name == chooseRemote }) { targetRepository.selectItem(at: index) } }
            else { targetRepository.selectItem(at: 0) }
            ignoreRemoteSelection = false
            targetChanged()
            yourBranch.removeAllItems()
            if let mine { populate(yourBranch, from: mine) } else { yourBranch.stringValue = "" }
            if let template = try? await context.source?.pullRequestTemplate(), !template.isEmpty { body.string = template }
        })
    }

    @objc private func targetChanged() {
        guard !ignoreRemoteSelection, foreign.indices.contains(targetRepository.indexOfSelectedItem) else { return }
        targetBranch.removeAllItems(); targetBranch.stringValue = "Loading..."
        populate(targetBranch, from: foreign[targetRepository.indexOfSelectedItem])
    }

    private func populate(_ combo: NSComboBox, from remote: HostedRemote) {
        tasks.append(Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let client = try context.client(remote.identity)
                let branches = try await client.branches()
                let defaultBranch = try await client.repository().default_branch
                try Task.checkCancellation()
                combo.removeAllItems()
                combo.addItems(withObjectValues: branches.map(\.name))
                if !branches.isEmpty {
                    combo.selectItem(at: branches.lastIndex(where: { $0.name == defaultBranch }) ?? 0)
                    combo.stringValue = branches[combo.indexOfSelectedItem].name
                    branchChanged()
                }
                createButton.isEnabled = true
            } catch is CancellationError { }
            catch {
                HostingMessages.error(String(format: "%@\n\nRemote: %@", error.localizedDescription, remote.displayData), "Fail to load target branches")
            }
        })
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let combo = notification.object as? NSComboBox, combo.indexOfSelectedItem >= 0 else { return }
        combo.stringValue = combo.itemObjectValue(at: combo.indexOfSelectedItem) as? String ?? ""
        branchChanged()
    }

    private func branchChanged() {
        guard titleField.stringValue == previousTitle, let mine,
              !yourBranch.stringValue.trimmingCharacters(in: .whitespaces).isEmpty, yourBranch.stringValue != "Loading..." else { return }
        let branch = yourBranch.stringValue
        subjectTask?.cancel()
        subjectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let subject = (try? await context.source?.pullRequestSubject(remote: mine.name, branch: branch)) ?? ""
            guard !Task.isCancelled, titleField.stringValue == previousTitle else { return }
            titleField.stringValue = subject; previousTitle = subject
        }
    }

    @objc private func create() {
        guard foreign.indices.contains(targetRepository.indexOfSelectedItem) else { return }
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { HostingMessages.error("You must specify a title."); return }
        let target = foreign[targetRepository.indexOfSelectedItem]
        let head = login + ":" + yourBranch.stringValue, base = targetBranch.stringValue
        let description = body.string.trimmingCharacters(in: .whitespacesAndNewlines)
        createButton.isEnabled = false
        tasks.append(Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await context.client(target.identity).createPullRequest(head: head, base: base, title: title, body: description)
                HostingMessages.information("Done", "Pull request")
                close()
            } catch is CancellationError { }
            catch {
                createButton.isEnabled = true
                HostingMessages.error("Failed to create pull request.\n" + error.localizedDescription)
            }
        })
    }
}

@MainActor
final class ForkAndCloneWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTabViewDelegate, NSTextFieldDelegate, NSComboBoxDelegate {
    struct Environment {
        let creator: any RepositoryCreating
        let addRemote: (URL, String, String) async throws -> Void
        let opened: (URL) -> Void
        var client: @MainActor () throws -> RepositoryHostClient = {
            RepositoryHostClient(identity: HostedRepositoryIdentity.parse("https://github.com/api/api")!, token: GitHubRepositoryPlugin.token)
        }
        var initialDestination: String = ""
    }
    private enum CloneProtocol: String, CaseIterable { case ssh = "Ssh", https = "Https" }
    private let environment: Environment
    private let tabs = NSTabView()
    private let myRepositoriesTable = NSTableView()
    private let searchTable = NSTableView()
    private let helpText = NSTextField(wrappingLabelWithString: "If you want to fork a repository owned by somebody else, go to the Search for repositories tab.")
    private let search = NSTextField(string: "")
    private let searchButton = NSButton(title: "Search", target: nil, action: nil)
    private let userButton = NSButton(title: "Get from user", target: nil, action: nil)
    private let forkButton = NSButton(title: "Fork!", target: nil, action: nil)
    private let descriptionText = NSTextField(wrappingLabelWithString: "")
    private let destination = NSTextField(string: "")
    private let createDirectory = NSTextField(string: "")
    private let depth = NSTextField(string: "0")
    private let protocolChoice = NSPopUpButton()
    private let protocolLabel = label("Protocol:")
    private let upstreamRemote = NSComboBox()
    private let cloneInfo = NSTextField(wrappingLabelWithString: "")
    private let cloneButton = NSButton(title: "Clone", target: nil, action: nil)
    private var myRepositories: [HostedRepositoryDetails] = []
    private var searchResults: [HostedRepositoryDetails] = []
    private var myLoading = false, searching = false
    private var parentOwners: [String: String?] = [:]
    private var parentURLs: [String: (https: String, ssh: String)] = [:]
    private var tasks: [Task<Void, Never>] = []

    init(environment: Environment, hostName: String = "GitHub") {
        self.environment = environment
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 744, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(hostName): Remote repository fork and clone"; window.minSize = NSSize(width: 640, height: 520); window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self; window.setFrameAutosaveName("RepositoryHosting.ForkClone")
        configure(myRepositoriesTable, [("name", "Name", 220), ("fork", "Is fork", 60), ("forks", "# Forks", 60), ("private", "Private", 60)], owner: self)
        configure(searchTable, [("name", "Name", 220), ("owner", "Owner", 140), ("fork", "Is fork", 60), ("forks", "# Forks", 60)], owner: self)
        let myPage = NSStackView(views: [scrolled(myRepositoriesTable), helpText]); myPage.alignment = .top
        helpText.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let myItem = NSTabViewItem(identifier: "mine"); myItem.label = "My repositories"; myItem.view = myPage
        for (button, action) in [(searchButton, #selector(find)), (userButton, #selector(user)), (forkButton, #selector(fork))] {
            button.target = self; button.action = action
        }
        search.delegate = self
        let queries = NSStackView(views: [search, searchButton, label("or"), userButton, NSView(), forkButton])
        let open = NSButton(title: "Open github page", target: self, action: #selector(openHomepage))
        let details = NSStackView(views: [label("Description:"), descriptionText, NSView(), open]); details.orientation = .vertical; details.alignment = .leading
        details.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let results = NSStackView(views: [scrolled(searchTable), details]); results.alignment = .top
        let searchPage = NSStackView(views: [queries, results]); searchPage.orientation = .vertical; searchPage.alignment = .width
        let searchItem = NSTabViewItem(identifier: "search"); searchItem.label = "Search for repositories"; searchItem.view = searchPage
        tabs.addTabViewItem(myItem); tabs.addTabViewItem(searchItem); tabs.delegate = self

        let browse = NSButton(title: "…", target: self, action: #selector(browseDestination))
        protocolChoice.addItems(withTitles: CloneProtocol.allCases.map(\.rawValue))
        protocolChoice.target = self; protocolChoice.action = #selector(protocolChanged)
        for field in [destination, createDirectory, depth] { field.delegate = self }
        upstreamRemote.delegate = self
        let setup = NSGridView(views: [
            [label("Destination folder:"), NSStackView(views: [destination, browse]), protocolLabel, protocolChoice],
            [label("Create directory:"), createDirectory, NSGridCell.emptyContentView, NSGridCell.emptyContentView],
            [label("Add upstream remote as:"), upstreamRemote, NSGridCell.emptyContentView, NSGridCell.emptyContentView],
            [label("Limit Depth:"), depth, NSGridCell.emptyContentView, NSGridCell.emptyContentView]])
        depth.widthAnchor.constraint(equalToConstant: 100).isActive = true
        let setupStack = NSStackView(views: [setup, cloneInfo]); setupStack.orientation = .vertical; setupStack.alignment = .leading
        setupStack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 8, right: 8)
        let group = NSBox(); group.title = "Clone"; group.contentView = setupStack
        cloneButton.target = self; cloneButton.action = #selector(startClone)
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeWindow)); closeButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cloneButton, closeButton])
        let root = NSStackView(views: [tabs, group, buttons]); root.orientation = .vertical; root.alignment = .trailing
        tabs.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        group.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        constrain(root, in: window)
        destination.stringValue = environment.initialDestination
        forkButton.isEnabled = false
        updateCloneInfo()
        updateMyRepositories()
    }
    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) { tasks.forEach { $0.cancel() } }
    @objc private func closeWindow() { close() }

    private var isSearchPage: Bool { tabs.selectedTabViewItem?.identifier as? String == "search" }
    private var selected: HostedRepositoryDetails? {
        let (table, rows) = isSearchPage ? (searchTable, searchResults) : (myRepositoriesTable, myRepositories)
        return table.numberOfSelectedRows == 1 && rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil
    }
    private var https: Bool { protocolChoice.titleOfSelectedItem == CloneProtocol.https.rawValue }

    private func updateMyRepositories() {
        myRepositories = []; myLoading = true; myRepositoriesTable.reloadData()
        tasks.append(Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let repositories = try await environment.client().myRepositories()
                myRepositories = repositories.enumerated().sorted { ($0.element.name, $0.offset) < ($1.element.name, $1.offset) }.map(\.element)
            } catch is CancellationError { return }
            catch {
                helpText.stringValue = "Failed to get repositories. This most likely means you didn't configure GitHub, please do so via the menu \"Plugins/GitHub\"."
                    + "\n\nException: " + error.localizedDescription + "\n\n" + helpText.stringValue
            }
            myLoading = false; myRepositoriesTable.reloadData()
        })
    }

    private func runSearch(_ query: @escaping (RepositoryHostClient) async throws -> [HostedRepositoryDetails], failure: @escaping (Error) -> String) {
        searchResults = []; searching = true; searchTable.reloadData(); searchButton.isEnabled = false; updateSelection()
        tasks.append(Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let found = try await query(environment.client())
                searchResults = found.enumerated().sorted { ($0.element.name, $0.offset) < ($1.element.name, $1.offset) }.map(\.element)
            } catch is CancellationError { return }
            catch { HostingMessages.error(failure(error)) }
            searching = false; searchTable.reloadData(); searchButton.isEnabled = true
        })
    }
    @objc private func find() {
        let text = search.stringValue
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        runSearch({ try await $0.searchRepositories(text) }) { "Search failed!\n" + $0.localizedDescription }
    }
    @objc private func user() {
        let text = search.stringValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        runSearch({ try await $0.repositories(user: text) }) { error in
            error as? RepositoryHostError == .notFound ? "User not found!" : "Could not fetch repositories of user!\n" + error.localizedDescription
        }
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        if notification.object as? NSTextField === search,
           (notification.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.return.rawValue { find() }
    }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField !== search { updateCloneInfo(updateCreateDirectory: false) }
    }
    func comboBoxSelectionDidChange(_ notification: Notification) {
        if upstreamRemote.indexOfSelectedItem >= 0 { upstreamRemote.stringValue = upstreamRemote.itemObjectValue(at: upstreamRemote.indexOfSelectedItem) as? String ?? "" }
        updateCloneInfo(updateCreateDirectory: false)
    }

    @objc private func fork() {
        guard searchTable.numberOfSelectedRows == 1, searchResults.indices.contains(searchTable.selectedRow) else {
            HostingMessages.error("You must select exactly one item"); return
        }
        let repository = searchResults[searchTable.selectedRow]
        tasks.append(Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let identity = HostedRepositoryIdentity.parse(repository.clone_url.absoluteString) else { throw RepositoryHostError.unsupported }
                _ = try await environment.client().with(identity).fork()
            } catch is CancellationError { return }
            catch { HostingMessages.error("Failed to fork:\n" + error.localizedDescription) }
            tabs.selectTabViewItem(at: 0)
            updateMyRepositories()
        })
    }

    @objc private func openHomepage() {
        guard let repository = selected else { return }
        guard let homepage = repository.homepage, homepage.hasPrefix("http://") || homepage.hasPrefix("https://"), let url = URL(string: homepage) else {
            HostingMessages.error("No homepage defined"); return
        }
        NSWorkspace.shared.open(url)
    }
    @objc private func browseDestination() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        if !destination.stringValue.isEmpty { panel.directoryURL = URL(fileURLWithPath: destination.stringValue, isDirectory: true) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destination.stringValue = url.path
        updateCloneInfo(updateCreateDirectory: false)
    }
    @objc private func protocolChanged() { updateCloneInfo(updateCreateDirectory: false) }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        updateCloneInfo()
        if isSearchPage { window?.makeFirstResponder(search) }
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }
    private func updateSelection() {
        updateCloneInfo()
        forkButton.isEnabled = searchTable.numberOfSelectedRows == 1 && searchResults.indices.contains(searchTable.selectedRow)
        descriptionText.stringValue = forkButton.isEnabled ? searchResults[searchTable.selectedRow].description ?? "" : descriptionText.stringValue
    }

    private func loadParent(_ repository: HostedRepositoryDetails) {
        guard repository.fork, parentOwners[repository.full_name] == nil else { return }
        if let parent = repository.parent {
            parentOwners[repository.full_name] = parent.owner.login
            parentURLs[repository.full_name] = (parent.clone_url.absoluteString, parent.ssh_url)
            return
        }
        tasks.append(Task { @MainActor [weak self] in
            guard let self, let identity = HostedRepositoryIdentity.parse(repository.clone_url.absoluteString),
                  let details = try? await environment.client().with(identity).repository() else { return }
            parentOwners[repository.full_name] = details.parent?.owner.login
            if let parent = details.parent { parentURLs[repository.full_name] = (parent.clone_url.absoluteString, parent.ssh_url) }
            if selected?.full_name == repository.full_name { updateCloneInfo() }
        })
    }

    private func updateCloneInfo(updateCreateDirectory: Bool = true) {
        guard let repository = selected else {
            protocolLabel.isHidden = true; protocolChoice.isHidden = true
            cloneButton.isEnabled = false; cloneInfo.stringValue = ""; createDirectory.stringValue = ""
            return
        }
        protocolLabel.isHidden = false; protocolChoice.isHidden = false
        if updateCreateDirectory {
            createDirectory.stringValue = repository.name
            upstreamRemote.stringValue = ""; upstreamRemote.removeAllItems()
            loadParent(repository)
            if let owner = parentOwners[repository.full_name] ?? nil {
                upstreamRemote.addItems(withObjectValues: [owner, "upstream"])
                upstreamRemote.stringValue = owner
            }
            upstreamRemote.isEnabled = (parentOwners[repository.full_name] ?? nil) != nil
        }
        cloneButton.isEnabled = true
        let remote = upstreamRemote.stringValue.trimmingCharacters(in: .whitespaces)
        let moreInfo = remote.isEmpty ? "" : "\"\(remote)\" will be added as a remote."
        let target = targetDirectory?.path ?? ""
        cloneInfo.stringValue = isSearchPage
            ? "Will clone \(repository.cloneURL(https: https)) into \(target).\nYou can not push unless you are a collaborator. \(moreInfo)"
            : "Will clone \(repository.cloneURL(https: https)) into \(target).\nYou will have push access. \(moreInfo)"
    }

    private var targetDirectory: URL? {
        let base = destination.stringValue.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return nil }
        let root = URL(fileURLWithPath: (base as NSString).expandingTildeInPath, isDirectory: true)
        let directory = createDirectory.stringValue
        return directory.isEmpty ? root : root.appendingPathComponent(directory, isDirectory: true)
    }

    @objc private func startClone() {
        guard let repository = selected, let window else { return }
        guard let target = targetDirectory else { HostingMessages.error("Clone folder can not be empty"); return }
        let depthValue = Int(depth.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
        guard (0...999).contains(depthValue) else { HostingMessages.error("Limit Depth: enter a number from 0 to 999."); return }
        let request = RepositoryCloneRequest(source: repository.cloneURL(https: https), destinationParent: target.deletingLastPathComponent(),
                                             subdirectory: target.lastPathComponent, initializesSubmodules: false,
                                             depth: depthValue == 0 ? nil : depthValue)
        let remote = upstreamRemote.stringValue.trimmingCharacters(in: .whitespaces)
        let parent = parentURLs[repository.full_name].map { https ? $0.https : $0.ssh }
        let creator = environment.creator
        tasks.append(Task { @MainActor [weak self] in
            guard let self else { return }
            let succeeded = await HostingProcessDialog.run("Clone", window) { output in
                _ = try await creator.clone(request, output: output); return true
            }
            guard succeeded else { return }
            if !remote.isEmpty, let parent, !parent.isEmpty {
                do { try await environment.addRemote(request.destinationURL, remote, parent) }
                catch { HostingMessages.error(error.localizedDescription, "Could not add remote") }
            }
            environment.opened(request.destinationURL)
            close()
        })
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === myRepositoriesTable { return myLoading ? 1 : myRepositories.count }
        return searching ? 1 : searchResults.count
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let column = tableColumn?.identifier.rawValue
        let isMine = tableView === myRepositoriesTable
        if (isMine && myLoading) || (!isMine && searching) {
            return label(column == "name" ? (isMine ? " : LOADING : " : " : SEARCHING : ") : "")
        }
        let repository = isMine ? myRepositories[row] : searchResults[row]
        switch column {
        case "name": return label(repository.name)
        case "owner": return label(repository.owner.login)
        case "fork": return label(repository.fork ? "Yes" : "No")
        case "forks": return label(String(repository.forks_count ?? 0))
        default: return label(repository.private ? "Yes" : "No")
        }
    }
}
