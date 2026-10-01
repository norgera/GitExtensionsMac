import AppKit
import GitExtensionsCore
import GitCommands


@MainActor
final class BlameWindowController: NSWindowController, NSWindowDelegate {
    let blameController = BlameViewController()
    let infoController = CommitDetailViewController()
    var onClose: (() -> Void)?
    private var selectionTask: Task<Void, Never>?

    init(source: any RepositoryBlameDataSource, infoSource: (any RepositoryCommitInfoDataSource)?,
         revision: Commit, file: String, initialLine: Int?,
         hostedRemotes: @escaping () async -> [HostedRemote], showChanges: @escaping (ObjectID) -> Void) {
        let split = RetainingSplitViewController(resizeBehavior: .fixedLeadingPane)
        split.splitView.isVertical = false
        super.init(window: nil)
        infoController.source = infoSource
        split.addSplitViewItem(NSSplitViewItem(viewController: infoController))
        split.splitViewItems[0].minimumThickness = 100
        split.splitViewItems[0].preferredThicknessFraction = 0.3
        split.addSplitViewItem(NSSplitViewItem(viewController: blameController))
        let window = NSWindow(contentViewController: split)
        window.title = "Blame (\(file))"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 784, height: 762))
        window.minSize = NSSize(width: 550, height: 400)
        window.setFrameAutosaveName("GitExtensionsMac.Blame")
        window.contentView?.layoutSubtreeIfNeeded()
        split.setRetainedPosition(180)
        window.isReleasedWhenClosed = false
        self.window = window
        window.delegate = self
        blameController.source = source
        blameController.context = .init(revisionInGrid: { _ in nil }, selectFileInRevision: { _, _ in false }, hostedRemotes: hostedRemotes)
        blameController.onShowChanges = showChanges
        blameController.onSelectedCommit = { [weak self] selected in
            guard let self else { return }
            selectionTask?.cancel()
            selectionTask = Task { @MainActor [weak self] in
                guard let commit = try? await source.loadBlameRevision(selected.objectID), !Task.isCancelled else { return }
                self?.infoController.apply(commit: commit, children: [])
            }
        }
        infoController.apply(commit: revision, children: [])
        if let id = revision.objectID {
            blameController.load(revision: id, file: file, encoding: AppSettingsStore.shared.fileViewerPreferences.textEncoding, initialLine: initialLine)
        }
    }

    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) {
        selectionTask?.cancel()
        blameController.cancel()
        onClose?()
    }
}
