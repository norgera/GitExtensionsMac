import AppKit
import GitCommands
import GitExtensionsCore

@MainActor
final class ImpactLoader {
    var onCommitsLoaded: (([ImpactCommit]) -> Void)?
    var onExited: (() -> Void)?
    var onError: ((Error) -> Void)?

    let respectMailmap: Bool
    private let source: any RepositoryImpactDataSource
    private let firstDayOfWeek: Int
    private var cache: [String: [ImpactCommit]] = [:]
    private var mainLoad: Task<Void, Never>?
    private var current: Task<Void, Never>?
    private var generation = 0
    private var disposed = false
    private(set) var executedLoads = 0

    var showSubmodules = false {
        didSet { stop() }
    }

    init(source: any RepositoryImpactDataSource, respectMailmap: Bool, firstDayOfWeek: Int = ImpactLog.currentFirstDayOfWeek) {
        self.source = source
        self.respectMailmap = respectMailmap
        self.firstDayOfWeek = firstDayOfWeek
        mainLoad = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = try? await self.load(nil)
        }
    }

    func dispose() {
        disposed = true
        mainLoad?.cancel()
        stop()
    }

    func stop() {
        generation += 1
        current?.cancel()
        current = nil
    }

    func execute() {
        guard !disposed else { return }
        stop()
        let token = generation
        let includeSubmodules = showSubmodules
        current = Task { @MainActor [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor in
                    await self.mainLoad?.value
                    await self.loadModule(nil, token: token)
                }
                if includeSubmodules {
                    do {
                        for path in try await self.source.impactSubmodulePaths() {
                            group.addTask { @MainActor in await self.loadModule(path, token: token) }
                        }
                    } catch {
                        if !(error is CancellationError), token == self.generation { self.onError?(error) }
                    }
                }
            }
            guard token == self.generation, !Task.isCancelled else { return }
            self.onExited?()
        }
    }

    private func load(_ path: String?) async throws -> [ImpactCommit] {
        let key = path ?? ""
        if let cached = cache[key] { return cached }
        executedLoads += 1
        let commits = try await source.impactCommits(submodulePath: path, respectMailmap: respectMailmap, firstDayOfWeek: firstDayOfWeek)
        try Task.checkCancellation()
        cache[key] = commits
        return commits
    }

    private func loadModule(_ path: String?, token: Int) async {
        do {
            let commits = try await load(path)
            guard token == generation, !Task.isCancelled else { return }
            onCommitsLoaded?(commits)
        } catch is CancellationError {
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            onError?(error)
        }
    }
}

struct ImpactGraphModel {
    static let blockWidth: CGFloat = 60
    static let transitionWidth: CGFloat = 50
    static let linesFontSize: CGFloat = 10

    struct WeekData {
        var order: [String] = []
        var values: [String: ImpactDataPoint] = [:]

        mutating func add(_ author: String, _ data: ImpactDataPoint) {
            if let existing = values[author] {
                values[author] = existing + data
            } else {
                order.append(author)
                values[author] = data
            }
        }

        var byChangedLines: [(String, ImpactDataPoint)] {
            order.enumerated().sorted { lhs, rhs in
                let left = values[lhs.element]!.changedLines, right = values[rhs.element]!.changedLines
                return left != right ? left > right : lhs.offset < rhs.offset
            }.map { ($0.element, values[$0.element]!) }
        }
    }

    struct Block: Equatable {
        var rect: CGRect
        var changeCount: Int
    }

    struct Layout {
        var blocks: [String: [Block]] = [:]
        var weekLabels: [(point: CGPoint, week: ImpactWeek)] = []
        var lineLabels: [String: [(center: CGPoint, text: String)]] = [:]
        var width: CGFloat = 0
    }

    private(set) var authors: [String: ImpactDataPoint] = [:]
    private(set) var authorOrder: [String] = []
    private(set) var impact: [ImpactWeek: WeekData] = [:]
    private(set) var authorStack: [String] = []

    var weeks: [ImpactWeek] { impact.keys.sorted() }
    var isEmpty: Bool { impact.isEmpty }

    mutating func clear() {
        authors = [:]; authorOrder = []; impact = [:]; authorStack = []
    }

    mutating func add(_ commits: [ImpactCommit]) {
        for commit in commits {
            impact[commit.week, default: WeekData()].add(commit.author, commit.data)
            if let existing = authors[commit.author] {
                authors[commit.author] = existing + commit.data
            } else {
                authors[commit.author] = commit.data
                authorOrder.append(commit.author)
            }
            if !authorStack.contains(commit.author) { authorStack.insert(commit.author, at: 0) }
        }
        Self.addIntermediateEmptyWeeks(&impact, authors: authorOrder)
    }

    static func addIntermediateEmptyWeeks(_ impact: inout [ImpactWeek: WeekData], authors: [String]) {
        let weeks = impact.keys.sorted()
        for author in authors {
            guard let start = weeks.first(where: { impact[$0]!.values[author] != nil }),
                  let end = weeks.last(where: { impact[$0]!.values[author] != nil }) else { continue }
            for week in weeks where week > start && week < end && impact[week]!.values[author] == nil {
                impact[week]!.add(author, .zero)
            }
        }
    }

    func authorInfo(_ author: String) -> ImpactDataPoint { authors[author] ?? .zero }

    static func blockHeight(changedLines: Int) -> Int {
        let changed = Double(max(1, changedLines))
        return max(1, Int((pow(log(changed), 1.5) * 4).rounded(.toNearestOrEven)))
    }

    func layout(height: CGFloat) -> Layout {
        var result = Layout()
        var unscaled: [String: [Block]] = [:]
        var weekLabels: [(CGPoint, ImpactWeek)] = []
        var maximum = 0
        var x: CGFloat = 0
        for week in weeks {
            var y = 0
            for (author, data) in impact[week]!.byChangedLines {
                let blockHeight = Self.blockHeight(changedLines: data.changedLines)
                unscaled[author, default: []].append(Block(rect: CGRect(x: x, y: CGFloat(y), width: Self.blockWidth, height: CGFloat(blockHeight)),
                                                           changeCount: data.changedLines))
                y += blockHeight + 2
            }
            maximum = max(maximum, y)
            weekLabels.append((CGPoint(x: x + Self.blockWidth / 2, y: CGFloat(y)), week))
            x += Self.blockWidth + Self.transitionWidth
        }
        result.width = max(0, x - Self.transitionWidth)
        let factor = maximum > 0 ? 0.9 * Double(height) / Double(maximum) : 1
        result.weekLabels = weekLabels.map { (CGPoint(x: $0.0.x, y: CGFloat(Double($0.0.y) * factor)), $0.1) }
        for (author, blocks) in unscaled {
            let scaled = blocks.map { block in
                Block(rect: CGRect(x: block.rect.minX, y: CGFloat(Int(Double(block.rect.minY) * factor)), width: block.rect.width,
                                   height: CGFloat(max(1, Int(Double(block.rect.height) * factor)))), changeCount: block.changeCount)
            }
            result.blocks[author] = scaled
            result.lineLabels[author] = scaled.filter { $0.rect.height > Self.linesFontSize * 1.5 }
                .map { (CGPoint(x: $0.rect.minX + Self.blockWidth / 2, y: $0.rect.minY + CGFloat(Int($0.rect.height) / 2)), String($0.changeCount)) }
        }
        return result
    }

    static func path(for blocks: [Block]) -> NSBezierPath? {
        guard let first = blocks.first, let last = blocks.last else { return nil }
        let half = transitionWidth / 2
        let path = NSBezierPath()
        path.windingRule = .evenOdd
        path.move(to: CGPoint(x: first.rect.minX, y: first.rect.maxY))
        path.line(to: CGPoint(x: first.rect.minX, y: first.rect.minY))
        for (index, block) in blocks.enumerated() {
            let rect = block.rect
            path.line(to: CGPoint(x: rect.minX, y: rect.minY))
            path.line(to: CGPoint(x: rect.maxX, y: rect.minY))
            if index < blocks.count - 1 {
                let next = blocks[index + 1].rect
                path.curve(to: CGPoint(x: next.minX, y: next.minY), controlPoint1: CGPoint(x: rect.maxX + half, y: rect.minY),
                           controlPoint2: CGPoint(x: rect.maxX + half, y: next.minY))
            }
        }
        path.line(to: CGPoint(x: last.rect.maxX, y: last.rect.minY))
        path.line(to: CGPoint(x: last.rect.maxX, y: last.rect.maxY))
        for index in stride(from: blocks.count - 1, through: 0, by: -1) {
            let rect = blocks[index].rect
            path.line(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.line(to: CGPoint(x: rect.minX, y: rect.maxY))
            if index > 0 {
                let previous = blocks[index - 1].rect
                path.curve(to: CGPoint(x: previous.maxX, y: previous.maxY), controlPoint1: CGPoint(x: rect.minX - half, y: rect.maxY),
                           controlPoint2: CGPoint(x: rect.minX - half, y: previous.maxY))
            }
        }
        path.close()
        return path
    }

    static func color(for author: String, dark: Bool) -> NSColor {
        var hash: UInt32 = 2_166_136_261
        for unit in author.utf16 { hash = (hash ^ UInt32(unit)) &* 16_777_619 }
        let red = CGFloat((hash >> 16) & 0xFF) / 255, green = CGFloat((hash >> 8) & 0xFF) / 255, blue = CGFloat(hash & 0xFF) / 255
        let color = NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        return dark ? color.blended(withFraction: 0.35, of: .black) ?? color : color
    }
}

@MainActor
final class ImpactGraphView: NSView {
    private(set) var model = ImpactGraphModel()
    private(set) var layout = ImpactGraphModel.Layout()
    private(set) var paths: [String: NSBezierPath] = [:]
    private(set) var selectedAuthor = ""
    var onSelectedAuthorChanged: (() -> Void)?
    var viewportHeight: CGFloat = 400 { didSet { if oldValue != viewportHeight { rebuild() } } }
    override var isFlipped: Bool { true }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    func clear() {
        model.clear()
        rebuild()
    }

    func add(_ commits: [ImpactCommit]) {
        model.add(commits)
        rebuild()
    }

    func color(for author: String) -> NSColor { ImpactGraphModel.color(for: author, dark: isDark) }

    private func rebuild() {
        layout = model.layout(height: viewportHeight)
        paths = layout.blocks.compactMapValues(ImpactGraphModel.path(for:))
        let scroll = enclosingScrollView
        let visibleWidth = scroll?.contentView.bounds.width ?? bounds.width
        let rightOffset = max(0, frame.width - ((scroll?.contentView.bounds.maxX) ?? frame.width))
        setFrameSize(NSSize(width: max(layout.width, visibleWidth), height: viewportHeight))
        if let scroll {
            let x = max(0, frame.width - visibleWidth - rightOffset)
            scroll.contentView.scroll(to: NSPoint(x: x, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }

    @discardableResult
    func selectAuthor(at point: NSPoint) -> Bool {
        for author in model.authorStack.reversed() {
            guard let path = paths[author], path.contains(point) else { continue }
            guard author != selectedAuthor else { return false }
            selectedAuthor = author
            needsDisplay = true
            onSelectedAuthorChanged?()
            return true
        }
        return false
    }

    override func mouseMoved(with event: NSEvent) {
        selectAuthor(at: convert(event.locationInWindow, from: nil))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let scroll = enclosingScrollView, abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 12)
        let maximum = max(0, frame.width - scroll.contentView.bounds.width)
        scroll.contentView.scroll(to: NSPoint(x: min(maximum, max(0, scroll.contentView.bounds.minX + delta)), y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        guard !model.isEmpty else { return }
        for author in model.authorStack where author != selectedAuthor {
            color(for: author).setFill()
            paths[author]?.fill()
        }
        if let selected = paths[selectedAuthor] {
            color(for: selectedAuthor).setFill()
            selected.fill()
            NSColor.textColor.setStroke()
            selected.lineWidth = 2
            selected.stroke()
        }
        let linesFont = NSFont(name: "Arial", size: ImpactGraphModel.linesFontSize) ?? .systemFont(ofSize: ImpactGraphModel.linesFontSize)
        let lineAttributes: [NSAttributedString.Key: Any] = [.font: linesFont, .foregroundColor: NSColor.white]
        for author in model.authorStack {
            for label in layout.lineLabels[author] ?? [] {
                let size = (label.text as NSString).size(withAttributes: lineAttributes)
                (label.text as NSString).draw(at: NSPoint(x: label.center.x - size.width / 2, y: label.center.y - size.height / 2), withAttributes: lineAttributes)
            }
        }
        let weekAttributes: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Arial", size: 8) ?? .systemFont(ofSize: 8), .foregroundColor: NSColor.gray]
        for label in layout.weekLabels {
            let text = Self.weekText(label.week) as NSString
            let size = text.size(withAttributes: weekAttributes)
            text.draw(at: NSPoint(x: label.point.x - size.width / 2, y: label.point.y + size.height / 2), withAttributes: weekAttributes)
        }
    }

    static func weekText(_ week: ImpactWeek) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: week.date)
    }
}

@MainActor
final class ImpactWindowController: NSWindowController, NSWindowDelegate {
    static let authorFormat = "%@ (%d Commits, %d Changed Lines)"

    let loader: ImpactLoader
    let graph = ImpactGraphView()
    let authorLabel = NSTextField(labelWithString: "Author")
    let authorColor = NSView()
    let submodules = NSButton(checkboxWithTitle: "Including submodules", target: nil, action: nil)
    let errorLabel = NSTextField(labelWithString: "")
    let progress = NSProgressIndicator()
    private let scroll = NSScrollView()
    private var onClose: (() -> Void)?

    init(source: any RepositoryImpactDataSource, firstDayOfWeek: Int = ImpactLog.currentFirstDayOfWeek) {
        loader = ImpactLoader(source: source, respectMailmap: true, firstDayOfWeek: firstDayOfWeek)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 863, height: 484),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Impact"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 400, height: 200)
        super.init(window: window)
        window.delegate = self
        build()
        updateAuthorInfo("")
        loader.onCommitsLoaded = { [weak self] commits in
            guard let self else { return }
            self.graph.add(commits)
            self.updateProgress()
            self.updateAuthorInfo(self.graph.selectedAuthor)
        }
        loader.onExited = { [weak self] in self?.progress.stopAnimation(nil); self?.progress.isHidden = true }
        loader.onError = { [weak self] error in
            guard let self else { return }
            self.errorLabel.stringValue = error.localizedDescription
            self.errorLabel.isHidden = false
            self.progress.stopAnimation(nil); self.progress.isHidden = true
        }
        graph.onSelectedAuthorChanged = { [weak self] in
            guard let self else { return }
            self.updateAuthorInfo(self.graph.selectedAuthor)
        }
        updateData()
    }

    required init?(coder: NSCoder) { nil }

    private func build() {
        let content = NSView()
        let top = NSView()
        authorColor.wantsLayer = true
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        errorLabel.lineBreakMode = .byTruncatingTail
        progress.style = .spinning
        progress.controlSize = .small
        submodules.target = self
        submodules.action = #selector(showSubmodulesChanged)
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = false
        scroll.documentView = graph
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        for view in [top, scroll] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        for view in [authorColor, authorLabel, errorLabel, progress, submodules] {
            view.translatesAutoresizingMaskIntoConstraints = false
            top.addSubview(view)
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor), top.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: content.trailingAnchor), top.heightAnchor.constraint(equalToConstant: 32),
            authorColor.leadingAnchor.constraint(equalTo: top.leadingAnchor, constant: 6), authorColor.centerYAnchor.constraint(equalTo: top.centerYAnchor),
            authorColor.widthAnchor.constraint(equalToConstant: 20), authorColor.heightAnchor.constraint(equalToConstant: 20),
            authorLabel.leadingAnchor.constraint(equalTo: top.leadingAnchor, constant: 30), authorLabel.centerYAnchor.constraint(equalTo: top.centerYAnchor),
            errorLabel.leadingAnchor.constraint(equalTo: top.leadingAnchor, constant: 6), errorLabel.centerYAnchor.constraint(equalTo: top.centerYAnchor),
            errorLabel.trailingAnchor.constraint(lessThanOrEqualTo: progress.leadingAnchor, constant: -8),
            authorLabel.trailingAnchor.constraint(lessThanOrEqualTo: progress.leadingAnchor, constant: -8),
            progress.trailingAnchor.constraint(equalTo: submodules.leadingAnchor, constant: -10), progress.centerYAnchor.constraint(equalTo: top.centerYAnchor),
            submodules.trailingAnchor.constraint(equalTo: top.trailingAnchor, constant: -12), submodules.centerYAnchor.constraint(equalTo: top.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor), scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        window?.contentView = content
        graph.frame = NSRect(x: 0, y: 0, width: 863, height: 430)
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged), name: NSView.frameDidChangeNotification, object: scroll.contentView)
        scroll.contentView.postsFrameChangedNotifications = true
    }

    @objc private func viewportChanged() {
        let height = scroll.contentView.bounds.height
        if height > 0 { graph.viewportHeight = height }
    }

    private func updateData() {
        loader.showSubmodules = submodules.state == .on
        updateProgress()
        loader.execute()
    }

    private func updateProgress() {
        let loading = graph.model.isEmpty && errorLabel.isHidden
        progress.isHidden = !loading
        if loading { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
    }

    func updateAuthorInfo(_ author: String) {
        let visible = !author.isEmpty
        authorLabel.isHidden = !visible
        authorColor.isHidden = !visible
        guard visible else { return }
        let data = graph.model.authorInfo(author)
        authorLabel.stringValue = String(format: Self.authorFormat, author, data.commits, data.changedLines)
        authorColor.layer?.backgroundColor = graph.color(for: author).cgColor
    }

    @objc func showSubmodulesChanged() {
        updateAuthorInfo("")
        errorLabel.isHidden = true
        loader.stop()
        graph.clear()
        updateData()
    }

    func present(owner: NSWindow?, onClose: @escaping () -> Void) {
        self.onClose = onClose
        if let owner, let window {
            window.setFrameOrigin(NSPoint(x: owner.frame.minX + 40, y: owner.frame.minY + 40))
            owner.addChildWindow(window, ordered: .above)
        }
        showWindow(nil)
        viewportChanged()
    }

    func windowWillClose(_ notification: Notification) {
        loader.stop()
        loader.dispose()
        NotificationCenter.default.removeObserver(self)
        if let parent = window?.parent { parent.removeChildWindow(window!) }
        let callback = onClose
        onClose = nil
        callback?()
    }
}

@MainActor
final class ImpactGraphPlugin: BuiltInPlugin {
    override var kind: BuiltInPluginKind { .impact }

    override func execute(in host: GitExtensionPluginHost) async throws -> Bool {
        guard host.repositoryURL != nil, let source = host.builtInRepository as? any RepositoryImpactDataSource else { return false }
        let controller = ImpactWindowController(source: source)
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                controller.present(owner: host.owner) { continuation.resume() }
            }
        } onCancel: { Task { @MainActor in controller.close() } }
        return false
    }
}
