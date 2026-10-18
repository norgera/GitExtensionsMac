import AppKit
import Darwin
import GitCommands
import SwiftTerm

final class EmbeddedConsoleViewController: NSViewController {
    private(set) var terminalView: ConsoleTerminalView?
    private(set) var repositoryURL: URL?
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    var inheritedEnvironment = ProcessInfo.processInfo.environment

    override func loadView() {
        view = NSView()
        view.setAccessibilityIdentifier("Browser.console")
    }

    func setRepository(_ url: URL) {
        let directory = url.standardizedFileURL
        guard repositoryURL != directory else { return }
        repositoryURL = directory
        guard let terminalView, terminalView.process.running else { return }
        terminalView.send(txt: Self.changeDirectoryInput(directory.path))
    }

    static func changeDirectoryInput(_ path: String) -> String {
        "\u{1}\u{b}cd '\(path.replacingOccurrences(of: "'", with: "'\\''"))'\r"
    }

    func activate(
        preferences: AppPreferences? = nil,
        environment: [String: String]? = nil
    ) {
        let preferences = preferences ?? AppSettingsStore.shared.preferences
        guard let directory = repositoryURL else { return }
        _ = view
        if terminalView?.process.running != true {
            terminalView?.removeFromSuperview()
            terminalView = nil
            errorLabel.removeFromSuperview()
            let shell = ((preferences.shellPath.isEmpty ? "/bin/zsh" : preferences.shellPath) as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard FileManager.default.isExecutableFile(atPath: shell),
                FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                showError(
                    "Unable to start console. Check the shell path and repository directory in Settings.")
                return
            }
            let terminal = ConsoleTerminalView(
                frame: view.bounds, font: AppSettingsStore.shared.monospaceFont,
                options: TerminalOptions(scrollback: 2000))
            terminal.terminalDelegate = terminal.sizeCoalescer
            terminal.setAccessibilityLabel("Repository console")
            terminal.setAccessibilityIdentifier("Browser.console.terminal")
            terminalView = terminal
            terminal.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(terminal)
            NSLayoutConstraint.activate([
                terminal.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                terminal.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                terminal.topAnchor.constraint(equalTo: view.topAnchor),
                terminal.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            view.layoutSubtreeIfNeeded()
            applyAppearance()
            terminal.startProcess(
                executable: shell, args: ["-l", "-i"],
                environment: Self.shellEnvironment(preferences: preferences, inherited: environment ?? inheritedEnvironment),
                currentDirectory: directory.path)
            if !terminal.process.running { showError("Unable to start the configured shell.") }
        }
        focus()
    }

    func focus() {
        if let terminalView { view.window?.makeFirstResponder(terminalView) }
    }

    func applyAppearance() {
        terminalView?.font = AppSettingsStore.shared.monospaceFont
        terminalView?.nativeForegroundColor = ApplicationColors.color(
            "WindowText", fallback: .textColor)
        terminalView?.nativeBackgroundColor = ApplicationColors.color(
            "Window", fallback: .textBackgroundColor)
    }

    func stop() {
        terminalView?.stopSession()
        terminalView?.removeFromSuperview()
        terminalView = nil
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        if errorLabel.superview == nil {
            view.addSubview(errorLabel)
            NSLayoutConstraint.activate([
                errorLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
                errorLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12),
                errorLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            ])
        }
    }

    static func shellEnvironment(preferences: AppPreferences, inherited: [String: String]) -> [String] {
        var environment = inherited
        let gitDirectory = preferences.gitExecutablePath.contains("/")
            ? ((preferences.gitExecutablePath as NSString).expandingTildeInPath as NSString).deletingLastPathComponent : ""
        let paths =
            [gitDirectory, "/opt/homebrew/bin", "/usr/local/bin"]
            + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(
                String.init)
        var seen = Set<String>()
        environment["PATH"] = paths.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(
            separator: ":")
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "GitExtensionsMac"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        environment.removeValue(forKey: "GIT_TERMINAL_PROMPT")
        return environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }
}

final class ConsoleTerminalView: LocalProcessTerminalView {
    private(set) lazy var sizeCoalescer = ConsoleSizeCoalescer(terminal: self)

    func stopSession() {
        sizeCoalescer.cancel()
        guard process.running else { return }
        let pid = process.shellPid
        let foreground = tcgetpgrp(process.childfd)
        if foreground > 0, foreground != getpgrp() { kill(-foreground, SIGHUP) }
        if pid > 0 { kill(-pid, SIGHUP) }
        let reaper = ConsoleProcessReaper(pid: pid)
        reaper.start()
        terminate()
    }

    deinit { stopSession() }
}

final class ConsoleSizeCoalescer: TerminalViewDelegate {
    static var delay: TimeInterval = 0.15
    private weak var terminal: ConsoleTerminalView?
    private var pending: DispatchWorkItem?

    init(terminal: ConsoleTerminalView) {
        self.terminal = terminal
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let terminal else { return }
            if NSEvent.pressedMouseButtons & 1 != 0 {
                sizeChanged(source: source, newCols: newCols, newRows: newRows)
                return
            }
            pending = nil
            terminal.sizeChanged(source: source, newCols: newCols, newRows: newRows)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    func setTerminalTitle(source: TerminalView, title: String) { terminal?.setTerminalTitle(source: source, title: title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { terminal?.hostCurrentDirectoryUpdate(source: source, directory: directory) }
    func send(source: TerminalView, data: ArraySlice<UInt8>) { terminal?.send(source: source, data: data) }
    func scrolled(source: TerminalView, position: Double) { terminal?.scrolled(source: source, position: position) }
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) { terminal?.requestOpenLink(source: source, link: link, params: params) }
    func bell(source: TerminalView) { terminal?.bell(source: source) }
    func clipboardCopy(source: TerminalView, content: Data) { terminal?.clipboardCopy(source: source, content: content) }
    func clipboardRead(source: TerminalView) -> Data? { terminal?.clipboardRead(source: source) }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) { terminal?.iTermContent(source: source, content: content) }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) { terminal?.rangeChanged(source: source, startY: startY, endY: endY) }
}

private final class ConsoleProcessReaper {
    private let pid: pid_t
    private let source: DispatchSourceProcess

    init(pid: pid_t) {
        self.pid = pid
        source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
    }

    func start() {
        source.setEventHandler { [self] in
            var status: Int32 = 0
            _ = waitpid(pid, &status, WNOHANG)
            source.cancel()
            source.setEventHandler(handler: nil)
        }
        source.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !source.isCancelled else { return }
            kill(pid, SIGKILL)
        }
    }
}
