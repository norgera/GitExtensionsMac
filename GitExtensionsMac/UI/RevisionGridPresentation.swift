import Foundation
import GitCommands
import GitExtensionsCore


enum RevisionGridPresentation {

    static func relativeDate(now: Date, date: Date) -> String {
        let seconds = Int((now.timeIntervalSince1970).rounded()) - Int((date.timeIntervalSince1970).rounded())
        let delta = abs(seconds)
        func text(_ value: Int, _ unit: String) -> String { "\(value) \(unit)\(abs(value) == 1 ? "" : "s") ago" }

        let minutes = (seconds / 60) % 60, hours = (seconds / 3600) % 24, days = seconds / 86_400
        if delta < 60 { return text(seconds % 60, "second") }
        if delta < 45 * 60 { return text(minutes, "minute") }
        if delta < 24 * 60 * 60 { return text(delta < 60 * 60 ? (minutes > 0 ? 1 : minutes < 0 ? -1 : 0) : hours, "hour") }
        if delta < 30 * 24 * 60 * 60 { return text(days, "day") }
        if delta < 365 * 24 * 60 * 60 { return text(Int((Double(days) / 30).rounded(.toNearestOrEven)), "month") }
        return text(Int((Double(days) / 365).rounded(.toNearestOrEven)), "year")
    }


    static func absoluteDate(_ date: Date, seconds: Bool = true) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = seconds ? .medium : .short
        return formatter.string(from: date)
    }


    static func dateText(_ commit: Commit, showAuthorDate: Bool, relative: Bool, now: Date = Date()) -> String {
        guard !commit.isArtificial else { return "" }
        let date = showAuthorDate ? commit.authorDate : commit.commitDate
        guard date != .distantPast, date != .distantFuture else { return "" }
        return relative ? relativeDate(now: now, date: date) : absoluteDate(date)
    }


    static func dateToolTip(_ commit: Commit) -> String? {
        guard !commit.isArtificial else { return nil }
        if commit.authorName == commit.committerName && commit.authorDate == commit.commitDate {
            return "\(absoluteDate(commit.authorDate, seconds: false)) \(commit.authorName) authored and committed"
        }
        return "\(absoluteDate(commit.authorDate, seconds: false)) \(commit.authorName) authored\n"
            + "\(absoluteDate(commit.commitDate, seconds: false)) \(commit.committerName) committed"
    }


    static func authorToolTip(_ commit: Commit) -> String? {
        guard !commit.isArtificial else { return nil }
        if commit.authorName == commit.committerName && commit.authorEmail == commit.committerEmail {
            return "\(commit.authorName) <\(commit.authorEmail)> authored and committed"
        }
        return "\(commit.authorName) <\(commit.authorEmail)> authored\n\(commit.committerName) <\(commit.committerEmail)> committed"
    }


    static func commitIDText(_ commit: Commit, width: CGFloat, characterWidth: CGFloat) -> String {
        guard let objectID = commit.objectID, characterWidth > 0 else { return "" }
        let count = Int((width - 8) / characterWidth)
        return count > 1 ? String(objectID.string.prefix(min(count, objectID.string.count))) : ""
    }


    static func bodyAndNotes(_ bodyOrSubject: String, notes: String) -> String {
        guard !notes.isEmpty else { return bodyOrSubject }
        var result = bodyOrSubject.isEmpty ? "" : bodyOrSubject + "\n"
        result += "\nNotes:\n" + notes.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n")
        return result
    }


    static func fullMessage(_ commit: Commit, notesInSeparateColumn: Bool) -> String {
        let message = commit.body.isEmpty ? commit.subject : commit.subject + "\n" + commit.body
        return notesInSeparateColumn ? message : bodyAndNotes(message, notes: commit.notes)
    }


    static func bodySuffix(_ commit: Commit, showBody: Bool, notesInSeparateColumn: Bool) -> String {
        guard showBody else { return "" }
        let lines = fullMessage(commit, notesInSeparateColumn: notesInSeparateColumn)
            .split(separator: "\n", omittingEmptySubsequences: true)
        return lines.dropFirst().map { " " + $0 }.joined()
    }


    static func summary(_ body: String) -> String? {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var lines: [String] = []
        for (index, line) in body.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if index == 30 { return lines.joined(separator: "\n") + "\n[...]" }
            lines.append(line.count > 150 ? String(line.prefix(150)) + " [...]" : String(line))
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }



    static func referenceToolTip(_ hit: RevisionLabelHit, aheadBehind: (RevisionReference) -> AheadBehindData?,
                                 showTooltips: Bool) -> String? {
        if let source = hit.virtualSource {

            let data = aheadBehind(source)
            let realIsRemote = source.kind == .remoteBranch
            var text = "[\(source.name)]"
            if realIsRemote {
                text += "\nis tracked by [\(data?.branch ?? "")]   \(data?.display() ?? "")"
            } else {
                let remoteBranch = data.map { shortRemote($0.remoteRef) } ?? ""
                text += data?.isGone == true ? "\nwas tracking [\(remoteBranch)], but the remote is gone"
                    : "   \(data?.display() ?? "")\nis tracking [\(remoteBranch)]"
            }
            return text
        }
        let reference = hit.reference
        var text = "[\(reference.name)]"
        switch reference.kind {
        case .remoteBranch:
            if let data = aheadBehind(reference) { text += "\nis tracked by [\(data.branch)]   \(data.display())" }
            else if showTooltips { text += "\nis a remote branch" } else { return nil }
        case .localBranch, .currentBranch:
            if let data = aheadBehind(reference) {
                let remoteBranch = shortRemote(data.remoteRef)
                text += data.isGone ? "\nwas tracking [\(remoteBranch)], but the remote is gone"
                    : "   \(data.display())\nis tracking [\(remoteBranch)]"
            } else if showTooltips { text += "\nis a local branch" } else { return nil }
        case .tag:
            if showTooltips { text += "\nis a tag" } else { return nil }
        default: break
        }
        return text
    }

    private static func shortRemote(_ ref: String) -> String { ref.hasPrefix("refs/remotes/") ? String(ref.dropFirst(13)) : ref }


    static func messageToolTip(_ commit: Commit, notesInSeparateColumn: Bool,
                               aheadBehind: (RevisionReference) -> AheadBehindData? = { _ in nil }) -> String? {
        let references = commit.references.filter { $0.kind != .stash }
        guard !commit.isArtificial, !commit.body.isEmpty || !references.isEmpty else { return nil }
        var text = summary(fullMessage(commit, notesInSeparateColumn: notesInSeparateColumn)) ?? commit.subject
        if !references.isEmpty {
            text += "\n\n" + sortedReferences(references).map { reference in
                switch reference.kind {
                case .bisectGood: return "Marked as good in bisect"
                case .bisectBad: return "Marked as bad in bisect"
                default:
                    return "[\(reference.name)]" + (aheadBehind(reference).map { "   " + $0.display(reverse: reference.kind == .remoteBranch) } ?? "")
                }
            }.joined(separator: "\n")
        }
        return text
    }


    static func sortedReferences(_ references: [RevisionReference]) -> [RevisionReference] {
        references.sorted { rank($0) == rank($1) ? $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) : rank($0) < rank($1) }
    }
    private static func rank(_ reference: RevisionReference) -> Int {
        switch reference.kind {
        case .bisectGood, .bisectBad: 0
        case .currentBranch, .head: 1
        case .localBranch: 3
        case .remoteBranch: 4
        case .tag, .stash: 5
        }
    }




    static func laneInfo(layout: RevisionGraphLayout, row: Int, lane: Int, commits: [RevisionID: Commit]) -> String {
        guard let located = layout.node(atRow: row, lane: lane) else { return "" }
        guard let node = commits[located.revisionID] else { return "Sorry, this commit seems to be not loaded." }
        var text = ""
        if let childID = located.singleChildID {
            text += "\(graphShortID(childID)): \(commits[childID]?.subject ?? "")\n|\n"
        }
        if !node.isArtificial {
            if located.isAtNode { text += "* " }
            text += (node.objectID?.string ?? "") + "\n"
            let branch = BranchFinder(node: node, layout: layout, commits: commits)
            if let committedTo = branch.committedTo, !committedTo.trimmingCharacters(in: .whitespaces).isEmpty {
                text += "\nBranch: \(committedTo)"
                if let mergedWith = branch.mergedWith, !mergedWith.trimmingCharacters(in: .whitespaces).isEmpty {
                    text += " (merged with \(mergedWith))"
                }
            }
            text += "\n"
        }
        text += summary(node.body.isEmpty ? node.subject : node.subject + "\n" + node.body) ?? node.subject
        return text
    }


    private static func graphShortID(_ id: RevisionID) -> String {
        switch id {
        case .workingDirectory: String(repeating: "1", count: 8)
        case .index: String(repeating: "2", count: 8)
        case .object(let objectID): objectID.shortString
        }
    }


    struct BranchFinder {
        private(set) var committedTo: String?
        private(set) var mergedWith: String?

        init(node start: Commit, layout: RevisionGraphLayout, commits: [RevisionID: Commit]) {
            var node = start
            var parent: Commit?
            let order = Dictionary(layout.rows.enumerated().map { ($0.element.commitID, $0.offset) }, uniquingKeysWith: { first, _ in first })
            while !checkForMerge(node, parent: parent, layout: layout) && !findBranch(node) {

                let children = layout.parentIDs.filter { $0.value.contains(node.id) }.map(\.key)
                guard let child = children.min(by: { (order[$0] ?? .max) < (order[$1] ?? .max) }), let next = commits[child] else { break }
                parent = node
                node = next
            }
        }

        private mutating func findBranch(_ node: Commit) -> Bool {
            guard let reference = node.references.first(where: { [.localBranch, .currentBranch, .remoteBranch].contains($0.kind) || ($0.kind == .stash && $0.name == "stash@{0}") })
            else { return false }
            committedTo = reference.kind == .stash ? "stash" : reference.name
            return true
        }

        private mutating func checkForMerge(_ node: Commit, parent: Commit?, layout: RevisionGraphLayout) -> Bool {
            let isTheFirstBranch = parent == nil || layout.parentIDs[node.id]?.first == parent?.id
            let parsed = RevisionGridPresentation.parseMergeMessage(node.subject, appendPullRequest: isTheFirstBranch)
            if let into = parsed.into {
                committedTo = isTheFirstBranch ? into : parsed.with
            }
            if mergedWith == nil { mergedWith = parsed.with ?? "" }
            return committedTo != nil
        }
    }


    static func parseMergeMessage(_ subject: String, appendPullRequest: Bool) -> (into: String?, with: String?) {
        let pattern = #"^merged? (pull request (?<pr>.*) from )?(.*branch |tag )?'?(?<with>[^ ']*[^ '.])'?( of [^ ]*[^ .])?( into (?<into>.*[^.]))?\.?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject))
        else { return (nil, nil) }
        func group(_ name: String) -> String? {
            let range = match.range(withName: name)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: subject) else { return nil }
            return String(subject[swiftRange])
        }
        var with = group("with") ?? "?"
        if appendPullRequest, let pr = group("pr") { with += " by pull request \(pr)" }
        return (group("into") ?? "master", with)
    }


    static func hasAutosquashMarker(_ subject: String) -> Bool {
        subject.hasPrefix("fixup!") || subject.hasPrefix("squash!") || subject.hasPrefix("amend!")
    }
}
