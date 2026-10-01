import Foundation
import GitCommands
import GitExtensionsCore



enum CommitInfoPresentation {

    enum Link: Equatable {
        case commit(ObjectID)
        case branch(String)
        case tag(String)
        case showAll(String)
        case external(URL)

        var url: URL {
            switch self {
            case .commit(let id): Self.internalURL("gotocommit", id.string)
            case .branch(let name): Self.internalURL("gotobranch", name)
            case .tag(let name): Self.internalURL("gototag", name)
            case .showAll(let what): Self.internalURL("showall", what)
            case .external(let url): url
            }
        }

        private static func internalURL(_ command: String, _ data: String) -> URL {
            var components = URLComponents()
            components.scheme = "gitext"
            components.host = command
            components.path = "/" + data
            return components.url ?? URL(string: "gitext://\(command)")!
        }


        init?(url: URL) {
            guard url.scheme == "gitext" else {
                self = .external(url)
                return
            }
            let data = String(url.path.dropFirst())
            switch url.host {
            case "gotocommit":
                guard let id = try? ObjectID.parse(data) else { return nil }
                self = .commit(id)
            case "gotobranch": self = .branch(data)
            case "gototag": self = .tag(data)
            case "showall": self = .showAll(data)
            default: return nil
            }
        }
    }


    struct Run: Equatable {
        let text: String
        let link: Link?
        init(_ text: String, link: Link? = nil) { self.text = text; self.link = link }
    }

    struct HeaderRow: Equatable {
        let label: String
        let value: [Run]
    }



    static func header(_ commit: Commit, children: [ObjectID], now: Date = Date()) -> [HeaderRow] {
        let author = user(commit.authorName, commit.authorEmail)
        let committer = user(commit.committerName, commit.committerEmail)
        let authorIsCommitter = author == committer
        let datesEqual = commit.authorDate == commit.commitDate
        var rows = [HeaderRow(label: "Author", value: [Run(author, link: mailto(commit.authorEmail))])]
        if !commit.isArtificial {
            rows.append(HeaderRow(label: datesEqual ? "Date" : "Author date", value: [Run(dateText(commit.authorDate, now: now))]))
        }
        if !authorIsCommitter {
            rows.append(HeaderRow(label: "Committer", value: [Run(committer, link: mailto(commit.committerEmail))]))
        }
        if !commit.isArtificial {
            if !datesEqual { rows.append(HeaderRow(label: "Commit date", value: [Run(dateText(commit.commitDate, now: now))])) }
            if let id = commit.objectID { rows.append(HeaderRow(label: "Commit hash", value: [Run(id.string)])) }
        }
        if !children.isEmpty { rows.append(HeaderRow(label: children.count == 1 ? "Child" : "Children", value: links(children))) }
        if !commit.parentIDs.isEmpty {
            rows.append(HeaderRow(label: commit.parentIDs.count == 1 ? "Parent" : "Parents", value: links(commit.parentIDs)))
        }
        return rows
    }


    static func plainHeader(_ rows: [HeaderRow]) -> String {
        rows.filter { !["Child", "Children", "Parent", "Parents"].contains($0.label) }.map { row in
            var value = row.value.map(\.text).joined()
            if let open = value.range(of: " ago ("), value.hasSuffix(")") {
                value = String(value[open.upperBound..<value.index(before: value.endIndex)])
            }
            return "\(row.label): \(value)"
        }.joined(separator: "\n")
    }

    private static func user(_ name: String, _ email: String) -> String {
        email.trimmingCharacters(in: .whitespaces).isEmpty ? name : "\(name) <\(email)>"
    }

    private static func mailto(_ email: String) -> Link? {
        URL(string: "mailto:\(email)").map(Link.external)
    }

    private static func links(_ ids: [ObjectID]) -> [Run] {
        ids.enumerated().flatMap { index, id in
            (index > 0 ? [Run(" ")] : []) + [Run(String(id.string.prefix(10)), link: .commit(id))]
        }
    }


    static func dateText(_ date: Date, now: Date) -> String {
        "\(relativeDate(now: now, date: date)) (\(fullDate(date)))"
    }


    static func fullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }


    static func relativeDate(now: Date, date: Date) -> String {
        let seconds = Int(now.timeIntervalSince1970.rounded(.down)) - Int(date.timeIntervalSince1970.rounded(.down))
        let delta = abs(seconds)
        func text(_ value: Int, _ unit: String) -> String { "\(value) \(unit)\(abs(value) == 1 ? "" : "s") ago" }
        let minutes = (seconds / 60) % 60, hours = (seconds / 3600) % 24, days = seconds / 86_400
        if delta < 60 { return text(seconds % 60, "second") }
        if delta < 45 * 60 { return text(minutes, "minute") }
        if delta < 24 * 60 * 60 { return text(delta < 60 * 60 ? (minutes > 0 ? 1 : minutes < 0 ? -1 : 0) : hours, "hour") }
        if delta < 7 * 24 * 60 * 60 { return text(days, "day") }
        if delta < 30 * 24 * 60 * 60 { return text(Int((Double(days) / 7).rounded(.toNearestOrEven)), "week") }
        if delta < 365 * 24 * 60 * 60 { return text(Int((Double(days) / 30).rounded(.toNearestOrEven)), "month") }
        return text(Int((Double(days) / 365).rounded(.toNearestOrEven)), "year")
    }




    static func bodyAndNotes(_ body: String, notes: String) -> String {
        guard !notes.isEmpty else { return body }
        var result = body.isEmpty ? "" : body + "\n"
        result += "\nNotes:\n"
        for line in notes.split(separator: "\n", omittingEmptySubsequences: false) { result += "    \(line)\n" }
        return result
    }


    static func hashCandidates(in text: String) -> [(range: Range<String.Index>, hash: String)] {
        guard let regex = try? NSRegularExpression(pattern: #"\b[a-f\d]{7,40}\b(?![^@\s]*@)"#) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range, in: text).map { ($0, String(text[$0])) }
        }
    }



    static let maximumDisplayedLinesIfLimited = 12
    static let maximumDisplayedRefsIfLimited = 10


    static func branchesInfo(_ branches: [String], preferences: CommitInfoPreferences, limit: Bool) -> [Run] {
        let remotePrefix = "remotes/"
        let getLocal = preferences.showContainedInBranchesLocal || preferences.showContainedInBranchesRemoteIfNoLocal
        let getRemote = preferences.showContainedInBranchesRemote || preferences.showContainedInBranchesRemoteIfNoLocal
        let allowLocal = preferences.showContainedInBranchesLocal
        var allowRemote = getRemote
        var formatted: [String] = []
        var truncated = false
        for branch in branches {
            var name = branch
            let isLocal: Bool
            if getLocal && getRemote {
                isLocal = !branch.hasPrefix(remotePrefix)
                if !isLocal { name = String(branch.dropFirst(remotePrefix.count)) }
            } else {
                isLocal = !getRemote
            }
            if (isLocal && allowLocal) || (!isLocal && allowRemote) {
                if limit && formatted.count == maximumDisplayedLinesIfLimited {
                    formatted.removeSubrange(maximumDisplayedRefsIfLimited..<maximumDisplayedLinesIfLimited)
                    truncated = true
                    break
                }
                formatted.append(name)
            }
            if isLocal && preferences.showContainedInBranchesRemoteIfNoLocal { allowRemote = false }
        }
        return refsList(formatted.map { branch in
            Run(branch, link: .branch(branch == RepositoryHistory.detachedBranch ? "HEAD" : branch))
        }, prefix: "Contained in branches:", empty: "Contained in no branch", what: "branches", truncated: truncated)
    }


    static func tagsInfo(_ tags: [String], limit: Bool) -> [Run] {
        let truncate = limit && tags.count > maximumDisplayedLinesIfLimited
        let shown = truncate ? Array(tags.prefix(maximumDisplayedRefsIfLimited)) : tags
        return refsList(shown.map { Run($0, link: .tag($0)) }, prefix: "Contained in tags:", empty: "Contained in no tag",
                        what: "tags", truncated: truncate)
    }

    private static func refsList(_ refs: [Run], prefix: String, empty: String, what: String, truncated: Bool) -> [Run] {
        guard !refs.isEmpty else { return [Run(empty)] }
        var runs = [Run(prefix + "\n")]
        for (index, ref) in refs.enumerated() {
            if index > 0 { runs.append(Run("\n")) }
            runs.append(ref)
        }
        if truncated { runs += [Run("\n"), Run("[ Show all ]", link: .showAll(what))] }
        return runs
    }


    static func describeInfo(_ description: RepositoryCommitDescription) -> [Run] {
        guard !description.precedingTag.isEmpty else { return [Run("Derives from no tag")] }
        var runs = [Run("Derives from tag: "), Run(description.precedingTag, link: .tag(description.precedingTag))]
        if !description.commitCount.isEmpty { runs.append(Run(" + \(description.commitCount) commits")) }
        return runs
    }


    static func annotatedTagsInfo(tagNames: [String], messages: [String: String], order: [String: Int]) -> [(tag: String, message: String)] {
        sortTags(tagNames, order: order).compactMap { tag in messages[tag].map { (tag, $0) } }
    }


    static func sortTags(_ tags: [String], order: [String: Int]) -> [String] {
        func index(_ tag: String) -> Int {
            let key = tag.hasPrefix("remotes/") ? "refs/" + tag : "refs/tags/" + tag
            return order[key] ?? -1
        }
        return tags.enumerated().sorted { lhs, rhs in
            let (left, right) = (index(lhs.element), index(rhs.element))
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }


    static let prioritizedBranchNames = "main[^/]*|master[^/]*|release/.*"
    static let prioritizedRemoteNames = "origin|upstream"


    static func sortBranches(_ branches: [String], currentBranch: String,
                             prioritizedBranches: String = prioritizedBranchNames,
                             prioritizedRemotes: String = prioritizedRemoteNames) -> [String] {
        let remotePrefix = "remotes/"
        func split(_ value: String) -> [String] {
            value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let branchRegexes = split(prioritizedBranches)
        let local = branchRegexes.compactMap { try? NSRegularExpression(pattern: "^(\($0))$") }
        let remoteBranches = branchRegexes.compactMap { try? NSRegularExpression(pattern: "^\(remotePrefix)[^/]+/(\($0))$") }
        let remotes = split(prioritizedRemotes).compactMap { try? NSRegularExpression(pattern: "^\(remotePrefix)(\($0))/") }
        let isDetached = currentBranch == RepositoryHistory.detachedBranch || currentBranch.isEmpty
        func matchIndex(_ branch: String, _ regexes: [NSRegularExpression]) -> (Int, Bool) {
            for (index, regex) in regexes.enumerated()
            where regex.firstMatch(in: branch, range: NSRange(branch.startIndex..., in: branch)) != nil {
                return (index, true)
            }
            return (regexes.count, false)
        }
        func order(_ branch: String) -> Int {
            if isDetached ? branch == RepositoryHistory.detachedBranch : branch == currentBranch { return 0 }
            var order = 1
            let remotesGroupLength = remotes.count + 1
            if !branch.hasPrefix(remotePrefix) {
                let (localOrder, matched) = matchIndex(branch, local)
                if !matched { order += remoteBranches.count * remotesGroupLength }
                return order + localOrder
            }
            order += local.count
            let (remoteBranchOrder, matched) = matchIndex(branch, remoteBranches)
            if !matched { order += 1 }
            return order + remoteBranchOrder * remotesGroupLength + matchIndex(branch, remotes).0
        }
        return branches.sorted { lhs, rhs in
            let (left, right) = (order(lhs), order(rhs))
            return left == right ? lhs < rhs : left < right
        }
    }
}
