import SwiftUI

@main
struct GitExtensionsMacApp: App {
    private let launch: RepositoryBrowserLaunch

    init() {
        let arguments = CommandLine.arguments
        if arguments.contains("--dashboard") {
            launch = .dashboard
            return
        }
        if arguments.contains("--mock") {
            launch = .mock
            return
        }

        let explicitPath: String? = arguments.firstIndex(of: "--repository").flatMap { index in
            let valueIndex = arguments.index(after: index)
            return valueIndex < arguments.endIndex ? arguments[valueIndex] : nil
        }
        if let explicitPath {
            launch = .repository(URL(fileURLWithPath: explicitPath, isDirectory: true))
        } else if AppSettingsStore.shared.preferences.reopenLastRepository,
                  let path = AppSettingsStore.shared.lastRepositoryPath,
                  FileManager.default.fileExists(atPath: path) {
            launch = .repository(URL(fileURLWithPath: path, isDirectory: true))
        } else {
            launch = .dashboard
        }
    }

    var body: some Scene {
        WindowGroup("gitextensions — Git Extensions", id: "repository-browser") {
            RepositoryBrowserHost(launch: launch)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            GitExtensionsMenuCommands()
        }
    }
}

private struct GitExtensionsMenuCommands: Commands {
    private func perform(_ title: String) {
        BrowserCommandCenter.perform(title)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New repository…") { perform("New repository") }
            Button("Open repository…") { perform("Open repository") }
                .keyboardShortcut("o", modifiers: .command)
            Button("Clone repository…") { perform("Clone repository") }

            Menu("Recent repositories") {
                ForEach(AppSettingsStore.shared.recentRepositories.prefix(10), id: \.path) { repository in
                    Button(URL(fileURLWithPath: repository.path).lastPathComponent) {
                        perform("Open recent repository: \(repository.path)")
                    }
                }
                Divider()
                Button("Clear recent repositories") { perform("Clear recent repositories") }
            }

            Divider()
            Button("Close (go to Dashboard)") { perform("Close (go to Dashboard)") }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }

        CommandMenu("Dashboard") {
            Button("Refresh") { perform("Refresh Dashboard") }
                .keyboardShortcut("r", modifiers: [.command, .option])
        }

        CommandMenu("Repository") {
            Button("Refresh") { perform("Refresh") }
                .keyboardShortcut("r", modifiers: .command)
            Button("File Explorer") { perform("File Explorer") }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("Remote repositories…") { perform("Remote repositories") }
            Divider()
            Button("Manage submodules…") { perform("Manage submodules") }
            Button("Update all submodules") { perform("Update all submodules") }
            Button("Synchronize all submodules") { perform("Synchronize all submodules") }
            Divider()
            Button("Manage worktrees…") { perform("Manage worktrees") }
            Divider()
            Button("Edit .gitignore") { perform("Edit .gitignore") }
            Button("Edit .git/info/exclude") { perform("Edit .git/info/exclude") }
            Button("Edit .gitattributes") { perform("Edit .gitattributes") }
            Button("Edit .mailmap") { perform("Edit .mailmap") }
            Button("Sparse Working Copy") { perform("Sparse Working Copy") }
            Divider()
            Menu("Git maintenance") {
                Button("Compress git database") { perform("Compress git database") }
                Button("Recover lost objects…") { perform("Recover lost objects") }
                Button("Delete index.lock") { perform("Delete index.lock") }
                Button("Edit .git/config") { perform("Edit .git/config") }
            }
            Button("Repository settings…") { perform("Repository settings") }
        }

        CommandMenu("Commands") {
            Button("Commit…") { perform("Commit") }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            Button("Undo last commit…") { perform("Undo last commit") }
            Button("Pull/Fetch…") { perform("Pull/Fetch") }
            Button("Push…") { perform("Push") }
            Divider()
            Button("Manage stashes…") { perform("Manage stashes") }
            Button("Reset changes…") { perform("Reset changes") }
            Button("Clean working directory…") { perform("Clean working directory") }
            Divider()
            Button("Create branch…") { perform("Create branch") }
            Button("Delete branch…") { perform("Delete branch") }
            Button("Checkout branch…") { perform("Checkout branch") }
            Button("Merge branches…") { perform("Merge branches") }
            Button("Rebase…") { perform("Rebase") }
            Button("Solve merge conflicts…") { perform("Solve merge conflicts") }
            Divider()
            Button("Create tag…") { perform("Create tag") }
            Button("Delete tag…") { perform("Delete tag") }
            Divider()
            Button("Cherry pick…") { perform("Cherry pick") }
            Button("Archive revision…") { perform("Archive revision") }
            Button("Checkout revision…") { perform("Checkout revision") }
            Button("Bisect…") { perform("Bisect") }
            Button("Show reflog…") { perform("Show reflog") }
            Divider()
            Button("Format patch…") { perform("Format patch") }
            Button("Apply patch…") { perform("Apply patch") }
            Button("View patch file…") { perform("View patch file") }
        }

        CommandMenu("Repository hosts") {
            Button("Fork/Clone repository…") { perform("Fork/Clone repository") }
            Button("View pull requests…") { perform("View pull requests") }
            Button("Create pull request…") { perform("Create pull request") }
            Button("Add upstream remote") { perform("Add upstream remote") }
        }

        CommandMenu("Plugins") {
            Button("Plugin manager…") { perform("Plugin manager") }
            Button("Plugin settings…") { perform("Plugin settings") }
        }

        CommandMenu("Tools") {
            Button("Git command log") { perform("Git command log") }
            Button("Settings…") { perform("Settings") }
                .keyboardShortcut(",", modifiers: .command)
            Divider()
            Button("Translation") { perform("Translation") }
            Button("Check for updates") { perform("Check for updates") }
        }

        CommandGroup(replacing: .help) {
            Button("Git Extensions manual") { perform("Git Extensions manual") }
            Button("Keyboard shortcuts") { perform("Keyboard shortcuts") }
            Button("Report an issue") { perform("Report an issue") }
        }
    }
}
