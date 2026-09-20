import GitExtensionsCore
import GitCommands
import AppKit

final class CommitDetailViewController: NSViewController, NSMenuDelegate {
    var onSelectRevision: ((ObjectID) -> Void)?

    private let documentView = FlippedView()
    private let stack = NSStackView()
    private let avatar = AuthorAvatarView()
    private let commitIDValue = NSTextField(labelWithString: "")
    private let authorValue = NSTextField(labelWithString: "")
    private let authorDateValue = NSTextField(labelWithString: "")
    private let committerValue = NSTextField(labelWithString: "")
    private let commitDateValue = NSTextField(labelWithString: "")
    private let parentsValue = RevisionLinkListView()
    private let childrenValue = RevisionLinkListView()
    private let branchesValue = NSTextField(labelWithString: "")
    private let tagsValue = NSTextField(labelWithString: "")
    private let subjectLabel = NSTextField(wrappingLabelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let scrollView = NSScrollView()
    private let externalLinks = NSStackView()

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .top
        headerRow.spacing = 8
        avatar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 80),
            avatar.heightAnchor.constraint(equalToConstant: 80)
        ])

        let grid = NSGridView(views: [
            [caption("Commit:"), commitIDValue],
            [caption("Author:"), authorValue],
            [caption("Author date:"), authorDateValue],
            [caption("Committer:"), committerValue],
            [caption("Commit date:"), commitDateValue],
            [caption("Parents:"), parentsValue],
            [caption("Children:"), childrenValue],
            [caption("Branches:"), branchesValue],
            [caption("Tags:"), tagsValue]
        ])
        grid.rowSpacing = 2
        grid.columnSpacing = 8
        grid.xPlacement = .leading
        grid.column(at: 0).xPlacement = .leading
        [commitIDValue, authorValue, authorDateValue, committerValue, commitDateValue, branchesValue, tagsValue].forEach {
            $0.font = AppSettingsStore.shared.applicationFont(size: 11)
            $0.lineBreakMode = .byTruncatingTail
            $0.isSelectable = true
        }
        parentsValue.onSelectRevision = { [weak self] in self?.onSelectRevision?($0) }
        childrenValue.onSelectRevision = { [weak self] in self?.onSelectRevision?($0) }
        commitIDValue.font = AppSettingsStore.shared.fontPreferences.font(.monospace, fallback: .monospacedSystemFont(ofSize: 10.5, weight: .regular))

        headerRow.addArrangedSubview(avatar)
        headerRow.addArrangedSubview(grid)

        let headerContainer = NSView()
        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.addSubview(headerRow)
        NSLayoutConstraint.activate([
            headerRow.topAnchor.constraint(equalTo: headerContainer.topAnchor, constant: 8),
            headerRow.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 8),
            headerRow.trailingAnchor.constraint(lessThanOrEqualTo: headerContainer.trailingAnchor, constant: -8),
            headerRow.bottomAnchor.constraint(equalTo: headerContainer.bottomAnchor, constant: -8)
        ])

        let messageBackground = NSVisualEffectView()
        messageBackground.material = .contentBackground
        messageBackground.blendingMode = .withinWindow
        messageBackground.state = .active
        subjectLabel.font = AppSettingsStore.shared.applicationFont(size: 12, weight: .bold)
        subjectLabel.translatesAutoresizingMaskIntoConstraints = false
        messageBackground.addSubview(subjectLabel)
        NSLayoutConstraint.activate([
            subjectLabel.topAnchor.constraint(equalTo: messageBackground.topAnchor, constant: 8),
            subjectLabel.leadingAnchor.constraint(equalTo: messageBackground.leadingAnchor, constant: 9),
            subjectLabel.trailingAnchor.constraint(equalTo: messageBackground.trailingAnchor, constant: -9),
            subjectLabel.bottomAnchor.constraint(equalTo: messageBackground.bottomAnchor, constant: -8)
        ])

        bodyLabel.font = AppSettingsStore.shared.applicationFont(size: 11)
        bodyLabel.textColor = .labelColor
        let bodyContainer = NSView()
        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.addSubview(bodyLabel)
        NSLayoutConstraint.activate([
            bodyLabel.topAnchor.constraint(equalTo: bodyContainer.topAnchor, constant: 8),
            bodyLabel.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor, constant: 9),
            bodyLabel.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor, constant: -9),
            bodyLabel.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor, constant: -8)
        ])

        stack.addArrangedSubview(headerContainer)
        stack.addArrangedSubview(messageBackground)
        stack.addArrangedSubview(bodyContainer)
        externalLinks.orientation = .vertical
        externalLinks.alignment = .leading
        externalLinks.spacing = 3
        stack.addArrangedSubview(externalLinks)
        [headerContainer, messageBackground, bodyContainer].forEach {
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        documentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor)
        ])

        let menu = NSMenu()
        menu.delegate = self
        documentView.menu = menu

        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        view = scrollView
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        documentView.frame.size.width = max(0, scrollView.contentSize.width)
        documentView.frame.size.height = max(scrollView.contentSize.height, stack.fittingSize.height)
    }

    func apply(commit: Commit, relations: CommitRelations, history: [Commit]) {
        applyExternalLinks([])
        let shortIDByID = Dictionary(uniqueKeysWithValues: history.map { ($0.id, $0.shortID) })
        avatar.apply(name: commit.authorName, email: commit.authorEmail)
        commitIDValue.stringValue = commit.shortID
        authorValue.stringValue = "\(commit.authorName) <\(commit.authorEmail)>"
        authorDateValue.stringValue = Self.dateFormatter.string(from: commit.authorDate)
        committerValue.stringValue = "\(commit.committerName) <\(commit.committerEmail)>"
        commitDateValue.stringValue = Self.dateFormatter.string(from: commit.commitDate)
        parentsValue.apply(revisions: relations.parentIDs.map { ($0, shortIDByID[.object($0)] ?? $0.shortString) })
        childrenValue.apply(revisions: relations.childIDs.map { ($0, shortIDByID[.object($0)] ?? $0.shortString) })
        branchesValue.stringValue = Self.joinedOrNone(relations.branchNames)
        tagsValue.stringValue = Self.joinedOrNone(relations.tagNames)
        subjectLabel.stringValue = commit.subject
        bodyLabel.stringValue = commit.body.isEmpty ? "No extended commit message." : commit.body
        view.needsLayout = true
    }

    func applyExternalLinks(_ links: [RevisionLinkDefinition.Link], error: String? = nil) {
        for view in externalLinks.arrangedSubviews { externalLinks.removeArrangedSubview(view); view.removeFromSuperview() }
        for link in links {
            let button = NSButton(title: link.caption, target: self, action: #selector(openExternalLink(_:)))
            button.isBordered = false
            button.contentTintColor = .linkColor
            button.font = AppSettingsStore.shared.applicationFont(size: 11)
            button.toolTip = link.destination
            button.identifier = NSUserInterfaceItemIdentifier(link.destination)
            button.isEnabled = URL(string: link.destination)?.scheme != nil
            externalLinks.addArrangedSubview(button)
        }
        if let error { externalLinks.addArrangedSubview(NSTextField(wrappingLabelWithString: "Revision links: \(error)")) }
        view.needsLayout = true
    }

    @objc private func openExternalLink(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue, let url = URL(string: value), url.scheme != nil else { return }
        NSWorkspace.shared.open(url)
    }

    private static func joinedOrNone(_ values: [String]) -> String {
        values.isEmpty ? "(none)" : values.joined(separator: ", ")
    }

    private func caption(_ value: String) -> NSTextField {
        let text = NSTextField(labelWithString: value)
        text.font = AppSettingsStore.shared.applicationFont(size: 11, weight: .semibold)
        text.textColor = .secondaryLabelColor
        return text
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        [
            "Copy link",
            "Copy commit info",
            "Show local branches containing this commit",
            "Show remote branches containing this commit",
            "Show tags containing this commit",
            "Show messages of annotated tags",
            "Show the most recent tag this commit derives from",
            "Add notes"
        ].forEach { menu.addItem(placeholderMenuItem($0)) }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

final class AuthorAvatarView: NSView {
    private var presentation = AuthorAvatarPresentation(initials: "?", paletteIndex: 0)
    private static let palette: [NSColor] = [
        NSColor(srgbRed: 0.439, green: 0.502, blue: 0.565, alpha: 1), // SlateGray
        NSColor(srgbRed: 0.255, green: 0.412, blue: 0.882, alpha: 1), // RoyalBlue
        NSColor(srgbRed: 0.502, green: 0, blue: 0.502, alpha: 1),     // Purple
        NSColor(srgbRed: 1, green: 0.271, blue: 0, alpha: 1),         // OrangeRed
        NSColor(srgbRed: 0, green: 0.502, blue: 0.502, alpha: 1),     // Teal
        NSColor(srgbRed: 0.420, green: 0.557, blue: 0.137, alpha: 1)  // OliveDrab
    ]

    func apply(name: String?, email: String?) {
        presentation = AuthorAvatarPresentation.make(name: name, email: email)
        setAccessibilityLabel("Author avatar for \(name?.isEmpty == false ? name! : email ?? "unknown author")")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let color = Self.palette[presentation.paletteIndex % Self.palette.count]
        color.setFill()
        bounds.fill()
        let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 32, weight: .regular),
            .foregroundColor: luminance > 0.58 ? NSColor.black : NSColor.white
        ]
        let size = presentation.initials.size(withAttributes: attributes)
        presentation.initials.draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes
        )
    }
}

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class RevisionLinkListView: NSView {
    var onSelectRevision: ((ObjectID) -> Void)?

    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func apply(revisions: [(id: ObjectID, title: String)]) {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        guard !revisions.isEmpty else {
            stack.addArrangedSubview(valueLabel("(none)"))
            return
        }

        for (index, revision) in revisions.enumerated() {
            if index > 0 { stack.addArrangedSubview(valueLabel(", ")) }
            let button = NSButton(title: revision.title, target: self, action: #selector(selectRevision(_:)))
            button.isBordered = false
            button.font = AppSettingsStore.shared.fontPreferences.font(.monospace, fallback: .monospacedSystemFont(ofSize: 10.5, weight: .regular))
            button.contentTintColor = .linkColor
            button.toolTip = "Go to revision \(revision.title)"
            button.identifier = NSUserInterfaceItemIdentifier(revision.id.string)
            button.setButtonType(.momentaryChange)
            stack.addArrangedSubview(button)
        }
    }

    @objc private func selectRevision(_ sender: NSButton) {
        guard let revisionID = sender.identifier?.rawValue,
              let objectID = try? ObjectID.parse(revisionID) else { return }
        onSelectRevision?(objectID)
    }

    private func valueLabel(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = AppSettingsStore.shared.applicationFont(size: 11)
        label.isSelectable = true
        return label
    }
}
