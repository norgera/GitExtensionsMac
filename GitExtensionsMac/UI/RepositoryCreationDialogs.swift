import GitCommands
import AppKit

package enum CloneSourceParser {
    package static func extract(from text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text.split(whereSeparator: \.isWhitespace).lazy.map(String.init).first(where: { value in
            value.contains("://")
                || value.hasPrefix("git@")
                || value.hasPrefix("ssh:")
                || value.hasPrefix("git:")
                || value.hasPrefix("file:")
                || value.hasPrefix("/")
        })
    }
}

@MainActor
extension GitUICommands {
    static func startCloneRepository(
        source: any RepositoryCreating,
        owner: NSWindow,
        initialSource: String? = nil,
        initialDestination: URL? = nil,
        onCreated: @escaping (RepositoryCreationResult) -> Void
    ) {
        RepositoryCreationDialogs.presentClone(
            source: source,
            owner: owner,
            initialSource: initialSource,
            initialDestination: initialDestination,
            onCreated: onCreated
        )
    }

    static func startInitializeRepository(
        source: any RepositoryCreating,
        owner: NSWindow,
        initialDirectory: URL? = nil,
        onCreated: @escaping (RepositoryCreationResult) -> Void
    ) {
        RepositoryCreationDialogs.presentInit(source: source, owner: owner, initialDirectory: initialDirectory, onCreated: onCreated)
    }
}

@MainActor
private enum RepositoryCreationDialogs {
    static func presentClone(
        source: any RepositoryCreating,
        owner: NSWindow,
        initialSource: String?,
        initialDestination: URL?,
        onCreated: @escaping (RepositoryCreationResult) -> Void
    ) {
        guard owner.attachedSheet == nil else { owner.attachedSheet?.makeKeyAndOrderFront(nil); return }
        let controller = CloneRepositoryViewController(
            source: source,
            initialSource: initialSource,
            initialDestination: initialDestination,
            onCreated: onCreated
        )
        let panel = NSPanel(contentViewController: controller)
        panel.title = "Clone repository"
        panel.styleMask = [.titled, .closable, .resizable]
        let preferences = AppSettingsStore.shared.repositoryCreationPreferences
        panel.setContentSize(NSSize(width: preferences.cloneWindowWidth, height: preferences.cloneWindowHeight))
        panel.minSize = NSSize(width: 520, height: 350)
        panel.maxSize = NSSize(width: 950, height: 700)
        controller.panel = panel
        owner.beginSheet(panel)
    }

    static func presentInit(
        source: any RepositoryCreating,
        owner: NSWindow,
        initialDirectory: URL?,
        onCreated: @escaping (RepositoryCreationResult) -> Void
    ) {
        guard owner.attachedSheet == nil else { owner.attachedSheet?.makeKeyAndOrderFront(nil); return }
        let controller = InitializeRepositoryViewController(source: source, initialDirectory: initialDirectory, onCreated: onCreated)
        let panel = NSPanel(contentViewController: controller)
        panel.title = "Create repository"
        panel.styleMask = [.titled, .closable, .resizable]
        let preferences = AppSettingsStore.shared.repositoryCreationPreferences
        panel.setContentSize(NSSize(width: preferences.initWindowWidth, height: preferences.initWindowHeight))
        panel.minSize = NSSize(width: 500, height: 210)
        panel.maxSize = NSSize(width: 900, height: 520)
        controller.panel = panel
        owner.beginSheet(panel)
    }
}

@MainActor
private final class CloneRepositoryViewController: NSViewController, NSWindowDelegate, NSComboBoxDelegate, NSTextFieldDelegate {
    private static let defaultBranchTitle = "(default: remote HEAD)"
    private static let noCheckoutTitle = "(none: don't checkout after clone)"

    weak var panel: NSPanel?
    private let source: any RepositoryCreating
    private let initialSource: String?
    private let initialDestination: URL?
    private let onCreated: (RepositoryCreationResult) -> Void
    private let sourceField = NSComboBox()
    private let destinationField = NSComboBox()
    private let subdirectoryField = NSTextField()
    private let branchField = NSComboBox()
    private let recursive = NSButton(checkboxWithTitle: "Initialize all submodules", target: nil, action: nil)
    private let fullHistory = NSButton(checkboxWithTitle: "Download full history", target: nil, action: nil)
    private let personal = NSButton(radioButtonWithTitle: "Personal repository", target: nil, action: nil)
    private let bare = NSButton(radioButtonWithTitle: "Public repository, no working directory (--bare)", target: nil, action: nil)
    private let destinationStatus = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let cloneButton = NSButton(title: "Clone", target: nil, action: nil)
    private var branchTask: Task<Void, Never>?
    private var isSubdirectoryUserEdited = false

    init(
        source: any RepositoryCreating,
        initialSource: String?,
        initialDestination: URL?,
        onCreated: @escaping (RepositoryCreationResult) -> Void
    ) {
        self.source = source
        self.initialSource = initialSource
        self.initialDestination = initialDestination
        self.onCreated = onCreated
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }
    deinit { branchTask?.cancel() }

    override func loadView() {
        let root = NSView()
        let preferences = AppSettingsStore.shared.repositoryCreationPreferences
        sourceField.usesDataSource = false
        sourceField.addItems(withObjectValues: preferences.recentSources)
        sourceField.placeholderString = "Repository URL or local path"
        sourceField.delegate = self
        if let clipboard = Self.cloneSourceFromPasteboard() {
            sourceField.stringValue = clipboard
        } else if let initialSource, !initialSource.isEmpty {
            sourceField.stringValue = initialSource
        } else if let first = preferences.recentSources.first {
            sourceField.stringValue = first
        }

        destinationField.usesDataSource = false
        destinationField.placeholderString = "/path/to/parent directory"
        destinationField.delegate = self
        let recentParents = AppSettingsStore.shared.recentRepositories.reduce(into: [String]()) { paths, repository in
            let parent = URL(fileURLWithPath: repository.path, isDirectory: true).deletingLastPathComponent().path
            if !paths.contains(parent) { paths.append(parent) }
        }
        destinationField.addItems(withObjectValues: recentParents)
        destinationField.stringValue = preferences.cloneDestinationPath.isEmpty
            ? (initialDestination?.path ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true).path)
            : preferences.cloneDestinationPath
        subdirectoryField.delegate = self
        subdirectoryField.stringValue = source.suggestedCloneSubdirectory(for: sourceField.stringValue)
        branchField.usesDataSource = false
        branchField.addItems(withObjectValues: [Self.defaultBranchTitle, Self.noCheckoutTitle])
        branchField.selectItem(at: 0)
        branchField.delegate = self
        recursive.state = .on
        fullHistory.state = .on
        personal.state = .on
        bare.state = .off
        personal.target = self; personal.action = #selector(repositoryKindChanged(_:))
        bare.target = self; bare.action = #selector(repositoryKindChanged(_:))

        let sourceBrowse = NSButton(title: "Browse…", target: self, action: #selector(browseSource))
        let destinationBrowse = NSButton(title: "Browse…", target: self, action: #selector(browseDestination))
        let sourceRow = fieldAndButton(sourceField, sourceBrowse)
        let destinationRow = fieldAndButton(destinationField, destinationBrowse)
        let grid = NSGridView(views: [
            [formLabel("Repository to clone:"), sourceRow],
            [formLabel("Destination parent directory:"), destinationRow],
            [formLabel("Subdirectory to create:"), subdirectoryField],
            [formLabel("Branch:"), branchField]
        ])
        grid.rowSpacing = 9; grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.column(at: 1).width = 420

        destinationStatus.textColor = .secondaryLabelColor
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        cloneButton.target = self; cloneButton.action = #selector(clone)
        cloneButton.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, cloneButton])
        buttons.orientation = .horizontal; buttons.spacing = 8
        let options = NSStackView(views: [recursive, fullHistory, personal, bare])
        options.orientation = .vertical; options.alignment = .leading; options.spacing = 7
        let content = NSStackView(views: [grid, destinationStatus, options, errorLabel, buttons])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            grid.widthAnchor.constraint(equalTo: content.widthAnchor),
            destinationStatus.widthAnchor.constraint(equalTo: content.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
        view = root
        updateDestinationStatus()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        panel?.delegate = self
        panel?.initialFirstResponder = sourceField
        sourceField.becomeFirstResponder()
    }

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSControl === sourceField {
            if !isSubdirectoryUserEdited {
                subdirectoryField.stringValue = source.suggestedCloneSubdirectory(for: sourceField.stringValue)
            }
            resetBranches()
        } else if obj.object as? NSControl === subdirectoryField {
            isSubdirectoryUserEdited = true
        }
        updateDestinationStatus()
    }

    func comboBoxWillPopUp(_ notification: Notification) {
        guard notification.object as? NSComboBox === branchField else { return }
        loadRemoteBranches()
    }

    private func resetBranches() {
        branchTask?.cancel()
        branchField.removeAllItems()
        branchField.addItems(withObjectValues: [Self.defaultBranchTitle, Self.noCheckoutTitle])
        branchField.selectItem(at: 0)
    }

    private func loadRemoteBranches() {
        guard branchTask == nil else { return }
        let repository = sourceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repository.isEmpty else { return }
        let previous = branchField.stringValue
        branchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let branches = try await source.remoteBranches(at: repository)
                guard !Task.isCancelled, repository == sourceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
                branchField.removeAllItems()
                branchField.addItems(withObjectValues: [Self.defaultBranchTitle, Self.noCheckoutTitle] + branches)
                if branchField.indexOfItem(withObjectValue: previous) >= 0 {
                    branchField.selectItem(withObjectValue: previous)
                } else {
                    branchField.selectItem(at: 0)
                }
                errorLabel.isHidden = true
            } catch is CancellationError {
            } catch {
                errorLabel.stringValue = "Could not load remote branches: \(error.localizedDescription)"
                errorLabel.isHidden = false
            }
            branchTask = nil
        }
    }

    private func updateDestinationStatus() {
        let parent = NSString(string: destinationField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
        let name = subdirectoryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !parent.isEmpty, !name.isEmpty else {
            destinationStatus.stringValue = "Enter a destination directory and subdirectory."
            cloneButton.isEnabled = false
            return
        }
        let url = URL(fileURLWithPath: parent, isDirectory: true).appendingPathComponent(name, isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            destinationStatus.stringValue = isDirectory.boolValue && contents.isEmpty
                ? "The existing empty directory will be used: \(url.path)"
                : "Warning: the destination already exists and is not empty: \(url.path)"
            destinationStatus.textColor = isDirectory.boolValue && contents.isEmpty ? .secondaryLabelColor : .systemOrange
        } else {
            destinationStatus.stringValue = "A new directory will be created: \(url.path)"
            destinationStatus.textColor = .secondaryLabelColor
        }
        cloneButton.isEnabled = !sourceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @objc private func repositoryKindChanged(_ sender: NSButton) {
        personal.state = sender === personal ? .on : .off
        bare.state = sender === bare ? .on : .off
    }

    @objc private func browseSource() {
        let picker = NSOpenPanel()
        picker.title = "Select repository to clone"
        picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let url = picker.url else { return }
        sourceField.stringValue = url.path
        if !isSubdirectoryUserEdited { subdirectoryField.stringValue = source.suggestedCloneSubdirectory(for: url.path) }
        resetBranches(); updateDestinationStatus()
    }

    @objc private func browseDestination() {
        let picker = NSOpenPanel()
        picker.title = "Select destination parent directory"
        picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.canCreateDirectories = true; picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let url = picker.url else { return }
        destinationField.stringValue = url.path
        updateDestinationStatus()
    }

    @objc private func clone() {
        guard let panel, let owner = panel.sheetParent else { return }
        let parentPath = NSString(string: destinationField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
        let sourceValue = sourceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let subdirectory = subdirectoryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceValue.isEmpty else { showValidation("Enter a repository URL or path to clone."); sourceField.becomeFirstResponder(); return }
        guard parentPath.hasPrefix("/") else { showValidation("The destination must be an absolute directory path."); destinationField.becomeFirstResponder(); return }
        guard !subdirectory.isEmpty, subdirectory != ".", subdirectory != "..", !subdirectory.contains("/"), !subdirectory.contains("\\") else {
            showValidation("Enter a valid subdirectory name."); subdirectoryField.becomeFirstResponder(); return
        }
        let branch: RepositoryCloneBranch = switch branchField.stringValue {
        case Self.defaultBranchTitle, "": .remoteHEAD
        case Self.noCheckoutTitle: .noCheckout
        default: .named(branchField.stringValue)
        }
        let request = RepositoryCloneRequest(
            source: sourceValue,
            destinationParent: URL(fileURLWithPath: parentPath, isDirectory: true),
            subdirectory: subdirectory,
            isBare: bare.state == .on,
            initializesSubmodules: recursive.state == .on,
            downloadsFullHistory: fullHistory.state == .on,
            branch: branch
        )
        errorLabel.isHidden = true
        Task { @MainActor [weak self, weak panel, weak owner] in
            guard let self, let panel, let owner else { return }
            let result = await RepositoryCreationProcessDialog.run(
                title: "Clone repository",
                initialStatus: "Cloning…",
                owner: panel,
                operation: { output in try await self.source.clone(request, output: output) }
            )
            switch result {
            case .success(let value):
                var preferences = AppSettingsStore.shared.repositoryCreationPreferences
                preferences.cloneDestinationPath = request.destinationParent.path
                AppSettingsStore.shared.saveRepositoryCreationPreferences(preferences)
                AppSettingsStore.shared.recordCloneSource(request.source)
                self.saveGeometry()
                owner.endSheet(panel)
                self.onCreated(value)
            case .failure(let error):
                errorLabel.stringValue = error.localizedDescription; errorLabel.isHidden = false
            case nil:
                break
            }
        }
    }

    private func showValidation(_ message: String) { errorLabel.stringValue = message; errorLabel.isHidden = false }

    @objc private func cancel() { closePanel() }
    override func cancelOperation(_ sender: Any?) { closePanel() }
    func windowWillClose(_ notification: Notification) { saveGeometry() }
    func windowDidResize(_ notification: Notification) { saveGeometry() }

    private func closePanel() {
        guard let panel else { return }
        saveGeometry()
        if let owner = panel.sheetParent { owner.endSheet(panel) } else { panel.close() }
    }

    private func saveGeometry() {
        guard let size = panel?.contentView?.bounds.size else { return }
        var preferences = AppSettingsStore.shared.repositoryCreationPreferences
        preferences.cloneWindowWidth = size.width; preferences.cloneWindowHeight = size.height
        AppSettingsStore.shared.saveRepositoryCreationPreferences(preferences)
    }

    private static func cloneSourceFromPasteboard() -> String? {
        CloneSourceParser.extract(from: NSPasteboard.general.string(forType: .string))
    }
}

@MainActor
private final class InitializeRepositoryViewController: NSViewController, NSWindowDelegate, NSComboBoxDelegate {
    weak var panel: NSPanel?
    private let source: any RepositoryCreating
    private let initialDirectory: URL?
    private let onCreated: (RepositoryCreationResult) -> Void
    private let directoryField = NSComboBox()
    private let personal = NSButton(radioButtonWithTitle: "Personal repository", target: nil, action: nil)
    private let bare = NSButton(radioButtonWithTitle: "Central repository, no working directory (--bare --shared=all)", target: nil, action: nil)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let createButton = NSButton(title: "Create", target: nil, action: nil)

    init(source: any RepositoryCreating, initialDirectory: URL?, onCreated: @escaping (RepositoryCreationResult) -> Void) {
        self.source = source; self.initialDirectory = initialDirectory; self.onCreated = onCreated
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        directoryField.usesDataSource = false
        directoryField.addItems(withObjectValues: AppSettingsStore.shared.recentRepositories.map(\.path))
        directoryField.delegate = self
        let last = AppSettingsStore.shared.repositoryCreationPreferences.cloneDestinationPath
        directoryField.stringValue = last.isEmpty ? (initialDirectory?.path ?? FileManager.default.homeDirectoryForCurrentUser.path) : last
        let browse = NSButton(title: "Browse…", target: self, action: #selector(browseDirectory))
        let row = NSGridView(views: [[formLabel("Directory:"), fieldAndButton(directoryField, browse)]])
        row.column(at: 0).xPlacement = .trailing; row.column(at: 1).xPlacement = .fill; row.column(at: 1).width = 390
        personal.state = .on; bare.state = .off
        personal.target = self; personal.action = #selector(repositoryKindChanged(_:))
        bare.target = self; bare.action = #selector(repositoryKindChanged(_:))
        errorLabel.textColor = .systemRed; errorLabel.isHidden = true
        createButton.target = self; createButton.action = #selector(create); createButton.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel)); cancel.keyEquivalent = "\u{1b}"
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, createButton]); buttons.orientation = .horizontal; buttons.spacing = 8
        let content = NSStackView(views: [row, personal, bare, errorLabel, buttons])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 10; content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            row.widthAnchor.constraint(equalTo: content.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
        view = root
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    }

    override func viewDidAppear() { super.viewDidAppear(); panel?.delegate = self; panel?.initialFirstResponder = directoryField; directoryField.becomeFirstResponder() }
    func controlTextDidChange(_ obj: Notification) { createButton.isEnabled = !directoryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    @objc private func repositoryKindChanged(_ sender: NSButton) { personal.state = sender === personal ? .on : .off; bare.state = sender === bare ? .on : .off }
    @objc private func browseDirectory() {
        let picker = NSOpenPanel(); picker.title = "Select or create repository directory"
        picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.canCreateDirectories = true; picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let url = picker.url else { return }
        directoryField.stringValue = url.path; createButton.isEnabled = true
    }
    @objc private func create() {
        guard let panel, let owner = panel.sheetParent else { return }
        let path = NSString(string: directoryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
        guard path.hasPrefix("/") else {
            errorLabel.stringValue = "The repository directory must be an absolute path."
            errorLabel.isHidden = false; directoryField.becomeFirstResponder(); return
        }
        let request = RepositoryInitRequest(directory: URL(fileURLWithPath: path, isDirectory: true), isBare: bare.state == .on)
        errorLabel.isHidden = true
        Task { @MainActor [weak self, weak panel, weak owner] in
            guard let self, let panel, let owner else { return }
            let result = await RepositoryCreationProcessDialog.run(
                title: "Create repository", initialStatus: "Initializing…", owner: panel,
                operation: { output in try await self.source.initialize(request, output: output) }
            )
            switch result {
            case .success(let value):
                var preferences = AppSettingsStore.shared.repositoryCreationPreferences
                preferences.cloneDestinationPath = request.directory.deletingLastPathComponent().path
                AppSettingsStore.shared.saveRepositoryCreationPreferences(preferences)
                self.saveGeometry(); owner.endSheet(panel); self.onCreated(value)
            case .failure(let error): errorLabel.stringValue = error.localizedDescription; errorLabel.isHidden = false
            case nil: break
            }
        }
    }
    @objc private func cancel() { closePanel() }
    override func cancelOperation(_ sender: Any?) { closePanel() }
    func windowWillClose(_ notification: Notification) { saveGeometry() }
    func windowDidResize(_ notification: Notification) { saveGeometry() }
    private func closePanel() { guard let panel else { return }; saveGeometry(); if let owner = panel.sheetParent { owner.endSheet(panel) } else { panel.close() } }
    private func saveGeometry() {
        guard let size = panel?.contentView?.bounds.size else { return }
        var preferences = AppSettingsStore.shared.repositoryCreationPreferences
        preferences.initWindowWidth = size.width; preferences.initWindowHeight = size.height
        AppSettingsStore.shared.saveRepositoryCreationPreferences(preferences)
    }
}

@MainActor
private enum RepositoryCreationProcessDialog {
    typealias Operation = @Sendable (@escaping GitOutputHandler) async throws -> RepositoryCreationResult

    static func run(
        title: String,
        initialStatus: String,
        owner: NSWindow,
        operation: @escaping Operation
    ) async -> Result<RepositoryCreationResult, Error>? {
        let controller = RepositoryCreationProcessViewController(initialStatus: initialStatus, operation: operation)
        let panel = NSPanel(contentViewController: controller)
        panel.title = title; panel.styleMask = [.titled, .closable, .resizable]
        panel.setContentSize(NSSize(width: 700, height: 430)); panel.minSize = NSSize(width: 520, height: 300)
        controller.panel = panel; panel.delegate = controller
        return await withCheckedContinuation { continuation in
            controller.onClose = { result in
                if owner.attachedSheet === panel { owner.endSheet(panel) }
                continuation.resume(returning: result)
            }
            owner.beginSheet(panel); controller.start()
        }
    }
}

@MainActor
private final class RepositoryCreationProcessViewController: NSViewController, NSWindowDelegate {
    weak var panel: NSPanel?
    var onClose: ((Result<RepositoryCreationResult, Error>?) -> Void)?
    private let initialStatus: String
    private let operation: RepositoryCreationProcessDialog.Operation
    private let progress = NSProgressIndicator()
    private let status = NSTextField(labelWithString: "Waiting…")
    private let outputView = NSTextView()
    private let keepOpen = NSButton(checkboxWithTitle: "Keep dialog open", target: nil, action: nil)
    private let abortButton = NSButton(title: "Abort", target: nil, action: nil)
    private let closeButton = NSButton(title: "OK", target: nil, action: nil)
    private var task: Task<Void, Never>?
    private var result: Result<RepositoryCreationResult, Error>?
    private var didClose = false

    init(initialStatus: String, operation: @escaping RepositoryCreationProcessDialog.Operation) {
        self.initialStatus = initialStatus; self.operation = operation
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    deinit { task?.cancel() }

    override func loadView() {
        let root = NSView()
        progress.style = .bar; progress.controlSize = .small; progress.isIndeterminate = true; progress.minValue = 0; progress.maxValue = 100
        progress.widthAnchor.constraint(equalToConstant: 92).isActive = true
        status.font = .boldSystemFont(ofSize: 12)
        outputView.isEditable = false; outputView.isSelectable = true; outputView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        outputView.textContainerInset = NSSize(width: 6, height: 6); outputView.isVerticallyResizable = true; outputView.isHorizontallyResizable = true
        outputView.autoresizingMask = [.width, .height]
        outputView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        outputView.textContainer?.widthTracksTextView = false
        let scroll = NSScrollView(); scroll.documentView = outputView; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .bezelBorder
        keepOpen.state = AppSettingsStore.shared.pullPreferences.closeProcessOnSuccess ? .off : .on
        keepOpen.target = self; keepOpen.action = #selector(keepOpenChanged)
        abortButton.target = self; abortButton.action = #selector(abort)
        closeButton.target = self; closeButton.action = #selector(close); closeButton.keyEquivalent = "\r"; closeButton.isEnabled = false
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [progress, status]); header.orientation = .horizontal; header.alignment = .centerY; header.spacing = 8
        let footer = NSStackView(views: [keepOpen, spacer, abortButton, closeButton]); footer.orientation = .horizontal; footer.alignment = .centerY; footer.spacing = 8
        for item in [header, scroll, footer] { item.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(item) }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), header.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 9), scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -9),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10), footer.heightAnchor.constraint(equalToConstant: 30)
        ])
        view = root
    }

    func start() {
        guard task == nil else { return }
        progress.startAnimation(nil); status.stringValue = initialStatus
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let value = try await operation { [weak self] event in Task { @MainActor in self?.append(event) } }
                result = .success(value); status.stringValue = "Completed successfully"
            } catch is CancellationError {
                result = .failure(CancellationError()); status.stringValue = "Aborted"; appendText("\nAborted\n", color: .systemOrange)
            } catch {
                result = .failure(error); status.stringValue = "Failed"; appendText("\n\(error.localizedDescription)\n", color: .systemRed)
            }
            progress.stopAnimation(nil); abortButton.isEnabled = false; closeButton.isEnabled = true; task = nil
            if case .success = result, keepOpen.state == .off { finish() }
        }
    }

    private func append(_ event: GitOutputEvent) {
        appendText(event.text, color: event.stream == .standardError ? .systemRed : .textColor)
        let lines = event.text.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
        if let last = lines.last, !last.isEmpty {
            let message = String(last); status.stringValue = message
            if let range = message.range(of: #"(?:^|\s)(\d{1,3})%"#, options: .regularExpression),
               let value = Double(message[range].trimmingCharacters(in: .whitespacesAndNewlines).dropLast()), (0...100).contains(value) {
                progress.isIndeterminate = false; progress.doubleValue = value
            }
        }
    }
    private func appendText(_ value: String, color: NSColor) {
        outputView.textStorage?.append(NSAttributedString(string: value, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: color]))
        outputView.scrollToEndOfDocument(nil)
    }
    override func cancelOperation(_ sender: Any?) { task != nil ? abort() : close() }
    @objc private func keepOpenChanged() {
        var preferences = AppSettingsStore.shared.pullPreferences
        preferences.closeProcessOnSuccess = keepOpen.state == .off
        AppSettingsStore.shared.savePullPreferences(preferences)
        if keepOpen.state == .off, case .success = result { finish() }
    }
    @objc private func abort() { status.stringValue = "Aborting…"; task?.cancel() }
    @objc private func close() { finish() }
    func windowWillClose(_ notification: Notification) { if task != nil { task?.cancel() }; finish() }
    private func finish() { guard !didClose else { return }; didClose = true; onClose?(result) }
}

@MainActor
private func formLabel(_ title: String) -> NSTextField {
    let label = NSTextField(labelWithString: title); label.alignment = .right; return label
}

@MainActor
private func fieldAndButton(_ field: NSView, _ button: NSButton) -> NSView {
    let row = NSStackView(views: [field, button]); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 8
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return row
}
