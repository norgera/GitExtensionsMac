import GitExtensionsCore
import GitCommands
import AppKit

@MainActor
final class GitUICommands {
    private let repositoryModule: any RepositoryBrowsingDataSource
    private weak var browser: RepositoryBrowserViewController?
    let repositoryChangedNotifier: RepositoryChangedNotifier
    private var remoteWindowController: NSWindowController?

    init(
        repositoryModule: any RepositoryBrowsingDataSource,
        browser: RepositoryBrowserViewController
    ) {
        self.repositoryModule = repositoryModule
        self.browser = browser
        repositoryChangedNotifier = RepositoryChangedNotifier {}
    }

    func perform(
        changesRepositoryState: Bool,
        action: @MainActor () async throws -> Bool
    ) async throws -> Bool {
        repositoryChangedNotifier.lock()
        defer { repositoryChangedNotifier.unlock(requestNotify: false) }
        let succeeded = try await action()
        if succeeded && changesRepositoryState {
            repositoryChangedNotifier.notify()
        }
        return succeeded
    }

    func notifyRepositoryChanged(preferredCommitID: RevisionID? = nil) {
        browser?.prepareNotifierRefresh(preferredCommitID: preferredCommitID)
        repositoryChangedNotifier.notify()
    }

    func startCommit(
        initialMode: RepositoryCommitMode = .normal,
        specialKind: CommitWorkflowSpecialKind? = nil
    ) {
        guard let browser,
              let identity = browser.repositoryIdentity,
              !identity.currentRepository.isBare,
              let window = browser.view.window,
              let source = repositoryModule as? any RepositoryCommitWorkflowDataSource else {
            browser?.showPlaceholderStatus("Commit is unavailable for mock data")
            return
        }

        if let existing = browser.commitWindowController {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let head = browser.revisions.first(where: \.isHEAD)
            ?? browser.revisions.first(where: { !$0.isArtificial })
        browser.commitWindowController = browser.presentCommitDialog(
            source: source,
            pushSource: repositoryModule as? any RepositoryPushingDataSource,
            initialMode: initialMode,
            specialKind: specialKind,
            head: head,
            draft: browser.commitDraft,
            owner: window,
            previousSelection: browser.selectedCommitID
        )
    }

    func startPull(action: PullActionPreference, immediately: Bool) {
        guard let browser, let context = browser.networkContext else { return }
        let effectiveAction = action == .openDialog ? AppSettingsStore.shared.pullPreferences.formAction : action
        let initialAction: NetworkDialogInitialAction = switch effectiveAction {
        case .rebase: .rebase
        case .fetch: .fetch
        case .fetchAll: .fetchAll
        case .fetchPruneAll: .fetchPruneAll
        case .merge, .openDialog: .merge
        }
        let isFetch = initialAction == .fetch || initialAction == .fetchAll || initialAction == .fetchPruneAll
        if let existing = browser.pullWindowController ?? browser.fetchWindowController {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard browser.view.window != nil,
              let source = repositoryModule as? any RepositoryPullingDataSource else { return }
        let controller = ApplicationShellDialogs.presentPullWindow(
            initialAction: initialAction,
            executeImmediately: immediately,
            context: context,
            source: source,
            onRepositoryChanged: { [weak self, weak browser] selected in
                self?.notifyRepositoryChanged(preferredCommitID: selected ?? browser?.selectedCommitID)
            },
            onClose: { [weak browser] in
                browser?.pullWindowController = nil
                browser?.fetchWindowController = nil
            }
        )
        if isFetch {
            browser.fetchWindowController = controller
        } else {
            browser.pullWindowController = controller
        }
    }

    func startFetchAll(prune: Bool) {
        startPull(action: prune ? .fetchPruneAll : .fetchAll, immediately: true)
    }

    func startRemoteManagement(selectedRemote: String? = nil) {
        if let remoteWindowController {
            remoteWindowController.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard let browser,
              let source = repositoryModule as? any RepositoryRemoteManagingDataSource else {
            browser?.showPlaceholderStatus("Remote management is unavailable for this data source.")
            return
        }

        remoteWindowController = RemoteManagementDialog.present(
            source: source,
            selectedRemote: selectedRemote,
            onRepositoryChanged: { [weak self, weak browser] in
                self?.notifyRepositoryChanged(preferredCommitID: browser?.selectedCommitID)
            },
            onClose: { [weak self] in
                self?.remoteWindowController = nil
            }
        )
    }

    func startPush(
        immediately: Bool = false,
        initialBranch: String? = nil,
        forceWithLease: Bool = false
    ) {
        guard let browser,
              let context = browser.networkContext,
              browser.view.window != nil,
              let source = repositoryModule as? any RepositoryPushingDataSource else { return }

        if let existing = browser.pushWindowController {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        browser.pushWindowController = PushDialog.present(
            source: source,
            context: context,
            initialBranch: initialBranch,
            executeImmediately: immediately,
            initialForceWithLease: forceWithLease,
            onRepositoryChanged: { [weak self, weak browser] preferredCommitID in
                self?.notifyRepositoryChanged(preferredCommitID: preferredCommitID ?? browser?.selectedCommitID)
            },
            onClose: { [weak browser] in
                browser?.pushWindowController = nil
            }
        )
    }

    func startMergeBranches(initialTarget: String?) {
        guard let browser,
              let context = browser.mergeContext,
              !context.repository.isBare else {
            browser?.showPlaceholderStatus("Merge is unavailable for this repository")
            return
        }
        if let existing = browser.mergeWindowController {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard let window = browser.view.window,
              let source = repositoryModule as? any RepositoryMergingDataSource else { return }
        browser.mergeWindowController = browser.presentMergeDialog(
            source: source,
            context: context,
            initialTarget: initialTarget,
            previousSelection: browser.selectedCommitID,
            owner: window
        )
    }

    func startCherryPick(_ selectedCommits: [Commit]) {
        guard let browser,
              browser.repositoryIdentity != nil,
              let window = browser.view.window,
              let source = repositoryModule as? any RepositoryCherryPickDataSource else {
            browser?.showPlaceholderStatus("Cherry-pick is unavailable for mock data")
            return
        }

        let historyIndex = Dictionary(uniqueKeysWithValues: browser.revisions.enumerated().map { ($0.element.id, $0.offset) })
        let ordered = selectedCommits
            .filter { !$0.isArtificial }
            .sorted { (historyIndex[$0.id] ?? 0) > (historyIndex[$1.id] ?? 0) }
        guard !ordered.isEmpty else { return }

        browser.startCherryPickWorkflow(
            orderedRevisions: ordered,
            history: browser.revisions,
            mutationSource: source,
            window: window,
            previousSelection: browser.selectedCommitID
        )
    }

    func startRebase(on target: Commit, interactive: Bool, showAdvancedOptions: Bool) {
        startRebase(
            on: target,
            interactive: interactive,
            initialActions: [:],
            advancedFrom: nil,
            showAdvancedOptions: showAdvancedOptions
        )
    }

    func startRebase(
        on target: Commit,
        interactive: Bool,
        initialActions: [ObjectID: RepositoryRebaseTodoAction] = [:],
        advancedFrom: String? = nil,
        showAdvancedOptions: Bool = false
    ) {
        guard let browser,
              let window = browser.view.window,
              let source = repositoryModule as? any RepositoryRebaseDataSource else {
            browser?.showPlaceholderStatus("Rebase is unavailable for mock data")
            return
        }
        browser.startRebaseWorkflow(
            on: target,
            interactive: interactive,
            initialActions: initialActions,
            advancedFrom: advancedFrom,
            showAdvancedOptions: showAdvancedOptions,
            mutationSource: source,
            window: window,
            previousSelection: browser.selectedCommitID
        )
    }

    func startCheckoutBranch(initialTarget: CheckoutDialogTarget?, confirmDirectCheckout: Bool = false) {
        makeCheckoutWorkflowCoordinator()?.checkoutBranch(
            initialTarget: initialTarget,
            confirmDirectCheckout: confirmDirectCheckout
        )
    }

    func startCheckoutRevision(_ commit: Commit) {
        makeCheckoutWorkflowCoordinator()?.checkoutRevision(commit)
    }

    func checkout(_ target: CheckoutDialogTarget, confirmDirectCheckout: Bool = false) {
        makeCheckoutWorkflowCoordinator()?.checkout(
            target,
            confirmDirectCheckout: confirmDirectCheckout
        )
    }

    func fetchRemoteBranch(
        _ branch: Branch,
        then followUp: CheckoutBranchFetchFollowUp
    ) {
        makeCheckoutWorkflowCoordinator()?.fetchRemoteBranch(branch, then: followUp)
    }

    func createBranch(sourceRevision: Commit?, suggestedPrefix: String? = nil) {
        makeCheckoutWorkflowCoordinator()?.createBranch(
            sourceRevision: sourceRevision,
            suggestedPrefix: suggestedPrefix
        )
    }

    func deleteBranches(initiallySelected: [String]) {
        makeCheckoutWorkflowCoordinator()?.deleteBranches(initiallySelected: initiallySelected)
    }

    func renameBranch(_ name: String) {
        makeCheckoutWorkflowCoordinator()?.renameBranch(name)
    }

    private func makeCheckoutWorkflowCoordinator() -> CheckoutBranchWorkflowCoordinator? {
        guard let browser,
              let context = browser.branchContext,
              let window = browser.view.window,
              let source = repositoryModule as? any RepositoryCheckoutBranchDataSource else {
            return nil
        }
        let coordinator = CheckoutBranchWorkflowCoordinator(
            source: source,
            stashSource: repositoryModule as? any RepositoryStashDataSource,
            pullSource: repositoryModule as? any RepositoryPullingDataSource,
            context: context,
            revisions: browser.revisions,
            owner: window,
            onRepositoryChanged: { [weak self, weak browser] selectedCommitID in
                self?.notifyRepositoryChanged(preferredCommitID: selectedCommitID ?? browser?.selectedCommitID)
            },
            onStatus: { [weak browser] message in
                browser?.statusLabel.stringValue = message
            },
            onConflicts: { [weak self] in
                self?.startConflictResolution()
            }
        )
        browser.checkoutBranchWorkflowCoordinator = coordinator
        return coordinator
    }

    func startConflictResolution(offerCommit: Bool = true) {
        guard let browser,
              let window = browser.view.window,
              let source = repositoryModule as? any RepositoryConflictResolutionDataSource else {
            browser?.showPlaceholderStatus("Conflict resolver is unavailable for mock data")
            return
        }

        Task { @MainActor [weak browser] in
            guard let browser else { return }
            let refreshed = await WorkflowManagementDialogs.resolveConflicts(
                source: source,
                window: window
            )
            if refreshed {
                self.notifyRepositoryChanged(preferredCommitID: browser.selectedCommitID)
            }
        }
    }

    func startStashManagement(manageStashes: Bool = true, initialStash: String? = nil) {
        guard let browser,
              let context = browser.stashContext,
              let window = browser.view.window,
              let source = repositoryModule as? any RepositoryStashWorkflowDataSource else {
            browser?.showPlaceholderStatus("Stash manager is unavailable for mock data")
            return
        }

        Task { @MainActor [weak browser] in
            guard let browser else { return }
            let result = await WorkflowManagementDialogs.manageStashes(
                source: source,
                context: context,
                window: window,
                manageStashes: manageStashes,
                initialStash: initialStash
            )
            if result.repositoryChanged {
                self.notifyRepositoryChanged(
                    preferredCommitID: result.selectedCommitID ?? browser.selectedCommitID
                )
            }
        }
    }

}
