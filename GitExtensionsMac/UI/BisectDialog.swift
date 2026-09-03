import GitExtensionsCore
import GitCommands
import AppKit

@MainActor
enum BisectDialog {
    struct Result: Sendable {
        let repositoryChanged: Bool
        let preferredCommitID: RevisionID?
    }

    static func present(
        source: any RepositoryBisectingDataSource,
        selectedRevisions: [Commit],
        owner: NSWindow,
        statusChanged: @escaping @MainActor (String) -> Void
    ) async -> Result {
        await withCheckedContinuation { continuation in
            let controller = BisectViewController(
                source: source,
                selectedRevisions: selectedRevisions,
                statusChanged: statusChanged,
                completion: { changed in continuation.resume(returning: changed) }
            )
            let panel = NSPanel(contentViewController: controller)
            panel.title = "Bisect"
            panel.styleMask = [.titled, .closable]
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.isReleasedWhenClosed = false
            panel.setContentSize(NSSize(width: 248, height: 171))
            controller.panel = panel
            owner.beginSheet(panel)
        }
    }
}

@MainActor
private final class BisectViewController: NSViewController, NSWindowDelegate {
    weak var panel: NSPanel?

    private let source: any RepositoryBisectingDataSource
    private let selectedRevisionIDs: [ObjectID]
    private let statusChanged: @MainActor (String) -> Void
    private let completion: (BisectDialog.Result) -> Void
    private let startButton = NSButton(title: "Start bisect", target: nil, action: nil)
    private let badButton = NSButton(title: "Mark current revision bad", target: nil, action: nil)
    private let goodButton = NSButton(title: "Mark current revision good", target: nil, action: nil)
    private let skipButton = NSButton(title: "Skip current revision", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop bisect", target: nil, action: nil)
    private var operationTask: Task<Void, Never>?
    private var repositoryChanged = false
    private var preferredCommitID: RevisionID?
    private var didFinish = false

    init(
        source: any RepositoryBisectingDataSource,
        selectedRevisions: [Commit],
        statusChanged: @escaping @MainActor (String) -> Void,
        completion: @escaping (BisectDialog.Result) -> Void
    ) {
        self.source = source
        selectedRevisionIDs = selectedRevisions.compactMap(\.objectID)
        self.statusChanged = statusChanged
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        startButton.target = self
        startButton.action = #selector(start)
        badButton.target = self
        badButton.action = #selector(markBad)
        goodButton.target = self
        goodButton.action = #selector(markGood)
        skipButton.target = self
        skipButton.action = #selector(skip)
        stopButton.target = self
        stopButton.action = #selector(stop)

        let stack = NSStackView(views: [startButton, badButton, goodButton, skipButton, stopButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -12)
        ])
        [startButton, badButton, goodButton, skipButton, stopButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            $0.heightAnchor.constraint(equalToConstant: 25).isActive = true
        }
        view = root
        setButtonsEnabled(false)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        panel?.delegate = self
        reloadState()
    }

    override func cancelOperation(_ sender: Any?) {
        finish()
    }

    func windowWillClose(_ notification: Notification) {
        finish()
    }

    @objc private func start() {
        run(closeAfterward: false) { [source] in try await source.startBisect() } completion: { [weak self] in
            guard let self else { return }
            if selectedRevisionIDs.count > 1 {
                await confirmAndSetSelectedRange()
            } else {
                reloadState()
            }
        }
    }

    @objc private func markBad() {
        run(closeAfterward: true) { [source] in try await source.markBisect(.bad, revisions: []) }
    }

    @objc private func markGood() {
        run(closeAfterward: true) { [source] in try await source.markBisect(.good, revisions: []) }
    }

    @objc private func skip() {
        run(closeAfterward: true) { [source] in try await source.markBisect(.skip, revisions: []) }
    }

    @objc private func stop() {
        run(closeAfterward: true) { [source] in try await source.resetBisect() }
    }

    private func confirmAndSetSelectedRange() async {
        guard let panel else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Bisect"
        alert.informativeText = "Mark selected revisions as start bisect range?"
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")
        guard await alert.beginSheetModal(for: panel) == .alertFirstButtonReturn else {
            reloadState()
            return
        }

        let good = selectedRevisionIDs[0]
        let bad = selectedRevisionIDs[selectedRevisionIDs.count - 1]
        do {
            setButtonsEnabled(false)
            let goodResult = try await source.markBisect(.good, revisions: [good])
            apply(goodResult)
            guard case .completed = goodResult.outcome else {
                finish()
                return
            }
            let badResult = try await source.markBisect(.bad, revisions: [bad])
            apply(badResult)
            finish()
        } catch is CancellationError {
            finish()
        } catch {
            await show(error)
            reloadState()
        }
    }

    private func run(
        closeAfterward: Bool,
        operation: @escaping @Sendable () async throws -> RepositoryMutationResult,
        completion: (@MainActor () async -> Void)? = nil
    ) {
        operationTask?.cancel()
        setButtonsEnabled(false)
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await operation()
                guard !Task.isCancelled else { return }
                apply(result)
                if closeAfterward {
                    finish()
                } else if let completion {
                    await completion()
                } else {
                    reloadState()
                }
            } catch is CancellationError {
                return
            } catch {
                await show(error)
                reloadState()
            }
        }
    }

    private func apply(_ result: RepositoryMutationResult) {
        repositoryChanged = true
        preferredCommitID = result.selectedCommitID ?? preferredCommitID
        statusChanged(result.message)
    }

    private func reloadState() {
        operationTask?.cancel()
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let state = try await source.loadBisectState()
                guard !Task.isCancelled else { return }
                startButton.isEnabled = !state.isActive
                badButton.isEnabled = state.isActive
                goodButton.isEnabled = state.isActive
                skipButton.isEnabled = state.isActive
                stopButton.isEnabled = state.isActive
                panel?.makeFirstResponder(state.isActive ? badButton : startButton)
            } catch {
                setButtonsEnabled(false)
                await show(error)
            }
        }
    }

    private func setButtonsEnabled(_ enabled: Bool) {
        [startButton, badButton, goodButton, skipButton, stopButton].forEach { $0.isEnabled = enabled }
    }

    private func show(_ error: Error) async {
        guard let panel else { return }
        let alert = NSAlert(error: error)
        alert.messageText = "Bisect failed"
        _ = await alert.beginSheetModal(for: panel)
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        operationTask?.cancel()
        let result = BisectDialog.Result(
            repositoryChanged: repositoryChanged,
            preferredCommitID: preferredCommitID
        )
        guard let panel, let owner = panel.sheetParent else {
            completion(result)
            return
        }
        owner.endSheet(panel)
        completion(result)
    }
}
