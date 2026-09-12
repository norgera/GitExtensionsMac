import AppKit
import GitCommands
import GitExtensionsCore
import UniformTypeIdentifiers

@MainActor
final class ArchiveWindowController: NSWindowController, NSWindowDelegate {
    private let controller: ArchiveViewController
    private let closed: () -> Void
    init(source: any RepositoryArchivingDataSource, repositoryName: String, history: [Commit], selected: [Commit], closed: @escaping () -> Void) {
        self.closed = closed
        controller = ArchiveViewController(source: source, repositoryName: repositoryName, history: history, selected: selected)
        let window = NSWindow(contentViewController: controller)
        window.title = "Archive"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 610, height: 590))
        window.minSize = NSSize(width: 610, height: 622)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("Archive")
        super.init(window: window)
        window.delegate = self
    }
    required init?(coder: NSCoder) { nil }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !controller.isBusy }
    func windowWillClose(_ notification: Notification) { closed() }
}

@MainActor
private final class ArchiveViewController: NSViewController {
    let source: any RepositoryArchivingDataSource
    let repositoryName: String
    let history: [Commit]
    var revision: Commit?
    var comparison: Commit?
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let comparisonSummary = NSTextField(wrappingLabelWithString: "...")
    private let zip = NSButton(radioButtonWithTitle: "zip", target: nil, action: nil)
    private let tar = NSButton(radioButtonWithTitle: "tar", target: nil, action: nil)
    private let pathFilter = NSButton(checkboxWithTitle: "Archive specific paths only", target: nil, action: nil)
    private let revisionFilter = NSButton(checkboxWithTitle: "Archive files changed between these revisions", target: nil, action: nil)
    private let paths = NSTextView()
    private let chooseComparison = NSButton(title: "Choose comparison revision…", target: nil, action: nil)
    private let chooseTarget = NSButton(title: "Choose another revision…", target: nil, action: nil)
    private let save = NSButton(title: "Save as…", target: nil, action: nil)
    private let close = NSButton(title: "Close", target: nil, action: nil)
    private let keepOpen = NSButton(checkboxWithTitle: "Keep dialog open", target: nil, action: nil)
    private let output = NSTextView()
    private var operation: Task<Void, Never>?
    var isBusy: Bool { operation != nil }

    init(source: any RepositoryArchivingDataSource, repositoryName: String, history: [Commit], selected: [Commit]) {
        self.source = source; self.repositoryName = repositoryName; self.history = history
        revision = selected.first; comparison = selected.count == 2 ? selected[1] : nil
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        let root = NSView()
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)])
        stack.addArrangedSubview(NSTextField(labelWithString: "This revision will be archived:"))
        stack.addArrangedSubview(summary)
        summary.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        chooseTarget.target = self; chooseTarget.action = #selector(chooseRevision)
        stack.addArrangedSubview(chooseTarget)
        for button in [zip, tar] { button.target = self; button.action = #selector(formatChanged(_:)) }
        zip.state = .on
        stack.addArrangedSubview(NSStackView(views: [NSTextField(labelWithString: "Archive format"), zip, tar]))
        pathFilter.target = self; pathFilter.action = #selector(filterChanged(_:))
        revisionFilter.target = self; revisionFilter.action = #selector(filterChanged(_:))
        stack.addArrangedSubview(NSTextField(labelWithString: "Filter files"))
        stack.addArrangedSubview(pathFilter)
        stack.addArrangedSubview(NSTextField(labelWithString: "Separate each new path by a new line"))
        paths.isRichText = false; paths.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let pathScroll = NSScrollView(); pathScroll.documentView = paths; pathScroll.hasVerticalScroller = true
        pathScroll.borderType = .bezelBorder; stack.addArrangedSubview(pathScroll)
        pathScroll.heightAnchor.constraint(equalToConstant: 75).isActive = true
        pathScroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addArrangedSubview(revisionFilter)
        chooseComparison.target = self; chooseComparison.action = #selector(chooseDiffRevision)
        stack.addArrangedSubview(chooseComparison); stack.addArrangedSubview(comparisonSummary)
        comparisonSummary.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        revisionFilter.state = comparison == nil ? .off : .on
        output.isEditable = false; output.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let transcript = NSScrollView(); transcript.documentView = output; transcript.hasVerticalScroller = true
        stack.addArrangedSubview(transcript)
        transcript.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        transcript.heightAnchor.constraint(greaterThanOrEqualToConstant: 45).isActive = true
        keepOpen.state = AppSettingsStore.shared.pullPreferences.closeProcessOnSuccess ? .off : .on
        stack.addArrangedSubview(keepOpen)
        save.target = self; save.action = #selector(saveArchive); save.keyEquivalent = "\r"
        close.target = self; close.action = #selector(closeWindow); close.keyEquivalent = "\u{1b}"
        stack.addArrangedSubview(NSStackView(views: [save, close]))
        view = root; update()
    }
    override func viewDidAppear() { super.viewDidAppear(); view.window?.makeFirstResponder(save) }
    private func describe(_ commit: Commit?) -> String {
        guard let commit else { return "..." }
        return "\(commit.id)\n\(commit.subject)\nAuthor: \(commit.authorName)\nCommit date: \(commit.commitDate.formatted())"
    }
    private func update() {
        summary.stringValue = describe(revision); comparisonSummary.stringValue = describe(comparison)
        paths.isEditable = !isBusy && pathFilter.state == .on
        chooseComparison.isEnabled = !isBusy && revisionFilter.state == .on
        comparisonSummary.textColor = revisionFilter.state == .on ? .labelColor : .disabledControlTextColor
        for button in [zip, tar, pathFilter, revisionFilter, chooseTarget, save] { button.isEnabled = !isBusy }
        close.title = isBusy ? "Cancel operation" : "Close"
    }
    @objc private func formatChanged(_ sender: NSButton) { zip.state = sender === zip ? .on : .off; tar.state = sender === tar ? .on : .off }
    @objc private func filterChanged(_ sender: NSButton) {
        if sender.state == .on { (sender === pathFilter ? revisionFilter : pathFilter).state = .off }
        update()
    }
    @objc private func chooseRevision() { choose(comparing: false) }
    @objc private func chooseDiffRevision() { choose(comparing: true) }
    private func choose(comparing: Bool) {
        guard let window = view.window, let initial = (comparing ? comparison : revision) ?? history.first else { return }
        Task {
            if let commit = await CherryPickRevisionChooser.present(history: history, selectedCommitID: initial.id, owner: window) {
                if comparing { comparison = commit } else { revision = commit }; update()
            }
        }
    }
    @objc private func saveArchive() {
        guard let window = view.window else { return }
        guard let id = revision?.objectID, revisionFilter.state == .off || comparison?.objectID != nil else {
            Task { await MutationDialogs.showInformation("You need to choose a target revision.", title: "Archive", window: window) }; return
        }
        let format: ArchiveFormat = zip.state == .on ? .zip : .tar
        let selectedPaths = paths.string.components(separatedBy: .newlines)
        let filter: ArchiveFilter = pathFilter.state == .on ? .paths(selectedPaths) :
            (revisionFilter.state == .on ? .changedSince(comparison!.objectID!) : .all)
        let panel = NSSavePanel(); panel.title = "Save archive as"
        panel.allowedContentTypes = [UTType(filenameExtension: format.rawValue)].compactMap { $0 }
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = GitArchiveCommands.suggestedFilename(repositoryName: repositoryName, revision: id,
            paths: pathFilter.state == .on ? selectedPaths : nil) + "." + format.rawValue
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let destination = panel.url else { return }
            var preferences = AppSettingsStore.shared.pullPreferences
            preferences.closeProcessOnSuccess = self.keepOpen.state == .off
            AppSettingsStore.shared.savePullPreferences(preferences)
            self.operation = Task {
                do {
                    let result = try await self.source.archive(ArchiveRequest(revision: id, format: format, destination: destination, filter: filter)) { [weak self] event in
                        Task { @MainActor in self?.output.textStorage?.append(NSAttributedString(string: event.text,
                            attributes: [.foregroundColor: NSColor.textColor])) }
                    }
                    self.output.string = result.standardOutputString + result.standardErrorString
                    if result.succeeded { self.output.string = "Archive created: \(destination.path)" }
                    self.operation = nil; self.update()
                    if result.succeeded && self.keepOpen.state == .off { window.close() }
                } catch { self.output.string = error.localizedDescription; self.operation = nil; self.update() }
            }
            self.update()
        }
    }
    @objc private func closeWindow() { if let operation { operation.cancel() } else { view.window?.close() } }
}
