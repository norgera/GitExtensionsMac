import Foundation
import CoreFoundation

package enum ObjectIDError: LocalizedError, Sendable {
    case invalid(String)

    package var errorDescription: String? {
        switch self {
        case .invalid(let value):
            return "Invalid Git object ID: \(value)"
        }
    }
}

public struct ObjectID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let string: String

    public init(parsing string: String) throws {
        guard Self.isValid(string) else { throw ObjectIDError.invalid(string) }
        self.string = string
    }

    public static func parse(_ string: String) throws -> ObjectID {
        try ObjectID(parsing: string)
    }

    package static func parseIfPresent(_ string: String?) throws -> ObjectID? {
        guard let string, !string.isEmpty else { return nil }
        return try parse(string)
    }

    public var description: String { string }
    public var shortString: String { String(string.prefix(8)) }

    public static func < (lhs: ObjectID, rhs: ObjectID) -> Bool { lhs.string < rhs.string }

    private static func isValid(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64)
            && value.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            }
    }
}

public enum RevisionID: Hashable, Sendable, CustomStringConvertible {
    case object(ObjectID)
    case workingDirectory
    case index

    public var objectID: ObjectID? {
        guard case .object(let objectID) = self else { return nil }
        return objectID
    }

    public var description: String {
        switch self {
        case .object(let objectID): objectID.string
        case .workingDirectory: "WORKTREE"
        case .index: "INDEX"
        }
    }
}

package struct Repository: Identifiable, Hashable, Sendable {
    package let id: String
    package let name: String
    package let path: String
    package let description: String
    package let isBare: Bool

    package init(id: String, name: String, path: String, description: String, isBare: Bool = false) {
        self.id = id
        self.name = name
        self.path = path
        self.description = description
        self.isBare = isBare
    }
}

package struct RepositoryReferenceSortMetadata: Hashable, Sendable {
    package let authorDate: Int64?
    package let committerDate: Int64?
    package let creatorDate: Int64?
    package let taggerDate: Int64?
    package let objectSize: Int64?

    package init(
        authorDate: Int64? = nil,
        committerDate: Int64? = nil,
        creatorDate: Int64? = nil,
        taggerDate: Int64? = nil,
        objectSize: Int64? = nil
    ) {
        self.authorDate = authorDate
        self.committerDate = committerDate
        self.creatorDate = creatorDate
        self.taggerDate = taggerDate
        self.objectSize = objectSize
    }
}

package struct Branch: Identifiable, Hashable, Sendable {
    package let id: String
    package let name: String
    package let commitID: ObjectID
    package let isCurrent: Bool
    package let isRemote: Bool
    package let remoteName: String?
    package let ahead: Int
    package let behind: Int
    package let sortMetadata: RepositoryReferenceSortMetadata

    package init(id: String, name: String, commitID: ObjectID, isCurrent: Bool, isRemote: Bool, remoteName: String?, ahead: Int, behind: Int, sortMetadata: RepositoryReferenceSortMetadata = .init()) {
        self.id = id
        self.name = name
        self.commitID = commitID
        self.isCurrent = isCurrent
        self.isRemote = isRemote
        self.remoteName = remoteName
        self.ahead = ahead
        self.behind = behind
        self.sortMetadata = sortMetadata
    }
}

package struct Tag: Identifiable, Hashable, Sendable {
    package let id: String
    package let name: String
    package let commitID: ObjectID
    package let sortMetadata: RepositoryReferenceSortMetadata

    package init(id: String, name: String, commitID: ObjectID, sortMetadata: RepositoryReferenceSortMetadata = .init()) {
        self.id = id
        self.name = name
        self.commitID = commitID
        self.sortMetadata = sortMetadata
    }
}

package struct Remote: Identifiable, Hashable, Sendable {
    package let id: String
    package let name: String
    package let fetchURL: String
    package let branches: [Branch]
    package let isDisabled: Bool

    package init(id: String, name: String, fetchURL: String, branches: [Branch], isDisabled: Bool = false) {
        self.id = id
        self.name = name
        self.fetchURL = fetchURL
        self.branches = branches
        self.isDisabled = isDisabled
    }
}

package struct Stash: Identifiable, Hashable, Sendable {
    package let id: String
    package let selector: String
    package let subject: String
    package let branchName: String
    package let commitID: ObjectID

    package init(id: String, selector: String, subject: String, branchName: String, commitID: ObjectID) {
        self.id = id
        self.selector = selector
        self.subject = subject
        self.branchName = branchName
        self.commitID = commitID
    }
}

package struct Worktree: Identifiable, Hashable, Sendable {
    package let id: String
    package let name: String
    package let path: String
    package let branchName: String
    package let isCurrent: Bool
    package let headID: ObjectID?
    package let isMain: Bool
    package let isBare: Bool
    package let isDetached: Bool
    package let isDeleted: Bool

    package init(id: String, name: String, path: String, branchName: String, isCurrent: Bool,
                 headID: ObjectID? = nil, isMain: Bool = false, isBare: Bool = false,
                 isDetached: Bool = false, isDeleted: Bool = false) {
        self.id = id
        self.name = name
        self.path = path
        self.branchName = branchName
        self.isCurrent = isCurrent
        self.headID = headID
        self.isMain = isMain
        self.isBare = isBare
        self.isDetached = isDetached
        self.isDeleted = isDeleted
    }

    package var canOpen: Bool { !isCurrent && !isDeleted }
    package var canDelete: Bool { canOpen && !isMain }
    package var headType: String { isBare ? "Bare" : isDetached ? "Detached" : "Branch" }
    package func displayName(_ name: String) -> String {
        let state = isBare ? "bare" : isDetached ? "detached at \(headID.map { String($0.string.prefix(7)) } ?? "???")" : branchName
        return "\(name) (\(state))"
    }
}

package struct Submodule: Identifiable, Hashable, Sendable {
    package enum State: String, Hashable, Sendable {
        case clean
        case uninitialized
        case modified
        case conflicted
        case unknown
    }

    package let id: String
    package let name: String
    package let path: String
    package let url: String?
    package let commitID: ObjectID?
    package let description: String?
    package let state: State
    package let parentPath: String
    package let localPath: String
    package let isDirty: Bool
    package let expectedCommitID: ObjectID?

    package init(id: String, name: String, path: String, url: String?, commitID: ObjectID?, description: String?, state: State, parentPath: String = "", localPath: String? = nil, isDirty: Bool = false, expectedCommitID: ObjectID? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.url = url
        self.commitID = commitID
        self.description = description
        self.state = state
        self.parentPath = parentPath
        self.localPath = localPath ?? path
        self.isDirty = isDirty
        self.expectedCommitID = expectedCommitID
    }
}

package struct SubmoduleTreeItem: Identifiable, Hashable, Sendable {
    package enum CommitState: String, Sendable {
        case same, ahead, behind, newer, older, modified, uninitialized, missing, conflicted
    }
    package let repositoryURL: URL
    package let parentURL: URL
    package let path: String
    package let localPath: String
    package let isCurrent: Bool
    package let isTop: Bool
    package let isInitialized: Bool
    package let branch: String?
    package let commitID: ObjectID?
    package let recordedID: ObjectID?
    package let commitState: CommitState
    package let addedCommits: Int?
    package let removedCommits: Int?
    package let isDirty: Bool
    package let commitDescription: String
    package let changeCounts: RevisionChangeCounts?
    package var diffSummary: SubmoduleDiffSummary?
    package var id: String { repositoryURL.path }

    package init(repositoryURL: URL, parentURL: URL, path: String, localPath: String,
                 isCurrent: Bool, isTop: Bool, isInitialized: Bool, branch: String?,
                 commitID: ObjectID?, recordedID: ObjectID?, commitState: CommitState,
                 addedCommits: Int? = nil, removedCommits: Int? = nil, isDirty: Bool = false,
                 commitDescription: String = "", changeCounts: RevisionChangeCounts? = nil) {
        self.repositoryURL = repositoryURL; self.parentURL = parentURL
        self.path = path; self.localPath = localPath; self.isCurrent = isCurrent; self.isTop = isTop
        self.isInitialized = isInitialized; self.branch = branch; self.commitID = commitID
        self.recordedID = recordedID; self.commitState = commitState
        self.addedCommits = addedCommits; self.removedCommits = removedCommits
        self.isDirty = isDirty; self.commitDescription = commitDescription; self.changeCounts = changeCounts
    }
}

package struct RevisionReference: Identifiable, Hashable, Sendable {
    package enum Kind: Sendable {
        case head
        case currentBranch
        case localBranch
        case remoteBranch
        case tag
        case stash

        case bisectGood
        case bisectBad
    }

    package let id: String
    package let name: String
    package let kind: Kind
    package let trackingRemote: String?
    package let mergeWith: String?

    package var isSelectedHeadMergeSource = false
    package let isAnnotated: Bool

    package init(
        id: String,
        name: String,
        kind: Kind,
        trackingRemote: String? = nil,
        mergeWith: String? = nil,
        isAnnotated: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.trackingRemote = trackingRemote
        self.mergeWith = mergeWith
        self.isAnnotated = isAnnotated
    }

    package var remoteName: String? {
        guard kind == .remoteBranch else { return nil }
        return name.split(separator: "/", maxSplits: 1).first.map(String.init)
    }

    package var localName: String {
        guard kind == .remoteBranch else { return name }
        return name.split(separator: "/", maxSplits: 1).dropFirst().first.map(String.init) ?? name
    }

    package func tracks(_ remoteReference: RevisionReference) -> Bool {
        guard kind == .currentBranch || kind == .localBranch,
              remoteReference.kind == .remoteBranch,
              let trackingRemote,
              let mergeWith
        else {
            return false
        }
        return trackingRemote == remoteReference.remoteName
            && mergeWith == remoteReference.localName
    }
}

package struct Commit: Identifiable, Hashable, Sendable {
    package enum Kind: Hashable, Sendable {
        case revision
        case workingDirectory
        case index
    }

    package let id: RevisionID
    package let shortID: String
    package let subject: String
    package let body: String
    package let authorName: String
    package let authorEmail: String
    package let authorDate: Date
    package let committerName: String
    package let committerEmail: String
    package let commitDate: Date
    package let parentIDs: [ObjectID]
    package let references: [RevisionReference]
    package let kind: Kind

    package var isAutostash = false
    package var isStash: Bool { references.contains { $0.kind == .stash } }
    package var isStashLike: Bool { isStash || isAutostash }
    package var loadsCommitInfo: Bool { !isArtificial && !isAutostash }
    package var notes: String = ""

    package init(
        id: RevisionID,
        shortID: String,
        subject: String,
        body: String,
        authorName: String,
        authorEmail: String,
        authorDate: Date,
        committerName: String,
        committerEmail: String,
        commitDate: Date,
        parentIDs: [ObjectID],
        references: [RevisionReference],
        kind: Kind = .revision
    ) {
        self.id = id
        self.shortID = shortID
        self.subject = subject
        self.body = body
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.authorDate = authorDate
        self.committerName = committerName
        self.committerEmail = committerEmail
        self.commitDate = commitDate
        self.parentIDs = parentIDs
        self.references = references
        self.kind = kind
    }

    package func withNotes(_ notes: String) -> Commit {
        var commit = self
        commit.notes = notes
        return commit
    }

    package var isMerge: Bool { parentIDs.count > 1 }
    package var isHEAD: Bool { references.contains { $0.kind == .head || $0.kind == .currentBranch } }
    package var isArtificial: Bool { kind != .revision }
    package var objectID: ObjectID? { id.objectID }
    package var graphParentIDs: [RevisionID] {
        switch kind {
        case .workingDirectory: [.index]
        case .index, .revision: parentIDs.map(RevisionID.object)
        }
    }
}

package enum RevisionSelectionRestorer {
    package static func restoredID(
        requestedID: RevisionID?,
        previousCommits: [Commit],
        refreshedCommits: [Commit]
    ) -> RevisionID? {
        guard !refreshedCommits.isEmpty else { return nil }
        let refreshedIDs = Set(refreshedCommits.map(\.id))
        if let requestedID, refreshedIDs.contains(requestedID) {
            return requestedID
        }

        if let requestedID,
           let previous = previousCommits.first(where: { $0.id == requestedID }) {
            let previousByID = Dictionary(uniqueKeysWithValues: previousCommits.map { ($0.id, $0) })
            var pending = Array(previous.parentIDs.prefix(50))
            var visited = Set<ObjectID>()
            while !pending.isEmpty, visited.count < 50 {
                let candidate = pending.removeFirst()
                guard visited.insert(candidate).inserted else { continue }
                let candidateID = RevisionID.object(candidate)
                if refreshedIDs.contains(candidateID) { return candidateID }
                if let commit = previousByID[candidateID] {
                    pending.append(contentsOf: commit.parentIDs)
                }
            }
        }

        return refreshedCommits.first(where: \.isHEAD)?.id
            ?? refreshedCommits.first(where: { !$0.isArtificial })?.id
            ?? refreshedCommits.first?.id
    }
}

package struct AuthorAvatarPresentation: Equatable {
    package let initials: String
    package let paletteIndex: Int

    package init(initials: String, paletteIndex: Int) {
        self.initials = initials
        self.paletteIndex = paletteIndex
    }

    package static func make(name: String?, email: String?, paletteCount: Int = 6) -> AuthorAvatarPresentation {
        let cleanName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selected = cleanName.isEmpty ? cleanEmail.split(separator: "@", maxSplits: 1).first.map(String.init) ?? "" : cleanName
        let pieces = selected.split(whereSeparator: { cleanName.isEmpty ? ".-_".contains($0) : $0.isWhitespace }).map(String.init)
        func initials(_ parts: [String]) -> String {
            guard !parts.isEmpty else { return "?" }
            let valid = parts.filter { $0.first?.isLetter == true || $0.first?.isNumber == true }
            guard !valid.isEmpty else { return String(parts[0].prefix(1)) + (parts.count > 1 ? String(parts[1].prefix(1)) : "") }
            if valid.count > 1 { return String(valid[0].prefix(1) + valid[valid.count - 1].prefix(1)).uppercased() }
            let value = valid[0]
            if value.count == 1 { return value.uppercased() }
            let second = value.dropFirst().first!
            if second.isUppercase { return String(value.prefix(1)).uppercased() + String(second) }
            let split = value.split(whereSeparator: { ".-_".contains($0) }).map(String.init)
            if split.count > 1 { return initials(split) }
            let uppercase = value.filter(\.isUppercase)
            if uppercase.count > 1 { return String(uppercase.prefix(1) + uppercase.suffix(1)) }
            return String(value.prefix(1)).uppercased() + String(second)
        }
        var hash = Int32(23)
        for scalar in cleanEmail.utf16 {
            hash = hash &* 31 &+ Int32(scalar)
        }
        let magnitude = hash == .min ? Int(Int32.max) : abs(Int(hash))
        return AuthorAvatarPresentation(initials: initials(pieces), paletteIndex: magnitude % max(1, paletteCount))
    }
}

package enum RevisionDiffSummaryResolver {
    package static func summary(selected: Commit, comparison: Commit?) -> String {
        guard let comparison else {
            return "Diff with empty tree"
        }
        return "Diff with A \(description(for: comparison))"
    }

    private static func description(for commit: Commit) -> String {
        commit.shortID.isEmpty ? commit.subject : "\(commit.shortID): \(commit.subject)"
    }
}

package enum FileChangeType: String, Hashable, Sendable {
    case added = "A"
    case modified = "M"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"

    package var description: String {
        switch self {
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        }
    }
}


package enum FileStagedStatus: String, Hashable, Sendable {
    case unset, none, workTree, index, unknown
}


package enum DiffBranchStatus: Hashable, Sendable {
    case unknown, onlyA, onlyB, same, unequal
}

package struct ChangedFile: Identifiable, Hashable, Sendable {
    package var id: String
    package let path: String
    package let oldPath: String?
    package var changeType: FileChangeType
    package let additions: Int
    package let deletions: Int

    package var staged: FileStagedStatus = .none
    package var isTracked = true
    package var isSubmodule = false
    package var submoduleCommitChanged = false
    package var submoduleIsDirty = false
    package var renameCopyPercentage: String?
    package var diffStatus: DiffBranchStatus = .unknown
    package var isConflict = false
    package var isTypeChanged = false

    package var isUnchanged = false
    package var isSkipWorktree = false
    package var isAssumeUnchanged = false
    package var isIgnored = false

    package var isStatusOnly = false
    package var isRangeDiff = false
    package var rangeDiffFirst: ObjectID?
    package var rangeDiffSecond: ObjectID?
    package var grepString: String?

    package init(id: String, path: String, oldPath: String?, changeType: FileChangeType, additions: Int, deletions: Int) {
        self.id = id
        self.path = path
        self.oldPath = oldPath
        self.changeType = changeType
        self.additions = additions
        self.deletions = deletions
    }
}

package enum DiffDisplayAppearance: String, CaseIterable, Hashable, Sendable, Codable {
    case patch
    case gitWordDiff
    case difftastic
}

package enum DiffTextColor: Hashable, Sendable {
    case text(dim: Bool)
    case palette(Int, dim: Bool)
    case rgb(Int, Int, Int)
}

package struct DiffTextStyle: Hashable, Sendable {
    package var location: Int
    package var length: Int
    package var foreground: DiffTextColor?
    package var background: DiffTextColor?

    package init(location: Int, length: Int, foreground: DiffTextColor?, background: DiffTextColor?) {
        self.location = location
        self.length = length
        self.foreground = foreground
        self.background = background
    }
}

package struct DiffHunkRanges: Hashable, Sendable {
    package struct Lines: Hashable, Sendable {
        package let start: Int
        package let count: Int
        package init(start: Int, count: Int) { self.start = start; self.count = count }
    }
    package let parents: [Lines]
    package let result: Lines
    package init(parents: [Lines], result: Lines) { self.parents = parents; self.result = result }
}

package struct DiffLine: Identifiable, Hashable, Sendable {
    package enum Kind: Hashable, Sendable {
        case header
        case hunk
        case context
        case addition
        case deletion
    }

    package let id: String
    package let oldLineNumber: Int?
    package let newLineNumber: Int?
    package let kind: Kind
    package let text: String
    package let styles: [DiffTextStyle]
    package let isMixedChange: Bool
    package let diffPrefix: String?
    package let isMovedLine: Bool
    package let hunkRanges: DiffHunkRanges?

    package init(id: String, oldLineNumber: Int?, newLineNumber: Int?, kind: Kind, text: String,
                 styles: [DiffTextStyle] = [], isMixedChange: Bool = false, diffPrefix: String? = nil, isMovedLine: Bool = false,
                 hunkRanges: DiffHunkRanges? = nil) {
        self.id = id
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.kind = kind
        self.text = text
        self.styles = styles
        self.isMixedChange = isMixedChange
        self.diffPrefix = diffPrefix
        self.isMovedLine = isMovedLine
        self.hunkRanges = hunkRanges
    }

    package var isChange: Bool { kind == .addition || kind == .deletion || isMixedChange }
    package var patchText: String {
        if let diffPrefix { return diffPrefix + text }
        switch kind {
        case .addition: return "+" + text
        case .deletion: return "-" + text
        case .context: return " " + text
        case .header, .hunk: return text
        }
    }
}

package struct FileDiff: Identifiable, Hashable, Sendable {
    package let id: String
    package let fileID: String
    package let lines: [DiffLine]
    package let appearance: DiffDisplayAppearance
    package let contentEncoding: String.Encoding
    package var normalizesCopyLineEndings = false
    package var submoduleSummary: SubmoduleDiffSummary?
    package var isTextOnly = false

    package init(id: String, fileID: String, lines: [DiffLine], appearance: DiffDisplayAppearance = .patch, contentEncoding: String.Encoding = .utf8) {
        self.id = id
        self.fileID = fileID
        self.lines = lines
        self.appearance = appearance
        self.contentEncoding = contentEncoding
    }
}

package struct SubmoduleDiffSummary: Hashable, Sendable {
    package enum Change: String, Sendable {
        case modified = "Modified", added = "New submodule", removed = "Removed submodule"
        case same = "Same commit", forward = "Fast Forward", rewind = "Rewind"
        case newer = "Newer commit time", older = "Older commit time", unknown = "Unknown"
    }
    package struct CommitInfo: Hashable, Sendable {
        package let id: ObjectID
        package let date: Date
        package let body: String
        package init(id: ObjectID, date: Date, body: String) { self.id = id; self.date = date; self.body = body }
    }
    package let path: String
    package let from: ObjectID?
    package let to: ObjectID?
    package let fromInfo: CommitInfo?
    package let toInfo: CommitInfo?
    package let change: Change
    package let added: Int?
    package let removed: Int?
    package let isDirty: Bool
    package let isInitialized: Bool
    package let status: String
    package let differences: String
    package let failure: String?

    package init(path: String, from: ObjectID?, to: ObjectID?, fromInfo: CommitInfo? = nil, toInfo: CommitInfo? = nil,
                 change: Change, added: Int? = nil, removed: Int? = nil, isDirty: Bool, isInitialized: Bool,
                 status: String = "", differences: String = "", failure: String? = nil) {
        self.path = path; self.from = from; self.to = to; self.fromInfo = fromInfo; self.toInfo = toInfo
        self.change = change; self.added = added; self.removed = removed; self.isDirty = isDirty
        self.isInitialized = isInitialized; self.status = status; self.differences = differences; self.failure = failure
    }
}

package enum DiffWhitespaceMode: String, CaseIterable, Hashable, Sendable, Codable {
    case none
    case endOfLine
    case changes
    case all
}

package struct FileDiffOptions: Hashable, Sendable {
    package var usesHistogram: Bool
    package var whitespace: DiffWhitespaceMode
    package var contextLines: Int
    package var showsEntireFile: Bool
    package var treatsAllFilesAsText: Bool
    package var appearance: DiffDisplayAppearance
    package var difftasticWidth: Int
    package var difftasticSyntaxHighlighting: Bool
    package var useGitColoring: Bool
    package var reverseGitColoring: Bool
    package var textEncoding: RepositoryTextEncoding
    package var omitsUninterestingCombinedDiff = false

    package var combinedDiffArguments: [String] { omitsUninterestingCombinedDiff ? ["--cc"] : ["-c", "-p"] }

    package init(
        whitespace: DiffWhitespaceMode = .none,
        contextLines: Int = 3,
        showsEntireFile: Bool = false,
        treatsAllFilesAsText: Bool = false,
        usesHistogram: Bool = false,
        appearance: DiffDisplayAppearance = .patch,
        difftasticWidth: Int = 88,
        difftasticSyntaxHighlighting: Bool = true,
        useGitColoring: Bool = false,
        reverseGitColoring: Bool = true,
        textEncoding: RepositoryTextEncoding = .automatic
    ) {
        self.whitespace = whitespace
        self.contextLines = max(0, contextLines)
        self.showsEntireFile = showsEntireFile
        self.treatsAllFilesAsText = treatsAllFilesAsText
        self.usesHistogram = usesHistogram
        self.appearance = appearance
        self.difftasticWidth = difftasticWidth
        self.difftasticSyntaxHighlighting = difftasticSyntaxHighlighting
        self.useGitColoring = useGitColoring
        self.reverseGitColoring = reverseGitColoring
        self.textEncoding = textEncoding
    }

    package var gitArguments: [String] {
        var arguments: [String] = usesHistogram ? ["--histogram"] : []
        switch whitespace {
        case .none: break
        case .endOfLine: arguments.append("--ignore-space-at-eol")
        case .changes: arguments.append("--ignore-space-change")
        case .all: arguments.append("--ignore-all-space")
        }
        if showsEntireFile {
            arguments += ["--inter-hunk-context=9000", "--unified=9000"]
        } else if contextLines != 3 {
            arguments.append("--unified=\(contextLines)")
        }
        if treatsAllFilesAsText { arguments.append("--text") }
        return arguments
    }
}

package struct RepositoryTextEncoding: RawRepresentable, CaseIterable, Hashable, Sendable, Codable {
    package let rawValue: String
    private init(_ rawValue: String) { self.rawValue = rawValue }
    package static let automatic = Self("automatic")
    package static let utf8 = Self("utf8")
    package static let utf16LittleEndian = Self("utf16LittleEndian")
    package static let utf16BigEndian = Self("utf16BigEndian")
    package static let westernISO88591 = Self("westernISO88591")
    package static let windows1252 = Self("windows1252")

    package init?(rawValue: String) {
        if Self.legacy.contains(where: { $0.rawValue == rawValue }) { self.init(rawValue); return }
        guard let encoding = Self(ianaName: rawValue) else { return nil }
        self = encoding
    }
    package init?(ianaName: String) {
        let value = ianaName.lowercased()
        let aliases: [String: Self] = ["utf8": .utf8, "utf-8": .utf8, "utf-16": .utf16LittleEndian,
                                     "utf-16le": .utf16LittleEndian, "utf16le": .utf16LittleEndian,
                                     "utf-16be": .utf16BigEndian, "utf16be": .utf16BigEndian,
                                     "iso-8859-1": .westernISO88591, "latin1": .westernISO88591,
                                     "windows-1252": .windows1252, "cp1252": .windows1252]
        if let known = aliases[value] { self = known; return }
        let cf = CFStringConvertIANACharSetNameToEncoding(value as CFString)
        guard cf != kCFStringEncodingInvalidId, cf != CFStringEncoding(CFStringEncodings.UTF7.rawValue),
              let name = CFStringConvertEncodingToIANACharSetName(cf) else { return nil }
        self.init((name as String).lowercased())
    }
    private static let legacy: [Self] = [.automatic, .utf8, .utf16LittleEndian, .utf16BigEndian, .westernISO88591, .windows1252]
    package static var allCases: [Self] {
        var values = legacy
        for encoding in String.availableStringEncodings {
            let cf = CFStringConvertNSStringEncodingToEncoding(encoding.rawValue)
            if let name = CFStringConvertEncodingToIANACharSetName(cf), let item = Self(ianaName: name as String), !values.contains(item) { values.append(item) }
        }
        return values
    }
    package var foundationEncoding: String.Encoding {
        switch self {
        case .automatic, .utf8: return .utf8
        case .utf16LittleEndian: return .utf16LittleEndian
        case .utf16BigEndian: return .utf16BigEndian
        case .westernISO88591: return .isoLatin1
        case .windows1252: return .windowsCP1252
        default: return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding(rawValue as CFString)))
        }
    }
    package var ianaName: String {
        let cf = CFStringConvertNSStringEncodingToEncoding(foundationEncoding.rawValue)
        return (CFStringConvertEncodingToIANACharSetName(cf) as String?)?.lowercased() ?? rawValue
    }
    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let encoding = Self(rawValue: value) else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported text encoding") }
        self = encoding
    }
    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer(); try container.encode(rawValue)
    }

    package var title: String {
        switch self {
        case .automatic: "Automatic"
        case .utf8: "Unicode (UTF-8)"
        case .utf16LittleEndian: "Unicode (UTF-16 LE)"
        case .utf16BigEndian: "Unicode (UTF-16 BE)"
        case .westernISO88591: "Western (ISO Latin 1)"
        case .windows1252: "Western (Windows Latin 1)"
        default: String.localizedName(of: foundationEncoding)
        }
    }
}

package struct RepositoryFileContent: Hashable, Sendable {
    package enum Kind: Hashable, Sendable {
        case text
        case image
        case binary
        case missing
    }

    package let path: String
    package let kind: Kind
    package let text: String
    package let data: Data
    package let encoding: RepositoryTextEncoding?
    package var normalizesCopyLineEndings = false

    package init(
        path: String,
        kind: Kind,
        text: String = "",
        data: Data = Data(),
        encoding: RepositoryTextEncoding? = nil
    ) {
        self.path = path
        self.kind = kind
        self.text = text
        self.data = data
        self.encoding = encoding
    }

    package var byteCount: Int { data.count }
}

package struct RepositoryFileEntry: Identifiable, Hashable, Sendable {
    package let id: String
    package let path: String
    package let content: String
    package let byteCount: Int
    package let isExecutable: Bool
    package let gitObjectID: ObjectID?
    package let gitObjectType: String?

    package init(
        id: String? = nil,
        path: String,
        content: String,
        byteCount: Int? = nil,
        isExecutable: Bool = false,
        gitObjectID: ObjectID? = nil,
        gitObjectType: String? = nil
    ) {
        self.id = id ?? path
        self.path = path
        self.content = content
        self.byteCount = byteCount ?? content.utf8.count
        self.isExecutable = isExecutable
        self.gitObjectID = gitObjectID
        self.gitObjectType = gitObjectType
    }
}

package struct RepositoryFileTreeNode: Identifiable, Hashable, Sendable {
    package enum Kind: Int, Hashable, Sendable {
        case folder
        case file
    }

    package let id: String
    package let name: String
    package let path: String
    package let kind: Kind
    package let file: RepositoryFileEntry?
    package let children: [RepositoryFileTreeNode]

    package init(id: String, name: String, path: String, kind: Kind, file: RepositoryFileEntry?, children: [RepositoryFileTreeNode]) {
        self.id = id
        self.name = name
        self.path = path
        self.kind = kind
        self.file = file
        self.children = children
    }
}

package enum RepositoryFileTreeBuilder {
    package static func build(files: [RepositoryFileEntry]) -> [RepositoryFileTreeNode] {
        let root = MutableRepositoryFileTreeNode(name: "", path: "", kind: .folder)

        for file in files.sorted(by: { $0.path.caseInsensitiveCompare($1.path) == .orderedAscending }) {
            let components = file.path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }

            var parent = root
            var accumulatedPath = ""
            for (index, component) in components.enumerated() {
                accumulatedPath = accumulatedPath.isEmpty ? component : "\(accumulatedPath)/\(component)"
                let isFile = index == components.count - 1
                if let existing = parent.children[component] {
                    if isFile { existing.file = file }
                    parent = existing
                } else {
                    let node = MutableRepositoryFileTreeNode(
                        name: component,
                        path: accumulatedPath,
                        kind: isFile ? .file : .folder,
                        file: isFile ? file : nil
                    )
                    parent.children[component] = node
                    parent = node
                }
            }
        }

        return root.immutableChildren()
    }
}

private final class MutableRepositoryFileTreeNode {
    let name: String
    let path: String
    let kind: RepositoryFileTreeNode.Kind
    var file: RepositoryFileEntry?
    var children: [String: MutableRepositoryFileTreeNode] = [:]

    init(
        name: String,
        path: String,
        kind: RepositoryFileTreeNode.Kind,
        file: RepositoryFileEntry? = nil
    ) {
        self.name = name
        self.path = path
        self.kind = kind
        self.file = file
    }

    func immutableChildren() -> [RepositoryFileTreeNode] {
        children.values
            .sorted {
                if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
                return $0.name.caseInsensitiveCompare($1.name) == .orderedAscending
            }
            .map { child in
                RepositoryFileTreeNode(
                    id: "\(child.kind == .folder ? "folder" : "file"):\(child.path)",
                    name: child.name,
                    path: child.path,
                    kind: child.kind,
                    file: child.file,
                    children: child.immutableChildren()
                )
            }
    }
}

package enum CommitSignatureStatus: Hashable, Sendable {
    case noSignature
    case goodSignature
    case signatureError
    case missingPublicKey
}

package enum TagSignatureStatus: Hashable, Sendable {
    case noTag
    case oneGood
    case oneBad
    case many
    case missingPublicKey
    case tagNotSigned
}

package struct RevisionGPGInfo: Hashable, Sendable {
    package let commitStatus: CommitSignatureStatus
    package let commitVerificationMessage: String
    package let tagStatus: TagSignatureStatus
    package let tagVerificationMessage: String?

    package init(commitStatus: CommitSignatureStatus, commitVerificationMessage: String, tagStatus: TagSignatureStatus, tagVerificationMessage: String?) {
        self.commitStatus = commitStatus
        self.commitVerificationMessage = commitVerificationMessage
        self.tagStatus = tagStatus
        self.tagVerificationMessage = tagVerificationMessage
    }
}

package enum SignatureIndicator: Hashable, Sendable {
    case none
    case good
    case warning
    case error
    case many
}

package struct SignatureRowPresentation: Equatable, Sendable {
    package let message: String
    package let indicator: SignatureIndicator
}

package struct RevisionGPGPresentation: Equatable, Sendable {
    package let commit: SignatureRowPresentation
    package let tag: SignatureRowPresentation?
}

package enum RevisionGPGPresentationResolver {
    package static func resolve(info: RevisionGPGInfo?) -> RevisionGPGPresentation {
        guard let info else {
            return RevisionGPGPresentation(
                commit: SignatureRowPresentation(message: "Commit is not signed", indicator: .none),
                tag: nil
            )
        }

        let commitIndicator: SignatureIndicator = switch info.commitStatus {
        case .noSignature: .none
        case .goodSignature: .good
        case .signatureError: .error
        case .missingPublicKey: .warning
        }
        let commitMessage = info.commitStatus == .noSignature
            ? "Commit is not signed"
            : info.commitVerificationMessage

        let tag: SignatureRowPresentation? = switch info.tagStatus {
        case .noTag:
            nil
        case .tagNotSigned:
            SignatureRowPresentation(message: "Tag is not signed", indicator: .none)
        case .oneGood:
            SignatureRowPresentation(message: info.tagVerificationMessage ?? "", indicator: .good)
        case .oneBad:
            SignatureRowPresentation(message: info.tagVerificationMessage ?? "", indicator: .error)
        case .many:
            SignatureRowPresentation(message: info.tagVerificationMessage ?? "", indicator: .many)
        case .missingPublicKey:
            SignatureRowPresentation(message: info.tagVerificationMessage ?? "", indicator: .warning)
        }

        return RevisionGPGPresentation(
            commit: SignatureRowPresentation(message: commitMessage, indicator: commitIndicator),
            tag: tag
        )
    }
}

package struct CommitRelations: Equatable, Sendable {
    package let parentIDs: [ObjectID]
    package let childIDs: [RevisionID]
    package let branchNames: [String]
    package let tagNames: [String]

    package init(parentIDs: [ObjectID], childIDs: [RevisionID], branchNames: [String], tagNames: [String]) {
        self.parentIDs = parentIDs
        self.childIDs = childIDs
        self.branchNames = branchNames
        self.tagNames = tagNames
    }
}

package enum CommitRelationsResolver {
    package static func resolve(commit: Commit, history: [Commit]) -> CommitRelations {
        CommitRelations(
            parentIDs: commit.parentIDs,
            childIDs: history.filter { candidate in
                candidate.kind == .workingDirectory
                    ? commit.kind == .index
                    : commit.objectID.map { candidate.parentIDs.contains($0) } ?? false
            }.map(\.id),
            branchNames: commit.references.filter {
                $0.kind == .currentBranch || $0.kind == .localBranch || $0.kind == .remoteBranch
            }.map(\.name),
            tagNames: commit.references.filter { $0.kind == .tag }.map(\.name)
        )
    }
}

package enum FileTreeSelectionResolver {
    package static func selectedPath(previousPath: String?, files: [RepositoryFileEntry]) -> String? {
        if let previousPath, files.contains(where: { $0.path == previousPath }) {
            return previousPath
        }
        return files.sorted { $0.path.caseInsensitiveCompare($1.path) == .orderedAscending }.first?.path
    }
}

package struct RepositoryIdentityState: Sendable {
    package let repositories: [Repository]
    package let currentRepository: Repository
    package let headID: ObjectID?

    package let userEmail: String?

    package init(repositories: [Repository], currentRepository: Repository, headID: ObjectID?, userEmail: String? = nil) {
        self.userEmail = userEmail
        self.repositories = repositories
        self.currentRepository = currentRepository
        self.headID = headID
    }
}

package struct RepositoryReferenceState: Sendable {
    package let branches: [Branch]
    package let tags: [Tag]
    package let referencesByCommit: [ObjectID: [RevisionReference]]

    package var references: [RevisionReference] { referencesByCommit.values.flatMap { $0 } }

    package init(branches: [Branch], tags: [Tag], referencesByCommit: [ObjectID: [RevisionReference]]) {
        self.branches = branches
        self.tags = tags
        self.referencesByCommit = referencesByCommit
    }
}

package struct RepositoryNavigationState: Sendable {
    package let remotes: [Remote]
    package let stashes: [Stash]
    package let worktrees: [Worktree]
    package let submodules: [Submodule]
    package let submoduleTree: [SubmoduleTreeItem]

    package init(remotes: [Remote], stashes: [Stash], worktrees: [Worktree], submodules: [Submodule], submoduleTree: [SubmoduleTreeItem] = []) {
        self.remotes = remotes
        self.stashes = stashes
        self.worktrees = worktrees
        self.submodules = submodules
        self.submoduleTree = submoduleTree
    }
}

package struct RevisionChangeCounts: Sendable, Hashable {
    package var changed: [String] = []
    package var added: [String] = []
    package var deleted: [String] = []
    package var submodulesChanged: [String] = []
    package var submodulesDirty: [String] = []
    package init() {}
}

package struct RepositoryStatusSummary: Sendable {
    package let visualState: RepositoryVisualState
    package let statusEntryCount: Int
    package let workingDirectoryChangeCount: Int
    package let worktree: RevisionChangeCounts?
    package let index: RevisionChangeCounts?

    package init(workingDirectoryChangeCount: Int, worktree: RevisionChangeCounts? = nil, index: RevisionChangeCounts? = nil, visualState: RepositoryVisualState = .unknown, statusEntryCount: Int? = nil) {
        self.visualState = visualState
        self.statusEntryCount = statusEntryCount ?? workingDirectoryChangeCount
        self.workingDirectoryChangeCount = workingDirectoryChangeCount
        self.worktree = worktree
        self.index = index
    }
}

package struct RepositoryNetworkContext: Sendable {
    package let repository: Repository
    package let headID: ObjectID?
    package let branches: [Branch]
    package let remotes: [Remote]
    package let references: [RevisionReference]
    package let submodules: [Submodule]

    package init(repository: Repository, headID: ObjectID?, branches: [Branch], remotes: [Remote], references: [RevisionReference], submodules: [Submodule]) {
        self.repository = repository
        self.headID = headID
        self.branches = branches
        self.remotes = remotes
        self.references = references
        self.submodules = submodules
    }
}

package struct RepositoryBranchContext: Sendable {
    package let repository: Repository
    package let headID: ObjectID?
    package let branches: [Branch]
    package let remotes: [Remote]
    package let referencesByCommit: [ObjectID: [RevisionReference]]
    package let submodules: [Submodule]

    package init(repository: Repository, headID: ObjectID?, branches: [Branch], remotes: [Remote], referencesByCommit: [ObjectID: [RevisionReference]], submodules: [Submodule]) {
        self.repository = repository
        self.headID = headID
        self.branches = branches
        self.remotes = remotes
        self.referencesByCommit = referencesByCommit
        self.submodules = submodules
    }
}

package struct RepositoryMergeContext: Sendable {
    package let repository: Repository
    package let branches: [Branch]
    package let tags: [Tag]
    package let referencesByCommit: [ObjectID: [RevisionReference]]
    package let submodules: [Submodule]

    package init(repository: Repository, branches: [Branch], tags: [Tag], referencesByCommit: [ObjectID: [RevisionReference]], submodules: [Submodule]) {
        self.repository = repository
        self.branches = branches
        self.tags = tags
        self.referencesByCommit = referencesByCommit
        self.submodules = submodules
    }
}

package struct RepositoryCommitContext: Sendable {
    package let repository: Repository
    package let headID: ObjectID?
    package let branches: [Branch]
    package let submodules: [Submodule]

    package init(repository: Repository, headID: ObjectID?, branches: [Branch], submodules: [Submodule]) {
        self.repository = repository
        self.headID = headID
        self.branches = branches
        self.submodules = submodules
    }
}

package struct RepositoryStashContext: Sendable {
    package let headID: ObjectID?
    package let stashes: [Stash]

    package init(headID: ObjectID?, stashes: [Stash]) {
        self.headID = headID
        self.stashes = stashes
    }
}

package struct RepositoryRebaseContext: Sendable {
    package let branches: [Branch]
    package let tags: [Tag]

    package init(branches: [Branch], tags: [Tag]) {
        self.branches = branches
        self.tags = tags
    }
}

package struct RepositoryRevisionDetails: Sendable {
    package let files: [ChangedFile]
    package let diffsByFile: [String: FileDiff]
    package let repositoryFiles: [RepositoryFileEntry]
    package let gpgInfo: RevisionGPGInfo?

    package init(files: [ChangedFile], diffsByFile: [String: FileDiff], repositoryFiles: [RepositoryFileEntry], gpgInfo: RevisionGPGInfo?) {
        self.files = files
        self.diffsByFile = diffsByFile
        self.repositoryFiles = repositoryFiles
        self.gpgInfo = gpgInfo
    }
}

package enum FilePreview<Value: Sendable>: Sendable {
    case ready(Value)
    case deferred(length: Int, load: @Sendable () async throws -> Value)

    package static var threshold: Int { 5 * 1024 * 1024 }

    package static func prepare(length: Int, defersLargeContent: Bool = true, load: @escaping @Sendable () async throws -> Value) async throws -> Self {
        try Task.checkCancellation()
        if defersLargeContent && length > threshold { return .deferred(length: length, load: load) }
        return .ready(try await load())
    }

    package func resolve() async throws -> Value {
        try Task.checkCancellation()
        switch self {
        case .ready(let value): return value
        case .deferred(_, let load): return try await load()
        }
    }
}
