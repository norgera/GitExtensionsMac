import AppKit

/// AppKit counterpart of Git Extensions' shared CommitSummaryUserControl.
@MainActor
final class CommitSummaryView: NSBox {
    private let subject = NSTextField(labelWithString: "")
    private let author = NSTextField(labelWithString: "")
    private let date = NSTextField(labelWithString: "")
    private let branches = NSTextField(labelWithString: "")
    private let tags = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        boxType = .primary
        titlePosition = .atTop
        contentViewMargins = NSSize(width: 14, height: 9)

        subject.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        author.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        [subject, author, date, branches, tags].forEach {
            $0.lineBreakMode = .byTruncatingTail
            $0.maximumNumberOfLines = 1
        }

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: 12).isActive = true
        let stack = NSStackView(views: [
            subject,
            spacer,
            metadataRow("Author:", author),
            metadataRow("Commit date:", date),
            metadataRow("Branch(es):", branches),
            metadataRow("Tag(s):", tags)
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView?.addSubview(stack)
        if let contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                stack.topAnchor.constraint(equalTo: contentView.topAnchor),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor)
            ])
        }
    }

    required init?(coder: NSCoder) { nil }

    func apply(_ commit: Commit?) {
        guard let commit else {
            title = "No revision"
            subject.stringValue = "---"
            author.stringValue = "---"
            date.stringValue = "---"
            branches.stringValue = "---"
            tags.stringValue = "---"
            styleReferenceLabel(branches, hasValues: false, color: .systemOrange)
            styleReferenceLabel(tags, hasValues: false, color: .systemBlue)
            branches.toolTip = nil
            tags.toolTip = nil
            return
        }

        title = commit.shortID
        subject.stringValue = commit.subject
        author.stringValue = commit.authorName
        date.stringValue = Self.relativeFormatter.localizedString(for: commit.commitDate, relativeTo: Date())
        let branchNames = commit.references.compactMap { reference -> String? in
            switch reference.kind {
            case .currentBranch, .localBranch, .remoteBranch: reference.name
            default: nil
            }
        }
        let tagNames = commit.references.filter { $0.kind == .tag }.map(\.name)
        branches.stringValue = shortened(branchNames)
        tags.stringValue = shortened(tagNames)
        styleReferenceLabel(branches, hasValues: !branchNames.isEmpty, color: .systemOrange)
        styleReferenceLabel(tags, hasValues: !tagNames.isEmpty, color: .systemBlue)
        branches.toolTip = branchNames.joined(separator: ", ")
        tags.toolTip = tagNames.joined(separator: ", ")
    }

    private func styleReferenceLabel(_ label: NSTextField, hasValues: Bool, color: NSColor) {
        label.font = hasValues
            ? .boldSystemFont(ofSize: NSFont.systemFontSize)
            : .systemFont(ofSize: NSFont.systemFontSize)
        label.drawsBackground = hasValues
        label.backgroundColor = hasValues ? color.withAlphaComponent(0.23) : .clear
    }

    private func metadataRow(_ caption: String, _ value: NSTextField) -> NSStackView {
        let captionLabel = NSTextField(labelWithString: caption)
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        captionLabel.widthAnchor.constraint(equalToConstant: 104).isActive = true
        let row = NSStackView(views: [captionLabel, value])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 5
        row.setContentHuggingPriority(.defaultLow, for: .horizontal)
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return row
    }

    private func shortened(_ values: [String]) -> String {
        guard !values.isEmpty else { return "n/a" }
        let joined = values.joined(separator: ", ")
        guard joined.count > 75 else { return joined }
        return String(joined.prefix(74)) + "…"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}
