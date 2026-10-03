import AppKit
import GitCommands
import GitExtensionsCore

public enum GitExtensionPluginSettingsScope: String {
    case effective, local, distributed, global
}

public enum GitExtensionPluginWorkflow {
    case commit, checkoutBranch, pull, push, fetch, merge, stashes, settings
    case remoteManagement, reflog, worktrees, submodules, clean, bisect, repositoryHosting
    case openRepository(URL)
}

public enum GitExtensionPluginSettingKind {
    case text, password, boolean, path
    case number(minimum: Int, maximum: Int)
    case decimal(minimum: Double, maximum: Double)
    case choice([String])
    case information
}

public struct GitExtensionPluginSetting {
    public let name: String
    public let caption: String
    public let defaultValue: String
    public let kind: GitExtensionPluginSettingKind
    public init(name: String, caption: String, defaultValue: String = "", kind: GitExtensionPluginSettingKind = .text) {
        self.name = name; self.caption = caption; self.defaultValue = defaultValue; self.kind = kind
    }
    func validate(_ value: String) throws {
        switch kind {
        case .number(let minimum, let maximum):
            guard minimum <= maximum, let number = Int(value), number >= minimum, number <= maximum else {
                throw PluginError.invalid("\(caption): enter a number from \(minimum) to \(maximum).")
            }
        case .decimal(let minimum, let maximum):
            guard minimum <= maximum, let number = Double(value), number.isFinite, number >= minimum, number <= maximum else {
                throw PluginError.invalid("\(caption): enter a number from \(minimum) to \(maximum).")
            }
        case .choice(let values):
            guard values.contains(value) else { throw PluginError.invalid("\(caption): choose a listed value.") }
        default: break
        }
    }
    static func textValue(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value == "<empty string>" ? "" : value
    }
}

@MainActor
public protocol GitExtensionPlugin: AnyObject {
    init()
    var identifier: UUID { get }
    var name: String { get }
    var pluginDescription: String { get }
    var icon: NSImage? { get }
    var requiresRepository: Bool { get }
    var settings: [GitExtensionPluginSetting] { get }
    func register(with host: GitExtensionPluginHost) throws
    func unregister(from host: GitExtensionPluginHost)
    func execute(in host: GitExtensionPluginHost) async throws -> Bool
    func settingsController(in host: GitExtensionPluginHost) throws -> NSViewController?
}

public extension GitExtensionPlugin {
    var icon: NSImage? { nil }
    var requiresRepository: Bool { true }
    var settings: [GitExtensionPluginSetting] { [] }
    func register(with host: GitExtensionPluginHost) throws {}
    func unregister(from host: GitExtensionPluginHost) {}
    func settingsController(in host: GitExtensionPluginHost) throws -> NSViewController? {
        settings.isEmpty ? nil : PluginSettingsViewController(settings: settings, host: host)
    }
}

@MainActor
public final class GitExtensionPluginHost {
    public private(set) var context: [String: [String]] = [:]
    public private(set) var selectedRevisions: [RevisionID] = []
    public var repositoryURL: URL? { context["WorkingDir"]?.first.map { URL(fileURLWithPath: $0, isDirectory: true) } }
    public weak var owner: NSWindow?
    var builtInRepository: (any RepositoryBuiltInPluginDataSource)?
    var builtInSettings: (any RepositorySettingsDataSource)?
    private let refresh: () -> Void
    private let navigate: (String) async throws -> Void
    private let readSetting: (String, GitExtensionPluginSettingsScope) throws -> String?
    private let writeSetting: (String, String?, GitExtensionPluginSettingsScope) throws -> Void
    private let executeCommand: ([String], Bool, Bool, Data?) async throws -> (Int32, Data, Data)
    private let settingsChanged: () -> Void
    private let launchWorkflow: (GitExtensionPluginWorkflow) throws -> Void
    private var handlers: [(UUID, String, (Bool?) throws -> Bool)] = []

    init(refresh: @escaping () -> Void, navigate: @escaping (String) async throws -> Void,
         readSetting: @escaping (String, GitExtensionPluginSettingsScope) throws -> String?,
         writeSetting: @escaping (String, String?, GitExtensionPluginSettingsScope) throws -> Void,
         settingsChanged: @escaping () -> Void = {},
         launchWorkflow: @escaping (GitExtensionPluginWorkflow) throws -> Void = { _ in
             throw PluginError.invalid("This workflow is unavailable in the current plugin context.")
         },
         executeCommand: @escaping ([String], Bool, Bool, Data?) async throws -> (Int32, Data, Data) = { _, _, _, _ in
             throw PluginError.invalid("Repository command execution is unavailable.")
         }) {
        self.refresh = refresh; self.navigate = navigate
        self.readSetting = readSetting; self.writeSetting = writeSetting
        self.executeCommand = executeCommand
        self.settingsChanged = settingsChanged
        self.launchWorkflow = launchWorkflow
    }
    func update(context: [String: [String]], owner: NSWindow?) {
        self.context = context; self.owner = owner
    }
    func updateSelection(_ revisions: [RevisionID]) { selectedRevisions = revisions }
    public func requestRepositoryRefresh() { refresh() }
    public func selectRevision(_ expression: String) async throws { try await navigate(expression) }
    public func setting(_ name: String, scope: GitExtensionPluginSettingsScope = .effective) throws -> String? {
        try readSetting(name, scope)
    }
    public func setSetting(_ name: String, value: String?, scope: GitExtensionPluginSettingsScope = .effective) throws {
        try writeSetting(name, value, scope)
    }
    public func settingsDidChange() { settingsChanged() }
    public func addCommitTemplate(_ name: String, text: @escaping () -> String, icon: NSImage? = nil, isRegex: Bool = false) {
        CommitTemplateRegistry.register(name, text: text, icon: icon, isRegex: isRegex)
    }
    public func removeCommitTemplate(_ name: String) { CommitTemplateRegistry.unregister(name) }
    public func start(_ workflow: GitExtensionPluginWorkflow) throws { try launchWorkflow(workflow) }
    public func runGit(arguments: [String], accessesRemote: Bool, mayChangeRepository: Bool,
                       standardInput: Data? = nil) async throws -> (exitStatus: Int32, stdout: Data, stderr: Data) {
        try await executeCommand(arguments, accessesRemote, mayChangeRepository, standardInput)
    }
    @discardableResult
    public func observe(_ event: String, handler: @escaping (Bool?) throws -> Bool) -> UUID {
        let id = UUID(); handlers.append((id, event, handler)); return id
    }
    public func removeObserver(_ id: UUID) { handlers.removeAll { $0.0 == id } }
    func removeAllObservers() { handlers.removeAll() }
    func dispatch(_ event: String, succeeded: Bool? = nil) throws -> Bool {
        for entry in handlers where entry.1 == event {
            if try !entry.2(succeeded) { return false }
        }
        return true
    }
}

@MainActor
final class ApplicationPluginSession {
    private(set) var registered: [(any GitExtensionPlugin, GitExtensionPluginHost)] = []
    private(set) var failures: [String] = []
    func register(_ plugin: any GitExtensionPlugin, host: GitExtensionPluginHost) {
        guard !registered.contains(where: { $0.0.identifier == plugin.identifier }) else { return }
        do {
            try plugin.register(with: host)
            registered.append((plugin, host))
        } catch {
            plugin.unregister(from: host)
            host.removeAllObservers()
            failures.append("\(plugin.name): \(error.localizedDescription)")
        }
    }
    func close() {
        for (plugin, host) in registered.reversed() {
            plugin.unregister(from: host)
            host.removeAllObservers()
        }
        registered.removeAll()
    }
    func dispatch(_ event: String, succeeded: Bool? = nil) -> Bool {
        var allowed = true
        for (plugin, host) in registered {
            do { if try !host.dispatch(event, succeeded: succeeded) { allowed = false } }
            catch { failures.append("\(plugin.name): \(error.localizedDescription)"); allowed = false }
        }
        return allowed
    }
}

@MainActor
final class ApplicationPluginRegistry {
    static func scriptPluginName(_ command: String) -> String? {
        if command.hasPrefix("plugin:") { return String(command.dropFirst(7)) }
        if command.lowercased().hasPrefix("{plugin"), command.hasSuffix("}"), command.count > 9 {
            let separator = command[command.index(command.startIndex, offsetBy: 7)]
            if [".", ":", "="].contains(String(separator)) { return String(command.dropFirst(8).dropLast()) }
        }
        return nil
    }
    struct Entry {
        let plugin: any GitExtensionPlugin
        let bundle: Bundle?
    }
    private(set) var entries: [Entry] = []
    private(set) var failures: [String] = []
    private var loaded = false

    static var userDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GitExtensionsMac/Plugins", isDirectory: true)
    }

    static func candidates(in directories: [URL]) throws -> [URL] {
        var result: [URL] = []
        var seen: Set<String> = []
        for root in directories where FileManager.default.fileExists(atPath: root.path) {
            let children = try FileManager.default.contentsOfDirectory(at: root,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            var files = children
            for child in children where child.pathExtension != "bundle" {
                if try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                    files += try FileManager.default.contentsOfDirectory(at: child,
                        includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                }
            }
            for file in files.sorted(by: { $0.path < $1.path })
                where file.pathExtension == "bundle" && file.lastPathComponent.hasPrefix("GitExtensions.") {
                if seen.insert(file.resolvingSymlinksInPath().path).inserted { result.append(file) }
            }
        }
        return result
    }

    func load(directories: [URL]? = nil) {
        guard !loaded else { return }
        loaded = true
        if directories == nil {
            do { try add(GitHubRepositoryPlugin()) }
            catch { failures.append(error.localizedDescription) }
            for plugin in BuiltInPlugins.make() {
                do { try add(plugin) } catch { failures.append(error.localizedDescription) }
            }
        }
        let roots = directories ?? [Bundle.main.builtInPlugInsURL, Self.userDirectory].compactMap { $0 }
        for root in roots {
            do {
                for url in try Self.candidates(in: [root]) {
                    if directories == nil, root == Bundle.main.builtInPlugInsURL,
                       !url.lastPathComponent.hasPrefix("GitExtensions.Plugins.") { continue }
                    do {
                        guard let bundle = Bundle(url: url),
                              bundle.object(forInfoDictionaryKey: "GitExtensionsPluginAPIVersion") as? Int == 1 else {
                            throw PluginError.invalid("Unsupported or missing plugin API version: \(url.lastPathComponent)")
                        }
                        try bundle.loadAndReturnError()
                        guard let type = bundle.principalClass as? any GitExtensionPlugin.Type else {
                            throw PluginError.invalid("Principal class does not implement GitExtensionPlugin: \(url.lastPathComponent)")
                        }
                        try add(type.init(), bundle: bundle)
                    } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                }
            } catch { failures.append("\(root.path): \(error.localizedDescription)") }
        }
    }

    func add(_ plugin: any GitExtensionPlugin, bundle: Bundle? = nil) throws {
        guard !plugin.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !entries.contains(where: { $0.plugin.identifier == plugin.identifier }) else {
            throw PluginError.invalid("Empty plugin name or duplicate identifier: \(plugin.identifier)")
        }
        entries.append(Entry(plugin: plugin, bundle: bundle))
    }
}

@MainActor
enum CommitTemplateRegistry {
    struct Template {
        let name: String
        let text: () -> String
        let icon: NSImage?
        let isRegex: Bool
    }
    static let didChange = Notification.Name("GitExtensionsMac.CommitTemplateRegistry.didChange")
    private(set) static var templates: [Template] = []
    static func register(_ name: String, text: @escaping () -> String, icon: NSImage?, isRegex: Bool) {
        guard !templates.contains(where: { $0.name == name }) else { return }
        templates.append(Template(name: name, text: text, icon: icon, isRegex: isRegex))
        NotificationCenter.default.post(name: didChange, object: nil)
    }
    static func unregister(_ name: String) {
        guard templates.contains(where: { $0.name == name }) else { return }
        templates.removeAll { $0.name == name }
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

enum PluginError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): return message } }
}

@MainActor
final class PluginSelectionTarget: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func changed() { action() }
}

@MainActor
final class PluginSettingsViewController: NSViewController {
    let settings: [GitExtensionPluginSetting]
    let host: GitExtensionPluginHost
    let scope = NSPopUpButton()
    var fields: [(GitExtensionPluginSetting, NSControl)] = []
    let rows = NSStackView()
    let apply = NSButton(title: "Apply", target: nil, action: nil)
    let reset = NSButton(title: "Reset to inherited/default values", target: nil, action: nil)
    var clearing = false
    var loadedScope: GitExtensionPluginSettingsScope?
    var drafts: [GitExtensionPluginSettingsScope: [String: String?]] = [:]
    var resetScopes: Set<GitExtensionPluginSettingsScope> = []
    init(settings: [GitExtensionPluginSetting], host: GitExtensionPluginHost) {
        self.settings = settings; self.host = host
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        view = root
        root.frame = NSRect(x: 0, y: 0, width: 560, height: max(280, settings.count * 36 + 160))
        root.widthAnchor.constraint(greaterThanOrEqualToConstant: 540).isActive = true
        scope.addItems(withTitles: host.context["WorkingDir"] == nil
            ? ["global"] : ["effective", "local", "distributed", "global"])
        for item in scope.itemArray { item.representedObject = item.title }
        scope.target = self; scope.action = #selector(reload)
        root.addArrangedSubview(NSTextField(labelWithString: "Settings source:")); root.addArrangedSubview(scope)
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 8
        root.addArrangedSubview(rows)
        rows.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true
        reset.target = self; reset.action = #selector(resetValues); root.addArrangedSubview(reset)
        apply.target = self; apply.action = #selector(save)
        let ok = NSButton(title: "OK", target: self, action: #selector(accept)); ok.keyEquivalent = "\r"
        let close = NSButton(title: "Cancel", target: self, action: #selector(closeWindow)); close.keyEquivalent = "\u{1b}"
        let discard = NSButton(title: "Discard", target: self, action: #selector(discardChanges))
        let buttons = NSStackView(views: [ok, close, discard, apply]); root.addArrangedSubview(buttons)
        reload()
    }
    private var currentScope: GitExtensionPluginSettingsScope {
        .init(rawValue: scope.selectedItem?.representedObject as? String ?? "global") ?? .global
    }
    private func capture() {
        guard let loadedScope else { return }
        var values: [String: String?] = [:]
        for (setting, control) in fields {
            let value: String?
            if clearing { value = nil }
            else if let choices = control as? NSPopUpButton { value = choices.selectedItem?.representedObject as? String }
            else if let button = control as? NSButton { value = button.state == .mixed ? nil : button.state == .on ? "true" : "false" }
            else { value = GitExtensionPluginSetting.textValue(control.stringValue) }
            values.updateValue(value, forKey: setting.name)
        }
        drafts[loadedScope] = values
    }
    @objc private func reload() {
        capture()
        loadedScope = currentScope
        clearing = resetScopes.contains(currentScope)
        for row in rows.arrangedSubviews { rows.removeArrangedSubview(row); row.removeFromSuperview() }
        fields.removeAll()
        do {
            for setting in settings {
                let value: String?
                if let draft = drafts[currentScope]?[setting.name] { value = draft }
                else {
                    value = try host.setting(setting.name, scope: currentScope)
                        ?? (currentScope == .effective ? setting.defaultValue : nil)
                }
                let control: NSControl
                switch setting.kind {
                case .information:
                    rows.addArrangedSubview(NSTextField(wrappingLabelWithString: setting.caption)); continue
                case .boolean:
                    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
                    checkbox.allowsMixedState = true
                    checkbox.state = value == nil ? .mixed : value?.lowercased() == "true" ? .on : .off; control = checkbox
                case .choice(let values):
                    let choices = NSPopUpButton(); choices.addItem(withTitle: "Not set")
                    for item in values { choices.addItem(withTitle: item); choices.lastItem?.representedObject = item }
                    if let value, let index = values.firstIndex(of: value) { choices.selectItem(at: index + 1) }
                    control = choices
                case .password: control = NSSecureTextField(string: value == "" ? "<empty string>" : value ?? "")
                default: control = NSTextField(string: value == "" ? "<empty string>" : value ?? "")
                }
                (control as? NSTextField)?.placeholderString = "Not set; <empty string> stores empty text"
                control.isEnabled = !clearing
                control.widthAnchor.constraint(equalToConstant: 300).isActive = true
                let label = NSTextField(wrappingLabelWithString: setting.caption)
                label.widthAnchor.constraint(equalToConstant: 180).isActive = true
                rows.addArrangedSubview(NSStackView(views: [label, control]))
                fields.append((setting, control))
            }
            apply.isEnabled = true; reset.isEnabled = true
        } catch { apply.isEnabled = false; NSAlert(error: error).runModal() }
    }
    @objc private func resetValues() {
        clearing = true; resetScopes.insert(currentScope); fields.forEach { $0.1.isEnabled = false }
    }
    @objc private func save() { _ = applyValues() }
    @objc private func accept() { if applyValues() { closeWindow() } }
    @objc private func discardChanges() {
        drafts.removeAll(); resetScopes.removeAll(); loadedScope = nil; reload()
    }
    private func applyValues() -> Bool {
        capture()
        do {
            for edits in drafts.values {
                for (name, value) in edits {
                    if let value, let setting = settings.first(where: { $0.name == name }) { try setting.validate(value) }
                }
            }
            for scope in [GitExtensionPluginSettingsScope.global, .distributed, .local, .effective] {
                for (name, value) in drafts[scope] ?? [:] {
                    if scope == .effective, let setting = settings.first(where: { $0.name == name }),
                       try (host.setting(name) ?? setting.defaultValue) == value { continue }
                    try host.setSetting(name, value: value, scope: scope)
                }
            }
            host.settingsDidChange(); discardChanges(); return true
        } catch { NSAlert(error: error).runModal(); return false }
    }
    @objc private func closeWindow() { view.window?.close() }
}

@MainActor
struct ApplicationPluginSettings {
    let identifier: UUID
    let legacyName: String
    let locations: DistributedSettings?
    let defaults: UserDefaults
    private var key: String { "GitExtensionsMac.plugins.settings.v1" }
    private var prefix: String {
        identifier == UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
            ? legacyName : identifier.uuidString.lowercased() + "."
    }
    private func globalValues() throws -> [String: String] {
        guard let value = defaults.object(forKey: key) else { return [:] }
        guard let values = value as? [String: String] else {
            throw PluginError.invalid("Stored plugin settings are malformed; the existing data has been preserved.")
        }
        return values
    }
    func value(_ name: String, scope: DistributedSettingsScope = .effective) throws -> String? {
        let global = try globalValues()
        if (scope == .local || scope == .distributed) && locations == nil {
            throw PluginError.invalid("No repository settings context is available.")
        }
        let effective = try locations?.values(scope, global: global) ?? global
        return effective[prefix + name] ?? effective[legacyName + name]
    }
    func set(_ name: String, value: String?, scope: DistributedSettingsScope = .global) throws {
        switch scope {
        case .global:
            var global = try globalValues()
            global[prefix + name] = value
            defaults.set(global, forKey: key)
        case .local, .distributed:
            guard let locations else { throw PluginError.invalid("No repository settings context is available.") }
            try DistributedSettings.write([prefix + name: value],
                to: scope == .local ? locations.localURL : locations.distributedURL)
        case .effective:
            guard try self.value(name) != value else { return }
            if let locations {
                let local = try DistributedSettings.read(locations.localURL)
                let distributed = try DistributedSettings.read(locations.distributedURL)
                if local[prefix + name] != nil || distributed[prefix + name] != nil {
                    try set(name, value: value, scope: .local)
                    return
                }
            }
            try set(name, value: value, scope: .global)
        }
    }
}
