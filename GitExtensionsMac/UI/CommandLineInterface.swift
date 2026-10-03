import Foundation
import GitExtensionsCore
import GitCommands
import AppKit

struct CommandLineRequest: Equatable {
    enum Verb: String, CaseIterable {
        case about, add, addfiles, apply, applypatch, blame, blamehistory, branch, browse
        case checkout, checkoutbranch, checkoutrevision, cherry, cleanup, clone, commit, difftool
        case filehistory, fileeditor, formatpatch, gitignore, help, initialize = "init", merge
        case mergeconflicts, mergetool, openrepo, pull, push, rebase, remotes, revert, reset
        case searchfile, settings, stash, synchronize, tag, viewdiff, viewpatch, uninstall
    }
    var verb: Verb
    var arguments: [String]
    var options: [String: String?]
    var repository: URL?
    var currentDirectory: URL
    var selection: [RevisionID] = []
    var fileHistory: FileHistoryBrowseRequest?
    var commitArgument: String?
    var revisionFilter = ""
    var pathFilter: String?

    func has(_ name: String) -> Bool { options.keys.contains(name) }
    func value(_ name: String) -> String? { options[name] ?? nil }
    func path(_ value: String) -> URL {
        URL(fileURLWithPath: (value as NSString).expandingTildeInPath, relativeTo: URL(fileURLWithPath: currentDirectory.path, isDirectory: true)).standardizedFileURL
    }
    func relativeFile(_ value: String, root: URL) -> String {
        let url = path(value)
        let prefix = root.standardizedFileURL.path + "/"
        return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : value
    }

    static func parse(_ supplied: [String], currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) throws -> Self? {
        let args = Array(supplied.dropFirst()).filter { !$0.hasPrefix("-psn_") }
        guard !args.isEmpty else { return nil }
        if args.contains("--dashboard") || args.contains("--mock") { return nil }
        var repository: URL?
        var remaining = args
        if let index = remaining.firstIndex(of: "--repository") {
            guard index + 1 < remaining.count, !remaining[index + 1].hasPrefix("--") else { throw CLIError.invalid("--repository requires a path.") }
            repository = URL(fileURLWithPath: (remaining[index + 1] as NSString).expandingTildeInPath, relativeTo: URL(fileURLWithPath: currentDirectory.path, isDirectory: true)).standardizedFileURL
            remaining.removeSubrange(index...index + 1)
        }
        let first = remaining.first ?? "browse"
        let verb: Verb
        var trailing: [String]
        if let known = Verb(rawValue: first) { verb = known; trailing = Array(remaining.dropFirst()) }
        else if first == "--help" || first == "-h" || first == "-?" { verb = .help; trailing = [] }
        else if first.hasPrefix("git://") || first.hasPrefix("http://") || first.hasPrefix("https://") {
            verb = .clone; trailing = [first]
        } else if first.hasPrefix("github-mac://openRepo/") || first.hasPrefix("github-windows://openRepo/") {
            verb = .clone; trailing = [String(first[first.range(of: "openRepo/")!.upperBound...])]
        } else if repository != nil && (first == "browse" || first.hasPrefix("--")) {
            verb = .browse; trailing = remaining
        } else {
            let url = URL(fileURLWithPath: (first as NSString).expandingTildeInPath, relativeTo: URL(fileURLWithPath: currentDirectory.path, isDirectory: true)).standardizedFileURL
            if remaining.count == 1 && FileManager.default.fileExists(atPath: url.path) {
                verb = .browse; trailing = [first]
            } else { verb = .help; trailing = [] }
        }
        var options: [String: String?] = [:]
        var index = 0
        while index < trailing.count {
            let argument = trailing[index]
            if argument.hasPrefix("--") {
                let key = String(argument.drop(while: { $0 == "-" }))
                guard key == "select-revision" || !options.keys.contains(key) else { throw CLIError.invalid("Duplicate command-line option: \(argument)") }
                if index + 1 < trailing.count && !trailing[index + 1].hasPrefix("--") {
                    index += 1; options.updateValue(trailing[index], forKey: key)
                } else { options.updateValue(nil, forKey: key) }
            }
            index += 1
        }
        var result = Self(verb: verb, arguments: trailing, options: options, repository: repository, currentDirectory: currentDirectory)
        result.selection = RepositoryOpeningSelection.parse(args)
        result.fileHistory = FileHistoryBrowseRequest.parse(args)
        func equals(_ key: String) -> String? { trailing.first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) } }
        result.revisionFilter = equals("-filter") ?? ""
        result.pathFilter = equals("--pathFilter")
        result.commitArgument = equals("-commit").flatMap { $0.isEmpty ? nil : $0 }
        if trailing.isEmpty, let missing = Self.missingFileMessages[verb] {
            throw CLIError.message(missing.text, caption: missing.caption)
        }
        if [.filehistory, .blamehistory].contains(verb), trailing.count > 1 {
            guard (try? ObjectID.parse(trailing[1])) != nil else { throw CLIError.silent("Invalid file-history revision: \(trailing[1])") }
            if trailing.count > 2 && trailing[2] != "--filter-by-revision" { throw CLIError.silent("Expected --filter-by-revision.") }
        }
        return result
    }

    static let missingFileMessages: [Verb: (text: String, caption: String)] = [
        .blame: ("Cannot open blame, there is no file selected.", "Blame"),
        .difftool: ("Cannot open difftool, there is no file selected.", "Difftool"),
        .blamehistory: ("Cannot open blame / file history, there is no file selected.", "Blame / file history"),
        .filehistory: ("Cannot open blame / file history, there is no file selected.", "Blame / file history"),
        .fileeditor: ("Cannot open file editor, there is no file selected.", "File editor"),
        .revert: ("Cannot open revert, there is no file selected.", "Revert")
    ]

    var opensDashboardWithoutRepository: Bool { [.browse, .openrepo].contains(verb) }

    var needsRepository: Bool {
        ![.about, .help, .clone, .initialize, .viewpatch, .uninstall, .fileeditor, .settings].contains(verb)
    }

    var succeedsOnClose: Bool {
        [.about, .help, .add, .addfiles, .apply, .applypatch, .blame, .blamehistory, .filehistory,
         .cleanup, .clone, .commit, .formatpatch, .initialize, .merge, .mergeconflicts, .mergetool,
         .rebase, .remotes, .stash, .viewpatch, .gitignore].contains(verb)
    }

    func repositoryLocation() throws -> URL? {
        if let repository { return repository }
        if verb == .openrepo, let first = arguments.first,
           let directory = try CommandLineRepository.repositoryPathFile(path(first)) { return directory }
        return CommandLineRepository.discover(candidate: arguments.first.map(path), currentDirectory: currentDirectory)
    }
}

enum CommandLineDispatch {
    case presentation
    case completed(Bool)
}

enum CLIError: LocalizedError, Equatable {
    case invalid(String)
    case message(String, caption: String)
    case silent(String)
    static let notValidRepository = CLIError.message("The current directory is not a valid git repository.", caption: "Error")
    var errorDescription: String? {
        switch self {
        case .invalid(let text), .silent(let text), .message(let text, _): text
        }
    }
    var caption: String? {
        switch self {
        case .invalid: "Invalid Git Extensions command line"
        case .message(_, let caption): caption
        case .silent: nil
        }
    }
}

@MainActor
enum CommandLineSession {
    static var exitStatus: Int32 = 0
    static var active = false
    static var present: (_ text: String, _ caption: String) -> Void = { text, caption in
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = caption
        alert.informativeText = text
        alert.runModal()
    }
    static func fail(_ error: Error) {
        exitStatus = -1
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        let caption = (error as? CLIError).map { $0.caption } ?? "Invalid Git Extensions command line"
        if let caption { present(error.localizedDescription, caption) }
    }
    static let header = "Supported commandline arguments for\nGitExtensionsMac (the executable in GitExtensionsMac.app/Contents/MacOS):"
    static let usage = """
    Run the app executable directly, or open -n -a GitExtensionsMac --args <command>.
    Repository discovery uses the first file/path argument, then the current directory.
    --repository <path> explicitly selects a repository. Existing --dashboard and
    --select-revision <ObjectID|WORKTREE|INDEX> launch arguments remain supported.

    [path]
    browse [path] [-filter=<revision filter>] [--pathFilter=<filepath>]
           [-commit=<selectedSha>[,<firstSha>]]
    about
    add / addfiles [filename ...]
    apply / applypatch [filename]
    blame filename [line]
    blamehistory / filehistory filename [ObjectID [--filter-by-revision]]
    branch
    checkout / checkoutbranch
    checkoutrevision
    cherry
    cleanup
    clone [source]
    commit [--quiet] [--message commitmessage]
    difftool filename
    fileeditor filename
    formatpatch
    gitignore
    help
    init [path]
    merge [--branch name]
    mergeconflicts / mergetool [--quiet]
    openrepo [repository-path-file] [-filter=<revision filter>]
    pull [--rebase] [--merge] [--fetch] [--autostash] [--quiet] [--remotebranch name]
    push [--quiet]
    rebase [--branch name]
    remotes
    reset [filename ...]
    revert filename ... (reset file changes, not commit revert)
    searchfile (prints the chosen absolute filename)
    settings
    stash
    synchronize [pull options] [--quiet] [--message commitmessage]
    tag
    viewdiff
    viewpatch [filename]
    uninstall (remove this application's Git editor configuration)

    Commands open the existing interactive workflows. --quiet skips an empty Commit
    or conflict dialog; Pull/Push execute immediately. Closing/cancelling a workflow
    returns its success/failure status. A missing file or repository shows a message
    and returns -1; an unresolved -commit prints "No commit found matching" to stderr.
    Unknown commands show this usage, as upstream. No embedded Git console or Windows
    shell/registry integration is installed.
    """
}
