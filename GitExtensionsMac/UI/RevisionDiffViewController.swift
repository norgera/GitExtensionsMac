import GitExtensionsCore
import GitCommands
import AppKit


final class RevisionDiffViewController: RetainingSplitViewController {
    let mode: FileStatusListMode
    var onScript: ((ScriptDefinition) -> Void)? { didSet { filesController.onScript = onScript } }
    var onHunkMutation: ((RepositoryHunkSelection) -> Void)?
    var onLinePatch: ((FileStatusLinePatchKind, ChangedFile, FileDiff, Set<String>) -> Void)?

    var onFileCommand: ((String, FileStatusListItem) -> Void)?

    var onCommand: ((FileStatusListCommand) -> Void)?

    var onRefreshArtificial: (() -> Void)?
    var fileStatusSource: (any RepositoryFileStatusDataSource)?
    var blameSource: (any RepositoryBlameDataSource)? { didSet { blameController.source = blameSource; filesController.canBlame = blameSource != nil } }
    var blameContext: BlameViewController.Context? { didSet { blameController.context = blameContext } }
    var onBlameInFileTree: ((String, Int?) -> Void)? {
        didSet { filesController.hasFileTreeBlameHandoff = onBlameInFileTree != nil }
    }
    var onFileHistory: ((String, RevisionID?) -> Void)? {
        didSet { filesController.canFileHistory = onFileHistory != nil }
    }

    var contentProvider: (@Sendable (Commit, RepositoryFileEntry, RepositoryTextEncoding) async throws -> FilePreview<RepositoryFileContent>)?
    var treeEntriesProvider: (@Sendable (Commit) async throws -> [RepositoryFileEntry])?
    var describe: @Sendable (ObjectID) -> String = { $0.shortString }
    var isBareRepository = false { didSet { filesController.isBareRepository = isBareRepository } }
    var repositoryURL: URL? { didSet { filesController.repositoryURL = repositoryURL } }
    var diffTools: [String] { get { filesController.diffTools } set { filesController.diffTools = newValue } }
    var parentsOf: (RevisionID) -> [RevisionID] { get { filesController.parentsOf } set { filesController.parentsOf = newValue } }
    var supportsContinuousFileNavigation = false { didSet { updateContinuousNavigation() } }
    private var scrollNextFileToBottom = false

    var fallbackFollowedFile: String? {
        didSet { lastExplicitlySelectedPath = nil }
    }
    private static let collapsedFilePaneThickness: CGFloat = RepositoryBrowserViewController.splitterPanelMinSize
    private static let collapsedDiffPaneThickness: CGFloat = RepositoryBrowserViewController.splitterPanelMinSize

    let filesController: ChangedFilesViewController
    private let fileListSplit = RetainingSplitViewController(resizeBehavior: .fixedTrailingPane)
    private let outputReservation = NSViewController()
    private lazy var outputReservationItem = NSSplitViewItem(viewController: outputReservation)
    private var reservedOutputHeight: CGFloat = 0
    private var reservedOutputLength: CGFloat = 0
    private let viewerContainer = NSViewController()
    private let diffController = DiffContentViewController()
    private let fileContentController = RevisionFileContentViewController()
    let blameController = BlameViewController()
    private var requestedBlameLine: Int?
    private var selectedBlamePath: String?
    var requestsBlameForFollowedFile = false
    private var revisions: [Commit] = []
    private var headID: ObjectID?
    private var shownItem: FileStatusListItem?
    private var previewGeneration = 0
    private var shownDiff: FileDiff?
    private var diffTask: Task<Void, Never>?
    private var setDiffsTask: Task<Void, Never>?
    private var treeEntries: (commit: RevisionID, entries: [String: RepositoryFileEntry])?
    private var lastExplicitlySelectedPath: String?
    private var isImplicitSelection = false
    private var didSetInitialDivider = false
    var restoredFileListWidth: ((CGFloat) -> CGFloat?)?

    var scriptFileContext: [String: [String]] {
        ["SelectedRelativePaths": filesController.currentlySelectedFiles().map(\.path),
         "LineNumber": [String(filesController.isBlameShown ? blameController.currentFileLine : diffController.scriptLineNumber)], "ColumnNumber": ["1"]]
    }

    init(mode: FileStatusListMode = .diff, groupsByRevision: Bool = true) {
        self.mode = mode
        filesController = ChangedFilesViewController(mode: mode)
        filesController.groupsByRevision = groupsByRevision
        super.init(resizeBehavior: .fixedLeadingPane)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        diffTask?.cancel()
        setDiffsTask?.cancel()
    }

    func reserveOutputHistoryPanel(height: CGFloat) {
        guard isViewLoaded else { return }
        let height = max(0, height)
        let length = fileListSplit.primaryLength
        guard abs(height - reservedOutputHeight) > 0.5 || abs(length - reservedOutputLength) > 0.5 else { return }
        reservedOutputHeight = height
        reservedOutputLength = length
        fileListSplit.setCollapsed(height == 0, for: outputReservationItem)
        if height > 0 { fileListSplit.setRetainedPosition(max(0, length - height - fileListSplit.splitView.dividerThickness)) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .paneSplitter

        fileListSplit.splitView.isVertical = false
        fileListSplit.splitView.dividerStyle = .paneSplitter
        fileListSplit.addSplitViewItem(NSSplitViewItem(viewController: filesController))
        outputReservation.view = NSView()
        outputReservationItem.minimumThickness = 0
        fileListSplit.addSplitViewItem(outputReservationItem)
        fileListSplit.setCollapsed(true, for: outputReservationItem)
        let filesItem = NSSplitViewItem(viewController: fileListSplit)
        filesItem.minimumThickness = Self.collapsedFilePaneThickness
        filesItem.preferredThicknessFraction = 300.0 / 850.0
        filesItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 260)
        addSplitViewItem(filesItem)


        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        viewerContainer.view = container
        for child in [diffController, fileContentController, blameController] as [NSViewController] {
            viewerContainer.addChild(child)
            child.view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(child.view)
            NSLayoutConstraint.activate([
                child.view.topAnchor.constraint(equalTo: container.topAnchor),
                child.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                child.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                child.view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
        }
        fileContentController.view.isHidden = true
        blameController.view.isHidden = true
        fileContentController.onBlame = { [weak self] in self?.toggleBlame() }
        let diffItem = NSSplitViewItem(viewController: viewerContainer)
        diffItem.minimumThickness = Self.collapsedDiffPaneThickness
        diffItem.holdingPriority = .defaultLow
        addSplitViewItem(diffItem)


        if mode == .fileTree { diffController.supportedFileCommands.remove("file.difftool") }
        filesController.canCherryPick = true
        filesController.canShowInFileTree = mode == .diff
        filesController.canFilterInGrid = true
        filesController.canOpenSubmodule = true
        filesController.describe = { [weak self] revision in self?.describeRevision(revision) ?? "" }
        filesController.supportLinePatching = { [weak self] in self?.supportLinePatching ?? false }
        filesController.currentLineNumber = { [weak self] in
            guard let self else { return nil }
            return filesController.isBlameShown ? blameController.currentFileLine : diffController.scriptLineNumber
        }
        filesController.onSelectionChanged = { [weak self] items, folder in self?.selectionChanged(items: items, folder: folder) }
        filesController.onCommand = { [weak self] command in self?.onCommand?(command) }
        filesController.onRefreshArtificial = { [weak self] in self?.refreshArtificial() }
        filesController.onRecalculate = { [weak self] in self?.recalculate() }
        filesController.onDoubleClick = { [weak self] item in
            guard let self else { return }

            if AppSettingsStore.shared.preferences.openSubmoduleDiffInSeparateWindow && item.file.isSubmodule {
                onCommand?(FileStatusListCommand(identifier: "file.openSubmodule", items: [item], folder: nil, tool: nil, focused: item, remembered: nil))
            } else if item.file.isTracked && !item.file.isStatusOnly && !item.file.isRangeDiff {
                onFileHistory?(item.file.path, item.second)
            }
        }
        diffController.onHunkMutation = { [weak self] selection in self?.onHunkMutation?(selection) }
        diffController.supportsDiffAppearance = true
        diffController.difftasticAvailability = { [weak self] in await self?.fileStatusSource?.isDifftasticEnabled() ?? false }
        diffController.linePatchingSupported = { [weak self] in self?.onLinePatch != nil && (self?.supportLinePatching ?? false) }
        diffController.onLinePatch = { [weak self] kind, file, diff, ids in self?.onLinePatch?(kind, file, diff, ids) }
        updateContinuousNavigation()
        diffController.loadNextSearchFile = { [weak self] direction in
            guard let self else { return nil }
            return await loadNextSearchFile(direction, search: diffController.searchState)
        }
        fileContentController.loadNextSearchFile = { [weak self] direction in
            guard let self else { return nil }
            return await loadNextSearchFile(direction, search: fileContentController.searchState)
        }
        diffController.onOptionsChanged = { [weak self] _ in self?.showSelected() }
        diffController.onFileCommand = { [weak self] identifier, _ in
            guard let self, let shownItem else { return }
            if identifier == "file.blame" {
                toggleBlame()
            } else if identifier == "file.difftool" {

                filesController.perform("file.difftool")
            } else {
                onFileCommand?(identifier, shownItem)
            }
        }
        fileContentController.onEncodingChanged = { [weak self] in self?.showSelected() }
        fileContentController.onFileHistory = { [weak self] in
            guard let self, let item = shownItem else { return }
            onFileHistory?(item.file.path, item.second)
        }
    }

    private func loadNextSearchFile(_ direction: FileViewerSearchState.Direction, search: FileViewerSearchState) async -> String? {
        guard filesController.selectNextSearchFile(forward: direction == .next), let item = shownItem else { return nil }
        let token = previewGeneration
        await diffTask?.value
        guard !Task.isCancelled, token == previewGeneration, shownItem == item else { return nil }
        let activeSearch = fileContentController.view.isHidden ? diffController.searchState : fileContentController.searchState
        if activeSearch !== search { search.setText(activeSearch.text) }
        return item.group.id + "|" + item.file.id
    }

    private func updateContinuousNavigation() {
        diffController.onScrollBoundary = supportsContinuousFileNavigation ? { [weak self] forward in
            guard let self else { return }
            scrollNextFileToBottom = !forward
            if !filesController.selectAdjacentVisibleFile(forward: forward) { scrollNextFileToBottom = false }
        } : nil
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !didSetInitialDivider, splitView.bounds.width >= 650 else { return }
        didSetInitialDivider = true
        setRetainedPosition(restoredFileListWidth?(primaryLength) ?? 300)
    }


    func setDiffs(revisions: [Commit], headID: ObjectID?) {
        _ = view
        let previous = filesController.selectedFolder
            ?? filesController.selectedItems().first.flatMap { item in filesController.firstGroupItems.contains(item) ? item.file.path : nil }
        self.revisions = revisions
        self.headID = headID
        filesController.canBlame = blameSource != nil && (headID != nil || revisions.contains { $0.objectID != nil })
        calculate(preferredPaths: [lastExplicitlySelectedPath, fallbackFollowedFile, previous].compactMap { $0 })
    }


    func refreshArtificial() {
        guard revisions.contains(where: \.isArtificial) else { return }
        onRefreshArtificial?()
        recalculate()
    }

    private func recalculate() {
        let previous = filesController.selectedFolder ?? filesController.selectedItems().first?.file.path
        calculate(preferredPaths: [lastExplicitlySelectedPath, previous].compactMap { $0 })
    }

    private func calculate(preferredPaths: [String]) {
        setDiffsTask?.cancel()
        diffTask?.cancel()
        guard let source = fileStatusSource else { return }
        let preferences = AppSettingsStore.shared.fileStatusListPreferences
        let grepText = filesController.grepText
        var request = FileStatusDiffRequest(
            revisions: revisions, headID: headID, allowMultiDiff: true,
            showDiffForAllParents: preferences.showDiffForAllParents,
            showSkipWorktreeFiles: filesController.showsSkipWorktreeFiles,
            showUntrackedFiles: filesController.showsUntrackedFiles,
            grepArguments: (try? FileStatusCommands.grepArguments(for: grepText)) ?? [],
            grepText: grepText,
            fileTreeMode: mode == .fileTree && grepText.trimmingCharacters(in: .whitespaces).isEmpty)
        request.grepSettings = preferences.grepOptions
        request.includeDiffs = mode != .fileTree
        let describe = describe
        let revisionIDs = revisions.map(\.id)
        filesController.isLoading = true
        setDiffsTask = Task { @MainActor [weak self] in
            do {
                let groups = revisionIDs.isEmpty ? [] : try await source.calculateFileStatus(request, describe: describe)
                guard let self, !Task.isCancelled else { return }
                isImplicitSelection = true
                filesController.apply(groups: groups, revisions: revisionIDs, preferredPaths: preferredPaths)
                isImplicitSelection = false
                if requestsBlameForFollowedFile, let path = fallbackFollowedFile {
                    selectFileOrFolder(path, requestBlame: true)
                }


                for group in groups {
                    for file in group.files where file.isSubmodule {
                        try Task.checkCancellation()
                        let status = try? await source.fileStatusSubmodule(group: group, file: file)
                        try Task.checkCancellation()
                        if let status { filesController.apply(submodule: status, fileID: group.id + "|" + file.id) }
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                filesController.apply(groups: [], revisions: revisionIDs)
                BrowserCommandCenter.perform(.showStatus(error.localizedDescription))
            }
        }
    }


    func selectFileOrFolder(_ path: String, requestBlame: Bool? = nil, line: Int? = nil) {
        lastExplicitlySelectedPath = path
        if let requestBlame { filesController.isBlameShown = requestBlame; selectedBlamePath = path }
        requestedBlameLine = line
        if !filesController.selectFileOrFolder(path) { return }
        filesController.focusList()
    }

    func focusFileList() { filesController.focusList() }

    func cancelLoads() {
        diffController.previewPresentation.cancel()
        fileContentController.previewPresentation.cancel()
        diffTask?.cancel()
        setDiffsTask?.cancel()
        blameController.cancel()
    }

    func toggleBlame() {
        if mode != .fileTree && !AppSettingsStore.shared.blamePreferences.useDiffViewerForBlame {
            if let folder = filesController.selectedFolder { onBlameInFileTree?(folder, nil); return }
            guard let item = filesController.focusedItem ?? filesController.selectedItems().first,
                  item.file.isTracked, item.file.changeType != .deleted else { return }
            filesController.isBlameShown = false
            onBlameInFileTree?(item.file.path, diffController.scriptLineNumber)
            return
        }
        guard let item = filesController.focusedItem ?? filesController.selectedItems().first,
              item.file.isTracked, !item.file.isSubmodule, blameSource != nil else { return }
        let line = filesController.isBlameShown ? blameController.currentFileLine : diffController.scriptLineNumber
        if mode == .fileTree || AppSettingsStore.shared.blamePreferences.useDiffViewerForBlame {
            filesController.isBlameShown.toggle()
            selectedBlamePath = filesController.isBlameShown ? item.file.path : nil
            requestedBlameLine = line
            showSelected()
        } else {
            filesController.isBlameShown = false
            onBlameInFileTree?(item.file.path, line)
        }
    }

    private func describeRevision(_ revision: RevisionID?) -> String {
        switch revision {
        case .object(let id)?: describe(id)
        case .workingDirectory?: "Working directory"
        case .index?: "Commit index"
        case nil: ""
        }
    }

    private func selectionChanged(items: [FileStatusListItem], folder: String?) {
        if mode != .fileTree, filesController.isBlameShown, let path = items.first?.file.path, path != selectedBlamePath {
            filesController.isBlameShown = false
        }
        if !isImplicitSelection {
            lastExplicitlySelectedPath = folder ?? items.first.flatMap { $0.file.isRangeDiff ? nil : $0.file.path }
        }
        showSelected()
    }


    private func showSelected() {
        previewGeneration += 1
        diffController.previewPresentation.cancel()
        fileContentController.previewPresentation.cancel()
        diffTask?.cancel()
        diffController.supportedFileCommands.remove("file.blame")
        fileContentController.canBlame = false
        let items = filesController.selectedItems()
        if let folder = filesController.selectedFolder {
            shownItem = nil
            showText(Self.folderDescription(folder, items: items), title: folder)
            return
        }
        guard let item = filesController.focusedItem ?? items.first else {
            shownItem = nil
            shownDiff = nil
            showDiffViewer()
            diffController.apply(file: ChangedFile(id: "none", path: "", oldPath: nil, changeType: .modified, additions: 0, deletions: 0),
                                 diff: FileDiff(id: "none", fileID: "none", lines: []))
            return
        }
        shownItem = item
        shownDiff = nil
        let canBlame = blameSource != nil && (item.second.objectID ?? headID) != nil && item.file.isTracked && !item.file.isSubmodule && !item.file.isRangeDiff && !item.file.isStatusOnly
        if onFileHistory != nil && item.file.isTracked && !item.file.isRangeDiff && !item.file.isStatusOnly { diffController.supportedFileCommands.insert("file.history") }
        else { diffController.supportedFileCommands.remove("file.history") }
        if canBlame { diffController.supportedFileCommands.insert("file.blame") }
        else { diffController.supportedFileCommands.remove("file.blame") }
        fileContentController.canBlame = canBlame
        if filesController.isBlameShown, item.file.isTracked, !item.file.isSubmodule,
           let revision = item.second.objectID ?? headID, blameSource != nil {
            diffController.view.isHidden = true
            fileContentController.view.isHidden = true
            blameController.view.isHidden = false
            let encoding = AppSettingsStore.shared.fileViewerPreferences.textEncoding
            blameController.load(revision: revision, file: item.file.path, encoding: encoding, initialLine: requestedBlameLine)
            requestedBlameLine = nil
            return
        }

        let displayOnly = item.group.isGrep || item.group.kind == .range || item.group.kind == .combined
        diffController.supportsDiffAppearance = !displayOnly
        diffController.selectionScope = switch item.second {
        case _ where displayOnly: .revision
        case .workingDirectory: .workingTree
        case .index: .index
        case .object: .revision
        }
        if mode == .fileTree && filesController.grepText.isEmpty && !item.file.isStatusOnly {
            showFileView(item)
            return
        }
        if !displayOnly, effectiveContentProvider != nil, Self.viewsAsFileContent(item), revisions.contains(where: { $0.id == item.second }) {
            showFileView(item)
            return
        }
        showDiffViewer()
        diffController.apply(file: item.file, diff: nil)
        guard let source = fileStatusSource else { return }
        let options = diffController.diffOptions
        let grep = AppSettingsStore.shared.fileStatusListPreferences.grepOptions
        diffTask = Task { @MainActor [weak self] in
            do {
                let content = try await source.prepareFileStatusPreview(group: item.group, file: item.file, options: options, grep: grep)
                guard let self, !Task.isCancelled, shownItem == item else { return }
                diffController.apply(preview: content, file: item.file) { [weak self] diff in
                    guard let self, shownItem == item else { return }
                    shownDiff = diff
                    if scrollNextFileToBottom { diffController.scrollToBottom(); scrollNextFileToBottom = false }
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled, shownItem == item else { return }
                diffController.apply(error: error, file: item.file)
            }
        }
    }


    private var effectiveContentProvider: (@Sendable (Commit, RepositoryFileEntry, RepositoryTextEncoding) async throws -> FilePreview<RepositoryFileContent>)? {
        if let contentProvider { return contentProvider }
        guard let source = fileStatusSource as? any RepositoryBrowsingDataSource else { return nil }
        return { commit, file, encoding in try await source.prepareFilePresentation(for: commit, file: file, encoding: encoding) }
    }

    var isShowingFileContent: Bool { !fileContentController.view.isHidden }
    var displayedFileContentText: String { fileContentController.textView.string }
    var displayedDiffText: String { diffController.searchState.text }

    private var effectiveTreeEntriesProvider: (@Sendable (Commit) async throws -> [RepositoryFileEntry])? {
        if let treeEntriesProvider { return treeEntriesProvider }
        guard let source = fileStatusSource as? any RepositoryBrowsingDataSource else { return nil }
        return { commit in try await source.loadRepositoryFiles(for: commit) }
    }

    static func viewsAsFileContent(_ item: FileStatusListItem) -> Bool {
        let file = item.file
        guard !file.isSubmodule, !file.isStatusOnly, !file.isRangeDiff, !item.group.isGrep else { return false }
        let isImage = [".bmp", ".gif", ".ico", ".jpg", ".jpeg", ".png", ".tif", ".tiff"].contains { file.path.lowercased().hasSuffix($0) }
        return file.changeType == .added || !file.isTracked || item.group.first == nil || (file.changeType != .deleted && isImage)
    }

    static func folderDescription(_ folder: String, items: [FileStatusListItem]) -> String {
        var path = folder
        var nameStart = path.count
        if !path.hasSuffix("/") {
            path += "/"
            if path.count > 1 { nameStart += 1 }
        }
        var lines = ["(\(items.count)) \(path)", ""]
        lines += items.map { String($0.file.path.dropFirst(min(nameStart, $0.file.path.count))) }
        return lines.joined(separator: "\n")
    }

    nonisolated static func textDiff(_ text: String, id: String) -> FileDiff {

        let lines = text.components(separatedBy: "\n").enumerated().map {
            DiffLine(id: String($0.offset), oldLineNumber: nil, newLineNumber: nil, kind: .context, text: $0.element)
        }
        var diff = FileDiff(id: id, fileID: id, lines: lines)
        diff.isTextOnly = true
        return diff
    }

    private func showText(_ text: String, title: String) {
        showDiffViewer()
        shownDiff = nil
        let file = ChangedFile(id: "folder:\(title)", path: title, oldPath: nil, changeType: .modified, additions: 0, deletions: 0)
        diffController.apply(file: file, diff: Self.textDiff(text, id: file.id))
    }

    private func showDiffViewer() {
        fileContentController.previewPresentation.cancel()
        blameController.cancel()
        blameController.view.isHidden = true
        diffController.view.isHidden = false
        fileContentController.view.isHidden = true
    }


    private func showFileView(_ item: FileStatusListItem) {
        diffController.previewPresentation.cancel()
        blameController.cancel()
        blameController.view.isHidden = true
        diffController.view.isHidden = true
        fileContentController.view.isHidden = false
        guard let commit = revisions.first(where: { $0.id == item.second }), let contentProvider = effectiveContentProvider else { return }
        let path = item.file.path
        if let source = fileStatusSource {
            let revision = item.second
            fileContentController.exporter = { url in try await source.exportFile(path: path, at: revision, to: url) }
        } else {
            fileContentController.exporter = nil
        }
        fileContentController.applyRevision(commit)
        fileContentController.apply(file: nil, selectedPath: path)
        let encoding = fileContentController.selectedEncoding
        let treeEntriesProvider = effectiveTreeEntriesProvider
        let cached = treeEntries?.commit == commit.id ? treeEntries?.entries : nil
        diffTask = Task { @MainActor [weak self] in
            do {
                var entries = cached
                if entries == nil, commit.kind != .workingDirectory, let treeEntriesProvider {
                    let loaded = try await treeEntriesProvider(commit)
                    entries = Dictionary(loaded.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
                    self?.treeEntries = (commit.id, entries ?? [:])
                }
                let entry = entries?[path] ?? RepositoryFileEntry(path: path, content: "")
                guard let self, !Task.isCancelled, shownItem == item else { return }
                fileContentController.apply(file: entry, selectedPath: path)
                let loaded = try await contentProvider(commit, entry, encoding)
                guard !Task.isCancelled, shownItem == item else { return }
                fileContentController.apply(preview: loaded, file: entry)
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled, shownItem == item else { return }
                fileContentController.apply(error: error, selectedPath: path)
            }
        }
    }


    var supportLinePatching: Bool {
        guard let item = shownItem, let diff = shownDiff else { return false }
        let exists = repositoryURL.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent(item.file.path).path) } ?? false
        return Self.supportsLinePatching(file: item.file, diff: diff, fileExists: exists, isBareRepository: isBareRepository)
    }

    static func supportsLinePatching(file: ChangedFile, diff: FileDiff, fileExists: Bool, isBareRepository: Bool) -> Bool {
        guard !isBareRepository, diff.appearance == .patch else { return false }
        let hasHunks = diff.lines.contains { $0.kind == .header || $0.text.hasPrefix("@@") }
        let isAdded = file.changeType == .added || file.changeType == .copied || !file.isTracked
        return (hasHunks && fileExists) || (isAdded && (file.staged == .workTree || file.staged == .index || !fileExists))
    }

    func repositoryChanged() {
        ChangedFilesViewController.repositoryChanged()
        treeEntries = nil
        lastExplicitlySelectedPath = nil
    }
}


enum RevisionDescription {
    static func describe(_ commit: Commit) -> String {
        let prefix = commit.isArtificial ? "" : commit.shortID + ": "
        let branches = commit.references.filter { $0.kind == .currentBranch || $0.kind == .localBranch }
            + commit.references.filter { $0.kind == .remoteBranch }
        let tags = commit.references.filter { $0.kind == .tag }
        return prefix + ((branches + tags).first?.name ?? commit.subject)
    }
}

struct ChangedFileSection: Sendable {
    let id: String
    let title: String
    let imageName: String
    let files: [ChangedFile]
}

final class ChangedFileCellView: NSTableCellView {
    private let statusImage = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let text = NSTextField(labelWithString: "")
        text.font = AppSettingsStore.shared.applicationFont(size: 11)
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        statusImage.translatesAutoresizingMaskIntoConstraints = false
        statusImage.imageScaling = .scaleProportionallyDown
        textField = text
        imageView = statusImage
        addSubview(statusImage)
        addSubview(text)
        NSLayoutConstraint.activate([
            statusImage.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            statusImage.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusImage.widthAnchor.constraint(equalToConstant: 16),
            statusImage.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: statusImage.trailingAnchor, constant: 3),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func apply(node: ChangedFileNode, submodule: FileStatusSubmodule? = nil, usesFileTypeIcon: Bool = false) {
        textField?.stringValue = node.title + (submodule?.countSuffix ?? "")
        textField?.font = AppSettingsStore.shared.applicationFont(size: 11)
        textField?.lineBreakMode = node.file == nil ? .byTruncatingMiddle : AppSettingsStore.shared.preferences.truncatePathMethod.lineBreakMode
        toolTip = submodule?.summary.map { SubmoduleDiffPresentation.text($0, limitOutput: true) }
        if let file = node.file {
            let icon = submodule.flatMap { Self.submoduleImage($0, file: file) } ?? node.imageName
            statusImage.image = usesFileTypeIcon && !file.isSubmodule && !file.isStatusOnly
                ? FileAssociatedIconProvider.shared.icon(path: file.path)
                : AppKitFactory.resourceImage(icon, accessibilityDescription: file.changeType.description)
        } else {
            statusImage.image = node.folderPath != nil ? FileAssociatedIconProvider.shared.icon(path: node.folderPath!, isDirectory: true)
                : node.isGroupKey && node.imageName == "File" && node.descendantFiles.first != nil
                ? FileAssociatedIconProvider.shared.icon(path: node.descendantFiles.first!.path)
                : AppKitFactory.resourceImage(node.imageName, accessibilityDescription: node.title)
        }
    }

    static func submoduleImage(_ status: FileStatusSubmodule, file: ChangedFile) -> String? {

        guard file.changeType != .added, file.changeType != .deleted, !file.isConflict else { return nil }
        let direction: String? = switch status.state {
        case .ahead: "Up"
        case .behind: "Down"
        case .newer: "SemiUp"
        case .older: "SemiDown"
        default: nil
        }
        if let direction { return "SubmoduleRevision\(direction)\(status.isDirty ? "Dirty" : "")" }
        return status.state == .same && !status.isDirty ? "FolderSubmodule" : "SubmoduleDirty"
    }

    func apply(file: ChangedFile, title: String? = nil) {
        textField?.stringValue = title ?? file.path
        textField?.font = AppSettingsStore.shared.applicationFont(size: 11)
        let imageName = ChangedFilesViewController.imageName(for: file, isGrep: false)
        statusImage.image = AppKitFactory.resourceImage(imageName, accessibilityDescription: file.changeType.description)
    }
}

enum ChangedFileStatusPresentation {
    static func imageName(for changeType: FileChangeType) -> String {
        switch changeType {
        case .added: "FileStatusAdded"
        case .modified: "FileStatusModified"
        case .deleted: "FileStatusRemoved"
        case .renamed: "FileStatusRenamed"
        case .copied: "FileStatusCopied"
        }
    }
}

final class ChangedFileNode: NSObject {
    let id: String
    let title: String
    let imageName: String
    let file: ChangedFile?
    let children: [ChangedFileNode]

    var folderPath: String?

    var isGroupKey = false

    var isDiffGroup = false
    var groupID: String?

    init(id: String, title: String, imageName: String, file: ChangedFile? = nil, children: [ChangedFileNode] = []) {
        self.id = id
        self.title = title
        self.imageName = imageName
        self.file = file
        self.children = children
    }

    static func file(_ file: ChangedFile, title: String, imageName: String? = nil) -> ChangedFileNode {
        let imageName = imageName ?? ChangedFilesViewController.imageName(for: file, isGrep: false)
        return ChangedFileNode(id: "file:\(file.id)", title: title, imageName: imageName, file: file)
    }

    func assignGroup(_ id: String) {
        groupID = id
        children.forEach { $0.assignGroup(id) }
    }

    var descendantFiles: [ChangedFile] {
        if let file { return [file] }
        return children.flatMap(\.descendantFiles)
    }
}

enum ChangedFilePathTreeBuilder {
    static func build(files: [ChangedFile], dense: Bool,
                      imageName: ((ChangedFile) -> String)? = nil) -> [ChangedFileNode] {
        nodes(FileStatusPaths.build(files, flat: false, dense: dense), imageName: imageName)
    }

    static func nodes(_ source: [FileStatusPathNode], imageName: ((ChangedFile) -> String)?) -> [ChangedFileNode] {
        source.map { item in
            if let file = item.file { return ChangedFileNode.file(file, title: item.title, imageName: imageName?(file)) }
            let node = ChangedFileNode(id: "folder:\(item.path)", title: item.title, imageName: "FolderClosed",
                                       children: nodes(item.children, imageName: imageName))
            node.folderPath = item.path
            return node
        }
    }
}

enum ChangedFileListTreeBuilder {
    static func build(
        files: [ChangedFile],
        grouping: FileStatusGrouping,
        isTreeMode: Bool,
        usesDenseTree: Bool,
        showsGroupNodesInFlatList: Bool,
        imageName: ((ChangedFile) -> String)? = nil,
        title: ((ChangedFile) -> String)? = nil
    ) -> [ChangedFileNode] {
        if isTreeMode, grouping == .path {
            return ChangedFilePathTreeBuilder.build(files: files, dense: usesDenseTree, imageName: imageName)
        }

        let leaves = sorted(files: files, grouping: grouping).map {
            ChangedFileNode.file($0, title: title?($0) ?? $0.path, imageName: imageName?($0))
        }
        guard grouping != .path,
              isTreeMode || showsGroupNodesInFlatList,
              !leaves.isEmpty else { return leaves }
        return groupedNodes(wrapping: leaves, grouping: grouping, tree: isTreeMode, dense: usesDenseTree, imageName: imageName)
    }

    private static func sorted(files: [ChangedFile], grouping: FileStatusGrouping) -> [ChangedFile] {
        files.sorted { left, right in
            let leftKey = groupKey(for: left, grouping: grouping)
            let rightKey = groupKey(for: right, grouping: grouping)
            let comparison = grouping == .path ? ComparisonResult.orderedSame : FileStatusPaths.compare(leftKey, rightKey)
            return comparison == .orderedAscending
                || (comparison == .orderedSame && FileStatusPaths.precedes(left.path, right.path))
        }
    }

    private static func groupedNodes(wrapping leaves: [ChangedFileNode], grouping: FileStatusGrouping, tree: Bool, dense: Bool,
                                     imageName: ((ChangedFile) -> String)?) -> [ChangedFileNode] {
        let groups = Dictionary(grouping: leaves) { node in
            node.file.map { groupKey(for: $0, grouping: grouping) } ?? ""
        }
        let result = groups.keys.sorted { FileStatusPaths.compare($0, $1) == .orderedAscending }.map { key in
            let sorted = (groups[key] ?? []).sorted {
                FileStatusPaths.precedes($0.file?.path ?? $0.title, $1.file?.path ?? $1.title)
            }
            let children = tree ? ChangedFilePathTreeBuilder.build(files: sorted.compactMap(\.file), dense: dense, imageName: imageName) : sorted
            if children.count == 1 && children[0].children.isEmpty { return children[0] }
            let imageName = grouping == .status ? children.first?.imageName ?? "FileStatusModified" : "File"
            let node = ChangedFileNode(
                id: "group:\(grouping.rawValue):\(key)",
                title: "(\(sorted.count)) \(key)",
                imageName: imageName,
                children: children
            )
            node.isGroupKey = true
            return node
        }
        if result.count == 1 && !result[0].children.isEmpty { return result[0].children }
        return result
    }

    private static func groupKey(for file: ChangedFile, grouping: FileStatusGrouping) -> String {
        switch grouping {
        case .path:
            return file.path
        case .fileExtension:
            let value = (file.path as NSString).pathExtension
            return value.isEmpty ? "(no extension)" : ".\(value.lowercased())"
        case .status:
            return file.changeType.description
        }
    }
}

final class DiffContentViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    var showsLocalToolbar = false {
        didSet { if isViewLoaded { hoverToolbar.isHidden = !showsLocalToolbar } }
    }
    var toolbarMode: DiffViewerToolbar.Mode = .diff {
        didSet { if isViewLoaded { hoverToolbar.configure(for: toolbarMode) } }
    }
    var onScrollBoundary: ((Bool) -> Void)? { didSet { tableView.onScrollBoundary = onScrollBoundary } }
    func scrollToBottom() {
        guard !presentations.isEmpty else { return }
        tableView.scrollRowToVisible(presentations.count - 1)
    }
    var onHunkMutation: ((RepositoryHunkSelection) -> Void)?
    var onOptionsChanged: ((FileDiffOptions) -> Void)?
    var onFileCommand: ((String, ChangedFile) -> Void)?
    var supportedFileCommands: Set<String> = ["file.open.local", "file.showFinder", "file.difftool"]
    var selectionScope: ChangedFileSelectionScope = .revision
    var supportsDiffAppearance = false
    var difftasticAvailability: (() async -> Bool)? { didSet { difftasticEnabled = nil } }
    var linePatchingSupported: () -> Bool = { false }
    var onLinePatch: ((FileStatusLinePatchKind, ChangedFile, FileDiff, Set<String>) -> Void)?
    private var difftasticEnabled: Bool?
    private var occurrences = FileViewerOccurrences()
    private var linePatchPending = false
    private let tableView = FileViewerTableView()
    private let emptyStateLabel = NSTextField(labelWithString: "")
    let previewPresentation = FilePreviewPresentation<FileStatusContent>()
    private let hoverToolbar = DiffViewerToolbar(preferences: AppSettingsStore.shared.preferencesForNewFileViewer())
    private var presentations: [DiffLinePresentation] = []
    private var syntaxStates: [Int?] = []
    private var gutterMetrics = DiffGutterMetrics.empty
    private var caretRow = -1
    let searchState = FileViewerSearchState()
    var loadNextSearchFile: ((FileViewerSearchState.Direction) async -> String?)? { didSet { findPanel.loadNext = loadNextSearchFile } }
    private var searchOffsets: [Int] = []
    private lazy var findPanel = FileViewerFindPanel(state: searchState, caret: { [weak self] in
        guard let self else { return 0 }
        return searchState.currentMatch.map(NSMaxRange) ?? (searchOffsets.indices.contains(caretRow) ? searchOffsets[caretRow] : 0)
    }, changed: { [weak self] in self?.applySearch() })
    private var preferences = AppSettingsStore.shared.preferencesForNewFileViewer()
    private var currentFile: ChangedFile?
    private var currentDiff: FileDiff?
    var diffOptions: FileDiffOptions {
        var options = preferences.diffOptions
        if !supportsDiffAppearance { options.appearance = .patch }
        if options.appearance == .difftastic {
            options.difftasticWidth = GitDiffAppearance.difftasticWidth(viewerWidth: tableView.enclosingScrollView?.contentSize.width ?? 600)
        }
        return options
    }

    var scriptLineNumber: Int {
        let row = tableView.selectedRow >= 0 ? tableView.selectedRow : caretRow
        guard presentations.indices.contains(row) else { return 1 }
        let line = presentations[row].line
        return line.newLineNumber ?? line.oldLineNumber ?? 1
    }

    override func loadView() {
        let root = DiffTrackingView()
        root.onPointerPresenceChanged = { [weak self] isPresent in
            guard let self else { return }
            hoverToolbar.isHidden = !(showsLocalToolbar || isPresent)
        }
        hoverToolbar.configure(for: toolbarMode)
        hoverToolbar.isHidden = !showsLocalToolbar
        hoverToolbar.onAction = { [weak self] action, state in
            self?.performToolbarAction(action, state: state)
        }

        NotificationCenter.default.addObserver(self, selector: #selector(viewerPreferencesChanged), name: .fileViewerSettingsApplied, object: AppSettingsStore.shared)
        tableView.onShortcut = { [weak self] shortcut in
            guard let self, !presentations.isEmpty else { return false }
            switch shortcut {
            case .find: findText()
            case .findNext, .findPrevious:
                if shortcut == .findNext, searchState.query.isEmpty, supportedFileCommands.contains("file.difftool") {
                    openWithDifftool()
                } else {
                    findPanel.perform(shortcut == .findNext ? .next : .previous, viaKeyboard: true)
                }
            case .goToLine: goToLine()
            case .replace: return false
            case .wordDiff: return toggleAppearance(.gitWordDiff)
            case .difftastic: return toggleAppearance(.difftastic)
            case .nextOccurrence, .previousOccurrence: moveToOccurrence(forward: shortcut == .nextOccurrence)
            case .stageLines: return performLinePatch(reset: false, unstage: false)
            case .unstageLines: return performLinePatch(reset: false, unstage: true)
            case .resetLines: return performLinePatch(reset: true, unstage: false)
            default: performToolbarAction(shortcut.title, state: preferences.showsSyntaxHighlighting ? .off : .on)
            }
            return true
        }
        tableView.target = self
        tableView.doubleAction = #selector(selectWordOccurrences)
        tableView.onScrollBoundary = onScrollBoundary
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("DiffLine"))
        column.width = 900
        column.minWidth = 500
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = AppSettingsStore.shared.diffLineHeight
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = ApplicationColors.color("EditorBackground", fallback: .textBackgroundColor)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.onCopy = { [weak self] in self?.copySelection() }
        tableView.allowsMultipleSelection = true
        tableView.selectionHighlightStyle = .none

        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(scroll)
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.alignment = .center
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(emptyStateLabel)
        hoverToolbar.install(in: root)
        previewPresentation.install(in: root)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyStateLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor)
        ])
        view = root
    }

    func apply(preview: FilePreview<FileStatusContent>, file: ChangedFile, displayed: ((FileDiff?) -> Void)? = nil) {
        apply(file: file, diff: FileDiff(id: file.id, fileID: file.id, lines: []))
        emptyStateLabel.isHidden = true
        previewPresentation.present(preview, display: { [weak self] content in
            guard let self else { return }
            let diff: FileDiff?
            switch content {
            case .diff(let value): diff = value
            case .text(let text): diff = RevisionDiffViewController.textDiff(text, id: file.id)
            }
            apply(file: file, diff: diff ?? FileDiff(id: file.id, fileID: file.id, lines: []), confirmed: true)
            displayed?(diff)
        }, failure: { [weak self] in self?.apply(error: $0, file: file) })
    }

    func apply(file: ChangedFile, diff: FileDiff?, confirmed: Bool = false) {
        if !confirmed, let diff {
            let length = diff.lines.reduce(0) { $0 + $1.text.utf16.count + ($1.diffPrefix?.utf16.count ?? 0) + 1 }
            if length > FilePreview<FileStatusContent>.threshold {
                apply(preview: .deferred(length: length, load: { .diff(diff) }), file: file)
                return
            }
        }
        previewPresentation.cancel()
        linePatchPending = false
        currentFile = file
        currentDiff = diff
        hoverToolbar.apply(preferences: preferences, resolvedEncoding: diff?.contentEncoding)
        hoverToolbar.toolTip = "\(file.path) — \(file.changeType.description), +\(file.additions) −\(file.deletions)"
        let lines = diff?.lines ?? []
        presentations = DiffLinePresentation.build(from: lines, appearance: diff?.appearance ?? .patch)
        syntaxStates = DiffSyntaxHighlighter.lineStates(lines, filePath: file.path)
        var offset = 0
        searchOffsets = lines.map { line in
            defer { offset += line.text.utf16.count + 1 }
            return offset
        }
        searchState.setText(lines.map(\.text).joined(separator: "\n"))
        occurrences.row = -1
        occurrences.column = -1
        emptyStateLabel.stringValue = diff == nil ? "Loading diff…" : (lines.isEmpty ? "No differences to display." : "")
        emptyStateLabel.isHidden = !presentations.isEmpty
        gutterMetrics = DiffGutterMetrics(lines: lines, font: AppSettingsStore.shared.diffGutterFont)
        caretRow = -1
        tableView.reloadData()
        if !presentations.isEmpty { tableView.scrollRowToVisible(0) }
    }

    func apply(error: Error, file: ChangedFile) {
        linePatchPending = false
        currentFile = file
        currentDiff = nil
        presentations = []
        gutterMetrics = .empty
        emptyStateLabel.stringValue = "Unable to load diff: \(error.localizedDescription)"
        emptyStateLabel.isHidden = false
        tableView.reloadData()
    }

    private func performToolbarAction(_ action: String, state: NSControl.StateValue) {
        switch action {
        case "Next change":
            navigateToChange(forward: true)
        case "Previous change":
            navigateToChange(forward: false)
        case "Show nonprinting characters":
            preferences.showsNonPrintingCharacters = state == .on
            persistPreferences(reloadDiff: false)
            reloadRenderedLines()
        case "Show syntax highlighting":
            preferences.showsSyntaxHighlighting = state == .on
            persistPreferences(reloadDiff: preferences.diffAppearance == .difftastic)
            reloadRenderedLines()
        case "Increase the number of lines of context":
            preferences.contextLines += 1
            persistPreferences(reloadDiff: true)
        case "Decrease the number of lines of context":
            preferences.contextLines = max(0, preferences.contextLines - 1)
            persistPreferences(reloadDiff: true)
        case "Show entire file":
            preferences.showsEntireFile.toggle()
            persistPreferences(reloadDiff: true)
        case "Ignore whitespace changes at end of line":
            preferences.whitespace = preferences.whitespace == .endOfLine ? .none : .endOfLine
            persistPreferences(reloadDiff: true)
        case "Ignore changes in amount of whitespace":
            preferences.whitespace = preferences.whitespace == .changes ? .none : .changes
            persistPreferences(reloadDiff: true)
        case "Ignore all whitespace changes":
            preferences.whitespace = preferences.whitespace == .all ? .none : .all
            persistPreferences(reloadDiff: true)
        case "Treat all files as text":
            preferences.treatsAllFilesAsText.toggle()
            persistPreferences(reloadDiff: true)
        case let value where value.hasPrefix("Encoding:"):
            let rawValue = String(value.dropFirst("Encoding:".count))
            preferences.textEncoding = RepositoryTextEncoding(rawValue: rawValue) ?? .automatic
            persistPreferences(reloadDiff: true)
        case "Settings":
            BrowserCommandCenter.perform(.settings)
        default:
            break
        }
    }

    private func persistPreferences(reloadDiff: Bool) {
        AppSettingsStore.shared.updateFileViewerPreferences(preferences)
        hoverToolbar.apply(preferences: preferences, resolvedEncoding: currentDiff?.contentEncoding)
        if reloadDiff { onOptionsChanged?(preferences.diffOptions) }
    }

    @objc private func viewerPreferencesChanged() {
        let updated = AppSettingsStore.shared.fileViewerPreferences
        let reload = updated.diffOptions != preferences.diffOptions
        preferences = updated
        hoverToolbar.apply(preferences: preferences, resolvedEncoding: currentDiff?.contentEncoding)
        reloadRenderedLines()
        if reload { onOptionsChanged?(preferences.diffOptions) }
    }

    private func navigateToChange(forward: Bool) {
        let starts = presentations.indices.filter { index in
            guard presentations[index].line.isChange else { return false }
            guard index > 0 else { return true }
            return !presentations[index - 1].line.isChange
        }

        let destination: Int?
        if forward {
            destination = starts.first { $0 > caretRow }
        } else {
            let origin = caretRow < 0 ? presentations.count : caretRow
            destination = starts.last { $0 < origin }
        }

        guard let destination else {
            NSSound.beep()
            return
        }
        caretRow = destination
        tableView.selectRowIndexes(IndexSet(integer: destination), byExtendingSelection: false)
        tableView.scrollRowToVisible(max(0, destination - 4))
        tableView.scrollRowToVisible(destination)
    }

    private func reloadRenderedLines() {
        tableView.backgroundColor = ApplicationColors.color("EditorBackground", fallback: .textBackgroundColor)
        gutterMetrics = DiffGutterMetrics(lines: currentDiff?.lines ?? [], font: AppSettingsStore.shared.diffGutterFont)
        let selectedRows = tableView.selectedRowIndexes
        tableView.reloadData()
        tableView.selectRowIndexes(selectedRows, byExtendingSelection: false)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { presentations.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { AppSettingsStore.shared.diffLineHeight }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("DiffLineCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? DiffLineCellView) ?? DiffLineCellView()
        cell.identifier = identifier
        cell.apply(
            presentation: presentations[row],
            gutterMetrics: gutterMetrics,
            showsNonPrintingCharacters: preferences.showsNonPrintingCharacters,
            showsSyntaxHighlighting: preferences.showsSyntaxHighlighting,
            filePath: currentFile?.path,
            appearance: currentDiff?.appearance ?? .patch,
            highlightTerm: occurrences.term,
            openSpan: syntaxStates.indices.contains(row) ? syntaxStates[row] : nil,
            searchRanges: searchRanges(row: row, active: false),
            activeSearchRanges: searchRanges(row: row, active: true)
        )
        return cell
    }

    private var isDiffView: Bool {
        guard let currentDiff else { return false }
        return currentDiff.appearance != .patch || currentDiff.lines.contains { $0.kind == .header || $0.kind == .hunk }
    }

    private var isDiffAppearanceVisible: Bool { supportsDiffAppearance && isDiffView }

    private var canPatchLines: Bool {
        !linePatchPending && isDiffView && currentDiff?.appearance == .patch && linePatchingSupported() && onLinePatch != nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.autoenablesItems = false
        menu.removeAllItems()
        if canPatchLines {
            let hasLines = !selectedChangeLineIDs.isEmpty
            if selectionScope == .index {
                addMenuItem("Unstage selected line(s)", action: #selector(unstageSelectedLines), to: menu, enabled: hasLines)
            } else {
                addMenuItem("Stage selected line(s)", action: #selector(stageSelectedLines), to: menu, enabled: hasLines)
            }
            addMenuItem("Reset selected line(s)", action: #selector(resetSelectedLines), to: menu, enabled: hasLines)
        }
        addMenuItem("Copy", action: #selector(copySelection), to: menu, enabled: !tableView.selectedRowIndexes.isEmpty)
        if (currentDiff?.appearance ?? .patch) == .patch && currentDiff?.isTextOnly != true {
            addMenuItem("Copy patch", action: #selector(copyPatch), to: menu, enabled: currentDiff != nil)
            addMenuItem("Copy new version", action: #selector(copyNewVersion), to: menu, enabled: currentDiff != nil)
            addMenuItem("Copy old version", action: #selector(copyOldVersion), to: menu, enabled: currentDiff != nil)
        }
        if isDiffView {
            menu.addItem(.separator())
            if supportsDiffAppearance {
                addDisplayOption("Increase the number of lines of context", action: .increaseContext, to: menu)
                addDisplayOption("Decrease the number of lines of context", action: .decreaseContext, to: menu)
                addDisplayOption("Show entire file", action: .entireFile, checked: preferences.showsEntireFile, to: menu)
            }
            addDisplayOption("Show nonprinting characters", action: .nonPrinting, checked: preferences.showsNonPrintingCharacters, to: menu)
            if supportsDiffAppearance {
                addDisplayOption("Show syntax highlighting", action: .syntax, checked: preferences.showsSyntaxHighlighting, to: menu)
                addDisplayOption("Ignore whitespace changes at end of line", action: .whitespaceEOL, checked: preferences.whitespace != .none, to: menu)
                if currentDiff?.appearance != .difftastic {
                    addDisplayOption("Ignore changes in amount of whitespace", action: .whitespaceChanges, checked: [.changes, .all].contains(preferences.whitespace), to: menu)
                    addDisplayOption("Ignore all whitespace changes", action: .whitespaceAll, checked: preferences.whitespace == .all, to: menu)
                }
            }
            if isDiffAppearanceVisible { menu.addItem(diffAppearanceMenuItem()) }
            menu.addItem(.separator())
            addDisplayOption("Treat all files as text", action: .treatAsText, checked: preferences.treatsAllFilesAsText, to: menu)
            if onScrollBoundary != nil {
                addDisplayOption("Enable automatic continuous scroll (without Option key)", action: .continuousScroll, checked: AppSettingsStore.shared.preferences.automaticContinuousScroll, to: menu)
            }
        } else {
            addMenuItem("Select all", action: #selector(selectAllDiffLines), to: menu, enabled: !presentations.isEmpty)
        }
        addMenuItem("Find…", action: #selector(findText), to: menu, enabled: !presentations.isEmpty || previewPresentation.state == .deferred)
        addMenuItem("Find next", action: #selector(findNext), to: menu, enabled: !presentations.isEmpty && !searchState.query.isEmpty)
        addMenuItem("Find previous", action: #selector(findPrevious), to: menu, enabled: !presentations.isEmpty && !searchState.query.isEmpty)
        addMenuItem("Go to line…", action: #selector(goToLine), to: menu, enabled: !presentations.isEmpty)
        if !isDiffView {
            menu.addItem(.separator())
            addMenuItem("Open working directory file", action: #selector(openFile), to: menu, enabled: currentFile?.changeType != .deleted && supportedFileCommands.contains("file.open.local"))
            addMenuItem("Open containing folder", action: #selector(showInFinder), to: menu, enabled: currentFile != nil && supportedFileCommands.contains("file.showFinder"))
            addMenuItem("Open with difftool", action: #selector(openWithDifftool), to: menu, enabled: currentFile != nil && supportedFileCommands.contains("file.difftool"))
            menu.addItem(.separator())
            addMenuItem("Show blame", action: #selector(showBlame), to: menu, enabled: currentFile != nil && supportedFileCommands.contains("file.blame"))
            addMenuItem("Show file history", action: #selector(showFileHistory), to: menu, enabled: currentFile != nil && supportedFileCommands.contains("file.history"))
        }
    }

    private enum DisplayOption: String {
        case increaseContext, decreaseContext, entireFile, nonPrinting, syntax, whitespaceEOL, whitespaceChanges, whitespaceAll, treatAsText, continuousScroll
    }

    private func addDisplayOption(_ title: String, action: DisplayOption, checked: Bool? = nil, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: #selector(displayOptionSelected(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action.rawValue
        item.identifier = .init("viewer.display." + action.rawValue)
        if let checked { item.state = checked ? .on : .off }
        let shortcut: FileViewerShortcut? = switch action {
        case .increaseContext: .increaseContext
        case .decreaseContext: .decreaseContext
        case .entireFile: .entireFile
        case .syntax: .syntax
        case .treatAsText: .treatAsText
        default: nil
        }
        if let shortcut { AppKitFactory.setMenuShortcut("viewer." + shortcut.rawValue, for: item) }
        let image: String? = switch action {
        case .increaseContext: "NumberOfLinesIncrease"
        case .decreaseContext: "NumberOfLinesDecrease"
        case .entireFile: "ShowEntireFile"
        case .nonPrinting: "ShowWhitespace"
        case .syntax: "SyntaxHighlighting"
        case .whitespaceEOL: "WhitespaceIgnoreEol"
        case .whitespaceChanges: "WhitespaceIgnore"
        case .whitespaceAll: "WhitespaceIgnoreAll"
        case .continuousScroll: "UiScrollBar"
        default: nil
        }
        if let image { AppKitFactory.setMenuImage(image, for: item, adaptLightness: [.whitespaceEOL, .whitespaceChanges, .whitespaceAll, .nonPrinting, .syntax, .continuousScroll].contains(action)) }
        if action == .whitespaceAll { AppKitFactory.setMenuShortcut("viewer.ignoreWhitespace", for: item) }
        menu.addItem(item)
    }

    @objc private func displayOptionSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let option = DisplayOption(rawValue: raw) else { return }
        let action: String
        switch option {
        case .increaseContext: action = FileViewerShortcut.increaseContext.title
        case .decreaseContext: action = FileViewerShortcut.decreaseContext.title
        case .entireFile: action = FileViewerShortcut.entireFile.title
        case .nonPrinting: action = "Show nonprinting characters"
        case .syntax: action = FileViewerShortcut.syntax.title
        case .whitespaceEOL: action = "Ignore whitespace changes at end of line"
        case .whitespaceChanges: action = "Ignore changes in amount of whitespace"
        case .whitespaceAll: action = "Ignore all whitespace changes"
        case .treatAsText: action = FileViewerShortcut.treatAsText.title
        case .continuousScroll:
            let store = AppSettingsStore.shared
            var value = store.preferences
            value.automaticContinuousScroll.toggle()
            store.save(value)
            return
        }
        performToolbarAction(action, state: sender.state == .on ? .off : .on)
    }

    private func addMenuItem(_ title: String, action: Selector?, to menu: NSMenu, enabled: Bool) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = action == nil ? nil : self
        item.isEnabled = enabled
        let shortcut: FileViewerShortcut? = switch action {
        case #selector(stageSelectedLines): .stageLines
        case #selector(unstageSelectedLines): .unstageLines
        case #selector(resetSelectedLines): .resetLines
        case #selector(findText): .find
        case #selector(findNext): .findNext
        case #selector(findPrevious): .findPrevious
        case #selector(goToLine): .goToLine
        default: nil
        }
        if let shortcut { AppKitFactory.setMenuShortcut("viewer." + shortcut.rawValue, for: item) }
        if action == #selector(copySelection) { item.keyEquivalent = "c"; item.keyEquivalentModifierMask = .command }
        let image: String? = switch action {
        case #selector(stageSelectedLines): "Stage"
        case #selector(unstageSelectedLines): "Unstage"
        case #selector(resetSelectedLines): "ResetWorkingDirChanges"
        case #selector(findText): "Preview"
        default: nil
        }
        if let image { AppKitFactory.setMenuImage(image, for: item) }
        menu.addItem(item)
    }

    @objc private func copySelection() { copy(.selection) }

    @objc private func showBlame() { if let currentFile { onFileCommand?("file.blame", currentFile) } }
    @objc private func showFileHistory() { if let currentFile { onFileCommand?("file.history", currentFile) } }

    @objc private func copyPatch() { copy(.patch) }
    @objc private func copyOldVersion() { copy(.oldVersion) }
    @objc private func copyNewVersion() { copy(.newVersion) }

    private func copy(_ command: FileViewerCopy.Command) {
        let lines = presentations.map(\.line)
        let combined = lines.contains { ($0.diffPrefix?.count ?? 0) == 2 }
        let isDiff = currentDiff?.isTextOnly != true && currentDiff?.appearance != .difftastic
        let prefixes = combined ? ["  ", "++", "+ ", " +", "--", "- ", " -"] : ["-", "+", " "]
        let ranges = FileViewerCopy.selectedRanges(lines: lines, rows: tableView.selectedRowIndexes, patch: currentDiff?.appearance == .patch && currentDiff?.isTextOnly != true)
        let selections: [NSRange?] = ranges.isEmpty ? [nil] : ranges.map(Optional.some)
        let payloads = selections.compactMap { selected in
            FileViewerCopy.payload(command, text: renderedPatchLines(), selection: selected,
                                                   isDiff: isDiff, fullPrefixes: prefixes,
                                                   normalizeLineEndings: currentDiff?.normalizesCopyLineEndings ?? false)
        }
        guard !payloads.isEmpty else { return }
        copyToPasteboard(payloads.joined())
    }

    private func renderedPatchLines() -> String {
        presentations.map { currentDiff?.appearance == .patch && currentDiff?.isTextOnly != true ? $0.line.patchText : $0.line.text }.joined(separator: "\n")
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @objc private func selectAllDiffLines() {
        tableView.selectRowIndexes(IndexSet(integersIn: presentations.indices), byExtendingSelection: false)
    }

    @objc private func findText() {
        guard !presentations.isEmpty || previewPresentation.state == .deferred else { return }
        findPanel.present(owner: view.window)
    }

    @objc private func findNext() { findPanel.perform(.next, viaKeyboard: true) }
    @objc private func findPrevious() { findPanel.perform(.previous, viaKeyboard: true) }

    private func applySearch() {
        if let match = searchState.currentMatch, let row = searchOffsets.lastIndex(where: { $0 <= match.location }) {
            caretRow = row
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        }
        tableView.reloadData()
    }

    private func searchRanges(row: Int, active: Bool) -> [NSRange] {
        let lineRange = NSRange(location: searchOffsets[row], length: presentations[row].line.text.utf16.count)
        let matches = active ? searchState.currentMatch.map { [$0] } ?? [] : searchState.highlightedRanges
        return matches.compactMap {
            let range = NSIntersectionRange($0, lineRange)
            return range.length > 0 ? NSRange(location: range.location - lineRange.location, length: range.length) : nil
        }
    }

    private func diffAppearanceMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Diff appearance", action: nil, keyEquivalent: "")
        AppKitFactory.setMenuImage("Diff", for: item)
        let submenu = NSMenu(title: "Diff appearance")
        submenu.autoenablesItems = false
        for (title, appearance) in [("Patch", DiffDisplayAppearance.patch), ("Git word diff", .gitWordDiff), ("Difftastic", .difftastic)] {
            let choice = NSMenuItem(title: title, action: #selector(selectDiffAppearance(_:)), keyEquivalent: "")
            choice.target = self
            choice.representedObject = appearance.rawValue
            AppKitFactory.setMenuImage(appearance == .patch ? "Diff" : appearance == .gitWordDiff ? "EditColor" : "Difftastic", for: choice, adaptLightness: appearance == .gitWordDiff)
            if appearance != .patch { AppKitFactory.setMenuShortcut(appearance == .gitWordDiff ? "viewer.wordDiff" : "viewer.difftastic", for: choice) }
            choice.state = preferences.diffAppearance == appearance ? .on : .off
            choice.isEnabled = appearance != .difftastic || difftasticEnabled == true
            if appearance == .difftastic, difftasticEnabled == nil {
                Task { @MainActor [weak self, weak choice] in
                    let enabled = await self?.difftasticAvailability?() ?? false
                    self?.difftasticEnabled = enabled
                    choice?.isEnabled = enabled
                }
            }
            submenu.addItem(choice)
        }
        item.submenu = submenu
        return item
    }

    @objc private func selectDiffAppearance(_ sender: NSMenuItem) {
        guard let appearance = (sender.representedObject as? String).flatMap(DiffDisplayAppearance.init(rawValue:)) else { return }
        if appearance == .patch {
            setAppearance(.patch)
        } else {
            _ = toggleAppearance(appearance)
        }
    }

    private func toggleAppearance(_ appearance: DiffDisplayAppearance) -> Bool {
        guard isDiffAppearanceVisible else { return false }
        if appearance == .difftastic {
            guard let difftasticEnabled else {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    difftasticEnabled = await difftasticAvailability?() ?? false
                    if difftasticEnabled == true { setAppearance(preferences.diffAppearance == .difftastic ? .patch : .difftastic) }
                }
                return true
            }
            guard difftasticEnabled else { return false }
        }
        setAppearance(preferences.diffAppearance == appearance ? .patch : appearance)
        return true
    }

    private func setAppearance(_ appearance: DiffDisplayAppearance) {
        preferences.diffAppearance = appearance
        persistPreferences(reloadDiff: true)
    }

    private var selectedChangeLineIDs: Set<String> {
        Set(tableView.selectedRowIndexes.compactMap { row -> String? in
            guard presentations.indices.contains(row) else { return nil }
            let line = presentations[row].line
            return line.kind == .addition || line.kind == .deletion ? line.id : nil
        })
    }

    @objc private func stageSelectedLines() { _ = performLinePatch(reset: false, unstage: false) }
    @objc private func unstageSelectedLines() { _ = performLinePatch(reset: false, unstage: true) }
    @objc private func resetSelectedLines() { _ = performLinePatch(reset: true, unstage: false) }

    private func performLinePatch(reset: Bool, unstage: Bool) -> Bool {
        guard canPatchLines, let currentFile, let currentDiff else { return false }
        if unstage != (selectionScope == .index) && !reset { return false }
        let ids = selectedChangeLineIDs
        guard !ids.isEmpty else { return true }
        let kind: FileStatusLinePatchKind = switch (selectionScope, reset) {
        case (.workingTree, false): .stage
        case (.workingTree, true): .resetWorkTree
        case (.index, false): .unstage
        case (.index, true): .resetIndex
        case (.revision, false): .applyToWorkTree
        case (.revision, true): .revertToWorkTree
        }
        guard reset, selectionScope != .revision, let window = view.window else {
            linePatchPending = true
            onLinePatch?(kind, currentFile, currentDiff, ids)
            return true
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset changes"
        alert.informativeText = "Are you sure you want to reset the changes to the selected lines?"
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn, canPatchLines, self.currentFile == currentFile, self.currentDiff == currentDiff else { return }
            linePatchPending = true
            onLinePatch?(kind, currentFile, currentDiff, ids)
        }
        return true
    }

    private func highlightOccurrences(of term: String, row: Int) {
        occurrences.term = term
        occurrences.row = row
        occurrences.column = presentations.indices.contains(row)
            ? FileViewerOccurrences.ranges(of: term, in: presentations[row].line.text).first?.location ?? -1
            : -1
        reloadRenderedLines()
    }

    @objc private func selectWordOccurrences() {
        let row = tableView.clickedRow
        guard presentations.indices.contains(row),
              let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? DiffLineCellView,
              let event = NSApp.currentEvent else { return }
        let index = cell.characterIndex(at: cell.convert(event.locationInWindow, from: nil))
        guard let word = FileViewerOccurrences.word(in: presentations[row].line.text, at: index) else { return }
        caretRow = row
        occurrences.term = word
        occurrences.row = row
        occurrences.column = FileViewerOccurrences.ranges(of: word, in: presentations[row].line.text).last(where: { $0.location <= index })?.location ?? index
        reloadRenderedLines()
    }

    private func moveToOccurrence(forward: Bool) {
        if occurrences.row < 0 { occurrences.row = caretRow }
        guard occurrences.next(in: presentations.map(\.line.text), forward: forward) else { return }
        caretRow = occurrences.row
        tableView.selectRowIndexes(IndexSet(integer: occurrences.row), byExtendingSelection: false)
        tableView.scrollRowToVisible(occurrences.row)
    }

    var highlightedOccurrenceTerm: String { occurrences.term }
    var occurrenceCaret: (row: Int, column: Int) { (occurrences.row, occurrences.column) }

    @objc private func goToLine() {
        guard let row = FileViewerNavigationDialogs.goToLine(lines: presentations.map(\.line)) else { return }
        caretRow = row
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    @objc private func openFile() { performFileCommand("file.open.local") }
    @objc private func showInFinder() { performFileCommand("file.showFinder") }
    @objc private func openWithDifftool() { performFileCommand("file.difftool") }

    private func performFileCommand(_ identifier: String) {
        guard let currentFile else { return }
        onFileCommand?(identifier, currentFile)
    }

    @objc private func applySelectedHunk(_ sender: NSMenuItem) {
        guard let currentFile, let currentDiff, let lineID = currentHunkLineID() else { return }
        let direction: RepositoryHunkDirection = selectionScope == .index ? .unstage : .stage
        onHunkMutation?(RepositoryHunkSelection(file: currentFile, diff: currentDiff, lineID: lineID, direction: direction))
    }

    private func currentHunkLineID() -> String? {
        let clicked = tableView.clickedRow
        let row = clicked >= 0 ? clicked : tableView.selectedRow
        guard row >= 0, row < presentations.count else { return nil }
        let line = presentations[row].line
        guard line.kind == .hunk || line.kind == .context || line.kind == .addition || line.kind == .deletion else { return nil }
        return line.id
    }
}

struct DiffLinePresentation {
    struct InlineChange {
        let location: Int
        let length: Int
    }

    let line: DiffLine
    let inlineRanges: DiffInlineRanges?
    var inlineChange: InlineChange? {
        guard let range = inlineRanges?.changed.first else { return nil }
        return InlineChange(location: range.location, length: range.length)
    }

    static func build(from lines: [DiffLine], appearance: DiffDisplayAppearance = .patch) -> [DiffLinePresentation] {
        let ranges = appearance == .patch ? DiffInlineAnalysis.analyze(lines) : [:]
        return lines.enumerated().map { DiffLinePresentation(line: $0.element, inlineRanges: ranges[$0.offset]) }
    }
}

struct DiffGutterMetrics: Equatable {
    static let leadingMargin: CGFloat = 4
    static let empty = DiffGutterMetrics(numberColumnWidth: 19)

    let numberColumnWidth: CGFloat

    init(numberColumnWidth: CGFloat) {
        self.numberColumnWidth = numberColumnWidth
    }

    init(lines: [DiffLine], font: NSFont = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)) {
        let maximum = lines
            .flatMap { [$0.oldLineNumber, $0.newLineNumber] }
            .compactMap { $0 }
            .max() ?? 0
        let digits = max(1, String(maximum).count)
        let digitWidth = ceil(("0" as NSString).size(withAttributes: [.font: font]).width)
        numberColumnWidth = CGFloat(digits + 1) * digitWidth
    }

    var oldColumnWidth: CGFloat { Self.leadingMargin + numberColumnWidth }
    var newColumnWidth: CGFloat { numberColumnWidth }
    var totalWidth: CGFloat { oldColumnWidth + newColumnWidth }
}

@MainActor
enum DiffTextColors {
    private static let names = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]
    private static let fallbacks: [NSColor] = [.black, .systemRed, .systemGreen, .systemYellow, .systemBlue, .systemPurple, .systemTeal, .white]

    static func color(_ color: DiffTextColor, foreground: Bool) -> NSColor {
        switch color {
        case .text(let dim):
            return dim ? .secondaryLabelColor : .labelColor
        case .rgb(let red, let green, let blue):
            return NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        case .palette(let id, let dim):
            let base: NSColor
            switch id {
            case 0..<16:
                let fallback = foreground ? fallbacks[id & 7] : fallbacks[id & 7].withAlphaComponent(id >= 8 ? 0.35 : 0.2)
                base = ApplicationColors.color("AnsiTerminal\(names[id & 7])\(foreground ? "Fore" : "Back")\(id >= 8 ? "Bold" : "Normal")", fallback: fallback)
            case 16..<232:
                let index = id - 16
                base = NSColor(srgbRed: CGFloat(index / 36 * 51) / 255, green: CGFloat(index % 36 / 6 * 51) / 255, blue: CGFloat(index % 6 * 51) / 255, alpha: 1)
            default:
                let level = CGFloat((min(id, 255) - 232) * 11) / 255
                base = NSColor(srgbRed: level, green: level, blue: level, alpha: 1)
            }
            guard dim else { return base }
            return base.blended(withFraction: 0.5, of: ApplicationColors.color("EditorBackground", fallback: .textBackgroundColor)) ?? base
        }
    }

    static func contrastingText(for background: NSColor) -> NSColor {
        let editor = ApplicationColors.color("EditorBackground", fallback: .textBackgroundColor)
        return NSColor(name: nil) { appearance in
            var result = NSColor.labelColor
            appearance.performAsCurrentDrawingAppearance {
                result = contrastingText(over: background, editor: editor)
            }
            return result
        }
    }

    static func contrastingText(over background: NSColor, editor: NSColor) -> NSColor {
        guard let rgb = background.usingColorSpace(.sRGB) else { return .labelColor }
        let base = editor.usingColorSpace(.sRGB)
        let alpha = rgb.alphaComponent
        func composite(_ top: CGFloat, _ bottom: CGFloat?) -> CGFloat { top * alpha + (bottom ?? 1) * (1 - alpha) }
        let luminance = 0.299 * composite(rgb.redComponent, base?.redComponent)
            + 0.587 * composite(rgb.greenComponent, base?.greenComponent)
            + 0.114 * composite(rgb.blueComponent, base?.blueComponent)
        return luminance > 0.5 ? .black : .white
    }

    static func apply(_ styles: [DiffTextStyle], to text: NSMutableAttributedString) {
        let length = text.length
        for style in styles {
            let location = min(max(0, style.location), length)
            let range = NSRange(location: location, length: min(max(0, style.length), length - location))
            guard range.length > 0 else { continue }
            let background = style.background.map { color($0, foreground: false) }
            if let background { text.addAttribute(.backgroundColor, value: background, range: range) }
            if let foreground = style.foreground {
                text.addAttribute(.foregroundColor, value: color(foreground, foreground: true), range: range)
            } else if let background {
                text.addAttribute(.foregroundColor, value: contrastingText(for: background), range: range)
            }
        }
    }
}

struct FileViewerOccurrences {
    var term = ""
    var row = -1
    var column = -1

    static func ranges(of term: String, in text: String) -> [NSRange] {
        guard !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let source = text as NSString
        var result: [NSRange] = []
        var searchRange = NSRange(location: 0, length: source.length)
        while searchRange.length > 0 {
            let found = source.range(of: term, options: .caseInsensitive, range: searchRange)
            guard found.location != NSNotFound else { break }
            result.append(found)
            let next = found.location + 1
            searchRange = NSRange(location: next, length: source.length - next)
        }
        return result
    }

    @MainActor static func highlight(_ term: String, in text: NSMutableAttributedString) {
        let color = ApplicationColors.color("HighlightAllOccurences", fallback: NSColor.systemYellow.withAlphaComponent(0.35))
        for range in ranges(of: term, in: text.string) {
            text.addAttribute(.backgroundColor, value: color, range: range)
            text.addAttribute(.foregroundColor, value: DiffTextColors.contrastingText(for: color), range: range)
        }
    }

    mutating func next(in lines: [String], forward: Bool) -> Bool {
        guard !term.isEmpty, !lines.isEmpty else { return false }
        if forward {
            var index = max(row, 0)
            while index < lines.count {
                let after = index == row ? column : -1
                if let match = Self.ranges(of: term, in: lines[index]).first(where: { $0.location > after }) {
                    row = index
                    column = match.location
                    return true
                }
                index += 1
            }
        } else {
            var index = row < 0 ? lines.count - 1 : min(row, lines.count - 1)
            while index >= 0 {
                let before = index == row ? column : Int.max
                if let match = Self.ranges(of: term, in: lines[index]).last(where: { $0.location < before }) {
                    row = index
                    column = match.location
                    return true
                }
                index -= 1
            }
        }
        return false
    }

    static func word(in text: String, at index: Int) -> String? {
        let characters = Array(text.utf16)
        guard !characters.isEmpty else { return nil }
        let position = min(max(0, index), characters.count - 1)
        func isWord(_ unit: UInt16) -> Bool {
            guard let scalar = Unicode.Scalar(unit) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
        }
        guard isWord(characters[position]) else { return nil }
        var start = position
        var end = position
        while start > 0, isWord(characters[start - 1]) { start -= 1 }
        while end + 1 < characters.count, isWord(characters[end + 1]) { end += 1 }
        return (text as NSString).substring(with: NSRange(location: start, length: end - start + 1))
    }
}

final class DiffLineCellView: NSTableCellView {
    private let oldNumber = NSTextField(labelWithString: "")
    private let newNumber = NSTextField(labelWithString: "")
    private let prefix = NSTextField(labelWithString: "")
    private let content = NSTextField(labelWithString: "")
    private var oldNumberWidthConstraint: NSLayoutConstraint!
    private var newNumberWidthConstraint: NSLayoutConstraint!
    private var presentation: DiffLinePresentation?
    private var gutterMetrics = DiffGutterMetrics.empty
    private var diffAppearance: DiffDisplayAppearance = .patch
    private let prefixWidth: CGFloat = 8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let stack = NSStackView(views: [oldNumber, newNumber, prefix, content])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        [oldNumber, newNumber].forEach {
            $0.font = AppSettingsStore.shared.diffGutterFont
            $0.textColor = .tertiaryLabelColor
            $0.alignment = .left
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        oldNumberWidthConstraint = oldNumber.widthAnchor.constraint(equalToConstant: gutterMetrics.numberColumnWidth)
        newNumberWidthConstraint = newNumber.widthAnchor.constraint(equalToConstant: gutterMetrics.numberColumnWidth)
        oldNumberWidthConstraint.isActive = true
        newNumberWidthConstraint.isActive = true
        prefix.font = AppSettingsStore.shared.codeFont
        prefix.alignment = .center
        prefix.translatesAutoresizingMaskIntoConstraints = false
        prefix.widthAnchor.constraint(equalToConstant: prefixWidth).isActive = true
        content.font = AppSettingsStore.shared.codeFont
        content.lineBreakMode = .byClipping
        content.maximumNumberOfLines = 1
        content.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DiffGutterMetrics.leadingMargin),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let presentation else { return }

        let gutterWidth = gutterMetrics.totalWidth
        ApplicationColors.color("LineNumberBackground", fallback: .clear).setFill()
        NSRect(x: 0, y: 0, width: min(gutterWidth, bounds.width), height: bounds.height).fill()
        let baseColor: NSColor?
        switch presentation.line.kind {
        case .addition:
            baseColor = ApplicationColors.color("AnsiTerminalGreenBackNormal", fallback: NSColor.systemGreen.withAlphaComponent(0.13))
        case .deletion:
            baseColor = ApplicationColors.color("AnsiTerminalRedBackNormal", fallback: NSColor.systemRed.withAlphaComponent(0.13))
        case .hunk:
            baseColor = ApplicationColors.color("DiffSection", fallback: NSColor.systemBlue.withAlphaComponent(0.10))
        case .header, .context:
            baseColor = nil
        }

        if let baseColor {
            baseColor.setFill()
            NSRect(x: 0, y: 0, width: min(gutterWidth, bounds.width), height: bounds.height).fill()

            if diffAppearance == .patch, presentation.line.styles.isEmpty, presentation.line.kind == .addition || presentation.line.kind == .deletion {
                let font = AppSettingsStore.shared.codeFont
                let textWidth = ceil((presentation.line.text as NSString).size(withAttributes: [.font: font]).width)
                let width = min(prefixWidth + textWidth + 1, max(0, bounds.width - gutterWidth))
                NSRect(x: gutterWidth, y: 0, width: width, height: bounds.height).fill()
            }
        }

        for change in (presentation.line.styles.isEmpty ? presentation.inlineRanges?.identical ?? [] : []) + (presentation.inlineRanges?.anchors ?? []).map({ NSRange(location: $0, length: 0) }) {
            let string = presentation.line.text as NSString
            let safeLocation = min(max(0, change.location), string.length)
            let safeLength = min(max(0, change.length), string.length - safeLocation)
            let font = AppSettingsStore.shared.codeFont
            let leadingText = string.substring(with: NSRange(location: 0, length: safeLocation))
            let changedText = string.substring(with: NSRange(location: safeLocation, length: safeLength))
            let leadingWidth = ceil((leadingText as NSString).size(withAttributes: [.font: font]).width)
            let changedWidth = max(2, ceil((changedText as NSString).size(withAttributes: [.font: font]).width))
            let background = ApplicationColors.color("EditorBackground", fallback: .textBackgroundColor)
            let emphasis = safeLength == 0 ? (presentation.line.kind == .addition ? NSColor.systemRed : NSColor.systemGreen)
                : (baseColor?.blended(withFraction: 0.75, of: background) ?? background)
            emphasis.setFill()
            NSRect(
                x: gutterWidth + prefixWidth + leadingWidth,
                y: 0,
                width: min(changedWidth, max(0, bounds.width - gutterWidth - prefixWidth - leadingWidth)),
                height: bounds.height
            ).fill()
        }

        if let x = Self.verticalRulerX(position: AppSettingsStore.shared.fileViewerPreferences.verticalRulerPosition,
                                       textOrigin: gutterWidth + prefixWidth, font: AppSettingsStore.shared.codeFont), x < bounds.width {
            NSColor.separatorColor.setFill()
            NSRect(x: floor(x), y: 0, width: 1, height: bounds.height).fill()
        }
    }

    static func verticalRulerX(position: Int, textOrigin: CGFloat, font: NSFont) -> CGFloat? {
        guard position > 0 else { return nil }
        let characterWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        return textOrigin + CGFloat(position - 1) * characterWidth
    }

    func apply(
        presentation: DiffLinePresentation,
        gutterMetrics: DiffGutterMetrics,
        showsNonPrintingCharacters: Bool,
        showsSyntaxHighlighting: Bool,
        filePath: String? = nil,
        appearance: DiffDisplayAppearance = .patch,
        highlightTerm: String = "",
        openSpan: Int? = nil,
        searchRanges: [NSRange] = [],
        activeSearchRanges: [NSRange] = []
    ) {
        self.presentation = presentation
        self.gutterMetrics = gutterMetrics
        self.diffAppearance = appearance
        oldNumberWidthConstraint.constant = gutterMetrics.numberColumnWidth
        newNumberWidthConstraint.constant = gutterMetrics.numberColumnWidth
        let line = presentation.line
        oldNumber.stringValue = line.oldLineNumber.map(String.init) ?? ""
        newNumber.stringValue = line.newLineNumber.map(String.init) ?? ""
        let displayText = showsNonPrintingCharacters
            ? FileViewerWhitespace.patchLine(line.text, glyph: AppSettingsStore.shared.fontPreferences.showEolMarkerAsGlyph)
            : line.text
        let attributed = NSMutableAttributedString(attributedString: DiffSyntaxHighlighter.attributedText(
            for: line,
            displayText: displayText,
            enabled: showsSyntaxHighlighting && appearance != .difftastic,
            filePath: filePath,
            openSpan: openSpan
        ))
        DiffTextColors.apply(line.styles, to: attributed)
        for change in presentation.inlineRanges?.identical ?? [] where appearance == .patch && !line.styles.isEmpty {
            let location = min(max(0, change.location), attributed.length)
            let length = min(max(0, change.length), attributed.length - location)
            let reverse = AppSettingsStore.shared.fileViewerPreferences.reverseGitColoring
            let color = line.kind == .addition
                ? ApplicationColors.color(reverse ? "AnsiTerminalGreenBackNormal" : "AnsiTerminalGreenForeNormal", fallback: .systemGreen)
                : ApplicationColors.color(reverse ? "AnsiTerminalRedBackNormal" : "AnsiTerminalRedForeNormal", fallback: .systemRed)
            let dimmed = color.blended(withFraction: reverse ? 0.75 : 0.5, of: ApplicationColors.color("EditorBackground", fallback: .textBackgroundColor)) ?? color
            attributed.addAttribute(reverse ? .backgroundColor : .foregroundColor, value: dimmed, range: NSRange(location: location, length: length))
        }
        FileViewerOccurrences.highlight(highlightTerm, in: attributed)
        for range in searchRanges where NSMaxRange(range) <= attributed.length {
            attributed.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.5), range: range)
        }
        for range in activeSearchRanges where NSMaxRange(range) <= attributed.length {
            attributed.addAttribute(.backgroundColor, value: NSColor.systemOrange.withAlphaComponent(0.6), range: range)
            attributed.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        }
        content.attributedStringValue = attributed
        switch line.kind {
        case .addition:
            prefix.stringValue = "+"
            prefix.textColor = ApplicationColors.color("AnsiTerminalGreenForeNormal", fallback: .systemGreen)
        case .deletion:
            prefix.stringValue = "−"
            prefix.textColor = ApplicationColors.color("AnsiTerminalRedForeNormal", fallback: .systemRed)
        case .hunk:
            prefix.stringValue = ""
        case .header:
            prefix.stringValue = ""
        case .context:
            prefix.stringValue = " "
        }
        if let value = line.diffPrefix { prefix.stringValue = value }
        if diffAppearance != .patch { prefix.stringValue = "" }
        needsDisplay = true
    }

    func characterIndex(at point: NSPoint) -> Int {
        let local = convert(point, to: content)
        let text = content.attributedStringValue
        guard text.length > 0, local.x > 0 else { return 0 }
        var low = 0
        var high = text.length
        while low < high {
            let middle = (low + high) / 2
            if text.attributedSubstring(from: NSRange(location: 0, length: middle + 1)).size().width <= local.x {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return min(low, text.length - 1)
    }
}

enum FileViewerWhitespace {
    static func text(_ text: String, glyph: Bool) -> String {
        var result = ""
        for character in text {
            switch character {
            case "\r\n": result += (glyph ? "¶" : "\\r\\n") + "\r\n"
            case "\n": result += (glyph ? "¶" : "\\n") + "\n"
            case "\r": result += (glyph ? "¶" : "\\r") + "\r"
            case "\t": result += "→"
            case " ": result += "·"
            default: result.append(character)
            }
        }
        return result
    }

    static func patchLine(_ line: String, glyph: Bool) -> String {
        text(line, glyph: glyph) + (glyph ? "¶" : "\\n")
    }
}

@MainActor enum DiffSyntaxHighlighter {
    private static var font: NSFont { AppSettingsStore.shared.codeFont }

    static func color(for kind: FileViewerSyntaxTokenKind) -> NSColor {
        switch kind {
        case .comment: .systemGreen
        case .string: .systemRed
        case .keyword: .systemBlue
        case .number: .systemPurple
        }
    }

    static func attributedText(
        for line: DiffLine,
        displayText: String,
        enabled: Bool,
        filePath: String?,
        openSpan: Int? = nil
    ) -> NSAttributedString {
        let baseColor: NSColor
        switch line.kind {
        case .header:
            baseColor = .secondaryLabelColor
        case .hunk:
            baseColor = .systemBlue
        case .context, .addition, .deletion:
            baseColor = ApplicationColors.color("WindowText", fallback: .labelColor)
        }

        let result = NSMutableAttributedString(
            string: displayText,
            attributes: [.font: font, .foregroundColor: baseColor]
        )
        guard enabled, let mode = FileViewerSyntaxRegistry.mode(for: filePath),
              line.kind == .context || line.kind == .addition || line.kind == .deletion else {
            return result
        }
        let length = (displayText as NSString).length
        for token in FileViewerSyntaxLexer.tokens(displayText, mode: mode, openSpan: openSpan).tokens where NSMaxRange(token.range) <= length {
            result.addAttribute(.foregroundColor, value: color(for: token.kind), range: token.range)
        }
        return result
    }

    static func lineStates(_ lines: [DiffLine], filePath: String?) -> [Int?] {
        guard let mode = FileViewerSyntaxRegistry.mode(for: filePath) else { return Array(repeating: nil, count: lines.count) }
        var state: Int?
        return lines.map { line in
            guard line.kind == .context || line.kind == .addition || line.kind == .deletion else {
                state = nil
                return nil
            }
            let start = state
            state = FileViewerSyntaxLexer.tokens(line.text, mode: mode, openSpan: state).openSpan
            return start
        }
    }
}

final class DiffViewerToolbar: NSVisualEffectView {
    enum Mode { case diff, fixedDiff, text }
    var onAction: ((String, NSControl.StateValue) -> Void)?
    private var buttons: [String: NSButton] = [:]
    private let encoding = NSPopUpButton()
    private var encodingWidth: NSLayoutConstraint!
    private var mode = Mode.diff
    private let navigationSeparator = AppKitFactory.separator()
    private let contextSeparator = AppKitFactory.separator()

    convenience init(showsNonPrintingCharacters: Bool, showsSyntaxHighlighting: Bool) {
        var preferences = FileViewerPreferences()
        preferences.showsNonPrintingCharacters = showsNonPrintingCharacters
        preferences.showsSyntaxHighlighting = showsSyntaxHighlighting
        self.init(preferences: preferences)
    }

    init(preferences: FileViewerPreferences) {
        super.init(frame: .zero)
        material = .headerView
        blendingMode = .withinWindow
        state = .active
        isHidden = true

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        @discardableResult
        func addButton(_ image: String, _ tooltip: String, toggleState: NSControl.StateValue? = nil) -> NSButton {
            let button = AppKitFactory.resourceButton(
                image,
                tooltip: tooltip,
                isTemplate: toggleState != nil,
                target: self,
                action: #selector(performAction(_:))
            )
            if let toggleState {
                button.setButtonType(.pushOnPushOff)
                button.state = toggleState
            }
            buttons[tooltip] = button
            stack.addArrangedSubview(button)
            return button
        }

        addButton("ArrowDown", "Next change")
        addButton("ArrowUp", "Previous change")
        stack.addArrangedSubview(navigationSeparator)
        addButton("NumberOfLinesIncrease", "Increase the number of lines of context")
        addButton("NumberOfLinesDecrease", "Decrease the number of lines of context")
        stack.addArrangedSubview(contextSeparator)
        addButton("ShowEntireFile", "Show entire file", toggleState: preferences.showsEntireFile ? .on : .off)
        addButton("ShowWhitespace", "Show nonprinting characters", toggleState: preferences.showsNonPrintingCharacters ? .on : .off)
        addButton("SyntaxHighlighting", "Show syntax highlighting", toggleState: preferences.showsSyntaxHighlighting ? .on : .off)
        addButton("WhitespaceIgnoreEol", "Ignore whitespace changes at end of line", toggleState: preferences.whitespace != .none ? .on : .off)
        addButton("WhitespaceIgnore", "Ignore changes in amount of whitespace", toggleState: [.changes, .all].contains(preferences.whitespace) ? .on : .off)
        addButton("WhitespaceIgnoreAll", "Ignore all whitespace changes", toggleState: preferences.whitespace == .all ? .on : .off)
        addButton("File", "Treat all files as text", toggleState: preferences.treatsAllFilesAsText ? .on : .off)

        encoding.controlSize = .small
        encoding.font = AppSettingsStore.shared.applicationFont(size: 11)
        AppSettingsStore.shared.viewerEncodings(including: preferences.textEncoding).forEach { value in
            encoding.addItem(withTitle: value.title)
            encoding.lastItem?.representedObject = value.rawValue
        }
        encoding.selectItem(at: encoding.itemArray.firstIndex { ($0.representedObject as? String) == preferences.textEncoding.rawValue } ?? 0)
        encoding.toolTip = "Encoding"
        encoding.target = self
        encoding.action = #selector(performPopUpAction(_:))
        encoding.translatesAutoresizingMaskIntoConstraints = false
        encodingWidth = encoding.widthAnchor.constraint(equalToConstant: 110)
        encodingWidth.isActive = true
        stack.addArrangedSubview(encoding)
        addButton("Settings", "Settings")

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(for mode: Mode) {
        self.mode = mode
        let visible: Set<String> = switch mode {
        case .diff: Set(buttons.keys)
        case .fixedDiff: ["Next change", "Previous change", "Show nonprinting characters", "Show syntax highlighting", "Settings"]
        case .text: ["Show nonprinting characters", "Settings"]
        }
        for (name, button) in buttons { button.isHidden = !visible.contains(name) }
        navigationSeparator.isHidden = mode == .text
        contextSeparator.isHidden = mode != .diff
        updateEncodingWidth()
    }

    private func updateEncodingWidth() {
        let width = (encoding.title as NSString).size(withAttributes: [.font: encoding.font ?? NSFont.systemFont(ofSize: 11)]).width
        encodingWidth.constant = mode == .diff ? 110 : max(110, ceil(width) + 32)
    }

    func apply(preferences: FileViewerPreferences, resolvedEncoding: String.Encoding? = nil) {
        buttons["Show entire file"]?.state = preferences.showsEntireFile ? .on : .off
        buttons["Show nonprinting characters"]?.state = preferences.showsNonPrintingCharacters ? .on : .off
        buttons["Show syntax highlighting"]?.state = preferences.showsSyntaxHighlighting ? .on : .off
        buttons["Ignore whitespace changes at end of line"]?.state = preferences.whitespace != .none ? .on : .off
        buttons["Ignore changes in amount of whitespace"]?.state = [.changes, .all].contains(preferences.whitespace) ? .on : .off
        buttons["Ignore all whitespace changes"]?.state = preferences.whitespace == .all ? .on : .off
        buttons["Treat all files as text"]?.state = preferences.treatsAllFilesAsText ? .on : .off
        encoding.removeAllItems()
        for value in AppSettingsStore.shared.viewerEncodings(including: preferences.textEncoding) {
            encoding.addItem(withTitle: value.title)
            encoding.lastItem?.representedObject = value.rawValue
        }
        encoding.selectItem(at: encoding.itemArray.firstIndex { ($0.representedObject as? String) == preferences.textEncoding.rawValue } ?? 0)
        if preferences.textEncoding == .automatic, let resolvedEncoding,
           let effective = RepositoryTextEncoding.allCases.first(where: { $0 != .automatic && $0.foundationEncoding == resolvedEncoding }) {
            encoding.selectedItem?.title = effective.title
        }
        updateEncodingWidth()
    }

    func install(in root: NSView) {
        translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(self)
        let leading = leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor)
        leading.priority = .init(240)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: root.topAnchor),
            trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -40),
            heightAnchor.constraint(equalToConstant: 23),
            leading
        ])
    }

    @objc private func performAction(_ sender: NSButton) {
        onAction?(sender.toolTip ?? "Diff option", sender.state)
    }

    @objc private func performPopUpAction(_ sender: NSPopUpButton) {
        onAction?("Encoding:\(sender.selectedItem?.representedObject as? String ?? RepositoryTextEncoding.automatic.rawValue)", .off)
    }
}

final class DiffTrackingView: NSView {
    var onPointerPresenceChanged: ((Bool) -> Void)?
    private var pointerTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onPointerPresenceChanged?(true)
    }

    override func mouseMoved(with event: NSEvent) {
        onPointerPresenceChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onPointerPresenceChanged?(false)
    }
}

enum FileViewerNavigationDialogs {
    static func maximumLine(in lines: [DiffLine]) -> Int {
        max(1, lines.flatMap { [$0.oldLineNumber, $0.newLineNumber].compactMap { $0 } }.max() ?? 1)
    }

    static func row(for line: Int, in lines: [DiffLine]) -> Int {
        lines.firstIndex { ($0.newLineNumber ?? 0) >= line } ?? 0
    }

    static func matchingRow(lines: [DiffLine], query: String, after caret: Int, forward: Bool = true) -> Int? {
        guard !lines.isEmpty, !query.isEmpty else { return nil }
        let origin = min(max(forward ? caret + 1 : (caret < 0 ? lines.count : caret), 0), lines.count)
        let order = forward ? Array(origin..<lines.count) + Array(0..<origin)
            : Array((0..<origin).reversed()) + Array((origin..<lines.count).reversed())
        return order.first {
            lines[$0].text.localizedCaseInsensitiveContains(query)
        }
    }

    static func goToLine(lines: [DiffLine]) -> Int? {
        let maximum = maximumLine(in: lines)
        guard let line = requestLine(maximum: maximum) else { return nil }
        return row(for: line, in: lines)
    }

    static func requestLine(maximum: Int) -> Int? {
        let input = FileViewerLineNumberInput(maximum: maximum)
        let alert = NSAlert()
        alert.messageText = "Go to line"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = input.view
        alert.window.initialFirstResponder = input.field
        input.field.selectText(nil)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return input.value
    }
}

final class FileViewerLineNumberInput: NSObject, NSTextFieldDelegate {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 52))
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 210, height: 24))
    let stepper = NSStepper(frame: NSRect(x: 216, y: 0, width: 19, height: 24))
    let maximum: Int

    init(maximum: Int) {
        self.maximum = max(1, maximum)
        super.init()
        let label = NSTextField(labelWithString: "Line number (1 - \(self.maximum)):")
        label.frame = NSRect(x: 0, y: 30, width: 240, height: 20)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.allowsFloats = false
        formatter.usesGroupingSeparator = false
        field.formatter = formatter
        field.integerValue = 1
        field.delegate = self
        stepper.minValue = 1
        stepper.maxValue = Double(self.maximum)
        stepper.integerValue = 1
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(step)
        for child in [label, field, stepper] { view.addSubview(child) }
    }

    var value: Int { min(max(field.integerValue, 1), maximum) }

    @objc private func step() { field.integerValue = stepper.integerValue }

    func controlTextDidEndEditing(_ notification: Notification) {
        field.integerValue = value
        stepper.integerValue = value
    }
}

final class RevisionFileContentViewController: NSViewController, NSMenuDelegate {
    var onBlame: (() -> Void)?
    var exporter: ((URL) async throws -> Void)?
    var onFileHistory: (() -> Void)?
    var canBlame = false
    private let pathLabel = NSTextField(labelWithString: "Select a file")
    private let metadataLabel = NSTextField(labelWithString: "")
    let textView = FileViewerTextView()
    let searchState = FileViewerSearchState()
    var loadNextSearchFile: ((FileViewerSearchState.Direction) async -> String?)? { didSet { findPanel.loadNext = loadNextSearchFile } }
    private lazy var findPanel = FileViewerFindPanel(state: searchState, caret: { [weak self] in
        self.map { NSMaxRange($0.textView.selectedRange()) } ?? 0
    }, changed: { [weak self] in self?.applySearch() })
    private let imageView = NSImageView()
    private let encodingButton = NSPopUpButton()
    private var revisionName = ""
    private var content: RepositoryFileContent?
    let previewPresentation = FilePreviewPresentation<RepositoryFileContent>()
    private var appliedEncoding: RepositoryTextEncoding = .automatic
    var onEncodingChanged: (() -> Void)?
    var selectedEncoding: RepositoryTextEncoding {
        AppSettingsStore.shared.fileViewerPreferences.textEncoding
    }

    override func loadView() {
        let root = NSView()
        let toolbar = AppKitFactory.toolbarBackground()
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        reloadEncodingChoices()
        appliedEncoding = selectedEncoding
        NotificationCenter.default.addObserver(self, selector: #selector(settingsApplied), name: .fileViewerSettingsApplied, object: AppSettingsStore.shared)
        encodingButton.controlSize = .small
        encodingButton.target = self
        encodingButton.action = #selector(changeEncoding(_:))
        let header = NSStackView(views: [pathLabel, metadataLabel, encodingButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = AppSettingsStore.shared.applicationFont(size: 11, weight: .semibold)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        metadataLabel.font = AppSettingsStore.shared.fontPreferences.font(.monospace, fallback: .monospacedDigitSystemFont(ofSize: 10, weight: .regular))
        metadataLabel.textColor = .secondaryLabelColor
        metadataLabel.lineBreakMode = .byTruncatingTail
        metadataLabel.setContentCompressionResistancePriority(.init(199), for: .horizontal)
        encodingButton.setContentCompressionResistancePriority(.init(198), for: .horizontal)
        toolbar.addSubview(header)

        textView.onReadOnlyFind = { [weak self] shortcut in
            guard let self, content != nil, content?.kind != .image else { return }
            if shortcut == .find { findText() }
            else {
                findPanel.perform(shortcut == .findPrevious ? .previous : .next, viaKeyboard: true)
            }
        }
        textView.onGoToLine = { [weak self] in
            guard let self, content != nil, content?.kind != .image else { return }
            goToTextLine()
        }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = AppSettingsStore.shared.codeFont
        textView.textColor = .labelColor
        textView.backgroundColor = ApplicationColors.color("EditorBackground", fallback: .textBackgroundColor)
        textView.textContainerInset = NSSize(width: 8, height: 7)
        textView.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        let menu = NSMenu()
        menu.delegate = self
        textView.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = textView
        FileViewerLineNumberRuler.install(on: scroll, textView: textView)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.isHidden = true

        root.addSubview(toolbar)
        root.addSubview(scroll)
        root.addSubview(imageView)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 25),
            header.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 5),
            header.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -5),
            header.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            imageView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            imageView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            imageView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            imageView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8)
        ])
        previewPresentation.install(in: root)
        view = root
    }

    func applyRevision(_ commit: Commit) {
        revisionName = commit.shortID
    }

    func apply(file: RepositoryFileEntry?, selectedPath: String?) {
        _ = view
        previewPresentation.cancel()
        content = nil
        searchState.setText("")
        imageView.image = nil
        imageView.isHidden = true
        textView.enclosingScrollView?.isHidden = false
        guard let file else {
            pathLabel.stringValue = selectedPath ?? "Select a file"
            metadataLabel.stringValue = selectedPath == nil ? "" : "Folder at \(revisionName)"
            textView.string = selectedPath == nil ? "Select a file to view its contents." : "Folder \(selectedPath ?? "")"
            return
        }
        pathLabel.stringValue = file.path
        metadataLabel.stringValue = "\(file.byteCount) bytes   \(revisionName)"
        textView.string = file.content.isEmpty && (file.gitObjectID != nil || file.gitObjectType == "working-tree")
            ? "Loading file…"
            : file.content
        imageView.isHidden = true
        textView.enclosingScrollView?.isHidden = false
        textView.scrollToBeginningOfDocument(nil)
    }

    func apply(preview: FilePreview<RepositoryFileContent>, file: RepositoryFileEntry) {
        apply(file: file, selectedPath: file.path)
        textView.string = ""
        previewPresentation.present(preview, display: { [weak self] in
            guard let self else { return }
            apply(content: $0, revisionLabel: revisionName, confirmed: true)
        }, failure: { [weak self] in self?.apply(error: $0, selectedPath: file.path) })
    }

    func apply(content: RepositoryFileContent, file: RepositoryFileEntry) {
        apply(content: content, revisionLabel: revisionName)
    }

    func apply(content: RepositoryFileContent, revisionLabel: String, confirmed: Bool = false) {
        _ = view
        if !confirmed, content.kind != .image, content.text.utf16.count > FilePreview<RepositoryFileContent>.threshold {
            imageView.image = nil
            imageView.isHidden = true
            textView.enclosingScrollView?.isHidden = false
            pathLabel.stringValue = content.path
            metadataLabel.stringValue = "\(content.byteCount) bytes   \(revisionLabel)"
            textView.string = ""
            searchState.setText("")
            self.content = nil
            previewPresentation.present(.deferred(length: content.text.utf16.count, load: { content }), display: { [weak self] in
                self?.apply(content: $0, revisionLabel: revisionLabel, confirmed: true)
            }, failure: { [weak self] in self?.apply(error: $0, selectedPath: content.path) })
            return
        }
        previewPresentation.cancel()
        revisionName = revisionLabel
        self.content = content
        searchState.setText("")
        textView.normalizesCopyLineEndings = content.normalizesCopyLineEndings
        appliedEncoding = selectedEncoding
        reloadEncodingChoices()
        pathLabel.stringValue = content.path
        let encoding = content.encoding?.title ?? (content.kind == .image ? "Image" : "Binary")
        metadataLabel.stringValue = "\(content.byteCount) bytes   \(encoding)   \(revisionName)"
        switch content.kind {
        case .image:
            imageView.image = NSImage(data: content.data)
            imageView.isHidden = false
            textView.enclosingScrollView?.isHidden = true
        case .text, .binary, .missing:
            imageView.image = nil
            imageView.isHidden = true
            textView.enclosingScrollView?.isHidden = false
            let preferences = AppSettingsStore.shared.fileViewerPreferences
            let displayed = content.text
            textView.layoutManager?.showsInvisibleCharacters = preferences.showsNonPrintingCharacters
            let line = DiffLine(
                id: "file-content",
                oldLineNumber: nil,
                newLineNumber: nil,
                kind: .context,
                text: displayed
            )
            textView.textStorage?.setAttributedString(DiffSyntaxHighlighter.attributedText(
                for: line,
                displayText: displayed,
                enabled: preferences.showsSyntaxHighlighting && content.kind == .text,
                filePath: content.path
            ))
            searchState.setText(displayed)
            textView.scrollToBeginningOfDocument(nil)
        }
    }

    @objc private func findNext() { findPanel.perform(.next, viaKeyboard: true) }
    @objc private func findPrevious() { findPanel.perform(.previous, viaKeyboard: true) }

    private func applySearch() {
        let entire = NSRange(location: 0, length: textView.string.utf16.count)
        textView.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: entire)
        for range in searchState.highlightedRanges {
            textView.layoutManager?.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.5), forCharacterRange: range)
        }
        if let range = searchState.currentMatch {
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
        }
    }

    func apply(error: Error, selectedPath: String) {
        _ = view
        previewPresentation.cancel()
        searchState.setText("")
        content = nil
        pathLabel.stringValue = selectedPath
        metadataLabel.stringValue = "Unable to load"
        textView.string = error.localizedDescription
        imageView.isHidden = true
        textView.enclosingScrollView?.isHidden = false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        copy.target = textView
        copy.isEnabled = textView.selectedRange().length > 0
        copy.keyEquivalent = "c"
        copy.keyEquivalentModifierMask = .command
        menu.addItem(copy)
        menu.addItem(.separator())
        let nonPrinting = NSMenuItem(title: "Show nonprinting characters", action: #selector(toggleNonPrinting), keyEquivalent: "")
        nonPrinting.target = self
        nonPrinting.state = AppSettingsStore.shared.fileViewerPreferences.showsNonPrintingCharacters ? .on : .off
        AppKitFactory.setMenuImage("ShowWhitespace", for: nonPrinting, adaptLightness: true)
        menu.addItem(nonPrinting)
        let find = NSMenuItem(title: "Find…", action: #selector(findText), keyEquivalent: "f")
        find.keyEquivalentModifierMask = [.command]
        find.target = self
        find.isEnabled = (content != nil && content?.kind != .image && !textView.string.isEmpty) || previewPresentation.state == .deferred
        menu.addItem(find)
        AppKitFactory.setMenuImage("Preview", for: find)
        for (title, action) in [("Find next", #selector(findNext)), ("Find previous", #selector(findPrevious))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = content != nil && content?.kind != .image && !searchState.query.isEmpty
            let command: FileViewerShortcut = action == #selector(findPrevious) ? .findPrevious : .findNext
            AppKitFactory.setMenuShortcut("viewer." + command.rawValue, for: item)
            menu.addItem(item)
        }
        let go = NSMenuItem(title: "Go to line…", action: #selector(goToTextLine), keyEquivalent: "")
        go.target = self
        go.isEnabled = content != nil && content?.kind != .image
        AppKitFactory.setMenuShortcut("viewer.goToLine", for: go)
        menu.addItem(go)
    }

    @objc private func toggleNonPrinting() {
        var preferences = AppSettingsStore.shared.fileViewerPreferences
        preferences.showsNonPrintingCharacters.toggle()
        AppSettingsStore.shared.updateFileViewerPreferences(preferences)
        textView.layoutManager?.showsInvisibleCharacters = preferences.showsNonPrintingCharacters
        textView.needsDisplay = true
    }

    @objc private func goToTextLine() {
        let starts = FileViewerTextLines.starts(in: textView.string)
        guard let line = FileViewerNavigationDialogs.requestLine(maximum: starts.count) else { return }
        let range = NSRange(location: starts[line - 1], length: 0)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
    }

    private func reloadEncodingChoices() {
        encodingButton.removeAllItems()
        AppSettingsStore.shared.viewerEncodings(including: selectedEncoding).forEach { encoding in
            encodingButton.addItem(withTitle: encoding.title)
            encodingButton.lastItem?.representedObject = encoding.rawValue
        }
        encodingButton.selectItem(at: encodingButton.itemArray.firstIndex { ($0.representedObject as? String) == selectedEncoding.rawValue } ?? 0)
        if selectedEncoding == .automatic, let effective = content?.encoding { encodingButton.selectedItem?.title = effective.title }
    }

    @objc private func showBlame() { onBlame?() }
    @objc private func showFileHistory() { onFileHistory?() }

    @objc private func settingsApplied() {
        reloadEncodingChoices()
        textView.backgroundColor = ApplicationColors.color("EditorBackground", fallback: .textBackgroundColor)
        guard appliedEncoding == selectedEncoding else {
            appliedEncoding = selectedEncoding
            onEncodingChanged?()
            return
        }
        guard let content else { return }
        let selection = textView.selectedRange()
        let origin = textView.enclosingScrollView?.contentView.bounds.origin
        apply(content: content, revisionLabel: revisionName)
        let length = (textView.string as NSString).length
        if selection.location <= length {
            textView.setSelectedRange(NSRange(location: selection.location, length: min(selection.length, length - selection.location)))
        }
        if let origin, let scroll = textView.enclosingScrollView {
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    @objc private func changeEncoding(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let encoding = RepositoryTextEncoding(rawValue: raw) else { return }
        var preferences = AppSettingsStore.shared.fileViewerPreferences
        preferences.textEncoding = encoding
        AppSettingsStore.shared.updateFileViewerPreferences(preferences)
        onEncodingChanged?()
    }

    @objc private func findText() {
        guard (content != nil && content?.kind != .image) || previewPresentation.state == .deferred else { return }
        findPanel.present(owner: view.window, selection: textView.selectedRange())
    }

    @objc private func saveAs() {
        guard let content else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = URL(fileURLWithPath: content.path).lastPathComponent
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let exporter {
            Task { @MainActor in
                do { try await exporter(url) } catch { BrowserCommandCenter.perform(.showStatus(error.localizedDescription)) }
            }
            return
        }
        do {
            try content.data.write(to: url, options: .atomic)
        } catch {
            BrowserCommandCenter.perform(.showStatus(error.localizedDescription))
        }
    }
}

final class GPGInfoViewController: NSViewController {
    private let stack = NSStackView()
    private let commitRow = SignatureMessageView()
    private let tagRow = SignatureMessageView()

    override func loadView() {
        let root = NSView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.distribution = .fillEqually
        stack.spacing = 0
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(commitRow)
        stack.addArrangedSubview(tagRow)
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8)
        ])
        view = root
    }

    func apply(commit: Commit, info: RevisionGPGInfo?) {
        _ = view
        let presentation = RevisionGPGPresentationResolver.resolve(info: info)
        commitRow.apply(
            message: presentation.commit.message,
            appearance: Self.appearance(for: presentation.commit.indicator, isTag: false)
        )

        tagRow.isHidden = presentation.tag == nil
        guard let tag = presentation.tag else { return }
        tagRow.apply(
            message: tag.message,
            appearance: Self.appearance(for: tag.indicator, isTag: true)
        )
    }

    func showPending() {
        _ = view
        commitRow.apply(message: "Loading data...", appearance: nil)
        tagRow.isHidden = true
    }

    func show(error message: String) {
        _ = view
        commitRow.apply(message: message, appearance: .init(imageName: "CommitSignatureError"))
        tagRow.isHidden = true
    }

    private static func appearance(for indicator: SignatureIndicator, isTag: Bool) -> SignatureMessageView.Appearance? {
        switch indicator {
        case .none: nil
        case .good: .init(imageName: isTag ? "TagOk" : "CommitSignatureOk")
        case .warning: .init(imageName: isTag ? "TagWarning" : "CommitSignatureWarning")
        case .error: .init(imageName: isTag ? "TagError" : "CommitSignatureError")
        case .many: .init(imageName: "TagMany")
        }
    }
}

private final class SignatureMessageView: NSView {
    struct Appearance {
        let imageName: String
    }

    private let imageView = NSImageView()
    private let textView = NSTextView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyDown

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = AppSettingsStore.shared.applicationFont(size: 11)
        textView.textContainerInset = NSSize(width: 3, height: 3)
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        addSubview(imageView)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            imageView.widthAnchor.constraint(equalToConstant: 32),
            imageView.heightAnchor.constraint(equalToConstant: 32),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 38),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func apply(message: String, appearance: Appearance?) {
        textView.string = message
        imageView.image = appearance.flatMap {
            AppKitFactory.resourceImage(
                $0.imageName,
                accessibilityDescription: message,
                size: NSSize(width: 32, height: 32)
            )
        }
        imageView.contentTintColor = nil
        imageView.isHidden = appearance == nil
        textView.scrollToBeginningOfDocument(nil)
    }
}
