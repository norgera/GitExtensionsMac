import AppKit
import Darwin
import SwiftTerm
import Testing

@testable import GitCommands
@testable import GitUI

extension UIIntegrationTests {
    @Suite("Embedded console")
    @MainActor
    enum EmbeddedConsoleTests {
        private static func send(_ text: String, to console: EmbeddedConsoleViewController) throws {
            let terminal = try #require(console.terminalView)
            terminal.send(data: Array(text.utf8)[...])
        }

        private static func text(_ console: EmbeddedConsoleViewController) -> String {
            guard let terminal = console.terminalView?.getTerminal() else { return "" }
            return String(decoding: terminal.getBufferAsData(), as: UTF8.self)
        }

        private static func wait(_ message: String, until condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while !condition() {
                try #require(ContinuousClock.now < deadline, Comment(rawValue: message))
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        private static func environment(_ fixture: FileStatusFixture, expected: URL? = nil) -> [String: String] {
            ProcessInfo.processInfo.environment.merging([
                "HOME": fixture.root.path, "ZDOTDIR": fixture.root.path, "ENV": "/dev/null",
                "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "LC_ALL": "en_US.UTF-8",
                "CONSOLE_EXPECTED_DIRECTORY": expected?.path ?? "",
            ]) { _, value in value }
        }

        private static let directoryCheck = "[ \"$(pwd -P)\" = \"$(cd \"$CONSOLE_EXPECTED_DIRECTORY\" && pwd -P)\" ] && printf '__CWD_OK__\\n'\r"

        @Test("Environment and preference persistence")
        static func environmentAndPreferences() throws {
            var preferences = AppPreferences()
            preferences.showConsoleTab = false
            preferences.gitExecutablePath = "/fixture tools/git"
            let decoded = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(preferences))
            #expect(!decoded.showConsoleTab)
            #expect(try JSONDecoder().decode(AppPreferences.self, from: Data("{}".utf8)).showConsoleTab)
            #expect(ApplicationHotkeys.chord("focus.console", overrides: [:]) == .init("6", .control))
            let values = EmbeddedConsoleViewController.shellEnvironment(
                preferences: preferences,
                inherited: [
                    "PATH": "/usr/bin:/bin:/usr/bin", "LANG": "fixture.UTF-8", "GIT_TERMINAL_PROMPT": "0", "SSH_AUTH_SOCK": "/fixture-agent",
                ])
            #expect(values.contains("TERM=xterm-256color"))
            #expect(values.contains("COLORTERM=truecolor"))
            #expect(values.contains("SSH_AUTH_SOCK=/fixture-agent"))
            #expect(values.contains("LANG=fixture.UTF-8"))
            #expect(!values.contains { $0.hasPrefix("GIT_TERMINAL_PROMPT=") })
            #expect(values.first { $0.hasPrefix("PATH=") } == "PATH=/fixture tools:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
            preferences.gitExecutablePath = "git"
            let bare = EmbeddedConsoleViewController.shellEnvironment(preferences: preferences, inherited: ["PATH": "/usr/bin"])
            #expect(bare.contains("PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin"))
            #expect(EmbeddedConsoleViewController.changeDirectoryInput("/a b/it's") == "\u{1}\u{b}cd '/a b/it'\\''s'\r")
        }

        @Test("Interactive repository shell, resize, interruption and restart")
        static func interactiveShell() async throws {
            let fixture = try FileStatusFixture.make()
            defer { fixture.remove() }
            let directory = fixture.repo.appendingPathComponent("space é ' $folder", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let console = EmbeddedConsoleViewController()
            console.setRepository(directory)
            #expect(console.terminalView == nil)
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = console
            window.makeKeyAndOrderFront(nil)
            defer {
                console.stop()
                window.close()
            }
            var preferences = AppPreferences()
            preferences.shellPath = "/bin/zsh"
            console.activate(preferences: preferences, environment: environment(fixture, expected: directory))
            let terminal = try #require(console.terminalView)
            let pid = terminal.process.shellPid
            try #require(pid > 0 && terminal.process.running)
            #expect(window.firstResponder === terminal)
            try send("stty -echo; printf '\\n__READY__\\n'\r", to: console)
            try await wait("shell prompt and input") { text(console).contains("\n__READY__\n") }
            try send(directoryCheck, to: console)
            try await wait("repository directory") { text(console).contains("__CWD_OK__\n") }
            try send("printf '\\033[31mé λ\\033[0m\\n'; test -t 0 && test -t 1 && test -t 2 && printf '__PTY__\\n'\r", to: console)
            try await wait("UTF-8, directory and real PTY") { text(console).contains("__PTY__\n") }
            #expect(text(console).contains("é λ"))
            #expect(!text(console).contains("\u{1b}[31m"))
            console.activate(preferences: preferences, environment: environment(fixture))
            #expect(console.terminalView === terminal && terminal.process.shellPid == pid)
            window.setContentSize(.init(width: 1040, height: 500))
            console.view.layoutSubtreeIfNeeded()
            let size = terminal.getWindowSize()
            try #require(size.ws_col > 80 && size.ws_row > 20)
            try await wait("PTY size applied") {
                var applied = winsize()
                return ioctl(terminal.process.childfd, TIOCGWINSZ, &applied) == 0 && applied.ws_col == size.ws_col && applied.ws_row == size.ws_row
            }
            try send("stty size; printf '__SIZE__\\n'\r", to: console)
            try await wait("PTY resize") { text(console).contains("__SIZE__\n") }
            #expect(text(console).contains("\(size.ws_row) \(size.ws_col)"))
            try send("sleep 30\r", to: console)
            try await wait("foreground job") { tcgetpgrp(terminal.process.childfd) != pid }
            try send("\u{3}", to: console)
            try send("printf '__INTERRUPTED__\\n'\r", to: console)
            try await wait("Ctrl-C returns to shell") { text(console).contains("__INTERRUPTED__\n") }
            try send(
                "printf 'console fixture\\n' > 'console é.txt'; git add -- 'console é.txt'; git commit -q -m 'Console fixture'; printf '__COMMITTED__\\n'\r",
                to: console)
            try await wait("Git mutation completes") { text(console).contains("__COMMITTED__\n") }
            #expect(try fixture.git(["show", "HEAD:space é ' $folder/console é.txt"]) == "console fixture\n")
            #expect(try fixture.git(["status", "--porcelain"]).isEmpty)
            try send("exit\r", to: console)
            try await wait("shell exits") { !terminal.process.running }
            console.activate(preferences: preferences, environment: environment(fixture))
            let restarted = try #require(console.terminalView)
            #expect(restarted !== terminal && restarted.process.running && restarted.process.shellPid != pid)
            let restartedPID = restarted.process.shellPid
            console.stop()
            try await wait("shell reaped on close") { kill(restartedPID, 0) == -1 && errno == ESRCH }
        }

        @Test("Dragging a resize redraws the prompt once")
        static func dragResize() async throws {
            let fixture = try FileStatusFixture.make()
            defer { fixture.remove() }
            try "PROMPT='~/github/react-spectrum '\n".write(to: fixture.root.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
            let console = EmbeddedConsoleViewController()
            console.setRepository(fixture.repo)
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = console
            window.makeKeyAndOrderFront(nil)
            defer {
                console.stop()
                window.close()
            }
            var preferences = AppPreferences()
            preferences.shellPath = "/bin/zsh"
            var shellEnvironment = environment(fixture)
            shellEnvironment.removeValue(forKey: "ENV")
            console.activate(preferences: preferences, environment: shellEnvironment)
            try await wait("prompt") { text(console).contains("~/github/react-spectrum ") }
            for width in Array(stride(from: 400, through: 60, by: -4)) + Array(stride(from: 64, through: 400, by: 4)) {
                window.setContentSize(.init(width: CGFloat(width), height: 300))
                console.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(8))
            }
            try await Task.sleep(for: .seconds(1))
            let lines = text(console).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            #expect(lines == ["~/github/react-spectrum"])
        }

        @Test("Browser Console tab, shortcut, preference and close")
        static func browserConsole() async throws {
            let fixture = try FileStatusFixture.make()
            defer { fixture.remove() }
            try fixture.write("base.txt", "fixture\n")
            try fixture.commitAll("base")
            let store = AppSettingsStore.shared
            let saved = store.preferences
            var preferences = saved
            preferences.showConsoleTab = true
            preferences.shellPath = "/bin/zsh"
            store.save(preferences)
            defer { store.save(saved) }
            let browser = RepositoryBrowserViewController(repositoryModule: GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit()))
            browser.consoleController.inheritedEnvironment = environment(fixture)
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = browser
            window.makeKeyAndOrderFront(nil)
            defer {
                browser.viewWillDisappear()
                window.close()
            }
            try await wait("browser repository") { browser.repositoryIdentity != nil && !browser.revisions.isEmpty }
            #expect(browser.consoleController.terminalView == nil)
            let event = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 1,
                    windowNumber: window.windowNumber, context: nil, characters: "6", charactersIgnoringModifiers: "6", isARepeat: false, keyCode: 22))
            #expect(window.performKeyEquivalent(with: event))
            let terminal = try #require(browser.consoleController.terminalView)
            #expect(window.firstResponder === terminal)
            #expect(terminal.process.running)
            let pid = terminal.process.shellPid
            preferences.showConsoleTab = false
            store.save(preferences)
            #expect(browser.consoleController.terminalView == nil)
            try await wait("disabled console stops its shell") { kill(pid, 0) == -1 && errno == ESRCH }
            #expect(window.performKeyEquivalent(with: event))
            #expect(browser.consoleController.terminalView == nil)
            preferences.showConsoleTab = true
            store.save(preferences)
            #expect(window.performKeyEquivalent(with: event))
            let reopened = try #require(browser.consoleController.terminalView)
            let reopenedPID = reopened.process.shellPid
            window.close()
            #expect(browser.consoleController.terminalView == nil)
            try await wait("window close reaps console shell") { kill(reopenedPID, 0) == -1 && errno == ESRCH }
        }

        @Test("Repository changes and invalid shell")
        static func repositoryChanges() async throws {
            let fixture = try FileStatusFixture.make()
            defer { fixture.remove() }
            let console = EmbeddedConsoleViewController()
            console.setRepository(fixture.repo)
            var preferences = AppPreferences()
            preferences.shellPath = "/missing-fixture-shell"
            console.activate(preferences: preferences, environment: environment(fixture))
            #expect(console.terminalView == nil)
            let other = fixture.root.appendingPathComponent("other $repo 'é'", isDirectory: true)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            preferences.shellPath = "/bin/zsh"
            console.activate(preferences: preferences, environment: environment(fixture, expected: other))
            defer { console.stop() }
            let terminal = try #require(console.terminalView)
            let pid = terminal.process.shellPid
            try send("stty -echo; printf '\\n__READY__\\n'\r", to: console)
            try await wait("shell ready") { text(console).contains("\n__READY__\n") }
            console.setRepository(other)
            #expect(console.repositoryURL == other.standardizedFileURL)
            try send(directoryCheck, to: console)
            try await wait("running shell changes directory") { text(console).contains("__CWD_OK__\n") }
            #expect(console.terminalView === terminal && terminal.process.running && terminal.process.shellPid == pid)
            console.setRepository(other)
            console.activate(preferences: preferences, environment: environment(fixture))
            #expect(console.terminalView === terminal && terminal.process.shellPid == pid)
        }
    }
}
