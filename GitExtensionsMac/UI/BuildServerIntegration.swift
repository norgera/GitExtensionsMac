import AppKit
import GitCommands
import GitExtensionsCore

@MainActor
struct BuildServerSettingsStore {
    static let globalKey = "GitExtensionsMac.buildServer.settings.v1"
    let locations: DistributedSettings?
    var defaults: UserDefaults = .standard

    func globalValues() -> [String: String] { defaults.dictionary(forKey: Self.globalKey) as? [String: String] ?? [:] }
    func values(_ scope: DistributedSettingsScope) throws -> [String: String] {
        let buildKeys = { (values: [String: String]) in values.filter { $0.key.hasPrefix("BuildServer.") } }
        guard let locations else { return scope == .effective || scope == .global ? globalValues() : [:] }
        return buildKeys(try locations.values(scope, global: globalValues()))
    }
    @discardableResult
    func write(_ edits: [String: String?], scope: DistributedSettingsScope) throws -> Bool {
        switch scope {
        case .global:
            var values = globalValues()
            for (key, value) in edits { values[key] = value }
            guard values != globalValues() else { return false }
            defaults.set(values, forKey: Self.globalKey)
            return true
        case .local, .distributed:
            guard let locations else { return false }
            return try DistributedSettings.write(edits, to: scope == .local ? locations.localURL : locations.distributedURL)
        case .effective: return false
        }
    }
    static func bool(_ value: String?) -> Bool? {
        switch value?.lowercased() { case "true": true; case "false": false; default: nil }
    }
    static func tokenAccount(_ type: BuildServerType, key: String) -> String { type.rawValue + "|" + key }
    static func gitHubTokenKey(apiURL: String?, owner: String?, repository: String?) -> String {
        var api = apiURL?.isEmpty == false ? apiURL! : GitHubActionsBuildAdapter.defaultApiURL
        while api.hasSuffix("/") { api.removeLast() }
        return tokenAccount(.gitHubActions, key: "\(api)/\(owner ?? "")/\(repository ?? "")".lowercased())
    }
    static func azureTokenKey(projectURL: String) -> String { tokenAccount(.azureDevOps, key: projectURL.lowercased()) }
    static func token(_ account: String) -> String? {
        let value = try? RepositoryHostCredentials.token(for: account, service: RepositoryHostCredentials.buildServerService)
        return value?.isEmpty == false ? value : nil
    }
}

@MainActor
enum BuildServerAdapterResolver {
    struct Resolution {
        let adapter: (any BuildServerAdapter)?
        let explicitlyEnabled: Bool
    }
    static func resolve(settings: [String: String], remotes: [RepositoryRemoteConfiguration], currentRemote: String?,
                        credential: @escaping (URL) async -> String?, transport: @escaping HostTransport = HostHTTP.send,
                        token: (String) -> String? = BuildServerSettingsStore.token) async -> Resolution {
        let enabled = BuildServerSettingsStore.bool(settings[BuildServerSettingKeys.enabled])
        let urls = BuildServerAutoDetector.orderedRemoteURLs(remotes)
        var typeName = settings[BuildServerSettingKeys.type] ?? ""
        if !typeName.isEmpty {
            if enabled == false { return .init(adapter: nil, explicitlyEnabled: false) }
        } else {
            guard enabled == nil, let detected = BuildServerAutoDetector.detect(urls) else {
                return .init(adapter: nil, explicitlyEnabled: enabled == true)
            }
            typeName = detected.0.rawValue
        }
        guard let type = BuildServerType(rawValue: typeName) else { return .init(adapter: nil, explicitlyEnabled: enabled == true) }
        var adapterSettings: [String: String] = [:]
        let prefix = "BuildServer.\(typeName)."
        for (key, value) in settings where key.hasPrefix(prefix) { adapterSettings[String(key.dropFirst(prefix.count))] = value }
        for (key, value) in BuildServerAutoDetector.detect(urls, only: type)?.1 ?? [:]
            where adapterSettings[key]?.trimmingCharacters(in: .whitespaces).isEmpty ?? true { adapterSettings[key] = value }
        let adapter: (any BuildServerAdapter)?
        switch type {
        case .gitHubActions:
            let api = adapterSettings[BuildServerSettingKeys.gitHubApiURL]
            let owner = adapterSettings[BuildServerSettingKeys.gitHubOwner], repository = adapterSettings[BuildServerSettingKeys.gitHubRepository]
            adapter = GitHubActionsBuildAdapter(apiURL: api, owner: owner, repository: repository,
                token: token(BuildServerSettingsStore.gitHubTokenKey(apiURL: api, owner: owner, repository: repository)), transport: transport)
        case .azureDevOps:
            let configured = AzureDevOpsBuildAdapter.Settings(projectURL: adapterSettings[BuildServerSettingKeys.azureProjectURL] ?? "",
                buildDefinitionFilter: adapterSettings[BuildServerSettingKeys.azureDefinitionFilter] ?? "",
                repositoryName: adapterSettings[BuildServerSettingKeys.azureRepositoryName] ?? "")
            let remoteURL = remotes.first { $0.name == currentRemote && !$0.isDisabled }?.fetchURL ?? remotes.first { !$0.isDisabled }?.fetchURL
            let projectURL = replaceBuildServerVariables(configured.projectURL, remoteURL: remoteURL)
            let pat = token(BuildServerSettingsStore.azureTokenKey(projectURL: configured.projectURL))
            var password: String?
            if pat == nil, let url = URL(string: projectURL) { password = await credential(url) }
            adapter = try? AzureDevOpsBuildAdapter(settings: configured, projectURL: projectURL, pat: pat, credentialPassword: password, transport: transport)
        }
        return .init(adapter: adapter, explicitlyEnabled: enabled == true)
    }
}

@MainActor
final class BuildServerWatcher {
    var onUpdate: ([BuildInfo]) -> Void = { _ in }
    var onInitializationError: (BuildServerError) -> Void = { _ in }
    var shortInterval: Duration = .seconds(10)
    var longInterval: Duration = .seconds(120)
    private var tasks: [Task<Void, Never>] = []
    private(set) var adapter: (any BuildServerAdapter)?
    private var anyRunning = false
    private var lookForNewlyFinished = false

    func launch(_ adapter: (any BuildServerAdapter)?, now: Date = Date()) {
        cancel()
        self.adapter = adapter
        guard let adapter else { return }
        anyRunning = false; lookForNewlyFinished = false
        tasks.append(Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let builds = await self.query { try await adapter.runningBuilds() }
                if !builds.isEmpty { anyRunning = true; lookForNewlyFinished = true }
                if Task.isCancelled { return }
                if !builds.isEmpty { onUpdate(builds) }
                let delay = anyRunning ? shortInterval : longInterval
                anyRunning = false
                try? await Task.sleep(for: delay)
            }
        })
        let threeDaysAgo = Calendar.current.date(byAdding: .day, value: -3, to: Calendar.current.startOfDay(for: now)) ?? now
        tasks.append(Task { @MainActor [weak self] in
            for since in [Optional(threeDaysAgo), nil] {
                guard let self, !Task.isCancelled else { return }
                let builds = await self.query { try await adapter.finishedBuilds(since: since) }
                if !builds.isEmpty, !Task.isCancelled { onUpdate(builds) }
            }
            let frozen = now
            while !Task.isCancelled {
                guard let delay = self?.longInterval else { return }
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled else { return }
                guard lookForNewlyFinished else { continue }
                let builds = await self.query { try await adapter.finishedBuilds(since: frozen) }
                lookForNewlyFinished = false
                if !builds.isEmpty, !Task.isCancelled { onUpdate(builds) }
            }
        })
    }
    private func query(_ operation: @escaping () async throws -> [BuildInfo]) async -> [BuildInfo] {
        do { return try await operation() }
        catch let error as BuildServerError {
            if case .initialization(let message, _, _) = error, !Task.isCancelled {
                onUpdate([BuildInfo(status: .failure, description: message, revisions: [.workingDirectory])])
                onInitializationError(error)
            }
            return []
        } catch { return [] }
    }
    func cancel() { tasks.forEach { $0.cancel() }; tasks = [] }
    func repositoryChanged() { if let adapter { Task { await adapter.repositoryChanged() } } }
}

@MainActor
enum BuildServerErrorPresenter {
    private static var shownKey: String?
    static func present(_ error: BuildServerError, window: NSWindow?, openSettings: @escaping () -> Void) {
        guard case .initialization(let message, let badToken, let key) = error, shownKey != key else { return }
        shownKey = key
        let alert = NSAlert()
        alert.messageText = "Azure DevOps error"
        alert.informativeText = message
        alert.alertStyle = .critical
        if badToken { alert.addButton(withTitle: "Open settings"); alert.addButton(withTitle: "Ignore") }
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            if badToken, response == .alertFirstButtonReturn { shownKey = nil; openSettings() }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }
}

@MainActor
final class BuildServerSettingsPageController: NSViewController, NSTextFieldDelegate {
    private let store: BuildServerSettingsStore
    private let remoteURLs: [String]
    private let workingDirectoryName: String?
    private var scope: DistributedSettingsScope = .effective
    private var edits: [DistributedSettingsScope: [String: String?]] = [:]
    private var tokenEdits: [String: String] = [:]
    private let stack = NSStackView()
    private let scopePopup = NSPopUpButton()
    private let enabled = NSButton(checkboxWithTitle: "Enable build server integration", target: nil, action: nil)
    private let showPage = NSButton(checkboxWithTitle: "Show build result page", target: nil, action: nil)
    private let typePopup = NSPopUpButton()
    private let adapterPanel = NSStackView()
    private var adapterFields: [String: NSTextField] = [:]
    private var tokenField: NSSecureTextField?
    private let regexError = NSTextField(labelWithString: "The 'Build definition name' regular expression is not valid and won't be saved!")
    private var tokenManagement: NSButton?

    init(store: BuildServerSettingsStore, remoteURLs: [String], workingDirectoryName: String?) {
        self.store = store; self.remoteURLs = remoteURLs; self.workingDirectoryName = workingDirectoryName
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        view = stack
        let scopes = store.locations == nil ? [DistributedSettingsScope.global] : DistributedSettingsScope.allCases
        if store.locations == nil { scope = .global }
        for item in scopes {
            scopePopup.addItem(withTitle: item.title)
            scopePopup.lastItem?.representedObject = item
        }
        scopePopup.selectItem(withTitle: scope.title)
        scopePopup.target = self; scopePopup.action = #selector(scopeChanged)
        stack.addArrangedSubview(NSStackView(views: [NSTextField(labelWithString: "Settings source:"), scopePopup]))
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString: "Git Extensions can integrate with build servers to supply per-commit Continuous Integration information."))
        for button in [enabled, showPage] { button.allowsMixedState = true; button.target = self; button.action = #selector(controlsChanged) }
        typePopup.addItems(withTitles: ["None"] + BuildServerType.allCases.map(\.rawValue))
        typePopup.target = self; typePopup.action = #selector(typeChanged)
        stack.addArrangedSubview(enabled)
        stack.addArrangedSubview(NSStackView(views: [NSTextField(labelWithString: "Build server type"), typePopup]))
        stack.addArrangedSubview(showPage)
        adapterPanel.orientation = .vertical; adapterPanel.alignment = .leading; adapterPanel.spacing = 6
        stack.addArrangedSubview(adapterPanel)
        regexError.textColor = .systemRed
        reload()
    }

    private func current() throws -> [String: String] {
        if scope == .effective {
            var values: [String: String] = [:]
            for layer in [DistributedSettingsScope.global, .distributed, .local] {
                var layerValues = try store.values(layer)
                for (key, value) in edits[layer] ?? [:] { layerValues[key] = value }
                values.merge(layerValues, uniquingKeysWith: { _, new in new })
            }
            return values
        }
        var values = try store.values(scope)
        for (key, value) in edits[scope] ?? [:] { values[key] = value }
        return values
    }
    private func setTristate(_ button: NSButton, _ value: String?) {
        button.state = BuildServerSettingsStore.bool(value).map { $0 ? .on : .off } ?? .mixed
    }
    private func reload() {
        guard let values = try? current() else { return }
        setTristate(enabled, values[BuildServerSettingKeys.enabled])
        setTristate(showPage, values[BuildServerSettingKeys.showBuildResultPage])
        let type = values[BuildServerSettingKeys.type] ?? ""
        typePopup.selectItem(withTitle: BuildServerType(rawValue: type) != nil ? type : "None")
        let editable = scope != .effective
        [enabled, showPage, typePopup].forEach { $0.isEnabled = editable }
        buildAdapterPanel(values)
    }
    private var selectedType: BuildServerType? { BuildServerType(rawValue: typePopup.titleOfSelectedItem ?? "") }
    private func field(_ key: String, _ caption: String, _ value: String, secure: Bool = false) -> NSTextField {
        let control: NSTextField = secure ? NSSecureTextField(string: value) : NSTextField(string: value)
        control.delegate = self; control.isEnabled = scope != .effective
        control.widthAnchor.constraint(equalToConstant: 380).isActive = true
        let caption = NSTextField(labelWithString: caption); caption.widthAnchor.constraint(equalToConstant: 200).isActive = true
        adapterPanel.addArrangedSubview(NSStackView(views: [caption, control]))
        adapterFields[key] = control
        return control
    }
    private func link(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false; button.contentTintColor = .linkColor
        adapterPanel.addArrangedSubview(button); return button
    }
    private func buildAdapterPanel(_ values: [String: String]) {
        adapterPanel.arrangedSubviews.forEach { adapterPanel.removeArrangedSubview($0); $0.removeFromSuperview() }
        adapterFields = [:]; tokenField = nil; tokenManagement = nil
        guard let type = selectedType, workingDirectoryName != nil || store.locations == nil else { return }
        func value(_ key: String) -> String? { values[BuildServerSettingKeys.adapter(type.rawValue, key)] }
        switch type {
        case .gitHubActions:
            let detected = BuildServerAutoDetector.detect(remoteURLs, only: .gitHubActions)?.1 ?? [:]
            let owner = value(BuildServerSettingKeys.gitHubOwner).flatMap { $0.isEmpty ? nil : $0 } ?? detected[BuildServerSettingKeys.gitHubOwner] ?? ""
            let repository = value(BuildServerSettingKeys.gitHubRepository).flatMap { $0.isEmpty ? nil : $0 } ?? detected[BuildServerSettingKeys.gitHubRepository] ?? ""
            let api = value(BuildServerSettingKeys.gitHubApiURL) ?? GitHubActionsBuildAdapter.defaultApiURL
            _ = field(BuildServerSettingKeys.gitHubApiURL, "API URL", api)
            _ = field(BuildServerSettingKeys.gitHubOwner, "Owner", owner)
            _ = field(BuildServerSettingKeys.gitHubRepository, "Repository", repository)
            tokenField = field("token", "API Token", "", secure: true) as? NSSecureTextField
            tokenField?.placeholderString = BuildServerSettingsStore.token(BuildServerSettingsStore.gitHubTokenKey(apiURL: api, owner: owner, repository: repository)) == nil
                ? "Not set" : "Stored in Keychain — enter a replacement"
            _ = link("Create a GitHub personal access token", #selector(openGitHubTokenPage))
        case .azureDevOps:
            var project = value(BuildServerSettingKeys.azureProjectURL) ?? ""
            if project.trimmingCharacters(in: .whitespaces).isEmpty { project = AzureDevOpsProjectURL.project(fromRemotes: remoteURLs) ?? "" }
            _ = field(BuildServerSettingKeys.azureProjectURL, "Project Url", project)
            adapterPanel.addArrangedSubview(NSTextField(wrappingLabelWithString: "Examples:\n - https://dev.azure.com/yourorganization/projectname/\n - https://yourhost:8080/tfs/collectionname/projectname/\n - https://yourorganization.visualstudio.com/projectname/"))
            _ = field(BuildServerSettingKeys.azureDefinitionFilter, "Build definition name\n(all existing if left empty)", value(BuildServerSettingKeys.azureDefinitionFilter) ?? "")
            adapterPanel.addArrangedSubview(NSTextField(labelWithString: "If needed, use the '*' wildcard or enter a Regular Expression"))
            adapterPanel.addArrangedSubview(regexError)
            tokenField = field("token", "Rest Api Token", "", secure: true) as? NSSecureTextField
            tokenField?.placeholderString = BuildServerSettingsStore.token(BuildServerSettingsStore.azureTokenKey(projectURL: project)) == nil
                ? "Not set — Git credential helper is used when available" : "Stored in Keychain — enter a replacement"
            adapterPanel.addArrangedSubview(NSTextField(wrappingLabelWithString: "You need to create a token with the following scopes:\n - 'Build (read)'\n - 'Project and team (read)'"))
            tokenManagement = link("Go to token management page", #selector(openAzureTokenPage))
            _ = link("Extract data from a build result url copied in the clipboard", #selector(extractFromClipboard))
            updateAzureView()
        }
    }
    private func updateAzureView() {
        regexError.isHidden = AzureDevOpsProjectURL.isRegexValid(adapterFields[BuildServerSettingKeys.azureDefinitionFilter]?.stringValue ?? "")
        tokenManagement?.isEnabled = AzureDevOpsProjectURL.tokenManagementURL(project: adapterFields[BuildServerSettingKeys.azureProjectURL]?.stringValue ?? "") != nil
    }
    func controlTextDidChange(_ notification: Notification) { captureAdapter(); if selectedType == .azureDevOps { updateAzureView() } }

    @objc private func scopeChanged() {
        view.window?.makeFirstResponder(nil)
        capture()
        scope = scopePopup.selectedItem?.representedObject as? DistributedSettingsScope ?? .effective
        reload()
    }
    @objc private func controlsChanged() { capture() }
    @objc private func typeChanged() { capture(); buildAdapterPanel((try? current()) ?? [:]) }
    private func tristate(_ button: NSButton) -> String? { button.state == .mixed ? nil : button.state == .on ? "true" : "false" }
    private func capture() {
        guard scope != .effective else { return }
        edits[scope, default: [:]][BuildServerSettingKeys.enabled] = .some(tristate(enabled))
        edits[scope, default: [:]][BuildServerSettingKeys.showBuildResultPage] = .some(tristate(showPage))
        edits[scope, default: [:]][BuildServerSettingKeys.type] = .some(selectedType?.rawValue)
        captureAdapter()
    }
    private func captureAdapter() {
        guard scope != .effective, let type = selectedType else { return }
        let text = { (key: String) in self.adapterFields[key]?.stringValue.trimmingCharacters(in: .whitespaces) ?? "" }
        switch type {
        case .gitHubActions:
            var api = text(BuildServerSettingKeys.gitHubApiURL)
            while api.hasSuffix("/") { api.removeLast() }
            let key = { (name: String) in BuildServerSettingKeys.adapter(type.rawValue, name) }
            edits[scope, default: [:]][key(BuildServerSettingKeys.gitHubApiURL)] = .some(api.isEmpty || api.caseInsensitiveCompare(GitHubActionsBuildAdapter.defaultApiURL) == .orderedSame ? nil : api)
            edits[scope, default: [:]][key(BuildServerSettingKeys.gitHubOwner)] = .some(text(BuildServerSettingKeys.gitHubOwner).isEmpty ? nil : text(BuildServerSettingKeys.gitHubOwner))
            edits[scope, default: [:]][key(BuildServerSettingKeys.gitHubRepository)] = .some(text(BuildServerSettingKeys.gitHubRepository).isEmpty ? nil : text(BuildServerSettingKeys.gitHubRepository))
            if let token = tokenField?.stringValue, !token.isEmpty {
                tokenEdits[BuildServerSettingsStore.gitHubTokenKey(apiURL: api, owner: text(BuildServerSettingKeys.gitHubOwner), repository: text(BuildServerSettingKeys.gitHubRepository))] = token
            }
        case .azureDevOps:
            let settings = AzureDevOpsBuildAdapter.Settings(projectURL: adapterFields[BuildServerSettingKeys.azureProjectURL]?.stringValue ?? "",
                buildDefinitionFilter: adapterFields[BuildServerSettingKeys.azureDefinitionFilter]?.stringValue ?? "")
            guard settings.isValid else { return }
            edits[scope, default: [:]][BuildServerSettingKeys.adapter(type.rawValue, BuildServerSettingKeys.azureProjectURL)] = .some(settings.projectURL)
            edits[scope, default: [:]][BuildServerSettingKeys.adapter(type.rawValue, BuildServerSettingKeys.azureDefinitionFilter)] = .some(settings.buildDefinitionFilter)
            if let token = tokenField?.stringValue, !token.isEmpty { tokenEdits[BuildServerSettingsStore.azureTokenKey(projectURL: settings.projectURL)] = token }
        }
    }
    @discardableResult
    func save() throws -> Bool {
        capture()
        var changed = false
        for scope in [DistributedSettingsScope.global, .distributed, .local] {
            if let changes = edits[scope], !changes.isEmpty { changed = try store.write(changes, scope: scope) || changed }
        }
        for (account, token) in tokenEdits {
            try RepositoryHostCredentials.save(token, for: account, service: RepositoryHostCredentials.buildServerService)
        }
        edits = [:]; tokenEdits = [:]
        return changed
    }

    @objc private func openGitHubTokenPage() { NSWorkspace.shared.open(URL(string: "https://github.com/settings/personal-access-tokens/new")!) }
    @objc private func openAzureTokenPage() {
        if let url = AzureDevOpsProjectURL.tokenManagementURL(project: adapterFields[BuildServerSettingKeys.azureProjectURL]?.stringValue ?? "") { NSWorkspace.shared.open(url) }
    }
    @objc private func extractFromClipboard() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        guard let parsed = AzureDevOpsProjectURL.parseBuildURL(text) else {
            HostingMessages.error("The clipboard doesn't contain a valid build url.\n\nPlease copy the url of the build into the clipboard before retrying.\n(Should contain at least the \"buildId\" parameter)", "Could not extract data")
            return
        }
        let token = tokenField?.stringValue ?? ""
        Task { @MainActor [weak self] in
            guard let self else { return }
            var name = ""
            if !token.isEmpty {
                do {
                    let client = try AzureDevOpsBuildAdapter(settings: .init(projectURL: parsed.project), projectURL: parsed.project, pat: token, credentialPassword: nil)
                    name = try await client.buildDefinitionName(buildID: parsed.buildID) ?? ""
                } catch {
                    HostingMessages.error("Error while trying to retrieve build definition information from url.\n\nPlease ensure that the url is valid and that the API token has access to build and project information.", "Could not extract data")
                    return
                }
            } else {
                HostingMessages.present("Unable to retrieve build definition information without API token. Field will be left blank.", "Could not extract data", .warning)
            }
            adapterFields[BuildServerSettingKeys.azureProjectURL]?.stringValue = parsed.project
            adapterFields[BuildServerSettingKeys.azureDefinitionFilter]?.stringValue = name
            captureAdapter(); updateAzureView()
        }
    }
}

@MainActor
final class BuildReportViewController: NSViewController {
    private let link = NSButton(title: "Open report", target: nil, action: nil)
    var url: URL?
    override func loadView() {
        let root = NSView()
        link.isBordered = false; link.contentTintColor = .linkColor
        link.font = .systemFont(ofSize: 16)
        link.target = self; link.action = #selector(open)
        link.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(link)
        NSLayoutConstraint.activate([link.centerXAnchor.constraint(equalTo: root.centerXAnchor), link.centerYAnchor.constraint(equalTo: root.centerYAnchor)])
        view = root
    }
    @objc private func open() { if let url { NSWorkspace.shared.open(url) } }
}
