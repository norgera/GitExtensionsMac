import AppKit
import GitExtensionsCore
import GitCommands

@MainActor
final class CommandLineHelpWindow: NSWindowController {
    init() {
        let text = NSTextView()
        text.isEditable = false
        text.font = AppSettingsStore.shared.applicationFont(size: 12)
        text.textContainerInset = NSSize(width: 10, height: 10)
        text.string = CommandLineSession.header + "\n\n" + CommandLineSession.usage
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 394, height: 662), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Commandline usage"
        window.minSize = NSSize(width: 410, height: 700)
        window.contentView = scroll
        window.isReleasedWhenClosed = false
        super.init(window: window)
        OwnedModalWindow.center(window, over: OwnedModalWindow.defaultOwner)
    }
    required init?(coder: NSCoder) { nil }
}

@MainActor
final class CommandLineAddFilesWindow: NSWindowController {
    init(source: any RepositoryAddingFilesDataSource, paths: [String], changed: @escaping () -> Void) {
        let controller = AddFilesController(source: source, paths: paths, changed: changed)
        let window = NSWindow(contentViewController: controller)
        window.title = "Add files"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 552, height: 73))
        window.contentMinSize = NSSize(width: 552, height: 73)
        window.contentMaxSize = NSSize(width: 10_000, height: 73)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        OwnedModalWindow.center(window, over: OwnedModalWindow.defaultOwner)
    }
    required init?(coder: NSCoder) { nil }

    private final class AddFilesController: NSViewController {
        let source: any RepositoryAddingFilesDataSource
        let changed: () -> Void
        let filter = NSTextField()
        let force = NSButton(checkboxWithTitle: "Force", target: nil, action: nil)
        var task: Task<Void, Never>?
        init(source: any RepositoryAddingFilesDataSource, paths: [String], changed: @escaping () -> Void) {
            self.source = source; self.changed = changed
            super.init(nibName: nil, bundle: nil)
            filter.stringValue = paths.isEmpty ? "." : paths.map { "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }.joined(separator: " ")
        }
        required init?(coder: NSCoder) { nil }
        deinit { task?.cancel() }
        override func loadView() {
            let root = NSView()
            let preview = NSButton(title: "Show files", target: self, action: #selector(showFiles))
            let add = NSButton(title: "Add files", target: self, action: #selector(addFiles))
            let label = NSTextField(labelWithString: "Filter")
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            let row = NSStackView(views: [label, filter, preview, add])
            row.alignment = .centerY
            row.spacing = 8
            for button in [preview, add] { button.setContentCompressionResistancePriority(.required, for: .horizontal) }
            row.translatesAutoresizingMaskIntoConstraints = false
            force.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(row)
            root.addSubview(force)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
                row.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
                row.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
                filter.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
                force.leadingAnchor.constraint(equalTo: filter.leadingAnchor),
                force.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 6),
                force.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -6)
            ])
            view = root
        }
        override func viewDidAppear() { super.viewDidAppear(); view.window?.makeFirstResponder(filter) }
        @objc func showFiles() { execute(dryRun: true) }
        @objc func addFiles() { execute(dryRun: false) }
        override func cancelOperation(_ sender: Any?) { task?.cancel(); view.window?.close() }
        func execute(dryRun: Bool) {
            guard task == nil, let owner = view.window else { return }
            let value = filter.stringValue, forced = force.state == .on
            task = Task { @MainActor in
                defer { task = nil }
                var mutation = false
                let succeeded = await HostingProcessDialog.run(dryRun ? "Show files" : "Add files", owner) { output in
                    let result = try await self.source.addFiles(filter: value, force: forced, dryRun: dryRun, output: output)
                    await MainActor.run { mutation = result.changed }
                    return result.command.succeeded
                }
                if mutation { changed() }
                if succeeded && !dryRun { owner.close() }
            }
        }
    }
}

@MainActor
final class CommandLinePresentation {
    private let owner: NSWindow
    private let existing = NSHashTable<NSWindow>.weakObjects()
    private var windows: [ObjectIdentifier: NSWindow] = [:]
    private var observers: [NSObjectProtocol] = []
    private(set) var presented = false
    private(set) var mutated = false
    var successfulRead = false
    var hidesOwner = false
    private var subscription: RepositoryChangedSubscription?

    init(owner: NSWindow, notifier: RepositoryChangedNotifier? = nil) {
        self.owner = owner
        for window in NSApp.windows { existing.add(window) }
        if let notifier { subscription = notifier.subscribe { [weak self] _, _ in self?.mutated = true } }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let window = notification.object as? NSWindow { self.capture(window) }
                    if let sheet = self.owner.attachedSheet { self.capture(sheet) }
                }
            })
        }
    }
    private func capture(_ window: NSWindow) {
        let identity = ObjectIdentifier(window)
        guard window !== owner, !existing.allObjects.contains(where: { $0 === window }) else { return }
        windows[identity] = window
        presented = true
        if hidesOwner, window.sheetParent == nil, owner.attachedSheet == nil { owner.orderOut(nil) }
    }
    func finish() { observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll(); subscription?.cancel(); subscription = nil }
    func wait() async throws -> Bool {
        defer { finish() }
        let deadline = ContinuousClock.now + .seconds(60)
        while !presented {
            try Task.checkCancellation()
            for window in NSApp.windows where window.isVisible { capture(window) }
            if let sheet = owner.attachedSheet { capture(sheet) }
            guard ContinuousClock.now < deadline else { throw CLIError.invalid("The command did not open a workflow.") }
            try await Task.sleep(for: .milliseconds(20))
        }
        while windows.values.contains(where: { $0.isVisible }) || owner.attachedSheet != nil {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(20))
        }
        await Task.yield()
        return successfulRead || mutated
    }
}
