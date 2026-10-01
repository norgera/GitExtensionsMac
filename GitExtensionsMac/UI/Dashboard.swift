import GitExtensionsCore
import GitCommands
import AppKit


@MainActor
struct DashboardTheme {
    let searchBack: NSColor
    let startBack: NSColor
    let contributeBack: NSColor
    let headerBack: NSColor
    let logoBack: NSColor
    let primaryText: NSColor
    let secondaryText: NSColor
    let accentedText: NSColor
    let secondaryHeadingText: NSColor
    let backgroundImage: String

    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }

    static let light = DashboardTheme(
        searchBack: rgb(248, 248, 255), startBack: rgb(219, 235, 248), contributeBack: rgb(230, 241, 250),
        headerBack: rgb(172, 208, 239), logoBack: rgb(19, 122, 212), primaryText: rgb(30, 30, 30),
        secondaryText: rgb(100, 127, 210), accentedText: rgb(184, 134, 11), secondaryHeadingText: rgb(105, 105, 105),
        backgroundImage: "DashboardBackgroundBlue")
    static let dark = DashboardTheme(
        searchBack: .controlBackgroundColor, startBack: .controlBackgroundColor, contributeBack: .underPageBackgroundColor,
        headerBack: .gridColor, logoBack: NSColor(white: 0.1, alpha: 1), primaryText: .labelColor,
        secondaryText: rgb(135, 206, 250), accentedText: rgb(218, 165, 32), secondaryHeadingText: .secondaryLabelColor,
        backgroundImage: "DashboardBackgroundGrey")

    static func current(for appearance: NSAppearance) -> DashboardTheme {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    }
}


@MainActor
final class DashboardViewController: NSViewController {
    var onOpenRepository: (() -> Void)?
    var onOpenRecentRepository: ((URL) -> Void)?
    var onCloneRepository: (() -> Void)?
    var onCloneHostedRepository: (() -> Void)?
    var onInitializeRepository: (() -> Void)?

    static let translateURL = URL(string: "https://github.com/gitextensions/gitextensions/wiki/Translations")!
    static let developURL = URL(string: "https://github.com/gitextensions/gitextensions")!
    static let issuesURL = URL(string: "https://github.com/gitextensions/gitextensions/issues")!
    static let donationURL = URL(string: "https://opencollective.com/gitextensions")!

    private let store: AppSettingsStore
    private let background = DashboardBackgroundView()
    private let logoPanel = DashboardColorView()
    private let startPanel = DashboardColorView()
    private let contributePanel = DashboardColorView()
    private let contributeLabel = NSTextField(labelWithString: "Contribute")
    private var links: [DashboardLinkButton] = []
    let repositoriesList: UserRepositoriesListViewController

    init(store: AppSettingsStore) {
        self.store = store
        repositoriesList = UserRepositoriesListViewController(store: store)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        background.onDrop = { [weak self] url in self?.repositoriesList.openDropped(url) }
        background.registerForDraggedTypes([.fileURL])
        let left = NSStackView()
        left.orientation = .vertical
        left.alignment = .width
        left.distribution = .fill
        left.spacing = 0
        left.translatesAutoresizingMaskIntoConstraints = false

        let logo = NSImageView(image: AppKitFactory.resourceImage("GitExtensionsLogoWide", accessibilityDescription: "Git Extensions",
                                                                  size: NSSize(width: 381, height: 100)) ?? NSImage())
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.translatesAutoresizingMaskIntoConstraints = false
        logoPanel.addSubview(logo)
        NSLayoutConstraint.activate([
            logoPanel.heightAnchor.constraint(equalToConstant: 68),
            logo.leadingAnchor.constraint(equalTo: logoPanel.leadingAnchor, constant: 20),
            logo.bottomAnchor.constraint(equalTo: logoPanel.bottomAnchor, constant: -14),
            logo.widthAnchor.constraint(equalToConstant: 185),
            logo.heightAnchor.constraint(equalToConstant: 44)
        ])

        let startStack = linkStack([
            link("Create new repository", image: "RepoCreate") { [weak self] in self?.onInitializeRepository?() },
            link("Open repository", image: "RepoOpen") { [weak self] in self?.onOpenRepository?() },
            link("Clone repository", image: "CloneRepoGit") { [weak self] in self?.onCloneRepository?() },

            link("Clone GitHub repository", image: "CloneRepoGitHub") { [weak self] in self?.onCloneHostedRepository?() }
        ])
        embed(startStack, in: startPanel, insets: NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20), pinBottom: false)

        contributeLabel.font = NSFont.systemFont(ofSize: store.applicationFont(size: 12).pointSize + 5.5)
        let contributeStack = linkStack([
            contributeLabel,
            link("Develop", image: "Develop", adapt: true) { NSWorkspace.shared.open(Self.developURL) },
            link("Donate", image: "DollarSign") { NSWorkspace.shared.open(Self.donationURL) },
            link("Translate", image: "Translate", adapt: true) { NSWorkspace.shared.open(Self.translateURL) },
            link("Issues", image: "DashboardBug") { UserEnvironmentInformation.copyInformationAndOpenIssues() }
        ])
        contributeStack.setCustomSpacing(12, after: contributeLabel)
        embed(contributeStack, in: contributePanel, insets: NSEdgeInsets(top: 20, left: 20, bottom: 30, right: 20), pinBottom: true)

        left.addArrangedSubview(logoPanel)
        left.addArrangedSubview(startPanel)
        left.addArrangedSubview(contributePanel)
        startPanel.setContentHuggingPriority(.defaultLow, for: .vertical)
        contributePanel.setContentHuggingPriority(.required, for: .vertical)

        addChild(repositoriesList)
        let right = repositoriesList.view
        right.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(left)
        background.addSubview(right)
        let leadingGuide = NSLayoutGuide()
        let trailingGuide = NSLayoutGuide()
        background.addLayoutGuide(leadingGuide)
        background.addLayoutGuide(trailingGuide)
        NSLayoutConstraint.activate([

            leadingGuide.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            leadingGuide.widthAnchor.constraint(equalTo: background.widthAnchor, multiplier: 0.0714),
            trailingGuide.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            trailingGuide.widthAnchor.constraint(equalTo: background.widthAnchor, multiplier: 0.0714),
            left.leadingAnchor.constraint(equalTo: leadingGuide.trailingAnchor),
            left.widthAnchor.constraint(equalToConstant: 213),
            left.topAnchor.constraint(equalTo: background.topAnchor),
            left.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            right.leadingAnchor.constraint(equalTo: left.trailingAnchor),
            right.trailingAnchor.constraint(equalTo: trailingGuide.leadingAnchor),
            right.topAnchor.constraint(equalTo: background.topAnchor),
            right.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            right.widthAnchor.constraint(greaterThanOrEqualToConstant: 450)
        ])
        repositoriesList.headerHeight = 68
        repositoriesList.onOpenRepository = { [weak self] url in self?.onOpenRecentRepository?(url) }
        view = background
        applyTheme()
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        repositoriesList.focusSearch()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let theme = DashboardTheme.current(for: view.effectiveAppearance)
        if theme.backgroundImage != background.imageName { applyTheme() }
    }


    func refreshContent() {
        applyTheme()
        repositoriesList.showRecentRepositories(reloadData: true)
    }

    func show(error: Error) { repositoriesList.show(error: error) }

    private func applyTheme() {
        let theme = DashboardTheme.current(for: view.effectiveAppearance)
        background.imageName = theme.backgroundImage
        logoPanel.color = theme.logoBack
        startPanel.color = theme.startBack
        contributePanel.color = theme.contributeBack
        contributeLabel.textColor = theme.secondaryHeadingText
        for link in links { link.colors = (theme.primaryText, theme.accentedText) }
        repositoriesList.apply(theme)
    }

    private func link(_ title: String, image: String, adapt: Bool = false, action: @escaping () -> Void) -> DashboardLinkButton {
        let button = DashboardLinkButton(title: title, image: AppKitFactory.resourceImage(image, accessibilityDescription: title, adaptLightness: adapt))
        button.font = store.applicationFont(size: 12)
        button.callback = action
        links.append(button)
        return button
    }

    private func linkStack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func embed(_ stack: NSStackView, in panel: NSView, insets: NSEdgeInsets, pinBottom: Bool) {
        panel.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: insets.left),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: panel.trailingAnchor, constant: -insets.right),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: insets.top),
            pinBottom ? stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -insets.bottom)
                : stack.bottomAnchor.constraint(lessThanOrEqualTo: panel.bottomAnchor, constant: -insets.bottom)
        ])
    }
}


final class DashboardBackgroundView: NSView {
    var imageName = "" { didSet { if oldValue != imageName { needsDisplay = true } } }
    var onDrop: ((URL) -> Void)?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = dirtyRect.intersection(bounds)
        NSColor.windowBackgroundColor.setFill()
        rect.fill()
        if let image = AppKitFactory.resourceImage(imageName, size: NSSize(width: 1240, height: 940)) {
            NSColor(patternImage: image).setFill()
            rect.fill()
        }
    }

    private static func directory(from info: NSDraggingInfo) -> URL? {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              urls.count == 1 else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: urls[0].path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return urls[0]
    }


    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.directory(from: sender) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = Self.directory(from: sender) else { return false }
        onDrop?(url)
        return true
    }
}

final class DashboardColorView: NSView {
    var color: NSColor = .clear { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {

        color.setFill()
        dirtyRect.intersection(bounds).fill(using: .sourceOver)
    }
}


final class DashboardLinkButton: NSButton {
    var callback: (() -> Void)?
    var colors: (normal: NSColor, hover: NSColor) = (.labelColor, .systemOrange) { didSet { updateTitle(hovered: false) } }
    private var trackingArea: NSTrackingArea?

    convenience init(title: String, image: NSImage?) {
        self.init(frame: .zero)
        self.title = title
        self.image = image
        imagePosition = image == nil ? .noImage : .imageLeading
        imageHugsTitle = true
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        action = #selector(invoke)
        updateTitle(hovered: false)
    }

    @objc private func invoke() { callback?() }

    private func updateTitle(hovered: Bool) {
        attributedTitle = NSAttributedString(string: " " + title, attributes: [
            .foregroundColor: hovered ? colors.hover : colors.normal,
            .font: font ?? NSFont.systemFont(ofSize: 12)
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { updateTitle(hovered: true) }
    override func mouseExited(with event: NSEvent) { updateTitle(hovered: false) }
}


@MainActor
final class UserRepositoriesListViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout, NSSearchFieldDelegate, NSMenuDelegate {
    struct Tile {
        let repository: RepositoryHistoryEntry
        let caption: String
        let isFavourite: Bool
        let isValid: Bool
    }

    struct Group {
        let title: String
        let isRecent: Bool
        var tiles: [Tile]
    }

    var onOpenRepository: ((URL) -> Void)?
    var headerHeight: CGFloat = 68 { didSet { headerHeightConstraint?.constant = headerHeight } }

    private let store: AppSettingsStore
    private let header = DashboardColorView()
    private let body = DashboardColorView()
    private let titleLabel = NSTextField(labelWithString: "Recent repositories")
    let searchField = NSSearchField()
    let collectionView = UserRepositoriesCollectionView()
    private let layout = NSCollectionViewFlowLayout()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var headerHeightConstraint: NSLayoutConstraint?
    private(set) var groups: [Group] = []
    private(set) var hasInvalidRepositories = false
    private var branchNames: [String: String] = [:]
    private var branchTask: Task<Void, Never>?
    private var theme = DashboardTheme.light
    private let repositoryMenu = NSMenu()
    private var contextTile: Tile?

    init(store: AppSettingsStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        titleLabel.font = NSFont.systemFont(ofSize: 18)
        searchField.placeholderString = "Search repositories..."
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)
        (searchField.cell as? NSSearchFieldCell)?.sendsWholeSearchString = false

        layout.itemSize = NSSize(width: 350, height: 50)
        layout.minimumInteritemSpacing = 4
        layout.minimumLineSpacing = 4
        layout.headerReferenceSize = NSSize(width: 100, height: 30)
        layout.sectionInset = NSEdgeInsets(top: 2, left: 0, bottom: 10, right: 0)
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(DashboardRepositoryItem.self, forItemWithIdentifier: DashboardRepositoryItem.identifier)
        collectionView.register(DashboardGroupHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                                withIdentifier: DashboardGroupHeader.identifier)
        collectionView.owner = self
        repositoryMenu.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = collectionView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        for view in [titleLabel, searchField, errorLabel] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false }
        header.translatesAutoresizingMaskIntoConstraints = false
        body.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titleLabel)
        body.addSubview(searchField)
        body.addSubview(scroll)
        body.addSubview(errorLabel)
        root.addSubview(header)
        root.addSubview(body)
        let headerHeightConstraint = header.heightAnchor.constraint(equalToConstant: headerHeight)
        self.headerHeightConstraint = headerHeightConstraint
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            headerHeightConstraint,
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
            titleLabel.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -11),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.topAnchor.constraint(equalTo: header.bottomAnchor),
            body.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            searchField.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 20),
            searchField.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -20),
            searchField.topAnchor.constraint(equalTo: body.topAnchor, constant: 18),
            scroll.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            errorLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            errorLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 4),
            errorLabel.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -3)
        ])
        view = root
        showRecentRepositories(reloadData: true)
    }

    override func viewDidLayout() {
        super.viewDidLayout()

        let size = tileSize()
        if layout.itemSize != size {
            layout.itemSize = size
            layout.invalidateLayout()
        }
    }

    func apply(_ theme: DashboardTheme) {
        self.theme = theme
        header.color = theme.headerBack
        body.color = .textBackgroundColor
        titleLabel.textColor = theme.secondaryHeadingText
        collectionView.reloadData()
    }

    func focusSearch() {

        if !searchField.stringValue.isEmpty {
            searchField.stringValue = ""
            showRecentRepositories(reloadData: false)
        }
        view.window?.makeFirstResponder(searchField)
    }

    func show(error: Error) {
        errorLabel.stringValue = error.localizedDescription
        errorLabel.isHidden = false
    }


    func showRecentRepositories(reloadData: Bool) {
        if reloadData {
            branchNames.removeAll()
            RepositoryCurrentBranchNameCache.shared.invalidateAll()
        }
        let settings = store.recentRepositorySettings
        let pattern = searchField.stringValue
        func filter(_ repositories: [RepositoryHistoryEntry]) -> [RepositoryHistoryEntry] {
            pattern.isEmpty ? repositories : repositories.filter { $0.path.localizedCaseInsensitiveContains(pattern) }
        }
        let font = store.applicationFont(size: 12)
        let splitter = RecentRepoSplitter(settings: settings) { ($0 as NSString).size(withAttributes: [.font: font]).width }
        func union(_ split: (top: [RecentRepoInfo], recent: [RecentRepoInfo])) -> [RecentRepoInfo] {
            var seen = Set<ObjectIdentifier>()
            return (split.top + split.recent).filter { seen.insert(ObjectIdentifier($0)).inserted }
        }
        let recent = union(splitter.split(filter(store.recentRepositories)))
        let favourites = union(splitter.split(filter(store.favouriteRepositories)))
        hasInvalidRepositories = false
        func tile(_ info: RecentRepoInfo, favourite: Bool) -> Tile {
            let valid = RepositoryHistory.isValidGitWorkingDir(info.repo.path)
            if !valid { hasInvalidRepositories = true }
            return Tile(repository: info.repo, caption: info.caption ?? info.repo.path, isFavourite: favourite, isValid: valid)
        }
        var groups = [Group(title: "Recent repositories", isRecent: true, tiles: recent.map { tile($0, favourite: false) })]
        var categories: [String] = []
        for info in recent + favourites {
            guard let category = info.repo.category, !category.trimmingCharacters(in: .whitespaces).isEmpty,
                  !categories.contains(category) else { continue }
            categories.append(category)
        }
        for category in categories.sorted(by: { $0.compare($1, locale: .current) == .orderedAscending }) {
            groups.append(Group(title: category, isRecent: false,
                                tiles: favourites.filter { $0.repo.category == category }.map { tile($0, favourite: true) }))
        }

        self.groups = groups.filter { !$0.tiles.isEmpty }
        layout.itemSize = tileSize()
        collectionView.reloadData()
        loadBranchNames()
    }

    private func loadBranchNames() {
        branchTask?.cancel()
        let paths = groups.flatMap(\.tiles).filter(\.isValid).map(\.repository.path)
        branchTask = Task { @MainActor [weak self] in
            for path in paths where self?.branchNames[path] == nil {
                guard !Task.isCancelled else { return }
                let name = RepositoryHistory.isBareRepository(path) || !AppSettingsStore.shared.recentRepositorySettings.showCurrentBranch
                    ? "" : await RepositoryCurrentBranchNameCache.shared.updatedBranchName(path)
                guard !Task.isCancelled, let self else { return }
                self.branchNames[path] = name
                for indexPath in self.indexPaths(for: path) {
                    (self.collectionView.item(at: indexPath) as? DashboardRepositoryItem)?.branch = name
                }
            }
            RepositoryHistoryUIService.shared.reload()
        }
    }

    private func indexPaths(for path: String) -> [IndexPath] {
        groups.enumerated().flatMap { section, group in
            group.tiles.enumerated().filter { $0.element.repository.path == path }.map { IndexPath(item: $0.offset, section: section) }
        }
    }


    private func tileSize() -> NSSize {
        let captions = groups.flatMap(\.tiles).map(\.caption)
        guard !captions.isEmpty else { return NSSize(width: 350, height: 50) }
        let font = store.applicationFont(size: 12)
        let secondary = NSFont.systemFont(ofSize: font.pointSize - 1)
        let longest = captions.map { ($0 as NSString).size(withAttributes: [.font: font]) }.max { $0.width < $1.width }!
        let branchHeight = ("A" as NSString).size(withAttributes: [.font: secondary]).height
        let configured = CGFloat(store.recentRepositorySettings.comboMinWidth)
        let width = configured < 1 ? longest.width + 32 : configured
        let height = longest.height + 2 * branchHeight + 4 + 2
        let available = max(200, collectionView.enclosingScrollView?.contentSize.width ?? 400)
        return NSSize(width: min(width + 50, available), height: max(height, 50))
    }

    func tile(at indexPath: IndexPath) -> Tile? {
        guard indexPath.section < groups.count, indexPath.item < groups[indexPath.section].tiles.count else { return nil }
        return groups[indexPath.section].tiles[indexPath.item]
    }

    var selectedTile: Tile? { collectionView.selectionIndexPaths.first.flatMap(tile(at:)) }



    func numberOfSections(in collectionView: NSCollectionView) -> Int { groups.count }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { groups[section].tiles.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: DashboardRepositoryItem.identifier, for: indexPath)
        if let item = item as? DashboardRepositoryItem, let tile = tile(at: indexPath) {
            item.configure(tile, branch: branchNames[tile.repository.path], theme: theme, font: store.applicationFont(size: 12))
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: DashboardGroupHeader.identifier, for: indexPath)
        if let header = header as? DashboardGroupHeader, indexPath.section < groups.count {
            let group = groups[indexPath.section]
            header.configure(title: group.title, color: theme.secondaryHeadingText) { [weak self, weak header] in
                guard let self, let header else { return }
                self.showCategoryMenu(for: indexPath.section, from: header)
            }
        }
        return header
    }

    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
                        referenceSizeForHeaderInSection section: Int) -> NSSize {
        NSSize(width: collectionView.bounds.width, height: 30)
    }



    @objc private func searchChanged() { showRecentRepositories(reloadData: false) }

    func controlTextDidChange(_ obj: Notification) { showRecentRepositories(reloadData: false) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):

            if let first = groups.first?.tiles.first { tryOpenRepository(first) }
            return true
        case #selector(NSResponder.moveDown(_:)):
            focusList()
            return true
        default:
            return false
        }
    }


    func focusList() {
        view.window?.makeFirstResponder(collectionView)
        if collectionView.selectionIndexPaths.isEmpty, !groups.isEmpty {
            let first = IndexPath(item: 0, section: 0)
            collectionView.selectionIndexPaths = [first]
            collectionView.scrollToItems(at: [first], scrollPosition: .nearestHorizontalEdge)
        }
    }


    func moveUpFromTopRow() -> Bool {
        guard let selected = collectionView.selectionIndexPaths.first,
              let frame = collectionView.layoutAttributesForItem(at: selected)?.frame,
              let firstFrame = collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame,
              frame.minY == firstFrame.minY else { return false }
        view.window?.makeFirstResponder(searchField)
        return true
    }




    func tryOpenRepository(_ tile: Tile) {
        if RepositoryHistory.isValidGitWorkingDir(tile.repository.path) {
            onOpenRepository?(URL(fileURLWithPath: tile.repository.path, isDirectory: true))
            return
        }
        InvalidRepositoryRemover.showDeleteInvalidRepositoryDialog(tile.repository.path, owner: view.window) { [weak self] removed in
            if removed { self?.showRecentRepositories(reloadData: true) }
        }
    }


    func openDropped(_ url: URL) {
        guard RepositoryHistory.isValidGitWorkingDir(url.path) else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Cannot open the folder"
            alert.informativeText = InvalidRepositoryRemover.directoryInvalidRepository
            if let window = view.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            return
        }
        onOpenRepository?(URL(fileURLWithPath: RepositoryHistory.normalizedPath(url.path), isDirectory: true))
    }



    func contextMenu(for indexPath: IndexPath) -> NSMenu? {
        guard let tile = tile(at: indexPath) else { return nil }
        collectionView.selectionIndexPaths = [indexPath]
        contextTile = tile
        repositoryMenu.removeAllItems()
        func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }
        repositoryMenu.addItem(item("Show in Finder", #selector(showInFinder)))
        repositoryMenu.addItem(.separator())
        let categories = NSMenuItem(title: "Categories", action: nil, keyEquivalent: "")
        categories.submenu = categoriesMenu(for: tile)
        repositoryMenu.addItem(categories)
        repositoryMenu.addItem(.separator())
        repositoryMenu.addItem(item("Remove project from the list", #selector(removeFromList)))
        if hasInvalidRepositories { repositoryMenu.addItem(item("Remove missing projects from the list", #selector(removeMissingFromList))) }
        return repositoryMenu
    }

    func menuDidClose(_ menu: NSMenu) {

        DispatchQueue.main.async { [weak self] in
            self?.contextTile = nil
            self?.showRecentRepositories(reloadData: false)
        }
    }


    private var categories: [String] {
        var result: [String] = []
        for tile in groups.flatMap(\.tiles) {
            guard let category = tile.repository.category, !category.trimmingCharacters(in: .whitespaces).isEmpty,
                  !result.contains(category) else { continue }
            result.append(category)
        }
        return result.sorted { $0.compare($1, locale: .current) == .orderedAscending }
    }


    private func categoriesMenu(for tile: Tile) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let categories = categories
        if !categories.isEmpty {
            let none = NSMenuItem(title: "(none)", action: #selector(assignCategory(_:)), keyEquivalent: "")
            none.target = self
            none.isEnabled = !(tile.repository.category?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
            menu.addItem(none)
            for category in categories {
                let item = NSMenuItem(title: category, action: #selector(assignCategory(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = category
                item.isEnabled = category != tile.repository.category
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        let add = NSMenuItem(title: "Add new...", action: #selector(addCategory), keyEquivalent: "")
        add.target = self
        menu.addItem(add)
        return menu
    }

    @objc private func showInFinder() {
        guard let tile = contextTile ?? selectedTile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: tile.repository.path, isDirectory: true)])
    }

    @objc private func assignCategory(_ sender: NSMenuItem) {
        guard let tile = contextTile ?? selectedTile else { return }
        store.assignCategory(tile.repository, category: sender.representedObject as? String)
        showRecentRepositories(reloadData: true)
    }

    @objc private func addCategory() {
        guard let tile = contextTile ?? selectedTile, let window = view.window else { return }
        DashboardCategoryTitleDialog.prompt(existing: categories, originalName: nil, owner: window) { [weak self] name in
            guard let self, let name else { return }
            self.store.assignCategory(tile.repository, category: name)
            self.showRecentRepositories(reloadData: true)
        }
    }

    @objc private func removeFromList() {
        guard let tile = contextTile ?? selectedTile else { return }
        if tile.isFavourite { store.removeFavouriteRepository(path: tile.repository.path) }
        else { store.removeRecentRepository(path: tile.repository.path) }
        showRecentRepositories(reloadData: true)
    }

    @objc private func removeMissingFromList() {
        store.removeInvalidRepositories()
        showRecentRepositories(reloadData: true)
    }



    private func showCategoryMenu(for section: Int, from view: NSView) {
        guard section < groups.count else { return }
        let group = groups[section]
        let menu = NSMenu()
        func add(_ title: String, _ handler: @escaping () -> Void) {
            let item = DashboardClosureMenuItem(title: title, handler: handler)
            menu.addItem(item)
        }
        if group.isRecent {
            add("Clear all recent repositories") { [weak self] in self?.clearRecent() }
        } else {
            add("Rename category") { [weak self] in self?.renameCategory(group.title) }
            add("Delete category") { [weak self] in self?.deleteCategory(group.title, count: group.tiles.count) }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.maxX - 60, y: view.bounds.maxY), in: view)
    }

    private func confirm(_ question: String, caption: String, completion: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = caption
        alert.informativeText = question
        alert.addButton(withTitle: "No")
        alert.addButton(withTitle: "Yes")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        let handler: (NSApplication.ModalResponse) -> Void = { if $0 == .alertSecondButtonReturn { completion() } }
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: handler) } else { handler(alert.runModal()) }
    }

    private func updateCategoryName(_ original: String, to name: String?) {
        for tile in groups.flatMap(\.tiles) where tile.repository.category == original {
            store.assignCategory(tile.repository, category: name)
        }
        showRecentRepositories(reloadData: true)
    }

    private func renameCategory(_ original: String) {
        guard let window = view.window else { return }
        DashboardCategoryTitleDialog.prompt(existing: categories.filter { $0 != original }, originalName: original, owner: window) { [weak self] name in
            guard let name else { return }
            self?.updateCategoryName(original, to: name)
        }
    }

    private func deleteCategory(_ name: String, count: Int) {
        confirm("Do you want to delete category \"\(name)\" with \(count) repositories?\n\nThe action cannot be undone.",
                caption: "Delete Category") { [weak self] in self?.updateCategoryName(name, to: nil) }
    }

    private func clearRecent() {
        let repositories = groups.flatMap(\.tiles).map(\.repository)
        confirm("Do you want to clear the list of recent repositories?\n\nThe action cannot be undone.",
                caption: "Clear recent repositories") { [weak self] in
            guard let self else { return }
            var history = store.recentRepositories
            for repository in repositories { history = RepositoryHistory.remove(repository.path, from: history) }
            store.saveRecentHistory(history)
            showRecentRepositories(reloadData: true)
        }
    }
}


final class UserRepositoriesCollectionView: NSCollectionView {
    weak var owner: UserRepositoriesListViewController?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, selectionIndexPaths.isEmpty, numberOfSections > 0, numberOfItems(inSection: 0) > 0 {
            selectionIndexPaths = [IndexPath(item: 0, section: 0)]
        }
        return result
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:
            if let tile = owner?.selectedTile { owner?.tryOpenRepository(tile) }
        case 126:
            if owner?.moveUpFromTopRow() != true { super.keyDown(with: event) }
        default:
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)

        let point = convert(event.locationInWindow, from: nil)
        guard event.clickCount == 1, let indexPath = indexPathForItem(at: point), let tile = owner?.tile(at: indexPath) else { return }
        owner?.tryOpenRepository(tile)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else { return nil }
        return owner?.contextMenu(for: indexPath)
    }
}

final class DashboardClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func invoke() { handler() }
}


final class DashboardGroupHeader: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("DashboardGroupHeader")
    private let label = NSTextField(labelWithString: "")
    private let actions = NSButton(title: "Actions", target: nil, action: nil)
    private let line = NSBox()
    private var handler: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = NSFont.systemFont(ofSize: NSFont.systemFontSize + 1)
        actions.isBordered = false
        actions.contentTintColor = .linkColor
        actions.target = self
        actions.action = #selector(invoke)
        line.boxType = .separator
        for view in [label, actions, line] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            line.trailingAnchor.constraint(equalTo: actions.leadingAnchor, constant: -8),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(title: String, color: NSColor, handler: @escaping () -> Void) {
        label.stringValue = title
        label.textColor = color
        self.handler = handler
    }

    @objc private func invoke() { handler?() }
}


final class DashboardRepositoryItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("DashboardRepositoryItem")
    private let tileView = DashboardTileView()

    override func loadView() { view = tileView }

    var branch: String? {
        get { tileView.branch }
        set { tileView.branch = newValue ?? "" }
    }

    override var isSelected: Bool { didSet { tileView.isSelectedTile = isSelected } }

    @MainActor
    func configure(_ tile: UserRepositoriesListViewController.Tile, branch: String?, theme: DashboardTheme, font: NSFont) {
        tileView.caption = tile.caption
        tileView.branch = tile.isValid ? branch ?? "" : ""
        tileView.icon = AppKitFactory.resourceImage(tile.isValid ? "DashboardFolderGit" : "DashboardFolderError",
                                                    size: NSSize(width: 32, height: 32))
        tileView.star = tile.repository.category?.trimmingCharacters(in: .whitespaces).isEmpty == false
            ? AppKitFactory.resourceImage("Star", size: NSSize(width: 16, height: 16)) : nil
        tileView.theme = theme
        tileView.font = font
        tileView.toolTip = tile.repository.path
        tileView.setAccessibilityLabel(tile.caption)
        tileView.needsDisplay = true
    }
}

final class DashboardTileView: NSView {
    var caption = ""
    var branch = "" { didSet { needsDisplay = true } }
    var icon: NSImage?
    var star: NSImage?
    var theme = DashboardTheme.light
    var font = NSFont.systemFont(ofSize: 12)
    var isSelectedTile = false { didSet { needsDisplay = true } }
    private var hovered = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func draw(_ dirtyRect: NSRect) {
        if hovered || isSelectedTile {
            theme.startBack.setFill()
            bounds.fill()
        }
        let imagePoint = NSPoint(x: 4, y: 8)
        icon?.draw(in: NSRect(origin: imagePoint, size: NSSize(width: 32, height: 32)))
        star?.draw(in: NSRect(x: imagePoint.x + 32 - 12, y: 2, width: 16, height: 16))
        let textX: CGFloat = 4 + 2 + 32 + 2 + 4
        let width = bounds.width - textX - 8
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let captionAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: theme.primaryText, .paragraphStyle: paragraph]
        let captionHeight = (caption as NSString).size(withAttributes: captionAttributes).height
        (caption as NSString).draw(in: NSRect(x: textX, y: 6, width: width, height: captionHeight), withAttributes: captionAttributes)
        guard !branch.isEmpty else { return }
        let secondary = NSFont.systemFont(ofSize: font.pointSize - 1)
        let branchAttributes: [NSAttributedString.Key: Any] = [.font: secondary, .foregroundColor: theme.secondaryText, .paragraphStyle: paragraph]
        let branchHeight = (branch as NSString).size(withAttributes: branchAttributes).height
        (branch as NSString).draw(in: NSRect(x: textX, y: 6 + captionHeight + 1, width: width, height: branchHeight), withAttributes: branchAttributes)
    }
}


@MainActor
final class DashboardCategoryTitleDialog: NSViewController, NSTextFieldDelegate {
    private let field = NSTextField()
    private let okButton = NSButton(title: "OK", target: nil, action: nil)
    private let existing: [String]
    private let originalName: String?
    private var completion: ((String?) -> Void)?

    static func prompt(existing: [String], originalName: String?, owner: NSWindow, completion: @escaping (String?) -> Void) {
        let controller = DashboardCategoryTitleDialog(existing: existing, originalName: originalName)
        controller.completion = completion
        let panel = NSPanel(contentViewController: controller)
        panel.title = originalName == nil ? "Enter Caption" : "Rename category"
        panel.styleMask = [.titled]
        owner.beginSheet(panel)
    }

    init(existing: [String], originalName: String?) {
        self.existing = existing
        self.originalName = originalName
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let label = NSTextField(labelWithString: "Category name")
        field.stringValue = originalName ?? ""
        field.delegate = self
        okButton.target = self
        okButton.action = #selector(ok)
        okButton.keyEquivalent = "\r"
        okButton.isEnabled = field.stringValue != (originalName ?? "") || originalName == nil
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancel, okButton])
        let stack = NSStackView(views: [label, field, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        field.widthAnchor.constraint(equalToConstant: 280).isActive = true
        buttons.trailingAnchor.constraint(equalTo: field.trailingAnchor).isActive = true
        view = stack
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
        field.selectText(nil)
    }


    func controlTextDidChange(_ obj: Notification) {
        okButton.isEnabled = field.stringValue != (originalName ?? "") || originalName == nil
    }


    @objc private func ok() {
        let name = field.stringValue
        let error = name.isEmpty ? "Category name is required" : existing.contains(name) ? "Category name already exists" : nil
        if let error, let window = view.window {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Category name"
            alert.informativeText = error
            alert.beginSheetModal(for: window)
            return
        }
        close(with: name)
    }

    @objc private func cancel() { close(with: nil) }

    private func close(with name: String?) {
        guard let window = view.window else { return }
        window.sheetParent?.endSheet(window)
        let completion = completion
        self.completion = nil
        completion?(name)
    }
}


@MainActor
enum UserEnvironmentInformation {
    static func information(gitVersion: String?) -> String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "(development)"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "(development)"
        let scale = NSScreen.main?.backingScaleFactor ?? 1
        return """
        - Git Extensions \(version) (macOS)
        - Build \(build)
        - Git \(gitVersionInfo(gitVersion))
        - \(ProcessInfo.processInfo.operatingSystemVersionString)
        - \(machineArchitecture())
        - Display scale \(scale == 1 ? "no" : "\(Int(scale * 100))%") scaling

        """
    }

    static func information() async -> String { information(gitVersion: await gitVersion()) }


    static func copyInformation() async {
        let text = await information()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }


    static func copyInformationAndOpenIssues() {
        Task { @MainActor in
            await copyInformation()
            NSWorkspace.shared.open(DashboardViewController.issuesURL)
        }
    }

    static let lastSupportedVersion = "2.43.0"
    static let lastRecommendedVersion = "2.53.0"


    static func gitVersionInfo(_ version: String?) -> String {
        guard let version, !version.isEmpty else {
            return "- (minimum: \(lastSupportedVersion), recommended: \(lastRecommendedVersion))"
        }
        if version.compare(lastSupportedVersion, options: .numeric) == .orderedAscending {
            return "\(version) (minimum: \(lastSupportedVersion), please update!)"
        }
        if version.compare(lastRecommendedVersion, options: .numeric) == .orderedAscending {
            return "\(version) (recommended: \(lastRecommendedVersion) or later)"
        }
        return version
    }

    private static var cachedGitVersion: String?


    static func gitVersion() async -> String? {
        if let cachedGitVersion { return cachedGitVersion }
        let git = GitProcess(executableURL: URL(fileURLWithPath: AppSettingsStore.shared.preferences.gitExecutablePath))
        let command = GitCommand(arguments: ["--version"], accessesRemote: false, changesRepositoryState: false)
        guard let result = try? await git.run(command, in: FileManager.default.homeDirectoryForCurrentUser), result.succeeded else { return nil }
        let version = result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").dropFirst(2).first.map(String.init)
        cachedGitVersion = version
        return version
    }

    private static func machineArchitecture() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
