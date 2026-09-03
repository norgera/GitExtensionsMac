import GitCommands
import AppKit

@MainActor
enum CleanDialog {
    static func present(
        source: any RepositoryCleaningDataSource,
        repositoryURL: URL,
        initialPath: String? = nil,
        owner: NSWindow,
        repositoryChanged: @escaping () -> Void,
        statusChanged: @escaping (String) -> Void
    ) {
        let controller = CleanViewController(
            source: source,
            repositoryURL: repositoryURL,
            initialPath: initialPath,
            repositoryChanged: repositoryChanged,
            statusChanged: statusChanged
        )
        let panel = NSPanel(contentViewController: controller)
        panel.title = "Clean working directory"
        panel.styleMask = [.titled, .closable, .resizable]
        panel.setContentSize(NSSize(width: 542, height: 727))
        panel.minSize = NSSize(width: 542, height: 727)
        controller.panel = panel
        owner.beginSheet(panel)
    }
}

@MainActor
private final class CleanViewController: NSViewController, NSWindowDelegate {
    weak var panel: NSPanel?
    private let source: any RepositoryCleaningDataSource
    private let repositoryURL: URL
    private let repositoryChanged: () -> Void
    private let statusChanged: (String) -> Void
    private let removeAll = NSButton(radioButtonWithTitle: "Remove all untracked files", target: nil, action: nil)
    private let removeNonIgnored = NSButton(radioButtonWithTitle: "Remove only non-ignored untracked files", target: nil, action: nil)
    private let removeIgnored = NSButton(radioButtonWithTitle: "Remove only ignored untracked files", target: nil, action: nil)
    private let removeDirectories = NSButton(checkboxWithTitle: "Remove untracked directories", target: nil, action: nil)
    private let cleanSubmodules = NSButton(checkboxWithTitle: "Clean submodules recursively", target: nil, action: nil)
    private let includePaths = NSTextView()
    private let excludePaths = NSTextView()
    private let includeToggle = NSButton(checkboxWithTitle: "Affect the following directory path(s) only:", target: nil, action: nil)
    private let excludeToggle = NSButton(checkboxWithTitle: "Exclude the following file path(s):", target: nil, action: nil)
    private let output = NSTextView()
    private let preview = NSButton(title: "Preview", target: nil, action: nil)
    private let cleanup = NSButton(title: "Cleanup", target: nil, action: nil)
    private var operationTask: Task<Void, Never>?

    init(
        source: any RepositoryCleaningDataSource,
        repositoryURL: URL,
        initialPath: String?,
        repositoryChanged: @escaping () -> Void,
        statusChanged: @escaping (String) -> Void
    ) {
        self.source = source
        self.repositoryURL = repositoryURL.standardizedFileURL
        self.repositoryChanged = repositoryChanged
        self.statusChanged = statusChanged
        super.init(nibName: nil, bundle: nil)
        if let initialPath, !initialPath.isEmpty {
            includeToggle.state = .on
            excludeToggle.state = .on
            includePaths.string = initialPath
            excludePaths.string = initialPath
        }
    }

    required init?(coder: NSCoder) { nil }
    deinit { operationTask?.cancel() }

    override func loadView() {
        let root = NSView()
        for button in [removeAll, removeNonIgnored, removeIgnored] {
            button.target = self
            button.action = #selector(selectMode(_:))
        }
        removeAll.state = .on
        removeDirectories.state = .on

        let modes = NSStackView(views: [removeAll, removeNonIgnored, removeIgnored])
        modes.orientation = .vertical
        modes.alignment = .leading
        modes.spacing = 7
        let modeBox = NSBox()
        modeBox.title = "Remove untracked files from working directory"
        modeBox.contentView = cleanPadded(modes, x: 10, y: 9)

        includeToggle.target = self
        includeToggle.action = #selector(togglePathInputs)
        excludeToggle.target = self
        excludeToggle.action = #selector(togglePathInputs)
        configureEditor(includePaths, editable: true)
        configureEditor(excludePaths, editable: true)
        let includeScroll = cleanScroll(includePaths, horizontal: false)
        let excludeScroll = cleanScroll(excludePaths, horizontal: false)
        includeScroll.heightAnchor.constraint(equalToConstant: 78).isActive = true
        excludeScroll.heightAnchor.constraint(equalToConstant: 78).isActive = true

        let addInclude = NSButton(title: "Add a path…", target: self, action: #selector(addIncludePath))
        let addExclude = NSButton(title: "Add a path…", target: self, action: #selector(addExcludePath))
        let includeHeader = cleanHeader(includeToggle, addInclude)
        let excludeHeader = cleanHeader(excludeToggle, addExclude)
        let includeHint = NSTextField(labelWithString: "(one path per line)")
        includeHint.textColor = .secondaryLabelColor
        let excludeHint = NSTextField(labelWithString: "(one path per line)")
        excludeHint.textColor = .secondaryLabelColor

        preview.target = self
        preview.action = #selector(previewClean)
        cleanup.target = self
        cleanup.action = #selector(confirmClean)
        let close = NSButton(title: "Close", target: self, action: #selector(close))
        close.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, preview, cleanup, close])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        configureEditor(output, editable: false)
        output.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        output.isHorizontallyResizable = true
        output.textContainer?.widthTracksTextView = false
        output.textContainer?.containerSize.width = .greatestFiniteMagnitude
        let outputScroll = cleanScroll(output, horizontal: true)
        let logLabel = NSTextField(labelWithString: "Log:")
        let content = NSStackView(views: [
            modeBox,
            removeDirectories,
            cleanSubmodules,
            includeHeader,
            includeScroll,
            includeHint,
            excludeHeader,
            excludeScroll,
            excludeHint,
            buttons,
            logLabel,
            outputScroll
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 7
        cleanPin(content, in: root, inset: 14)
        for view in [modeBox, includeHeader, includeScroll, excludeHeader, excludeScroll, buttons, outputScroll] {
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        outputScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        outputScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 115).isActive = true
        view = root
        togglePathInputs()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        panel?.delegate = self
        panel?.makeFirstResponder(removeAll)
    }

    @objc private func selectMode(_ sender: NSButton) {
        for button in [removeAll, removeNonIgnored, removeIgnored] {
            button.state = button === sender ? .on : .off
        }
    }

    @objc private func togglePathInputs() {
        includePaths.isEditable = includeToggle.state == .on
        includePaths.textColor = includePaths.isEditable ? .textColor : .disabledControlTextColor
        excludePaths.isEditable = excludeToggle.state == .on
        excludePaths.textColor = excludePaths.isEditable ? .textColor : .disabledControlTextColor
    }

    @objc private func addIncludePath() {
        let picker = NSOpenPanel()
        picker.title = "Select a directory to clean"
        picker.prompt = "Add"
        picker.directoryURL = repositoryURL
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        guard let panel else { return }
        picker.beginSheetModal(for: panel) { [weak self] response in
            guard response == .OK, let self, let url = picker.url,
                  isInsideRepository(url), url.standardizedFileURL != repositoryURL.appendingPathComponent(".git").standardizedFileURL
            else { return }
            includeToggle.state = .on
            appendLine(url.standardizedFileURL.path, to: includePaths)
            togglePathInputs()
        }
    }

    @objc private func addExcludePath() {
        let picker = NSOpenPanel()
        picker.title = "Select a file to exclude"
        picker.prompt = "Add"
        picker.directoryURL = repositoryURL
        picker.canChooseDirectories = false
        picker.canChooseFiles = true
        picker.allowsMultipleSelection = false
        guard let panel else { return }
        picker.beginSheetModal(for: panel) { [weak self] response in
            guard response == .OK, let self, let url = picker.url, isInsideRepository(url) else { return }
            excludeToggle.state = .on
            appendLine(relativePath(for: url), to: excludePaths)
            togglePathInputs()
        }
    }

    @objc private func previewClean() {
        let cleanRequest = request()
        run { [source] in
            let result = try await source.previewClean(cleanRequest)
            return (result.output, result.hasCandidates ? "Preview complete." : "Nothing to clean.", false, nil)
        }
    }

    @objc private func confirmClean() {
        guard let panel else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Cleanup"
        alert.informativeText = "Are you sure you want to cleanup the repository?"
        alert.addButton(withTitle: "Cleanup")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        alert.beginSheetModal(for: panel) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let cleanRequest = request()
            run { [source] in
                let result = try await source.clean(cleanRequest)
                switch result.outcome {
                case .noChanges:
                    return (result.output, "Nothing to clean.", false, nil)
                case .cleaned:
                    return (result.output, "Cleaned working directory.", true, nil)
                case .partiallyCleaned(let detail):
                    return (result.output, "Clean partially completed.", true, detail)
                }
            }
        }
    }

    private func run(
        _ operation: @escaping @MainActor () async throws -> (String, String, Bool, String?)
    ) {
        operationTask?.cancel()
        setBusy(true)
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let (log, status, changed, partialError) = try await operation()
                guard !Task.isCancelled else { return }
                output.string = log
                statusChanged(status)
                if changed { repositoryChanged() }
                if let partialError, let panel {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Clean partially completed"
                    alert.informativeText = partialError
                    _ = await alert.beginSheetModal(for: panel)
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, let panel else { return }
                let alert = NSAlert(error: error)
                alert.messageText = "Clean failed"
                _ = await alert.beginSheetModal(for: panel)
            }
            setBusy(false)
        }
    }

    private func request() -> RepositoryCleanRequest {
        let mode: RepositoryCleanMode
        if removeNonIgnored.state == .on { mode = .onlyNonIgnored }
        else if removeIgnored.state == .on { mode = .onlyIgnored }
        else { mode = .all }
        return RepositoryCleanRequest(
            mode: mode,
            removeDirectories: removeDirectories.state == .on,
            cleanSubmodules: cleanSubmodules.state == .on,
            includePaths: includeToggle.state == .on ? lines(in: includePaths) : [],
            excludePaths: excludeToggle.state == .on ? lines(in: excludePaths) : []
        )
    }

    private func setBusy(_ busy: Bool) {
        preview.isEnabled = !busy
        cleanup.isEnabled = !busy
    }

    @objc private func close() {
        operationTask?.cancel()
        if let panel, let owner = panel.sheetParent { owner.endSheet(panel) }
    }

    override func cancelOperation(_ sender: Any?) { close() }
    func windowWillClose(_ notification: Notification) { operationTask?.cancel() }

    private func lines(in textView: NSTextView) -> [String] {
        textView.string.components(separatedBy: .newlines).filter { !$0.isEmpty }
    }

    private func appendLine(_ value: String, to textView: NSTextView) {
        if !textView.string.isEmpty { textView.string += "\n" }
        textView.string += value
    }

    private func isInsideRepository(_ url: URL) -> Bool {
        let root = repositoryURL.path.hasSuffix("/") ? repositoryURL.path : repositoryURL.path + "/"
        let path = url.standardizedFileURL.path
        return path == repositoryURL.path || path.hasPrefix(root)
    }

    private func relativePath(for url: URL) -> String {
        let root = repositoryURL.path.hasSuffix("/") ? repositoryURL.path : repositoryURL.path + "/"
        return String(url.standardizedFileURL.path.dropFirst(root.count))
    }

    private func configureEditor(_ editor: NSTextView, editable: Bool) {
        editor.isEditable = editable
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.font = .systemFont(ofSize: NSFont.systemFontSize)
    }
}

@MainActor
private func cleanScroll(_ document: NSView, horizontal: Bool) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.borderType = .bezelBorder
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = horizontal
    scroll.autohidesScrollers = true
    scroll.documentView = document
    return scroll
}

@MainActor
private func cleanHeader(_ toggle: NSButton, _ add: NSButton) -> NSView {
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let row = NSStackView(views: [toggle, spacer, add])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    return row
}

@MainActor
private func cleanPadded(_ view: NSView, x: CGFloat, y: CGFloat) -> NSView {
    let container = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(view)
    NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: x),
        view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -x),
        view.topAnchor.constraint(equalTo: container.topAnchor, constant: y),
        view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -y)
    ])
    return container
}

@MainActor
private func cleanPin(_ view: NSView, in parent: NSView, inset: CGFloat) {
    view.translatesAutoresizingMaskIntoConstraints = false
    parent.addSubview(view)
    NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
        view.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
        view.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
        view.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
    ])
}
