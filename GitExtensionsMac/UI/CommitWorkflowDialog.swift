import GitExtensionsCore
import GitCommands
import AppKit

private enum CommitKeyboardShortcut: String {
    case unstaged
    case diff
    case staged
    case message
    case stageAll
    case filter
    case toggleSelectionFilter
    case refresh
    case createBranch
    case openWithDifftool
    case nextFile
    case previousFile
    case addSelectionToMessage
    case conventionalType
    case conventionalScope
}

@MainActor
enum CommitSpelling {
    static let none = "none"

    static func dictionaryName(language: String) -> String { language.replacingOccurrences(of: "_", with: "-") }

    static func availableDictionaries() -> [String] {
        NSSpellChecker.shared.availableLanguages.map(dictionaryName).sorted()
    }

    static func language(for dictionary: String) -> String? {
        guard dictionary.lowercased() != none else { return nil }
        let available = NSSpellChecker.shared.availableLanguages
        let wanted = dictionary.replacingOccurrences(of: "-", with: "_")
        if let exact = available.first(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame }) { return exact }
        let prefix = wanted.split(separator: "_").first.map(String.init) ?? wanted
        return available.first { $0.caseInsensitiveCompare(prefix) == .orderedSame }
    }

    static func effectiveDictionary(_ dictionary: String) -> String? {
        language(for: dictionary).map(dictionaryName)
    }

    static func apply(to textView: NSTextView) {
        guard let language = language(for: AppSettingsStore.shared.spellingDictionary) else {
            textView.isContinuousSpellCheckingEnabled = false
            return
        }
        NSSpellChecker.shared.automaticallyIdentifiesLanguages = false
        NSSpellChecker.shared.setLanguage(language)
        textView.isContinuousSpellCheckingEnabled = true
        textView.checkTextInDocument(nil)
    }

    static func misspelledWord(in textView: NSTextView, at index: Int) -> NSRange? {
        guard let language = language(for: AppSettingsStore.shared.spellingDictionary) else { return nil }
        let text = textView.string as NSString
        guard text.length > 0 else { return nil }
        let position = min(max(0, index), text.length - 1)
        let range = textView.selectionRange(forProposedRange: NSRange(location: position, length: 0), granularity: .selectByWord)
        guard range.length > 0 else { return nil }
        var wordCount = 0
        let found = NSSpellChecker.shared.checkSpelling(of: text.substring(with: range), startingAt: 0, language: language, wrap: false,
                                                        inSpellDocumentWithTag: textView.spellCheckerDocumentTag, wordCount: &wordCount)
        return found.location == NSNotFound ? nil : NSRange(location: range.location + found.location, length: found.length)
    }

    static func menuItems(for textView: NSTextView, at index: Int, target: AnyObject, replace: Selector, add: Selector, ignore: Selector, remove: Selector) -> [NSMenuItem] {
        guard let range = misspelledWord(in: textView, at: index),
              let language = language(for: AppSettingsStore.shared.spellingDictionary) else { return [] }
        let word = (textView.string as NSString).substring(with: range)
        var items: [NSMenuItem] = []
        let guesses = NSSpellChecker.shared.guesses(forWordRange: range, in: textView.string, language: language,
                                                    inSpellDocumentWithTag: textView.spellCheckerDocumentTag) ?? []
        for guess in guesses.prefix(5) {
            let item = NSMenuItem(title: guess, action: replace, keyEquivalent: "")
            item.target = target
            item.representedObject = [NSValue(range: range), guess] as [Any]
            item.attributedTitle = NSAttributedString(string: guess, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
            items.append(item)
        }
        for (title, action) in [("Add to dictionary", add), ("Ignore word", ignore), ("Remove word", remove)] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = word
            items.append(item)
        }
        items.append(.separator())
        return items
    }

    static func dictionaryMenuItem(target: AnyObject, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: "Dictionary", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Dictionary")
        let current = effectiveDictionary(AppSettingsStore.shared.spellingDictionary)
        for name in ["None"] + availableDictionaries() {
            let choice = NSMenuItem(title: name, action: action, keyEquivalent: "")
            choice.target = target
            choice.representedObject = name == "None" ? none : name
            choice.state = (name == "None" ? current == nil : current == name) ? .on : .off
            menu.addItem(choice)
        }
        item.submenu = menu
        return item
    }
}

enum CommitPushTarget {
    static let untracked = "(untracked)"
    static let withoutRemote = "(remote not configured)"

    static func describe(_ tracking: RepositoryBranchTracking) -> String {
        guard !tracking.trackingRemote.isEmpty else {
            let remote = tracking.remotes.first { $0 == "origin" } ?? tracking.remotes.sorted().first
            return remote.map { "\($0)/\(tracking.branch) \(untracked)" } ?? withoutRemote
        }
        return "\(tracking.trackingRemote)/\(tracking.mergeWith)"
    }
}

enum CommitWorkflowSpecialKind {
    case fixup(Commit)
    case squash(Commit)
    case amendAutosquash(Commit)

    var message: String {
        switch self {
        case .fixup(let commit):
            prefixed("fixup!", subject: commit.subject)
        case .squash(let commit):
            prefixed("squash!", subject: commit.subject)
        case .amendAutosquash(let commit):
            prefixed("amend!", subject: commit.subject) + (commit.body.isEmpty ? "" : "\n\n\(commit.body)")
        }
    }

    private func prefixed(_ prefix: String, subject: String) -> String {
        subject.hasPrefix(prefix) ? subject : "\(prefix) \(subject)"
    }
}

@MainActor
private final class CommitRootView: NSView {
    var onShortcut: ((CommitKeyboardShortcut) -> Bool)?
    var onScriptShortcut: ((String) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.attachedSheet == nil, let command = ApplicationHotkeys.shared.matching(event, category: "Scripts") {
            onScriptShortcut?(command); return true
        }
        if let viewer = window?.firstResponder as? FileViewerTableView, viewer.performConfiguredShortcut(event) { return true }
        let configured = ApplicationHotkeys.shared.matching(event, category: "Commit")
            .flatMap { CommitKeyboardShortcut(rawValue: String($0.dropFirst("commit.".count).split(separator: ".")[0])) }
        if let action = configured, onShortcut?(action) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
enum CommitWorkflowDialog {
    static func nextItemToSelect(rows: [String], selected: Set<String>) -> String? {
        if let first = rows.firstIndex(where: { selected.contains($0) }),
           let next = rows[(first + 1)...].first(where: { !selected.contains($0) }) {
            return next
        }
        return rows.first
    }

    static func present(
        source: any RepositoryCommitWorkflowDataSource,
        pushSource: (any RepositoryPushingDataSource)? = nil,
        initialMode: RepositoryCommitMode,
        specialKind: CommitWorkflowSpecialKind? = nil,
        head: Commit?,
        draft: CommitDialogDraft?,
        owner: NSWindow,
        initialMessage: String? = nil,
        onManageRemotes: ((String?, String?) -> Void)? = nil,
        onDifftool: ((Commit, ChangedFile) -> Void)? = nil,
        onBlame: ((ChangedFile, NSWindow) -> Void)? = nil,
        onFileHistory: ((ChangedFile, NSWindow) -> Void)? = nil,
        scriptHooks: ApplicationScriptHooks? = nil,
        onEditIgnoredFiles: ((Bool, NSWindow, @escaping () -> Void) -> Void)? = nil,
        onRepositoryChanged: @escaping (RevisionID?) -> Void,
        onClose: @escaping () -> Void
    ) -> NSWindowController {
        let controller = CommitWorkflowViewController(
            source: source,
            pushSource: pushSource,
            initialMode: initialMode,
            specialKind: specialKind,
            head: head,
            draft: draft,
            onManageRemotes: onManageRemotes,
            onDifftool: onDifftool,
            onRepositoryChanged: onRepositoryChanged
        )
        controller.scriptHooks = scriptHooks
        controller.commandLineMessage = initialMessage
        controller.onEditIgnoredFiles = onEditIgnoredFiles
        controller.onBlame = onBlame
        controller.onFileHistory = onFileHistory
        let commitWindow = NSWindow(contentViewController: controller)
        commitWindow.title = "Commit"
        commitWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        commitWindow.standardWindowButton(.closeButton)?.isEnabled = true
        commitWindow.standardWindowButton(.zoomButton)?.isEnabled = true
        let geometry = AppSettingsStore.shared.commitPreferences
        commitWindow.setContentSize(NSSize(width: geometry.windowWidth, height: geometry.windowHeight))
        commitWindow.contentMinSize = NSSize(width: 600, height: 297)
        commitWindow.minSize = NSSize(width: 600, height: 297)
        commitWindow.isReleasedWhenClosed = false
        if let visibleFrame = owner.screen?.visibleFrame {
            commitWindow.maxSize = visibleFrame.size
        }
        controller.commitWindow = commitWindow
        commitWindow.delegate = controller

        let windowController = NSWindowController(window: commitWindow)
        controller.onClose = onClose
        commitWindow.setFrameOrigin(NSPoint(
            x: owner.frame.midX - commitWindow.frame.width / 2,
            y: owner.frame.midY - commitWindow.frame.height / 2
        ))
        windowController.showWindow(nil)
        commitWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return windowController
    }
}

@MainActor
private final class CommitWorkflowViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextViewDelegate, NSSearchFieldDelegate, NSComboBoxDelegate, NSWindowDelegate, NSMenuDelegate {
    var scriptHooks: ApplicationScriptHooks?
    var commandLineMessage: String?
    private struct TemplateMenuValue {
        let template: CommitMessageTemplate
    }

    weak var commitWindow: NSWindow?
    var onClose: (() -> Void)?

    var onEditIgnoredFiles: ((Bool, NSWindow, @escaping () -> Void) -> Void)?
    var onBlame: ((ChangedFile, NSWindow) -> Void)?
    var onFileHistory: ((ChangedFile, NSWindow) -> Void)?

    private let source: any RepositoryCommitWorkflowDataSource
    private let pushSource: (any RepositoryPushingDataSource)?
    private let initialMode: RepositoryCommitMode
    private var activeSpecialKind: CommitWorkflowSpecialKind?
    private let head: Commit?
    private let draft: CommitDialogDraft?
    private let onManageRemotes: ((String?, String?) -> Void)?
    private let onDifftool: ((Commit, ChangedFile) -> Void)?
    private let onRepositoryChanged: (RevisionID?) -> Void
    private let settings = AppSettingsStore.shared
    private let unstagedTable = NSOutlineView()
    private let stagedTable = NSOutlineView()
    private let unstagedEmptyLabel = NSTextField(labelWithString: "There are no unstaged changes")
    private let stagedEmptyLabel = NSTextField(labelWithString: "There are no staged changes")
    private let unstagedFilter = NSSearchField()
    private let stagedFilter = NSSearchField()
    private let stageSelectedButton = NSButton(title: "Stage", target: nil, action: nil)
    private let stageAllFilesButton = NSButton(title: "Stage All", target: nil, action: nil)
    private let unstageSelectedButton = NSButton(title: "Unstage", target: nil, action: nil)
    private let unstageAllFilesButton = NSButton(title: "Unstage All", target: nil, action: nil)
    private let messageView = CommitMessageTextView()
    private let commitDiffView = CommitDiffView()
    private let amend = NSButton(checkboxWithTitle: "Amend commit", target: nil, action: nil)
    private let amendPanel = NSStackView()
    private let messageMenu = NSPopUpButton()
    private let templatesMenu = NSPopUpButton()
    private let optionsMenu = NSPopUpButton()
    private let stageAll = NSButton(checkboxWithTitle: "Stage all before committing", target: nil, action: nil)
    private let signOff = NSButton(checkboxWithTitle: "Sign-off commit", target: nil, action: nil)
    private let resetAuthor = NSButton(checkboxWithTitle: "Reset author", target: nil, action: nil)
    private let author = NSTextField(string: "")
    private let stageInSuperproject = NSButton(checkboxWithTitle: CommitSuperprojectStaging.title, target: nil, action: nil)
    private var superprojectSubmodule: RepositorySuperprojectSubmodule?
    private var pendingSuperprojectStage: RepositorySuperprojectSubmodule?
    private let authorStatus = CommitAuthorStatusButton()
    private let selectionFilterBox = NSComboBox()
    private let selectionFilterBar = NSStackView()
    private let selectionFilterThrottle = CommitSelectionFilterThrottle()
    private var insertScopeParentheses = false
    private var autoCompleteWords: [String] = []
    private var autoCompleteTask: Task<Void, Never>?
    private let status = NSTextField(labelWithString: "Loading changes…")
    private let commitButton = CommitShortcutButton(title: "Commit", target: nil, action: nil)
    private let commitAndPushButton = LeadingImageButton(title: "Commit & push", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let stashStagedButton = LeadingImageButton(title: "Stash staged changes", target: nil, action: nil)
    private let resetAllButton = LeadingImageButton(title: "Reset all changes", target: nil, action: nil)
    private let resetUnstagedButton = LeadingImageButton(title: "Reset unstaged changes", target: nil, action: nil)
    private let resetSoftButton = LeadingImageButton(title: "Reset soft", target: nil, action: nil)
    private let createBranchButton = NSButton(title: "Create branch", target: nil, action: nil)
    private let solveMergeConflictsButton = NSButton(title: "There are unresolved merge conflicts", target: nil, action: nil)
    private let branchIcon = NSImageView()
    private let branchNameLabel = NSTextField(labelWithString: "")
    private let remoteNameLink = CommitAuthorStatusButton()
    private let stagedCountLabel = NSTextField(labelWithString: "Staged")
    private let stagedCountValue = NSTextField(labelWithString: "0")
    private let cursorLineLabel = NSTextField(labelWithString: "Ln")
    private let cursorLineValue = NSTextField(labelWithString: "0")
    private let cursorColumnLabel = NSTextField(labelWithString: "Col")
    private let cursorColumnValue = NSTextField(labelWithString: "0")
    private let toolbarOverflow = CommitToolbarOverflow()
    private let modifyCommitMessageButton = NSButton(title: "Modify commit message", target: nil, action: nil)
    private let mainSplit = NSSplitView()
    private let fileSplit = NSSplitView()
    private let contentSplit = NSSplitView()
    private let messageSplit = NSStackView()
    private let splitterManager = SplitterManager(settingsPath: "CommitDialog")
    private var didSetInitialDividers = false
    private var unstaged: [ChangedFile] = []
    private var staged: [ChangedFile] = []
    private var unstagedRootNodes: [ChangedFileNode] = []
    private var stagedRootNodes: [ChangedFileNode] = []
    private var repositoryContext: RepositoryCommitContext?
    private var networkContext: RepositoryNetworkContext?
    private var commitState: RepositoryCommitState?
    private var loadTask: Task<Void, Never>?
    private var diffLoadTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>? {
        didSet {
            if isViewLoaded { updateButtonStates() }
        }
    }
    private var didComplete = false
    private var showOnlyMyMessages = false
    private var usingTemplate = false
    private var registeredTemplatesObserver: NSObjectProtocol?
    private var noVerify = false
    private var gpgSigning: RepositoryCommitGPGSigning = .gitDefault
    private var gpgKey = ""
    private var pushWindowController: NSWindowController?
    private var didInitialFocus = false
    private var persistDraftOnClose = true
    private let composesMessage = AppSettingsStore.shared.preferences.composeCommitMessages
    private let messageWatermark = NSTextField(labelWithString: "")
    private var didBecomeKeyOnce = false
    private var refreshPushTargetOnFocus = false
    private var historyWasSoftReset = false
    private var closeWhenPushCompletes = false
    private var fileTreeMode: Bool
    private var fileGroupingMode: FileStatusGrouping
    private var usesDenseTree: Bool
    private var showsGroupNodesInFlatList: Bool
    private var showsUntrackedFiles: Bool
    private var fileTreeButtons: [NSButton] = []
    private var fileGroupingButtons: [NSButton] = []
    private var fileCollapseButtons: [NSButton] = []
    private var fileGroupingMenus: [NSMenu] = []
    private var showsIgnoredFiles = false
    private var showsAssumeUnchangedFiles = false
    private var showsSkipWorktreeFiles = false
    private var stagedShowsSkipWorktreeFiles = false
    private var fileToolbarItems: [ObjectIdentifier: [(name: String, title: String, view: NSView)]] = [:]
    private var fileToolbarMenus: [NSMenu] = []
    private var isFormattingMessage = false
    private var lastShownMessageLoadError: String?
    private var selectedCommitMode: RepositoryCommitMode = .normal

    init(
        source: any RepositoryCommitWorkflowDataSource,
        pushSource: (any RepositoryPushingDataSource)?,
        initialMode: RepositoryCommitMode,
        specialKind: CommitWorkflowSpecialKind?,
        head: Commit?,
        draft: CommitDialogDraft?,
        onManageRemotes: ((String?, String?) -> Void)?,
        onDifftool: ((Commit, ChangedFile) -> Void)?,
        onRepositoryChanged: @escaping (RevisionID?) -> Void
    ) {
        self.source = source
        self.pushSource = pushSource
        self.initialMode = initialMode
        self.activeSpecialKind = specialKind
        self.head = head
        self.draft = draft
        self.onManageRemotes = onManageRemotes
        self.onDifftool = onDifftool
        self.onRepositoryChanged = onRepositoryChanged
        self.showOnlyMyMessages = AppSettingsStore.shared.commitPreferences.showOnlyMyMessages
        let filePreferences = AppSettingsStore.shared.fileStatusListPreferences
        self.fileTreeMode = filePreferences.isTreeMode
        self.fileGroupingMode = filePreferences.grouping
        self.usesDenseTree = filePreferences.usesDenseTree
        self.showsGroupNodesInFlatList = filePreferences.showsGroupNodesInFlatList
        self.showsUntrackedFiles = filePreferences.showsUntrackedFiles
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }
    deinit {
        loadTask?.cancel(); diffLoadTask?.cancel(); actionTask?.cancel(); autoCompleteTask?.cancel()
        if let registeredTemplatesObserver { NotificationCenter.default.removeObserver(registeredTemplatesObserver) }
    }

    override func loadView() {
        let root = CommitRootView()
        root.onShortcut = { [weak self] shortcut in self?.perform(shortcut: shortcut) ?? false }
        root.onScriptShortcut = { [weak self] identifier in
            guard let script = try? ApplicationScriptsStore.shared.load().first(where: { "script.\($0.hotkeyCommandIdentifier)" == identifier }) else { return }
            self?.executeScript(script)
        }
        commitDiffView.onApplyHunk = { [weak self] lineID, direction in
            self?.applySelectedHunk(lineID: lineID, direction: direction)
        }
        commitDiffView.onApplyLines = { [weak self] lineIDs, direction in
            self?.applySelectedLines(lineIDs: lineIDs, direction: direction)
        }
        commitDiffView.onResetLines = { [weak self] ids, direction in self?.resetSelectedLines(lineIDs: ids, direction: direction) }
        commitDiffView.difftasticAvailability = { [source] in await (source as? any RepositoryBrowsingDataSource)?.isDifftasticEnabled() ?? false }
        commitDiffView.onAddSelectedText = { [weak self] text in
            self?.addSelectedDiffTextToMessage(text)
        }
        commitDiffView.onOptionsChanged = { [weak self] in
            guard let self else { return }
            let table = !unstagedTable.selectedRowIndexes.isEmpty ? unstagedTable : stagedTable
            loadSelectedDiff(from: table)
        }
        if onBlame != nil {
            commitDiffView.onBlame = { [weak self] file in
                guard let self, head?.objectID != nil, let commitWindow else { return }
                onBlame?(file, commitWindow)
            }
            commitDiffView.blameAllowed = { [weak self] in self?.head?.objectID != nil }
        }
        commitDiffView.onFileHistory = { [weak self] file in
            guard let self, let commitWindow else { return }
            onFileHistory?(file, commitWindow)
        }
        commitDiffView.historyAllowed = { [weak self] in self?.onFileHistory != nil }
        if onDifftool != nil {
            commitDiffView.onDifftool = { [weak self] file, direction in
                guard let self, let context = repositoryContext,
                      let commit = RevisionCommitBuilder.artificialRevisions(headID: context.headID)
                        .first(where: { $0.kind == (direction == .stage ? .workingDirectory : .index) }) else { return }
                onDifftool?(commit, file)
            }
        }
        let left = makeFilePane()
        let right = makeMessagePane()
        mainSplit.isVertical = true
        mainSplit.dividerStyle = .paneSplitter
        mainSplit.addArrangedSubview(left)
        mainSplit.addArrangedSubview(right)
        splitterManager.addSplitter(mainSplit, name: "splitMain", fixedPanel: .fixedLeadingPane, defaultDistance: 397)
        splitterManager.addSplitter(fileSplit, name: "splitLeft", fixedPanel: .proportional, defaultDistance: 274)
        splitterManager.addSplitter(contentSplit, name: "splitRight", fixedPanel: .fixedTrailingPane, defaultDistance: 426)
        mainSplit.translatesAutoresizingMaskIntoConstraints = false
        left.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true

        status.font = AppSettingsStore.shared.applicationFont(size: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.translatesAutoresizingMaskIntoConstraints = false
        authorStatus.font = AppSettingsStore.shared.applicationFont(size: 11)
        authorStatus.target = self
        authorStatus.action = #selector(openAuthorSettings)
        authorStatus.translatesAutoresizingMaskIntoConstraints = false
        authorStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        authorStatus.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        branchIcon.image = AppKitFactory.resourceImage("Branch", accessibilityDescription: "Branch")
        for label in [branchNameLabel, stagedCountLabel, stagedCountValue, cursorLineLabel, cursorLineValue, cursorColumnLabel, cursorColumnValue] {
            label.font = AppSettingsStore.shared.applicationFont(size: 11)
            label.lineBreakMode = .byClipping
        }
        remoteNameLink.font = AppSettingsStore.shared.applicationFont(size: 11)
        for (label, width) in [(stagedCountValue, CGFloat(40)), (cursorLineValue, 40), (cursorColumnValue, 40)] {
            label.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        let strip = NSStackView(views: [branchIcon, branchNameLabel, remoteNameLink, stagedCountLabel, stagedCountValue, cursorLineLabel, cursorLineValue, cursorColumnLabel, cursorColumnValue])
        strip.orientation = .horizontal
        strip.alignment = .centerY
        strip.spacing = 4
        strip.setCustomSpacing(12, after: remoteNameLink)
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.setContentCompressionResistancePriority(.required, for: .horizontal)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        root.addSubview(mainSplit)
        root.addSubview(authorStatus)
        root.addSubview(status)
        root.addSubview(strip)
        root.addSubview(cancelButton)
        cancelButton.frame = .zero
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(greaterThanOrEqualTo: status.trailingAnchor, constant: 8),
            strip.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -11),
            strip.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            mainSplit.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            mainSplit.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            mainSplit.topAnchor.constraint(equalTo: root.topAnchor),
            mainSplit.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -2),
            authorStatus.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            authorStatus.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            authorStatus.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, multiplier: 0.6),
            status.leadingAnchor.constraint(equalTo: authorStatus.trailingAnchor, constant: 12),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -4),
            status.heightAnchor.constraint(equalToConstant: 18)
        ])
        view = root
        configureInitialValues()
        reloadChanges()
        loadSuperprojectSubmodule()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !didSetInitialDividers else { return }
        didSetInitialDividers = true
        view.layoutSubtreeIfNeeded()
        splitterManager.restoreSplitters()
    }

    private func makeFilePane() -> NSView {
        configureTable(unstagedTable)
        configureTable(stagedTable)
        let unstagedScroll = scroll(for: unstagedTable)
        let stagedScroll = scroll(for: stagedTable)
        stageSelectedButton.target = self; stageSelectedButton.action = #selector(stageSelected)
        stageSelectedButton.keyEquivalent = "s"; stageSelectedButton.keyEquivalentModifierMask = .command
        stageAllFilesButton.target = self; stageAllFilesButton.action = #selector(stageEveryFile)
        unstageSelectedButton.target = self; unstageSelectedButton.action = #selector(unstageSelected)
        unstageAllFilesButton.target = self; unstageAllFilesButton.action = #selector(unstageEveryFile)
        unstagedFilter.placeholderString = "Filter files using a regular expression…"
        stagedFilter.placeholderString = "Filter files using a regular expression…"
        unstagedFilter.delegate = self
        stagedFilter.delegate = self
        unstagedTable.target = self; unstagedTable.doubleAction = #selector(stageSelected)
        stagedTable.target = self; stagedTable.doubleAction = #selector(unstageSelected)
        let topTools = fileToolbar(for: unstagedTable)
        let transfer = transferToolbar(
            unstageAll: unstageAllFilesButton,
            unstage: unstageSelectedButton,
            stage: stageSelectedButton,
            stageAll: stageAllFilesButton
        )
        let bottomTools = fileToolbar(for: stagedTable)
        configureSelectionFilterBar()
        let top = stacked(selectionFilterBar, topTools, unstagedFilter, unstagedScroll)
        let bottom = stacked(transfer, bottomTools, stagedFilter, stagedScroll)
        fileSplit.isVertical = false
        fileSplit.dividerStyle = .paneSplitter
        fileSplit.addArrangedSubview(top)
        fileSplit.addArrangedSubview(bottom)
        return fileSplit
    }

    private func makeMessagePane() -> NSView {
        messageView.isRichText = false
        messageView.font = AppSettingsStore.shared.commitFont
        messageView.delegate = self
        messageView.isAutomaticTextCompletionEnabled = settings.preferences.provideAutocompletion
        messageView.onStringAssigned = { [weak self] in self?.refreshMessageMarkup() }
        CommitSpelling.apply(to: messageView)
        NotificationCenter.default.addObserver(self, selector: #selector(spellingDictionaryChanged), name: .spellingDictionaryDidChange, object: nil)
        let messageScroll = NSScrollView()
        messageScroll.documentView = messageView
        messageScroll.hasVerticalScroller = true
        messageScroll.borderType = .bezelBorder
        configureDocumentView(messageView, width: 760, height: 260)
        if settings.commitMessageEditorPreferences.messageEditorWordWrap {
            messageScroll.hasHorizontalScroller = false
            messageView.setSoftWrap(true)
        } else {
            messageScroll.hasHorizontalScroller = true
            messageScroll.autohidesScrollers = true
        }
        messageScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 115).isActive = true
        messageWatermark.stringValue = composesMessage ? "Enter commit message" : "Commit Message is requested during commit"
        messageWatermark.textColor = .placeholderTextColor
        messageWatermark.font = messageView.font
        messageWatermark.sizeToFit()
        messageWatermark.setFrameOrigin(NSPoint(x: messageView.textContainerInset.width + 5, y: messageView.textContainerInset.height))
        messageView.addSubview(messageWatermark)

        commitButton.target = self
        commitButton.action = #selector(commit)
        commitAndPushButton.target = self
        commitAndPushButton.action = #selector(commitAndPush)
        commitAndPushButton.isEnabled = pushSource != nil
        amend.target = self
        amend.action = #selector(amendChanged)
        stageInSuperproject.target = self
        stageInSuperproject.action = #selector(stageInSuperprojectChanged)
        stageInSuperproject.toolTip = CommitSuperprojectStaging.toolTip
        stageInSuperproject.isHidden = true
        modifyCommitMessageButton.target = self
        modifyCommitMessageButton.action = #selector(modifySpecialCommitMessage)
        modifyCommitMessageButton.bezelStyle = .inline
        stashStagedButton.target = self; stashStagedButton.action = #selector(stashStagedChanges)
        resetAllButton.target = self; resetAllButton.action = #selector(resetAllChanges)
        resetUnstagedButton.target = self; resetUnstagedButton.action = #selector(resetUnstagedChanges)
        resetSoftButton.target = self; resetSoftButton.action = #selector(resetSoft)
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.alphaValue = 0
        cancelButton.refusesFirstResponder = true
        cancelButton.setAccessibilityElement(false)
        for (button, image) in [(commitButton, "RepoStateClean"), (commitAndPushButton, "ArrowUp"), (stashStagedButton, "stash"),
                                (resetAllButton, "ResetWorkingDirChanges"), (resetUnstagedButton, "ResetWorkingDirChanges"), (resetSoftButton, "ResetCurrentBranchToHere")] {
            button.image = AppKitFactory.resourceImage(image, accessibilityDescription: button.title)
            button.imagePosition = .imageLeft
            button.imageHugsTitle = false
        }
        for button in [commitButton, commitAndPushButton, stashStagedButton, resetAllButton, resetUnstagedButton] {
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 171).isActive = true
            button.heightAnchor.constraint(equalToConstant: 26).isActive = true
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        resetSoftButton.heightAnchor.constraint(equalToConstant: 26).isActive = true
        resetSoftButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        amendPanel.orientation = .vertical
        amendPanel.alignment = .leading
        amendPanel.spacing = 2
        amendPanel.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 0)
        amendPanel.addArrangedSubview(resetAuthor)
        amendPanel.addArrangedSubview(resetSoftButton)
        amendPanel.isHidden = true
        let commands = NSStackView(views: [commitButton, commitAndPushButton, stageInSuperproject, amend, amendPanel, modifyCommitMessageButton, stashStagedButton, resetAllButton, resetUnstagedButton])
        NSLayoutConstraint.activate([commitAndPushButton, stashStagedButton, resetAllButton, resetUnstagedButton].map { $0.widthAnchor.constraint(equalTo: commitButton.widthAnchor) }
            + [resetSoftButton.widthAnchor.constraint(equalTo: commitButton.widthAnchor, constant: -12)])
        commands.orientation = .vertical
        commands.alignment = .leading
        commands.spacing = 7
        commands.edgeInsets = NSEdgeInsets(top: 8, left: 3, bottom: 8, right: 3)

        messageMenu.removeAllItems()
        messageMenu.pullsDown = true
        messageMenu.addItem(withTitle: "Commit message")
        createBranchButton.target = self
        createBranchButton.action = #selector(createBranch)
        remoteNameLink.target = self
        remoteNameLink.action = #selector(manageTracking)
        remoteNameLink.toolTip = nil
        templatesMenu.removeAllItems()
        templatesMenu.pullsDown = true
        templatesMenu.addItem(withTitle: "Commit templates")
        optionsMenu.removeAllItems()
        optionsMenu.pullsDown = true
        optionsMenu.addItem(withTitle: "Options")
        configureOptionsMenu()
        for (menu, image) in [(messageMenu, "WorkingDirChanges"), (templatesMenu, "CommitTemplates"), (optionsMenu, nil)] as [(NSPopUpButton, String?)] {
            menu.isBordered = false
            (menu.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
            if let image, let title = menu.item(at: 0) {
                title.image = AppKitFactory.resourceImage(image, accessibilityDescription: title.title)
                menu.imagePosition = .imageLeft
            }
        }
        [messageMenu, templatesMenu, createBranchButton, optionsMenu].forEach {
            $0.setContentCompressionResistancePriority(.required, for: .horizontal)
            $0.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let messageToolbar = NSStackView(views: [messageMenu, templatesMenu, createBranchButton, spacer, optionsMenu, toolbarOverflow.button])
        toolbarOverflow.attach(to: messageToolbar, overflowing: [createBranchButton, templatesMenu])
        messageToolbar.orientation = .horizontal
        messageToolbar.alignment = .centerY
        messageToolbar.spacing = 6
        messageToolbar.edgeInsets = NSEdgeInsets(top: 3, left: 5, bottom: 3, right: 5)
        let editor = NSStackView(views: [messageToolbar, messageScroll])
        editor.orientation = .vertical
        editor.alignment = .leading
        editor.spacing = 0
        messageToolbar.widthAnchor.constraint(equalTo: editor.widthAnchor).isActive = true
        messageScroll.widthAnchor.constraint(equalTo: editor.widthAnchor).isActive = true
        messageSplit.orientation = .horizontal
        messageSplit.alignment = .top
        messageSplit.distribution = .fill
        messageSplit.spacing = 0
        commands.setHuggingPriority(.defaultHigh, for: .horizontal)
        messageSplit.addArrangedSubview(commands)
        messageSplit.addArrangedSubview(editor)
        commands.setClippingResistancePriority(.defaultLow, for: .vertical)
        for stack in [editor, messageSplit] { stack.setClippingResistancePriority(.defaultLow, for: .horizontal) }
        commands.setHuggingPriority(.defaultLow, for: .vertical)
        editor.heightAnchor.constraint(equalTo: messageSplit.heightAnchor).isActive = true
        editor.trailingAnchor.constraint(equalTo: messageSplit.trailingAnchor).isActive = true

        contentSplit.isVertical = false
        contentSplit.dividerStyle = .paneSplitter
        contentSplit.addArrangedSubview(commitDiffView)
        solveMergeConflictsButton.target = self
        solveMergeConflictsButton.action = #selector(solveMergeConflicts)
        solveMergeConflictsButton.image = AppKitFactory.resourceImage("SolveMerge", accessibilityDescription: "Solve merge conflicts")
        solveMergeConflictsButton.imagePosition = .imageLeft
        solveMergeConflictsButton.imageHugsTitle = false
        solveMergeConflictsButton.isBordered = false
        solveMergeConflictsButton.wantsLayer = true
        solveMergeConflictsButton.layer?.backgroundColor = NSColor(srgbRed: 230 / 255, green: 99 / 255, blue: 99 / 255, alpha: 1).cgColor
        (solveMergeConflictsButton.cell as? NSButtonCell)?.wraps = true
        solveMergeConflictsButton.attributedTitle = NSAttributedString(string: solveMergeConflictsButton.title, attributes: [
            .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize), .foregroundColor: NSColor.black,
            .paragraphStyle: { let style = NSMutableParagraphStyle(); style.alignment = .center; style.lineBreakMode = .byWordWrapping; return style }()
        ])
        solveMergeConflictsButton.isHidden = true
        solveMergeConflictsButton.translatesAutoresizingMaskIntoConstraints = false
        commitDiffView.addSubview(solveMergeConflictsButton)
        NSLayoutConstraint.activate([
            solveMergeConflictsButton.leadingAnchor.constraint(equalTo: commitDiffView.leadingAnchor, constant: 14),
            solveMergeConflictsButton.topAnchor.constraint(equalTo: commitDiffView.topAnchor, constant: 12),
            solveMergeConflictsButton.widthAnchor.constraint(equalToConstant: 188),
            solveMergeConflictsButton.heightAnchor.constraint(equalToConstant: 42)
        ])
        contentSplit.addArrangedSubview(messageSplit)
        return contentSplit
    }

    private func configureMessageMenu() {
        guard let menu = messageMenu.menu else { return }
        while menu.items.count > 1 { menu.removeItem(at: 1) }
        var history = commitState?.previousMessages ?? []
        let last = settings.commitPreferences.lastCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty, !history.contains(last) {
            history.insert(last, at: 0)
            history = Array(history.prefix(max(1, settings.commitPreferences.historyLimit)))
        }
        for message in history {
            let item = NSMenuItem(title: shortenedMessage(message), action: #selector(selectRecentCommitMessage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = message
            menu.addItem(item)
        }
        if history.isEmpty == false { menu.addItem(.separator()) }
        let changes = NSMenuItem(title: "Generate a list of changes in submodules", action: #selector(generateSubmoduleMessage(_:)), keyEquivalent: "")
        changes.target = self
        menu.addItem(changes)
        let mine = NSMenuItem(title: "Show only my messages", action: #selector(toggleMyMessages(_:)), keyEquivalent: "")
        mine.target = self
        mine.state = showOnlyMyMessages ? .on : .off
        mine.representedObject = "showOnlyMine"
        menu.addItem(mine)
    }

    private func configureTemplatesMenu() {
        guard let menu = templatesMenu.menu else { return }
        if registeredTemplatesObserver == nil {
            registeredTemplatesObserver = NotificationCenter.default.addObserver(
                forName: CommitTemplateRegistry.didChange, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.configureTemplatesMenu() }
            }
        }
        while menu.items.count > 1 { menu.removeItem(at: 1) }
        let registered = CommitTemplateRegistry.templates.filter { !$0.name.isEmpty }
        for template in registered {
            let item = NSMenuItem(title: template.name, action: #selector(selectRegisteredTemplate(_:)), keyEquivalent: "")
            item.target = self
            item.image = template.icon
            item.representedObject = template.name
            menu.addItem(item)
        }
        if !registered.isEmpty { menu.addItem(.separator()) }
        let templates = settings.commitPreferences.templates.filter { !$0.name.isEmpty }
        for template in templates {
            let item = NSMenuItem(title: template.name, action: #selector(selectCommitTemplate(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = TemplateMenuValue(template: template)
            menu.addItem(item)
        }
        if !templates.isEmpty { menu.addItem(.separator()) }

        let conventional = NSMenuItem(title: "Conventional Commits", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Conventional Commits")
        for keyword in ConventionalCommitPrefixer.headerCommitTypes {
            let item = NSMenuItem(title: keyword, action: #selector(insertConventionalPrefix(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = keyword
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        for footer in ConventionalCommitPrefixer.footerKeywords + ["[skip ci]"] {
            let item = NSMenuItem(title: footer, action: #selector(insertTemplateFooter(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = footer
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let documentation = NSMenuItem(title: "Documentation…", action: #selector(openConventionalCommitDocumentation), keyEquivalent: "")
        documentation.target = self
        submenu.addItem(documentation)
        conventional.submenu = submenu
        menu.addItem(conventional)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Edit commit message templates and settings…", action: #selector(editCommitTemplates), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
    }

    private func configureOptionsMenu() {
        guard let menu = optionsMenu.menu else { return }
        while menu.items.count > 1 { menu.removeItem(at: 1) }
        for (title, key) in [
            ("Close dialog after each commit", "closeEach"),
            ("Close dialog when all changes are committed", "closeAll"),
            ("Refresh dialog on form focus", "refreshFocus"),
            ("Select staged on entering message editor", "selectStaged")
        ] {
            let item = NSMenuItem(title: title, action: #selector(toggleCommitOption(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key
            let preferences = settings.commitPreferences
            item.state = switch key {
            case "closeEach": preferences.closeAfterCommit ? .on : .off
            case "closeAll": preferences.closeAfterLastCommit ? .on : .off
            case "refreshFocus": preferences.refreshOnFocus ? .on : .off
            case "selectStaged": preferences.selectStagedOnMessageFocus ? .on : .off
            default: .off
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let sign = NSMenuItem(title: "Sign-off commit", action: #selector(toggleCommitOption(_:)), keyEquivalent: "")
        sign.target = self
        sign.representedObject = "signOff"
        sign.state = signOff.state
        menu.addItem(sign)
        let emptyAuthor = author.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let authorInfo = NSMenuItem(
            title: emptyAuthor ? "Override author…" : "Author: \(author.stringValue)…",
            action: #selector(promptAuthorOverride),
            keyEquivalent: ""
        )
        authorInfo.target = self
        menu.addItem(authorInfo)
        if !emptyAuthor {
            let clearAuthor = NSMenuItem(title: "Clear author override", action: #selector(clearAuthorOverride), keyEquivalent: "")
            clearAuthor.target = self
            menu.addItem(clearAuthor)
        }
        let noVerifyItem = NSMenuItem(title: "No verify", action: #selector(toggleCommitOption(_:)), keyEquivalent: "")
        noVerifyItem.target = self
        noVerifyItem.representedObject = "noVerify"
        noVerifyItem.state = noVerify ? .on : .off
        menu.addItem(noVerifyItem)
        menu.addItem(.separator())
        let gpg = NSMenuItem(title: "Git default GPG signing", action: nil, keyEquivalent: "")
        let gpgMenu = NSMenu(title: "GPG signing")
        for (index, title) in ["Git default GPG signing", "Do not sign commit", "Sign with default GPG", "Sign with specific GPG"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(selectGPGSigning(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = gpgSelectionIndex == index ? .on : .off
            gpgMenu.addItem(item)
        }
        gpg.submenu = gpgMenu
        menu.addItem(gpg)
    }

    private func shortenedMessage(_ value: String) -> String {
        let firstLine = value.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first.map(String.init) ?? value
        return firstLine.count > 72 ? String(firstLine.prefix(69)) + "…" : firstLine
    }

    private var gpgSelectionIndex: Int {
        switch gpgSigning {
        case .gitDefault: 0
        case .doNotSign: 1
        case .signDefault: 2
        case .signSpecificKey: 3
        }
    }

    @objc private func selectRecentCommitMessage(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        messageView.string = value.trimmingCharacters(in: .whitespacesAndNewlines)
        commitWindow?.makeFirstResponder(messageView)
    }

    @objc private func generateSubmoduleMessage(_ sender: NSMenuItem) {
        let changed = (repositoryContext?.submodules ?? []).filter { module in
            staged.contains { $0.path == module.path }
        }
        guard !changed.isEmpty else {
            status.stringValue = "There are no staged submodule changes."
            return
        }
        var lines = ["Submodule\(changed.count == 1 ? "" : "s") \(changed.map(\.path).joined(separator: ", ")) updated", ""]
        for module in changed {
            lines.append("Submodule \(module.path):")
            lines.append("    * Revision changed to \(module.commitID.map { String($0.string.prefix(7)) } ?? "unknown")")
            lines.append("")
        }
        messageView.string = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
        commitWindow?.makeFirstResponder(messageView)
    }

    @objc private func toggleMyMessages(_ sender: NSMenuItem) {
        showOnlyMyMessages.toggle()
        var preferences = settings.commitPreferences
        preferences.showOnlyMyMessages = showOnlyMyMessages
        settings.saveCommitPreferences(preferences)
        reloadChanges(preserveMessage: true)
    }

    @objc private func selectCommitTemplate(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? TemplateMenuValue else { return }
        let branch = commitState?.mutationState.currentBranch ?? ""
        messageView.string = CommitTemplateExpander.expand(
            value.template.text,
            forBranch: branch,
            enabled: value.template.expandsBranchRegularExpressions
        )
        usingTemplate = true
        commitWindow?.makeFirstResponder(messageView)
    }

    @objc private func selectRegisteredTemplate(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let template = CommitTemplateRegistry.templates.first(where: { $0.name == name }) else { return }
        let branch = commitState?.mutationState.currentBranch ?? ""
        messageView.string = CommitTemplateExpander.expand(template.text(), forBranch: branch, enabled: template.isRegex)
        usingTemplate = true
        commitWindow?.makeFirstResponder(messageView)
    }

    @objc private func editCommitTemplates() {
        guard let commitWindow else { return }
        CommitTemplateSettingsDialog.present(parent: commitWindow) { [weak self] in
            self?.configureTemplatesMenu()
        }
    }

    @objc private func openConventionalCommitDocumentation() {
        guard let url = URL(string: "https://www.conventionalcommits.org/") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func insertConventionalPrefix(_ sender: NSMenuItem) {
        guard let keyword = sender.representedObject as? String else { return }
        applyConventionalKeyword(keyword)
    }

    @objc private func insertTemplateFooter(_ sender: NSMenuItem) {
        guard let footer = sender.representedObject as? String else { return }
        let keepsCursorPosition = footer == "[skip ci]"
        let selection = messageView.selectedRange()
        messageView.string = ConventionalCommitPrefixer.appendFooter(keepsCursorPosition ? footer : "\(footer): ", to: messageView.string)
        let length = (messageView.string as NSString).length
        messageView.setSelectedRange(keepsCursorPosition ? NSRange(location: min(selection.location, length), length: 0) : NSRange(location: length, length: 0))
        commitWindow?.makeFirstResponder(messageView)
    }

    private func applyConventionalKeyword(_ keyword: String) {
        let result = ConventionalCommitPrefixer.apply(keyword: keyword, message: messageView.string,
                                                      selectionStart: messageView.selectedRange().location, insertScope: insertScopeParentheses)
        messageView.string = result.message
        messageView.setSelectedRange(NSRange(location: min(result.selectionStart, (result.message as NSString).length), length: 0))
        commitWindow?.makeFirstResponder(messageView)
    }

    private func openConventionalCommitMenu(insertScope: Bool) {
        insertScopeParentheses = insertScope
        guard let submenu = templatesMenu.menu?.items.first(where: { $0.title == "Conventional Commits" })?.submenu,
              let feat = submenu.items.first(where: { $0.title == ConventionalCommitPrefixer.feat }) else { return }
        let menu = submenu.copy() as? NSMenu ?? submenu
        let positioning = menu.items.first(where: { $0.title == feat.title })
        let caret = messageView.firstRect(forCharacterRange: messageView.selectedRange(), actualRange: nil)
        let location = commitWindow.map { window -> NSPoint in
            let inWindow = window.convertFromScreen(caret).origin
            return messageView.convert(inWindow, from: nil)
        } ?? .zero
        menu.popUp(positioning: positioning, at: location, in: messageView)
    }

    @objc private func stageInSuperprojectChanged() {
        guard !stageInSuperproject.isHidden else { return }
        var preferences = settings.commitMessageEditorPreferences
        preferences.stageInSuperprojectAfterCommit = stageInSuperproject.state == .on
        settings.saveCommitMessageEditorPreferences(preferences)
    }

    private func loadSuperprojectSubmodule() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let submodule = await source.loadSuperprojectSubmodule()
            superprojectSubmodule = submodule
            stageInSuperproject.isHidden = submodule == nil
        }
    }

    private func stageSubmoduleInSuperproject(_ target: RepositorySuperprojectSubmodule) async {
        do {
            try await source.stageInSuperproject(target)
        } catch {
            status.stringValue = error.localizedDescription
        }
    }

    @objc private func openAuthorSettings() {
        guard let commitWindow else { return }
        Task { @MainActor [weak self, weak commitWindow] in
            guard let self, let commitWindow else { return }
            await ApplicationShellDialogs.presentSettings(from: commitWindow, source: source as? any RepositorySettingsDataSource,
                                                          initialPage: CommitAuthorStatus.settingsPage)
            reloadChanges(preserveMessage: true)
        }
    }

    private func configureSelectionFilterBar() {
        let label = NSTextField(labelWithString: CommitSelectionFilter.title)
        label.font = AppSettingsStore.shared.applicationFont(size: 11)
        selectionFilterBox.isEditable = true
        selectionFilterBox.completes = false
        selectionFilterBox.numberOfVisibleItems = CommitSelectionFilter.historyLimit
        selectionFilterBox.toolTip = CommitSelectionFilter.toolTip
        selectionFilterBox.delegate = self
        selectionFilterBox.setAccessibilityIdentifier("CommitSelectionFilter")
        selectionFilterBox.widthAnchor.constraint(equalToConstant: 160).isActive = true
        selectionFilterBar.setViews([label, selectionFilterBox], in: .leading)
        selectionFilterBar.orientation = .horizontal
        selectionFilterBar.alignment = .centerY
        selectionFilterBar.spacing = 5
        selectionFilterBar.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 5)
    }

    private func toggleSelectionFilter() {
        let visible = selectionFilterBar.isHidden
        selectionFilterBar.isHidden = !visible
        if visible {
            commitWindow?.makeFirstResponder(selectionFilterBox)
        } else if let editor = selectionFilterBox.currentEditor(), commitWindow?.firstResponder === editor {
            commitWindow?.makeFirstResponder(unstagedTable)
        }
    }

    @discardableResult
    private func applySelectionFilter(_ text: String) -> Int {
        let paths = unstagedSelectableNodes().compactMap { $0.file?.path }
        let matches: Set<String>
        do {
            matches = Set(try CommitSelectionFilter.matchingPaths(paths, pattern: text))
            selectionFilterBox.toolTip = CommitSelectionFilter.toolTip
        } catch {
            selectionFilterBox.toolTip = CommitSelectionFilter.errorToolTip(error)
            return 0
        }
        if !matches.isEmpty { unstagedTable.expandItem(nil, expandChildren: true) }
        var rows = IndexSet()
        for row in 0..<unstagedTable.numberOfRows {
            if let path = (unstagedTable.item(atRow: row) as? ChangedFileNode)?.file?.path, matches.contains(path) { rows.insert(row) }
        }
        unstagedTable.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first { unstagedTable.scrollRowToVisible(first) }
        return rows.count
    }

    private func selectionFilterTextChanged(_ text: String) {
        selectionFilterThrottle.submit(text) { [weak self] value in
            guard let self else { return }
            if applySelectionFilter(value) > 0 {
                let history = CommitSelectionFilter.history(selectionFilterBox.objectValues.compactMap { $0 as? String }, adding: value)
                selectionFilterBox.removeAllItems()
                selectionFilterBox.addItems(withObjectValues: history)
            }
        }
    }

    private func unstagedSelectableNodes() -> [ChangedFileNode] {
        func flatten(_ nodes: [ChangedFileNode]) -> [ChangedFileNode] { nodes.flatMap { [$0] + flatten($0.children) } }
        return flatten(unstagedRootNodes).filter { $0.file != nil }
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSComboBox === selectionFilterBox else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            selectionFilterThrottle.cancel()
            applySelectionFilter(selectionFilterBox.stringValue)
        }
    }

    private func refreshMessageMarkup() {
        let text = messageView.string
        messageView.illFormedRanges = settings.commitMessageEditorPreferences.markIllFormedLines ? CommitMessageMarkup.illFormedRanges(in: text) : []
        messageView.marksBlankFirstLine = settings.commitMessageEditorPreferences.markIllFormedLines && CommitMessageMarkup.marksBlankFirstLine(text)
        let validation = settings.commitPreferences.validation
        messageView.applyOverLimitRanges(CommitMessageMarkup.overLimitRanges(in: text, firstLineLimit: validation.maximumSubjectLength,
                                                                             bodyLineLimit: validation.maximumLineLength,
                                                                             secondLineMustBeEmpty: validation.requireEmptySecondLine))
        messageView.needsDisplay = true
    }

    @objc private func wordWrapCommitMessageBody() {
        let limit = CommitWordWrapper.bodyLineLimit(configured: settings.commitPreferences.validation.maximumLineLength)
        let original = messageView.string
        let wrapped = CommitWordWrapper.wrapBody(original, limit: limit)
        guard wrapped != original else { return }
        let full = NSRange(location: 0, length: (original as NSString).length)
        guard messageView.shouldChangeText(in: full, replacementString: wrapped) else { return }
        messageView.replaceCharacters(in: full, with: wrapped)
        messageView.didChangeText()
    }

    @objc private func toggleMarkIllFormedLines(_ sender: NSMenuItem) {
        var preferences = settings.commitMessageEditorPreferences
        preferences.markIllFormedLines.toggle()
        settings.saveCommitMessageEditorPreferences(preferences)
        refreshMessageMarkup()
    }

    private func refreshAutoCompleteWords() {
        autoCompleteTask?.cancel()
        guard settings.preferences.provideAutocompletion, let context = repositoryContext else { return }
        let files = unstaged.map { (file: $0, kind: Commit.Kind.workingDirectory) } + staged.map { (file: $0, kind: Commit.Kind.index) }
        let artificial = RevisionCommitBuilder.artificialRevisions(headID: context.headID)
        let regexes = CommitAutoCompleteRegexes.regexes
        let source = source
        autoCompleteTask = Task { @MainActor [weak self] in
            let words = await CommitAutoCompleteRegexes.collectWords(files: files, regexes: regexes) { file, kind in
                guard let commit = artificial.first(where: { $0.kind == kind }) else { return nil }
                return try? await source.loadDiff(for: commit, file: file, options: FileDiffOptions(contextLines: 5))
            }
            guard !Task.isCancelled, let self else { return }
            autoCompleteWords = words
        }
    }

    @objc private func toggleCommitOption(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        if key == "signOff" {
            signOff.state = signOff.state == .on ? .off : .on
            sender.state = signOff.state
        } else if key == "noVerify" {
            noVerify.toggle()
            sender.state = noVerify ? .on : .off
        } else {
            sender.state = sender.state == .on ? .off : .on
            var preferences = settings.commitPreferences
            switch key {
            case "closeEach": preferences.closeAfterCommit = sender.state == .on
            case "closeAll": preferences.closeAfterLastCommit = sender.state == .on
            case "refreshFocus": preferences.refreshOnFocus = sender.state == .on
            case "selectStaged": preferences.selectStagedOnMessageFocus = sender.state == .on
            default: break
            }
            settings.saveCommitPreferences(preferences)
        }
    }

    @objc private func promptAuthorOverride() {
        guard let commitWindow else { return }
        actionTask = Task { @MainActor [weak self, weak commitWindow] in
            guard let self, let commitWindow else { return }
            defer { actionTask = nil; updateButtonStates() }
            let alert = NSAlert()
            alert.messageText = "Override commit author"
            alert.informativeText = "Enter the author using the format Name <email@example.com>."
            alert.addButton(withTitle: "Use Author")
            alert.addButton(withTitle: "Cancel")
            let field = NSTextField(string: author.stringValue)
            field.placeholderString = "Name <email@example.com>"
            field.frame.size.width = 320
            alert.accessoryView = field
            guard await begin(alert, window: commitWindow) == .alertFirstButtonReturn else { return }
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.isEmpty || value.range(of: #"^.+\s<[^<>]+>$"#, options: .regularExpression) != nil else {
                status.stringValue = "Author must use the format Name <email@example.com>."
                return
            }
            author.stringValue = value
            configureOptionsMenu()
            updateStatus()
        }
    }

    @objc private func clearAuthorOverride() {
        author.stringValue = ""
        configureOptionsMenu()
        updateStatus()
    }

    @objc private func selectGPGSigning(_ sender: NSMenuItem) {
        switch sender.tag {
        case 1: gpgSigning = .doNotSign
        case 2: gpgSigning = .signDefault
        case 3:
            guard let commitWindow else { return }
            actionTask?.cancel()
            actionTask = Task { @MainActor [weak self, weak commitWindow] in
                guard let self, let commitWindow else { return }
                defer { actionTask = nil; updateButtonStates() }
                let alert = NSAlert()
                alert.messageText = "Sign with specific GPG key"
                alert.informativeText = "Enter the key ID, fingerprint, or signing identity Git should pass to --gpg-sign."
                alert.addButton(withTitle: "Use Key")
                alert.addButton(withTitle: "Cancel")
                let field = NSTextField(string: gpgKey.isEmpty ? settings.preferences.signingKey : gpgKey)
                field.placeholderString = "GPG key"
                field.frame.size.width = 320
                alert.accessoryView = field
                guard await begin(alert, window: commitWindow) == .alertFirstButtonReturn else { return }
                let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { status.stringValue = "Enter a GPG key."; return }
                gpgKey = key
                gpgSigning = .signSpecificKey(key)
                configureOptionsMenu()
            }
            return
        default: gpgSigning = .gitDefault
        }
        configureOptionsMenu()
    }

    private func configureInitialValues() {
        let initial = draft?.request
        let selectedMode = initial?.mode ?? initialMode
        selectedCommitMode = selectedMode
        amend.state = selectedMode == .normal ? .off : .on
        messageView.string = !composesMessage ? "" : activeSpecialKind?.message ?? commandLineMessage ?? initial?.message ?? (selectedMode == .normal ? "" : headMessage())
        let preferences = settings.preferences
        let commitPreferences = settings.commitPreferences
        stageAll.state = initial?.stageAllBeforeCommit == true ? .on : .off
        signOff.state = (initial?.signOff ?? preferences.defaultSignOff) ? .on : .off
        resetAuthor.state = initial?.resetAuthor == true ? .on : .off
        author.stringValue = initial?.author ?? ""
        noVerify = initial?.noVerify ?? false
        gpgSigning = initial?.gpgSigning ?? .gitDefault
        usingTemplate = initial?.usingTemplate ?? false
        applySpecialCommitState()
        commitAndPushButton.isHidden = !commitPreferences.showCommitAndPush
        resetAllButton.isHidden = !commitPreferences.showResetAll
        resetUnstagedButton.isHidden = !commitPreferences.showResetUnstaged
        stageInSuperproject.state = settings.commitMessageEditorPreferences.stageInSuperprojectAfterCommit ? .on : .off
        selectionFilterBar.isHidden = !settings.commitMessageEditorPreferences.showsSelectionFilter
        modeChanged()
        refreshMessageMarkup()
    }

    private func configureTable(_ table: NSOutlineView) {
        let fileColumn = NSTableColumn(identifier: .init("File"))
        fileColumn.width = 330
        table.addTableColumn(fileColumn)
        table.outlineTableColumn = fileColumn
        table.headerView = nil
        table.rowHeight = BrowserMetrics.fileRowHeight
        table.indentationPerLevel = 14
        table.intercellSpacing = .zero
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .controlBackgroundColor
        table.delegate = self
        table.dataSource = self
        let menu = NSMenu(title: "File actions")
        menu.identifier = NSUserInterfaceItemIdentifier(table === unstagedTable ? "unstaged" : "staged")
        menu.delegate = self
        table.menu = menu
    }

    private func headMessage() -> String {
        guard let head else { return "" }
        return head.subject + (head.body.isEmpty ? "" : "\n\n\(head.body)")
    }

    private func scroll(for table: NSOutlineView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let label = table === stagedTable ? stagedEmptyLabel : unstagedEmptyLabel
        label.font = NSFontManager.shared.convert(AppSettingsStore.shared.applicationFont(size: 11), toHaveTrait: .italicFontMask)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        scroll.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 6)
        ])
        return scroll
    }

    private func toolbar(title: String, buttons: [NSButton]) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = AppSettingsStore.shared.applicationFont(size: 12, weight: .bold)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [label, spacer] + buttons)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 5)
        return stack
    }

    private func stacked(_ views: NSView...) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.spacing = 0
        return stack
    }

    private func fileToolbar(for table: NSTableView) -> NSView {
        let tree = makeFileGroupingMenu()
        let path = makeDirectGroupingButton(.path, tag: 0, image: "FolderClosed", tooltip: "Group by file path")
        let fileExtension = makeDirectGroupingButton(.fileExtension, tag: 1, image: "File", tooltip: "Group by file type (extension)")
        let statusGrouping = makeDirectGroupingButton(.status, tag: 2, image: "FileStatusModified", tooltip: "Group by diff status")
        let settings = makeFileSettingsMenu(for: table)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let collapse = AppKitFactory.resourceButton(
            "CollapseAll",
            tooltip: "Collapse all groups, otherwise expand all groups",
            target: self,
            action: #selector(toggleFileGroupExpansion(_:))
        )
        collapse.tag = table === unstagedTable ? 0 : 1
        fileCollapseButtons.append(collapse)
        var controls: [NSView] = [collapse, AppKitFactory.separator()]
        if table === unstagedTable {
            controls.append(AppKitFactory.resourceButton("ReloadRevisions", tooltip: "Refresh changes", target: self, action: #selector(refreshChanges)))
            controls.append(AppKitFactory.separator())
        }
        controls += [tree, AppKitFactory.separator(), path, fileExtension, statusGrouping, AppKitFactory.separator(), settings, spacer]
        var named: [(name: String, title: String, view: NSView)] = [("btnCollapseGroups", collapse.toolTip ?? "", collapse)]
        if table === unstagedTable {
            named += [("sepRefresh", "", controls[1]), ("btnRefresh", "Refresh changes", controls[2]), ("sepAsTree", "", controls[3])]
        } else {
            named.append(("sepAsTree", "", controls[1]))
        }
        let base = table === unstagedTable ? 4 : 2
        named += [("btnAsTree", "Toggle flat list / tree", controls[base]), ("sepGroupBy", "", controls[base + 1]),
                  ("btnByPath", "Group by file path", path), ("btnByExtension", "Group by file type (extension)", fileExtension),
                  ("btnByStatus", "Group by diff status", statusGrouping), ("sepSettings", "", controls[base + 5]), ("btnSettings", "Settings", settings)]
        fileToolbarItems[ObjectIdentifier(table)] = named
        if let menu = settings.menu {
            let toolbarItem = menu.items.first { $0.title == "Toolbar" }
            let toolbarMenu = NSMenu()
            for (index, item) in named.enumerated() {
                let title = item.name.hasPrefix("sep") && index + 1 < named.count ? "Separator '\(named[index + 1].title)'" : item.title
                let menuItem = NSMenuItem(title: title, action: #selector(toggleFileToolbarItem(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.representedObject = item.name
                menuItem.isEnabled = item.name != "btnSettings"
                toolbarMenu.addItem(menuItem)
            }
            toolbarItem?.submenu = toolbarMenu
            fileToolbarMenus.append(toolbarMenu)
        }
        applyFileToolbarVisibility()
        let bar = NSStackView(views: controls)
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 0
        bar.edgeInsets = NSEdgeInsets(top: 1, left: 3, bottom: 1, right: 3)
        bar.heightAnchor.constraint(equalToConstant: 25).isActive = true
        return bar
    }

    @objc private func toggleFileGroupExpansion(_ sender: NSButton) {
        let table = sender.tag == 0 ? unstagedTable : stagedTable
        let roots = rootNodes(for: table)
        let expanded = roots.contains { table.isItemExpanded($0) }
        roots.forEach { node in
            if expanded {
                table.collapseItem(node, collapseChildren: true)
            } else {
                table.expandItem(node, expandChildren: true)
            }
        }
    }

    private func makeDirectGroupingButton(_ grouping: FileStatusGrouping, tag: Int, image: String, tooltip: String) -> NSButton {
        let button = AppKitFactory.resourceButton(image, tooltip: tooltip, target: self, action: #selector(selectDirectFileGrouping(_:)))
        button.setButtonType(.pushOnPushOff)
        button.tag = tag
        button.state = fileGroupingMode == grouping ? .on : .off
        fileGroupingButtons.append(button)
        return button
    }

    private func makeFileGroupingMenu() -> NSView {
        let control = NSStackView()
        control.orientation = .horizontal
        control.spacing = 0
        control.alignment = .centerY
        let tree = AppKitFactory.resourceButton("FileTree", tooltip: "Toggle flat list / tree", target: self, action: #selector(toggleFileTree(_:)))
        tree.setButtonType(.pushOnPushOff)
        tree.state = fileTreeMode ? .on : .off
        fileTreeButtons.append(tree)
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.isBordered = false
        button.controlSize = .small
        button.toolTip = "File list grouping options"
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 12).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        button.addItem(withTitle: "")
        button.itemArray.first?.title = ""
        control.addArrangedSubview(tree)
        control.addArrangedSubview(button)
        let entries = [
            ("Group by file path - tree", 0),
            ("Group by file path - flat", 1),
            ("Group by file extension - tree", 2),
            ("Group by file extension - flat", 3),
            ("Group by file status - tree", 4),
            ("Group by file status - flat", 5)
        ]
        for (title, tag) in entries {
            let item = NSMenuItem(title: title, action: #selector(selectFileGrouping(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            button.menu?.addItem(item)
        }
        button.menu?.addItem(.separator())
        let dense = NSMenuItem(title: "Dense tree (merge single item with its folder node)", action: #selector(toggleTreePresentationOption(_:)), keyEquivalent: "")
        dense.target = self
        dense.tag = 10
        dense.state = usesDenseTree ? .on : .off
        dense.isEnabled = fileTreeMode
        button.menu?.addItem(dense)
        let groups = NSMenuItem(title: "Show group nodes in flat list (if multiple)", action: #selector(toggleTreePresentationOption(_:)), keyEquivalent: "")
        groups.target = self
        groups.tag = 11
        groups.state = showsGroupNodesInFlatList ? .on : .off
        groups.isEnabled = !fileTreeMode && fileGroupingMode != .path
        button.menu?.addItem(groups)
        if let menu = button.menu { fileGroupingMenus.append(menu) }
        return control
    }

    private func makeFileSettingsMenu(for table: NSTableView) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.isBordered = false
        button.controlSize = .small
        button.toolTip = "File list settings"
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        button.addItem(withTitle: "")
        button.itemArray.first?.title = ""
        button.itemArray.first?.image = AppKitFactory.resourceImage("Settings", accessibilityDescription: "File list settings")

        if table === unstagedTable {
            let ignoredFiles = NSMenuItem(title: "Show ignored files", action: #selector(toggleFileDiscovery(_:)), keyEquivalent: "")
            ignoredFiles.target = self
            ignoredFiles.tag = 0
            ignoredFiles.state = showsIgnoredFiles ? .on : .off
            button.menu?.addItem(ignoredFiles)
        }
        let skipWorktree = NSMenuItem(title: "Show skip-worktree files", action: #selector(toggleFileDiscovery(_:)), keyEquivalent: "")
        skipWorktree.target = self
        skipWorktree.tag = table === unstagedTable ? 1 : 3
        skipWorktree.state = (table === unstagedTable ? showsSkipWorktreeFiles : stagedShowsSkipWorktreeFiles) ? .on : .off
        button.menu?.addItem(skipWorktree)
        if table === unstagedTable {
            let assumeUnchanged = NSMenuItem(title: "Show assumed-unchanged files", action: #selector(toggleFileDiscovery(_:)), keyEquivalent: "")
            assumeUnchanged.target = self
            assumeUnchanged.tag = 2
            assumeUnchanged.state = showsAssumeUnchangedFiles ? .on : .off
            button.menu?.addItem(assumeUnchanged)
        }
        let untracked = NSMenuItem(title: "Show untracked files", action: #selector(toggleShowUntrackedFiles(_:)), keyEquivalent: "")
        untracked.target = self
        untracked.state = showsUntrackedFiles ? .on : .off
        untracked.isEnabled = table === unstagedTable
        button.menu?.addItem(untracked)
        button.menu?.addItem(.separator())

        let ignored = NSMenuItem(title: "Edit ignored files", action: #selector(editIgnoredFiles(_:)), keyEquivalent: "")
        ignored.target = self
        ignored.tag = 0
        button.menu?.addItem(ignored)
        let localIgnored = NSMenuItem(title: "Edit locally ignored files", action: #selector(editIgnoredFiles(_:)), keyEquivalent: "")
        localIgnored.target = self
        localIgnored.tag = 1
        button.menu?.addItem(localIgnored)
        button.menu?.addItem(.separator())
        if table === unstagedTable {
            let refreshOnFocus = NSMenuItem(title: "Refresh artificial commits on form focus", action: #selector(toggleRefreshOnFocus(_:)), keyEquivalent: "")
            refreshOnFocus.target = self
            refreshOnFocus.state = settings.commitPreferences.refreshOnFocus ? .on : .off
            button.menu?.addItem(refreshOnFocus)
            button.menu?.addItem(.separator())
        }
        let toolbar = NSMenuItem(title: "Toolbar", action: nil, keyEquivalent: "")
        button.menu?.addItem(toolbar)
        return button
    }

    @objc private func spellingDictionaryChanged() { CommitSpelling.apply(to: messageView) }

    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        guard view === messageView else { return menu }
        let nativeItems = menu.items
        menu.removeAllItems()
        for (offset, item) in CommitSpelling.menuItems(for: view, at: charIndex, target: self, replace: #selector(replaceMisspelledWord(_:)),
                                                       add: #selector(addWordToDictionary(_:)), ignore: #selector(ignoreMisspelledWord(_:)),
                                                       remove: #selector(removeWordFromDictionary(_:))).enumerated() {
            menu.insertItem(item, at: offset)
        }
        let edits: [(String, Selector)] = [
            ("Cut", #selector(NSText.cut(_:))), ("Copy", #selector(NSText.copy(_:))),
            ("Paste", #selector(NSText.paste(_:))), ("Delete", #selector(CommitMessageTextView.deleteSelectedMessageText(_:))),
            ("Select all", #selector(NSText.selectAll(_:)))
        ]
        for (title, action) in edits {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = messageView
            menu.addItem(item)
        }
        let wordWrap = NSMenuItem(title: "Word wrap (except subject line)", action: #selector(wordWrapCommitMessageBody), keyEquivalent: "")
        wordWrap.target = self
        menu.addItem(wordWrap)
        menu.addItem(.separator())
        menu.addItem(CommitSpelling.dictionaryMenuItem(target: self, action: #selector(selectSpellingDictionary(_:))))
        menu.addItem(.separator())
        let markIllFormed = NSMenuItem(title: "Mark ill formed lines", action: #selector(toggleMarkIllFormedLines(_:)), keyEquivalent: "")
        markIllFormed.target = self
        markIllFormed.state = settings.commitMessageEditorPreferences.markIllFormedLines ? .on : .off
        menu.addItem(markIllFormed)
        let completion = NSMenuItem(title: "Provide auto completion", action: #selector(toggleAutoCompletion(_:)), keyEquivalent: "")
        completion.target = self
        completion.state = settings.preferences.provideAutocompletion ? .on : .off
        menu.addItem(completion)
        let editActions = Set(edits.map(\.1) + [#selector(NSTextView.delete(_:))])
        let services = nativeItems.filter { $0.action.map { !editActions.contains($0) } ?? true }
        if services.contains(where: { !$0.isSeparatorItem }) {
            menu.addItem(.separator())
            for item in services where !item.isSeparatorItem || menu.items.last?.isSeparatorItem != true { menu.addItem(item) }
            if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        }
        return menu
    }

    @objc private func toggleAutoCompletion(_ sender: NSMenuItem) {
        var preferences = settings.preferences
        preferences.provideAutocompletion.toggle()
        settings.save(preferences)
        messageView.isAutomaticTextCompletionEnabled = preferences.provideAutocompletion
        refreshAutoCompleteWords()
    }

    @objc private func replaceMisspelledWord(_ sender: NSMenuItem) {
        guard let values = sender.representedObject as? [Any], let range = (values.first as? NSValue)?.rangeValue,
              let replacement = values.last as? String, messageView.shouldChangeText(in: range, replacementString: replacement) else { return }
        messageView.replaceCharacters(in: range, with: replacement)
        messageView.didChangeText()
    }

    @objc private func addWordToDictionary(_ sender: NSMenuItem) {
        guard let word = sender.representedObject as? String else { return }
        NSSpellChecker.shared.learnWord(word)
        messageView.checkTextInDocument(nil)
    }

    @objc private func ignoreMisspelledWord(_ sender: NSMenuItem) {
        guard let word = sender.representedObject as? String else { return }
        NSSpellChecker.shared.ignoreWord(word, inSpellDocumentWithTag: messageView.spellCheckerDocumentTag)
        messageView.checkTextInDocument(nil)
    }

    @objc private func removeWordFromDictionary(_ sender: NSMenuItem) {
        guard let word = sender.representedObject as? String else { return }
        NSSpellChecker.shared.unlearnWord(word)
        messageView.checkTextInDocument(nil)
    }

    @objc private func selectSpellingDictionary(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        AppSettingsStore.shared.spellingDictionary = name
    }

    @objc private func toggleFileDiscovery(_ sender: NSMenuItem) {
        switch sender.tag {
        case 0: showsIgnoredFiles.toggle(); sender.state = showsIgnoredFiles ? .on : .off
        case 1: showsSkipWorktreeFiles.toggle(); sender.state = showsSkipWorktreeFiles ? .on : .off
        case 2: showsAssumeUnchangedFiles.toggle(); sender.state = showsAssumeUnchangedFiles ? .on : .off
        default: stagedShowsSkipWorktreeFiles.toggle(); sender.state = stagedShowsSkipWorktreeFiles ? .on : .off
        }
        reloadChanges(preserveMessage: true)
    }

    @objc private func toggleFileToolbarItem(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        var preferences = settings.fileStatusListPreferences
        if preferences.hiddenToolbarItems.contains(name) { preferences.hiddenToolbarItems.removeAll { $0 == name } }
        else { preferences.hiddenToolbarItems.append(name) }
        settings.saveFileStatusListPreferences(preferences)
        applyFileToolbarVisibility()
    }

    private func applyFileToolbarVisibility() {
        let hidden = Set(settings.fileStatusListPreferences.hiddenToolbarItems)
        for items in fileToolbarItems.values {
            let refreshVisible = items.contains { $0.name == "btnRefresh" } && !hidden.contains("btnRefresh")
            for item in items {
                switch item.name {
                case "btnCollapseGroups", "sepRefresh": item.view.isHidden = true
                case "sepAsTree": item.view.isHidden = hidden.contains(item.name) || !refreshVisible
                default: item.view.isHidden = hidden.contains(item.name)
                }
            }
        }
        for menu in fileToolbarMenus {
            for item in menu.items { item.state = (item.representedObject as? String).map { hidden.contains($0) ? .off : .on } ?? .off }
        }
    }

    private func transferToolbar(unstageAll: NSButton, unstage: NSButton, stage: NSButton, stageAll: NSButton) -> NSView {
        for button in [unstageAll, unstage, stage, stageAll] {
            let isStage = button === stage || button === stageAll
            let isAll = button === stageAll || button === unstageAll
            button.image = AppKitFactory.resourceImage(isStage ? (isAll ? "StageAll" : "Stage") : (isAll ? "UnstageAll" : "Unstage"), accessibilityDescription: isStage ? "Stage" : "Unstage")
            button.isBordered = false
            button.toolTip = button === stageAll ? "Stage all" : button === stage ? "Stage selected" : button === unstageAll ? "Unstage all" : "Unstage selected"
            if isAll {
                button.title = ""
                button.imagePosition = .imageOnly
                button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            } else {
                button.title = isStage ? "Stage" : "Unstage"
                button.imagePosition = .imageLeading
                button.imageHugsTitle = true
                button.font = AppSettingsStore.shared.applicationFont(size: 12)
                button.widthAnchor.constraint(greaterThanOrEqualToConstant: isStage ? 70 : 82).isActive = true
            }
        }
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [unstageAll, unstage, spacer, stage, stageAll])
        bar.orientation = .horizontal; bar.alignment = .centerY; bar.spacing = 5
        bar.edgeInsets = NSEdgeInsets(top: 3, left: 5, bottom: 3, right: 5)
        return bar
    }

    private func configureDocumentView(_ textView: NSTextView, width: CGFloat, height: CGFloat) {
        textView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
    }

    private func selectedChangedFile() -> ChangedFile? {
        selectedLeafFile(in: unstagedTable) ?? selectedLeafFile(in: stagedTable)
    }

    @objc private func toggleFileTree(_ sender: NSButton) {
        fileTreeMode.toggle()
        updateFileGroupingControls()
        persistFileListPreferences()
        reloadFileTrees()
        status.stringValue = fileTreeMode
            ? "File list: tree view"
            : "File list: flat view"
    }

    @objc private func selectFileGrouping(_ sender: NSMenuItem) {
        fileGroupingMode = switch sender.tag {
        case 2, 3: .fileExtension
        case 4, 5: .status
        default: .path
        }
        fileTreeMode = sender.tag.isMultiple(of: 2)
        updateFileGroupingControls()
        persistFileListPreferences()
        reloadFileTrees()
        status.stringValue = sender.title
    }

    @objc private func selectDirectFileGrouping(_ sender: NSButton) {
        fileGroupingMode = switch sender.tag {
        case 1: .fileExtension
        case 2: .status
        default: .path
        }
        updateFileGroupingControls()
        persistFileListPreferences()
        reloadFileTrees()
        status.stringValue = sender.toolTip ?? "File list grouping updated."
    }

    @objc private func toggleTreePresentationOption(_ sender: NSMenuItem) {
        if sender.tag == 10 {
            usesDenseTree.toggle()
            sender.state = usesDenseTree ? .on : .off
        } else {
            showsGroupNodesInFlatList.toggle()
            sender.state = showsGroupNodesInFlatList ? .on : .off
        }
        persistFileListPreferences()
        reloadFileTrees()
    }

    private func persistFileListPreferences() {
        var preferences = settings.fileStatusListPreferences
        preferences.grouping = fileGroupingMode
        preferences.isTreeMode = fileTreeMode
        preferences.usesDenseTree = usesDenseTree
        preferences.showsGroupNodesInFlatList = showsGroupNodesInFlatList
        preferences.showsUntrackedFiles = showsUntrackedFiles
        settings.saveFileStatusListPreferences(preferences)
    }

    private func updateFileGroupingControls() {
        fileTreeButtons.forEach { $0.state = fileTreeMode ? .on : .off }
        fileGroupingButtons.forEach { button in
            let grouping: FileStatusGrouping = switch button.tag {
            case 1: .fileExtension
            case 2: .status
            default: .path
            }
            button.state = grouping == fileGroupingMode ? .on : .off
        }
        fileGroupingMenus.forEach { menu in
            for item in menu.items {
                if item.action == #selector(selectFileGrouping(_:)) {
                    let itemGrouping: FileStatusGrouping = switch item.tag {
                    case 2, 3: .fileExtension
                    case 4, 5: .status
                    default: .path
                    }
                    let itemIsTree = item.tag.isMultiple(of: 2)
                    item.state = itemGrouping == fileGroupingMode && itemIsTree == fileTreeMode ? .on : .off
                } else if item.tag == 10 {
                    item.state = usesDenseTree ? .on : .off
                    item.isEnabled = fileTreeMode
                } else if item.tag == 11 {
                    item.state = showsGroupNodesInFlatList ? .on : .off
                    item.isEnabled = !fileTreeMode && fileGroupingMode != .path
                }
            }
        }
    }

    @objc private func openContainingFolder(_ sender: NSButton) {
        guard let file = selectedChangedFile(), let context = repositoryContext else {
            status.stringValue = "Select a file first."
            return
        }
        let url = URL(fileURLWithPath: context.repository.path).appendingPathComponent(file.path).deletingLastPathComponent()
        NSWorkspace.shared.open(url)
    }

    @objc private func viewSelectedFile(_ sender: NSButton) {
        guard let file = selectedChangedFile(), let context = repositoryContext else {
            status.stringValue = "Select a file first."
            return
        }
        let url = URL(fileURLWithPath: context.repository.path).appendingPathComponent(file.path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            status.stringValue = "The selected file is not present in the working directory."
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func focusFileFilter() {
        view.window?.makeFirstResponder(unstagedTable.selectedRow >= 0 ? unstagedFilter : stagedFilter)
    }


    @objc private func editIgnoredFiles(_ sender: NSMenuItem) {
        guard let window = view.window else { return }
        onEditIgnoredFiles?(sender.tag == 1, window) { [weak self] in self?.reloadChanges(preserveMessage: true) }
    }

    @objc private func toggleRefreshOnFocus(_ sender: NSMenuItem) {
        var preferences = settings.commitPreferences
        preferences.refreshOnFocus.toggle()
        settings.saveCommitPreferences(preferences)
        sender.state = preferences.refreshOnFocus ? .on : .off
    }

    @objc private func toggleShowUntrackedFiles(_ sender: NSMenuItem) {
        showsUntrackedFiles.toggle()
        sender.state = showsUntrackedFiles ? .on : .off
        persistFileListPreferences()
        reloadFileTrees()
    }

    private func displayedFiles(for tableView: NSOutlineView) -> [ChangedFile] {
        var files = tableView === unstagedTable ? unstaged : staged
        if tableView === unstagedTable, !showsUntrackedFiles {
            files.removeAll { $0.changeType == .added }
        }
        let query = (tableView === unstagedTable ? unstagedFilter : stagedFilter)
            .stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            if let expression = try? NSRegularExpression(pattern: query, options: [.caseInsensitive]) {
                files = files.filter { file in
                    let range = NSRange(file.path.startIndex..<file.path.endIndex, in: file.path)
                    return expression.firstMatch(in: file.path, range: range) != nil
                }
            } else {
                files = []
            }
        }
        return files
    }

    private func rootNodes(for outlineView: NSOutlineView) -> [ChangedFileNode] {
        outlineView === unstagedTable ? unstagedRootNodes : stagedRootNodes
    }

    private func reloadFileTrees(preserveSelection: Bool = true) {
        let unstagedPaths = preserveSelection ? selectedPaths(in: unstagedTable) : []
        let stagedPaths = preserveSelection ? selectedPaths(in: stagedTable) : []
        unstagedRootNodes = ChangedFileListTreeBuilder.build(
            files: displayedFiles(for: unstagedTable),
            grouping: fileGroupingMode,
            isTreeMode: fileTreeMode,
            usesDenseTree: usesDenseTree,
            showsGroupNodesInFlatList: showsGroupNodesInFlatList
        )
        stagedRootNodes = ChangedFileListTreeBuilder.build(
            files: displayedFiles(for: stagedTable),
            grouping: fileGroupingMode,
            isTreeMode: fileTreeMode,
            usesDenseTree: usesDenseTree,
            showsGroupNodesInFlatList: showsGroupNodesInFlatList
        )
        for table in [unstagedTable, stagedTable] {
            table.reloadData()
            rootNodes(for: table).forEach { table.expandItem($0, expandChildren: true) }
        }
        fileCollapseButtons.forEach { button in
            let table = button.tag == 0 ? unstagedTable : stagedTable
            button.isEnabled = rootNodes(for: table).contains { !$0.children.isEmpty }
        }
        restoreSelection(paths: unstagedPaths, in: unstagedTable)
        restoreSelection(paths: stagedPaths, in: stagedTable)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? ChangedFileNode)?.children.count ?? rootNodes(for: outlineView).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? ChangedFileNode)?.children[index] ?? rootNodes(for: outlineView)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? ChangedFileNode)?.children.isEmpty == false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? ChangedFileNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("ChangedFile")
        let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? ChangedFileCellView) ?? ChangedFileCellView()
        cell.identifier = identifier
        cell.apply(node: node)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        GitExtensionsSelectionRowView()
    }

    private func selectedFiles(in outlineView: NSOutlineView) -> [ChangedFile] {
        var seen = Set<String>()
        return outlineView.selectedRowIndexes.flatMap { row -> [ChangedFile] in
            guard let node = outlineView.item(atRow: row) as? ChangedFileNode else { return [] }
            return node.descendantFiles
        }.filter { seen.insert($0.id).inserted }
    }

    private func selectedLeafFile(in outlineView: NSOutlineView) -> ChangedFile? {
        guard outlineView.selectedRowIndexes.count == 1,
              let row = outlineView.selectedRowIndexes.first,
              let node = outlineView.item(atRow: row) as? ChangedFileNode else { return nil }
        return node.file
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.identifier?.rawValue == "unstaged" || menu.identifier?.rawValue == "staged" else { return }
        let table = menu.identifier?.rawValue == "unstaged" ? unstagedTable : stagedTable
        if table.clickedRow >= 0, !table.selectedRowIndexes.contains(table.clickedRow) {
            table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
        }
        menu.removeAllItems()
        let files = selectedFiles(in: table)
        let scripts = NSMenuItem(title: "Scripts", action: nil, keyEquivalent: "")
        scripts.submenu = ApplicationScriptsMenu(placement: .files, execute: { [weak self] in self?.executeScript($0) })
        menu.addItem(scripts)
        let mutation = NSMenuItem(
            title: table === unstagedTable ? "Stage selected" : "Unstage selected",
            action: table === unstagedTable ? #selector(stageSelected) : #selector(unstageSelected),
            keyEquivalent: ""
        )
        mutation.target = self
        mutation.isEnabled = !files.isEmpty && actionTask == nil
        menu.addItem(mutation)
        let all = NSMenuItem(
            title: table === unstagedTable ? "Stage all" : "Unstage all",
            action: table === unstagedTable ? #selector(stageEveryFile) : #selector(unstageEveryFile),
            keyEquivalent: ""
        )
        all.target = self
        all.isEnabled = !displayedFiles(for: table).isEmpty && actionTask == nil
        menu.addItem(all)
        menu.addItem(.separator())

        let open = NSMenuItem(title: "Open file", action: #selector(openContextFile(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = files.first?.path
        open.isEnabled = files.count == 1 && files.first?.changeType != .deleted
        menu.addItem(open)
        let reveal = NSMenuItem(title: "Show in Finder", action: #selector(revealContextFile(_:)), keyEquivalent: "")
        reveal.target = self
        reveal.representedObject = files.first?.path
        reveal.isEnabled = files.count == 1
        menu.addItem(reveal)
        let copy = NSMenuItem(title: "Copy path", action: #selector(copyContextPaths(_:)), keyEquivalent: "")
        copy.target = self
        copy.representedObject = files.map(\.path)
        copy.isEnabled = !files.isEmpty
        menu.addItem(copy)
        let blame = NSMenuItem(title: "Blame", action: #selector(blameContextFile(_:)), keyEquivalent: "b")
        blame.keyEquivalentModifierMask = []
        blame.target = self
        blame.representedObject = files.first
        blame.isEnabled = onBlame != nil && head?.objectID != nil && files.count == 1 && files.first?.isTracked == true && files.first?.isSubmodule != true
        menu.addItem(blame)
        let history = NSMenuItem(title: "File history", action: #selector(historyContextFile(_:)), keyEquivalent: "h")
        history.keyEquivalentModifierMask = []; history.target = self; history.representedObject = files.first
        history.isEnabled = onFileHistory != nil && files.count == 1 && files.first?.isTracked == true
        menu.addItem(history)
        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "Refresh", action: #selector(refreshChanges), keyEquivalent: "")
        refresh.target = self
        refresh.isEnabled = actionTask == nil
        menu.addItem(refresh)
    }

    @objc private func openContextFile(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String,
              let repository = repositoryContext?.repository else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: repository.path).appendingPathComponent(path))
    }

    @objc private func historyContextFile(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? ChangedFile, let commitWindow else { return }
        onFileHistory?(file, commitWindow)
    }

    @objc private func blameContextFile(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? ChangedFile, let commitWindow else { return }
        onBlame?(file, commitWindow)
    }

    @objc private func revealContextFile(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String,
              let repository = repositoryContext?.repository else { return }
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: repository.path).appendingPathComponent(path)
        ])
    }

    @objc private func copyContextPaths(_ sender: NSMenuItem) {
        guard let paths = sender.representedObject as? [String], !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSOutlineView else { return }
        if table === unstagedTable, !table.selectedRowIndexes.isEmpty {
            stagedTable.deselectAll(nil)
        } else if table === stagedTable, !table.selectedRowIndexes.isEmpty {
            unstagedTable.deselectAll(nil)
        }
        updateButtonStates()
        loadSelectedDiff(from: table)
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === author {
            updateStatus()
            return
        }
        if notification.object as? NSComboBox === selectionFilterBox {
            selectionFilterTextChanged(selectionFilterBox.stringValue)
            return
        }
        guard let field = notification.object as? NSSearchField,
              field === unstagedFilter || field === stagedFilter else { return }
        reloadFileTrees()
        updateButtonStates()
        let query = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty, (try? NSRegularExpression(pattern: query)) == nil {
            status.stringValue = "The file filter is not a valid regular expression."
        }
    }

    private func reloadChanges(preserveMessage: Bool = false, preferredPath: String? = nil, transfer: (source: NSOutlineView, next: String?, moved: [String])? = nil) {
        commitDiffView.previewPresentation.cancel()
        loadTask?.cancel()
        diffLoadTask?.cancel()
        let preservedMessage = messageView.string
        let unstagedSelection = preferredPath ?? selectedPaths(in: unstagedTable).first
        let stagedSelection = preferredPath ?? selectedPaths(in: stagedTable).first
        commitButton.isEnabled = false
        commitAndPushButton.isEnabled = false
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                loadTask = nil
                updateButtonStates()
            }
            do {
                async let repositoryStateValue = source.loadRepositoryState()
                async let stateValue = source.loadCommitState(
                    historyLimit: settings.commitPreferences.historyLimit,
                    showOnlyMyMessages: showOnlyMyMessages,
                    rememberAmend: settings.commitPreferences.rememberAmendState
                )
                let repositoryState = try await repositoryStateValue
                let context = repositoryState.commitContext
                let artificial = RevisionCommitBuilder.artificialRevisions(headID: context.headID)
                guard let worktree = artificial.first(where: { $0.kind == .workingDirectory }),
                      let index = artificial.first(where: { $0.kind == .index }) else {
                    throw RepositoryDataSourceError.unavailable
                }
                async let worktreeDetails = source.loadRevisionDetails(for: worktree)
                async let indexDetails = source.loadRevisionDetails(for: index)
                let (worktreeValue, indexValue, loadedCommitState) = try await (worktreeDetails, indexDetails, stateValue)
                guard !Task.isCancelled else { return }
                repositoryContext = context
                networkContext = repositoryState.networkContext
                commitState = loadedCommitState
                if preserveMessage {
                    messageView.string = preservedMessage
                } else if !composesMessage {
                    messageView.string = loadedCommitState.loadedTemplate ?? ""
                    usingTemplate = loadedCommitState.loadedTemplate != nil
                } else if draft == nil, commandLineMessage == nil, activeSpecialKind == nil, !loadedCommitState.message.isEmpty {
                    messageView.string = loadedCommitState.message
                    usingTemplate = loadedCommitState.loadedTemplate != nil
                }
                updateMessageWatermark()
                if draft == nil, initialMode == .normal, loadedCommitState.rememberedAmend {
                    amend.state = .on
                    selectedCommitMode = .amend
                    if composesMessage, messageView.string.isEmpty { messageView.string = headMessage() }
                    modeChanged()
                }
                configureMessageMenu()
                configureTemplatesMenu()
                configureOptionsMenu()
                let branch = context.branches.first(where: \.isCurrent)?.name ?? "detached HEAD"
                commitWindow?.title = "Commit to \(branch) (\(context.repository.path))"
                remoteNameLink.isEnabled = onManageRemotes != nil && context.branches.contains(where: \.isCurrent)
                var discovered: [ChangedFile] = []
                if showsIgnoredFiles || showsAssumeUnchangedFiles || showsSkipWorktreeFiles,
                   let files = source as? any RepositoryFileStatusDataSource {
                    let existing = Set(worktreeValue.files.map(\.path))
                    discovered = try await files.workingTreeDiscoveryFiles(ignored: showsIgnoredFiles, assumeUnchanged: showsAssumeUnchangedFiles,
                                                                         skipWorktree: showsSkipWorktreeFiles).filter { !existing.contains($0.path) }
                    guard !Task.isCancelled else { return }
                }
                unstaged = worktreeValue.files + discovered
                staged = indexValue.files
                reloadFileTrees(preserveSelection: false)
                if let transfer {
                    let target = transfer.source === unstagedTable ? stagedTable : unstagedTable
                    if displayedFiles(for: transfer.source).isEmpty {
                        restoreSelection(paths: transfer.moved, in: target)
                        commitWindow?.makeFirstResponder(target)
                    } else {
                        target.deselectAll(nil)
                        transfer.source.deselectAll(nil)
                        restoreSelection(path: transfer.next, in: transfer.source)
                        commitWindow?.makeFirstResponder(transfer.source)
                    }
                } else {
                    restoreSelection(path: unstagedSelection, in: unstagedTable)
                    restoreSelection(path: stagedSelection, in: stagedTable)
                    if unstagedTable.selectedRow < 0, stagedTable.selectedRow < 0 {
                        let table = unstaged.isEmpty ? stagedTable : unstagedTable
                        if let row = firstFileRow(in: table) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
                    }
                }
                updateStatus()
                refreshAutoCompleteWords()
                setInitialFocusIfNeeded()
                if let loadError = loadedCommitState.messageLoadError,
                   loadError != lastShownMessageLoadError,
                   let commitWindow {
                    lastShownMessageLoadError = loadError
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Commit message could not be loaded"
                    alert.informativeText = loadError
                    alert.addButton(withTitle: "OK")
                    _ = await begin(alert, window: commitWindow)
                }
            } catch is CancellationError {
                return
            } catch {
                status.stringValue = error.localizedDescription
            }
        }
    }

    @objc private func manageTracking() {
        guard let branch = repositoryContext?.branches.first(where: \.isCurrent)?.name else { return }
        refreshPushTargetOnFocus = true
        onManageRemotes?(nil, branch)
    }

    private func loadSelectedDiff(from table: NSOutlineView) {
        guard let file = selectedLeafFile(in: table), let context = repositoryContext else { return }
        let kind: Commit.Kind = table === unstagedTable ? .workingDirectory : .index
        guard let commit = RevisionCommitBuilder.artificialRevisions(headID: context.headID)
            .first(where: { $0.kind == kind }) else { return }
        diffLoadTask?.cancel()
        commitDiffView.apply(file: file, diff: nil, direction: table === unstagedTable ? .stage : .unstage)
        let headless = context.headID == nil && kind == .index
        diffLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if CommitFileContentPresentation.viewsAsFileContent(file, headless: headless), let browsing = source as? any RepositoryBrowsingDataSource,
                   let preview = try await fileContentPreview(file: file, commit: commit, source: browsing) {
                    guard !Task.isCancelled else { return }
                    commitDiffView.apply(file: file, preview: preview, direction: table === unstagedTable ? .stage : .unstage)
                    return
                }
                let preview = try await source.prepareDiff(
                    for: commit,
                    file: file,
                    options: commitDiffView.diffOptions
                )
                guard !Task.isCancelled else { return }
                commitDiffView.apply(
                    file: file,
                    preview: preview,
                    direction: table === unstagedTable ? .stage : .unstage
                )
            } catch is CancellationError {
                return
            } catch {
                status.stringValue = error.localizedDescription
            }
        }
    }

    private func fileContentPreview(file: ChangedFile, commit: Commit, source: any RepositoryBrowsingDataSource) async throws -> FilePreview<FileDiff?>? {
        let entry: RepositoryFileEntry
        if commit.kind == .workingDirectory {
            entry = RepositoryFileEntry(path: file.path, content: "")
        } else if let indexed = try await source.loadRepositoryFiles(for: commit).first(where: { $0.path == file.path }) {
            entry = indexed
        } else {
            return nil
        }
        let id = file.id
        let convert: @Sendable (RepositoryFileContent) -> FileDiff? = { content in
            content.kind == .text ? CommitFileContentPresentation.numberedText(content.text, id: id) : nil
        }
        switch try await source.prepareFilePresentation(for: commit, file: entry, encoding: .automatic) {
        case .ready(let content):
            guard content.kind == .text else { return nil }
            return .ready(convert(content))
        case .deferred(let length, let load):
            return .deferred(length: length) { convert(try await load()) }
        }
    }

    @objc private func stageSelected() {
        mutate(paths: mutationPaths(for: selectedFiles(in: unstagedTable)), stage: true)
    }

    @objc private func unstageSelected() {
        mutate(paths: mutationPaths(for: selectedFiles(in: stagedTable)), stage: false)
    }

    @objc private func stageEveryFile() { mutateAll(stage: true) }
    @objc private func unstageEveryFile() { mutateAll(stage: false) }

    private func mutate(paths: [String], stage: Bool) {
        guard !paths.isEmpty else { status.stringValue = "Select at least one file."; return }
        let sourceTable = stage ? unstagedTable : stagedTable
        let rows = (0..<sourceTable.numberOfRows).compactMap { (sourceTable.item(atRow: $0) as? ChangedFileNode)?.file?.path }
        let moved = selectedPaths(in: sourceTable)
        let next = CommitWorkflowDialog.nextItemToSelect(rows: rows, selected: Set(moved))
        actionTask?.cancel()
        actionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { actionTask = nil; updateButtonStates() }
            do {
                status.stringValue = stage ? "Staging…" : "Unstaging…"
                _ = try await (stage ? source.stage(paths: paths, showErrors: settings.preferences.showErrorsWhenStagingFiles) : source.unstage(paths: paths))
                reloadChanges(preserveMessage: true, transfer: (sourceTable, next, moved))
            } catch { await stagingFailed(error, stage: stage, count: paths.count) }
        }
    }

    private func mutateAll(stage: Bool) {
        let filter = stage ? unstagedFilter.stringValue : stagedFilter.stringValue
        let visibleFiles = displayedFiles(for: stage ? unstagedTable : stagedTable)
        let visiblePaths = mutationPaths(for: visibleFiles)
        let preferredPath = visibleFiles.first?.path
        actionTask?.cancel()
        actionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { actionTask = nil; updateButtonStates() }
            do {
                status.stringValue = stage ? "Staging all…" : "Unstaging all…"
                let showErrors = settings.preferences.showErrorsWhenStagingFiles
                if filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    _ = try await (stage ? source.stageAll(showErrors: showErrors) : source.unstageAll())
                } else {
                    guard !visiblePaths.isEmpty else { throw RepositoryMutationError.noPaths }
                    _ = try await (stage ? source.stage(paths: visiblePaths, showErrors: showErrors) : source.unstage(paths: visiblePaths))
                }
                if stage { unstagedFilter.stringValue = "" } else { stagedFilter.stringValue = "" }
                reloadChanges(preserveMessage: true, preferredPath: preferredPath)
            } catch { await stagingFailed(error, stage: stage, count: visiblePaths.count) }
        }
    }

    private func stagingFailed(_ error: Error, stage: Bool, count: Int) async {
        guard stage, !(error is CancellationError) else {
            await showOperationError(error, title: stage ? "Stage failed" : "Unstage failed")
            return
        }
        if settings.preferences.showErrorsWhenStagingFiles {
            await showOperationError(error, title: "Stage Details")
        }
        reloadChanges(preserveMessage: true)
    }

    private func applySelectedHunk(lineID: String, direction: RepositoryHunkDirection) {
        guard let selection = commitDiffView.currentSelection(lineID: lineID, direction: direction) else { return }
        actionTask?.cancel()
        actionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { actionTask = nil; updateButtonStates() }
            do {
                status.stringValue = direction == .stage ? "Staging selected hunk…" : "Unstaging selected hunk…"
                _ = try await source.applyHunk(selection)
                reloadChanges(preserveMessage: true, preferredPath: selection.file.path)
            } catch {
                commitDiffView.allowPatching()
                await showOperationError(error, title: direction == .stage ? "Stage hunk failed" : "Unstage hunk failed")
            }
        }
    }

    private func applySelectedLines(lineIDs: Set<String>, direction: RepositoryHunkDirection) {
        guard let selection = commitDiffView.currentLineSelection(lineIDs: lineIDs, direction: direction) else { return }
        actionTask?.cancel()
        actionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { actionTask = nil; updateButtonStates() }
            do {
                status.stringValue = direction == .stage ? "Staging selected line(s)…" : "Unstaging selected line(s)…"
                _ = try await source.applyLines(selection)
                reloadChanges(preserveMessage: true, preferredPath: selection.file.path)
            } catch {
                commitDiffView.allowPatching()
                await showOperationError(error, title: direction == .stage ? "Stage lines failed" : "Unstage lines failed")
            }
        }
    }

    private func resetSelectedLines(lineIDs: Set<String>, direction: RepositoryHunkDirection) {
        guard let selection = commitDiffView.currentLineSelection(lineIDs: lineIDs, direction: direction) else { return }
        actionTask?.cancel()
        actionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { actionTask = nil; updateButtonStates() }
            do {
                _ = try await source.resetLines(selection)
                reloadChanges(preserveMessage: true, preferredPath: selection.file.path)
            } catch {
                commitDiffView.allowPatching()
                await showOperationError(error, title: "Reset lines failed")
            }
        }
    }

    private func addSelectedDiffTextToMessage(_ text: String) {
        guard !text.isEmpty, messageView.isEditable else { return }
        let selection = messageView.selectedRange()
        let insertion = selection.length == 0 ? text + "\n" : text
        messageView.insertText(insertion, replacementRange: selection)
        commitWindow?.makeFirstResponder(messageView)
    }

    @objc private func modeChanged() {
        amendPanel.isHidden = selectedCommitMode == .normal
        stageAll.isEnabled = selectedCommitMode != .amendMessageOnly
        updateButtonStates()
    }

    @objc private func amendChanged() {
        if amend.state == .off { resetAuthor.state = .off }
        selectedCommitMode = amend.state == .on ? .amend : .normal
        if composesMessage, amend.state == .on, messageView.string.isEmpty { messageView.string = headMessage() }
        modeChanged()
    }

    @objc private func modifySpecialCommitMessage() {
        activeSpecialKind = nil
        applySpecialCommitState()
        commitWindow?.makeFirstResponder(messageView)
    }

    private func applySpecialCommitState() {
        let isSpecial = activeSpecialKind != nil
        let canChangeMessage = composesMessage && !isSpecial
        messageView.isEditable = canChangeMessage
        messageMenu.isEnabled = canChangeMessage
        templatesMenu.isEnabled = canChangeMessage
        amend.isHidden = isSpecial
        amendPanel.isHidden = isSpecial || currentCommitMode == .normal
        modifyCommitMessageButton.isHidden = !(composesMessage && isSpecial)
        updateMessageWatermark()
    }

    @objc private func refreshChanges() { reloadChanges(preserveMessage: true) }

    @objc private func stashStagedChanges() {
        guard !staged.isEmpty else { status.stringValue = "There are no staged changes to stash."; return }
        actionTask?.cancel()
        actionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { actionTask = nil; updateButtonStates() }
            do {
                status.stringValue = "Stashing staged changes…"
                _ = try await source.createStash(RepositoryStashCreateRequest(message: "", includeUntracked: false, keepIndex: false, stagedOnly: true))
                reloadChanges(preserveMessage: true)
            } catch { await showOperationError(error, title: "Stash staged changes failed") }
        }
    }

    @objc private func commit() {
        performCommit(pushAfter: false)
    }

    @objc private func solveMergeConflicts() {
        resolveConflicts()
    }

    @objc private func commitAndPush() {
        performCommit(pushAfter: true)
    }

    private func performCommit(pushAfter: Bool) {
        guard actionTask == nil, let commitWindow else { return }
        if pushAfter,
           currentCommitMode == .normal,
           staged.isEmpty,
           unstaged.isEmpty {
            openPush(context: networkContext, forceWithLease: false)
            return
        }
        actionTask = Task { @MainActor [weak self, weak commitWindow] in
            guard let self, let commitWindow else { return }
            defer { actionTask = nil; updateButtonStates() }
            scriptHooks?.begin()
            defer { scriptHooks?.end() }
            let originalMutationState = try? await source.loadMutationState()
            do {
                let message = messageView.string
                var shouldStageAll = stageAll.state == .on
                var shouldAllowEmpty = false
                if currentCommitMode != .normal {
                    if settings.commitPreferences.confirmAmend, !(await confirmAmend(window: commitWindow)) { return }
                } else if staged.isEmpty, !shouldStageAll {
                    if commitState?.isMergeCommit == true {
                        guard await confirmEmptyMerge(window: commitWindow) else { return }
                        shouldAllowEmpty = true
                    } else {
                        guard let choice = await noStagedChoice(window: commitWindow) else { return }
                        switch choice {
                        case .stage:
                            let filtered = mutationPaths(for: displayedFiles(for: unstagedTable))
                            if !unstagedFilter.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                guard !filtered.isEmpty else { throw RepositoryMutationError.noPaths }
                                _ = try await source.stage(paths: filtered)
                                shouldStageAll = false
                            } else {
                                shouldStageAll = true
                            }
                        case .empty:
                            shouldAllowEmpty = true
                        }
                    }
                }
                if !(commitState?.mutationState.conflictedPaths.isEmpty ?? true) {
                    let alert = NSAlert()
                    alert.alertStyle = .critical
                    alert.messageText = "Merge conflicts"
                    alert.informativeText = "There are unresolved merge conflicts, solve merge conflicts before committing."
                    alert.addButton(withTitle: "OK")
                    _ = await begin(alert, window: commitWindow)
                    return
                }
                guard !composesMessage || (!message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && !(usingTemplate && message == commitState?.loadedTemplate)) else {
                    status.stringValue = "Please enter a commit message."
                    commitWindow.makeFirstResponder(messageView)
                    return
                }
                let authorValue = author.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !authorValue.isEmpty,
                   authorValue.range(of: #"^.+\s<[^<>]+>$"#, options: .regularExpression) == nil {
                    status.stringValue = "Author must use the format Name <email@example.com>."
                    commitWindow.makeFirstResponder(author)
                    return
                }
                if commitState?.mutationState.currentBranch == nil,
                   settings.commitPreferences.confirmDetachedHead,
                   !(await resolveDetachedHead(window: commitWindow)) {
                    return
                }

                let validationContext = validationContext(for: message)
                let issues = !composesMessage ? [] : CommitMessageValidator.issues(
                    in: message,
                    preferences: settings.commitPreferences.validation,
                    skipRegularExpression: validationContext.skipRegularExpression,
                    regularExpressionText: validationContext.regularExpressionText
                )
                for issue in issues {
                    if !(await confirmValidationIssue(issue, window: commitWindow)) { return }
                }

                let request = RepositoryCommitRequest(
                    message: message,
                    mode: currentCommitMode,
                    stageAllBeforeCommit: shouldStageAll,
                    allowEmpty: shouldAllowEmpty,
                    signOff: signOff.state == .on,
                    author: authorValue.isEmpty ? nil : authorValue,
                    resetAuthor: resetAuthor.state == .on,
                    noVerify: noVerify,
                    gpgSigning: gpgSigning,
                    messageEncoding: commitState?.commitEncoding,
                    usingTemplate: usingTemplate,
                    ensureSecondLineEmpty: settings.commitPreferences.ensureSecondLineEmpty,
                    composesMessage: composesMessage
                )
                commitButton.isEnabled = false
                commitAndPushButton.isEnabled = false
                status.stringValue = currentCommitMode == .normal ? "Committing…" : "Amending…"
                let wasAmend = currentCommitMode != .normal
                let hooks = scriptHooks
                let scriptContext = scriptFileContext
                let result = try await OutputHistoryRecording.perform {
                    try await source.commit(request, beforeExecution: {
                        guard await hooks?.runWithOptions(.beforeCommit, options: scriptContext) != false else { throw CancellationError() }
                    })
                }
                onRepositoryChanged(result.selectedCommitID)
                _ = await scriptHooks?.runWithOptions(.afterCommit, options: scriptContext)
                let repositoryState = try await source.loadRepositoryState()
                repositoryContext = repositoryState.commitContext
                networkContext = repositoryState.networkContext
                var preferences = settings.commitPreferences
                if composesMessage { preferences.lastCommitMessage = message }
                settings.saveCommitPreferences(preferences)
                noVerify = false
                usingTemplate = false
                activeSpecialKind = nil
                applySpecialCommitState()
                status.stringValue = result.message

                let superprojectTarget = stageInSuperproject.isHidden ? nil : CommitSuperprojectStaging.target(
                    location: superprojectSubmodule, preference: settings.commitMessageEditorPreferences.stageInSuperprojectAfterCommit)
                if pushAfter {
                    pendingSuperprojectStage = superprojectTarget
                    openPush(
                        context: networkContext,
                        forceWithLease: (wasAmend || historyWasSoftReset) && preferences.forceWithLeaseAfterAmend
                    )
                    if pushWindowController == nil { pendingSuperprojectStage = nil }
                } else if CommitSuperprojectStaging.shouldStage(target: superprojectTarget, pushRequested: false, pushCompleted: false),
                          let superprojectTarget {
                    await stageSubmoduleInSuperproject(superprojectTarget)
                }
                historyWasSoftReset = false
                let newState = try await source.loadMutationState()
                if preferences.closeAfterCommit || (preferences.closeAfterLastCommit && !newState.isDirty) {
                    if pushAfter, pushWindowController != nil {
                        persistDraftOnClose = false
                        closeWhenPushCompletes = true
                    } else {
                        closeAfterSuccessfulCommit()
                    }
                } else {
                    messageView.string = ""
                    amend.state = .off
                    selectedCommitMode = .normal
                    modeChanged()
                    reloadChanges()
                }
            } catch is CancellationError {
                if let before = originalMutationState, let after = try? await source.loadMutationState(), before != after {
                    onRepositoryChanged(nil)
                }
                status.stringValue = "Commit cancelled."
                reloadChanges(preserveMessage: true)
                return
            } catch {
                if let before = originalMutationState, let after = try? await source.loadMutationState(), before != after {
                    onRepositoryChanged(nil)
                }
                status.stringValue = error.localizedDescription
                await showOperationError(error, title: "Commit failed")
                reloadChanges(preserveMessage: true)
            }
        }
    }

    private var scriptFileContext: [String: [String]] {
        ["SelectedRelativePaths": selectedPaths(in: unstagedTable) + selectedPaths(in: stagedTable),
         "LineNumber": [String(commitDiffView.scriptLineNumber)], "ColumnNumber": ["1"]]
    }

    private func executeScript(_ script: ScriptDefinition) {
        guard actionTask == nil, let run = scriptHooks?.manualRun else { return }
        actionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { actionTask = nil; updateButtonStates() }
            _ = await run(script, scriptFileContext)
            reloadChanges(preserveMessage: true)
        }
    }

    private enum NoStagedChoice { case stage, empty }

    private func validationContext(for message: String) -> (skipRegularExpression: Bool, regularExpressionText: String?) {
        switch activeSpecialKind {
        case .fixup, .squash:
            return (true, nil)
        case .amendAutosquash:
            let lines = message.components(separatedBy: .newlines)
            if lines.count > 2, lines[1].isEmpty {
                return (false, lines.dropFirst(2).joined(separator: "\n"))
            }
            return (false, nil)
        case nil:
            return (false, nil)
        }
    }

    private var currentCommitMode: RepositoryCommitMode {
        selectedCommitMode
    }

    private func confirmAmend(window: NSWindow) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Amend commit"
        alert.informativeText = "Amending rewrites the current commit. Do not amend a commit that has already been published."
        alert.addButton(withTitle: "Amend")
        alert.addButton(withTitle: "Cancel")
        return await begin(alert, window: window) == .alertFirstButtonReturn
    }

    private func noStagedChoice(window: NSWindow) async -> NoStagedChoice? {
        let alert = NSAlert()
        alert.messageText = "There are no staged changes"
        let filtered = !unstagedFilter.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        alert.informativeText = unstaged.isEmpty
            ? "Create an empty commit or cancel."
            : "Stage \(filtered ? "the filtered changes" : "all changes") and commit, create an empty commit, or cancel."
        alert.addButton(withTitle: unstaged.isEmpty ? "Commit Empty" : (filtered ? "Stage Filtered and Commit" : "Stage All and Commit"))
        if !unstaged.isEmpty { alert.addButton(withTitle: "Commit Empty") }
        alert.addButton(withTitle: "Cancel")
        let response = await begin(alert, window: window)
        if unstaged.isEmpty { return response == .alertFirstButtonReturn ? .empty : nil }
        if response == .alertFirstButtonReturn { return .stage }
        if response == .alertSecondButtonReturn { return .empty }
        return nil
    }

    private func confirmEmptyMerge(window: NSWindow) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Commit an empty merge?"
        alert.informativeText = "No files are staged. The merge itself can still be committed, but confirm that no files were accidentally left unstaged."
        alert.addButton(withTitle: "Commit Merge")
        alert.addButton(withTitle: "Cancel")
        return await begin(alert, window: window) == .alertFirstButtonReturn
    }

    private func confirmValidationIssue(_ issue: CommitMessageValidationIssue, window: NSWindow) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Commit message validation"
        alert.informativeText = issue.localizedDescription
        alert.addButton(withTitle: "Commit Anyway")
        alert.addButton(withTitle: "Edit Message")
        return await begin(alert, window: window) == .alertFirstButtonReturn
    }

    private func resolveDetachedHead(window: NSWindow) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "HEAD is detached"
        alert.informativeText = "The new commit will not belong to a branch unless you create or checkout one first."
        alert.addButton(withTitle: "Continue Detached")
        alert.addButton(withTitle: "Create Branch…")
        alert.addButton(withTitle: "Checkout Branch…")
        alert.addButton(withTitle: "Cancel")
        switch await begin(alert, window: window) {
        case .alertFirstButtonReturn:
            return true
        case .alertSecondButtonReturn:
            return await promptAndCreateBranch(window: window)
        case .alertThirdButtonReturn:
            return await promptAndCheckoutBranch(window: window)
        default:
            return false
        }
    }

    private func openPush(context: RepositoryNetworkContext?, forceWithLease: Bool) {
        guard let source = pushSource, let context else {
            status.stringValue = "Push is unavailable for this repository."
            return
        }
        if let pushWindowController {
            pushWindowController.window?.makeKeyAndOrderFront(nil)
            return
        }
        pushWindowController = PushDialog.present(
            source: source,
            context: context,
            initialBranch: context.branches.first(where: \.isCurrent)?.name,
            executeImmediately: true,
            initialForceWithLease: forceWithLease,
            onManageRemotes: onManageRemotes ?? { _, _ in },
            scriptHooks: scriptHooks,
            onRepositoryChanged: { [weak self] selected in
                self?.onRepositoryChanged(selected)
                self?.reloadChanges(preserveMessage: true)
            },
            onCompletion: { [weak self] completed in
                guard let self else { return }
                let target = pendingSuperprojectStage
                pendingSuperprojectStage = nil
                if CommitSuperprojectStaging.shouldStage(target: target, pushRequested: true, pushCompleted: completed), let target {
                    Task { @MainActor [weak self] in
                        await self?.stageSubmoduleInSuperproject(target)
                        guard let self else { return }
                        if closeWhenPushCompletes { closeAfterSuccessfulCommit() }
                    }
                    return
                }
                if completed, closeWhenPushCompletes {
                    closeAfterSuccessfulCommit()
                } else if !completed, closeWhenPushCompletes {
                    closeWhenPushCompletes = false
                    persistDraftOnClose = true
                    messageView.string = ""
                    amend.state = .off
                    selectedCommitMode = .normal
                    modeChanged()
                    reloadChanges()
                }
            },
            onClose: { [weak self] in
                guard let self else { return }
                pushWindowController = nil
            }
        )
    }

    @objc private func resetUnstagedChanges() { confirmReset(scope: .worktree) }
    @objc private func resetAllChanges() { confirmReset(scope: .all) }

    private func confirmReset(scope: RepositoryResetChangesScope) {
        guard let commitWindow else { return }
        actionTask?.cancel()
        actionTask = Task { @MainActor [weak self, weak commitWindow] in
            guard let self, let commitWindow else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = scope == .worktree ? "Reset unstaged changes" : "Reset all changes"
            alert.informativeText = scope == .worktree
                ? "Discard tracked working-tree changes? This cannot be undone."
                : "Reset the index and working tree to HEAD? This cannot be undone."
            alert.addButton(withTitle: "Reset")
            alert.addButton(withTitle: "Cancel")
            let clean = NSButton(checkboxWithTitle: "Delete new files and directories", target: nil, action: nil)
            clean.state = .off
            clean.isEnabled = commitState?.mutationState.hasUntrackedFiles == true
            alert.accessoryView = clean
            guard await begin(alert, window: commitWindow) == .alertFirstButtonReturn else { actionTask = nil; return }
            do {
                let result = try await source.resetChanges(RepositoryResetChangesRequest(scope: scope, deleteUntracked: clean.state == .on))
                onRepositoryChanged(result.selectedCommitID)
                reloadChanges(preserveMessage: true)
            } catch { await showOperationError(error, title: "Reset failed") }
            actionTask = nil
        }
    }

    @objc private func resetSoft() {
        guard let commitWindow else { return }
        actionTask?.cancel()
        actionTask = Task { @MainActor [weak self, weak commitWindow] in
            guard let self, let commitWindow else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Reset soft"
            alert.informativeText = "Move HEAD to its parent and leave the removed commit's changes staged?"
            alert.addButton(withTitle: "Reset Soft")
            alert.addButton(withTitle: "Cancel")
            guard await begin(alert, window: commitWindow) == .alertFirstButtonReturn else { actionTask = nil; return }
            do {
                let result = try await source.resetSoftToParent()
                onRepositoryChanged(result.selectedCommitID)
                historyWasSoftReset = true
                amend.state = .off; selectedCommitMode = .normal; modeChanged()
                reloadChanges(preserveMessage: true)
            } catch { await showOperationError(error, title: "Reset soft failed") }
            actionTask = nil
        }
    }

    @objc private func createBranch() {
        guard let commitWindow else { return }
        actionTask = Task { @MainActor [weak self, weak commitWindow] in
            guard let self, let commitWindow else { return }
            _ = await promptAndCreateBranch(window: commitWindow)
            actionTask = nil
        }
    }

    private func promptAndCreateBranch(window: NSWindow) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Create branch"
        alert.informativeText = "Create and checkout a local branch at HEAD."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: "")
        field.placeholderString = "Branch name"
        field.frame.size.width = 320
        alert.accessoryView = field
        guard await begin(alert, window: window) == .alertFirstButtonReturn else { return false }
        do {
            let result = try await source.createBranch(named: field.stringValue)
            onRepositoryChanged(result.selectedCommitID)
            reloadChanges(preserveMessage: true)
            return true
        } catch {
            await showOperationError(error, title: "Create branch failed")
            return false
        }
    }

    private func promptAndCheckoutBranch(window: NSWindow) async -> Bool {
        let branches = (repositoryContext?.branches ?? []).filter { !$0.isRemote }
        guard !branches.isEmpty else { return await promptAndCreateBranch(window: window) }
        let alert = NSAlert()
        alert.messageText = "Checkout branch"
        alert.addButton(withTitle: "Checkout")
        alert.addButton(withTitle: "Cancel")
        let popup = NSPopUpButton()
        popup.addItems(withTitles: branches.map(\.name))
        popup.frame.size.width = 320
        alert.accessoryView = popup
        guard await begin(alert, window: window) == .alertFirstButtonReturn,
              let name = popup.titleOfSelectedItem else { return false }
        scriptHooks?.begin()
        defer { scriptHooks?.end() }
        do {
            let hooks = scriptHooks
            let context = scriptFileContext
            let result = try await source.checkout(RepositoryCheckoutRequest(target: .localBranch(name), localChanges: .keep), beforeExecution: {
                guard await hooks?.runWithOptions(.beforeCheckout, options: context) != false else { throw CancellationError() }
            })
            onRepositoryChanged(result.selectedCommitID)
            _ = await hooks?.runWithOptions(.afterCheckout, options: context)
            reloadChanges(preserveMessage: true)
            return true
        } catch {
            await showOperationError(error, title: "Checkout failed")
            return false
        }
    }

    private func resolveConflicts() {
        guard let commitWindow else { return }
        actionTask = Task { @MainActor [weak self, weak commitWindow] in
            guard let self, let commitWindow else { return }
            if await WorkflowManagementDialogs.resolveConflicts(source: source, window: commitWindow, scriptHooks: scriptHooks) {
                onRepositoryChanged(nil)
            }
            actionTask = nil
            reloadChanges(preserveMessage: true)
        }
    }

    private func selectedPaths(in table: NSOutlineView) -> [String] {
        selectedFiles(in: table).map(\.path)
    }

    private func mutationPaths(for files: [ChangedFile]) -> [String] {
        var seen = Set<String>()
        return files.flatMap { [$0.oldPath, $0.path].compactMap { $0 } }
            .filter { seen.insert($0).inserted }
    }

    private func restoreSelection(path: String?, in table: NSOutlineView) {
        guard let path else { return }
        restoreSelection(paths: [path], in: table)
    }

    private func restoreSelection(paths: [String], in table: NSOutlineView) {
        let requested = Set(paths)
        guard !requested.isEmpty else { return }
        var rows = IndexSet()
        for row in 0..<table.numberOfRows {
            guard let file = (table.item(atRow: row) as? ChangedFileNode)?.file,
                  requested.contains(file.path) else { continue }
            rows.insert(row)
        }
        guard !rows.isEmpty else { return }
        table.selectRowIndexes(rows, byExtendingSelection: false)
        if let row = rows.first { table.scrollRowToVisible(row) }
    }

    private func updateButtonStates() {
        updateMessageWatermark()
        let busy = actionTask != nil || loadTask != nil
        unstagedEmptyLabel.isHidden = commitState == nil || !unstaged.isEmpty
        stagedEmptyLabel.isHidden = commitState == nil || !staged.isEmpty
        unstagedFilter.isHidden = !unstagedEmptyLabel.isHidden
        stagedFilter.isHidden = !stagedEmptyLabel.isHidden
        let conflicts = !(commitState?.mutationState.conflictedPaths.isEmpty ?? true)
        commitButton.title = "Commit"
        solveMergeConflictsButton.isHidden = !conflicts
        commitButton.isEnabled = !busy
        commitAndPushButton.title = currentCommitMode == .normal && staged.isEmpty && unstaged.isEmpty ? "Push" : "Commit & push"
        commitAndPushButton.isEnabled = !busy && pushSource != nil
        stageSelectedButton.isEnabled = !busy
        unstageSelectedButton.isEnabled = !busy
        stageAllFilesButton.isEnabled = !busy
        unstageAllFilesButton.isEnabled = !busy
        stashStagedButton.isEnabled = !busy
        resetUnstagedButton.isEnabled = !busy && !unstaged.isEmpty
        resetAllButton.isEnabled = !busy && (!unstaged.isEmpty || !staged.isEmpty)
        let currentHead = head
        resetSoftButton.isEnabled = !busy && currentHead?.parentIDs.isEmpty == false
    }

    private func perform(shortcut: CommitKeyboardShortcut) -> Bool {
        guard actionTask == nil else { return false }
        switch shortcut {
        case .unstaged:
            commitWindow?.makeFirstResponder(unstagedTable)
        case .diff:
            commitWindow?.makeFirstResponder(commitDiffView.focusView)
        case .staged:
            commitWindow?.makeFirstResponder(stagedTable)
        case .message:
            commitWindow?.makeFirstResponder(messageView)
        case .stageAll:
            stageEveryFile()
        case .filter:
            commitWindow?.makeFirstResponder(unstagedTable.selectedRow >= 0 ? unstagedFilter : stagedFilter)
        case .toggleSelectionFilter:
            toggleSelectionFilter()
        case .refresh:
            refreshChanges()
        case .createBranch:
            createBranch()
        case .openWithDifftool:
            let staged = commitDiffView.direction == .unstage
            guard let onDifftool, let context = repositoryContext,
                  let commit = RevisionCommitBuilder.artificialRevisions(headID: context.headID)
                    .first(where: { $0.kind == (staged ? .index : .workingDirectory) }) else { return false }
            selectedFiles(in: staged ? stagedTable : unstagedTable).forEach { onDifftool(commit, $0) }
        case .nextFile:
            moveFileSelection(backwards: false)
        case .previousFile:
            moveFileSelection(backwards: true)
        case .addSelectionToMessage:
            guard let responder = commitWindow?.firstResponder as? NSView,
                  responder === commitDiffView.focusView || responder.isDescendant(of: commitDiffView),
                  commitDiffView.addSelectionToMessage() else { return false }
        case .conventionalType:
            openConventionalCommitMenu(insertScope: false)
        case .conventionalScope:
            openConventionalCommitMenu(insertScope: true)
        }
        return true
    }

    private func moveFileSelection(backwards: Bool) {
        let responder = commitWindow?.firstResponder as? NSView
        let stagedHasFocus = responder.map { $0 === stagedTable || $0.isDescendant(of: stagedTable) } == true
        let messageHasFocus = responder.map { $0 === messageView || $0.isDescendant(of: messageView) } == true
        let table = stagedHasFocus || messageHasFocus || (unstagedTable.selectedRow < 0 && stagedTable.selectedRow >= 0)
            ? stagedTable
            : unstagedTable
        let rows = (0..<table.numberOfRows).filter {
            (table.item(atRow: $0) as? ChangedFileNode)?.file != nil
        }
        guard !rows.isEmpty else { return }
        let currentIndex = rows.firstIndex(of: table.selectedRow)
        let row: Int
        if let currentIndex {
            let next = backwards
                ? (currentIndex == 0 ? rows.count - 1 : currentIndex - 1)
                : (currentIndex + 1 == rows.count ? 0 : currentIndex + 1)
            row = rows[next]
        } else {
            row = backwards ? rows.last! : rows[0]
        }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        commitWindow?.makeFirstResponder(table)
    }

    private func updateStatus() {
        let branch = commitState?.mutationState.currentBranch ?? "detached HEAD"
        if let tracking = commitState?.branchTracking {
            branchNameLabel.stringValue = "\(branch) \u{2192}"
            remoteNameLink.statusText = CommitPushTarget.describe(tracking)
            remoteNameLink.isHidden = false
        } else {
            branchNameLabel.stringValue = branch
            remoteNameLink.statusText = ""
            remoteNameLink.isHidden = true
        }
        stagedCountValue.stringValue = "\(staged.count)/\(staged.count + unstaged.count)"
        authorStatus.statusText = CommitAuthorStatus.text(committer: commitState?.committer, author: author.stringValue)
        status.stringValue = ""
    }

    private func setInitialFocusIfNeeded() {
        guard !didInitialFocus, let commitWindow else { return }
        didInitialFocus = true
        if activeSpecialKind != nil {
            commitWindow.makeFirstResponder(messageView)
            return
        }
        if !unstaged.isEmpty {
            commitWindow.makeFirstResponder(unstagedTable)
            if let row = firstFileRow(in: unstagedTable) {
                unstagedTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        } else if !staged.isEmpty {
            commitWindow.makeFirstResponder(messageView)
            if let row = firstFileRow(in: stagedTable) {
                stagedTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        } else {
            commitWindow.makeFirstResponder(amend)
        }
    }

    private func updateMessageWatermark() {
        messageWatermark.isHidden = !messageView.string.isEmpty
    }

    func textDidChange(_ notification: Notification) {
        updateMessageWatermark()
        if !isFormattingMessage {
            let original = messageView.string
            let formatted = CommitMessageAutoFormatter.format(
                original,
                preferences: settings.commitPreferences.validation
            )
            if formatted != original {
                let oldSelection = messageView.selectedRange()
                let lengthDelta = (formatted as NSString).length - (original as NSString).length
                isFormattingMessage = true
                messageView.string = formatted
                messageView.setSelectedRange(NSRange(
                    location: min((formatted as NSString).length, max(0, oldSelection.location + lengthDelta)),
                    length: 0
                ))
                isFormattingMessage = false
            }
        }
        usingTemplate = usingTemplate && messageView.string == commitState?.loadedTemplate
        refreshMessageMarkup()
        updateLineAndColumn()
    }

    func textView(
        _ textView: NSTextView,
        completions words: [String],
        forPartialWordRange charRange: NSRange,
        indexOfSelectedItem index: UnsafeMutablePointer<Int>?
    ) -> [String] {
        guard settings.preferences.provideAutocompletion else { return [] }
        let typed = (textView.string as NSString).substring(with: charRange)
        return (autoCompleteWords + CommitAutoCompleteRegexes.metadataKeywords)
            .map(CommitAutoCompleteWord.init)
            .filter { $0.matches(typed) }
            .map(\.word)
    }

    func textViewDidChangeSelection(_ notification: Notification) { updateLineAndColumn() }

    func textDidBeginEditing(_ notification: Notification) {
        if settings.commitPreferences.selectStagedOnMessageFocus,
           stagedTable.selectedRow < 0,
           !staged.isEmpty,
           let row = firstFileRow(in: stagedTable) {
            stagedTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    private func firstFileRow(in table: NSOutlineView) -> Int? {
        (0..<table.numberOfRows).first {
            (table.item(atRow: $0) as? ChangedFileNode)?.file != nil
        }
    }

    private func updateLineAndColumn() {
        let location = min(messageView.selectedRange().location, (messageView.string as NSString).length)
        let prefix = (messageView.string as NSString).substring(to: location)
        let lines = prefix.components(separatedBy: "\n")
        cursorLineValue.stringValue = String(lines.count)
        cursorColumnValue.stringValue = String((lines.last.map { ($0 as NSString).length } ?? 0) + 1)
    }

    private func showOperationError(_ error: Error, title: String) async {
        status.stringValue = error.localizedDescription
        guard let commitWindow else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        _ = await begin(alert, window: commitWindow)
    }

    private func begin(_ alert: NSAlert, window: NSWindow) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    @objc private func cancel() {
        if let actionTask {
            status.stringValue = "Cancelling…"
            actionTask.cancel()
        } else {
            commitWindow?.performClose(nil)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let actionTask else { return true }
        status.stringValue = "Cancelling…"
        actionTask.cancel()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        commitDiffView.previewPresentation.cancel()
        saveGeometry()
        if persistDraftOnClose {
            let message = messageView.string
            let amendState = currentCommitMode != .normal
            let remember = settings.commitPreferences.rememberAmendState
            let encoding = commitState?.commitEncoding
            Task { try? await source.saveCommitDraft(message: message, amend: amendState, rememberAmend: remember, encoding: encoding) }
        }
        finishClose()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard didBecomeKeyOnce else { didBecomeKeyOnce = true; return }
        let pushTargetChanged = refreshPushTargetOnFocus
        refreshPushTargetOnFocus = false
        if settings.commitPreferences.refreshOnFocus || pushTargetChanged, actionTask == nil, !commitDiffView.isResetConfirmationOpen {
            reloadChanges(preserveMessage: true)
        }
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let visibleFrame = window.screen?.visibleFrame else { return }
        window.maxSize = visibleFrame.size
    }

    private func saveGeometry() {
        guard let commitWindow else { return }
        var preferences = settings.commitPreferences
        preferences.windowWidth = commitWindow.contentLayoutRect.width
        preferences.windowHeight = commitWindow.contentLayoutRect.height
        settings.saveCommitPreferences(preferences)
        splitterManager.saveSplitters()
    }

    private func closeAfterSuccessfulCommit() {
        persistDraftOnClose = false
        actionTask = nil
        commitWindow?.performClose(nil)
    }

    private func finishClose() {
        guard !didComplete else { return }
        didComplete = true
        onClose?()
    }
}

@MainActor
final class CommitDiffView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation, NSMenuDelegate {
    private(set) var isResetConfirmationOpen = false
    var scriptLineNumber: Int {
        let row = tableView.selectedRow >= 0 ? tableView.selectedRow : caretRow
        guard presentations.indices.contains(row) else { return 1 }
        let line = presentations[row].line
        return line.newLineNumber ?? line.oldLineNumber ?? 1
    }
    private let tableView = FileViewerTableView()
    private let trackingView = DiffTrackingView()
    private let hoverToolbar = DiffViewerToolbar(preferences: AppSettingsStore.shared.preferencesForNewFileViewer())
    private var presentations: [DiffLinePresentation] = []
    private var syntaxStates: [Int?] = []
    private var gutterMetrics = DiffGutterMetrics.empty
    private var caretRow = -1
    let searchState = FileViewerSearchState()
    private var searchOffsets: [Int] = []
    let previewPresentation = FilePreviewPresentation<FileDiff?>()
    private lazy var findPanel = FileViewerFindPanel(state: searchState, caret: { [weak self] in
        guard let self else { return 0 }
        return searchState.currentMatch.map(NSMaxRange) ?? (searchOffsets.indices.contains(caretRow) ? searchOffsets[caretRow] : 0)
    }, changed: { [weak self] in self?.applySearch() })
    private var occurrences = FileViewerOccurrences()
    private var difftasticEnabled: Bool?
    var difftasticAvailability: (() async -> Bool)?
    private var preferences = AppSettingsStore.shared.preferencesForNewFileViewer()
    private var file: ChangedFile?
    private var diff: FileDiff?
    private(set) var direction: RepositoryHunkDirection = .stage
    private var patchingAllowed = true
    var onApplyHunk: ((String, RepositoryHunkDirection) -> Void)?
    var onApplyLines: ((Set<String>, RepositoryHunkDirection) -> Void)?
    var onResetLines: ((Set<String>, RepositoryHunkDirection) -> Void)?
    var onAddSelectedText: ((String) -> Void)?
    var onOptionsChanged: (() -> Void)?
    var onDifftool: ((ChangedFile, RepositoryHunkDirection) -> Void)?
    var onBlame: ((ChangedFile) -> Void)?
    var onFileHistory: ((ChangedFile) -> Void)?
    var historyAllowed: () -> Bool = { false }
    var blameAllowed: () -> Bool = { false }
    var focusView: NSView { tableView }
    var diffOptions: FileDiffOptions {
        var options = preferences.diffOptions
        options.difftasticWidth = GitDiffAppearance.difftasticWidth(viewerWidth: tableView.enclosingScrollView?.contentSize.width ?? 600)
        return options
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        trackingView.onPointerPresenceChanged = { [weak self] isPresent in
            self?.hoverToolbar.isHidden = !isPresent
        }
        hoverToolbar.onAction = { [weak self] action, state in
            self?.performToolbarAction(action, state: state)
        }

        NotificationCenter.default.addObserver(self, selector: #selector(viewerPreferencesChanged), name: .fileViewerSettingsApplied, object: AppSettingsStore.shared)
        tableView.onShortcut = { [weak self] shortcut in
            guard let self, !presentations.isEmpty else { return false }
            switch shortcut {
            case .replace: return false
            case .wordDiff: setAppearance(.gitWordDiff)
            case .difftastic:
                Task { @MainActor in
                    guard await self.difftasticAvailability?() == true else { return }
                    self.setAppearance(.difftastic)
                }
            case .nextOccurrence, .previousOccurrence:
                if occurrences.next(in: presentations.map(\.line.text), forward: shortcut == .nextOccurrence) {
                    caretRow = occurrences.row
                    tableView.selectRowIndexes(IndexSet(integer: caretRow), byExtendingSelection: false)
                    tableView.scrollRowToVisible(caretRow)
                }
            case .resetLines: resetLines()
            case .stageLines:
                guard patchingAllowed, direction == .stage else { return false }
                applyLines()
            case .unstageLines:
                guard patchingAllowed, direction == .unstage else { return false }
                applyLines()
            case .find:
                findText()
            case .findNext, .findPrevious:
                if shortcut == .findNext, searchState.query.isEmpty, let file, let onDifftool { onDifftool(file, direction) }
                else { findPanel.perform(shortcut == .findNext ? .next : .previous, viaKeyboard: true) }
            case .goToLine:
                if let row = FileViewerNavigationDialogs.goToLine(lines: presentations.map(\.line)) {
                    caretRow = row
                    tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    tableView.scrollRowToVisible(row)
                }
            default: performToolbarAction(shortcut.title, state: preferences.showsSyntaxHighlighting ? .off : .on)
            }
            return true
        }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("CommitDiff"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = AppSettingsStore.shared.diffLineHeight
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = ApplicationColors.color("EditorBackground", fallback: .textBackgroundColor)
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.onCopy = { [weak self] in self?.copyViewer(.selection) }
        tableView.target = self; tableView.doubleAction = #selector(selectDiffWord)
        let menu = NSMenu(title: "Diff actions")
        menu.delegate = self
        let lines = NSMenuItem(title: "Stage selected line(s)", action: #selector(applyLines), keyEquivalent: "")
        lines.target = self
        let hunk = NSMenuItem(title: "Stage selected hunk", action: #selector(applyHunk), keyEquivalent: "")
        hunk.target = self
        menu.addItem(lines)
        menu.addItem(hunk)
        menu.addItem(.separator())
        let addToMessage = NSMenuItem(title: "Add selection to commit message", action: #selector(addSelectedText), keyEquivalent: "")
        addToMessage.target = self
        menu.addItem(addToMessage)
        menu.addItem(.separator())
        let blame = NSMenuItem(title: "Show blame", action: #selector(showBlame), keyEquivalent: "")
        blame.target = self
        menu.addItem(blame)
        let history = NSMenuItem(title: "Show file history", action: #selector(showFileHistory), keyEquivalent: "")
        history.target = self; menu.addItem(history)
        tableView.menu = menu

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        trackingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(trackingView)
        trackingView.addSubview(scrollView)
        hoverToolbar.install(in: trackingView)
        previewPresentation.install(in: trackingView)
        NSLayoutConstraint.activate([
            trackingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            trackingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            trackingView.topAnchor.constraint(equalTo: topAnchor),
            trackingView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: trackingView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trackingView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: trackingView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: trackingView.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func apply(file: ChangedFile, preview: FilePreview<FileDiff?>, direction: RepositoryHunkDirection) {
        apply(file: file, diff: nil, direction: direction)
        previewPresentation.present(preview, display: { [weak self] in self?.apply(file: file, diff: $0, direction: direction) }, failure: { [weak self] in self?.toolTip = $0.localizedDescription })
    }

    @objc private func findText() { if !presentations.isEmpty { findPanel.present(owner: window) } }
    @objc private func findNext() { findPanel.perform(.next, viaKeyboard: true) }
    @objc private func findPrevious() { findPanel.perform(.previous, viaKeyboard: true) }
    private func applySearch() {
        if let match = searchState.currentMatch, let row = searchOffsets.lastIndex(where: { $0 <= match.location }) {
            caretRow = row
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        }
        reloadRenderedLines()
    }
    private func searchRanges(row: Int, active: Bool) -> [NSRange] {
        let lineRange = NSRange(location: searchOffsets[row], length: presentations[row].line.text.utf16.count)
        let matches = active ? searchState.currentMatch.map { [$0] } ?? [] : searchState.highlightedRanges
        return matches.compactMap {
            let range = NSIntersectionRange($0, lineRange)
            return range.length > 0 ? NSRange(location: range.location - lineRange.location, length: range.length) : nil
        }
    }

    func apply(file: ChangedFile, diff: FileDiff?, direction: RepositoryHunkDirection) {
        previewPresentation.cancel()
        self.file = file
        self.diff = diff
        self.direction = direction
        patchingAllowed = (diff?.appearance ?? .patch) == .patch && diff?.submoduleSummary == nil && diff?.isTextOnly != true
        presentations = DiffLinePresentation.build(from: diff?.lines ?? [], appearance: diff?.appearance ?? .patch)
        syntaxStates = DiffSyntaxHighlighter.lineStates(diff?.lines ?? [], filePath: file.path)
        var offset = 0
        searchOffsets = (diff?.lines ?? []).map { line in defer { offset += line.text.utf16.count + 1 }; return offset }
        searchState.setText((diff?.lines ?? []).map(\.text).joined(separator: "\n"))
        occurrences.row = -1; occurrences.column = -1
        gutterMetrics = DiffGutterMetrics(lines: diff?.lines ?? [], font: AppSettingsStore.shared.diffGutterFont)
        caretRow = -1
        hoverToolbar.toolTip = "\(file.path) — \(file.changeType.description), +\(file.additions) −\(file.deletions)"
        tableView.reloadData()
        if !presentations.isEmpty {
            tableView.scrollRowToVisible(0)
        }
        toolTip = diff == nil ? "No diff is available for \(file.path)." : file.path
        tableView.menu?.items.first?.title = direction == .stage ? "Stage selected line(s)" : "Unstage selected line(s)"
        tableView.menu?.items[1].title = direction == .stage ? "Stage selected hunk" : "Unstage selected hunk"
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if [#selector(applyLines), #selector(applyHunk), #selector(resetLines)].contains(menuItem.action) { return patchingAllowed && !tableView.selectedRowIndexes.isEmpty }
        if menuItem.action == #selector(showFileHistory) { return historyAllowed() && file?.isTracked == true }
        if menuItem.action == #selector(showBlame) {
            return onBlame != nil && blameAllowed() && file?.isTracked == true && file?.isSubmodule != true
        }
        if [#selector(findText), #selector(findNext), #selector(findPrevious)].contains(menuItem.action) { return !presentations.isEmpty }
        return true
    }

    @objc private func showBlame() { if let file { onBlame?(file) } }
    @objc private func showFileHistory() { if let file { onFileHistory?(file) } }

    func currentSelection(lineID: String, direction: RepositoryHunkDirection) -> RepositoryHunkSelection? {
        guard patchingAllowed, self.direction == direction, let file, let diff else { return nil }
        patchingAllowed = false
        return RepositoryHunkSelection(file: file, diff: diff, lineID: lineID, direction: direction)
    }

    func currentLineSelection(lineIDs: Set<String>, direction: RepositoryHunkDirection) -> RepositoryLineSelection? {
        guard patchingAllowed, self.direction == direction, let file, let diff, !lineIDs.isEmpty else { return nil }
        patchingAllowed = false
        return RepositoryLineSelection(file: file, diff: diff, lineIDs: lineIDs, direction: direction)
    }

    func allowPatching() { patchingAllowed = (diff?.appearance ?? .patch) == .patch && diff?.submoduleSummary == nil && diff?.isTextOnly != true }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where ["viewer.appearance", "viewer.copy", "viewer.find"].contains(item.identifier?.rawValue ?? "") || item.action == #selector(resetLines) { menu.removeItem(item) }
        for (title, action) in [("Find…", #selector(findText)), ("Find next", #selector(findNext)), ("Find previous", #selector(findPrevious))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.identifier = .init("viewer.find"); item.target = self; menu.addItem(item)
        }
        let commands: [(String, Selector)] = [("Copy", #selector(copySelection)), ("Copy patch", #selector(copyPatch)),
                                             ("Copy old version", #selector(copyOldVersion)), ("Copy new version", #selector(copyNewVersion))]
        for (title, action) in commands where title == "Copy" || (diff?.appearance == .patch && diff?.isTextOnly != true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.identifier = .init("viewer.copy"); item.target = self; menu.addItem(item)
        }
        let reset = NSMenuItem(title: "Reset selected line(s)", action: #selector(resetLines), keyEquivalent: "")
        reset.target = self; menu.insertItem(reset, at: min(2, menu.items.count))
        let root = NSMenuItem(title: "Diff appearance", action: nil, keyEquivalent: "")
        root.identifier = .init("viewer.appearance")
        let submenu = NSMenu(); submenu.autoenablesItems = false
        for (title, appearance) in [("Patch", DiffDisplayAppearance.patch), ("Git word diff", .gitWordDiff), ("Difftastic", .difftastic)] {
            let item = NSMenuItem(title: title, action: #selector(appearanceSelected(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = appearance.rawValue
            item.state = preferences.diffAppearance == appearance ? .on : .off
            item.isEnabled = appearance != .difftastic || difftasticEnabled == true
            if appearance == .difftastic, difftasticEnabled == nil {
                Task { @MainActor [weak self, weak item] in
                    let enabled = await self?.difftasticAvailability?() ?? false
                    self?.difftasticEnabled = enabled; item?.isEnabled = enabled
                }
            }
            submenu.addItem(item)
        }
        root.submenu = submenu; menu.addItem(root)
    }

    @objc private func appearanceSelected(_ item: NSMenuItem) {
        guard let appearance = (item.representedObject as? String).flatMap(DiffDisplayAppearance.init(rawValue:)) else { return }
        setAppearance(appearance)
    }

    @objc private func copySelection() { copyViewer(.selection) }
    @objc private func copyPatch() { copyViewer(.patch) }
    @objc private func copyOldVersion() { copyViewer(.oldVersion) }
    @objc private func copyNewVersion() { copyViewer(.newVersion) }
    private func copyViewer(_ command: FileViewerCopy.Command) {
        let lines = presentations.map(\.line)
        let patch = diff?.appearance == .patch && diff?.isTextOnly != true
        let text = lines.map { patch ? $0.patchText : $0.text }.joined(separator: "\n")
        let ranges = FileViewerCopy.selectedRanges(lines: lines, rows: tableView.selectedRowIndexes, patch: patch)
        let selections: [NSRange?] = ranges.isEmpty ? [nil] : ranges.map(Optional.some)
        let payloads = selections.compactMap {
            FileViewerCopy.payload(command, text: text, selection: $0, isDiff: diff?.isTextOnly != true && diff?.appearance != .difftastic,
                                   normalizeLineEndings: diff?.normalizesCopyLineEndings ?? false)
        }
        guard !payloads.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(payloads.joined(), forType: .string)
    }

    private func setAppearance(_ appearance: DiffDisplayAppearance) {
        preferences.diffAppearance = appearance == .patch || preferences.diffAppearance == appearance ? .patch : appearance
        persistPreferences(reloadDiff: true)
    }

    @objc private func selectDiffWord() {
        let row = tableView.clickedRow
        guard presentations.indices.contains(row), let event = NSApp.currentEvent,
              let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? DiffLineCellView else { return }
        let column = cell.characterIndex(at: cell.convert(event.locationInWindow, from: nil))
        guard let word = FileViewerOccurrences.word(in: presentations[row].line.text, at: column) else { return }
        occurrences.term = word; occurrences.row = row; occurrences.column = column; caretRow = row
        reloadRenderedLines()
    }

    @objc private func resetLines() {
        guard patchingAllowed, let window else { return }
        let ids = Set(tableView.selectedRowIndexes.compactMap { row -> String? in
            guard presentations.indices.contains(row), [.addition, .deletion].contains(presentations[row].line.kind) else { return nil }
            return presentations[row].line.id
        })
        guard !ids.isEmpty else { return }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "Reset changes"; alert.informativeText = "Are you sure you want to reset the changes to the selected lines?"
        alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No")
        let direction = direction
        let file = file, diff = diff
        isResetConfirmationOpen = true
        alert.beginSheetModal(for: window) { [weak self] response in
            defer { self?.isResetConfirmationOpen = false }
            guard let self, response == .alertFirstButtonReturn, patchingAllowed, self.file == file, self.diff == diff, self.direction == direction else { return }
            onResetLines?(ids, direction)
        }
    }

    @objc private func applyLines() {
        guard patchingAllowed else { return }
        let ids = Set(tableView.selectedRowIndexes.compactMap { row -> String? in
            guard presentations.indices.contains(row) else { return nil }
            let line = presentations[row].line
            return line.kind == .addition || line.kind == .deletion ? line.id : nil
        })
        guard !ids.isEmpty else { return }
        onApplyLines?(ids, direction)
    }

    @objc private func applyHunk() {
        guard patchingAllowed,
              let row = tableView.selectedRowIndexes.first,
              presentations.indices.contains(row) else { return }
        onApplyHunk?(presentations[row].line.id, direction)
    }

    @objc private func addSelectedText() {
        _ = addSelectionToMessage()
    }

    @discardableResult
    func addSelectionToMessage() -> Bool {
        let text = tableView.selectedRowIndexes.compactMap { row -> String? in
            guard presentations.indices.contains(row) else { return nil }
            let line = presentations[row].line
            guard line.kind != .header, line.kind != .hunk else { return nil }
            return line.text
        }.joined(separator: "\n")
        guard !text.isEmpty else { return false }
        onAddSelectedText?(text)
        return true
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        presentations.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard presentations.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("CommitDiffLine")
        let cell: DiffLineCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? DiffLineCellView {
            cell = reused
        } else {
            cell = DiffLineCellView()
            cell.identifier = identifier
        }
        cell.apply(
            presentation: presentations[row],
            gutterMetrics: gutterMetrics,
            showsNonPrintingCharacters: preferences.showsNonPrintingCharacters,
            showsSyntaxHighlighting: preferences.showsSyntaxHighlighting,
            filePath: file?.path,
            appearance: diff?.appearance ?? .patch,
            highlightTerm: occurrences.term,
            openSpan: syntaxStates.indices.contains(row) ? syntaxStates[row] : nil,
            searchRanges: searchRanges(row: row, active: false),
            activeSearchRanges: searchRanges(row: row, active: true)
        )
        return cell
    }

    private func performToolbarAction(_ action: String, state: NSControl.StateValue) {
        switch action {
        case "Next change": navigateToChange(forward: true)
        case "Previous change": navigateToChange(forward: false)
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
            preferences.textEncoding = RepositoryTextEncoding(rawValue: String(value.dropFirst("Encoding:".count))) ?? .automatic
            persistPreferences(reloadDiff: true)
        default:
            break
        }
    }

    private func persistPreferences(reloadDiff: Bool) {
        AppSettingsStore.shared.updateFileViewerPreferences(preferences)
        hoverToolbar.apply(preferences: preferences)
        if reloadDiff { onOptionsChanged?() }
    }

    @objc private func viewerPreferencesChanged() {
        let updated = AppSettingsStore.shared.fileViewerPreferences
        let reload = updated.diffOptions != preferences.diffOptions
        preferences = updated
        hoverToolbar.apply(preferences: preferences)
        reloadRenderedLines()
        if reload { onOptionsChanged?() }
    }

    private func navigateToChange(forward: Bool) {
        let starts = presentations.indices.filter { index in
            let kind = presentations[index].line.kind
            guard kind == .addition || kind == .deletion else { return false }
            guard index > 0 else { return true }
            let previous = presentations[index - 1].line.kind
            return previous != .addition && previous != .deletion
        }
        let destination = forward
            ? starts.first(where: { $0 > caretRow })
            : starts.last(where: { $0 < (caretRow < 0 ? presentations.count : caretRow) })
        guard let destination else { NSSound.beep(); return }
        caretRow = destination
        tableView.selectRowIndexes(IndexSet(integer: destination), byExtendingSelection: false)
        tableView.scrollRowToVisible(destination)
    }

    private func reloadRenderedLines() {
        tableView.backgroundColor = ApplicationColors.color("EditorBackground", fallback: .textBackgroundColor)
        gutterMetrics = DiffGutterMetrics(lines: diff?.lines ?? [], font: AppSettingsStore.shared.diffGutterFont)
        let selection = tableView.selectedRowIndexes
        tableView.reloadData()
        tableView.selectRowIndexes(selection, byExtendingSelection: false)
    }

}

@MainActor
private enum CommitTemplateSettingsDialog {
    static func present(parent: NSWindow, onClose: @escaping () -> Void) {
        let controller = CommitTemplateSettingsViewController()
        let panel = NSPanel(contentViewController: controller)
        panel.title = "Commit message settings"
        panel.styleMask = [.titled, .closable, .resizable]
        panel.setContentSize(NSSize(width: 698, height: 361))
        panel.minSize = NSSize(width: 550, height: 310)
        controller.panel = panel
        controller.onFinish = { saved in
            parent.endSheet(panel)
            if saved { onClose() }
        }
        parent.beginSheet(panel)
    }
}

@MainActor
enum CommitTemplateSlotTitle {
    static func title(index: Int, name: String) -> String {
        let caption: String
        if name.isEmpty {
            caption = "<empty>"
        } else if name.count <= 50 {
            caption = name
        } else {
            caption = String(name.prefix(47)) + "..."
        }
        return "\(index + 1) : \(caption)"
    }
}

enum CommitTemplateSettingsPresentation {
    static let regexHelp = #"""
    Use {{regex}}[regex group number] to extract branch name part
    Group number is optional, default is 1

    Examples on branch name: "feature/ABC-4587-commitMessageRegex"
    "Commit from: {{^feature/(.*)$}} branch" -> "Commit from: ABC-4587-commitMessageRegex branch"
    "{{([A-Z]+-\d+)}}: My message is" -> "ABC-4587: My message is "
    "Name: {{([A-Z]+-\d+)-(.*)}}[2], issue: {{([A-Z]+-\d+)-(.*)}}[1]" -> "Name: commitMessageRegex, issue: ABC-4587"
    """#

    static func validatedLength(_ text: String) -> Int? {
        guard let value = Int(text), (0...100).contains(value) else { return nil }
        return value
    }
}

final class CommitTemplateSettingsViewController: NSViewController, NSWindowDelegate, NSTextFieldDelegate {
    weak var panel: NSPanel?
    var onFinish: ((Bool) -> Void)?
    private var preferences = AppSettingsStore.shared.commitPreferences
    private var templates: [CommitMessageTemplate] = []
    private var selectedSlot = 0
    private var didFinish = false
    private let slots = NSPopUpButton()
    private let nameField = NSTextField(string: "")
    private let regexCheck = NSButton(checkboxWithTitle: "Enable regex", target: nil, action: nil)
    private let textView = NSTextView()
    private let subjectLength = NSTextField(string: "0")
    private let lineLength = NSTextField(string: "0")
    private let secondLine = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let autoWrap = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let indent = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let subjectStepper = NSStepper()
    private let lineStepper = NSStepper()
    private let validationRegex = NSTextField(string: "")

    override func loadView() {
        templates = Array(preferences.templates.prefix(10))
        while templates.count < 10 { templates.append(CommitMessageTemplate()) }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 698, height: 361))
        slots.addItems(withTitles: (0..<10).map { CommitTemplateSlotTitle.title(index: $0, name: "") })
        slots.target = self; slots.action = #selector(slotChanged)
        slots.setAccessibilityIdentifier("CommitTemplate.Slot")
        nameField.maximumNumberOfLines = 1
        nameField.delegate = self
        nameField.setAccessibilityIdentifier("CommitTemplate.Name")
        regexCheck.toolTip = CommitTemplateSettingsPresentation.regexHelp
        regexCheck.setAccessibilityIdentifier("CommitTemplate.Regex")
        textView.isRichText = false
        textView.font = AppSettingsStore.shared.fontPreferences.font(.monospace, fallback: .monospacedSystemFont(ofSize: 12, weight: .regular))
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityIdentifier("CommitTemplate.Body")
        let textScroll = NSScrollView()
        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.borderType = .bezelBorder
        let bodyLabel = label("Commit template:")
        let nameLabel = label("Name:")
        let templatePage = NSView()
        for control in [slots, nameLabel, nameField, bodyLabel, textScroll, regexCheck] {
            control.translatesAutoresizingMaskIntoConstraints = false
            templatePage.addSubview(control)
        }
        NSLayoutConstraint.activate([
            slots.leadingAnchor.constraint(equalTo: templatePage.leadingAnchor, constant: 8),
            slots.trailingAnchor.constraint(equalTo: templatePage.trailingAnchor, constant: -8),
            slots.topAnchor.constraint(equalTo: templatePage.topAnchor, constant: 8),
            nameLabel.leadingAnchor.constraint(equalTo: slots.leadingAnchor),
            nameLabel.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            nameField.leadingAnchor.constraint(equalTo: templatePage.leadingAnchor, constant: 120),
            nameField.trailingAnchor.constraint(equalTo: slots.trailingAnchor),
            nameField.topAnchor.constraint(equalTo: slots.bottomAnchor, constant: 6),
            bodyLabel.leadingAnchor.constraint(equalTo: slots.leadingAnchor),
            bodyLabel.topAnchor.constraint(equalTo: textScroll.topAnchor),
            textScroll.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            textScroll.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            textScroll.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 6),
            textScroll.bottomAnchor.constraint(equalTo: regexCheck.topAnchor, constant: -6),
            textScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            regexCheck.leadingAnchor.constraint(equalTo: slots.leadingAnchor),
            regexCheck.bottomAnchor.constraint(equalTo: templatePage.bottomAnchor, constant: -8)
        ])
        let subject = numericControl(subjectLength, stepper: subjectStepper, value: preferences.validation.maximumSubjectLength, id: "CommitValidation.SubjectLength", tag: 0)
        let line = numericControl(lineLength, stepper: lineStepper, value: preferences.validation.maximumLineLength, id: "CommitValidation.LineLength", tag: 1)
        secondLine.state = preferences.validation.requireEmptySecondLine ? .on : .off
        autoWrap.state = preferences.validation.autoWrap ? .on : .off
        indent.state = preferences.validation.indentAfterFirstLine ? .on : .off
        validationRegex.stringValue = preferences.validation.regularExpression
        validationRegex.setAccessibilityIdentifier("CommitValidation.Regex")
        let validation = NSGridView(views: [
            [label("Maximum number of characters in the first line (0 = check disabled):"), subject],
            [label("Maximum number of characters per line (0 = check disabled):"), line],
            [label("Auto-wrap commit message (except subject line)"), autoWrap],
            [label("Commit must match following RegEx (Empty = check disabled):"), validationRegex],
            [label("Indent lines after the first line:"), indent],
            [label("Second line must be empty:"), secondLine]
        ])
        validation.rowSpacing = 8
        validation.columnSpacing = 8
        validation.column(at: 1).xPlacement = .leading
        for index in 0..<validation.numberOfRows { validation.row(at: index).yPlacement = .center }
        validationRegex.widthAnchor.constraint(greaterThanOrEqualToConstant: 230).isActive = true
        let validationPage = NSView()
        validation.translatesAutoresizingMaskIntoConstraints = false
        validationPage.addSubview(validation)
        NSLayoutConstraint.activate([
            validation.leadingAnchor.constraint(equalTo: validationPage.leadingAnchor, constant: 8),
            validation.topAnchor.constraint(equalTo: validationPage.topAnchor, constant: 8),
            validation.trailingAnchor.constraint(lessThanOrEqualTo: validationPage.trailingAnchor, constant: -8),
            validation.bottomAnchor.constraint(lessThanOrEqualTo: validationPage.bottomAnchor, constant: -8)
        ])
        let tabs = NSTabView()
        tabs.setAccessibilityIdentifier("CommitTemplate.Tabs")
        for (title, page) in [("Commit templates", templatePage), ("Commit validation", validationPage)] {
            let item = NSTabViewItem(identifier: title)
            item.label = title; item.view = page
            tabs.addTabViewItem(item)
        }
        let ok = NSButton(title: "OK", target: self, action: #selector(save))
        ok.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, ok]); buttons.spacing = 8
        for control in [tabs, buttons] { control.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(control) }
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 9),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -9),
            tabs.topAnchor.constraint(equalTo: root.topAnchor, constant: 9),
            tabs.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -9),
            buttons.leadingAnchor.constraint(equalTo: tabs.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: tabs.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -9)
        ])
        view = root
        refreshSlotTitles()
        loadSlot(0)
    }

    private func label(_ title: String) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.font = AppSettingsStore.shared.applicationFont(size: 11)
        return field
    }

    private func numericControl(_ field: NSTextField, stepper: NSStepper, value: Int, id: String, tag: Int) -> NSView {
        let formatter = NumberFormatter()
        formatter.allowsFloats = false; formatter.minimum = 0; formatter.maximum = 100
        field.formatter = formatter; field.alignment = .right; field.delegate = self
        field.integerValue = value
        field.setAccessibilityIdentifier(id)
        field.widthAnchor.constraint(equalToConstant: 60).isActive = true
        stepper.minValue = 0; stepper.maxValue = 100; stepper.increment = 1; stepper.valueWraps = false
        stepper.integerValue = value; stepper.tag = tag
        stepper.target = self; stepper.action = #selector(stepLength(_:))
        stepper.setAccessibilityIdentifier(id + ".Stepper")
        let controls = NSStackView(views: [field, stepper]); controls.spacing = 2
        return controls
    }

    @objc private func stepLength(_ sender: NSStepper) {
        let field = sender.tag == 0 ? subjectLength : lineLength
        field.integerValue = sender.integerValue
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field === subjectLength || field === lineLength,
              let value = CommitTemplateSettingsPresentation.validatedLength(field.stringValue) else { return }
        (field === subjectLength ? subjectStepper : lineStepper).integerValue = value
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === subjectLength || control === lineLength,
              commandSelector == #selector(NSResponder.moveUp(_:)) || commandSelector == #selector(NSResponder.moveDown(_:)),
              let value = CommitTemplateSettingsPresentation.validatedLength(textView.string) else { return false }
        let step = control === subjectLength ? subjectStepper : lineStepper
        step.integerValue = min(100, max(0, value + (commandSelector == #selector(NSResponder.moveUp(_:)) ? 1 : -1)))
        stepLength(step)
        textView.string = String(step.integerValue)
        textView.selectAll(nil)
        return true
    }

    @objc private func slotChanged() {
        captureSlot(selectedSlot)
        selectedSlot = max(0, slots.indexOfSelectedItem)
        loadSlot(selectedSlot)
    }

    private func captureSlot(_ index: Int) {
        guard templates.indices.contains(index) else { return }
        templates[index].name = String(nameField.stringValue.prefix(80))
        templates[index].text = textView.string
        templates[index].expandsBranchRegularExpressions = regexCheck.state == .on
        refreshSlotTitles()
    }

    private func loadSlot(_ index: Int) {
        guard templates.indices.contains(index) else { return }
        nameField.stringValue = templates[index].name
        textView.string = templates[index].text
        regexCheck.state = templates[index].expandsBranchRegularExpressions ? .on : .off
    }

    private func refreshSlotTitles() {
        for index in templates.indices {
            slots.item(at: index)?.title = CommitTemplateSlotTitle.title(index: index, name: templates[index].name)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSTextField === nameField, templates.indices.contains(selectedSlot) else { return }
        templates[selectedSlot].name = String(nameField.stringValue.prefix(80))
        slots.item(at: selectedSlot)?.title = CommitTemplateSlotTitle.title(index: selectedSlot, name: templates[selectedSlot].name)
    }

    @objc private func save() {
        guard panel?.makeFirstResponder(nil) != false,
              let subject = CommitTemplateSettingsPresentation.validatedLength(subjectLength.stringValue),
              let line = CommitTemplateSettingsPresentation.validatedLength(lineLength.stringValue) else { NSSound.beep(); return }
        captureSlot(selectedSlot)
        preferences.templates = templates
        preferences.validation.maximumSubjectLength = subject
        preferences.validation.maximumLineLength = line
        preferences.validation.requireEmptySecondLine = secondLine.state == .on
        preferences.validation.autoWrap = autoWrap.state == .on
        preferences.validation.indentAfterFirstLine = indent.state == .on
        preferences.validation.regularExpression = validationRegex.stringValue
        AppSettingsStore.shared.saveCommitPreferences(preferences)
        finish(true)
    }

    @objc private func cancel() { finish(false) }
    func windowWillClose(_ notification: Notification) { finish(false) }
    private func finish(_ saved: Bool) {
        guard !didFinish else { return }
        didFinish = true
        onFinish?(saved)
    }
}

final class CommitToolbarOverflow: NSObject, NSStackViewDelegate, NSMenuDelegate {
    let button = NSPopUpButton(frame: .zero, pullsDown: true)
    private weak var stack: NSStackView?
    private var overflowing: [NSView] = []
    private var detached: Set<ObjectIdentifier> = []
    var isAvailable: (NSView) -> Bool = { _ in true }

    override init() {
        super.init()
        button.bezelStyle = .recessed
        button.isBordered = false
        button.addItem(withTitle: "»")
        button.menu?.delegate = self
        button.toolTip = "More"
        button.setAccessibilityLabel("More")
        button.setAccessibilityIdentifier("CommitToolbarOverflow")
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.isHidden = true
    }

    func attach(to stack: NSStackView, overflowing views: [NSView]) {
        self.stack = stack
        overflowing = views
        stack.delegate = self
        stack.detachesHiddenViews = true
        stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        for (index, view) in views.enumerated() {
            stack.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: Float(100 + index * 100)), for: view)
        }
    }

    var overflowTitles: [String] {
        overflowItems().map(\.title)
    }

    func stackView(_ stackView: NSStackView, willDetach views: [NSView]) {
        views.forEach { detached.insert(ObjectIdentifier($0)) }
        DispatchQueue.main.async { [weak self] in self?.updateButton() }
    }

    func stackView(_ stackView: NSStackView, didReattach views: [NSView]) {
        views.forEach { detached.remove(ObjectIdentifier($0)) }
        views.filter { !isAvailable($0) }.forEach { $0.isHidden = true }
        DispatchQueue.main.async { [weak self] in self?.updateButton() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let title = menu.items.first?.copy() as? NSMenuItem ?? NSMenuItem(title: "»", action: nil, keyEquivalent: "")
        menu.removeAllItems()
        menu.addItem(title)
        overflowItems().forEach(menu.addItem)
    }

    func updateButton() {
        button.isHidden = overflowItems().isEmpty
    }

    private func overflowItems() -> [NSMenuItem] {
        let order = stack?.arrangedSubviews ?? []
        return order.filter { view in
            overflowing.contains { $0 === view } && detached.contains(ObjectIdentifier(view)) && isAvailable(view)
        }.compactMap { view -> NSMenuItem? in
            if let popUp = view as? NSPopUpButton {
                let item = NSMenuItem(title: popUp.itemTitle(at: 0), action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: item.title)
                popUp.itemArray.dropFirst().forEach { submenu.addItem($0.copy() as! NSMenuItem) }
                item.submenu = submenu
                item.isEnabled = popUp.isEnabled
                return item
            }
            if let control = view as? NSButton {
                let item = NSMenuItem(title: control.title, action: control.action, keyEquivalent: "")
                item.target = control.target
                item.isEnabled = control.isEnabled
                return item
            }
            return nil
        }
    }
}

final class CommitShortcutButton: LeadingImageButton {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isEnabled, event.type == .keyDown, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              event.charactersIgnoringModifiers == "\r" else { return super.performKeyEquivalent(with: event) }
        performClick(nil)
        return true
    }
}

enum CommitFileContentPresentation {
    static func viewsAsFileContent(_ file: ChangedFile, headless: Bool) -> Bool {
        guard !file.isSubmodule, !file.isStatusOnly else { return false }
        let isImage = [".bmp", ".gif", ".ico", ".jpg", ".jpeg", ".png", ".tif", ".tiff"].contains { file.path.lowercased().hasSuffix($0) }
        return file.changeType == .added || !file.isTracked || headless || (file.changeType != .deleted && isImage)
    }

    static func numberedText(_ text: String, id: String) -> FileDiff {
        var lines = text.components(separatedBy: "\n")
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        var diff = FileDiff(id: id, fileID: id, lines: lines.enumerated().map {
            DiffLine(id: String($0.offset), oldLineNumber: nil, newLineNumber: $0.offset + 1, kind: .context, text: $0.element)
        })
        diff.isTextOnly = true
        return diff
    }
}
