import AppKit
import GitCommands
import GitExtensionsCore
import UniformTypeIdentifiers

@MainActor
final class ArchiveWindowController: NSWindowController, NSWindowDelegate {
    private let controller: ArchiveViewController
    private let closed: () -> Void
    init(source: any RepositoryArchivingDataSource, repositoryName: String, selected: [Commit], chooseCommit: @escaping (RevisionID?, NSWindow) async -> Commit?, closed: @escaping () -> Void) {
        self.closed = closed
        controller = ArchiveViewController(source: source, repositoryName: repositoryName, selected: selected, chooseCommit: chooseCommit)
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
    private let chooseCommit: (RevisionID?, NSWindow) async -> Commit?
    var revision: Commit?
    var comparison: Commit?
    private let summary = CommitSummaryView()
    private let comparisonSummary = NSTextField(wrappingLabelWithString: "...")
    private let zip = NSButton(radioButtonWithTitle: "zip", target: nil, action: nil)
    private let tar = NSButton(radioButtonWithTitle: "tar", target: nil, action: nil)
    private let pathFilter = NSButton(checkboxWithTitle: "Archive specific paths only", target: nil, action: nil)
    private let revisionFilter = NSButton(checkboxWithTitle: "Take the files that have changed from the revision above to this one and archive only those", target: nil, action: nil)
    private let paths = NSTextView()
    private let chooseComparison = NSButton(image: AppKitFactory.resourceImage("SelectRevision", accessibilityDescription: "Choose revision to compare with first") ?? NSImage(), target: nil, action: nil)
    private let chooseTarget = NSButton(image: AppKitFactory.resourceImage("SelectRevision", accessibilityDescription: "Choose another revision") ?? NSImage(), target: nil, action: nil)
    private let save = LeadingImageButton(title: "Save as...", target: nil, action: nil)
    private let close = NSButton(title: "Close", target: nil, action: nil)
    private let keepOpen = NSButton(checkboxWithTitle: "Keep dialog open", target: nil, action: nil)
    private let output = NSTextView()
    private var operation: Task<Void, Never>?
    var isBusy: Bool { operation != nil }

    init(source: any RepositoryArchivingDataSource, repositoryName: String, selected: [Commit], chooseCommit: @escaping (RevisionID?, NSWindow) async -> Commit?) {
        self.source = source; self.repositoryName = repositoryName; self.chooseCommit = chooseCommit
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
        chooseTarget.target = self; chooseTarget.action = #selector(chooseRevision)
        chooseTarget.setAccessibilityIdentifier("Archive.ChooseRevision")
        let chooseTargetColumn = NSStackView(views: [NSTextField(labelWithString: "Choose another\nrevision:"), chooseTarget])
        chooseTargetColumn.orientation = .vertical; chooseTargetColumn.alignment = .leading
        let targetRow = NSStackView(views: [summary, chooseTargetColumn]); targetRow.alignment = .top
        summary.setContentHuggingPriority(.defaultLow, for: .horizontal)
        chooseTargetColumn.setContentHuggingPriority(.required, for: .horizontal)
        stack.addArrangedSubview(targetRow)
        targetRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        for button in [zip, tar] { button.target = self; button.action = #selector(formatChanged(_:)) }
        zip.state = .on
        pathFilter.target = self; pathFilter.action = #selector(filterChanged(_:))
        revisionFilter.target = self; revisionFilter.action = #selector(filterChanged(_:))
        paths.isRichText = false; paths.font = AppSettingsStore.shared.fontPreferences.font(.monospace, fallback: .monospacedSystemFont(ofSize: 12, weight: .regular))
        let pathScroll = NSScrollView(); pathScroll.documentView = paths; pathScroll.hasVerticalScroller = true
        pathScroll.borderType = .bezelBorder
        pathScroll.heightAnchor.constraint(equalToConstant: 75).isActive = true
        let pathHint = NSTextField(labelWithString: "separate each new path by new line")
        pathHint.textColor = .secondaryLabelColor
        chooseComparison.target = self; chooseComparison.action = #selector(chooseDiffRevision)
        chooseComparison.setAccessibilityIdentifier("Archive.ChooseComparison")
        let comparisonBox = AppKitFactory.titledBox("", comparisonSummary)
        let comparisonChooser = NSStackView(views: [NSTextField(labelWithString: "Choose revision to\ncompare with first:"), chooseComparison])
        comparisonChooser.orientation = .vertical; comparisonChooser.alignment = .leading
        let comparisonRow = NSStackView(views: [comparisonBox, comparisonChooser]); comparisonRow.alignment = .top
        let filterContent = NSStackView(views: [pathFilter, pathScroll, pathHint, revisionFilter, comparisonRow])
        filterContent.orientation = .vertical; filterContent.alignment = .leading; filterContent.spacing = 6
        let filterGroup = AppKitFactory.titledBox("Filter files", filterContent)
        filterGroup.setAccessibilityIdentifier("Archive.FilterFiles")
        stack.addArrangedSubview(filterGroup)
        filterGroup.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        pathScroll.widthAnchor.constraint(equalTo: filterContent.widthAnchor).isActive = true
        comparisonRow.widthAnchor.constraint(equalTo: filterContent.widthAnchor).isActive = true
        revisionFilter.state = comparison == nil ? .off : .on
        let formatGroup = AppKitFactory.titledBox("Archive format", NSStackView(views: [zip, tar]))
        save.target = self; save.action = #selector(saveArchive); save.keyEquivalent = "\r"
        save.image = AppKitFactory.resourceImage("SaveAs", accessibilityDescription: "Save as"); save.imagePosition = .imageLeft
        let formatRow = NSStackView(views: [formatGroup, save]); formatRow.alignment = .bottom
        formatRow.setAccessibilityIdentifier("Archive.FormatRow")
        stack.addArrangedSubview(formatRow)
        output.isEditable = false; output.font = AppSettingsStore.shared.fontPreferences.font(.monospace, fallback: .monospacedSystemFont(ofSize: 11, weight: .regular))
        let transcript = NSScrollView(); transcript.documentView = output; transcript.hasVerticalScroller = true
        stack.addArrangedSubview(transcript)
        transcript.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        transcript.heightAnchor.constraint(greaterThanOrEqualToConstant: 45).isActive = true
        keepOpen.state = AppSettingsStore.shared.pullPreferences.closeProcessOnSuccess ? .off : .on
        close.target = self; close.action = #selector(closeWindow); close.keyEquivalent = "\u{1b}"
        stack.addArrangedSubview(NSStackView(views: [keepOpen, close]))
        view = root; update()
    }
    override func viewDidAppear() { super.viewDidAppear(); view.window?.makeFirstResponder(save) }
    private func describeComparison(_ commit: Commit?) -> String {
        guard let commit else { return "...\n\nAuthor:  ...\nCommit date:  ..." }
        return "\(commit.subject)\n\nAuthor:  \(commit.authorName)\nCommit date:  \(CommitInfoPresentation.dateText(commit.commitDate, now: Date()))"
    }
    private func update() {
        summary.apply(revision); comparisonSummary.stringValue = describeComparison(comparison)
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
        guard let window = view.window else { return }
        let initial = (comparing ? comparison : revision)?.id
        Task {
            if let commit = await chooseCommit(initial, window) {
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
