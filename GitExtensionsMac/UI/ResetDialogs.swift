import GitExtensionsCore
import GitCommands
import AppKit

struct ResetAnotherBranchDialogValue: Sendable {
    let branch: Branch
    let force: Bool
    let checkoutAfterReset: Bool
}

struct RepositoryResetFollowUpError: LocalizedError {
    let detail: String
    var errorDescription: String? { detail }
}

@MainActor
enum ResetDialogs {
    static func resetCurrentBranch(
        branchName: String?,
        target: Commit,
        owner: NSWindow
    ) async -> RepositoryResetMode? {
        await withCheckedContinuation { continuation in
            let controller = ResetCurrentBranchViewController(
                branchName: branchName,
                target: target,
                completion: { value in continuation.resume(returning: value) }
            )
            let panel = NSPanel(contentViewController: controller)
            panel.title = "Reset current branch"
            panel.styleMask = [.titled, .closable]
            panel.setContentSize(NSSize(width: 520, height: 520))
            controller.panel = panel
            owner.beginSheet(panel)
        }
    }

    static func resetAnotherBranch(
        source: any RepositoryResettingDataSource,
        branches: [Branch],
        localReferences: [RevisionReference],
        currentBranchName: String?,
        target: Commit,
        owner: NSWindow
    ) async -> ResetAnotherBranchDialogValue? {
        await withCheckedContinuation { continuation in
            let controller = ResetAnotherBranchViewController(
                source: source,
                branches: branches,
                localReferences: localReferences,
                currentBranchName: currentBranchName,
                target: target,
                completion: { value in continuation.resume(returning: value) }
            )
            let panel = NSPanel(contentViewController: controller)
            panel.title = "Reset branch"
            panel.styleMask = [.titled, .closable]
            panel.setContentSize(NSSize(width: 550, height: 375))
            controller.panel = panel
            owner.beginSheet(panel)
        }
    }

    static func confirmHardReset(owner: NSWindow) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Reset branch"
        alert.informativeText = "You are about to discard ALL local changes, including uncommitted changes. Are you sure?"
        alert.addButton(withTitle: "Reset Hard")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[1].keyEquivalent = "\r"
        alert.buttons[0].keyEquivalent = ""
        return await alert.beginSheetModal(for: owner) == .alertFirstButtonReturn
    }

    static func confirmUpdateSubmodules(owner: NSWindow) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Update submodules"
        alert.informativeText = "Update and initialize submodules after reset?"
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Not now")
        let remember = NSButton(checkboxWithTitle: "Remember my answer", target: nil, action: nil)
        alert.accessoryView = remember
        let update = await alert.beginSheetModal(for: owner) == .alertFirstButtonReturn
        if remember.state == .on {
            var preferences = AppSettingsStore.shared.checkoutBranchPreferences
            preferences.updateSubmodulesOnCheckout = update
            AppSettingsStore.shared.saveCheckoutBranchPreferences(preferences)
        }
        return update
    }

    static func confirmResetChanges(
        hasTrackedChanges: Bool,
        hasUntrackedFiles: Bool,
        owner: NSWindow
    ) async -> Bool? {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Reset changes"
        alert.informativeText = "Are you sure you want to reset your changes?\n\nThis will delete any uncommitted work."
        let deleteNew = NSButton(checkboxWithTitle: "Also delete new files and/or directories", target: nil, action: nil)
        if !hasTrackedChanges {
            deleteNew.state = .on
            deleteNew.isEnabled = false
        } else if !hasUntrackedFiles {
            deleteNew.state = .off
            deleteNew.isEnabled = false
        }
        alert.accessoryView = deleteNew
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reset")
        let response = await alert.beginSheetModal(for: owner)
        guard response == .alertSecondButtonReturn else { return nil }
        return deleteNew.state == .on
    }

    static func showError(_ error: Error, title: String, owner: NSWindow) async {
        let alert = NSAlert(error: error)
        alert.messageText = title
        _ = await alert.beginSheetModal(for: owner)
    }
}

@MainActor
private final class ResetCurrentBranchViewController: NSViewController, NSWindowDelegate {
    weak var panel: NSPanel?
    private let branchName: String?
    private let target: Commit
    private let completion: (RepositoryResetMode?) -> Void
    private let summary = CommitSummaryView()
    private let soft = NSButton(radioButtonWithTitle: "Soft: leave working directory and index untouched", target: nil, action: nil)
    private let mixed = NSButton(radioButtonWithTitle: "Mixed: leave working directory untouched, reset index", target: nil, action: nil)
    private let keep = NSButton(radioButtonWithTitle: "Keep: update working directory to the commit (abort if there are local changes), reset index", target: nil, action: nil)
    private let merge = NSButton(radioButtonWithTitle: "Merge: update working directory to the commit and keep local changes (abort on conflicts), reset index", target: nil, action: nil)
    private let hard = NSButton(radioButtonWithTitle: "Hard: reset working directory and index (discard ALL local changes)", target: nil, action: nil)
    private var completed = false

    init(branchName: String?, target: Commit, completion: @escaping (RepositoryResetMode?) -> Void) {
        self.branchName = branchName
        self.target = target
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        let branch = branchName ?? "detached HEAD"
        let heading = NSTextField(labelWithString: "Reset branch ‘\(branch)’ to revision:")
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        summary.apply(target)
        let modes = [soft, mixed, keep, merge, hard]
        for mode in modes {
            mode.target = self
            mode.action = #selector(selectMode(_:))
            mode.cell?.wraps = true
            mode.lineBreakMode = .byWordWrapping
            mode.heightAnchor.constraint(equalToConstant: 38).isActive = true
            mode.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        soft.state = .on
        style(soft, color: .systemGreen)
        style(mixed, color: .systemYellow)
        style(keep, color: .systemYellow)
        style(merge, color: .systemYellow)
        style(hard, color: .systemRed)

        let modeStack = NSStackView(views: modes)
        modeStack.orientation = .vertical
        modeStack.alignment = .leading
        modeStack.spacing = 8
        let modeBox = NSBox()
        modeBox.title = "Reset type"
        modeBox.contentView = resetPadded(modeStack, x: 12, y: 10)

        let help = NSButton(title: "Help", target: self, action: #selector(openHelp))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let reset = NSButton(title: "Reset", target: self, action: #selector(accept))
        reset.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [help, spacer, cancel, reset])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let content = NSStackView(views: [heading, summary, modeBox, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        resetPin(content, in: root, inset: 14)
        summary.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        summary.heightAnchor.constraint(equalToConstant: 132).isActive = true
        modeBox.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        buttons.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        panel?.delegate = self
        panel?.makeFirstResponder(soft)
    }

    @objc private func selectMode(_ sender: NSButton) {
        for button in [soft, mixed, keep, merge, hard] { button.state = button === sender ? .on : .off }
    }

    @objc private func accept() {
        let mode: RepositoryResetMode
        if mixed.state == .on { mode = .mixed }
        else if keep.state == .on { mode = .keep }
        else if merge.state == .on { mode = .merge }
        else if hard.state == .on { mode = .hard }
        else { mode = .soft }
        finish(mode)
    }

    @objc private func openHelp() {
        let mode: String
        if mixed.state == .on { mode = "mixed" }
        else if keep.state == .on { mode = "keep" }
        else if merge.state == .on { mode = "merge" }
        else if hard.state == .on { mode = "hard" }
        else { mode = "soft" }
        NSWorkspace.shared.open(URL(string: "https://git-scm.com/docs/git-reset#Documentation/git-reset.txt---\(mode)")!)
    }

    @objc private func cancel() { finish(nil) }
    override func cancelOperation(_ sender: Any?) { finish(nil) }
    func windowWillClose(_ notification: Notification) { finish(nil) }

    private func finish(_ mode: RepositoryResetMode?) {
        guard !completed else { return }
        completed = true
        if let panel, let owner = panel.sheetParent { owner.endSheet(panel) }
        completion(mode)
    }

    private func style(_ button: NSButton, color: NSColor) {
        button.wantsLayer = true
        button.layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor
        button.layer?.cornerRadius = 4
    }
}

@MainActor
private final class ResetAnotherBranchViewController: NSViewController, NSWindowDelegate, NSComboBoxDelegate {
    weak var panel: NSPanel?
    private let source: any RepositoryResettingDataSource
    private let branches: [Branch]
    private let preferredBranchName: String?
    private let target: Commit
    private let completion: (ResetAnotherBranchDialogValue?) -> Void
    private let selector = NSComboBox()
    private let summary = CommitSummaryView()
    private let checkout = NSButton(checkboxWithTitle: "Checkout branch after reset", target: nil, action: nil)
    private let force = NSButton(checkboxWithTitle: "Force reset for a non-fast-forward reset", target: nil, action: nil)
    private let validation = NSTextField(wrappingLabelWithString: "")
    private let reset = NSButton(title: "Reset", target: nil, action: nil)
    private var validationTask: Task<Void, Never>?
    private var completed = false

    init(
        source: any RepositoryResettingDataSource,
        branches: [Branch],
        localReferences: [RevisionReference],
        currentBranchName: String?,
        target: Commit,
        completion: @escaping (ResetAnotherBranchDialogValue?) -> Void
    ) {
        self.source = source
        self.target = target
        self.completion = completion
        let candidates = Self.orderedCandidates(
            branches,
            localReferences: localReferences,
            currentBranchName: currentBranchName,
            target: target
        )
        self.branches = candidates
        preferredBranchName = Self.preferredCandidate(
            candidates,
            localReferences: localReferences,
            target: target
        )?.name
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }
    deinit { validationTask?.cancel() }

    override func loadView() {
        let root = NSView()
        let warning = NSTextField(wrappingLabelWithString: "⚠︎ You can only reset a branch safely if there is a direct path from it to the selected revision. Forcing a reset may leave commits unreachable.")
        warning.textColor = .systemOrange
        selector.addItems(withObjectValues: branches.map(\.name))
        selector.completes = true
        selector.delegate = self
        selector.widthAnchor.constraint(greaterThanOrEqualToConstant: 350).isActive = true
        if let preferredBranchName {
            selector.stringValue = preferredBranchName
        }
        summary.apply(target)
        checkout.state = AppSettingsStore.shared.resetPreferences.checkoutOtherBranchAfterReset ? .on : .off
        checkout.target = self
        checkout.action = #selector(checkoutChanged)
        force.target = self
        force.action = #selector(validateSelection)
        validation.textColor = .systemRed
        reset.target = self
        reset.action = #selector(accept)
        reset.keyEquivalent = "\r"
        reset.isEnabled = false
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [validation, spacer, cancel, reset])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let content = NSStackView(views: [
            warning,
            resetLabeled("Reset local branch:", selector),
            summary,
            checkout,
            force,
            buttons
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        resetPin(content, in: root, inset: 14)
        warning.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        summary.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        summary.heightAnchor.constraint(equalToConstant: 132).isActive = true
        buttons.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        view = root
        validateSelection()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        panel?.delegate = self
        panel?.makeFirstResponder(selector)
        if selector.stringValue.isEmpty { selector.performClick(nil) }
    }

    func controlTextDidChange(_ obj: Notification) { validateSelection() }
    func comboBoxSelectionDidChange(_ notification: Notification) { validateSelection() }

    @objc private func validateSelection() {
        validationTask?.cancel()
        reset.isEnabled = false
        validation.stringValue = ""
        let value = selector.stringValue
        guard let branch = branches.first(where: { $0.name == value }),
              let targetID = target.objectID else {
            if !value.isEmpty { validation.stringValue = "‘\(value)’ is not an existing local branch." }
            return
        }
        if force.state == .on {
            reset.isEnabled = true
            return
        }
        validation.stringValue = "Checking whether the reset is a fast-forward…"
        validation.textColor = .secondaryLabelColor
        validationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let safety = try await source.resetSafety(for: branch.name, target: targetID)
                guard !Task.isCancelled, selector.stringValue == branch.name else { return }
                switch safety {
                case .safe:
                    validation.stringValue = "The branch can be reset safely."
                    validation.textColor = .secondaryLabelColor
                    reset.isEnabled = true
                case .requiresForce:
                    validation.stringValue = "This is not a fast-forward. Enable Force reset to continue."
                    validation.textColor = .systemRed
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                validation.stringValue = error.localizedDescription
                validation.textColor = .systemRed
            }
        }
    }

    @objc private func checkoutChanged() {
        var preferences = AppSettingsStore.shared.resetPreferences
        preferences.checkoutOtherBranchAfterReset = checkout.state == .on
        AppSettingsStore.shared.saveResetPreferences(preferences)
    }

    @objc private func accept() {
        guard let branch = branches.first(where: { $0.name == selector.stringValue }) else { return }
        finish(ResetAnotherBranchDialogValue(
            branch: branch,
            force: force.state == .on,
            checkoutAfterReset: checkout.state == .on
        ))
    }

    @objc private func cancel() { finish(nil) }
    override func cancelOperation(_ sender: Any?) { finish(nil) }
    func windowWillClose(_ notification: Notification) { finish(nil) }

    private func finish(_ value: ResetAnotherBranchDialogValue?) {
        guard !completed else { return }
        completed = true
        validationTask?.cancel()
        if let panel, let owner = panel.sheetParent { owner.endSheet(panel) }
        completion(value)
    }

    private static func orderedCandidates(
        _ branches: [Branch],
        localReferences: [RevisionReference],
        currentBranchName: String?,
        target: Commit
    ) -> [Branch] {
        let targetRemotes = target.references.filter { $0.kind == .remoteBranch }
        let candidates = branches.filter {
            !$0.isRemote && $0.name != currentBranchName && $0.commitID != target.objectID
        }
        return candidates.sorted { lhs, rhs in
            let lhsTracks = tracksTargetRemote(lhs, localReferences: localReferences, targetRemotes: targetRemotes)
            let rhsTracks = tracksTargetRemote(rhs, localReferences: localReferences, targetRemotes: targetRemotes)
            if lhsTracks != rhsTracks { return lhsTracks }
            let lhsSameName = targetRemotes.contains { $0.localName == lhs.name }
            let rhsSameName = targetRemotes.contains { $0.localName == rhs.name }
            if lhsSameName != rhsSameName { return lhsSameName }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func preferredCandidate(
        _ branches: [Branch],
        localReferences: [RevisionReference],
        target: Commit
    ) -> Branch? {
        let targetRemotes = target.references.filter { $0.kind == .remoteBranch }
        var matches: [Branch] = []
        for branch in branches {
            let tracksRemote = tracksTargetRemote(
                branch,
                localReferences: localReferences,
                targetRemotes: targetRemotes
            )
            let sharesName = targetRemotes.contains { $0.localName == branch.name }
            if tracksRemote || sharesName { matches.append(branch) }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func tracksTargetRemote(
        _ branch: Branch,
        localReferences: [RevisionReference],
        targetRemotes: [RevisionReference]
    ) -> Bool {
        guard let local = localReferences.first(where: { reference in
            reference.name == branch.name
                && (reference.kind == .localBranch || reference.kind == .currentBranch)
        }) else { return false }
        return targetRemotes.contains { local.tracks($0) }
    }
}

@MainActor
private func resetPadded(_ view: NSView, x: CGFloat, y: CGFloat) -> NSView {
    let container = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(view)
    NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: x),
        view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -x),
        view.topAnchor.constraint(equalTo: container.topAnchor, constant: y),
        view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -y)
    ])
    return container
}

@MainActor
private func resetPin(_ view: NSView, in parent: NSView, inset: CGFloat) {
    view.translatesAutoresizingMaskIntoConstraints = false
    parent.addSubview(view)
    NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
        view.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
        view.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
        view.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
    ])
}

@MainActor
private func resetLabeled(_ title: String, _ control: NSView) -> NSView {
    let label = NSTextField(labelWithString: title)
    let row = NSStackView(views: [label, control])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    control.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return row
}
