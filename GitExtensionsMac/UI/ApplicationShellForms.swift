import GitExtensionsCore
import GitCommands
import AppKit


@MainActor
final class RecentRepositoriesSettingsDialog: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private var settings: RecentRepositorySettings
    private var history: [RepositoryHistoryEntry]
    private let store: AppSettingsStore
    private var completion: ((Bool) -> Void)?
    private var topRepos: [RecentRepoInfo] = []
    private var recentRepos: [RecentRepoInfo] = []
    private let topList = NSTableView()
    private let recentList = NSTableView()
    private let maxTop = NSTextField()
    private let maxTopStepper = NSStepper()
    private let historySize = NSTextField()
    private let historySizeStepper = NSStepper()
    private let comboWidth = NSTextField()
    private let comboWidthStepper = NSStepper()
    private let hideTop = NSButton(checkboxWithTitle: "Hide top repositories from recent repositories list", target: nil, action: nil)
    private let sortTop = NSButton(checkboxWithTitle: "Sort top repositories alphabetically", target: nil, action: nil)
    private let sortRecent = NSButton(checkboxWithTitle: "Sort recent repositories alphabetically", target: nil, action: nil)
    private let strategies: [(ShorteningRecentRepoPathStrategy, NSButton)] = [
        (.none, NSButton(radioButtonWithTitle: "Do not shorten", target: nil, action: nil)),
        (.middleDots, NSButton(radioButtonWithTitle: "Replace middle part with dots", target: nil, action: nil)),
        (.mostSignDir, NSButton(radioButtonWithTitle: "The most significant directory", target: nil, action: nil))
    ]
    private var previousComboWidth = 0

    static func present(owner: NSWindow, store: AppSettingsStore? = nil, completion: @escaping (Bool) -> Void) {
        let controller = RecentRepositoriesSettingsDialog(store: store ?? .shared)
        controller.completion = completion
        let panel = NSPanel(contentViewController: controller)
        panel.title = "Recent repositories settings"
        panel.styleMask = [.titled, .resizable]
        panel.setContentSize(NSSize(width: 684, height: 361))
        panel.contentMinSize = NSSize(width: 684, height: 361)
        owner.beginSheet(panel)
    }

    init(store: AppSettingsStore) {
        self.store = store
        settings = store.recentRepositorySettings
        history = store.recentRepositories
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        func number(_ field: NSTextField, _ stepper: NSStepper, value: Int, range: ClosedRange<Int>) -> NSView {
            field.integerValue = min(max(value, range.lowerBound), range.upperBound)
            field.alignment = .right
            field.target = self
            field.action = #selector(numberChanged(_:))
            let formatter = NumberFormatter()
            formatter.minimum = NSNumber(value: range.lowerBound)
            formatter.maximum = NSNumber(value: range.upperBound)
            formatter.allowsFloats = false
            field.formatter = formatter
            field.widthAnchor.constraint(equalToConstant: 61).isActive = true
            stepper.minValue = Double(range.lowerBound)
            stepper.maxValue = Double(range.upperBound)
            stepper.integerValue = field.integerValue
            stepper.valueWraps = false
            stepper.target = self
            stepper.action = #selector(stepperChanged(_:))
            let row = NSStackView(views: [field, stepper])
            row.spacing = 2
            return row
        }
        for button in [hideTop, sortTop, sortRecent] + strategies.map(\.1) {
            button.target = self
            button.action = #selector(optionChanged)
        }
        hideTop.state = settings.hideTopRepositoriesFromRecentList ? .on : .off
        sortTop.state = settings.sortTopRepos ? .on : .off
        sortRecent.state = settings.sortRecentRepos ? .on : .off
        for (strategy, button) in strategies { button.state = strategy == settings.shorteningStrategy ? .on : .off }
        previousComboWidth = settings.comboMinWidth
        let strategyStack = NSStackView(views: strategies.map(\.1))
        strategyStack.orientation = .vertical
        strategyStack.alignment = .leading
        strategyStack.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
        let shorteningTitle = NSTextField(labelWithString: "Shortening strategy")
        let note = NSTextField(wrappingLabelWithString: "NB: The width of the columns helps to visualise how the repository name will be shown in the combobox.")
        note.preferredMaxLayoutWidth = 330
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Maximum number of top repositories"),
             number(maxTop, maxTopStepper, value: settings.maxTopRepositories, range: RecentRepositorySettings.maxTopRepositoriesRange)],
            [NSTextField(labelWithString: "Maximum number of recent repositories"),
             number(historySize, historySizeStepper, value: settings.historySize, range: RecentRepositorySettings.historySizeRange)],
            [hideTop], [sortTop], [sortRecent], [shorteningTitle], [strategyStack],
            [NSTextField(labelWithString: "Combobox minimum width (0 = Autosize)"),
             number(comboWidth, comboWidthStepper, value: settings.comboMinWidth, range: RecentRepositorySettings.comboMinWidthRange)],
            [note]
        ])
        grid.rowSpacing = 6
        grid.column(at: 0).xPlacement = .leading
        grid.rowAlignment = .firstBaseline
        for row in [2, 3, 4, 5, 6, 8] { grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 2), verticalRange: NSRange(location: row, length: 1)) }
        grid.translatesAutoresizingMaskIntoConstraints = false

        func list(_ table: NSTableView, title: String) -> (NSTextField, NSScrollView) {
            let column = NSTableColumn(identifier: .init("Header"))
            table.addTableColumn(column)
            table.headerView = nil
            table.allowsMultipleSelection = true
            table.columnAutoresizingStyle = .noColumnAutoresizing
            table.dataSource = self
            table.delegate = self
            table.target = self
            table.doubleAction = #selector(doubleClicked(_:))
            let menu = NSMenu()
            menu.delegate = self
            table.menu = menu
            let scroll = NSScrollView()
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            scroll.borderType = .bezelBorder
            scroll.translatesAutoresizingMaskIntoConstraints = false
            let label = NSTextField(labelWithString: title)
            label.translatesAutoresizingMaskIntoConstraints = false
            return (label, scroll)
        }
        let (topLabel, topScroll) = list(topList, title: "Top repositories")
        let (recentLabel, recentScroll) = list(recentList, title: "Recent repositories")

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: "OK", target: self, action: #selector(ok))
        ok.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, ok])
        buttons.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        for view in [grid, topLabel, topScroll, recentLabel, recentScroll, buttons] as [NSView] { root.addSubview(view) }
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            grid.widthAnchor.constraint(equalToConstant: 340),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: buttons.topAnchor, constant: -8),
            topLabel.leadingAnchor.constraint(equalTo: grid.trailingAnchor, constant: 12),
            topLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            topScroll.leadingAnchor.constraint(equalTo: topLabel.leadingAnchor),
            topScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            topScroll.topAnchor.constraint(equalTo: topLabel.bottomAnchor, constant: 4),
            topScroll.heightAnchor.constraint(equalTo: recentScroll.heightAnchor, multiplier: 0.6),
            recentLabel.leadingAnchor.constraint(equalTo: topLabel.leadingAnchor),
            recentLabel.topAnchor.constraint(equalTo: topScroll.bottomAnchor, constant: 8),
            recentScroll.leadingAnchor.constraint(equalTo: topLabel.leadingAnchor),
            recentScroll.trailingAnchor.constraint(equalTo: topScroll.trailingAnchor),
            recentScroll.topAnchor.constraint(equalTo: recentLabel.bottomAnchor, constant: 4),
            recentScroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 684),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 380)
        ])
        view = root
        refreshRepos()
    }

    private var currentSettings: RecentRepositorySettings {
        var value = settings
        value.maxTopRepositories = maxTop.integerValue
        value.historySize = historySize.integerValue
        value.hideTopRepositoriesFromRecentList = hideTop.state == .on
        value.sortTopRepos = sortTop.state == .on
        value.sortRecentRepos = sortRecent.state == .on
        value.shorteningStrategy = strategies.first { $0.1.state == .on }?.0 ?? .none
        value.comboMinWidth = comboWidth.integerValue
        return value
    }


    private func refreshRepos() {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let splitter = RecentRepoSplitter(settings: currentSettings) { ($0 as NSString).size(withAttributes: [.font: font]).width }
        (topRepos, recentRepos) = splitter.split(history)
        topList.reloadData()
        recentList.reloadData()
        setComboWidth()
    }


    private func setComboWidth() {
        for (table, repos) in [(topList, topRepos), (recentList, recentRepos)] {
            let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let autosize = (repos.map { (($0.caption ?? "") as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0) + 12
            let width = comboWidth.integerValue == 0 ? autosize : CGFloat(max(RecentRepositorySettings.minimumComboWidth, comboWidth.integerValue))
            table.tableColumns.first?.width = width
        }
    }

    @objc private func optionChanged() { refreshRepos() }

    @objc private func stepperChanged(_ sender: NSStepper) {
        let field = sender === maxTopStepper ? maxTop : sender === historySizeStepper ? historySize : comboWidth
        field.integerValue = sender.integerValue
        numberChanged(field)
    }

    @objc private func numberChanged(_ sender: NSTextField) {
        if sender === maxTop { maxTopStepper.integerValue = maxTop.integerValue; refreshRepos() }
        else if sender === historySize { historySizeStepper.integerValue = historySize.integerValue }
        else if sender === comboWidth { comboMinWidthChanged() }
    }


    private func comboMinWidthChanged() {
        var value = comboWidth.integerValue
        guard value != previousComboWidth else { return }
        if value < RecentRepositorySettings.minimumComboWidth {
            value = value < previousComboWidth ? 0 : RecentRepositorySettings.minimumComboWidth
        }
        comboWidth.integerValue = value
        comboWidthStepper.integerValue = value
        previousComboWidth = value
        setComboWidth()
    }



    private func repos(for table: NSTableView) -> [RecentRepoInfo] { table === topList ? topRepos : recentRepos }

    func numberOfRows(in tableView: NSTableView) -> Int { repos(for: tableView).count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let info = repos(for: tableView)[row]
        let label = NSTextField(labelWithString: info.caption ?? info.repo.path)
        label.lineBreakMode = .byClipping

        let anchored = tableView === topList ? info.repo.anchor == .anchoredInTop : info.repo.anchor == .anchoredInRecent
        label.font = anchored ? .boldSystemFont(ofSize: NSFont.systemFontSize) : .systemFont(ofSize: NSFont.systemFontSize)
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: info.repo.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            label.textColor = .systemRed
        }
        label.toolTip = info.repo.path
        return label
    }

    private func selected(_ table: NSTableView) -> [RecentRepoInfo] {
        let repos = repos(for: table)
        let rows = table.clickedRow >= 0 && !table.selectedRowIndexes.contains(table.clickedRow)
            ? IndexSet(integer: table.clickedRow) : table.selectedRowIndexes
        return rows.filter { $0 < repos.count }.map { repos[$0] }
    }

    private func setAnchor(_ anchor: RepositoryAnchor, for repos: [RecentRepoInfo]) {
        guard !repos.isEmpty else { return }
        let paths = Set(repos.map(\.repo.path))
        for index in history.indices where paths.contains(history[index].path) { history[index].anchor = anchor }
        refreshRepos()
    }


    @objc private func doubleClicked(_ sender: NSTableView) {
        setAnchor(sender === topList ? .anchoredInRecent : .anchoredInTop, for: selected(sender))
    }


    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let table = [topList, recentList].first(where: { $0.menu === menu }) else { return }
        let repos = selected(table)
        guard let last = repos.last else { return }
        menu.autoenablesItems = false
        func add(_ title: String, enabled: Bool, _ handler: @escaping () -> Void) {
            let item = DashboardClosureMenuItem(title: title, handler: handler)
            item.isEnabled = enabled
            menu.addItem(item)
        }
        add("Anchor to top repositories", enabled: last.repo.anchor != .anchoredInTop) { [weak self] in self?.setAnchor(.anchoredInTop, for: repos) }
        add("Anchor to recent repositories", enabled: last.repo.anchor != .anchoredInRecent) { [weak self] in self?.setAnchor(.anchoredInRecent, for: repos) }
        add("Remove anchor", enabled: last.repo.anchor != .none) { [weak self] in self?.setAnchor(.none, for: repos) }
        add("Remove from recent repositories", enabled: true) { [weak self] in
            guard let self else { return }
            for repo in repos { store.removeRecentRepository(path: repo.repo.path) }
            history = store.recentRepositories
            refreshRepos()
        }
    }




    @objc private func ok() {
        guard view.window?.makeFirstResponder(nil) != false else { return }
        comboMinWidthChanged()
        store.saveRecentRepositorySettings(currentSettings)
        store.saveRecentHistory(history)
        close(true)
    }

    @objc private func cancel() { close(false) }

    private func close(_ saved: Bool) {
        guard let window = view.window else { return }
        window.sheetParent?.endSheet(window)
        let completion = completion
        self.completion = nil
        completion?(saved)
    }
}


@MainActor
final class OpenLocalRepositoryDialog: NSViewController, NSComboBoxDelegate {
    static let warningOpenFailed = "The selected directory is not a valid git repository."

    private let directory = NSComboBox()
    private let goUp = NSButton()
    private let store: AppSettingsStore
    private let currentRepository: URL?
    private var completion: ((URL?) -> Void)?

    static func present(owner: NSWindow, currentRepository: URL?, store: AppSettingsStore? = nil, completion: @escaping (URL?) -> Void) {
        let controller = OpenLocalRepositoryDialog(store: store ?? .shared, currentRepository: currentRepository)
        controller.completion = completion
        let panel = NSPanel(contentViewController: controller)
        panel.title = "Open local repository"
        panel.styleMask = [.titled, .resizable]
        panel.contentMinSize = NSSize(width: 450, height: 90)
        panel.contentMaxSize = NSSize(width: 800, height: 90)
        owner.beginSheet(panel)
    }

    init(store: AppSettingsStore, currentRepository: URL?) {
        self.store = store
        self.currentRepository = currentRepository
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }


    static func directories(store: AppSettingsStore, currentRepository: URL?) -> [String] {
        func withSeparator(_ path: String) -> String { path.hasSuffix("/") ? path : path + "/" }
        var directories: [String] = []
        let clonePath = store.repositoryCreationPreferences.cloneDestinationPath
        if !clonePath.trimmingCharacters(in: .whitespaces).isEmpty { directories.append(withSeparator(clonePath)) }
        if let currentRepository {
            let path = RepositoryHistory.normalizedPath(currentRepository.path)
            if path != "/" { directories.append(withSeparator((path as NSString).deletingLastPathComponent)) }
        }
        directories += store.recentRepositories.map(\.path)
        if directories.isEmpty {
            if let recent = store.lastRepositoryPath, !recent.isEmpty { directories.append(withSeparator(recent)) }
            directories.append(withSeparator(FileManager.default.homeDirectoryForCurrentUser.path))
        }
        var seen = Set<String>()
        return directories.filter { seen.insert($0).inserted }
    }


    static func openGitRepository(_ path: String, store: AppSettingsStore) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
              RepositoryHistory.isValidGitWorkingDir(path) else { return nil }
        let url = URL(fileURLWithPath: RepositoryHistory.normalizedPath(path), isDirectory: true)
        store.recordRecentRepository(url)
        return url
    }

    override func loadView() {
        let label = NSTextField(labelWithString: "Directory:")
        directory.addItems(withObjectValues: Self.directories(store: store, currentRepository: currentRepository))
        if directory.numberOfItems > 0 { directory.selectItem(at: 0) }
        directory.completes = true
        directory.delegate = self
        directory.target = self
        directory.action = #selector(open)
        goUp.image = AppKitFactory.resourceImage("NavigateUp", accessibilityDescription: "Go to parent directory...")
        goUp.bezelStyle = .smallSquare
        goUp.imagePosition = .imageOnly
        goUp.toolTip = "Go to parent directory..."
        goUp.target = self
        goUp.action = #selector(goToParent)
        let browse = NSButton(title: "Browse...", target: self, action: #selector(browse))
        let openButton = NSButton(title: "Open", target: self, action: #selector(open))
        openButton.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let row = NSStackView(views: [label, directory, goUp])
        let buttons = NSStackView(views: [browse, NSView(), cancel, openButton])
        let stack = NSStackView(views: [row, buttons])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        directory.widthAnchor.constraint(greaterThanOrEqualToConstant: 330).isActive = true
        view = stack
        updateGoUp()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(directory)
    }

    func controlTextDidChange(_ obj: Notification) { updateGoUp() }
    func comboBoxSelectionDidChange(_ notification: Notification) { DispatchQueue.main.async { self.updateGoUp() } }


    private func updateGoUp() {
        var isDirectory: ObjCBool = false
        let path = directory.stringValue
        goUp.isEnabled = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            && RepositoryHistory.normalizedPath(path) != "/"
    }

    @objc private func goToParent() {
        let path = RepositoryHistory.normalizedPath(directory.stringValue)
        guard path != "/", path.hasPrefix("/") else { return }
        let parent = (path as NSString).deletingLastPathComponent
        directory.stringValue = parent.hasSuffix("/") ? parent : parent + "/"
        view.window?.makeFirstResponder(directory)
        directory.currentEditor()?.selectedRange = NSRange(location: directory.stringValue.utf16.count, length: 0)
        updateGoUp()
    }


    @objc private func browse() {
        guard let window = view.window else { return }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.directoryURL = URL(fileURLWithPath: directory.stringValue, isDirectory: true)
        picker.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = picker.url, let self else { return }
            directory.stringValue = url.path
            open()
        }
    }


    @objc private func open() {
        let path = directory.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        directory.stringValue = path
        if let url = Self.openGitRepository((path as NSString).expandingTildeInPath, store: store) {
            close(url)
            return
        }
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Error"
        alert.informativeText = Self.warningOpenFailed
        alert.beginSheetModal(for: window)
    }

    @objc private func cancel() { close(nil) }

    private func close(_ url: URL?) {
        guard let window = view.window else { return }
        window.sheetParent?.endSheet(window)
        let completion = completion
        self.completion = nil
        completion?(url)
    }
}


@MainActor
final class DonateWindowController: NSWindowController {
    private static var shared: DonateWindowController?

    static let donateText = "We have a dedicated team of collaborators that spends a lot of time maintaining the app, working on new features and fixing bugs."
        + "You can support the project by making a financial contribution. Donations will be used to cover running costs "
        + "and to get the resources needed to keep the project running. We will also use donations to thank collaborators for their efforts.\n\n"
        + "Click on the button below to get more information about making a donation."

    static func show() {
        if shared == nil {
            let text = NSTextField(wrappingLabelWithString: donateText)
            text.preferredMaxLayoutWidth = 420
            let badge = NSButton(image: AppKitFactory.resourceImage("DonateBadge", size: NSSize(width: 230, height: 48)) ?? NSImage(),
                                 target: nil, action: nil)
            badge.isBordered = false
            badge.toolTip = DashboardViewController.donationURL.absoluteString
            let controller = DonateWindowController(window: nil)
            badge.target = controller
            badge.action = #selector(openDonation)
            let stack = NSStackView(views: [text, badge])
            stack.orientation = .vertical
            stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
            stack.spacing = 16
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Donate"
            window.contentView = stack
            window.isReleasedWhenClosed = false
            controller.window = window
            window.center()
            shared = controller
        }
        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openDonation() { NSWorkspace.shared.open(DashboardViewController.donationURL) }
}


@MainActor
final class AboutWindowController: NSWindowController {
    private static var shared: AboutWindowController?
    private let thanksTo = NSButton(title: "", target: nil, action: nil)
    private var timer: Timer?
    private var environment = NSTextField(wrappingLabelWithString: "")

    static func show() {
        if shared == nil { shared = AboutWindowController() }
        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)
    }

    convenience init() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "About Git Extensions"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        let logo = NSImageView(image: AppKitFactory.resourceImage("GitExtensionsLogo256", size: NSSize(width: 128, height: 128)) ?? NSImage())
        let product = linkButton("Git Extensions", size: 22) { NSWorkspace.shared.open(DashboardViewController.developURL) }
        let copyright = NSTextField(labelWithString: "Proudly presented by Git Extensions team")
        environment.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        environment.isSelectable = true
        let copy = NSButton(image: AppKitFactory.resourceImage("CopyToClipboard", accessibilityDescription: "Copy environment info") ?? NSImage(),
                            target: self, action: #selector(copyEnvironment))
        copy.isBordered = false
        copy.toolTip = "Copy environment info"
        let environmentRow = NSStackView(views: [environment, copy])
        environmentRow.alignment = .top
        thanksTo.isBordered = false
        thanksTo.contentTintColor = .linkColor
        thanksTo.target = self
        thanksTo.action = #selector(showContributors)
        thanksTo.lineBreakMode = .byTruncatingTail
        let icons = linkButton("Some icons by Yusuke Kamiyamane (CCA3)", size: NSFont.systemFontSize) {
            NSWorkspace.shared.open(URL(string: "http://p.yusukekamiyamane.com/")!)
        }
        let involved = NSTextField(labelWithString: "Git Extensions is open source. Get involved!")
        let donate = NSButton(image: AppKitFactory.resourceImage("DonateBadge", size: NSSize(width: 150, height: 31)) ?? NSImage(),
                              target: self, action: #selector(donate))
        donate.isBordered = false
        let warranty = NSTextField(wrappingLabelWithString: "This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY of FITNESS FOR A PARTICULAR PURPOSE.")
        warranty.preferredMaxLayoutWidth = 420
        warranty.textColor = .secondaryLabelColor
        let details = NSStackView(views: [product, environmentRow, copyright, thanksTo, icons, involved, donate, warranty])
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 8
        thanksTo.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
        details.widthAnchor.constraint(equalToConstant: 420).isActive = true
        let content = NSStackView(views: [logo, details])
        content.alignment = .top
        content.spacing = 18
        content.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        window.contentView = content
        environment.stringValue = UserEnvironmentInformation.information(gitVersion: nil)
        Task { @MainActor [weak self] in self?.environment.stringValue = await UserEnvironmentInformation.information() }
        thankNextContributor()

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in AboutWindowController.shared?.thankNextContributor() }
        }
        window.center()
    }

    private func linkButton(_ title: String, size: CGFloat, action: @escaping () -> Void) -> NSButton {
        let button = DashboardLinkButton(title: title, image: nil)
        button.font = .systemFont(ofSize: size)
        button.colors = (.linkColor, .linkColor)
        button.callback = action
        return button
    }

    private func thankNextContributor() {
        let contributors = GitExtensionsContributors.all
        guard let name = contributors.randomElement() else { return }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let count = formatter.string(from: NSNumber(value: contributors.count)) ?? "\(contributors.count)"
        thanksTo.title = "Thanks to over \(count) contributors: \(name)"
    }

    @objc private func copyEnvironment() { Task { await UserEnvironmentInformation.copyInformation() } }
    @objc private func donate() { NSWorkspace.shared.open(DashboardViewController.donationURL) }
    @objc private func showContributors() { ContributorsWindowController.show() }
}


@MainActor
final class ContributorsWindowController: NSWindowController {
    private static var shared: ContributorsWindowController?

    static func show() {
        if shared == nil {
            let tabs = NSTabView()
            let pages = [
                ("Developers", "Team:\n\(GitExtensionsContributors.team)\n\nContributors:\n\(GitExtensionsContributors.coders)"),
                ("Translators", GitExtensionsContributors.translators),
                ("Designers", GitExtensionsContributors.designers)
            ]
            for (title, text) in pages {
                let item = NSTabViewItem(identifier: title)
                item.label = title
                let scroll = NSTextView.scrollableTextView()
                (scroll.documentView as? NSTextView)?.string = text
                (scroll.documentView as? NSTextView)?.isEditable = false
                item.view = scroll
                tabs.addTabViewItem(item)
            }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 624, height: 442), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "The application would not be possible without..."
            window.contentView = tabs
            window.isReleasedWhenClosed = false
            window.center()
            shared = ContributorsWindowController(window: window)
        }
        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)
    }
}
