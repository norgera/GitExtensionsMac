import GitExtensionsCore
import GitCommands
import AppKit

@MainActor
enum MergeDialog {
    static func present(
        source: any RepositoryMergingDataSource,
        context: RepositoryMergeContext,
        initialTarget: String?,
        owner: NSWindow,
        onRepositoryChanged: @escaping (RevisionID?) -> Void,
        onClose: @escaping () -> Void
    ) -> NSWindowController {
        let controller = MergeDialogViewController(
            source: source,
            context: context,
            initialTarget: initialTarget,
            onRepositoryChanged: onRepositoryChanged
        )
        let window = NSWindow(contentViewController: controller)
        window.title = "Merge branches"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: controller.initialWindowWidth, height: 460))
        window.minSize = NSSize(width: 478, height: 380)
        window.isReleasedWhenClosed = false
        window.delegate = controller
        controller.window = window
        controller.onClose = onClose

        let controllerWindow = NSWindowController(window: window)
        controllerWindow.showWindow(nil)
        let ownerFrame = owner.frame
        var frame = window.frame
        frame.origin = NSPoint(
            x: ownerFrame.midX - frame.width / 2,
            y: ownerFrame.midY - frame.height / 2
        )
        if let screen = owner.screen ?? NSScreen.main {
            frame = window.constrainFrameRect(frame, to: screen)
        }
        window.setFrame(frame, display: false)
        window.makeKeyAndOrderFront(nil)
        return controllerWindow
    }
}

@MainActor
private final class MergeDialogViewController: NSViewController, NSWindowDelegate, NSComboBoxDelegate {
    private struct TargetChoice: Hashable {
        let value: String
        let title: String
    }

    weak var window: NSWindow?
    var onClose: (() -> Void)?

    private let source: any RepositoryMergingDataSource
    private let context: RepositoryMergeContext
    private let onRepositoryChanged: (RevisionID?) -> Void
    private let settings = AppSettingsStore.shared
    private let targets: [TargetChoice]

    private let targetCombo = NSComboBox()
    private let currentBranch = NSTextField(labelWithString: "")
    private let fastForward = NSButton(radioButtonWithTitle: "Keep a single branch line if possible (fast forward)", target: nil, action: nil)
    private let noFastForward = NSButton(radioButtonWithTitle: "Always create a new merge commit", target: nil, action: nil)
    private let noCommit = NSButton(checkboxWithTitle: "Do not commit", target: nil, action: nil)
    private let advanced = NSButton(checkboxWithTitle: "Show advanced options", target: nil, action: nil)
    private let advancedPanel = NSStackView()
    private let useStrategy = NSButton(checkboxWithTitle: "Use non-default merge strategy", target: nil, action: nil)
    private let strategy = NSComboBox()
    private let strategyHelp = NSButton(title: "Help", target: nil, action: nil)
    private let squash = NSButton(checkboxWithTitle: "Squash commits", target: nil, action: nil)
    private let allowUnrelated = NSButton(checkboxWithTitle: "Allow unrelated histories", target: nil, action: nil)
    private let addLog = NSButton(checkboxWithTitle: "Add log messages", target: nil, action: nil)
    private let logCount = NSTextField(string: "20")
    private let logStepper = NSStepper()
    private let specifyMessage = NSButton(checkboxWithTitle: "Specify merge message", target: nil, action: nil)
    private let mergeMessage = NSTextView()
    private let mergeButton = NSButton(title: "Merge", target: nil, action: nil)
    private let helpImage = PullHelpImageView()
    private let helpNotice = NSTextField(wrappingLabelWithString: "Hover to see scenario when fast forward is possible.")
    private let helpToggle = NSButton(title: "", target: nil, action: nil)
    private let helpPane = NSView()
    private var helpWidthConstraint: NSLayoutConstraint?

    private var isHelpExpanded: Bool
    private var operationTask: Task<Void, Never>?
    private var didClose = false

    var initialWindowWidth: CGFloat { isHelpExpanded ? 772 : 563 }

    init(
        source: any RepositoryMergingDataSource,
        context: RepositoryMergeContext,
        initialTarget: String?,
        onRepositoryChanged: @escaping (RevisionID?) -> Void
    ) {
        self.source = source
        self.context = context
        self.onRepositoryChanged = onRepositoryChanged
        self.targets = Self.makeTargets(context)
        self.isHelpExpanded = AppSettingsStore.shared.mergePreferences.helpExpanded
        super.init(nibName: nil, bundle: nil)

        let current = context.branches.first(where: \.isCurrent)
        currentBranch.stringValue = current?.name ?? "Detached HEAD"
        currentBranch.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        let defaultTarget = initialTarget ?? Self.trackingTarget(context: context, currentBranch: current)
        targetCombo.stringValue = defaultTarget ?? ""
    }

    required init?(coder: NSCoder) { nil }
    deinit { operationTask?.cancel() }

    override func loadView() {
        let root = NSView()
        configureHelpPane()
        let form = makeMergeGroup()

        mergeButton.target = self
        mergeButton.action = #selector(startMerge)
        mergeButton.keyEquivalent = "\r"
        mergeButton.translatesAutoresizingMaskIntoConstraints = false

        for subview in [helpPane, form, mergeButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }

        let helpWidth = helpPane.widthAnchor.constraint(equalToConstant: isHelpExpanded ? 289 : 80)
        helpWidthConstraint = helpWidth
        NSLayoutConstraint.activate([
            helpPane.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 3),
            helpPane.topAnchor.constraint(equalTo: root.topAnchor, constant: 3),
            helpPane.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -3),
            helpWidth,

            form.leadingAnchor.constraint(equalTo: helpPane.trailingAnchor, constant: 6),
            form.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            form.topAnchor.constraint(equalTo: root.topAnchor, constant: 3),
            form.widthAnchor.constraint(equalToConstant: 474),
            form.heightAnchor.constraint(equalToConstant: 412),

            mergeButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            mergeButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            mergeButton.widthAnchor.constraint(equalToConstant: 108),
            mergeButton.heightAnchor.constraint(equalToConstant: 25)
        ])

        view = root
        updateAdvancedState(resetWhenHidden: false)
        updateFastForwardState()
        updateStrategyState()
        updateMessageState()
        updateLogState()
        updateHelpVisibility()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(targetCombo)
    }

    private func configureHelpPane() {
        helpImage.imageScaling = .scaleProportionallyUpOrDown
        helpImage.translatesAutoresizingMaskIntoConstraints = false
        helpNotice.font = .systemFont(ofSize: 11)
        helpNotice.textColor = .secondaryLabelColor
        helpNotice.alignment = .center
        helpNotice.translatesAutoresizingMaskIntoConstraints = false
        helpToggle.target = self
        helpToggle.action = #selector(toggleHelp)
        helpToggle.translatesAutoresizingMaskIntoConstraints = false

        helpPane.addSubview(helpImage)
        helpPane.addSubview(helpNotice)
        helpPane.addSubview(helpToggle)
        NSLayoutConstraint.activate([
            helpImage.leadingAnchor.constraint(equalTo: helpPane.leadingAnchor),
            helpImage.trailingAnchor.constraint(equalTo: helpPane.trailingAnchor),
            helpImage.topAnchor.constraint(equalTo: helpPane.topAnchor),
            helpImage.heightAnchor.constraint(equalToConstant: 373),
            helpNotice.leadingAnchor.constraint(equalTo: helpPane.leadingAnchor, constant: 4),
            helpNotice.trailingAnchor.constraint(equalTo: helpPane.trailingAnchor, constant: -4),
            helpNotice.topAnchor.constraint(equalTo: helpImage.bottomAnchor, constant: 3),
            helpToggle.centerXAnchor.constraint(equalTo: helpPane.centerXAnchor),
            helpToggle.bottomAnchor.constraint(equalTo: helpPane.bottomAnchor, constant: -4),
            helpToggle.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    private func makeMergeGroup() -> NSBox {
        targetCombo.usesDataSource = false
        targetCombo.completes = true
        targetCombo.delegate = self
        targetCombo.addItems(withObjectValues: targets.map(\.title))
        targetCombo.translatesAutoresizingMaskIntoConstraints = false
        targetCombo.widthAnchor.constraint(equalToConstant: 296).isActive = true

        let selectMultiple = AppKitFactory.symbolButton(
            "list.bullet.rectangle",
            tooltip: "Select multiple branches",
            target: self,
            action: #selector(selectMultipleTargets)
        )
        let targetControl = NSStackView(views: [targetCombo, selectMultiple])
        targetControl.orientation = .horizontal
        targetControl.spacing = 4

        fastForward.target = self
        fastForward.action = #selector(fastForwardChanged)
        noFastForward.target = self
        noFastForward.action = #selector(fastForwardChanged)
        let preferences = settings.mergePreferences
        noFastForward.state = preferences.noFastForward ? .on : .off
        fastForward.state = preferences.noFastForward ? .off : .on
        noCommit.state = preferences.noCommit ? .on : .off

        advanced.target = self
        advanced.action = #selector(advancedChanged)
        advanced.state = .off
        configureAdvancedPanel(preferences: preferences)

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 5
        content.addArrangedSubview(row(label: "Merge branch", control: targetControl))
        content.addArrangedSubview(row(label: "Into current branch", control: currentBranch))
        content.setCustomSpacing(13, after: content.arrangedSubviews[1])
        for control in [fastForward, noFastForward, noCommit, advanced, advancedPanel] {
            content.addArrangedSubview(control)
        }

        let box = NSBox()
        box.boxType = .primary
        box.title = "Merge"
        box.titlePosition = .atTop
        content.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(content)
        if let holder = box.contentView {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 10),
                content.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -8),
                content.topAnchor.constraint(equalTo: holder.topAnchor, constant: 7),
                content.bottomAnchor.constraint(lessThanOrEqualTo: holder.bottomAnchor, constant: -8)
            ])
        }
        return box
    }

    private func configureAdvancedPanel(preferences: MergePreferences) {
        advancedPanel.orientation = .vertical
        advancedPanel.alignment = .leading
        advancedPanel.spacing = 3

        useStrategy.target = self
        useStrategy.action = #selector(strategyChanged)
        strategy.addItems(withObjectValues: ["resolve", "recursive", "octopus", "ours", "subtree"])
        strategy.isEditable = true
        strategy.completes = true
        strategy.translatesAutoresizingMaskIntoConstraints = false
        strategy.widthAnchor.constraint(equalToConstant: 158).isActive = true
        strategyHelp.target = self
        strategyHelp.action = #selector(openStrategyHelp)
        strategyHelp.isBordered = false
        strategyHelp.contentTintColor = .linkColor
        let strategyControls = NSStackView(views: [strategy, strategyHelp])
        strategyControls.orientation = .horizontal
        strategyControls.spacing = 5
        advancedPanel.addArrangedSubview(row(labelControl: useStrategy, control: strategyControls, labelWidth: 230))

        advancedPanel.addArrangedSubview(squash)
        advancedPanel.addArrangedSubview(allowUnrelated)

        addLog.state = preferences.addLogMessages ? .on : .off
        addLog.target = self
        addLog.action = #selector(logChanged)
        logCount.stringValue = String(max(1, preferences.logMessagesCount))
        logCount.alignment = .center
        logCount.formatter = integerFormatter()
        logCount.translatesAutoresizingMaskIntoConstraints = false
        logCount.widthAnchor.constraint(equalToConstant: 44).isActive = true
        logStepper.minValue = 1
        logStepper.maxValue = 999
        logStepper.integerValue = max(1, preferences.logMessagesCount)
        logStepper.target = self
        logStepper.action = #selector(logStepperChanged)
        let countControls = NSStackView(views: [logCount, logStepper])
        countControls.orientation = .horizontal
        countControls.spacing = 0
        advancedPanel.addArrangedSubview(row(labelControl: addLog, control: countControls, labelWidth: 230))

        specifyMessage.target = self
        specifyMessage.action = #selector(messageChanged)
        advancedPanel.addArrangedSubview(specifyMessage)

        mergeMessage.font = .systemFont(ofSize: NSFont.systemFontSize)
        mergeMessage.isRichText = false
        mergeMessage.isAutomaticQuoteSubstitutionEnabled = false
        mergeMessage.isAutomaticDashSubstitutionEnabled = false
        let messageScroll = NSScrollView()
        messageScroll.documentView = mergeMessage
        messageScroll.hasVerticalScroller = true
        messageScroll.borderType = .bezelBorder
        messageScroll.translatesAutoresizingMaskIntoConstraints = false
        messageScroll.widthAnchor.constraint(equalToConstant: 435).isActive = true
        messageScroll.heightAnchor.constraint(equalToConstant: 77).isActive = true
        advancedPanel.addArrangedSubview(messageScroll)
    }

    private func row(label: String, control: NSView) -> NSStackView {
        let labelField = NSTextField(labelWithString: label)
        labelField.alignment = .left
        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.widthAnchor.constraint(equalToConstant: 115).isActive = true
        let row = NSStackView(views: [labelField, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func row(labelControl: NSView, control: NSView, labelWidth: CGFloat) -> NSStackView {
        labelControl.translatesAutoresizingMaskIntoConstraints = false
        labelControl.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
        let row = NSStackView(views: [labelControl, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 3
        return row
    }

    private func integerFormatter() -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 1
        formatter.maximum = 999
        formatter.allowsFloats = false
        return formatter
    }

    @objc private func advancedChanged() {
        updateAdvancedState(resetWhenHidden: true)
    }

    private func updateAdvancedState(resetWhenHidden: Bool) {
        let shown = advanced.state == .on
        advancedPanel.isHidden = !shown
        if !shown && resetWhenHidden {
            useStrategy.state = .off
            strategy.stringValue = ""
            squash.state = .off
            allowUnrelated.state = .off
            specifyMessage.state = .off
            updateStrategyState()
            updateMessageState()
        }
    }

    @objc private func fastForwardChanged(_ sender: NSButton) {
        if sender === fastForward {
            fastForward.state = .on
            noFastForward.state = .off
        } else {
            noFastForward.state = .on
            fastForward.state = .off
        }
        updateFastForwardState()
    }

    private func updateFastForwardState() {
        let noFF = noFastForward.state == .on
        squash.isEnabled = !noFF
        if noFF { squash.state = .off }
        let primary = AppKitFactory.resourceImage(
            "HelpCommandMerge",
            accessibilityDescription: "Merge scenario",
            size: NSSize(width: 289, height: 373),
            adaptLightness: true
        )
        let alternate = noFF ? nil : AppKitFactory.resourceImage(
            "HelpCommandMergeFastForward",
            accessibilityDescription: "Fast-forward merge scenario",
            size: NSSize(width: 289, height: 373),
            adaptLightness: true
        )
        helpImage.setImages(primary: primary, alternate: alternate)
        helpNotice.isHidden = !isHelpExpanded || noFF
    }

    @objc private func strategyChanged() { updateStrategyState() }
    private func updateStrategyState() {
        let enabled = useStrategy.state == .on
        strategy.isHidden = !enabled
        strategyHelp.isHidden = !enabled
        if !enabled && advanced.state == .off { strategy.stringValue = "" }
    }

    @objc private func messageChanged() { updateMessageState() }
    private func updateMessageState() { mergeMessage.isEditable = specifyMessage.state == .on }

    @objc private func logChanged() {
        updateLogState()
        saveLogPreferences()
    }

    @objc private func logStepperChanged() {
        logCount.integerValue = logStepper.integerValue
        saveLogPreferences()
    }

    private func updateLogState() {
        let enabled = addLog.state == .on
        logCount.isEnabled = enabled
        logStepper.isEnabled = enabled
    }

    private func saveLogPreferences() {
        var preferences = settings.mergePreferences
        preferences.addLogMessages = addLog.state == .on
        let count = max(1, logCount.integerValue)
        logCount.integerValue = count
        logStepper.integerValue = count
        preferences.logMessagesCount = count
        settings.saveMergePreferences(preferences)
    }

    @objc private func toggleHelp() {
        let oldWidth = isHelpExpanded ? 289.0 : 80.0
        isHelpExpanded.toggle()
        let newWidth = isHelpExpanded ? 289.0 : 80.0
        helpWidthConstraint?.constant = newWidth
        updateHelpVisibility()
        var preferences = settings.mergePreferences
        preferences.helpExpanded = isHelpExpanded
        settings.saveMergePreferences(preferences)

        guard let window else { return }
        var frame = window.frame
        let delta = newWidth - oldWidth
        frame.origin.x -= delta
        frame.size.width += delta
        if let screen = window.screen ?? NSScreen.main {
            frame = window.constrainFrameRect(frame, to: screen)
        }
        window.setFrame(frame, display: true, animate: false)
    }

    private func updateHelpVisibility() {
        helpImage.isHidden = !isHelpExpanded
        helpNotice.isHidden = !isHelpExpanded || noFastForward.state == .on
        if isHelpExpanded {
            helpToggle.image = nil
            helpToggle.isBordered = false
            helpToggle.attributedTitle = NSAttributedString(
                string: "Hide help",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ]
            )
            helpToggle.setAccessibilityLabel("Hide help")
        } else {
            helpToggle.attributedTitle = NSAttributedString(
                string: "Show help",
                attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.linkColor]
            )
            helpToggle.image = AppKitFactory.resourceImage("Information", accessibilityDescription: "Show help")
            helpToggle.imagePosition = .imageLeading
            helpToggle.isBordered = true
            helpToggle.bezelStyle = .texturedRounded
            helpToggle.setAccessibilityLabel("Show help")
        }
    }

    @objc private func selectMultipleTargets() {
        guard let window else { return }
        let current = Set(targetCombo.stringValue.split(separator: " ").map(String.init))
        Task { @MainActor [weak self, weak window] in
            guard let self, let window else { return }
            if let selected = await MergeTargetSelectionDialog.present(
                choices: targets.map { ($0.value, $0.title) },
                selected: current,
                owner: window
            ) {
                targetCombo.stringValue = selected.joined(separator: " ")
            }
        }
    }

    @objc private func openStrategyHelp() {
        guard let url = URL(string: "https://git-extensions-documentation.readthedocs.io/en/latest/branches.html#advanced-merge-options") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func startMerge() {
        guard operationTask == nil, let window else { return }
        let values = targetCombo.stringValue
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !values.isEmpty else {
            showValidation("Select at least one branch, tag, or revision to merge.")
            return
        }

        var preferences = settings.mergePreferences
        preferences.noFastForward = noFastForward.state == .on
        preferences.noCommit = noCommit.state == .on
        settings.saveMergePreferences(preferences)
        saveLogPreferences()

        let allowsFastForward = fastForward.state == .on
        let squashes = squash.state == .on
        let leavesUncommitted = noCommit.state == .on
        let selectedStrategy = useStrategy.state == .on ? strategy.stringValue : nil
        let allowsUnrelatedHistories = allowUnrelated.state == .on
        let customMessage = specifyMessage.state == .on ? mergeMessage.string : nil
        let selectedLogCount = addLog.state == .on ? max(1, logCount.integerValue) : nil
        setExecuting(true)
        operationTask = Task { @MainActor [weak self, weak window] in
            guard let self, let window else { return }
            let updateSubmodules = await shouldUpdateSubmodules(afterMergeIn: context, window: window)
            guard !Task.isCancelled else {
                operationTask = nil
                setExecuting(false)
                return
            }
            let request = RepositoryMergeRequest(
                targets: values,
                allowFastForward: allowsFastForward,
                squash: squashes,
                noCommit: leavesUncommitted,
                strategy: selectedStrategy,
                allowUnrelatedHistories: allowsUnrelatedHistories,
                message: customMessage,
                logCount: selectedLogCount,
                updateSubmodulesAfterMerge: updateSubmodules
            )
            let result = await MergeProcessDialog.run(request: request, source: source, parent: window)
            operationTask = nil
            setExecuting(false)
            guard let result else { return }
            switch result {
            case .failure(let error):
                if !(error is CancellationError) {
                    await MutationDialogs.showError(error, title: "Merge failed", window: window)
                }
            case .success(let value):
                onRepositoryChanged(value.selectedCommitID)
                switch value.outcome {
                case .completed, .alreadyUpToDate, .readyToCommit:
                    finish()
                    self.window?.close()
                case .failed:
                    break
                case .conflicts(let paths):
                    if await MutationDialogs.confirmResolveMergeConflicts(paths: paths, window: window) {
                        let resolution = await WorkflowManagementDialogs.resolveMergeConflicts(
                            source: source,
                            offerCommit: !request.noCommit,
                            window: window
                        )
                        if resolution.repositoryChanged { onRepositoryChanged(value.selectedCommitID) }
                    }
                    finish()
                    self.window?.close()
                }
            }
        }
    }

    private func shouldUpdateSubmodules(
        afterMergeIn context: RepositoryMergeContext,
        window: NSWindow
    ) async -> Bool {
        guard !context.submodules.isEmpty else { return false }
        switch settings.pullPreferences.updateSubmodulesAfterPull {
        case true:
            return true
        case false:
            return false
        case nil:
            let initializing = context.submodules.contains(where: { $0.state == .uninitialized })
            let alert = NSAlert()
            alert.messageText = "Submodules"
            if initializing {
                alert.informativeText = "The repository has uninitialized submodules. Initialize and update all submodules recursively after Merge?"
                alert.addButton(withTitle: "Initialize submodules")
            } else {
                alert.informativeText = "Update all configured submodules recursively after Merge?"
                alert.addButton(withTitle: "Update submodules")
            }
            alert.addButton(withTitle: "Not now")
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) {
                    continuation.resume(returning: $0 == .alertFirstButtonReturn)
                }
            }
        }
    }

    private func setExecuting(_ executing: Bool) {
        mergeButton.isEnabled = !executing
        targetCombo.isEnabled = !executing
    }

    private func showValidation(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Merge"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window { alert.beginSheetModal(for: window) }
    }

    override func cancelOperation(_ sender: Any?) {
        if operationTask != nil { operationTask?.cancel() } else { window?.close() }
    }

    func windowWillClose(_ notification: Notification) { finish() }

    private func finish() {
        guard !didClose else { return }
        didClose = true
        operationTask?.cancel()
        onClose?()
    }

    private static func makeTargets(_ context: RepositoryMergeContext) -> [TargetChoice] {
        var values: [TargetChoice] = context.branches.filter { !$0.isRemote }.map {
            TargetChoice(value: $0.name, title: $0.name)
        }
        values += context.branches.filter(\.isRemote).compactMap { branch in
            guard let remote = branch.remoteName else { return nil }
            let name = "\(remote)/\(branch.name)"
            return TargetChoice(value: name, title: name)
        }
        values += context.tags.map { TargetChoice(value: $0.name, title: $0.name) }
        var seen = Set<String>()
        return values.filter { seen.insert($0.value).inserted }
    }

    private static func trackingTarget(context: RepositoryMergeContext, currentBranch: Branch?) -> String? {
        guard let currentBranch,
              let reference = context.referencesByCommit[currentBranch.commitID]?.first(where: {
                  ($0.kind == .currentBranch || $0.kind == .localBranch) && $0.name == currentBranch.name
              }),
              let remote = reference.trackingRemote,
              let mergeWith = reference.mergeWith
        else { return nil }
        return "\(remote)/\(mergeWith)"
    }
}

@MainActor
private enum MergeTargetSelectionDialog {
    static func present(
        choices: [(value: String, title: String)],
        selected: Set<String>,
        owner: NSWindow
    ) async -> [String]? {
        let controller = MergeTargetSelectionViewController(choices: choices, selected: selected)
        let panel = NSPanel(contentViewController: controller)
        panel.title = "Select multiple branches"
        panel.styleMask = [.titled, .closable, .resizable]
        panel.setContentSize(NSSize(width: 320, height: 300))
        panel.minSize = NSSize(width: 200, height: 200)
        controller.panel = panel
        return await withCheckedContinuation { continuation in
            controller.onClose = { result in
                if owner.attachedSheet === panel { owner.endSheet(panel) }
                continuation.resume(returning: result)
            }
            owner.beginSheet(panel)
        }
    }
}

@MainActor
private final class MergeTargetSelectionViewController: NSViewController, NSWindowDelegate {
    weak var panel: NSPanel?
    var onClose: (([String]?) -> Void)?
    private let choices: [(value: String, title: String)]
    private var selected: Set<String>
    private var didClose = false

    init(choices: [(value: String, title: String)], selected: Set<String>) {
        self.choices = choices
        self.selected = selected
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        let label = NSTextField(labelWithString: "Select branches")
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 3
        for (index, choice) in choices.enumerated() {
            let button = NSButton(checkboxWithTitle: choice.title, target: self, action: #selector(changed(_:)))
            button.tag = index
            button.state = selected.contains(choice.value) ? .on : .off
            list.addArrangedSubview(button)
        }
        let document = TopAlignedDocumentView()
        list.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 5),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -5),
            list.topAnchor.constraint(equalTo: document.topAnchor, constant: 5),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -5),
            list.widthAnchor.constraint(greaterThanOrEqualToConstant: 270)
        ])
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        let ok = NSButton(title: "OK", target: self, action: #selector(accept))
        ok.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, ok])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        for subview in [label, scroll, buttons] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            label.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),
            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10)
        ])
        view = root
    }

    @objc private func changed(_ sender: NSButton) {
        guard choices.indices.contains(sender.tag) else { return }
        let value = choices[sender.tag].value
        if sender.state == .on { selected.insert(value) } else { selected.remove(value) }
    }

    @objc private func accept() {
        finish(choices.compactMap { selected.contains($0.value) ? $0.value : nil })
    }

    @objc private func cancel() { finish(nil) }
    func windowWillClose(_ notification: Notification) { finish(nil) }
    private func finish(_ value: [String]?) {
        guard !didClose else { return }
        didClose = true
        onClose?(value)
    }
}

@MainActor
private enum MergeProcessDialog {
    typealias Operation = @Sendable (@escaping GitOutputHandler) async throws -> RepositoryMergeResult

    static func run(
        request: RepositoryMergeRequest,
        source: any RepositoryMergingDataSource,
        parent: NSWindow
    ) async -> Result<RepositoryMergeResult, Error>? {
        let controller = MergeProcessViewController {
            try await source.performMerge(request, output: $0)
        }
        let panel = NSPanel(contentViewController: controller)
        panel.title = "Merge"
        panel.styleMask = [.titled, .closable, .resizable]
        panel.setContentSize(NSSize(width: 700, height: 430))
        panel.minSize = NSSize(width: 520, height: 300)
        controller.panel = panel
        panel.delegate = controller
        return await withCheckedContinuation { continuation in
            controller.onClose = { result in
                if parent.attachedSheet === panel { parent.endSheet(panel) }
                continuation.resume(returning: result)
            }
            parent.beginSheet(panel)
            controller.start()
        }
    }
}

@MainActor
private final class MergeProcessViewController: NSViewController, NSWindowDelegate {
    weak var panel: NSPanel?
    var onClose: ((Result<RepositoryMergeResult, Error>?) -> Void)?
    private let operation: MergeProcessDialog.Operation
    private let progress = NSProgressIndicator()
    private let status = NSTextField(labelWithString: "Waiting…")
    private let outputView = NSTextView()
    private let keepOpen = NSButton(checkboxWithTitle: "Keep dialog open", target: nil, action: nil)
    private let abortButton = NSButton(title: "Abort", target: nil, action: nil)
    private let closeButton = NSButton(title: "OK", target: nil, action: nil)
    private var task: Task<Void, Never>?
    private var result: Result<RepositoryMergeResult, Error>?
    private var didClose = false

    init(operation: @escaping MergeProcessDialog.Operation) {
        self.operation = operation
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }
    deinit { task?.cancel() }

    override func loadView() {
        let root = NSView()
        progress.style = .bar
        progress.controlSize = .small
        progress.isIndeterminate = true
        progress.widthAnchor.constraint(equalToConstant: 92).isActive = true
        status.font = .boldSystemFont(ofSize: 12)
        outputView.isEditable = false
        outputView.isSelectable = true
        outputView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        outputView.textContainerInset = NSSize(width: 6, height: 6)
        outputView.isVerticallyResizable = true
        outputView.isHorizontallyResizable = true
        outputView.autoresizingMask = [.width, .height]
        outputView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        outputView.textContainer?.widthTracksTextView = false
        let scroll = NSScrollView()
        scroll.documentView = outputView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        keepOpen.state = AppSettingsStore.shared.mergePreferences.closeProcessOnSuccess ? .off : .on
        keepOpen.target = self
        keepOpen.action = #selector(keepOpenChanged)
        abortButton.target = self
        abortButton.action = #selector(abort)
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.keyEquivalent = "\r"
        closeButton.isEnabled = false
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [progress, status])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        let footer = NSStackView(views: [keepOpen, spacer, abortButton, closeButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        for subview in [header, scroll, footer] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 9),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -9),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            footer.heightAnchor.constraint(equalToConstant: 30)
        ])
        view = root
    }

    func start() {
        guard task == nil else { return }
        progress.startAnimation(nil)
        status.stringValue = "Merging…"
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let value = try await operation { [weak self] event in
                    Task { @MainActor in self?.append(event) }
                }
                result = .success(value)
                switch value.outcome {
                case .completed: status.stringValue = "Completed successfully"
                case .alreadyUpToDate: status.stringValue = "Already up to date"
                case .readyToCommit: status.stringValue = "Merge is ready to commit"
                case .conflicts(let paths): status.stringValue = "Stopped with \(paths.count) conflict(s)"
                case .failed:
                    let failed = value.followUpCommands.first(where: { !$0.succeeded }) ?? value.command
                    status.stringValue = "Failed (exit \(failed.exitStatus))"
                }
            } catch is CancellationError {
                status.stringValue = "Aborted"
                result = .failure(CancellationError())
                appendText("\nAborted\n", color: .systemOrange)
            } catch {
                status.stringValue = "Failed"
                result = .failure(error)
                appendText("\n\(error.localizedDescription)\n", color: .systemRed)
            }
            progress.stopAnimation(nil)
            abortButton.isEnabled = false
            closeButton.isEnabled = true
            task = nil
            if case .success(let value) = result,
               (value.outcome == .completed || value.outcome == .alreadyUpToDate || value.outcome == .readyToCommit),
               keepOpen.state == .off {
                finish()
            }
        }
    }

    private func append(_ event: GitOutputEvent) {
        appendText(event.text, color: event.stream == .standardError ? .systemRed : .textColor)
        let lines = event.text.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
        if let last = lines.last, !last.isEmpty { status.stringValue = String(last) }
    }

    private func appendText(_ value: String, color: NSColor) {
        outputView.textStorage?.append(NSAttributedString(
            string: value,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: color
            ]
        ))
        outputView.scrollToEndOfDocument(nil)
    }

    @objc private func keepOpenChanged() {
        var preferences = AppSettingsStore.shared.mergePreferences
        preferences.closeProcessOnSuccess = keepOpen.state == .off
        AppSettingsStore.shared.saveMergePreferences(preferences)
        if keepOpen.state == .off,
           case .success(let value) = result,
           (value.outcome == .completed || value.outcome == .alreadyUpToDate || value.outcome == .readyToCommit) {
            finish()
        }
    }

    override func cancelOperation(_ sender: Any?) { task != nil ? abort() : close() }
    @objc private func abort() { status.stringValue = "Aborting…"; task?.cancel() }
    @objc private func close() { finish() }
    func windowWillClose(_ notification: Notification) { if task != nil { task?.cancel() }; finish() }
    private func finish() {
        guard !didClose else { return }
        didClose = true
        onClose?(result)
    }
}
