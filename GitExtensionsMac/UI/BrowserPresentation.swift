import Foundation
import GitCommands
import GitExtensionsCore


enum BrowserPresentation {
    static let applicationName = "Git Extensions"


    static func windowTitle(repositoryURL: URL?, branch: String?, pathFilter: String? = nil,
                            fileManager: FileManager = .default) -> String {
        guard let repositoryURL, isValidGitWorkingDir(repositoryURL, fileManager: fileManager) else { return applicationName }
        let branchName = branch?.trimmingCharacters(in: .whitespaces).isEmpty == false ? branch! : "no branch"
        return "\(pathFilterPrefix(pathFilter))\(repositoryDescription(repositoryURL, fileManager: fileManager)) (\(branchName)) - \(applicationName)"
    }

    private static func pathFilterPrefix(_ pathFilter: String?) -> String {
        guard let path = pathFilter?.trimmingCharacters(in: .whitespaces), !path.isEmpty else { return "" }
        let file = (path.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) as NSString).lastPathComponent
        if !file.isEmpty { return "\"\(file)\" " }
        return (path.hasPrefix("\"") && path.hasSuffix("\"") ? path : "\"\(path)\"") + " "
    }


    static func repositoryDescription(_ repositoryURL: URL, fileManager: FileManager = .default) -> String {
        let directory = repositoryURL.standardizedFileURL
        var root = directory
        var parent = directory.deletingLastPathComponent()
        while parent.path != root.path, parent.path != "/", fileManager.fileExists(atPath: parent.path) {
            if isValidGitWorkingDir(parent, fileManager: fileManager) { root = parent }
            let next = parent.deletingLastPathComponent()
            if next.path == parent.path { break }
            parent = next
        }
        func shortName(_ url: URL) -> String {
            guard fileManager.fileExists(atPath: url.path) else { return url.lastPathComponent }
            if let description = repositoryDescriptionFile(url, fileManager: fileManager) { return description }
            var current = url
            let uninformative = try? NSRegularExpression(pattern: "^(app|(repo(sitory)?))$", options: [.caseInsensitive])
            while current.path != root.path, current.path != "/",
                  uninformative?.firstMatch(in: current.lastPathComponent, range: NSRange(current.lastPathComponent.startIndex..., in: current.lastPathComponent)) != nil,
                  !isValidGitWorkingDir(current.deletingLastPathComponent(), fileManager: fileManager) {
                current = current.deletingLastPathComponent()
            }
            return current.lastPathComponent
        }
        let name = shortName(directory)
        return directory.path == root.path ? name : "\(name) < \(shortName(root))"
    }

    private static func repositoryDescriptionFile(_ workingDir: URL, fileManager: FileManager) -> String? {
        let dotGit = workingDir.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        var gitDir = workingDir
        if fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                gitDir = dotGit
            } else if let text = try? String(contentsOf: dotGit, encoding: .utf8), text.hasPrefix("gitdir:") {
                let path = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                gitDir = path.hasPrefix("/") ? URL(fileURLWithPath: path) : workingDir.appendingPathComponent(path).standardizedFileURL
            }
        }
        guard let text = try? String(contentsOf: gitDir.appendingPathComponent("description"), encoding: .utf8),
              let first = text.components(separatedBy: .newlines).first,
              !first.trimmingCharacters(in: .whitespaces).isEmpty,
              first != "Unnamed repository; edit this file 'description' to name the repository." else { return nil }
        return first
    }


    static func isValidGitWorkingDir(_ url: URL, fileManager: FileManager = .default) -> Bool {
        if fileManager.fileExists(atPath: url.appendingPathComponent(".git").path) { return true }
        return fileManager.fileExists(atPath: url.appendingPathComponent("HEAD").path)
            && fileManager.fileExists(atPath: url.appendingPathComponent("objects").path)
            && fileManager.fileExists(atPath: url.appendingPathComponent("refs").path)
    }
}


enum BrowserGitAction: Equatable, Sendable {
    case none, rebase, merge, patch

    enum Button: Equatable, Sendable { case resolve, `continue`, abort, more }


    static func detect(rebase: Bool, merge: Bool, patch: Bool) -> Self {
        rebase ? .rebase : merge ? .merge : patch ? .patch : .none
    }


    func presentation(hasConflicts: Bool) -> (message: String, buttons: [Button])? {
        let name: String
        var buttons: [Button]
        switch self {
        case .none:
            guard hasConflicts else { return nil }
            return ("There are unresolved merge conflicts.", [.resolve])
        case .rebase: name = "Rebase"; buttons = [.abort, .more]
        case .merge: name = "Merge"; buttons = [.abort]
        case .patch: name = "Patch"; buttons = [.abort, .more]
        }
        buttons.insert(hasConflicts ? .resolve : .continue, at: 0)
        return (hasConflicts ? "\(name) is currently in progress with merge conflicts." : "\(name) is currently in progress.", buttons)
    }
}
