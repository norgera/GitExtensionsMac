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
    @ObservedObject private var availability = BrowserCommandAvailability.shared

    private func perform(_ command: BrowserCommand) {
        BrowserCommandCenter.perform(command)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New repository…") { perform(.unavailable("New repository")) }
            Button("Open repository…") { perform(.openRepository) }
                .keyboardShortcut("o", modifiers: .command)
            Button("Clone repository…") { perform(.cloneRepository) }

            Menu("Recent repositories") {
                ForEach(AppSettingsStore.shared.recentRepositories.prefix(10), id: \.path) { repository in
                    Button(URL(fileURLWithPath: repository.path).lastPathComponent) {
                        perform(.openRecentRepository(URL(fileURLWithPath: repository.path, isDirectory: true)))
                    }
                }
                Divider()
                Button("Clear recent repositories") { perform(.clearRecentRepositories) }
            }

            Divider()
            Button("Close (go to Dashboard)") { perform(.closeToDashboard) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }

        CommandMenu("Dashboard") {
            Button("Refresh") { perform(.unavailable("Refresh Dashboard")) }
                .keyboardShortcut("r", modifiers: [.command, .option])
        }

        CommandMenu("Repository") {
            Button("Refresh") { perform(.refresh) }
                .keyboardShortcut("r", modifiers: .command)
            Button("File Explorer") { perform(.unavailable("File Explorer")) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("Remote repositories…") { perform(.remoteRepositories) }
            Divider()
            Button("Manage submodules…") { perform(.unavailable("Manage submodules")) }
            Button("Update all submodules") { perform(.unavailable("Update all submodules")) }
            Button("Synchronize all submodules") { perform(.unavailable("Synchronize all submodules")) }
            Divider()
            Button("Manage worktrees…") { perform(.unavailable("Manage worktrees")) }
            Divider()
            Button("Edit .gitignore") { perform(.unavailable("Edit .gitignore")) }
            Button("Edit .git/info/exclude") { perform(.unavailable("Edit .git/info/exclude")) }
            Button("Edit .gitattributes") { perform(.unavailable("Edit .gitattributes")) }
            Button("Edit .mailmap") { perform(.unavailable("Edit .mailmap")) }
            Button("Sparse Working Copy") { perform(.unavailable("Sparse Working Copy")) }
            Divider()
            Menu("Git maintenance") {
                Button("Compress git database") { perform(.unavailable("Compress git database")) }
                Button("Recover lost objects…") { perform(.unavailable("Recover lost objects")) }
                Button("Delete index.lock") { perform(.unavailable("Delete index.lock")) }
                Button("Edit .git/config") { perform(.unavailable("Edit .git/config")) }
            }
            Button("Repository settings…") { perform(.unavailable("Repository settings")) }
        }

        CommandMenu("Commands") {
            Button("Commit…") { perform(.commit) }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            Button("Undo last commit…") { perform(.unavailable("Undo last commit")) }
            Button("Pull/Fetch…") { perform(.pullFetch) }
            Button("Push…") { perform(.push) }
            Divider()
            Button("Manage stashes…") { perform(.manageStashes) }
            Button("Reset changes…") { perform(.unavailable("Reset changes")) }
            Button("Clean working directory…") { perform(.unavailable("Clean working directory")) }
            Divider()
            Button("Create branch…") { perform(.unavailable("Create branch")) }
            Button("Delete branch…") { perform(.unavailable("Delete branch")) }
            Button("Checkout branch…") { perform(.unavailable("Checkout branch")) }
            Button("Merge branches…") { perform(.mergeBranches) }
                .keyboardShortcut("m", modifiers: .control)
                .disabled(!availability.canMerge)
            Button("Rebase…") { perform(.rebase) }
            Button("Solve merge conflicts…") { perform(.solveMergeConflicts) }
            Divider()
            Button("Create tag…") { perform(.unavailable("Create tag")) }
            Button("Delete tag…") { perform(.unavailable("Delete tag")) }
            Divider()
            Button("Cherry pick…") { perform(.cherryPick) }
            Button("Archive revision…") { perform(.unavailable("Archive revision")) }
            Button("Checkout revision…") { perform(.unavailable("Checkout revision")) }
            Button("Bisect…") { perform(.unavailable("Bisect")) }
            Button("Show reflog…") { perform(.unavailable("Show reflog")) }
            Divider()
            Button("Format patch…") { perform(.unavailable("Format patch")) }
            Button("Apply patch…") { perform(.unavailable("Apply patch")) }
            Button("View patch file…") { perform(.unavailable("View patch file")) }
        }

        CommandMenu("Repository hosts") {
            Button("Fork/Clone repository…") { perform(.unavailable("Fork/Clone repository")) }
            Button("View pull requests…") { perform(.unavailable("View pull requests")) }
            Button("Create pull request…") { perform(.unavailable("Create pull request")) }
            Button("Add upstream remote") { perform(.unavailable("Add upstream remote")) }
        }

        CommandMenu("Plugins") {
            Button("Plugin manager…") { perform(.unavailable("Plugin manager")) }
            Button("Plugin settings…") { perform(.unavailable("Plugin settings")) }
        }

        CommandMenu("Tools") {
            Button("Git command log") { perform(.unavailable("Git command log")) }
            Button("Settings…") { perform(.settings) }
                .keyboardShortcut(",", modifiers: .command)
            Divider()
            Button("Translation") { perform(.unavailable("Translation")) }
            Button("Check for updates") { perform(.unavailable("Check for updates")) }
        }

        CommandGroup(replacing: .help) {
            Button("Git Extensions manual") { perform(.unavailable("Git Extensions manual")) }
            Button("Keyboard shortcuts") { perform(.unavailable("Keyboard shortcuts")) }
            Button("Report an issue") { perform(.unavailable("Report an issue")) }
        }
    }
}
