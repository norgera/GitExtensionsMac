import GitExtensionsCore
import GitCommands
import AppKit

struct CheckoutBranchDialogResult {
    let request: RepositoryCheckoutRequest
    let needsAutoPopPrompt: Bool
}

@MainActor
enum CheckoutBranchDialogs {
    static func checkoutBranch(
        source: any RepositoryCheckoutBranchDataSource,
        context: RepositoryBranchContext,
        revisions: [Commit],
        state: RepositoryMutationState,
        initialTarget: CheckoutDialogTarget?,
        updateSubmodules: Bool,
        owner: NSWindow
    ) async -> CheckoutBranchDialogResult? {
        let controller = CheckoutBranchViewController(
            context: context,
            state: state,
            source: source,
            initialTarget: initialTarget,
            updateSubmodules: updateSubmodules
        )
        return await present(
            controller,
            title: "Checkout branch",
            size: NSSize(width: AppSettingsStore.shared.checkoutBranchPreferences.checkoutWindowWidth, height: 260),
            minimumSize: NSSize(width: 626, height: 120),
            owner: owner
        )
    }

    static func checkoutRevision(
        commit: Commit,
        revisions: [Commit],
        source: any RepositoryCheckoutBranchDataSource,
        updateSubmodules: Bool,
        owner: NSWindow
    ) async -> RepositoryCheckoutRequest? {
        let controller = CheckoutRevisionViewController(
            commit: commit,
            revisions: revisions,
            source: source,
            updateSubmodules: updateSubmodules
        )
        return await present(
            controller,
            title: "Checkout revision",
            size: NSSize(width: 481, height: 131),
            minimumSize: NSSize(width: 460, height: 125),
            owner: owner
        )
    }

    static func createBranch(
        source: any RepositoryCheckoutBranchDataSource,
        context: RepositoryBranchContext,
        revisions: [Commit],
        sourceRevision: Commit?,
        suggestedPrefix: String? = nil,
        isUnbornRepository: Bool,
        updateSubmodules: Bool,
        owner: NSWindow
    ) async -> RepositoryCreateBranchRequest? {
        let controller = CreateBranchViewController(
            context: context,
            revisions: revisions,
            source: source,
            sourceRevision: sourceRevision,
            suggestedPrefix: suggestedPrefix,
            isUnbornRepository: isUnbornRepository,
            updateSubmodules: updateSubmodules
        )
        return await present(
            controller,
            title: "Create branch",
            size: NSSize(width: AppSettingsStore.shared.checkoutBranchPreferences.createWindowWidth, height: 386),
            minimumSize: NSSize(width: 580, height: 425),
            owner: owner
        )
    }

    static func deleteBranches(
        availableBranches: [Branch],
        initiallySelected: [String],
        owner: NSWindow
    ) async -> [String]? {
        let controller = DeleteBranchViewController(
            branches: availableBranches.filter { !$0.isRemote },
            initiallySelected: initiallySelected
        )
        return await present(
            controller,
            title: "Delete branch",
            size: NSSize(width: AppSettingsStore.shared.checkoutBranchPreferences.deleteWindowWidth, height: 91),
            minimumSize: NSSize(width: 420, height: 130),
            owner: owner
        )
    }

    static func renameBranch(
        name: String,
        existingNames: Set<String>,
        source: any RepositoryCheckoutBranchDataSource,
        owner: NSWindow
    ) async -> RepositoryRenameBranchRequest? {
        let controller = RenameBranchViewController(name: name, existingNames: existingNames, source: source)
        return await present(
            controller,
            title: "Rename branch",
            size: NSSize(width: AppSettingsStore.shared.checkoutBranchPreferences.renameWindowWidth, height: 42),
            minimumSize: NSSize(width: 400, height: 80),
            owner: owner
        )
    }

    private static func present<Result>(
        _ controller: BranchFormViewController<Result>,
        title: String,
        size: NSSize,
        minimumSize: NSSize,
        owner: NSWindow
    ) async -> Result? {
        let panel = NSPanel(contentViewController: controller)
        panel.title = title
        panel.styleMask = [.titled, .closable, .resizable]
        panel.setContentSize(size)
        panel.minSize = minimumSize
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isReleasedWhenClosed = false
        controller.panel = panel
        return await withCheckedContinuation { continuation in
            controller.onClose = { result in
                owner.endSheet(panel)
                continuation.resume(returning: result)
            }
            owner.beginSheet(panel)
        }
    }
}

@MainActor
private class BranchFormViewController<Result>: NSViewController, NSWindowDelegate {
    weak var panel: NSPanel?
    var onClose: ((Result?) -> Void)?
    private var didClose = false
    private var fixedFrameHeight: CGFloat?

    func finish(_ result: Result?) {
        guard !didClose else { return }
        didClose = true
        persistWindowWidth()
        onClose?(result)
        onClose = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(nil)
        return false
    }

    override func cancelOperation(_ sender: Any?) { finish(nil) }

    func configurePanel() {
        panel?.delegate = self
    }

    func windowDidEndLiveResize(_ notification: Notification) { persistWindowWidth() }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard let fixedFrameHeight else { return frameSize }
        return NSSize(width: frameSize.width, height: fixedFrameHeight)
    }

    func setFixedContentHeight(_ height: CGFloat) {
        guard let panel else { return }
        panel.setContentSize(NSSize(width: panel.contentView?.bounds.width ?? panel.frame.width, height: height))
        fixedFrameHeight = panel.frame.height
    }

    private func persistWindowWidth() {
        guard let panel else { return }
        var preferences = AppSettingsStore.shared.checkoutBranchPreferences
        switch panel.title {
        case "Checkout branch": preferences.checkoutWindowWidth = panel.frame.width
        case "Create branch": preferences.createWindowWidth = panel.frame.width
        case "Delete branch": preferences.deleteWindowWidth = panel.frame.width
        case "Rename branch": preferences.renameWindowWidth = panel.frame.width
        default: return
        }
        AppSettingsStore.shared.saveCheckoutBranchPreferences(preferences)
    }
}

@MainActor
private final class CheckoutBranchViewController: BranchFormViewController<CheckoutBranchDialogResult>, NSComboBoxDelegate {
    private let context: RepositoryBranchContext
    private let state: RepositoryMutationState
    private let source: any RepositoryCheckoutBranchDataSource
    private let updateSubmodules: Bool
    private let localBranches: [Branch]
    private let remoteBranches: [Branch]
    private let localRadio = NSButton(radioButtonWithTitle: "Local branch", target: nil, action: nil)
    private let remoteRadio = NSButton(radioButtonWithTitle: "Remote branch", target: nil, action: nil)
    private let branches = NSComboBox()
    private let resetRemote = NSButton(radioButtonWithTitle: "Reset local branch with the name", target: nil, action: nil)
    private let customRemote = NSButton(radioButtonWithTitle: "Create local branch with custom name", target: nil, action: nil)
    private let detachedRemote = NSButton(radioButtonWithTitle: "Checkout the commit (in detached head)", target: nil, action: nil)
    private let customName = NSTextField(string: "")
    private let remoteOptions = NSStackView()
    private let changesGroup = NSBox()
    private let keepChanges = NSButton(radioButtonWithTitle: "Don’t change", target: nil, action: nil)
    private let mergeChanges = NSButton(radioButtonWithTitle: "Merge", target: nil, action: nil)
    private let stashChanges = NSButton(radioButtonWithTitle: "Stash", target: nil, action: nil)
    private let forceChanges = NSButton(radioButtonWithTitle: "Reset", target: nil, action: nil)
    private let setDefault = NSButton(checkboxWithTitle: "Set as default", target: nil, action: nil)
    private let checkoutButton = NSButton(title: "Checkout", target: nil, action: nil)
    private let validation = NSTextField(labelWithString: "")
    private let aheadBehind = NSTextField(labelWithString: "")
    private let contentStack = NSStackView()
    private var divergenceTask: Task<Void, Never>?

    init(
        context: RepositoryBranchContext,
        state: RepositoryMutationState,
        source: any RepositoryCheckoutBranchDataSource,
        initialTarget: CheckoutDialogTarget?,
        updateSubmodules: Bool
    ) {
        self.context = context
        self.state = state
        self.source = source
        self.updateSubmodules = updateSubmodules
        localBranches = context.branches.filter { !$0.isRemote }
        remoteBranches = context.remotes.flatMap(\.branches)
        super.init(nibName: nil, bundle: nil)

        switch initialTarget {
        case .remote(let branch):
            remoteRadio.state = .on
            branches.stringValue = Self.fullName(branch)
        case .local(let branch):
            localRadio.state = .on
            branches.stringValue = branch.name
        default:
            localRadio.state = .on
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit { divergenceTask?.cancel() }

    override func loadView() {
        let root = NSView()
        localRadio.target = self; localRadio.action = #selector(branchKindChanged)
        remoteRadio.target = self; remoteRadio.action = #selector(branchKindChanged)
        let branchTypeSpacer = NSView()
        branchTypeSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let branchTypeRow = NSStackView(views: [localRadio, remoteRadio, branchTypeSpacer])
        branchTypeRow.orientation = .horizontal; branchTypeRow.alignment = .centerY; branchTypeRow.spacing = 12
        branches.completes = true
        branches.delegate = self
        branches.target = self; branches.action = #selector(branchSelectionChanged)
        branches.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        aheadBehind.textColor = .secondaryLabelColor
        aheadBehind.alignment = .left
        aheadBehind.setContentHuggingPriority(.required, for: .horizontal)
        let selectorRow = NSStackView(views: [NSTextField(labelWithString: "Select branch"), branches, aheadBehind])
        selectorRow.orientation = .horizontal; selectorRow.alignment = .centerY; selectorRow.spacing = 8
        let separator = NSBox()
        separator.boxType = .separator

        [resetRemote, customRemote, detachedRemote].forEach {
            $0.target = self; $0.action = #selector(remoteModeChanged(_:))
        }
        resetRemote.state = AppSettingsStore.shared.checkoutBranchPreferences.createLocalBranchForRemote ? .off : .on
        customRemote.state = AppSettingsStore.shared.checkoutBranchPreferences.createLocalBranchForRemote ? .on : .off
        remoteOptions.orientation = .vertical; remoteOptions.alignment = .leading; remoteOptions.spacing = 5
        remoteOptions.addArrangedSubview(resetRemote)
        let customRow = NSStackView(views: [customRemote, customName])
        customRow.orientation = .horizontal; customRow.spacing = 6; customRow.alignment = .centerY
        customName.widthAnchor.constraint(equalToConstant: 210).isActive = true
        customName.target = self; customName.action = #selector(validateForm)
        remoteOptions.addArrangedSubview(customRow)
        remoteOptions.addArrangedSubview(detachedRemote)

        [keepChanges, mergeChanges, stashChanges, forceChanges].forEach {
            $0.target = self; $0.action = #selector(changesModeChanged)
        }
        switch AppSettingsStore.shared.checkoutBranchPreferences.localChangesAction {
        case .keep: keepChanges.state = .on
        case .merge: mergeChanges.state = .on
        case .stash: stashChanges.state = .on
        case .force: forceChanges.state = .on
        }
        let changeRow = NSStackView(views: [keepChanges, mergeChanges, stashChanges, forceChanges, setDefault])
        changeRow.orientation = .horizontal; changeRow.spacing = 12; changeRow.alignment = .centerY
        changesGroup.title = "Local changes"
        changesGroup.contentView = padded(changeRow, x: 10, y: 8)
        changesGroup.isHidden = !state.isDirty
            && AppSettingsStore.shared.checkoutBranchPreferences.checkForUncommittedChanges

        validation.textColor = .systemRed
        validation.lineBreakMode = .byTruncatingTail
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        checkoutButton.target = self; checkoutButton.action = #selector(checkout)
        checkoutButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [validation, spacer, checkoutButton])
        buttons.orientation = .horizontal; buttons.alignment = .centerY; buttons.spacing = 8

        [branchTypeRow, selectorRow, separator, remoteOptions, changesGroup, buttons].forEach {
            contentStack.addArrangedSubview($0)
        }
        contentStack.orientation = .vertical; contentStack.alignment = .leading; contentStack.spacing = 8
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            contentStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            contentStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -14),
            branchTypeRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            selectorRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            changesGroup.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: contentStack.widthAnchor)
        ])
        view = root
        branchKindChanged()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        configurePanel()
        panel?.makeFirstResponder(branches)
        if branches.stringValue.isEmpty { branches.performClick(nil) }
        updatePanelHeight()
    }

    func comboBoxSelectionDidChange(_ notification: Notification) { branchSelectionChanged() }
    func controlTextDidChange(_ obj: Notification) { branchSelectionChanged() }

    @objc private func branchKindChanged() {
        let remote = remoteRadio.state == .on
        localRadio.state = remote ? .off : .on
        let values = remote ? remoteBranches.map(Self.fullName) : localBranches.map(\.name)
        let previous = branches.stringValue
        branches.removeAllItems()
        branches.addItems(withObjectValues: values)
        branches.stringValue = values.contains(previous) ? previous : ""
        remoteOptions.isHidden = !remote
        branchSelectionChanged()
        updatePanelHeight()
    }

    @objc private func branchSelectionChanged() {
        updateDivergence()
        guard remoteRadio.state == .on else { validateForm(); return }
        let selected = selectedRemote
        let tracking = selected.flatMap(trackingLocalBranch)
        let sameName = selected?.name ?? ""
        let resetName = tracking?.name ?? sameName
        let exists = localBranches.contains { $0.name.caseInsensitiveCompare(resetName) == .orderedSame }
        resetRemote.title = exists
            ? "Reset local branch with the name: ‘\(resetName)’"
            : "Create local branch with same name: ‘\(resetName)’"
        customName.stringValue = suggestedCustomName(for: selected)
        remoteModeChanged(nil)
    }

    @objc private func remoteModeChanged(_ sender: NSButton?) {
        if let sender {
            resetRemote.state = sender === resetRemote ? .on : .off
            customRemote.state = sender === customRemote ? .on : .off
            detachedRemote.state = sender === detachedRemote ? .on : .off
        }
        customName.isEnabled = customRemote.state == .on
        validateForm()
    }

    @objc private func changesModeChanged() {
        setDefault.isEnabled = forceChanges.state != .on
        if !setDefault.isEnabled { setDefault.state = .off }
    }

    @objc private func validateForm() {
        checkoutButton.isEnabled = true
        validation.stringValue = ""
    }

    @objc private func checkout() {
        if remoteRadio.state == .on {
            guard selectedRemote != nil else {
                validation.stringValue = "Select an existing branch."
                return
            }
            if customRemote.state == .on,
               customName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                validation.stringValue = "Enter a custom local branch name."
                return
            }
        } else if !localBranches.contains(where: { $0.name == branches.stringValue }) {
            validation.stringValue = "Select an existing branch."
            return
        }
        if remoteRadio.state == .on,
           let selected = selectedRemote,
           detachedRemote.state != .on {
            let localName = customRemote.state == .on
                ? normalizedBranchName(customName.stringValue)
                : trackingLocalBranch(selected)?.name ?? selected.name
            if customRemote.state == .on { customName.stringValue = localName }
            checkoutButton.isEnabled = false
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    guard try await source.isValidBranchName(localName) else {
                        validation.stringValue = "‘\(localName)’ is not a valid local branch name."
                        checkoutButton.isEnabled = true
                        return
                    }
                    completeCheckout()
                } catch {
                    validation.stringValue = error.localizedDescription
                    checkoutButton.isEnabled = true
                }
            }
            return
        }
        completeCheckout()
    }

    private func completeCheckout() {
        let target: RepositoryCheckoutTarget
        if remoteRadio.state == .on {
            guard let selected = selectedRemote, let remote = selected.remoteName else { validateForm(); return }
            let mode: RemoteCheckoutMode
            if detachedRemote.state == .on {
                mode = .detached
            } else if customRemote.state == .on {
                mode = .createTracking(localBranch: normalizedBranchName(customName.stringValue))
            } else {
                mode = .resetTracking(localBranch: trackingLocalBranch(selected)?.name ?? selected.name)
            }
            target = .remoteBranch(remote: remote, branch: selected.name, mode: mode)
        } else {
            guard localBranches.contains(where: { $0.name == branches.stringValue }) else { validateForm(); return }
            target = .localBranch(branches.stringValue)
        }

        let action: CheckoutLocalChangesAction
        let preference: CheckoutLocalChangesPreference
        let autoPop = AppSettingsStore.shared.checkoutBranchPreferences.autoPopStash
        if mergeChanges.state == .on {
            action = .merge; preference = .merge
        } else if stashChanges.state == .on {
            action = .stash(
                includeUntracked: AppSettingsStore.shared.pullPreferences.includeUntrackedInAutoStash,
                reapply: autoPop == .always
            )
            preference = .stash
        } else if forceChanges.state == .on {
            action = .force; preference = .force
        } else {
            action = .keep; preference = .keep
        }
        if setDefault.state == .on {
            var preferences = AppSettingsStore.shared.checkoutBranchPreferences
            preferences.localChangesAction = preference
            AppSettingsStore.shared.saveCheckoutBranchPreferences(preferences)
        }
        finish(CheckoutBranchDialogResult(
            request: RepositoryCheckoutRequest(
                target: target,
                localChanges: action,
                updateSubmodulesAfterCheckout: updateSubmodules
            ),
            needsAutoPopPrompt: preference == .stash && autoPop == .ask
        ))
    }

    private var selectedRemote: Branch? {
        remoteBranches.first { Self.fullName($0) == branches.stringValue }
    }

    private func normalizedBranchName(_ value: String) -> String {
        let preferences = AppSettingsStore.shared.checkoutBranchPreferences
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard preferences.autoNormaliseBranchName else { return trimmed }
        return RepositoryBranchNameNormalizer.normalize(
            trimmed,
            replacementToken: preferences.branchNameReplacement
        )
    }

    private func trackingLocalBranch(_ remote: Branch) -> Branch? {
        guard let remoteName = remote.remoteName else { return nil }
        return localBranches.first { local in
            context.referencesByCommit[local.commitID]?.contains { reference in
                (reference.kind == .currentBranch || reference.kind == .localBranch)
                    && reference.name == local.name
                    && reference.trackingRemote == remoteName
                    && reference.mergeWith == remote.name
            } == true
        }
    }

    private func suggestedCustomName(for remote: Branch?) -> String {
        guard let remote, let remoteName = remote.remoteName else { return "" }
        let base = "\(remoteName)_\(remote.name)"
        if !localBranches.contains(where: { $0.name.caseInsensitiveCompare(base) == .orderedSame }) { return base }
        var suffix = 2
        while localBranches.contains(where: { $0.name.caseInsensitiveCompare("\(base)_\(suffix)") == .orderedSame }) { suffix += 1 }
        return "\(base)_\(suffix)"
    }

    private func updatePanelHeight() {
        view.layoutSubtreeIfNeeded()
        setFixedContentHeight(ceil(contentStack.fittingSize.height) + 28)
    }

    private func updateDivergence() {
        divergenceTask?.cancel()
        aheadBehind.stringValue = ""
        guard let headID = context.headID else { return }
        let target: ObjectID?
        if remoteRadio.state == .on {
            target = selectedRemote?.commitID
        } else {
            target = localBranches.first(where: { $0.name == branches.stringValue })?.commitID
        }
        guard let target else { return }
        let selectedValue = branches.stringValue
        divergenceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let value = try await source.divergence(from: headID, to: target)
                guard !Task.isCancelled, branches.stringValue == selectedValue else { return }
                aheadBehind.stringValue = value.displayText
            } catch {
                guard !Task.isCancelled, branches.stringValue == selectedValue else { return }
                aheadBehind.stringValue = ""
            }
        }
    }

    private static func fullName(_ branch: Branch) -> String {
        branch.remoteName.map { "\($0)/\(branch.name)" } ?? branch.name
    }
}

@MainActor
private final class CheckoutRevisionViewController: BranchFormViewController<RepositoryCheckoutRequest>, NSComboBoxDelegate {
    private let revisions: [Commit]
    private let source: any RepositoryCheckoutBranchDataSource
    private let updateSubmodules: Bool
    private let revision = NSComboBox()
    private let force = NSButton(checkboxWithTitle: "Force (reset local changes)", target: nil, action: nil)
    private let checkout = NSButton(title: "Checkout", target: nil, action: nil)
    private let validation = NSTextField(labelWithString: "")

    init(
        commit: Commit,
        revisions: [Commit],
        source: any RepositoryCheckoutBranchDataSource,
        updateSubmodules: Bool
    ) {
        self.revisions = revisions
        self.source = source
        self.updateSubmodules = updateSubmodules
        super.init(nibName: nil, bundle: nil)
        revision.stringValue = "\(commit.shortID)  \(commit.subject)"
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        revision.addItems(withObjectValues: revisions.filter { !$0.isArtificial }.map {
            "\($0.shortID)  \($0.subject)"
        })
        revision.completes = true
        revision.delegate = self
        revision.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        checkout.target = self
        checkout.action = #selector(accept)
        checkout.keyEquivalent = "\r"
        validation.textColor = .systemRed
        validation.lineBreakMode = .byTruncatingTail
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [validation, spacer, checkout])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        let content = NSStackView(views: [
            labeled("Checkout this revision:", revision),
            force,
            buttons
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        pin(content, in: root, inset: 14)
        buttons.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        view = root
        validateForm()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        configurePanel()
        panel?.makeFirstResponder(revision)
        revision.selectText(nil)
    }

    func controlTextDidChange(_ obj: Notification) { validateForm() }
    func comboBoxSelectionDidChange(_ notification: Notification) { validateForm() }

    @objc private func accept() {
        validateForm()
        guard checkout.isEnabled else { return }
        let selected = selectedRevision
        checkout.isEnabled = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard try await source.isValidRevision(selected) else {
                    validation.stringValue = "Select an existing revision."
                    checkout.isEnabled = true
                    return
                }
                finish(RepositoryCheckoutRequest(
                    target: .revision(selected),
                    localChanges: force.state == .on ? .force : .keep,
                    updateSubmodulesAfterCheckout: updateSubmodules
                ))
            } catch {
                validation.stringValue = error.localizedDescription
                checkout.isEnabled = true
            }
        }
    }

    private func validateForm() {
        checkout.isEnabled = true
        validation.stringValue = ""
    }

    private var selectedRevision: String {
        let value = revision.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = value.split(separator: " ", maxSplits: 1).first.map(String.init) ?? value
        return revisions.first { $0.shortID == prefix || $0.id.description == prefix }?.objectID?.string ?? prefix
    }
}

@MainActor
private final class CreateBranchViewController: BranchFormViewController<RepositoryCreateBranchRequest>, NSComboBoxDelegate {
    private let context: RepositoryBranchContext
    private let revisions: [Commit]
    private let sourceCapability: any RepositoryCheckoutBranchDataSource
    private let initialRevision: Commit?
    private let updateSubmodules: Bool
    private let isUnbornRepository: Bool
    private let name: NSTextField
    private let source = NSComboBox()
    private let sourceCaption = NSTextField(labelWithString: "Create branch at this revision:")
    private let checkout = NSButton(checkboxWithTitle: "Checkout after create", target: nil, action: nil)
    private let orphan = NSButton(checkboxWithTitle: "Create orphan", target: nil, action: nil)
    private let clear = NSButton(checkboxWithTitle: "Clear working directory and index", target: nil, action: nil)
    private let create = NSButton(title: "Create branch", target: nil, action: nil)
    private let validation = NSTextField(labelWithString: "")
    private let summary = CommitSummaryView()

    init(context: RepositoryBranchContext, revisions: [Commit], source: any RepositoryCheckoutBranchDataSource, sourceRevision: Commit?, suggestedPrefix: String?, isUnbornRepository: Bool, updateSubmodules: Bool) {
        self.context = context; self.revisions = revisions; self.sourceCapability = source; initialRevision = sourceRevision; self.isUnbornRepository = isUnbornRepository; self.updateSubmodules = updateSubmodules
        name = NSTextField(string: suggestedPrefix ?? Self.suggestedName(from: sourceRevision))
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        source.addItems(withObjectValues: revisions.filter { !$0.isArtificial }.map { "\($0.shortID)  \($0.subject)" })
        source.stringValue = initialRevision.map { "\($0.shortID)  \($0.subject)" } ?? "HEAD"
        source.completes = true
        source.delegate = self
        source.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        checkout.state = .on
        orphan.target = self; orphan.action = #selector(orphanChanged)
        clear.state = .on; clear.isEnabled = false
        if isUnbornRepository {
            source.isHidden = true
            sourceCaption.stringValue = "Creating orphan branch (repository has no commits)"
            orphan.state = .on
            orphan.isEnabled = false
            clear.state = .off
            clear.isEnabled = false
            checkout.state = .on
            checkout.isEnabled = false
        }
        create.target = self; create.action = #selector(accept); create.keyEquivalent = "\r"
        name.delegate = self
        validation.textColor = .systemRed
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [validation, spacer, create]); buttons.orientation = .horizontal; buttons.spacing = 8
        let orphanBox = NSBox(); orphanBox.title = "Orphan branch"
        let orphanStack = NSStackView(views: [orphan, clear]); orphanStack.orientation = .vertical; orphanStack.alignment = .leading; orphanStack.spacing = 5
        orphanBox.contentView = padded(orphanStack, x: 10, y: 8)
        let sourceRow = NSStackView(views: [sourceCaption, source])
        sourceRow.orientation = .horizontal; sourceRow.alignment = .centerY; sourceRow.spacing = 8
        let content = NSStackView(views: [
            labeled("Branch name:", name),
            sourceRow,
            checkout,
            summary,
            orphanBox,
            buttons
        ])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 12
        pin(content, in: root, inset: 14)
        summary.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        summary.heightAnchor.constraint(greaterThanOrEqualToConstant: 122).isActive = true
        orphanBox.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        buttons.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        view = root
        updateSummary()
        validateForm()
    }
    override func viewDidAppear() { super.viewDidAppear(); configurePanel(); panel?.makeFirstResponder(name); name.selectText(nil) }
    @objc private func orphanChanged() {
        clear.isEnabled = orphan.state == .on
        source.isEnabled = orphan.state != .on
        if orphan.state == .on {
            checkout.state = .on
            checkout.isEnabled = false
        } else {
            checkout.isEnabled = true
        }
        validateForm()
    }
    @objc private func validateForm() {
        create.isEnabled = true
        validation.stringValue = ""
    }
    @objc private func accept() {
        validateForm()
        var branchName = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branchName.isEmpty else {
            validation.stringValue = "Enter a branch name."
            return
        }
        let preferences = AppSettingsStore.shared.checkoutBranchPreferences
        if preferences.autoNormaliseBranchName {
            branchName = RepositoryBranchNameNormalizer.normalize(
                branchName,
                replacementToken: preferences.branchNameReplacement
            )
        }
        if context.branches.contains(where: { !$0.isRemote && $0.name == branchName }) {
            validation.stringValue = "A local branch named ‘\(branchName)’ already exists."
            return
        }
        create.isEnabled = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard try await sourceCapability.isValidBranchName(branchName) else {
                    validation.stringValue = "‘\(branchName)’ is not a valid local branch name."
                    create.isEnabled = true
                    return
                }
                if let revision = selectedRevision,
                   !(try await sourceCapability.isValidRevision(revision)) {
                    validation.stringValue = "Select an existing revision."
                    create.isEnabled = true
                    return
                }
                finish(RepositoryCreateBranchRequest(
                    name: branchName,
                    sourceRevision: selectedRevision,
                    checkoutAfterCreation: orphan.state == .on || checkout.state == .on,
                    mode: orphan.state == .on ? .orphan(clearWorkingDirectoryAndIndex: clear.state == .on) : .normal,
                    updateSubmodulesAfterCheckout: updateSubmodules
                ))
            } catch {
                validation.stringValue = error.localizedDescription
                create.isEnabled = true
            }
        }
    }
    func controlTextDidChange(_ obj: Notification) {
        if let field = obj.object as? NSTextField, field === name {
            validateForm()
        } else {
            updateSummary()
        }
    }
    func comboBoxSelectionDidChange(_ notification: Notification) { updateSummary() }
    private var selectedRevision: String? {
        let prefix = source.stringValue.split(separator: " ", maxSplits: 1).first.map(String.init) ?? source.stringValue
        if prefix == "HEAD" || prefix.isEmpty { return nil }
        return revisions.first { $0.shortID == prefix || $0.id.description == prefix }?.objectID?.string ?? prefix
    }
    private func updateSummary() {
        let selected = selectedRevision
        let commit = revisions.first { $0.objectID?.string == selected || $0.shortID == selected }
            ?? (!isUnbornRepository ? revisions.first(where: \.isHEAD) : nil)
        summary.apply(commit)
    }
    private static func suggestedName(from commit: Commit?) -> String {
        commit?.references.first(where: {
            $0.kind == .currentBranch || $0.kind == .localBranch || $0.kind == .remoteBranch || $0.kind == .tag
        })?.localName ?? ""
    }
}

@MainActor
private final class DeleteBranchViewController: BranchFormViewController<[String]>, NSComboBoxDelegate {
    private let branches: [Branch]
    private let selector = NSComboBox()
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private let validation = NSTextField(labelWithString: "")
    private var multipleSelectionPanel: NSPanel?
    private var multipleSelectionController: MultipleBranchSelectionViewController?

    init(branches: [Branch], initiallySelected: [String]) {
        self.branches = branches.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        super.init(nibName: nil, bundle: nil)
        selector.stringValue = initiallySelected.joined(separator: " ")
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        selector.addItems(withObjectValues: branches.map(\.name))
        selector.completes = true
        selector.delegate = self
        selector.widthAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true

        let chooseMultiple = NSButton(
            image: NSImage(
                systemSymbolName: "list.bullet.rectangle",
                accessibilityDescription: "Select multiple branches"
            ) ?? NSImage(),
            target: self,
            action: #selector(selectMultiple)
        )
        chooseMultiple.bezelStyle = .rounded
        chooseMultiple.toolTip = "Select multiple branches"
        let selectorControls = NSStackView(views: [selector, chooseMultiple])
        selectorControls.orientation = .horizontal
        selectorControls.alignment = .centerY
        selectorControls.spacing = 4

        deleteButton.target = self
        deleteButton.action = #selector(accept)
        deleteButton.keyEquivalent = "\r"
        validation.textColor = .systemRed
        validation.lineBreakMode = .byTruncatingTail
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [validation, spacer, deleteButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        let content = NSStackView(views: [
            labeled("Select branches:", selectorControls),
            buttons
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        pin(content, in: root, inset: 10)
        buttons.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        configurePanel()
        panel?.makeFirstResponder(selector)
    }

    func controlTextDidChange(_ obj: Notification) { validation.stringValue = "" }
    func comboBoxSelectionDidChange(_ notification: Notification) { validation.stringValue = "" }

    @objc private func accept() {
        let names = selectedNames
        guard !names.isEmpty else { return }
        let available = Set(branches.map(\.name))
        let invalid = names.filter { !available.contains($0) }
        guard invalid.isEmpty else {
            validation.stringValue = "Branch ‘\(invalid[0])’ is not selectable."
            return
        }
        finish(branches.map(\.name).filter(Set(names).contains))
    }

    @objc private func selectMultiple() {
        guard let panel, multipleSelectionPanel == nil else { return }
        let controller = MultipleBranchSelectionViewController(
            branches: branches,
            selected: Set(selectedNames)
        )
        let child = NSPanel(contentViewController: controller)
        child.title = "Select multiple branches"
        child.styleMask = [.titled, .closable, .resizable]
        child.setContentSize(NSSize(width: 263, height: 252))
        child.minSize = NSSize(width: 200, height: 200)
        child.isReleasedWhenClosed = false
        controller.panel = child
        controller.onClose = { [weak self, weak panel, weak child] selected in
            guard let self, let panel, let child else { return }
            panel.endSheet(child)
            if let selected {
                self.selector.stringValue = selected.joined(separator: " ")
                self.validation.stringValue = ""
            }
            self.multipleSelectionPanel = nil
            self.multipleSelectionController = nil
        }
        multipleSelectionController = controller
        multipleSelectionPanel = child
        panel.beginSheet(child)
    }

    private var selectedNames: [String] {
        var seen = Set<String>()
        return selector.stringValue
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { seen.insert($0).inserted }
    }
}

@MainActor
private final class MultipleBranchSelectionViewController:
    NSViewController,
    NSTableViewDataSource,
    NSTableViewDelegate,
    NSWindowDelegate
{
    let branches: [Branch]
    var selected: Set<String>
    weak var panel: NSPanel?
    var onClose: (([String]?) -> Void)?
    private let table = NSTableView()
    private var didClose = false

    init(branches: [Branch], selected: Set<String>) {
        self.branches = branches
        self.selected = selected
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("branch"))
        table.addTableColumn(column)
        table.headerView = nil
        table.delegate = self
        table.dataSource = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let ok = NSButton(title: "OK", target: self, action: #selector(accept))
        ok.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, ok])
        buttons.orientation = .horizontal
        let content = NSStackView(views: [
            NSTextField(labelWithString: "Select branches"),
            scroll,
            buttons
        ])
        content.orientation = .vertical
        content.spacing = 8
        pin(content, in: root, inset: 12)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        buttons.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        panel?.delegate = self
        panel?.makeFirstResponder(table)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { branches.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let button = NSButton(
            checkboxWithTitle: branches[row].name + (branches[row].isCurrent ? " (current)" : ""),
            target: self,
            action: #selector(toggle(_:))
        )
        button.tag = row
        button.state = selected.contains(branches[row].name) ? .on : .off
        return button
    }

    @objc private func toggle(_ sender: NSButton) {
        let name = branches[sender.tag].name
        if sender.state == .on {
            selected.insert(name)
        } else {
            selected.remove(name)
        }
    }

    @objc private func accept() {
        close(branches.map(\.name).filter(selected.contains))
    }

    override func cancelOperation(_ sender: Any?) { close(nil) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close(nil)
        return false
    }

    private func close(_ value: [String]?) {
        guard !didClose else { return }
        didClose = true
        onClose?(value)
        onClose = nil
    }
}
@MainActor
private final class RenameBranchViewController: BranchFormViewController<RepositoryRenameBranchRequest>, NSTextFieldDelegate {
    private let oldName: String
    private let existingNames: Set<String>
    private let source: any RepositoryCheckoutBranchDataSource
    private let name: NSTextField
    private let renameButton = NSButton(title: "Rename", target: nil, action: nil)
    private let validation = NSTextField(labelWithString: "")
    init(name: String, existingNames: Set<String>, source: any RepositoryCheckoutBranchDataSource) {
        oldName = name; self.existingNames = existingNames; self.source = source
        self.name = NSTextField(string: name); super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        let root = NSView()
        renameButton.target = self; renameButton.action = #selector(accept); renameButton.keyEquivalent = "\r"
        name.delegate = self
        validation.textColor = .systemRed
        validation.lineBreakMode = .byTruncatingTail
        validation.isHidden = true
        let row = NSStackView(views: [NSTextField(labelWithString: "New name:"), name, renameButton]); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 8
        let content = NSStackView(views: [row, validation]); content.orientation = .vertical; content.alignment = .leading; content.spacing = 4
        pin(content, in: root, inset: 10); name.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        view = root
    }
    override func viewDidAppear() { super.viewDidAppear(); configurePanel(); panel?.makeFirstResponder(name); name.selectText(nil) }
    @objc private func accept() {
        var value = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferences = AppSettingsStore.shared.checkoutBranchPreferences
        if preferences.autoNormaliseBranchName {
            value = RepositoryBranchNameNormalizer.normalize(
                value,
                replacementToken: preferences.branchNameReplacement
            )
        }
        guard value != oldName else { finish(nil); return }
        guard !existingNames.contains(value) else {
            showValidation("A local branch named ‘\(value)’ already exists.")
            return
        }
        renameButton.isEnabled = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard try await source.isValidBranchName(value) else {
                    showValidation("‘\(value)’ is not a valid local branch name.")
                    renameButton.isEnabled = true
                    return
                }
                finish(RepositoryRenameBranchRequest(oldName: oldName, newName: value))
            } catch {
                showValidation(error.localizedDescription)
                renameButton.isEnabled = true
            }
        }
    }
    func controlTextDidChange(_ obj: Notification) {
        validation.stringValue = ""
        validation.isHidden = true
        renameButton.isEnabled = true
        panel?.setContentSize(NSSize(width: panel?.contentView?.bounds.width ?? 484, height: 42))
    }

    private func showValidation(_ message: String) {
        validation.stringValue = message
        validation.isHidden = false
        panel?.setContentSize(NSSize(width: panel?.contentView?.bounds.width ?? 484, height: 70))
    }
}

@MainActor private func labeled(_ title: String, _ control: NSView) -> NSStackView {
    let label = NSTextField(labelWithString: title); label.setContentHuggingPriority(.required, for: .horizontal)
    let row = NSStackView(views: [label, control]); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 8
    return row
}

@MainActor private func padded(_ content: NSView, x: CGFloat, y: CGFloat) -> NSView {
    let view = NSView(); content.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(content)
    NSLayoutConstraint.activate([
        content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: x), content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -x),
        content.topAnchor.constraint(equalTo: view.topAnchor, constant: y), content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -y)
    ])
    return view
}

@MainActor private func pin(_ content: NSView, in root: NSView, inset: CGFloat) {
    content.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(content)
    NSLayoutConstraint.activate([
        content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset), content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
        content.topAnchor.constraint(equalTo: root.topAnchor, constant: inset), content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -inset)
    ])
}
