import CoreGraphics
import Foundation
import GitExtensionsCore


package enum RepositoryAnchor: String, Codable, Sendable, CaseIterable {
    case anchoredInTop = "Pinned"
    case anchoredInRecent = "AllRecent"
    case none = "None"
}


package struct RepositoryHistoryEntry: Codable, Equatable, Sendable {
    package var path: String
    package var anchor: RepositoryAnchor
    package var category: String?

    package init(path: String, anchor: RepositoryAnchor = .none, category: String? = nil) {
        self.path = path
        self.anchor = anchor
        self.category = category
    }

    private enum CodingKeys: String, CodingKey { case path, anchor, category }
    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        path = try values.decode(String.self, forKey: .path)
        anchor = (try? values.decodeIfPresent(RepositoryAnchor.self, forKey: .anchor)) ?? RepositoryAnchor.none
        category = try values.decodeIfPresent(String.self, forKey: .category)
    }
}


package enum ShorteningRecentRepoPathStrategy: String, Codable, Sendable, CaseIterable {
    case none = "None"
    case mostSignDir = "MostSignDir"
    case middleDots = "MiddleDots"
}


package struct RecentRepositorySettings: Codable, Equatable, Sendable {

    package var historySize = 30

    package var maxTopRepositories = 0
    package var hideTopRepositoriesFromRecentList = false

    package var sortTopRepos = false

    package var sortRecentRepos = false
    package var shorteningStrategy: ShorteningRecentRepoPathStrategy = .none

    package var comboMinWidth = 0

    package var showCurrentBranch = true

    package static let historySizeRange = 10...999
    package static let maxTopRepositoriesRange = 0...1_000_000
    package static let comboMinWidthRange = 0...800

    package static let minimumComboWidth = 30

    package init() {}

    private enum CodingKeys: String, CodingKey {
        case historySize, maxTopRepositories, hideTopRepositoriesFromRecentList, sortTopRepos, sortRecentRepos
        case shorteningStrategy, comboMinWidth, showCurrentBranch
    }
    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        historySize = (try? values.decodeIfPresent(Int.self, forKey: .historySize)) ?? 30
        maxTopRepositories = (try? values.decodeIfPresent(Int.self, forKey: .maxTopRepositories)) ?? 0
        hideTopRepositoriesFromRecentList = (try? values.decodeIfPresent(Bool.self, forKey: .hideTopRepositoriesFromRecentList)) ?? false
        sortTopRepos = (try? values.decodeIfPresent(Bool.self, forKey: .sortTopRepos)) ?? false
        sortRecentRepos = (try? values.decodeIfPresent(Bool.self, forKey: .sortRecentRepos)) ?? false
        shorteningStrategy = (try? values.decodeIfPresent(ShorteningRecentRepoPathStrategy.self, forKey: .shorteningStrategy)) ?? ShorteningRecentRepoPathStrategy.none
        comboMinWidth = (try? values.decodeIfPresent(Int.self, forKey: .comboMinWidth)) ?? 0
        showCurrentBranch = (try? values.decodeIfPresent(Bool.self, forKey: .showCurrentBranch)) ?? true
    }
}


package final class RecentRepoInfo {
    package let repo: RepositoryHistoryEntry
    package fileprivate(set) var caption: String?
    package fileprivate(set) var topRepo: Bool
    package let anchored: Bool

    fileprivate var dirInfo: String?
    fileprivate let shortName: String?
    fileprivate let dirName: String

    package init(repo: RepositoryHistoryEntry, topRepo: Bool, anchored: Bool) {
        self.repo = repo
        self.topRepo = topRepo
        self.anchored = anchored
        let path = RepositoryHistory.normalizedPath(repo.path)
        shortName = RepositoryHistory.directoryName(path)
        dirInfo = RepositoryHistory.parentDirectory(path)
        dirName = dirInfo ?? ""
    }

    fileprivate var fullPath: Bool { dirInfo == nil }
}


package struct RecentRepoSplitter {
    package var maxTopRepositories: Int
    package var hideTopRepositoriesFromRecentList: Bool
    package var shorteningStrategy: ShorteningRecentRepoPathStrategy
    package var sortTopRepos: Bool
    package var sortRecentRepos: Bool
    package var recentReposComboMinWidth: Int

    package var measure: (String) -> CGFloat
    package var homeDirectory: String

    package init(settings: RecentRepositorySettings, homeDirectory: String = NSHomeDirectory(),
                 measure: @escaping (String) -> CGFloat = { CGFloat($0.count) * 7 }) {
        maxTopRepositories = settings.maxTopRepositories
        hideTopRepositoriesFromRecentList = settings.hideTopRepositoriesFromRecentList
        shorteningStrategy = settings.shorteningStrategy
        sortTopRepos = settings.sortTopRepos
        sortRecentRepos = settings.sortRecentRepos
        recentReposComboMinWidth = settings.comboMinWidth
        self.homeDirectory = homeDirectory
        self.measure = measure
    }

    package func split(_ repositories: [RepositoryHistoryEntry]) -> (top: [RecentRepoInfo], recent: [RecentRepoInfo]) {
        var ordered = OrderedCaptions()
        var topRepos: [RecentRepoInfo] = []
        var recentRepos: [RecentRepoInfo] = []
        let middleDot = shorteningStrategy == .middleDots
        let signDir = shorteningStrategy == .mostSignDir
        let n = min(maxTopRepositories, repositories.count)


        for repository in repositories {
            let topRepo = (topRepos.count < n && repository.anchor == .none) || repository.anchor == .anchoredInTop
            let info = RecentRepoInfo(repo: repository, topRepo: topRepo,
                                      anchored: repository.anchor == .anchoredInTop || repository.anchor == .anchoredInRecent)
            if info.topRepo { topRepos.append(info) }
            if !hideTopRepositoriesFromRecentList || !info.topRepo { recentRepos.append(info) }
            if middleDot { addToOrderedMiddleDots(&ordered, info) }
            else { Self.addToOrderedSignDir(&ordered, info, shortenPath: signDir) }
            if let caption = info.caption { info.caption = RepositoryHistory.displayPath(caption, homeDirectory: homeDirectory) }
        }


        var r = topRepos.count - 1
        while topRepos.count > n && r >= 0 {
            let repo = topRepos[r]
            if repo.repo.anchor == .anchoredInTop {
                r -= 1
            } else {
                repo.topRepo = false
                topRepos.remove(at: r)
            }
        }

        func sorted(topRepo: Bool) -> [RecentRepoInfo] {
            ordered.sortedKeys.flatMap { ordered.values[$0] ?? [] }
                .filter { $0.topRepo == topRepo || (!topRepo && !hideTopRepositoriesFromRecentList) }
        }
        return (sortTopRepos ? sorted(topRepo: true) : topRepos, sortRecentRepos ? sorted(topRepo: false) : recentRepos)
    }


    fileprivate struct OrderedCaptions {
        var values: [String: [RecentRepoInfo]] = [:]
        var sortedKeys: [String] {
            values.keys.sorted { $0.compare($1, locale: .current) == .orderedAscending }
        }
    }

    private static func addToOrderedSignDir(_ ordered: inout OrderedCaptions, _ info: RecentRepoInfo, shortenPath: Bool) {

        if shortenPath, let dirInfo = info.dirInfo {
            var suffix = String(info.dirName.dropFirst(dirInfo.count))
            if !suffix.isEmpty { suffix = suffix.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }

            info.caption = (info.shortName ?? "") + (suffix.isEmpty ? "" : " (\(suffix))")
            info.dirInfo = RepositoryHistory.parentDirectory(dirInfo)
        } else {
            info.caption = info.repo.path
        }
        let caption = info.caption ?? info.repo.path
        guard shortenPath else {
            ordered.values[caption, default: []].append(info)
            return
        }
        let exists = ordered.values[caption] != nil
        var list = ordered.values[caption] ?? []
        var pending: [RecentRepoInfo] = []
        if exists {
            for index in list.indices.reversed() where !list[index].fullPath {
                pending.append(list[index])
                list.remove(at: index)
            }
        }
        if info.fullPath || !exists { list.append(info) } else { pending.append(info) }
        ordered.values[caption] = list

        for repo in pending { addToOrderedSignDir(&ordered, repo, shortenPath: shortenPath) }
    }

    private func addToOrderedMiddleDots(_ ordered: inout OrderedCaptions, _ info: RecentRepoInfo) {
        let path = RepositoryHistory.normalizedPath(info.repo.path)
        guard path.hasPrefix("/") else {
            info.caption = info.repo.path
            ordered.values[info.repo.path, default: []].append(info)
            return
        }
        var root: String?
        var company: String?
        var repository: String?
        let workingDir = RepositoryHistory.directoryName(path)
        var dirInfo = RepositoryHistory.parentDirectory(path)
        if let directory = dirInfo {
            repository = RepositoryHistory.directoryName(directory)
            dirInfo = RepositoryHistory.parentDirectory(directory)
        }
        var addDots = false
        let isInUserProfile = RepositoryHistory.isInUserProfile(info.repo.path, homeDirectory: homeDirectory)
        if var directory = dirInfo {
            if directory != homeDirectory {
                while let parent = RepositoryHistory.parentDirectory(directory),
                      RepositoryHistory.parentDirectory(parent) != nil,
                      isInUserProfile, parent != homeDirectory {
                    directory = parent
                    addDots = true
                }
                company = RepositoryHistory.directoryName(directory)
            }
            if isInUserProfile {
                root = "~/"
            } else if let parent = RepositoryHistory.parentDirectory(directory) {
                root = RepositoryHistory.directoryName(parent)
            }
        }

        func makePath(_ left: String?, _ right: String?) -> String? {
            guard let left else { return right }
            guard let right else { return left }
            if right.hasPrefix("/") { return right }
            if right.isEmpty { return left }
            return left.hasSuffix("/") ? left + right : left + "/" + right
        }

        func shortenPathWithCompany(_ skipCount: Int) {
            var c: String?
            var r: String?
            if let company, company.count > skipCount { c = String(company.dropLast(skipCount)) }
            if let repository, repository.count > skipCount { r = String(repository.dropFirst(skipCount)) }
            var caption = c == nil ? root : makePath(root, c)
            if addDots { caption = makePath(caption, "..") }
            caption = makePath(caption, r)
            info.caption = makePath(caption, workingDir)
        }

        func shortenPath(_ skipCount: Int) -> Bool {
            let firstDir = root ?? company ?? repository
            let lastDir = workingDir
            guard let firstDir, path.count - lastDir.count - firstDir.count - skipCount > 0 else { return false }
            let middle = ((path.count - lastDir.count) / 2) + ((path.count - lastDir.count) % 2)
            let leftEnd = middle - (skipCount / 2)
            let rightStart = middle + (skipCount / 2) + (skipCount % 2)
            if leftEnd == rightStart {
                info.caption = path
            } else {
                info.caption = String(path.prefix(leftEnd)) + ".." + String(path.dropFirst(rightStart))
            }
            return true
        }

        if recentReposComboMinWidth == 0 {

            shortenPathWithCompany(0)
        } else {

            var skipCount = 0
            var canShorten: Bool
            repeat {
                canShorten = shortenPath(skipCount)
                skipCount += 1
            } while measure(info.caption ?? "") > CGFloat(recentReposComboMinWidth - 10) && canShorten
        }
        let caption = info.caption ?? info.repo.path
        info.caption = caption
        ordered.values[caption, default: []].append(info)
    }
}


package enum RepositoryHistory {

    package static func normalizedPath(_ path: String) -> String {
        var value = path.trimmingCharacters(in: .whitespaces)
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        return value
    }

    static func directoryName(_ path: String) -> String {
        path == "/" ? "/" : (path as NSString).lastPathComponent
    }

    static func parentDirectory(_ path: String) -> String? {
        guard path != "/", path.hasPrefix("/") else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? nil : parent
    }

    package static func samePath(_ left: String, _ right: String) -> Bool {
        normalizedPath(left).caseInsensitiveCompare(normalizedPath(right)) == .orderedSame
    }


    package static func isInUserProfile(_ path: String, homeDirectory: String = NSHomeDirectory()) -> Bool {
        path.hasPrefix(homeDirectory)
    }


    package static func displayPath(_ path: String, homeDirectory: String = NSHomeDirectory()) -> String {
        guard isInUserProfile(path, homeDirectory: homeDirectory) else { return path }
        var rest = String(path.dropFirst(homeDirectory.count))
        if rest.hasSuffix("/") { rest.removeLast() }
        return "~" + rest
    }


    package static func adjustHistorySize(_ repositories: [RepositoryHistoryEntry], size: Int) -> [RepositoryHistoryEntry] {
        let anchoredCount = repositories.filter { $0.anchor != .none }.count
        let unanchoredAllowed = max(0, size - anchoredCount)
        var kept = 0
        return repositories.filter { repository in
            if repository.anchor != .none { return true }
            guard kept < unanchoredAllowed else { return false }
            kept += 1
            return true
        }
    }


    package static func addAsMostRecent(_ path: String, to history: [RepositoryHistoryEntry]) -> [RepositoryHistoryEntry] {
        let path = normalizedPath(path)
        var history = history
        var entry = RepositoryHistoryEntry(path: path)
        if let index = history.firstIndex(where: { samePath($0.path, path) }) {
            if index == 0 { return history }
            entry = history.remove(at: index)
        }
        history.insert(entry, at: 0)
        return history
    }


    package static func remove(_ path: String, from history: [RepositoryHistoryEntry]) -> [RepositoryHistoryEntry] {
        guard let index = history.firstIndex(where: { samePath($0.path, path) }) else { return history }
        var history = history
        history.remove(at: index)
        return history
    }


    package static func assignCategory(_ repository: RepositoryHistoryEntry, category: String?,
                                       favourites: [RepositoryHistoryEntry]) -> [RepositoryHistoryEntry] {
        var favourites = favourites
        let hasCategory = !(category?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
        if let index = favourites.firstIndex(where: { samePath($0.path, repository.path) }) {
            if hasCategory { favourites[index].category = category } else { favourites.remove(at: index) }
        } else if hasCategory {
            var repository = repository
            repository.category = category
            favourites.append(repository)
        }
        return favourites
    }


    package static func isValidGitWorkingDir(_ path: String, fileManager: FileManager = .default) -> Bool {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        if fileManager.fileExists(atPath: url.appendingPathComponent(".git").path) { return true }
        return fileManager.fileExists(atPath: url.appendingPathComponent("HEAD").path)
            && fileManager.fileExists(atPath: url.appendingPathComponent("objects").path)
            && fileManager.fileExists(atPath: url.appendingPathComponent("refs").path)
    }


    package static func isBareRepository(_ path: String, fileManager: FileManager = .default) -> Bool {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return !fileManager.fileExists(atPath: url.appendingPathComponent(".git").path) && isValidGitWorkingDir(path, fileManager: fileManager)
    }


    static func gitDirectory(_ path: String, fileManager: FileManager = .default) -> URL {
        let workingDir = URL(fileURLWithPath: path, isDirectory: true)
        let dotGit = workingDir.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return workingDir }
        if isDirectory.boolValue { return dotGit }
        guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
              let line = text.components(separatedBy: .newlines).first(where: { $0.hasPrefix("gitdir:") }) else { return dotGit }
        let value = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        return value.hasPrefix("/") ? URL(fileURLWithPath: value, isDirectory: true)
            : workingDir.appendingPathComponent(value, isDirectory: true).standardizedFileURL
    }


    package static func currentBranchName(_ path: String, git: any GitCommandRunning) async -> String {
        let head = gitDirectory(path).appendingPathComponent("HEAD")
        if let contents = try? String(contentsOf: head, encoding: .utf8) {
            guard contents.hasPrefix("ref: ") else { return detachedBranch }
            let prefix = "ref: refs/heads/"
            guard contents.hasPrefix(prefix) else { return "" }
            let name = String(contents.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)

            if !name.isEmpty && name != ".invalid" { return name }
        }
        let command = GitCommand(arguments: ["symbolic-ref", "--quiet", "HEAD"], accessesRemote: false, changesRepositoryState: false)
        guard let result = try? await git.run(command, in: URL(fileURLWithPath: path, isDirectory: true)) else { return unknownBranchName }
        guard result.succeeded else { return detachedBranch }
        return String(result.standardOutputString.dropFirst("refs/heads/".count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }


    package static let detachedBranch = "(no branch)"
    package static let unknownBranchName = "???"


    package static func removeInvalid(_ history: [RepositoryHistoryEntry], isValid: (String) -> Bool) -> [RepositoryHistoryEntry] {
        history.filter { isValid($0.path) }
    }
}
