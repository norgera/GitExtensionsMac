import AppKit
import WebKit
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
    static func adapterTokenKey(_ type: BuildServerType, identity: String) -> String { tokenAccount(type, key: identity.lowercased()) }
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
                        token: (String) -> String? = BuildServerSettingsStore.token,
                        buildCredentials: @escaping BuildServerCredentialProvider = { key, stored in
                            await GitUICommands.requestBuildServerCredentials(key: key, useStored: stored)
                        }, isCommitVisible: @escaping @Sendable (ObjectID) async -> Bool = { _ in true }) async -> Resolution {
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
        let remoteURL = remotes.first { $0.name == currentRemote && !$0.isDisabled }?.fetchURL ?? remotes.first { !$0.isDisabled }?.fetchURL
        switch type {
        case .appVeyor:
            let account = adapterSettings["AppVeyorAccountName"] ?? ""
            let projects = replaceBuildServerVariables(adapterSettings["AppVeyorProjectName"] ?? "", remoteURL: remoteURL)
            let apiToken = token(BuildServerSettingsStore.adapterTokenKey(type, identity: account)) ?? adapterSettings["AppVeyorAccountToken"] ?? ""
            adapter = projects.isEmpty && (account.isEmpty || apiToken.isEmpty) ? nil : AppVeyorBuildAdapter(account: account,
                projects: projects, token: apiToken, loadTests: BuildServerSettingsStore.bool(adapterSettings["AppVeyorLoadTestsResults"]) ?? false,
                transport: transport, isCommitVisible: isCommitVisible)
        case .gitHubActions:
            let api = adapterSettings[BuildServerSettingKeys.gitHubApiURL]
            let owner = adapterSettings[BuildServerSettingKeys.gitHubOwner], repository = adapterSettings[BuildServerSettingKeys.gitHubRepository]
            adapter = GitHubActionsBuildAdapter(apiURL: api, owner: owner, repository: repository,
                token: token(BuildServerSettingsStore.gitHubTokenKey(apiURL: api, owner: owner, repository: repository)), transport: transport)
        case .azureDevOps:
            let configured = AzureDevOpsBuildAdapter.Settings(projectURL: adapterSettings[BuildServerSettingKeys.azureProjectURL] ?? "",
                buildDefinitionFilter: adapterSettings[BuildServerSettingKeys.azureDefinitionFilter] ?? "",
                repositoryName: adapterSettings[BuildServerSettingKeys.azureRepositoryName] ?? "")
            let projectURL = replaceBuildServerVariables(configured.projectURL, remoteURL: remoteURL)
            let pat = token(BuildServerSettingsStore.azureTokenKey(projectURL: configured.projectURL))
            var password: String?
            if pat == nil, let url = URL(string: projectURL) { password = await credential(url) }
            adapter = try? AzureDevOpsBuildAdapter(settings: configured, projectURL: projectURL, pat: pat, credentialPassword: password, transport: transport)
        case .gitLab:
            let instance = adapterSettings["InstanceUrl"] ?? ""
            adapter = GitLabBuildAdapter(instanceURL: instance, projectID: Int(adapterSettings["ProjectId"] ?? "") ?? 0,
                token: token(BuildServerSettingsStore.adapterTokenKey(type, identity: instance)) ?? adapterSettings["ApiToken"] ?? "",
                pagesLimit: Int(adapterSettings["PagesLimit"] ?? ""), transport: transport)
        case .jenkins:
            adapter = JenkinsBuildAdapter(server: adapterSettings["BuildServerUrl"] ?? "",
                projects: replaceBuildServerVariables(adapterSettings["ProjectName"] ?? "", remoteURL: remoteURL),
                ignoreBranch: adapterSettings["IgnoreBuildBranch"] ?? "", credentialProvider: buildCredentials, transport: transport)
        case .teamCity:
            adapter = TeamCityBuildAdapter(server: adapterSettings["BuildServerUrl"] ?? "",
                projects: replaceBuildServerVariables(adapterSettings["ProjectName"] ?? "", remoteURL: remoteURL),
                buildFilter: adapterSettings["BuildIdFilter"] ?? "", logAsGuest: BuildServerSettingsStore.bool(adapterSettings["LogAsGuest"]) ?? false,
                credentialProvider: buildCredentials, transport: transport)
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
    private var adapterButtons: [String: NSButton] = [:]
    private var panelType: BuildServerType?
    private var lookupTask: Task<Void, Never>?
    private let transport: HostTransport
    private let lookupStatus = NSTextField(labelWithString: "")
    private var lookupLink: NSButton?
    private var chooserLink: NSButton?
    private var credentialsLink: NSButton?
    private var clipboardLink: NSButton?

    init(store: BuildServerSettingsStore, remoteURLs: [String], workingDirectoryName: String?, transport: @escaping HostTransport = HostHTTP.send) {
        self.store = store; self.remoteURLs = remoteURLs; self.workingDirectoryName = workingDirectoryName
        self.transport = transport
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    deinit { lookupTask?.cancel() }

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
        lookupTask?.cancel()
        adapterPanel.arrangedSubviews.forEach { adapterPanel.removeArrangedSubview($0); $0.removeFromSuperview() }
        adapterFields = [:]; adapterButtons = [:]; tokenField = nil; tokenManagement = nil; lookupLink = nil; chooserLink = nil; credentialsLink = nil; clipboardLink = nil
        panelType = selectedType
        guard let type = selectedType, workingDirectoryName != nil || store.locations == nil else { return }
        func value(_ key: String) -> String? { values[BuildServerSettingKeys.adapter(type.rawValue, key)] }
        switch type {
        case .appVeyor:
            _ = field("AppVeyorProjectName", "Project(s) Name(s)", value("AppVeyorProjectName") ?? workingDirectoryName ?? "")
            adapterPanel.addArrangedSubview(NSTextField(wrappingLabelWithString: "Separate different projects with |. Projects may include an account name: account/project."))
            let account = value("AppVeyorAccountName") ?? ""
            _ = field("AppVeyorAccountName", "Account name", account)
            addAdapterToken(type, identity: account, caption: "Api token")
            adapterPanel.addArrangedSubview(NSTextField(wrappingLabelWithString: "Token used to query the AppVeyor REST API, available in your AppVeyor user account."))
            addAdapterCheck("AppVeyorLoadTestsResults", "Display test results in build status summary for each build result (network intensive)", value("AppVeyorLoadTestsResults"))
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
            regexError.stringValue = "The 'Build definition name' regular expression is not valid and won't be saved!"
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
        case .gitLab:
            let detected = remoteURLs.compactMap(CIConfiguration.gitLabRemote).first
            let instance = value("InstanceUrl") ?? detected?.instance ?? ""
            _ = field("InstanceUrl", "Instance URL", instance)
            _ = field("ProjectId", "Project ID", value("ProjectId") ?? "")
            addAdapterToken(type, identity: instance, caption: "Api Token")
            lookupLink = link("Get Project ID from server", #selector(getGitLabProjectID))
            tokenManagement = link("Go to token management page", #selector(openGitLabTokenPage))
            lookupStatus.stringValue = ""; lookupStatus.textColor = .systemRed; adapterPanel.addArrangedSubview(lookupStatus)
            updateExtraView()
            if value("ProjectId") == nil, !instance.isEmpty { getGitLabProjectID() }
        case .jenkins, .teamCity:
            _ = field("BuildServerUrl", type == .jenkins ? "Jenkins server URL" : "TeamCity server URL", value("BuildServerUrl") ?? "")
            _ = field("ProjectName", "Project name", value("ProjectName") ?? workingDirectoryName ?? "")
            if type == .jenkins {
                _ = field("IgnoreBuildBranch", "Ignore build for branch", value("IgnoreBuildBranch") ?? "")
            } else {
                adapterPanel.addArrangedSubview(NSTextField(labelWithString: "Several names split by | character"))
                _ = field("BuildIdFilter", "Build Id Filter (Regexp)", value("BuildIdFilter") ?? "")
                addAdapterCheck("LogAsGuest", "Log as guest to display the build report", value("LogAsGuest") ?? "false")
                chooserLink = link("Choose project/build…", #selector(chooseTeamCityBuild))
                clipboardLink = link("Extract the data from the build url copied in the clipboard", #selector(extractTeamCityClipboard))
                regexError.stringValue = "The \"Build Id Filter\" regular expression is not valid and won't be saved!"
                adapterPanel.addArrangedSubview(regexError)
            }
            credentialsLink = link("Credentials…", #selector(editBuildCredentials))
            updateExtraView()
        }
    }
    private func addAdapterToken(_ type: BuildServerType, identity: String, caption: String) {
        tokenField = field("token", caption, "", secure: true) as? NSSecureTextField
        tokenField?.placeholderString = BuildServerSettingsStore.token(BuildServerSettingsStore.adapterTokenKey(type, identity: identity)) == nil
            ? "Not set" : "Stored in Keychain — enter a replacement"
    }
    private func addAdapterCheck(_ key: String, _ title: String, _ value: String?) {
        let control = NSButton(checkboxWithTitle: title, target: self, action: #selector(controlsChanged))
        control.allowsMixedState = true; setTristate(control, value); control.isEnabled = scope != .effective
        adapterButtons[key] = control; adapterPanel.addArrangedSubview(control)
    }
    private func updateExtraView() {
        credentialsLink?.isEnabled = CIConfiguration.serverURL(adapterFields["BuildServerUrl"]?.stringValue ?? "", jenkins: selectedType == .jenkins) != nil
        clipboardLink?.isEnabled = scope != .effective
        if selectedType == .teamCity {
            regexError.isHidden = CIConfiguration.regexValid(adapterFields["BuildIdFilter"]?.stringValue ?? "")
            chooserLink?.isEnabled = scope != .effective && CIConfiguration.serverURL(adapterFields["BuildServerUrl"]?.stringValue ?? "") != nil
        }
        if selectedType == .gitLab {
            let valid = CIConfiguration.serverURL(adapterFields["InstanceUrl"]?.stringValue ?? "") != nil
            lookupLink?.isEnabled = scope != .effective && valid; tokenManagement?.isEnabled = valid
        }
    }
    private func updateAzureView() {
        regexError.isHidden = AzureDevOpsProjectURL.isRegexValid(adapterFields[BuildServerSettingKeys.azureDefinitionFilter]?.stringValue ?? "")
        tokenManagement?.isEnabled = AzureDevOpsProjectURL.tokenManagementURL(project: adapterFields[BuildServerSettingKeys.azureProjectURL]?.stringValue ?? "") != nil
    }
    func controlTextDidChange(_ notification: Notification) { captureAdapter(); if selectedType == .azureDevOps { updateAzureView() }; updateExtraView() }

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
        guard scope != .effective, let type = selectedType, panelType == type else { return }
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
        case .appVeyor, .gitLab, .jenkins, .teamCity:
            let keys: [String]
            switch type {
            case .appVeyor: keys = ["AppVeyorProjectName", "AppVeyorAccountName"]
            case .gitLab: keys = ["InstanceUrl", "ProjectId"]
            case .jenkins: keys = ["BuildServerUrl", "ProjectName", "IgnoreBuildBranch"]
            default: keys = ["BuildServerUrl", "ProjectName", "BuildIdFilter"]
            }
            if type == .teamCity && !CIConfiguration.regexValid(text("BuildIdFilter")) { return }
            for key in keys {
                if key == "ProjectId", Int(text(key)) == nil { continue }
                edits[scope, default: [:]][BuildServerSettingKeys.adapter(type.rawValue, key)] = .some(text(key).isEmpty ? nil : text(key))
            }
            for (key, button) in adapterButtons { edits[scope, default: [:]][BuildServerSettingKeys.adapter(type.rawValue, key)] = .some(tristate(button)) }
            if type == .gitLab { edits[scope, default: [:]][BuildServerSettingKeys.adapter(type.rawValue, "PagesLimit")] = .some("0") }
            if type == .gitLab || type == .appVeyor, let token = tokenField?.stringValue, !token.isEmpty {
                let identity = text(type == .gitLab ? "InstanceUrl" : "AppVeyorAccountName")
                tokenEdits[BuildServerSettingsStore.adapterTokenKey(type, identity: identity)] = token
                edits[scope, default: [:]][BuildServerSettingKeys.adapter(type.rawValue, type == .gitLab ? "ApiToken" : "AppVeyorAccountToken")] = .some(nil)
            }
        }
    }

    @objc private func editBuildCredentials() {
        guard let server = CIConfiguration.serverURL(adapterFields["BuildServerUrl"]?.stringValue ?? "", jenkins: selectedType == .jenkins), let host = server.host else { return }
        Task { _ = await GitUICommands.requestBuildServerCredentials(key: host, useStored: false) }
    }
    @objc private func openGitLabTokenPage() {
        guard let base = CIConfiguration.serverURL(adapterFields["InstanceUrl"]?.stringValue ?? ""),
              let url = URL(string: "-/profile/personal_access_tokens?name=GitExtensionsIntegration&scopes=api", relativeTo: base) else { return }
        NSWorkspace.shared.open(url.absoluteURL)
    }
    @objc private func getGitLabProjectID() {
        guard selectedType == .gitLab else { return }
        guard let remote = remoteURLs.compactMap(CIConfiguration.gitLabRemote).first else {
            lookupStatus.stringValue = "Failed to obtain project from server. Try a valid API token or check instance URL."; return
        }
        let instance = adapterFields["InstanceUrl"]?.stringValue ?? ""
        let token = tokenField?.stringValue.isEmpty == false ? tokenField!.stringValue : BuildServerSettingsStore.token(BuildServerSettingsStore.adapterTokenKey(.gitLab, identity: instance)) ?? ""
        lookupTask?.cancel()
        lookupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let id = try await GitLabBuildAdapter.projectID(instanceURL: instance, namespace: remote.namespace, repository: remote.repository, token: token, transport: transport)
                try Task.checkCancellation()
                guard selectedType == .gitLab, adapterFields["InstanceUrl"]?.stringValue == instance else { return }
                if let id, id > 0 { adapterFields["ProjectId"]?.stringValue = String(id); lookupStatus.stringValue = ""; captureAdapter() }
                else { lookupStatus.stringValue = "Failed to obtain project from server. Try a valid API token or check instance URL." }
            } catch is CancellationError { } catch { lookupStatus.stringValue = "Failed to obtain project from server. Try a valid API token or check instance URL." }
        }
    }
    private func teamCityClient() -> TeamCityBuildAdapter? {
        TeamCityBuildAdapter(server: adapterFields["BuildServerUrl"]?.stringValue ?? "", projects: "",
            credentialProvider: { key, stored in await GitUICommands.requestBuildServerCredentials(key: key, useStored: stored) }, transport: transport)
    }
    @objc private func chooseTeamCityBuild() {
        guard scope != .effective, let adapter = teamCityClient() else { return }
        let controller = TeamCityBuildChooserController(adapter: adapter, project: adapterFields["ProjectName"]?.stringValue ?? "", build: adapterFields["BuildIdFilter"]?.stringValue ?? "")
        let window = NSWindow(contentViewController: controller); window.title = "Choose the TeamCity build…"
        window.styleMask = [.titled, .resizable]; window.setContentSize(NSSize(width: 460, height: 400))
        let owner = view.window
        controller.onComplete = { [weak self] build in
            if let build { self?.adapterFields["ProjectName"]?.stringValue = build.projectID; self?.adapterFields["BuildIdFilter"]?.stringValue = build.id; self?.captureAdapter(); self?.updateExtraView() }
            if let owner { owner.endSheet(window) }; window.orderOut(nil); controller.onComplete = { _ in }
        }
        if let owner { owner.beginSheet(window) } else { window.center(); window.makeKeyAndOrderFront(nil) }
    }
    @objc private func extractTeamCityClipboard() {
        guard scope != .effective, let parsed = CIConfiguration.teamCityBuildURL(NSPasteboard.general.string(forType: .string) ?? "") else {
            HostingMessages.error("The clipboard doesn't contain a valid build url. Copy a URL containing the buildTypeId parameter.", "Build url not valid"); return
        }
        adapterFields["BuildServerUrl"]?.stringValue = parsed.server.absoluteString
        guard let adapter = teamCityClient() else { return }
        lookupTask?.cancel()
        lookupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let build = try await adapter.buildType(parsed.buildType); try Task.checkCancellation()
                guard selectedType == .teamCity else { return }
                adapterFields["ProjectName"]?.stringValue = build.projectID; adapterFields["BuildIdFilter"]?.stringValue = build.id; captureAdapter(); updateExtraView()
            } catch is CancellationError { } catch { HostingMessages.error(error.localizedDescription, "Error when loading the projects and build list") }
        }
    }
    @discardableResult
    func save() throws -> Bool {
        capture()
        var changed = !tokenEdits.isEmpty
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
final class BuildReportViewController: NSViewController, WKNavigationDelegate {
    private let link = NSButton(title: "Open report", target: nil, action: nil)
    private var webView: WKWebView?
    private var info: BuildInfo?
    private(set) var url: URL?
    func show(_ info: BuildInfo?) {
        guard self.info != info else { return }
        self.info = info; url = info?.url
        if isViewLoaded { updateContent() }
    }
    var embedsReport: Bool { info?.showInBuildReportTab == true }
    override func loadView() {
        let root = NSView()
        link.isBordered = false; link.contentTintColor = .linkColor
        link.font = .systemFont(ofSize: 16)
        link.target = self; link.action = #selector(open)
        link.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(link)
        NSLayoutConstraint.activate([link.centerXAnchor.constraint(equalTo: root.centerXAnchor), link.centerYAnchor.constraint(equalTo: root.centerYAnchor)])
        view = root
        updateContent()
    }
    private func updateContent() {
        webView?.stopLoading()
        guard embedsReport, let url else { webView?.removeFromSuperview(); webView = nil; link.isHidden = false; return }
        link.isHidden = true
        if webView == nil {
            let browser = WKWebView(); browser.navigationDelegate = self; browser.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(browser)
            NSLayoutConstraint.activate([browser.leadingAnchor.constraint(equalTo: view.leadingAnchor), browser.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                                         browser.topAnchor.constraint(equalTo: view.topAnchor), browser.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
            webView = browser
        }
        webView?.load(URLRequest(url: url))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        webView.removeFromSuperview(); self.webView = nil; link.isHidden = false
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        webView.removeFromSuperview(); self.webView = nil; link.isHidden = false
    }
    @objc private func open() { if let url { NSWorkspace.shared.open(url) } }
}
