import AppKit
import GitCommands
import GitExtensionsCore



@MainActor
final class RevisionFilterToolbar: NSObject, NSComboBoxDelegate, NSMenuDelegate {
    struct References { var local: [String] = []; var remote: [String] = []; var tags: [String] = [] }
    static let noResultsFound = "No results found"
    static let builtInRevisionFilters = [
        #"--invert-grep --grep="EXCLUDE_COMMIT_MESSAGE_REGEX_PATTERN""#,
        #"--perl-regexp --author="^(?!.*EXCLUDE_AUTHOR_REGEX_PATTERN)""#,
        "--exclude=refs/remotes/EXCLUDE_REMOTE_REGEX_PATTERN"
    ]

    weak var grid: RevisionGridViewController?
    var references: () -> References = { References() }
    var resolveRevision: (String) async -> ObjectID? = { _ in nil }
    var showAdvancedFilter: () -> Void = {}

    var warn: (String) -> Void = { name in
        let alert = NSAlert()
        alert.messageText = "Nonexisting Git revision"
        alert.informativeText = "Ignoring \(name)"
        alert.alertStyle = .warning
        alert.runModal()
    }

    let advancedButton = NSButton()
    let reflogButton = NSButton()
    let branchesMode = NSPopUpButton(frame: .zero, pullsDown: true)
    let branchCombo = NSComboBox()
    let branchType = NSPopUpButton(frame: .zero, pullsDown: true)
    let revisionCombo = NSComboBox()
    let filterType = NSPopUpButton(frame: .zero, pullsDown: true)
    let firstParentButton = NSButton()
    private var applying = false

    private enum Mode: Int { case all = 1, current, filtered }

    override init() {
        super.init()
        configure(advancedButton, image: "FunnelPencil", tooltip: "Advanced filter", action: #selector(advancedClicked))
        configure(reflogButton, image: "Book", tooltip: "Show reflog references", action: #selector(reflogClicked))
        reflogButton.setButtonType(.pushOnPushOff)
        configure(firstParentButton, image: "ShowOnlyFirstParent", tooltip: "Show only first parent", action: #selector(firstParentClicked))
        firstParentButton.setButtonType(.pushOnPushOff)

        branchesMode.addItem(withTitle: "")
        for (title, tooltip) in [("All branches", "Show all branches"), ("Current branch only", "Show current branch only"), ("Filtered branches", "Show filtered branches")] {
            branchesMode.addItem(withTitle: title)
            branchesMode.lastItem?.toolTip = tooltip
            branchesMode.lastItem?.image = AppKitFactory.resourceImage(title == "Filtered branches" ? "BranchFilter" : "BranchLocal", accessibilityDescription: title)
        }
        branchesMode.target = self; branchesMode.action = #selector(branchModeChanged)
        compact(branchesMode, width: 36)

        branchType.addItem(withTitle: "Branch type")
        for (title, on) in [("Local", true), ("Remote", false), ("Tag", false)] {
            branchType.addItem(withTitle: title); branchType.lastItem?.state = on ? .on : .off
            branchType.lastItem?.target = self; branchType.lastItem?.action = #selector(toggleCheck(_:))
        }
        branchType.menu?.autoenablesItems = false
        compact(branchType, width: 29, image: "EditFilter")

        filterType.addItem(withTitle: "Filter type")
        for (title, on) in [("Commit message", true), ("Committer", false), ("Author", false), ("Diff contains (SLOW)", false)] {
            filterType.addItem(withTitle: title); filterType.lastItem?.state = on ? .on : .off
            filterType.lastItem?.target = self; filterType.lastItem?.action = #selector(filterTypeChanged(_:))
        }
        compact(filterType, width: 29, image: "EditFilter")

        for combo in [branchCombo, revisionCombo] {
            combo.controlSize = .small
            combo.font = AppSettingsStore.shared.applicationFont(size: 11)
            combo.completes = false
            combo.delegate = self
            combo.target = self
            combo.translatesAutoresizingMaskIntoConstraints = false
            combo.widthAnchor.constraint(equalToConstant: 120).isActive = true
        }
        branchCombo.action = #selector(branchEntered)
        branchCombo.toolTip = "Branch filter"
        revisionCombo.action = #selector(revisionEntered)
        revisionCombo.toolTip = "Text filter"
        reloadRevisionHistory()
    }

    private func configure(_ button: NSButton, image: String, tooltip: String, action: Selector) {
        button.image = AppKitFactory.resourceImage(image, accessibilityDescription: tooltip)
        button.title = ""; button.isBordered = false; button.bezelStyle = .texturedRounded
        button.toolTip = tooltip; button.target = self; button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }
    private func compact(_ button: NSPopUpButton, width: CGFloat, image: String? = nil) {
        button.controlSize = .small; button.bezelStyle = .texturedRounded
        if let image { button.item(at: 0)?.image = AppKitFactory.resourceImage(image, accessibilityDescription: button.item(at: 0)?.title) }
        button.item(at: 0)?.title = ""
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
    }



    var customizableItems: [(key: String, title: String, views: [NSView])] {
        [
            ("tsddbtnAdvancedFilter", "Advanced filter", [advancedButton]),
            ("tsbShowReflog", "Show reflog references", [reflogButton]),
            ("tsddbtnBranchesMode", "Branches", [branchesMode]),
            ("ToolBar_group:Branch filter", "Branch filter", [branchesLabel, branchCombo, branchType]),
            ("ToolBar_group:Text filter", "Text filter", [filterLabel, revisionCombo, filterType]),
            ("tsbtnShowOnlyFirstParent", "Show first parents", [firstParentButton])
        ]
    }

    private lazy var branchesLabel: NSTextField = {
        let label = AppKitFactory.label("Branches:"); label.toolTip = "Branch filter"; return label
    }()
    private lazy var filterLabel: NSTextField = {
        let label = AppKitFactory.label("Filter:"); label.toolTip = "Text filter"; return label
    }()
    private lazy var groupSeparator = AppKitFactory.separator()
    var views: [NSView] {
        [advancedButton, reflogButton, branchesMode, branchesLabel, branchCombo, branchType, groupSeparator,
         filterLabel, revisionCombo, filterType, firstParentButton]
    }



    @objc private func advancedClicked() {
        guard let grid else { return }
        let filter = grid.currentFilter
        guard filter.hasFilter else { showAdvancedFilter(); return }
        let menu = NSMenu()
        let resetPath = NSMenuItem(title: "Reset path filter", action: #selector(resetPathFilter), keyEquivalent: "")
        resetPath.target = self; resetPath.isEnabled = !filter.effectivePathFilter.isEmpty
        let resetAll = NSMenuItem(title: "Reset revision filters", action: #selector(resetAllFilters), keyEquivalent: "")
        resetAll.target = self
        let advanced = NSMenuItem(title: "Advanced filter", action: #selector(openAdvancedFilter), keyEquivalent: "")
        advanced.target = self
        menu.autoenablesItems = false
        [resetPath, resetAll, .separator(), advanced].forEach(menu.addItem)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: advancedButton.bounds.maxY + 2), in: advancedButton)
    }
    @objc func resetPathFilter() { grid?.setAndApplyPathFilter("") }
    @objc func resetAllFilters() { grid?.resetAllFiltersAndRefresh() }
    @objc func openAdvancedFilter() { showAdvancedFilter() }
    @objc private func reflogClicked() { grid?.toggleShowReflogReferences() }
    @objc private func firstParentClicked() { grid?.toggleShowOnlyFirstParent() }
    @objc private func branchModeChanged() {
        switch Mode(rawValue: branchesMode.indexOfSelectedItem) {
        case .all: grid?.showAllBranches()
        case .current: grid?.showCurrentBranchOnly()
        case .filtered: grid?.showFilteredBranches()
        case nil: break
        }
    }
    @objc private func toggleCheck(_ item: NSMenuItem) { item.state = item.state == .on ? .off : .on }
    @objc private func filterTypeChanged(_ item: NSMenuItem) {
        item.state = item.state == .on ? .off : .on

        if !revisionCombo.stringValue.trimmingCharacters(in: .whitespaces).isEmpty { applyRevisionFilter() }
    }
    @objc private func revisionEntered() { applyRevisionFilter() }
    @objc private func branchEntered() { applyCustomBranchFilter(checkBranch: true) }

    private func checked(_ title: String) -> Bool { filterType.item(withTitle: title)?.state == .on }


    func applyRevisionFilter() {
        guard !applying else { return }
        applying = true; defer { applying = false }
        grid?.setAndApplyRevisionFilter(.init(text: revisionCombo.stringValue.trimmingCharacters(in: .whitespaces),
                                              message: checked("Commit message"), committer: checked("Committer"),
                                              author: checked("Author"), diffContent: checked("Diff contains (SLOW)")))
    }


    func applyCustomBranchFilter(checkBranch: Bool) {
        guard !applying else { return }
        let text = branchCombo.stringValue == Self.noResultsFound ? "" : branchCombo.stringValue
        guard checkBranch, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            grid?.setAndApplyBranchFilter(text); return
        }
        applying = true
        let known = Set(references().local + references().remote + references().tags)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { applying = false }
            var accepted: [String] = []
            for branch in text.split(whereSeparator: \.isWhitespace).map(String.init) {
                let wildcard = branch.contains { "?*[".contains($0) }
                if branch.hasPrefix("--") || known.contains(branch) || branch.contains("..") || wildcard {
                    accepted.append(branch); continue
                }
                let reference = branch.hasPrefix("^") ? String(branch.dropFirst()) : branch
                if await resolveRevision(reference) == nil { warn(branch); continue }
                accepted.append(branch)
            }
            grid?.setAndApplyBranchFilter(accepted.joined(separator: " "))
        }
    }


    func branchSuggestions(for text: String) -> [String] {
        let refs = references()
        let local = branchType.item(withTitle: "Local")?.state == .on
        let remote = branchType.item(withTitle: "Remote")?.state == .on
        let tag = branchType.item(withTitle: "Tag")?.state == .on
        let any = !local && !remote && !tag
        let names = (local || any ? refs.local : []) + (remote || any ? refs.remote : []) + (tag || any ? refs.tags : [])
        let matches = names.filter { text.isEmpty || $0.range(of: text, options: .caseInsensitive) != nil }
        return matches.isEmpty ? [Self.noResultsFound] : matches
    }
    func comboBoxWillPopUp(_ notification: Notification) {
        guard (notification.object as? NSComboBox) === branchCombo else { return }
        branchCombo.removeAllItems()
        branchCombo.addItems(withObjectValues: branchSuggestions(for: branchCombo.stringValue))
    }
    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSComboBox) === branchCombo else { return }
        branchCombo.removeAllItems()
        branchCombo.addItems(withObjectValues: branchSuggestions(for: branchCombo.stringValue))
    }


    func setBranchFilter(_ filter: String) {
        branchCombo.stringValue = filter
        applyCustomBranchFilter(checkBranch: false)
    }

    func focus(in window: NSWindow?) {
        let revisionFocused = (window?.firstResponder as? NSText)?.delegate as? NSComboBox === revisionCombo
        window?.makeFirstResponder(revisionFocused ? branchCombo : revisionCombo)
    }

    private func reloadRevisionHistory() {
        let history = AppSettingsStore.shared.revisionGridPreferences.revisionFilterHistory
        revisionCombo.removeAllItems()
        revisionCombo.addItems(withObjectValues: history + Self.builtInRevisionFilters.filter { !history.contains($0) })
    }


    func filterChanged(_ filter: RevisionGridFilter) {
        firstParentButton.state = filter.showOnlyFirstParent ? .on : .off
        reflogButton.state = filter.showReflogReferences ? .on : .off
        var mode = Mode.all
        if filter.isShowFilteredBranchesChecked { mode = .filtered; branchCombo.stringValue = filter.effectiveBranchFilter }
        if filter.isShowCurrentBranchOnlyChecked { mode = .current }
        for (index, item) in branchesMode.itemArray.enumerated() where index > 0 { item.state = index == mode.rawValue ? .on : .off }
        branchesMode.item(at: 0)?.image = branchesMode.item(at: mode.rawValue)?.image
        branchesMode.toolTip = branchesMode.item(at: mode.rawValue)?.toolTip

        let filters = [(filter.effectiveMessage, "Commit message"), (filter.effectiveCommitter, "Committer"),
                       (filter.effectiveAuthor, "Author"), (filter.effectiveDiffContent, "Diff contains (SLOW)")]
        revisionCombo.stringValue = ""
        if filters.contains(where: { !$0.0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            for (value, title) in filters {
                let matches = !value.trimmingCharacters(in: .whitespaces).isEmpty
                    && (revisionCombo.stringValue.isEmpty || value == revisionCombo.stringValue)
                if matches { revisionCombo.stringValue = value }
                filterType.item(withTitle: title)?.state = matches ? .on : .off
            }
        }
        let text = revisionCombo.stringValue.trimmingCharacters(in: .whitespaces)
        var preferences = AppSettingsStore.shared.revisionGridPreferences
        if !text.isEmpty, preferences.revisionFilterHistory.first != text {
            preferences.revisionFilterHistory.removeAll { $0 == text }
            preferences.revisionFilterHistory.insert(text, at: 0)
            preferences.revisionFilterHistory = Array(preferences.revisionFilterHistory.prefix(30))
            AppSettingsStore.shared.saveRevisionGridPreferences(preferences)
            reloadRevisionHistory()
            revisionCombo.stringValue = text
        }
        let summary = filter.summary
        advancedButton.toolTip = summary.isEmpty ? "Advanced filter" : summary
        advancedButton.image = AppKitFactory.resourceImage(filter.hasFilter ? "FunnelExclamation" : "FunnelPencil", accessibilityDescription: "Advanced filter")
    }
}


@MainActor
final class RevisionFilterDialogController: NSViewController {
    private var filter: RevisionGridFilter
    private let defaultLimit: Int
    private let completion: (RevisionGridFilter?) -> Void
    private let sinceCheck = NSButton(checkboxWithTitle: "Since", target: nil, action: nil)
    private let since = NSDatePicker()
    private let untilCheck = NSButton(checkboxWithTitle: "Until", target: nil, action: nil)
    private let until = NSDatePicker()
    private let authorCheck = NSButton(checkboxWithTitle: "Author", target: nil, action: nil)
    private let author = NSTextField(string: "")
    private let committerCheck = NSButton(checkboxWithTitle: "Committer", target: nil, action: nil)
    private let committer = NSTextField(string: "")
    private let messageCheck = NSButton(checkboxWithTitle: "Message", target: nil, action: nil)
    private let message = NSTextField(string: "")
    private let diffCheck = NSButton(checkboxWithTitle: "Diff contains", target: nil, action: nil)
    private let diff = NSTextField(string: "")
    private let ignoreCase = NSButton(checkboxWithTitle: "Ignore case", target: nil, action: nil)
    private let limitCheck = NSButton(checkboxWithTitle: "Limit", target: nil, action: nil)
    private let limit = NSTextField(string: "")
    private let limitStepper = NSStepper()
    private let pathCheck = NSButton(checkboxWithTitle: "Path filter", target: nil, action: nil)
    private let path = NSTextField(string: "")
    private let branchCheck = NSButton(checkboxWithTitle: "Branches", target: nil, action: nil)
    private let branch = NSTextField(string: "")
    private let currentBranchOnly = NSButton(checkboxWithTitle: "Show current branch only", target: nil, action: nil)
    private let reflog = NSButton(checkboxWithTitle: "Show reflog", target: nil, action: nil)
    private let firstParent = NSButton(checkboxWithTitle: "Show only first parent", target: nil, action: nil)
    private let hideMerges = NSButton(checkboxWithTitle: "Hide merge commits", target: nil, action: nil)
    private let simplifyByDecoration = NSButton(checkboxWithTitle: "Simplify by decoration", target: nil, action: nil)
    private let fullHistory = NSButton(checkboxWithTitle: "Full history", target: nil, action: nil)
    private let simplifyMerges = NSButton(checkboxWithTitle: "Simplify merges", target: nil, action: nil)

    init(filter: RevisionGridFilter, defaultLimit: Int, completion: @escaping (RevisionGridFilter?) -> Void) {
        self.filter = filter; self.defaultLimit = defaultLimit; self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    static func present(filter: RevisionGridFilter, defaultLimit: Int, window: NSWindow, completion: @escaping (RevisionGridFilter?) -> Void) {
        let panel = NSPanel(contentViewController: RevisionFilterDialogController(filter: filter, defaultLimit: defaultLimit) { result in
            completion(result)
        })
        panel.title = "Filter"
        panel.styleMask = [.titled, .closable]
        window.beginSheet(panel)
    }

    override func loadView() {
        for picker in [since, until] {
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
        }
        diffCheck.toolTip = "SLOW"; diff.toolTip = "SLOW"
        limitStepper.minValue = 0; limitStepper.maxValue = 1_000_000; limitStepper.increment = 10_000
        limitStepper.target = self; limitStepper.action = #selector(stepperChanged)
        let limitRow = NSStackView(views: [limit, limitStepper])
        let rows: [[NSView]] = [[sinceCheck, since], [untilCheck, until], [authorCheck, author], [committerCheck, committer],
                                [messageCheck, message], [diffCheck, diff], [NSGridCell.emptyContentView, ignoreCase],
                                [limitCheck, limitRow], [pathCheck, path], [branchCheck, branch]]
        let grid = NSGridView(views: rows)
        grid.column(at: 1).width = 260
        let options = NSStackView(views: [currentBranchOnly, reflog, firstParent, hideMerges, simplifyByDecoration, fullHistory, simplifyMerges])
        options.orientation = .vertical; options.alignment = .leading
        let ok = NSButton(title: "OK", target: self, action: #selector(accept)); ok.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(dismissDialog)); cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(), cancel, ok])
        let root = NSStackView(views: [grid, options, buttons])
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        buttons.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true
        for control in [sinceCheck, untilCheck, authorCheck, committerCheck, messageCheck, diffCheck, limitCheck, pathCheck,
                        branchCheck, currentBranchOnly, reflog, fullHistory] {
            control.target = self; control.action = #selector(optionChanged(_:))
        }
        view = root
        load()
    }


    private func load() {
        sinceCheck.state = filter.byDateFrom ? .on : .off
        since.dateValue = filter.dateFrom ?? Calendar.current.startOfDay(for: Date())
        untilCheck.state = filter.byDateTo ? .on : .off
        until.dateValue = filter.dateTo ?? Calendar.current.startOfDay(for: Date())
        authorCheck.state = filter.byAuthor ? .on : .off; author.stringValue = filter.author
        committerCheck.state = filter.byCommitter ? .on : .off; committer.stringValue = filter.committer
        messageCheck.state = filter.byMessage ? .on : .off; message.stringValue = filter.message
        diffCheck.state = filter.byDiffContent ? .on : .off; diff.stringValue = filter.diffContent
        ignoreCase.state = filter.ignoreCase ? .on : .off
        limitCheck.state = filter.byCommitsLimit ? .on : .off
        setLimit(filter.effectiveCommitsLimit(default: defaultLimit))
        pathCheck.state = filter.byPathFilter ? .on : .off; path.stringValue = filter.pathFilter
        branchCheck.state = filter.isShowFilteredBranchesChecked ? .on : .off; branch.stringValue = filter.branchFilter
        currentBranchOnly.state = filter.showCurrentBranchOnly ? .on : .off
        reflog.state = filter.showReflogReferences ? .on : .off
        firstParent.state = filter.showOnlyFirstParent ? .on : .off
        hideMerges.state = filter.hideMergeCommits ? .on : .off
        simplifyByDecoration.state = filter.showSimplifyByDecoration ? .on : .off
        fullHistory.state = filter.showFullHistory ? .on : .off
        simplifyMerges.state = filter.showSimplifyMerges ? .on : .off
        updateFilters()
    }
    private func setLimit(_ value: Int) { limit.stringValue = String(value); limitStepper.integerValue = value }
    @objc private func stepperChanged() { limit.stringValue = String(limitStepper.integerValue) }
    @objc private func optionChanged(_ sender: NSButton) {
        updateFilters()

        if sender === limitCheck, limitCheck.state == .off { setLimit(defaultLimit) }
    }

    private func updateFilters() {
        since.isEnabled = sinceCheck.state == .on
        until.isEnabled = untilCheck.state == .on
        author.isEnabled = authorCheck.state == .on
        committer.isEnabled = committerCheck.state == .on
        message.isEnabled = messageCheck.state == .on
        diff.isEnabled = diffCheck.state == .on
        ignoreCase.isEnabled = author.isEnabled || committer.isEnabled || messageCheck.state == .on || diffCheck.state == .on
        limit.isEnabled = limitCheck.state == .on; limitStepper.isEnabled = limit.isEnabled
        path.isEnabled = pathCheck.state == .on
        currentBranchOnly.isEnabled = reflog.state == .off
        branchCheck.isEnabled = currentBranchOnly.state == .off && reflog.state == .off
        branch.isEnabled = branchCheck.state == .on
        simplifyMerges.isEnabled = fullHistory.state == .on
    }

    @objc private func accept() {
        filter.byDateFrom = sinceCheck.state == .on; filter.dateFrom = since.dateValue
        filter.byDateTo = untilCheck.state == .on; filter.dateTo = until.dateValue
        filter.byAuthor = authorCheck.state == .on; filter.author = author.stringValue.trimmingCharacters(in: .whitespaces)
        filter.byCommitter = committerCheck.state == .on; filter.committer = committer.stringValue.trimmingCharacters(in: .whitespaces)
        filter.byMessage = messageCheck.state == .on; filter.message = message.stringValue.trimmingCharacters(in: .whitespaces)
        filter.byDiffContent = diffCheck.state == .on; filter.diffContent = diff.stringValue.trimmingCharacters(in: .whitespaces)
        filter.ignoreCase = ignoreCase.state == .on
        filter.byCommitsLimit = limitCheck.state == .on
        filter.commitsLimit = min(1_000_000, max(0, Int(limit.stringValue.trimmingCharacters(in: .whitespaces)) ?? defaultLimit))
        filter.byPathFilter = pathCheck.state == .on; filter.pathFilter = path.stringValue
        filter.byBranchFilter = branchCheck.state == .on; filter.branchFilter = branch.stringValue
        filter.showCurrentBranchOnly = currentBranchOnly.state == .on
        filter.showReflogReferences = reflog.state == .on
        filter.showOnlyFirstParent = firstParent.state == .on
        filter.hideMergeCommits = hideMerges.state == .on
        filter.showSimplifyByDecoration = simplifyByDecoration.state == .on
        filter.showFullHistory = fullHistory.state == .on
        filter.showSimplifyMerges = simplifyMerges.state == .on
        finish(filter)
    }
    @objc private func dismissDialog() { finish(nil) }
    private func finish(_ result: RevisionGridFilter?) {
        if let window = view.window { window.sheetParent?.endSheet(window) }
        completion(result)
    }
}


@MainActor
final class GoToCommitDialog: NSViewController, NSTextFieldDelegate, NSComboBoxDelegate {
    private let expression = NSTextField(string: "")
    private let tags = NSComboBox()
    private let branches = NSComboBox()
    private let tagNames: [String]
    private let branchNames: [String]
    private var selected = ""
    private let completion: (String?) -> Void

    init(branches: [String], tags: [String], initialExpression: String, completion: @escaping (String?) -> Void) {
        branchNames = Array(branches.prefix(1_000)); tagNames = Array(tags.prefix(1_000)); self.completion = completion
        super.init(nibName: nil, bundle: nil)
        expression.stringValue = initialExpression
        selected = initialExpression
    }
    required init?(coder: NSCoder) { nil }

    static func present(window: NSWindow, branches: [String], tags: [String], initialExpression: String, completion: @escaping (String?) -> Void) {
        let panel = NSPanel(contentViewController: GoToCommitDialog(branches: branches, tags: tags, initialExpression: initialExpression, completion: completion))
        panel.title = "Go to commit"; panel.styleMask = [.titled, .closable]
        window.beginSheet(panel)
    }

    override func loadView() {
        expression.delegate = self
        for (combo, names) in [(tags, tagNames), (branches, branchNames)] {
            combo.addItems(withObjectValues: names); combo.delegate = self; combo.completes = true
        }
        let help = NSTextField(wrappingLabelWithString: "Commit expression examples:\n- complete commit hash: e. g.: 8eab51fcb9c4538eb74c4dcd4c31ffd693ad25c9\n- partial commit hash (if unique): e. g.: 8eab51fcb9c453\n- tag name\n- branch name")
        let link = NSButton(title: "More see git-rev-parse", target: self, action: #selector(openHelp))
        link.isBordered = false; link.contentTintColor = .linkColor
        let helpBox = NSBox(); helpBox.title = "Help"
        let helpStack = NSStackView(views: [help, link]); helpStack.orientation = .vertical; helpStack.alignment = .leading
        helpBox.contentView = helpStack
        let go = NSButton(title: "Go", target: self, action: #selector(goClicked)); go.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked)); cancel.keyEquivalent = "\u{1b}"
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Commit expression:"), expression],
                                      [NSTextField(labelWithString: "Go to tag:"), tags],
                                      [NSTextField(labelWithString: "Go to branch:"), branches]])
        grid.column(at: 1).width = 300
        let root = NSStackView(views: [grid, helpBox, NSStackView(views: [NSView(), cancel, go])])
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        helpBox.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        view = root
    }
    override func viewDidAppear() { super.viewDidAppear(); view.window?.makeFirstResponder(expression); expression.selectText(nil) }


    func controlTextDidChange(_ notification: Notification) { take(notification.object as? NSControl) }
    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let combo = notification.object as? NSComboBox, combo.indexOfSelectedItem >= 0 else { return }
        combo.stringValue = combo.itemObjectValue(at: combo.indexOfSelectedItem) as? String ?? ""
        take(combo)
    }
    private func take(_ control: NSControl?) {
        if control === expression { selected = expression.stringValue.trimmingCharacters(in: .whitespaces) }
        else if control === tags { selected = tagNames.contains(tags.stringValue) ? "refs/tags/" + tags.stringValue : "" }
        else if control === branches { selected = branchNames.contains(branches.stringValue) ? "refs/heads/" + branches.stringValue : "" }
    }
    @objc private func openHelp() { NSWorkspace.shared.open(URL(string: "https://git-scm.com/docs/git-rev-parse#_specifying_revisions")!) }
    @objc private func goClicked() { finish(selected) }
    @objc private func cancelClicked() { finish(nil) }
    private func finish(_ value: String?) {
        if let window = view.window { window.sheetParent?.endSheet(window) }
        completion(value)
    }
}
