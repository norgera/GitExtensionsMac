import GitExtensionsCore
import GitCommands
import AppKit



@MainActor
final class CommitDetailViewController: NSViewController, NSTextViewDelegate {

    var onGoToRevision: ((RevisionID) -> Void)?

    var onNavigate: ((_ backward: Bool) -> Void)?

    var source: (any RepositoryCommitInfoDataSource)?

    private let documentView = CommitInfoDocumentView()
    private let stack = NSStackView()
    private let avatar = AuthorAvatarView()
    let headerText = CommitInfoTextView()
    let messageText = CommitInfoTextView()
    let revisionInfoText = CommitInfoTextView()
    private let messagePanel = CommitInfoColorView()
    private let scrollView = NSScrollView()

    private(set) var commit: Commit?
    private var childIDs: [ObjectID] = []
    private(set) var headerRows: [CommitInfoPresentation.HeaderRow] = []
    private var loadTask: Task<Void, Never>?
    private var tagOrderTask: Task<Void, Never>?
    private var tagOrder: [String: Int]?
    private var brokenRefsReported = false


    private(set) var body = ""
    private(set) var notes = ""
    private var annotatedTagMessages: [String: String]?
    private var linksInfo: [CommitInfoPresentation.Run] = []
    private var branches: [String]?
    private var tags: [String]?
    private var describe: RepositoryCommitDescription?
    private var showAllBranches = false
    private var showAllTags = false
    private var currentBranch = ""

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.commitInfoMode = true
        NSLayoutConstraint.activate([avatar.widthAnchor.constraint(equalToConstant: 80), avatar.heightAnchor.constraint(equalToConstant: 80)])
        for text in [headerText, messageText, revisionInfoText] {
            text.delegate = self
            text.owner = self
        }
        messageText.font = AppSettingsStore.shared.fontPreferences.font(.commit, fallback: AppSettingsStore.shared.applicationFont(size: 12))
        headerText.font = AppSettingsStore.shared.applicationFont(size: 11)
        revisionInfoText.font = AppSettingsStore.shared.applicationFont(size: 11)

        let headerRow = NSStackView(views: [avatar, headerText])
        headerRow.alignment = .top
        headerRow.spacing = 8
        headerRow.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        messagePanel.addSubview(messageText)
        messageText.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            messageText.topAnchor.constraint(equalTo: messagePanel.topAnchor, constant: 8),
            messageText.leadingAnchor.constraint(equalTo: messagePanel.leadingAnchor, constant: 8),
            messageText.trailingAnchor.constraint(equalTo: messagePanel.trailingAnchor, constant: -8),
            messageText.bottomAnchor.constraint(equalTo: messagePanel.bottomAnchor, constant: -8)
        ])
        let infoContainer = NSView()
        infoContainer.addSubview(revisionInfoText)
        revisionInfoText.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            revisionInfoText.topAnchor.constraint(equalTo: infoContainer.topAnchor, constant: 8),
            revisionInfoText.leadingAnchor.constraint(equalTo: infoContainer.leadingAnchor, constant: 8),
            revisionInfoText.trailingAnchor.constraint(equalTo: infoContainer.trailingAnchor, constant: -8),
            revisionInfoText.bottomAnchor.constraint(equalTo: infoContainer.bottomAnchor, constant: -8)
        ])
        for view in [headerRow, messagePanel, infoContainer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        documentView.addSubview(stack)
        documentView.owner = self
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor)
        ])
        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        view = scrollView
        stack.isHidden = true
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        documentView.frame.size.width = max(0, scrollView.contentSize.width)
        documentView.layoutSubtreeIfNeeded()
        documentView.frame.size.height = max(scrollView.contentSize.height, stack.fittingSize.height)
    }



    func apply(commit: Commit, children: [ObjectID]) {
        if self.commit?.id != commit.id { linksInfo = [] }
        self.commit = commit
        childIDs = children
        _ = view
        stack.isHidden = false
        headerRows = CommitInfoPresentation.header(commit, children: children)
        headerText.setContent(renderHeader(headerRows))
        avatar.apply(name: commit.authorName, email: commit.authorEmail)
        reloadCommitInfo()
    }


    func clear() {
        loadTask?.cancel()
        commit = nil
        _ = view
        stack.isHidden = true
    }


    func repositoryChanged() {
        tagOrder = nil
        brokenRefsReported = false
        guard let source else { return }
        tagOrderTask?.cancel()
        tagOrderTask = Task { @MainActor [weak self] in
            do {
                let order = try await source.loadTagOrder()
                guard !Task.isCancelled, let self else { return }
                tagOrder = order
                updateRevisionInfo()
            } catch let error as RepositoryCommitInfoError {
                guard let self, !brokenRefsReported, let window = view.window else { return }
                brokenRefsReported = true
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "Repository failure"
                alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: window) { _ in }
            } catch {}
        }
    }

    func reloadCommitInfo() {
        loadTask?.cancel()
        showAllBranches = false
        showAllTags = false
        branches = nil
        tags = nil
        annotatedTagMessages = nil
        describe = nil
        guard let commit else { return }
        body = commit.body.isEmpty ? commit.subject : commit.subject + "\n\n" + commit.body
        notes = commit.notes
        renderMessage(links: [:])
        guard !commit.isArtificial, let objectID = commit.objectID, let source else {
            revisionInfoText.setContent(NSAttributedString())
            return
        }
        let preferences = AppSettingsStore.shared.commitInfoPreferences
        let showAnnotated = AppSettingsStore.shared.revisionGridPreferences.showAnnotatedTagsMessages
        let annotatedTags = commit.references.filter { $0.kind == .tag && $0.isAnnotated }.map(\.name)
        let commitID = commit.id
        updateRevisionInfo()
        loadTask = Task { @MainActor [weak self] in
            async let message = try? source.loadCommitMessageAndNotes(objectID)
            async let branchList: [String]? = preferences.showContainedInBranches
                ? (try? source.loadBranchesContaining(objectID,
                                                      local: preferences.showContainedInBranchesLocal || preferences.showContainedInBranchesRemoteIfNoLocal,
                                                      remote: preferences.showContainedInBranchesRemote || preferences.showContainedInBranchesRemoteIfNoLocal)) ?? []
                : nil
            async let tagList: [String]? = preferences.showContainedInTags ? (try? source.loadTagsContaining(objectID)) ?? [] : nil
            async let description: RepositoryCommitDescription? = preferences.showTagThisCommitDerivesFrom ? try? source.loadDescribe(objectID) : nil
            async let selectedBranch = (try? source.loadSelectedBranch()) ?? ""
            var messages: [String: String]?
            if showAnnotated {
                var loaded: [String: String] = [:]
                for tag in annotatedTags { if let text = try? await source.loadTagMessage(tag) { loaded[tag] = text } }
                messages = loaded
            }
            let loadedMessage = await message
            var hashLinks: [String: ObjectID] = [:]
            if let text = loadedMessage.map({ CommitInfoPresentation.bodyAndNotes($0.body, notes: $0.notes) }) {
                for candidate in Set(CommitInfoPresentation.hashCandidates(in: text).map(\.hash)) {
                    if let id = try? await source.resolveCommit(candidate), id.string.hasPrefix(candidate) { hashLinks[candidate] = id }
                }
            }
            let (loadedBranches, loadedTags, loadedDescription, current) = await (branchList, tagList, description, selectedBranch)
            guard !Task.isCancelled, let self, self.commit?.id == commitID else { return }
            if let loadedMessage {
                body = loadedMessage.body
                notes = loadedMessage.notes
            }
            renderMessage(links: hashLinks)
            annotatedTagMessages = messages
            branches = loadedBranches
            tags = loadedTags
            describe = loadedDescription
            currentBranch = current
            updateRevisionInfo()
        }
    }


    func applyExternalLinks(_ links: [RevisionLinkDefinition.Link], error: String? = nil) {
        var runs: [CommitInfoPresentation.Run] = []
        var seen: [RevisionLinkDefinition.Link] = []
        for link in links where !seen.contains(link) {
            seen.append(link)
            if !runs.isEmpty { runs.append(.init(", ")) }
            runs.append(.init(link.caption, link: URL(string: link.destination).flatMap { $0.scheme == nil ? nil : .external($0) }))
        }
        linksInfo = runs.isEmpty ? [] : [.init("Related links: ")] + runs
        if let error { linksInfo.append(.init("\nRevision links: \(error)")) }
        updateRevisionInfo()
    }



    private var linkAttributes: [NSAttributedString.Key: Any] { [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand] }

    private func attributed(_ runs: [CommitInfoPresentation.Run], font: NSFont) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        for run in runs {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            if let link = run.link { attributes[.link] = link.url }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return result
    }

    private func renderHeader(_ rows: [CommitInfoPresentation.HeaderRow]) -> NSAttributedString {
        let font = headerText.font ?? .systemFont(ofSize: 11)
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let paragraph = NSMutableParagraphStyle()
        let labelWidth = rows.map { ($0.label + ":" as NSString).size(withAttributes: [.font: bold]).width }.max() ?? 0
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: labelWidth + 8)]
        paragraph.headIndent = labelWidth + 8
        let result = NSMutableAttributedString()
        for (index, row) in rows.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            result.append(NSAttributedString(string: row.label + ":\t", attributes: [.font: bold, .foregroundColor: NSColor.secondaryLabelColor]))
            result.append(attributed(row.value, font: font))
        }
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }


    private func renderMessage(links: [String: ObjectID]) {
        let text = CommitInfoPresentation.bodyAndNotes(body, notes: notes).trimmingCharacters(in: .whitespacesAndNewlines)
        let font = messageText.font ?? .systemFont(ofSize: 12)
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        if commit?.isArtificial == false {
            for candidate in CommitInfoPresentation.hashCandidates(in: text) {
                guard let id = links[candidate.hash] else { continue }
                result.addAttribute(.link, value: CommitInfoPresentation.Link.commit(id).url, range: NSRange(candidate.range, in: text))
            }
        }
        messageText.setContent(result)
        view.needsLayout = true
    }


    private func updateRevisionInfo() {
        let font = revisionInfoText.font ?? .systemFont(ofSize: 11)
        let preferences = AppSettingsStore.shared.commitInfoPreferences
        var sections: [NSAttributedString] = []
        if let order = tagOrder, let messages = annotatedTagMessages, !messages.isEmpty, let commit {
            let names = commit.references.filter { $0.kind == .tag }.map(\.name)
            let info = NSMutableAttributedString()
            for (index, entry) in CommitInfoPresentation.annotatedTagsInfo(tagNames: names, messages: messages, order: order).enumerated() {
                if index > 0 { info.append(NSAttributedString(string: "\n")) }
                info.append(NSAttributedString(string: entry.tag, attributes: [.font: font, .underlineStyle: NSUnderlineStyle.single.rawValue]))
                info.append(NSAttributedString(string: ": " + entry.message, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
            }
            if info.length > 0 { sections.append(info) }
        }
        if !linksInfo.isEmpty { sections.append(attributed(linksInfo, font: font)) }
        if let branches {
            let sorted = CommitInfoPresentation.sortBranches(branches, currentBranch: currentBranch)
            sections.append(attributed(CommitInfoPresentation.branchesInfo(sorted, preferences: preferences, limit: !showAllBranches), font: font))
        }
        if let order = tagOrder, let tags {
            sections.append(attributed(CommitInfoPresentation.tagsInfo(CommitInfoPresentation.sortTags(tags, order: order), limit: !showAllTags), font: font))
        }
        if let describe { sections.append(attributed(CommitInfoPresentation.describeInfo(describe), font: font)) }
        let result = NSMutableAttributedString()
        for (index, section) in sections.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n\n", attributes: [.font: font])) }
            result.append(section)
        }
        revisionInfoText.setContent(result)
        view.needsLayout = true
    }


    var revisionInfoString: String { revisionInfoText.string }



    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return false }
        execute(url)
        return true
    }


    func execute(_ url: URL) {
        guard let link = CommitInfoPresentation.Link(url: url) else { return }
        switch link {
        case .commit(let id):
            onGoToRevision?(.object(id))
        case .branch(let name), .tag(let name):
            guard let source else { return }
            Task { @MainActor [weak self] in
                guard let id = try? await source.resolveCommit(name) else { return }
                self?.onGoToRevision?(.object(id))
            }
        case .showAll(let what):
            if what == "branches" { showAllBranches = true } else if what == "tags" { showAllTags = true }
            updateRevisionInfo()
        case .external(let url):
            NSWorkspace.shared.open(url)
        }
    }

    func otherMouseDown(button: Int) {
        if button == 3 { onNavigate?(true) } else if button == 4 { onNavigate?(false) }
    }



    func contextMenu(link: URL?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let preferences = AppSettingsStore.shared.commitInfoPreferences
        func item(_ title: String, checked: Bool? = nil, enabled: Bool = true, _ handler: @escaping () -> Void) {
            let item = DashboardClosureMenuItem(title: title, handler: handler)
            if let checked { item.state = checked ? .on : .off }
            item.isEnabled = enabled
            menu.addItem(item)
        }
        if let link {
            item("Copy link (\(link.absoluteString))") { Self.copy(link.absoluteString) }
        }
        item("Copy commit info") { [weak self] in self.map { Self.copy($0.commitInfoText) } }
        menu.addItem(.separator())
        func toggle(_ title: String, _ keyPath: WritableKeyPath<CommitInfoPreferences, Bool>) {
            item(title, checked: preferences[keyPath: keyPath]) { [weak self] in
                var value = AppSettingsStore.shared.commitInfoPreferences
                value[keyPath: keyPath].toggle()
                AppSettingsStore.shared.saveCommitInfoPreferences(value)
                self?.reloadCommitInfo()
            }
        }
        toggle("Show local branches containing this commit", \.showContainedInBranchesLocal)
        toggle("Show remote branches containing this commit", \.showContainedInBranchesRemote)
        toggle("Show remote branches only when no local branch contains this commit", \.showContainedInBranchesRemoteIfNoLocal)
        toggle("Show tags containing this commit", \.showContainedInTags)
        item("Show messages of annotated tags", checked: AppSettingsStore.shared.revisionGridPreferences.showAnnotatedTagsMessages) { [weak self] in
            var grid = AppSettingsStore.shared.revisionGridPreferences
            grid.showAnnotatedTagsMessages.toggle()
            AppSettingsStore.shared.saveRevisionGridPreferences(grid)
            NotificationCenter.default.post(name: .commitInfoAnnotatedTagsSettingChanged, object: nil)
            self?.reloadCommitInfo()
        }
        toggle("Show the most recent tag this commit derives from", \.showTagThisCommitDerivesFrom)
        menu.addItem(.separator())
        let addNotes = DashboardClosureMenuItem(title: "Add notes") { [weak self] in self?.addNotes() }
        addNotes.isEnabled = commit.map { !$0.isArtificial } ?? false && source != nil
        if let chord = ApplicationHotkeys.shared.chord(for: "addNotes"), let shortcut = chord.swiftUIKeyEquivalent {
            addNotes.keyEquivalent = shortcut.key
            addNotes.keyEquivalentModifierMask = shortcut.modifiers
        }
        menu.addItem(addNotes)
        return menu
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }


    var commitInfoText: String {
        "\(CommitInfoPresentation.plainHeader(headerRows))\n\n\(messageText.string)"
    }




    func addNotes() {
        guard let commit, !commit.isArtificial, let objectID = commit.objectID, let source, let window = view.window else { return }
        Task { @MainActor [weak self] in
            let current = (try? await source.loadNotes(objectID)) ?? ""
            CommitNotesEditor.present(owner: window, commit: commit, notes: current) { text in
                guard let text else { return }
                Task { @MainActor in
                    do {
                        try await source.saveNotes(objectID, text: text)
                        guard let self, self.commit?.id == commit.id else { return }
                        self.commit = commit.withNotes("")
                        self.reloadCommitInfo()
                    } catch {
                        await MutationDialogs.showError(error, title: "Add notes", window: window)
                    }
                }
            }
        }
    }
}

extension Notification.Name {

    static let commitInfoAnnotatedTagsSettingChanged = Notification.Name("GitExtensionsMac.commitInfoAnnotatedTagsSettingChanged")
}

private extension ApplicationKeyChord {
    var swiftUIKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags)? {
        key.isEmpty ? nil : (key, NSEvent.ModifierFlags(rawValue: modifiers))
    }
}


final class CommitInfoTextView: NSTextView {
    weak var owner: CommitDetailViewController?

    convenience init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        isRichText = true
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        isVerticallyResizable = false
        linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        setContentHuggingPriority(.defaultHigh, for: .vertical)
    }

    override var intrinsicContentSize: NSSize {
        guard let layoutManager, let textContainer else { return super.intrinsicContentSize }
        layoutManager.ensureLayout(for: textContainer)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(layoutManager.usedRect(for: textContainer).height))
    }


    func setContent(_ text: NSAttributedString) {
        textStorage?.setAttributedString(text)
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize() }
    }

    override func layout() {
        super.layout()
        invalidateIntrinsicContentSize()
    }


    func link(at point: NSPoint) -> URL? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        var fraction: CGFloat = 0
        let index = layoutManager.characterIndex(for: point, in: textContainer, fractionOfDistanceBetweenInsertionPoints: &fraction)
        guard index < storage.length,
              layoutManager.boundingRect(forGlyphRange: layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil),
                                         in: textContainer).contains(point) else { return nil }
        let value = storage.attribute(.link, at: index, effectiveRange: nil)
        return (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.contextMenu(link: link(at: convert(event.locationInWindow, from: nil)))
    }

    override func otherMouseDown(with event: NSEvent) {
        owner?.otherMouseDown(button: event.buttonNumber)
    }
}

final class CommitInfoDocumentView: NSView {
    weak var owner: CommitDetailViewController?
    override var isFlipped: Bool { true }
    override func menu(for event: NSEvent) -> NSMenu? { owner?.contextMenu(link: nil) }
    override func otherMouseDown(with event: NSEvent) { owner?.otherMouseDown(button: event.buttonNumber) }
}


final class CommitInfoColorView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.blended(withFraction: 0.04, of: .black)?.setFill()
        dirtyRect.intersection(bounds).fill()
    }
}


@MainActor
final class CommitNotesEditor: NSViewController {
    private let textView = NSTextView()
    private let initial: String
    private var completion: ((String?) -> Void)?

    static func present(owner: NSWindow, commit: Commit, notes: String, completion: @escaping (String?) -> Void) {
        let controller = CommitNotesEditor(notes: notes)
        controller.completion = completion
        let panel = NSPanel(contentViewController: controller)
        panel.title = "Add notes"
        panel.styleMask = [.titled, .resizable]
        panel.setContentSize(NSSize(width: 520, height: 300))
        owner.beginSheet(panel)
    }

    init(notes: String) {
        initial = notes
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let scroll = NSTextView.scrollableTextView()
        if let text = scroll.documentView as? NSTextView {
            text.string = initial
            text.font = AppSettingsStore.shared.fontPreferences.font(.commit, fallback: .monospacedSystemFont(ofSize: 12, weight: .regular))
            text.isRichText = false
            text.allowsUndo = true
        }
        scroll.borderType = .bezelBorder
        let note = NSTextField(wrappingLabelWithString: "An empty note removes the note from the commit.")
        note.textColor = .secondaryLabelColor
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        save.keyEquivalentModifierMask = .command
        let buttons = NSStackView(views: [note, NSView(), cancel, save])
        let stack = NSStackView(views: [scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 480).isActive = true
        view = stack
    }

    var editedText: String { ((view.subviews.first as? NSScrollView)?.documentView as? NSTextView)?.string ?? "" }

    @objc private func save() { close(editedText) }
    @objc private func cancel() { close(nil) }

    private func close(_ text: String?) {
        guard let window = view.window else { return }
        window.sheetParent?.endSheet(window)
        let completion = completion
        self.completion = nil
        completion?(text)
    }
}

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
